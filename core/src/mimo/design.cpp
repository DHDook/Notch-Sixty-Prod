// MIMO room treatment design core (E19 S2, design notes 1-4 and 6). See n60/mimo.h.
//
// Offline, control or worker thread only; allocates freely; deterministic.
//
// Steps: decimate the plants to the low rate fs/D; take their spectra on a dense Hz grid (0.5 Hz);
// build the decaying, shifted, level-matched target per feed and seat; solve a per-bin Tikhonov problem
// for the delta E with a regularisation that rises 24 dB/octave outside each source's support range;
// taper and cap each source's row; check headroom and thermal budgets (re-solving with 4x more
// regularisation, at most four times); synthesise the taps by a direct sum of cosines on the Hz grid and
// window the tail. No FFT: the grid is in Hz, so a rate family gets the same design up to plant sampling.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

#include "n60/mimo.h"
#include "kernel.hpp"

namespace {

using Cx = std::complex<double>;
constexpr double kPi = 3.14159265358979323846;
constexpr double kLn1000 = 6.907755278982137;
constexpr uint32_t kCausalIterations = 5;       // proximal causality iterations per regularisation step
constexpr double kCausalPull = 1.0;             // weight of the pull towards the causal projection, re the mean plant power

std::vector<double> decimationKernel(uint32_t d) {
    std::vector<double> h(::n60::mimo::kernelTaps(d));
    ::n60::mimo::designKernel(d, h.data());
    return h;
}

void decimateInto(const std::vector<double> &h, uint32_t d, const float *in, uint64_t count, std::vector<double> &out) {
    const int64_t half = static_cast<int64_t>(h.size() / 2);
    const uint64_t n = (count + d - 1) / d;
    out.assign(n, 0.0);
    for (uint64_t j = 0; j < n; ++j) {
        const int64_t centre = static_cast<int64_t>(j) * d;
        const int64_t lo = std::max<int64_t>(0, centre - half);
        const int64_t hi = std::min<int64_t>(static_cast<int64_t>(count) - 1, centre + half);
        double acc = 0;
        for (int64_t i = lo; i <= hi; ++i) acc += h[static_cast<size_t>(i - centre + half)] * static_cast<double>(in[i]);
        out[j] = acc;
    }
}

// X(f) = sum x[n] exp(-j 2 pi f n / fs) at each frequency, by a phasor recurrence re-synchronised exactly.
void dtft(const std::vector<double> &x, double fs, const std::vector<double> &freqs, std::vector<Cx> &out) {
    out.assign(freqs.size(), Cx(0, 0));
    for (size_t k = 0; k < freqs.size(); ++k) {
        const double w = 2.0 * kPi * freqs[k] / fs;
        const Cx step(std::cos(w), -std::sin(w));
        Cx z(1, 0), acc(0, 0);
        for (size_t n = 0; n < x.size(); ++n) {
            if ((n & 63u) == 0) z = Cx(std::cos(w * static_cast<double>(n)), -std::sin(w * static_cast<double>(n)));
            acc += x[n] * z;
            z *= step;
        }
        out[k] = acc;
    }
}

double octavesOutside(double f, double lo, double hi) {
    if (f < lo) return std::log2(lo / f);
    if (f > hi) return std::log2(f / hi);
    return 0.0;
}

// Row taper (amplitude): 0 dB inside the support range, raised cosine in dB to -46 dB at one octave out, then
// 24 dB per octave further.
double rowTaper(double f, double lo, double hi) {
    const double o = octavesOutside(f, lo, hi);
    if (o <= 0.0) return 1.0;
    const double db = o < 1.0 ? -46.0 * 0.5 * (1.0 - std::cos(kPi * o)) : -46.0 - 24.0 * (o - 1.0);
    return std::pow(10.0, db / 20.0);
}

bool finite(const float *x, uint64_t n) {
    for (uint64_t i = 0; i < n; ++i) if (!std::isfinite(x[i])) return false;
    return true;
}

uint64_t argmaxAbs(const float *x, uint64_t n) {
    uint64_t best = 0;
    float peak = 0;
    for (uint64_t i = 0; i < n; ++i) if (std::fabs(x[i]) > peak) { peak = std::fabs(x[i]); best = i; }
    return best;
}

// In-place Cholesky of a Hermitian positive-definite n x n matrix (row-major lower), then solves.
bool cholesky(std::vector<Cx> &a, int n) {
    for (int j = 0; j < n; ++j) {
        double d = a[j * n + j].real();
        for (int k = 0; k < j; ++k) d -= std::norm(a[j * n + k]);
        if (!(d > 0.0)) return false;
        const double ljj = std::sqrt(d);
        a[j * n + j] = Cx(ljj, 0);
        for (int i = j + 1; i < n; ++i) {
            Cx s = a[i * n + j];
            for (int k = 0; k < j; ++k) s -= a[i * n + k] * std::conj(a[j * n + k]);
            a[i * n + j] = s / ljj;
        }
    }
    return true;
}

void choleskySolve(const std::vector<Cx> &l, int n, std::vector<Cx> &b) {
    for (int i = 0; i < n; ++i) {
        Cx s = b[i];
        for (int k = 0; k < i; ++k) s -= l[i * n + k] * b[k];
        b[i] = s / l[i * n + i].real();
    }
    for (int i = n - 1; i >= 0; --i) {
        Cx s = b[i];
        for (int k = i + 1; k < n; ++k) s -= std::conj(l[k * n + i]) * b[k];
        b[i] = s / l[i * n + i].real();
    }
}

}  // namespace

extern "C" {

uint32_t n60_mimo_abi_version(void) { return N60_MIMO_ABI_VERSION; }

void n60_mimo_defaults(double sample_rate, uint32_t source_count, uint32_t seat_count, n60_mimo_problem *p) {
    if (p == nullptr) return;
    *p = n60_mimo_problem{};
    p->struct_size = sizeof(n60_mimo_problem);
    p->sample_rate = sample_rate;
    p->source_count = source_count;
    p->seat_count = seat_count;
    p->primary_seat = 0;
    p->tau_seconds = 0.015; /* G11: recommended bass time target */
    p->decay_seconds = 0.3;
    p->taps = N60_MIMO_MAX_TAPS;
    p->regularisation = 1e-3;
    p->thermal_limit_db = -6.0;
    p->causality_limit_db = -12.0;
    for (uint32_t s = 0; s < N60_MIMO_MAX_SOURCES; ++s) {
        p->sources[s].excluded = 0;
        p->sources[s].support_low_hz = 25.0;
        p->sources[s].support_high_hz = 150.0;
        p->sources[s].excursion_corner_hz = 0.0;
        p->sources[s].effort_limit_db = 9.0;
        p->sources[s].gain_limit_db = 9.0;
        for (uint32_t m = 0; m < N60_MIMO_MAX_SEATS; ++m) p->program_arrival_seconds[s][m] = -1.0;
    }
    for (uint32_t m = 0; m < N60_MIMO_MAX_SEATS; ++m) {
        p->seats[m].included = 1;
        p->seats[m].weight = 1.0;
    }
}

int32_t n60_mimo_low_rate(double sample_rate, uint32_t *decimation_out, double *low_rate_out) {
    if (!(sample_rate >= 44000.0 && sample_rate <= 385000.0)) return N60_MIMO_ERR_RATE;
    uint32_t d = 16;
    if (sample_rate > 50000.0) d = 32;
    if (sample_rate > 100000.0) d = 64;
    if (sample_rate > 200000.0) d = 128;
    if (decimation_out != nullptr) *decimation_out = d;
    if (low_rate_out != nullptr) *low_rate_out = sample_rate / d;
    return N60_MIMO_OK;
}

int32_t n60_mimo_decimate(double sample_rate, const float *in, uint64_t count, float *out, uint64_t capacity,
                          uint64_t *count_out) {
    uint32_t d = 0;
    if (in == nullptr || out == nullptr || count_out == nullptr || count == 0) return N60_MIMO_ERR_ARGUMENT;
    if (n60_mimo_low_rate(sample_rate, &d, nullptr) != N60_MIMO_OK) return N60_MIMO_ERR_RATE;
    if (count > (1ull << 40)) return N60_MIMO_ERR_ARGUMENT;
    const uint64_t n = (count + d - 1) / d;
    if (capacity < n) return N60_MIMO_ERR_CAPACITY;
    std::vector<double> low;
    decimateInto(decimationKernel(d), d, in, count, low);
    for (uint64_t j = 0; j < n; ++j) out[j] = static_cast<float>(low[j]);
    *count_out = n;
    return N60_MIMO_OK;
}

int32_t n60_mimo_interpolate(double sample_rate, const float *in, uint64_t count, float *out, uint64_t capacity,
                             uint64_t *count_out) {
    uint32_t d = 0;
    if (in == nullptr || out == nullptr || count_out == nullptr || count == 0) return N60_MIMO_ERR_ARGUMENT;
    if (n60_mimo_low_rate(sample_rate, &d, nullptr) != N60_MIMO_OK) return N60_MIMO_ERR_RATE;
    if (count > (1ull << 40)) return N60_MIMO_ERR_ARGUMENT;
    const uint64_t n = count * d;
    if (capacity < n) return N60_MIMO_ERR_CAPACITY;
    const std::vector<double> h = decimationKernel(d);
    const int64_t half = static_cast<int64_t>(h.size() / 2);
    std::vector<double> acc(n, 0.0);
    for (uint64_t j = 0; j < count; ++j) {
        const double v = static_cast<double>(in[j]) * d;
        if (v == 0.0) continue;
        const int64_t centre = static_cast<int64_t>(j) * d;
        const int64_t lo = std::max<int64_t>(0, centre - half);
        const int64_t hi = std::min<int64_t>(static_cast<int64_t>(n) - 1, centre + half);
        for (int64_t i = lo; i <= hi; ++i) acc[static_cast<size_t>(i)] += v * h[static_cast<size_t>(i - centre + half)];
    }
    for (uint64_t i = 0; i < n; ++i) out[i] = static_cast<float>(acc[i]);
    *count_out = n;
    return N60_MIMO_OK;
}

void n60_mimo_tap_response(const float *taps, uint32_t count, double sample_rate, double hz, double *re_out,
                           double *im_out) {
    double re = 0, im = 0;
    const double w = 2.0 * kPi * hz / sample_rate;
    if (taps != nullptr) {
        for (uint32_t n = 0; n < count; ++n) {
            re += taps[n] * std::cos(w * n);
            im -= taps[n] * std::sin(w * n);
        }
    }
    if (re_out != nullptr) *re_out = re;
    if (im_out != nullptr) *im_out = im;
}

namespace {
int32_t designImpl(const n60_mimo_problem *p, float *delta_out, uint64_t capacity, float *solved_out,
                   uint64_t solved_capacity, n60_mimo_info *infoOut);
}  // namespace

int32_t n60_mimo_design(const n60_mimo_problem *p, float *delta_out, uint64_t capacity, n60_mimo_info *infoOut) {
    return designImpl(p, delta_out, capacity, nullptr, 0, infoOut);
}

int32_t n60_mimo_design_solved(const n60_mimo_problem *p, float *delta_out, uint64_t capacity, float *solved_out,
                               uint64_t solved_capacity, n60_mimo_info *infoOut) {
    if (solved_out == nullptr) return N60_MIMO_ERR_ARGUMENT;
    return designImpl(p, delta_out, capacity, solved_out, solved_capacity, infoOut);
}

namespace {
int32_t designImpl(const n60_mimo_problem *p, float *delta_out, uint64_t capacity, float *solved_out,
                   uint64_t solved_capacity, n60_mimo_info *infoOut) {
    n60_mimo_info scratch{};
    n60_mimo_info &info = infoOut != nullptr ? *infoOut : scratch;
    info = n60_mimo_info{};
    info.bad_source = -1;
    info.bad_seat = -1;
    for (uint32_t s = 0; s < N60_MIMO_MAX_SOURCES; ++s) {
        info.peak_gain_db[s] = 0.0;
        info.effort_peak_db[s] = -400.0;
        info.thermal_db[s] = -400.0;
    }
    if (p == nullptr || delta_out == nullptr || p->struct_size < sizeof(n60_mimo_problem)) return N60_MIMO_ERR_ARGUMENT;
    const uint32_t N = p->source_count, M = p->seat_count;
    if (N < 1 || N > N60_MIMO_MAX_SOURCES || M < 1 || M > N60_MIMO_MAX_SEATS) return N60_MIMO_ERR_ARGUMENT;
    if (p->taps < 64 || p->taps > N60_MIMO_MAX_TAPS) return N60_MIMO_ERR_ARGUMENT;
    if (!(p->decay_seconds >= 0.05 && p->decay_seconds <= 2.0)) return N60_MIMO_ERR_ARGUMENT;
    if (!(p->regularisation > 0.0) || !std::isfinite(p->regularisation)) return N60_MIMO_ERR_ARGUMENT;
    if (!std::isfinite(p->thermal_limit_db) || !std::isfinite(p->causality_limit_db)) return N60_MIMO_ERR_ARGUMENT;
    if (!std::isfinite(p->tau_seconds) || p->tau_seconds < 0.0 || p->tau_seconds > N60_MIMO_MAX_TAU_SECONDS) return N60_MIMO_ERR_TAU;
    uint32_t D = 0;
    double fs = 0;
    if (n60_mimo_low_rate(p->sample_rate, &D, &fs) != N60_MIMO_OK) return N60_MIMO_ERR_RATE;
    const uint64_t total = static_cast<uint64_t>(N) * N * p->taps;
    if (capacity < total) return N60_MIMO_ERR_CAPACITY;
    info.decimation = D;
    info.low_rate_hz = fs;
    info.taps = p->taps;
    info.tau_seconds = p->tau_seconds;

    std::vector<uint32_t> seats, active;
    if (p->primary_seat >= M || !p->seats[p->primary_seat].included) return N60_MIMO_ERR_ARGUMENT;
    for (uint32_t m = 0; m < M; ++m) {
        if (!p->seats[m].included) continue;
        if (!(p->seats[m].weight > 0.0) || !std::isfinite(p->seats[m].weight)) return N60_MIMO_ERR_ARGUMENT;
        seats.push_back(m);
    }
    double minLow = 1e9, maxHigh = 0;
    for (uint32_t s = 0; s < N; ++s) {
        const n60_mimo_source &src = p->sources[s];
        if (src.excluded) continue;
        if (!(src.support_low_hz >= 10.0 && src.support_low_hz < src.support_high_hz && src.support_high_hz <= 400.0))
            { info.bad_source = static_cast<int32_t>(s); return N60_MIMO_ERR_SUPPORT; }
        if (!std::isfinite(src.effort_limit_db) || !std::isfinite(src.gain_limit_db)) return N60_MIMO_ERR_ARGUMENT;
        active.push_back(s);
        minLow = std::min(minLow, src.support_low_hz);
        maxHigh = std::max(maxHigh, src.support_high_hz);
    }
    if (active.empty()) return N60_MIMO_ERR_SUPPORT;
    for (uint32_t s : active) {
        for (uint32_t m : seats) {
            if (p->program_plant[s][m] == nullptr || p->program_count[s][m] == 0 ||
                (p->injection_plant[s][m] != nullptr && p->injection_count[s][m] == 0)) {
                info.bad_source = static_cast<int32_t>(s);
                info.bad_seat = static_cast<int32_t>(m);
                return N60_MIMO_ERR_MISSING_PLANT;
            }
            if (!finite(p->program_plant[s][m], p->program_count[s][m]) ||
                (p->injection_plant[s][m] != nullptr && !finite(p->injection_plant[s][m], p->injection_count[s][m])))
                return N60_MIMO_ERR_ARGUMENT;
        }
    }

    // Grid in Hz: half the lowest support edge up to twice the highest (one octave outside every range).
    const double step = N60_MIMO_GRID_STEP_HZ;
    const double gLow = std::max(5.0, 0.5 * minLow);
    const double gHigh = std::min(2.0 * maxHigh, 0.4 * fs);
    std::vector<double> freqs;
    for (double f = std::ceil(gLow / step) * step; f <= gHigh + 1e-9; f += step) freqs.push_back(f);
    const size_t K = freqs.size();
    if (K < 8) return N60_MIMO_ERR_SUPPORT;
    info.grid_low_hz = freqs.front();
    info.grid_high_hz = freqs.back();
    info.grid_bins = static_cast<uint32_t>(K);

    // Plants at the low rate and their spectra.
    const std::vector<double> kernel = decimationKernel(D);
    const size_t A = active.size(), S = seats.size();
    std::vector<std::vector<Cx>> prog(A * S), inj(A * S), targ(A * S);
    std::vector<double> lowPlant;
    std::vector<double> win;
    for (size_t a = 0; a < A; ++a) {
        const uint32_t s = active[a];
        for (size_t mi = 0; mi < S; ++mi) {
            const uint32_t m = seats[mi];
            decimateInto(kernel, D, p->program_plant[s][m], p->program_count[s][m], lowPlant);
            dtft(lowPlant, fs, freqs, prog[a * S + mi]);
            double arrival = p->program_arrival_seconds[s][m];
            if (!(arrival >= 0.0)) arrival = static_cast<double>(argmaxAbs(p->program_plant[s][m], p->program_count[s][m])) / p->sample_rate;
            win = lowPlant;
            for (size_t j = 0; j < win.size(); ++j) {
                const double t = static_cast<double>(j) / fs;
                if (t > arrival) win[j] *= std::exp(-kLn1000 * (t - arrival) / p->decay_seconds);
            }
            dtft(win, fs, freqs, targ[a * S + mi]);
            if (p->injection_plant[s][m] != nullptr) {
                decimateInto(kernel, D, p->injection_plant[s][m], p->injection_count[s][m], lowPlant);
                dtft(lowPlant, fs, freqs, inj[a * S + mi]);
            } else {
                inj[a * S + mi] = prog[a * S + mi];
            }
        }
    }

    // In-band bins (inside some source's support range) for level matching and the regularisation scale.
    std::vector<uint8_t> inBand(K, 0);
    for (size_t k = 0; k < K; ++k) inBand[k] = (freqs[k] >= minLow && freqs[k] <= maxHigh) ? 1 : 0;
    double scale = 0;
    size_t scaleCount = 0;
    for (size_t a = 0; a < A; ++a)
        for (size_t mi = 0; mi < S; ++mi)
            for (size_t k = 0; k < K; ++k)
                if (inBand[k]) { scale += std::norm(inj[a * S + mi][k]); ++scaleCount; }
    if (scaleCount == 0 || !(scale > 0.0)) return N60_MIMO_ERR_UNUSABLE;
    scale /= static_cast<double>(scaleCount);

    // Level match: scale each target so its in-band power equals the untreated plant's.
    for (size_t i = 0; i < A * S; ++i) {
        double pp = 0, tt = 0;
        for (size_t k = 0; k < K; ++k) if (inBand[k]) { pp += std::norm(prog[i][k]); tt += std::norm(targ[i][k]); }
        if (!(tt > 0.0) || !(pp > 0.0)) return N60_MIMO_ERR_UNUSABLE;
        const double g = std::sqrt(pp / tt);
        for (size_t k = 0; k < K; ++k) targ[i][k] *= g;
    }

    double wsum = 0;
    for (uint32_t m : seats) wsum += p->seats[m].weight;
    std::vector<double> w(S);
    for (size_t mi = 0; mi < S; ++mi) w[mi] = p->seats[seats[mi]].weight * static_cast<double>(S) / wsum;

    // Causal projection of E: synthesise on the Hz grid, drop everything before t = 0, taper the end and transform
    // back to the grid. The solver pulls towards this projection (a proximal term), so the per-bin solution
    // converges to one that is nearly causal: a bin-wise inverse of a modal room is otherwise anti-causal, and
    // dropping that energy at synthesis would leave an uncancelled tail.
    const uint32_t pTaps = p->taps, pPre = pTaps / 4, pTail = pTaps / 4;
    const size_t pSpan = static_cast<size_t>(pPre) + pTaps;
    auto project = [&](const std::vector<Cx> &Ein, std::vector<Cx> &Eout) {
        std::vector<double> ser(pSpan);
        for (size_t pair = 0; pair < static_cast<size_t>(A) * A; ++pair) {
            std::fill(ser.begin(), ser.end(), 0.0);
            for (size_t k = 0; k < K; ++k) {
                const Cx e = Ein[pair * K + k];
                if (e == Cx(0, 0)) continue;
                const double w0 = 2.0 * kPi * freqs[k] / fs;
                const Cx stepZ(std::cos(w0), std::sin(w0));
                Cx z(1, 0);
                for (size_t n = 0; n < pSpan; ++n) {
                    if ((n & 63u) == 0) {
                        const double ang = w0 * (static_cast<double>(n) - static_cast<double>(pPre));
                        z = Cx(std::cos(ang), std::sin(ang));
                    }
                    ser[n] += 2.0 * (e * z).real();
                    z *= stepZ;
                }
            }
            for (size_t n = 0; n < pSpan; ++n) {
                double v = ser[n] * step / fs;
                if (n < pPre) v = 0.0;
                else {
                    const uint32_t t = static_cast<uint32_t>(n - pPre);
                    if (t >= pTaps - pTail) {
                        const double u = static_cast<double>(t - (pTaps - pTail)) / pTail;
                        v *= 0.5 * (1.0 + std::cos(kPi * u));
                    }
                }
                ser[n] = v;
            }
            for (size_t k = 0; k < K; ++k) {
                const double w0 = 2.0 * kPi * freqs[k] / fs;
                const Cx stepZ(std::cos(w0), -std::sin(w0));
                Cx z(1, 0), acc(0, 0);
                for (size_t n = pPre; n < pSpan; ++n) {
                    if (((n - pPre) & 63u) == 0) {
                        const double ang = -w0 * static_cast<double>(n - pPre);
                        z = Cx(std::cos(ang), std::sin(ang));
                    }
                    acc += ser[n] * z;
                    z *= stepZ;
                }
                Eout[pair * K + k] = acc;
            }
        }
    };
    std::vector<Cx> Ecausal(static_cast<size_t>(A) * A * K, Cx(0, 0));

    // Solve, taper, cap and check; re-solve with more regularisation on a headroom or thermal miss.
    std::vector<Cx> E(static_cast<size_t>(A) * A * K);   // [(sa * A + ta) * K + k]
    std::vector<Cx> mat(A * A), rhs(A);
    int32_t failure = N60_MIMO_OK;
    for (uint32_t attempt = 0; attempt < 5; ++attempt) {
        const double eps = p->regularisation * std::pow(4.0, attempt);
        info.regularisation_used = eps;
        info.regularisation_steps = attempt;
        info.capped_bins = 0;
        failure = N60_MIMO_OK;
        std::fill(Ecausal.begin(), Ecausal.end(), Cx(0, 0));
        for (uint32_t it = 0; it < kCausalIterations; ++it) {
            const double muRel = it == 0 ? 0.0 : kCausalPull;
            std::fill(E.begin(), E.end(), Cx(0, 0));
            for (size_t k = 0; k < K; ++k) {
                const double f = freqs[k];
                const double om = 2.0 * kPi * f * p->tau_seconds;
                const Cx delay(std::cos(om), -std::sin(om));
                for (size_t i = 0; i < A; ++i) {
                    for (size_t j = 0; j <= i; ++j) {
                        Cx acc(0, 0);
                        for (size_t mi = 0; mi < S; ++mi) acc += w[mi] * std::conj(inj[i * S + mi][k]) * inj[j * S + mi][k];
                        mat[i * A + j] = acc;
                        mat[j * A + i] = std::conj(acc);
                    }
                    const n60_mimo_source &src = p->sources[active[i]];
                    mat[i * A + i] += eps * scale * std::pow(10.0, 2.4 * octavesOutside(f, src.support_low_hz, src.support_high_hz)) ; 
                }
                double mu = 0.0;
                if (muRel > 0.0) {
                    for (size_t i = 0; i < A; ++i) mu += mat[i * A + i].real();
                    mu *= muRel / static_cast<double>(A);
                    for (size_t i = 0; i < A; ++i) mat[i * A + i] += mu;
                }
                if (!cholesky(mat, static_cast<int>(A))) return N60_MIMO_ERR_UNUSABLE;
                for (size_t ta = 0; ta < A; ++ta) {
                    for (size_t i = 0; i < A; ++i) {
                        Cx acc(0, 0);
                        for (size_t mi = 0; mi < S; ++mi) {
                            const Cx d = delay * (targ[ta * S + mi][k] - prog[ta * S + mi][k]);
                            acc += w[mi] * std::conj(inj[i * S + mi][k]) * d;
                        }
                        if (mu > 0.0) acc += mu * Ecausal[(i * A + ta) * K + k];
                        rhs[i] = acc;
                    }
                    choleskySolve(mat, static_cast<int>(A), rhs);
                    for (size_t i = 0; i < A; ++i) E[(i * A + ta) * K + k] = rhs[i];
                }
                // Row taper and effort cap.
                for (size_t i = 0; i < A; ++i) {
                    const n60_mimo_source &src = p->sources[active[i]];
                    const double taper = rowTaper(f, src.support_low_hz, src.support_high_hz);
                    double norm2 = 0;
                    for (size_t ta = 0; ta < A; ++ta) {
                        E[(i * A + ta) * K + k] *= taper;
                        norm2 += std::norm(E[(i * A + ta) * K + k]);
                    }
                    const double corner = src.excursion_corner_hz > 0.0 ? src.excursion_corner_hz : src.support_low_hz;
                    double cap = std::pow(10.0, src.effort_limit_db / 20.0);
                    if (f < corner) cap *= (f / corner) * (f / corner);
                    const double norm = std::sqrt(norm2);
                    if (norm > cap) {
                        const double g = cap / norm;
                        for (size_t ta = 0; ta < A; ++ta) E[(i * A + ta) * K + k] *= g;
                        ++info.capped_bins;
                    }
                }
            }
            if (it + 1 < kCausalIterations) project(E, Ecausal);
        }
        // Budgets.
        for (size_t i = 0; i < A; ++i) {
            const n60_mimo_source &src = p->sources[active[i]];
            double peakGain = 0, peakEffort = 0, powerSum = 0;
            size_t powerCount = 0;
            for (size_t k = 0; k < K; ++k) {
                const double om = 2.0 * kPi * freqs[k] * p->tau_seconds;
                const Cx delay(std::cos(om), -std::sin(om));
                double gain = 0, effort2 = 0;
                for (size_t ta = 0; ta < A; ++ta) {
                    const Cx e = E[(i * A + ta) * K + k];
                    gain += std::abs(e + (ta == i ? delay : Cx(0, 0)));
                    effort2 += std::norm(e);
                }
                peakGain = std::max(peakGain, gain);
                peakEffort = std::max(peakEffort, std::sqrt(effort2));
                if (freqs[k] >= src.support_low_hz && freqs[k] <= src.support_high_hz) { powerSum += effort2; ++powerCount; }
            }
            const uint32_t s = active[i];
            info.peak_gain_db[s] = 20.0 * std::log10(std::max(peakGain, 1e-20));
            info.effort_peak_db[s] = 20.0 * std::log10(std::max(peakEffort, 1e-20));
            info.thermal_db[s] = powerCount ? 10.0 * std::log10(std::max(powerSum / static_cast<double>(powerCount), 1e-40)) : -400.0;
            if (info.peak_gain_db[s] > src.gain_limit_db && failure == N60_MIMO_OK) {
                failure = N60_MIMO_ERR_HEADROOM;
                info.bad_source = static_cast<int32_t>(s);
            }
            if (info.thermal_db[s] > p->thermal_limit_db && failure == N60_MIMO_OK) {
                failure = N60_MIMO_ERR_THERMAL;
                info.bad_source = static_cast<int32_t>(s);
            }
        }
        if (failure == N60_MIMO_OK) { info.bad_source = -1; break; }
    }
    if (failure != N60_MIMO_OK) return failure;

    // Optional readback of the solved (pre-synthesis) response, for the realisation check.
    if (solved_out != nullptr) {
        const uint64_t need = static_cast<uint64_t>(N) * N * K * 2u;
        if (solved_capacity < need) return N60_MIMO_ERR_CAPACITY;
        std::fill(solved_out, solved_out + need, 0.0f);
        for (size_t i = 0; i < A; ++i)
            for (size_t ta = 0; ta < A; ++ta) {
                float *dst = solved_out + ((static_cast<uint64_t>(active[i]) * N + active[ta]) * K) * 2u;
                for (size_t k = 0; k < K; ++k) {
                    const Cx e = E[(i * A + ta) * K + k];
                    dst[2 * k] = static_cast<float>(e.real());
                    dst[2 * k + 1] = static_cast<float>(e.imag());
                }
            }
    }

    // Synthesis on the Hz grid: c[n] = (df / fs) * sum_k 2 Re(E_k exp(j w_k n)), for n from -pre to taps - 1.
    const uint32_t taps = p->taps, pre = taps / 4;
    const size_t span = static_cast<size_t>(pre) + taps;
    std::fill(delta_out, delta_out + total, 0.0f);
    std::vector<double> series(span);
    double preEnergy = 0, allEnergy = 0;
    const uint32_t tail = taps / 4;
    for (size_t i = 0; i < A; ++i) {
        for (size_t ta = 0; ta < A; ++ta) {
            std::fill(series.begin(), series.end(), 0.0);
            for (size_t k = 0; k < K; ++k) {
                const Cx e = E[(i * A + ta) * K + k];
                if (e == Cx(0, 0)) continue;
                const double w0 = 2.0 * kPi * freqs[k] / fs;
                const Cx stepZ(std::cos(w0), std::sin(w0));
                Cx z(1, 0);
                for (size_t n = 0; n < span; ++n) {
                    if ((n & 63u) == 0) {
                        const double ang = w0 * (static_cast<double>(n) - static_cast<double>(pre));
                        z = Cx(std::cos(ang), std::sin(ang));
                    }
                    series[n] += 2.0 * (e * z).real();
                    z *= stepZ;
                }
            }
            float *dst = delta_out + (static_cast<uint64_t>(active[i]) * N + active[ta]) * taps;
            for (size_t n = 0; n < span; ++n) {
                double v = series[n] * step / fs;
                if (n < pre) { preEnergy += v * v; allEnergy += v * v; continue; }
                const uint32_t t = static_cast<uint32_t>(n - pre);
                if (t >= taps - tail) {
                    const double u = static_cast<double>(t - (taps - tail)) / tail;
                    v *= 0.5 * (1.0 + std::cos(kPi * u));
                }
                allEnergy += v * v;
                dst[t] = static_cast<float>(v);
            }
        }
    }
    info.pre_energy_db = allEnergy > 1e-30 ? 10.0 * std::log10(std::max(preEnergy, 1e-40) / allEnergy) : -400.0;
    if (info.pre_energy_db > p->causality_limit_db) return N60_MIMO_ERR_CAUSALITY;
    return N60_MIMO_OK;
}
}  // namespace

int32_t n60_mimo_problem_set_plant(n60_mimo_problem *p, uint32_t source, uint32_t seat, const float *program,
                                   uint64_t program_count, const float *injection, uint64_t injection_count,
                                   double program_arrival_seconds) {
    if (p == nullptr || source >= N60_MIMO_MAX_SOURCES || seat >= N60_MIMO_MAX_SEATS) return N60_MIMO_ERR_ARGUMENT;
    p->program_plant[source][seat] = program;
    p->program_count[source][seat] = program != nullptr ? program_count : 0;
    p->injection_plant[source][seat] = injection;
    p->injection_count[source][seat] = injection != nullptr ? injection_count : 0;
    p->program_arrival_seconds[source][seat] = program_arrival_seconds;
    return N60_MIMO_OK;
}

int32_t n60_mimo_problem_set_source(n60_mimo_problem *p, uint32_t source, const n60_mimo_source *value) {
    if (p == nullptr || value == nullptr || source >= N60_MIMO_MAX_SOURCES) return N60_MIMO_ERR_ARGUMENT;
    p->sources[source] = *value;
    return N60_MIMO_OK;
}

int32_t n60_mimo_problem_set_seat(n60_mimo_problem *p, uint32_t seat, const n60_mimo_seat *value) {
    if (p == nullptr || value == nullptr || seat >= N60_MIMO_MAX_SEATS) return N60_MIMO_ERR_ARGUMENT;
    p->seats[seat] = *value;
    return N60_MIMO_OK;
}

int32_t n60_mimo_realise_check(const n60_mimo_problem *p, const float *delta, uint64_t delta_count, const float *solved,
                               uint64_t solved_count, const n60_mimo_info *info, n60_mimo_realisation *out) {
    if (p == nullptr || delta == nullptr || solved == nullptr || info == nullptr || out == nullptr ||
        p->struct_size < sizeof(n60_mimo_problem))
        return N60_MIMO_ERR_ARGUMENT;
    *out = n60_mimo_realisation{};
    const uint32_t N = p->source_count, taps = p->taps, K = info->grid_bins;
    if (N < 1 || N > N60_MIMO_MAX_SOURCES || K < 2 || info->decimation == 0 || !(info->low_rate_hz > 0.0))
        return N60_MIMO_ERR_ARGUMENT;
    if (delta_count < static_cast<uint64_t>(N) * N * taps || solved_count < static_cast<uint64_t>(N) * N * K * 2u)
        return N60_MIMO_ERR_CAPACITY;
    const double fs = info->low_rate_hz;
    const double step = N60_MIMO_GRID_STEP_HZ;
    for (uint32_t s = 0; s < N60_MIMO_MAX_SOURCES; ++s) {
        out->gain_overshoot_db[s] = -400.0;
        out->effort_overshoot_db[s] = -400.0;
    }
    // Edge energy: the last eighth of every filter against the whole filter (the tail is windowed in the design).
    const uint32_t edge = taps / 8;
    for (uint32_t s = 0; s < N; ++s)
        for (uint32_t t = 0; t < N; ++t) {
            const float *h = delta + (static_cast<uint64_t>(s) * N + t) * taps;
            double all = 0, tail = 0;
            for (uint32_t n = 0; n < taps; ++n) {
                const double v = static_cast<double>(h[n]) * h[n];
                all += v;
                if (n >= taps - edge) tail += v;
            }
            if (all > 1e-30) out->edge_energy_fraction = std::max(out->edge_energy_fraction, tail / all);
        }
    // Dense response over each source's support range, against the solved response interpolated on its grid.
    const double dense = N60_MIMO_DENSE_STEP_HZ;
    const double tau = p->tau_seconds;
    for (uint32_t s = 0; s < N; ++s) {
        const n60_mimo_source &src = p->sources[s];
        if (src.excluded) continue;
        // The judged band is the support range less a third of an octave at each edge, where the design's own
        // roll-off (row taper, rising regularisation) is steep and a hard comparison would judge the taper.
        const double inset = std::pow(2.0, 1.0 / 3.0);
        const double lo = std::max(src.support_low_hz * inset, info->grid_low_hz);
        const double hi = std::min(src.support_high_hz / inset, info->grid_high_hz);
        double devMax = 0, gainPeak = 0, effortPeak = 0;
        // Gain and effort are peaks over the whole solved band; deviation is judged in the support range.
        for (double f = info->grid_low_hz; f <= info->grid_high_hz + 1e-9; f += dense) {
            double gain = 0, eff2 = 0, err2 = 0;
            const double pos = (f - info->grid_low_hz) / step;
            uint32_t k0 = static_cast<uint32_t>(std::floor(pos));
            if (k0 >= K - 1) k0 = K - 2;
            const double frac = pos - k0;
            const double om = 2.0 * kPi * f * tau;
            for (uint32_t t = 0; t < N; ++t) {
                const float *h = delta + (static_cast<uint64_t>(s) * N + t) * taps;
                double re = 0, im = 0;
                {   // Rotating phasor, re-seeded every 64 taps (same sum as n60_mimo_tap_response, much cheaper).
                    const double w = 2.0 * kPi * f / fs;
                    const double cs = std::cos(w), sn = std::sin(w);
                    double zr = 1.0, zi = 0.0;
                    for (uint32_t n = 0; n < taps; ++n) {
                        if ((n & 63u) == 0) { zr = std::cos(w * n); zi = std::sin(w * n); }
                        re += h[n] * zr;
                        im -= h[n] * zi;
                        const double nr = zr * cs - zi * sn;
                        zi = zr * sn + zi * cs;
                        zr = nr;
                    }
                }
                const float *sv = solved + (static_cast<uint64_t>(s) * N + t) * K * 2u;
                const double sre = sv[2 * k0] * (1.0 - frac) + sv[2 * (k0 + 1)] * frac;
                const double sim = sv[2 * k0 + 1] * (1.0 - frac) + sv[2 * (k0 + 1) + 1] * frac;
                eff2 += re * re + im * im;
                err2 += (re - sre) * (re - sre) + (im - sim) * (im - sim);
                const double cre = re + (t == s ? std::cos(om) : 0.0);
                const double cim = im + (t == s ? -std::sin(om) : 0.0);
                gain += std::sqrt(cre * cre + cim * cim);
            }
            gainPeak = std::max(gainPeak, gain);
            effortPeak = std::max(effortPeak, std::sqrt(eff2));
            if (f >= lo && f <= hi) {
                const double d = 20.0 * std::log10(1.0 + std::sqrt(err2) / std::max(gain, 1e-6));
                if (d > devMax) { devMax = d; if (d > out->max_deviation_db) out->max_deviation_hz = f; }
            }
        }
        out->max_deviation_db = std::max(out->max_deviation_db, devMax);
        out->gain_peak_db[s] = 20.0 * std::log10(std::max(gainPeak, 1e-20));
        out->effort_peak_db[s] = 20.0 * std::log10(std::max(effortPeak, 1e-20));
        out->gain_overshoot_db[s] = out->gain_peak_db[s] - src.gain_limit_db;
        out->effort_overshoot_db[s] = out->effort_peak_db[s] - src.effort_limit_db;
    }
    return N60_MIMO_OK;
}

}  // extern "C"
