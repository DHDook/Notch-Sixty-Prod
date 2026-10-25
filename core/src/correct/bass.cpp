// Joint mains-and-subwoofer bass optimiser (E10 S6, design note 7).
//
// Offline only: control or worker thread, allocates freely, never called from an audio callback.
// Double precision, fixed summation order, fixed starts, no threads and no randomness, so two runs
// give identical bits. See the model and the two steps in n60/correct.h, section 5.
//
// Derivation: the seat response is a sum of the channel responses H_kn through the analytic
// Linkwitz-Riley 4 crossover, a delay, a gain and a polarity (the model of the header). Step (i)
// minimises the weighted variance of the seat log-magnitudes around the target shape, over the
// fit band (coordinate descent on a delay/polarity/gain grid, then Levenberg-Marquardt with the
// analytic Jacobian d ln|E| = Re(dE / E)). Step (ii) is Tikhonov-regularised weighted least
// squares per grid point, solved by Gaussian elimination on the N x N normal equations, with the
// boost cap enforced by an active set (Lawson and Hanson style clamp-and-resolve).
#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

#include "common.hpp"
#include "../measure/offline_fft.hpp"

namespace {

using namespace n60::correct;
using Complex = std::complex<double>;

constexpr uint32_t kGrid = N60_CORRECT_GRID_POINTS;
constexpr uint32_t kMaxSeats = 64;
constexpr double kThirdOctave = 1.2599210498948732;  // 2^(1/3)

bool finite(double v) { return std::isfinite(v); }

// ---- parameter checks ------------------------------------------------------------------------

struct Resolved {
    double crossover = 80, fit_low = 20, fit_high = 120, fir_high = 160, max_delay = 0.02, max_boost = 6, reg = 0.01;
    double ir_seconds = 0;
};

bool resolveParams(const n60_correct_problem *problem, const n60_correct_bass_params *p, Resolved &r) {
    if (problem == nullptr || p == nullptr || problem->irs == nullptr || p->channels == nullptr) return false;
    if (!finite(problem->sample_rate) || problem->sample_rate < 8000.0 || problem->sample_rate > 768000.0) return false;
    if (problem->channel_count == 0 || problem->channel_count > N60_CORRECT_MAX_BASS_CHANNELS || problem->seat_count == 0 ||
        problem->seat_count > kMaxSeats) {
        return false;
    }
    if (!finite(p->crossover_hz) || p->crossover_hz < 20.0 || p->crossover_hz > 500.0) return false;
    r.crossover = p->crossover_hz;
    r.fit_low = p->fit_low_hz;
    r.fit_high = p->fit_high_hz > 0.0 ? p->fit_high_hz : 1.5 * r.crossover;
    r.fir_high = p->fir_high_hz > 0.0 ? p->fir_high_hz : 2.0 * r.crossover;
    r.max_delay = p->max_delay_seconds;
    r.max_boost = p->max_boost_db;
    r.reg = p->regularisation;
    r.ir_seconds = p->ir_seconds;
    if (!finite(r.fit_low) || !finite(r.fit_high) || !finite(r.fir_high) || r.fit_low < 10.0 || !(r.fit_high > r.fit_low * 2.0) ||
        !(r.fir_high >= r.fit_high / kThirdOctave)) {
        return false;
    }
    if (r.fir_high * kThirdOctave > 0.45 * problem->sample_rate) return false;
    if (!finite(r.max_delay) || r.max_delay < 0.0 || r.max_delay > 0.1) return false;
    if (!finite(r.max_boost) || r.max_boost < 0.0 || r.max_boost > 12.0) return false;
    if (!finite(r.reg) || r.reg < 1e-6 || r.reg > 10.0) return false;
    if (!finite(r.ir_seconds) || r.ir_seconds < 0.0) return false;
    for (uint32_t n = 0; n < problem->channel_count; ++n) {
        const n60_correct_bass_channel &c = p->channels[n];
        if (c.role > N60_CORRECT_BASS_ROLE_SUB) return false;
        if (!finite(c.min_gain_db) || !finite(c.max_gain_db) || c.min_gain_db > c.max_gain_db || c.min_gain_db < -60.0 ||
            c.max_gain_db > 24.0) {
            return false;
        }
    }
    if (p->target_points > 0) {
        if (p->target_frequencies_hz == nullptr || p->target_gain_db == nullptr) return false;
        for (uint32_t i = 0; i < p->target_points; ++i) {
            if (!finite(p->target_frequencies_hz[i]) || !finite(p->target_gain_db[i]) || !(p->target_frequencies_hz[i] > 0.0)) return false;
            if (i > 0 && !(p->target_frequencies_hz[i] > p->target_frequencies_hz[i - 1])) return false;
        }
    }
    double weightSum = 0;
    for (uint32_t n = 0; n < problem->channel_count; ++n) {
        for (uint32_t k = 0; k < problem->seat_count; ++k) {
            const n60_correct_seat_ir &ir = problem->irs[static_cast<size_t>(n) * problem->seat_count + k];
            if (ir.ir == nullptr || ir.frames < 64 || !finite(ir.arrival_frames) || ir.arrival_frames < 0.0 ||
                ir.arrival_frames >= static_cast<double>(ir.frames) || !finite(ir.weight) || ir.weight < 0.0) {
                return false;
            }
            if (n == 0) weightSum += ir.weight;
        }
    }
    return weightSum > 0.0;
}

// ---- the model ---------------------------------------------------------------------------------

// Linkwitz-Riley 4 (two cascaded Butterworth 2nd-order sections) at hz for crossover fc.
Complex crossoverResponse(bool highPass, double hz, double fc) {
    const Complex s(0.0, hz / fc);
    const Complex denominator = s * s + std::sqrt(2.0) * s + 1.0;
    const Complex section = (highPass ? s * s : Complex(1.0, 0.0)) / denominator;
    return section * section;
}

struct Model {
    uint32_t N = 0, K = 0;
    double fs = 0;
    std::vector<double> freq;       // all grid points
    std::vector<Complex> B;         // [g][k][n]: crossover * measured response
    std::vector<double> w;          // seat weights, normalised to sum 1
    std::vector<double> lnT;        // log of the target shape at every grid point
    uint32_t fit0 = 0, fit1 = 0;    // fit band, grid indices inclusive
    uint32_t solve0 = 0, solve1 = 0;// correction solve band, inclusive

    Complex &b(uint32_t g, uint32_t k, uint32_t n) { return B[(static_cast<size_t>(g) * K + k) * N + n]; }
    const Complex &b(uint32_t g, uint32_t k, uint32_t n) const { return B[(static_cast<size_t>(g) * K + k) * N + n]; }
};

struct Setting {
    double delay[N60_CORRECT_MAX_BASS_CHANNELS] = {};
    double gain_db[N60_CORRECT_MAX_BASS_CHANNELS] = {};
    bool invert[N60_CORRECT_MAX_BASS_CHANNELS] = {};
};

// Channel factor of the model without the filter: polarity * gain * e^{-j 2 pi f d}.
Complex channelFactor(const Setting &s, uint32_t n, double hz) {
    const double mag = (s.invert[n] ? -1.0 : 1.0) * std::pow(10.0, s.gain_db[n] / 20.0);
    const double ph = -2.0 * kPi * hz * s.delay[n];
    return Complex(mag * std::cos(ph), mag * std::sin(ph));
}

// Real spectrum of one IR interpolated onto the correction grid (complex linear interpolation on a
// 4x zero-padded FFT: the bin spacing is under a quarter of the IR's own resolution).
bool irOnGrid(const n60_correct_seat_ir &ir, double fs, double irSeconds, std::vector<Complex> &out) {
    uint64_t used = ir.frames;
    if (irSeconds > 0.0) used = std::min<uint64_t>(used, std::max<uint64_t>(64, static_cast<uint64_t>(std::llround(irSeconds * fs))));
    const uint64_t n = nextPow2(used * 4);
    if (!n60::fft::offline::validSize(n)) return false;
    std::vector<double> x(n, 0.0);
    const double fadeStart = 0.75 * static_cast<double>(used);
    for (uint64_t i = 0; i < used; ++i) {
        double v = static_cast<double>(ir.ir[i]);
        if (irSeconds > 0.0 && static_cast<double>(i) > fadeStart) {
            const double u = (static_cast<double>(i) - fadeStart) / (static_cast<double>(used) - fadeStart);
            v *= 0.5 * (1.0 + std::cos(kPi * std::min(u, 1.0)));
        }
        x[i] = v;
    }
    std::vector<n60::fft::offline::Cplx> spectrum;
    if (!n60::fft::offline::realForward(x.data(), n, spectrum)) return false;
    out.assign(kGrid, Complex(0.0, 0.0));
    const double binHz = fs / static_cast<double>(n);
    const size_t last = spectrum.size() - 1;
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double pos = gridFrequency(g) / binHz;
        size_t lo = static_cast<size_t>(std::floor(pos));
        if (lo >= last) lo = last - 1;
        const double fr = std::min(1.0, pos - static_cast<double>(lo));
        const auto &a = spectrum[lo];
        const auto &b = spectrum[lo + 1];
        out[g] = Complex(a.re + fr * (b.re - a.re), a.im + fr * (b.im - a.im));
    }
    return true;
}

// ---- step (i) ------------------------------------------------------------------------------------

// Sum over channels of the model term, for one grid point and seat: channel factor times B.
struct Cost {
    double value = 0;
    double offset = 0;  // the fitted mean level c, in natural-log units
};

// Cost of a complete setting over the fit band: the weighted seat-to-seat variance of ln|E| per bin,
// averaged over the band. The per-bin mean is the common response the correction filters flatten
// afterwards, so alignment is judged on the spread the filters cannot remove.
Cost evaluate(const Model &m, const Setting &s) {
    Cost c;
    const double bins = static_cast<double>(m.fit1 - m.fit0 + 1);
    double total = 0.0;
    for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
        Complex factor[N60_CORRECT_MAX_BASS_CHANNELS];
        for (uint32_t n = 0; n < m.N; ++n) factor[n] = channelFactor(s, n, m.freq[g]);
        double v[64];
        double mean = 0.0;
        for (uint32_t k = 0; k < m.K; ++k) {
            Complex e(0.0, 0.0);
            for (uint32_t n = 0; n < m.N; ++n) e += factor[n] * m.b(g, k, n);
            v[k] = std::log(std::max(std::abs(e), 1e-12));
            mean += m.w[k] * v[k];
        }
        for (uint32_t k = 0; k < m.K; ++k) total += m.w[k] * (v[k] - mean) * (v[k] - mean) / bins;
    }
    c.value = total;
    return c;
}

// Cost of one candidate (delay, gain, polarity) for channel n with the other channels summed in `rest`.
double evaluateCandidate(const Model &m, const std::vector<Complex> &rest, uint32_t n, double delay, double gainDb, bool invert) {
    const double mag = (invert ? -1.0 : 1.0) * std::pow(10.0, gainDb / 20.0);
    const double bins = static_cast<double>(m.fit1 - m.fit0 + 1);
    double total = 0.0;
    for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
        const double ph = -2.0 * kPi * m.freq[g] * delay;
        const Complex factor(mag * std::cos(ph), mag * std::sin(ph));
        double v[64];
        double mean = 0.0;
        for (uint32_t k = 0; k < m.K; ++k) {
            const Complex e = rest[static_cast<size_t>(g - m.fit0) * m.K + k] + factor * m.b(g, k, n);
            v[k] = std::log(std::max(std::abs(e), 1e-12));
            mean += m.w[k] * v[k];
        }
        for (uint32_t k = 0; k < m.K; ++k) total += m.w[k] * (v[k] - mean) * (v[k] - mean) / bins;
    }
    return total;
}

void restOf(const Model &m, const Setting &s, uint32_t skip, std::vector<Complex> &rest) {
    rest.assign(static_cast<size_t>(m.fit1 - m.fit0 + 1) * m.K, Complex(0.0, 0.0));
    for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
        for (uint32_t n = 0; n < m.N; ++n) {
            if (n == skip) continue;
            const Complex factor = channelFactor(s, n, m.freq[g]);
            for (uint32_t k = 0; k < m.K; ++k) rest[static_cast<size_t>(g - m.fit0) * m.K + k] += factor * m.b(g, k, n);
        }
    }
}

double clampd(double v, double lo, double hi) { return std::min(std::max(v, lo), hi); }

// Solves A x = b (n x n, row-major, destroyed) by Gaussian elimination with partial pivoting.
bool solveReal(std::vector<double> &a, std::vector<double> &b, uint32_t n) {
    for (uint32_t c = 0; c < n; ++c) {
        uint32_t piv = c;
        for (uint32_t r = c + 1; r < n; ++r) {
            if (std::fabs(a[r * n + c]) > std::fabs(a[piv * n + c])) piv = r;
        }
        if (std::fabs(a[piv * n + c]) < 1e-300) return false;
        if (piv != c) {
            for (uint32_t j = 0; j < n; ++j) std::swap(a[c * n + j], a[piv * n + j]);
            std::swap(b[c], b[piv]);
        }
        for (uint32_t r = c + 1; r < n; ++r) {
            const double f = a[r * n + c] / a[c * n + c];
            for (uint32_t j = c; j < n; ++j) a[r * n + j] -= f * a[c * n + j];
            b[r] -= f * b[c];
        }
    }
    for (int64_t r = static_cast<int64_t>(n) - 1; r >= 0; --r) {
        double v = b[static_cast<size_t>(r)];
        for (uint32_t j = static_cast<uint32_t>(r) + 1; j < n; ++j) v -= a[static_cast<size_t>(r) * n + j] * b[j];
        b[static_cast<size_t>(r)] = v / a[static_cast<size_t>(r) * n + static_cast<size_t>(r)];
    }
    return true;
}

// Levenberg-Marquardt polish of the continuous delays (in ms) and gains of the free channels.
void polish(const Model &m, const n60_correct_bass_channel *ch, double maxDelay, Setting &s) {
    uint32_t idx[2 * N60_CORRECT_MAX_BASS_CHANNELS];  // parameter -> channel
    bool isGain[2 * N60_CORRECT_MAX_BASS_CHANNELS];
    uint32_t P = 0;
    for (uint32_t n = 0; n < m.N; ++n) {
        if (ch[n].free_delay) { idx[P] = n; isGain[P++] = false; }
        if (ch[n].free_gain) { idx[P] = n; isGain[P++] = true; }
    }
    if (P == 0) return;
    const uint32_t bins = m.fit1 - m.fit0 + 1;
    double mu = 1e-3;
    Cost current = evaluate(m, s);
    for (int iter = 0; iter < 40; ++iter) {
        std::vector<double> jtj(static_cast<size_t>(P) * P, 0.0), grad(P, 0.0);
        // Accumulate centred residual and Jacobian: r_c = r - mean, J_c = J - mean(J).
        std::vector<double> J(static_cast<size_t>(bins) * m.K * P), r(static_cast<size_t>(bins) * m.K);
        std::vector<double> jMean(static_cast<size_t>(bins) * P, 0.0), rMean(bins, 0.0);
        size_t row = 0;
        for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
            Complex term[N60_CORRECT_MAX_BASS_CHANNELS];
            const uint32_t gi = g - m.fit0;
            for (uint32_t k = 0; k < m.K; ++k, ++row) {
                Complex e(0.0, 0.0);
                for (uint32_t n = 0; n < m.N; ++n) {
                    term[n] = channelFactor(s, n, m.freq[g]) * m.b(g, k, n);
                    e += term[n];
                }
                const double mag = std::max(std::abs(e), 1e-12);
                const Complex inv = std::conj(e) / (mag * mag);  // 1/e
                r[row] = std::log(mag);
                rMean[gi] += m.w[k] * r[row];
                for (uint32_t p = 0; p < P; ++p) {
                    const Complex t = term[idx[p]];
                    // d e / d delay[ms] = -j 2 pi f 1e-3 t;  d e / d gain[dB] = ln10/20 t.
                    const Complex de = isGain[p] ? t * (kLn10 / 20.0) : t * Complex(0.0, -2.0 * kPi * m.freq[g] * 1e-3);
                    const double v = (de * inv).real();
                    J[row * P + p] = v;
                    jMean[static_cast<size_t>(gi) * P + p] += m.w[k] * v;
                }
            }
        }
        row = 0;
        for (uint32_t g = 0; g < bins; ++g) {
            for (uint32_t k = 0; k < m.K; ++k, ++row) {
                const double wr = m.w[k] / bins;
                const double rc = r[row] - rMean[g];
                for (uint32_t a = 0; a < P; ++a) {
                    const double ja = J[row * P + a] - jMean[static_cast<size_t>(g) * P + a];
                    grad[a] += wr * rc * ja;
                    for (uint32_t b2 = a; b2 < P; ++b2) jtj[a * P + b2] += wr * ja * (J[row * P + b2] - jMean[static_cast<size_t>(g) * P + b2]);
                }
            }
        }
        for (uint32_t a = 0; a < P; ++a) for (uint32_t b2 = 0; b2 < a; ++b2) jtj[a * P + b2] = jtj[b2 * P + a];
        bool accepted = false;
        for (int attempt = 0; attempt < 12 && !accepted; ++attempt) {
            std::vector<double> a = jtj, rhs(P);
            for (uint32_t p = 0; p < P; ++p) {
                a[p * P + p] += mu * (jtj[p * P + p] + 1e-9);
                rhs[p] = -grad[p];
            }
            if (!solveReal(a, rhs, P)) { mu *= 10.0; continue; }
            Setting trial = s;
            double stepNorm = 0.0;
            for (uint32_t p = 0; p < P; ++p) {
                const uint32_t n = idx[p];
                if (isGain[p]) trial.gain_db[n] = clampd(s.gain_db[n] + rhs[p], ch[n].min_gain_db, ch[n].max_gain_db);
                else trial.delay[n] = clampd(s.delay[n] + rhs[p] * 1e-3, 0.0, maxDelay);
                stepNorm += rhs[p] * rhs[p];
            }
            const Cost c = evaluate(m, trial);
            if (c.value < current.value) {
                s = trial;
                const double gain = current.value - c.value;
                current = c;
                mu = std::max(mu * 0.3, 1e-9);
                accepted = true;
                if (gain < 1e-14 || stepNorm < 1e-14) return;
            } else {
                mu *= 5.0;
            }
        }
        if (!accepted) return;
    }
}

// Step (i): coordinate descent on a grid, then polish, from one start. Returns the final cost.
double optimiseFrom(const Model &m, const n60_correct_bass_channel *ch, double maxDelay, Setting &s) {
    const double delayStep = 0.00025;
    std::vector<Complex> rest;
    for (int sweep = 0; sweep < 3; ++sweep) {
        for (uint32_t n = 0; n < m.N; ++n) {
            if (!ch[n].free_delay && !ch[n].free_gain && !ch[n].free_polarity) continue;
            restOf(m, s, n, rest);
            double bestD = s.delay[n], bestG = s.gain_db[n];
            bool bestInv = s.invert[n];
            double best = evaluateCandidate(m, rest, n, bestD, bestG, bestInv);
            // Delay and polarity on the grid at the current gain.
            const int steps = ch[n].free_delay ? static_cast<int>(std::floor(maxDelay / delayStep + 1e-9)) : 0;
            for (int pol = 0; pol < (ch[n].free_polarity ? 2 : 1); ++pol) {
                const bool inv = ch[n].free_polarity ? pol == 1 : s.invert[n];
                for (int i = 0; i <= steps; ++i) {
                    const double d = ch[n].free_delay ? delayStep * i : s.delay[n];
                    const double v = evaluateCandidate(m, rest, n, d, bestG, inv);
                    if (v < best - 1e-15) { best = v; bestD = d; bestInv = inv; }
                }
            }
            s.delay[n] = bestD;
            s.invert[n] = bestInv;
            // Gain on a 1 dB grid.
            if (ch[n].free_gain) {
                for (double g = std::ceil(ch[n].min_gain_db); g <= ch[n].max_gain_db + 1e-9; g += 1.0) {
                    const double v = evaluateCandidate(m, rest, n, s.delay[n], g, s.invert[n]);
                    if (v < best - 1e-15) { best = v; bestG = g; }
                }
                s.gain_db[n] = bestG;
            }
        }
    }
    polish(m, ch, maxDelay, s);
    return evaluate(m, s).value;
}

// ---- step (ii) -----------------------------------------------------------------------------------

// Solves the complex Hermitian-positive system M x = b by Gaussian elimination (n <= 16).
bool solveComplex(std::vector<Complex> &a, std::vector<Complex> &b, uint32_t n) {
    for (uint32_t c = 0; c < n; ++c) {
        uint32_t piv = c;
        for (uint32_t r = c + 1; r < n; ++r) {
            if (std::abs(a[r * n + c]) > std::abs(a[piv * n + c])) piv = r;
        }
        if (std::abs(a[piv * n + c]) < 1e-300) return false;
        if (piv != c) {
            for (uint32_t j = 0; j < n; ++j) std::swap(a[c * n + j], a[piv * n + j]);
            std::swap(b[c], b[piv]);
        }
        for (uint32_t r = c + 1; r < n; ++r) {
            const Complex f = a[r * n + c] / a[c * n + c];
            for (uint32_t j = c; j < n; ++j) a[r * n + j] -= f * a[c * n + j];
            b[r] -= f * b[c];
        }
    }
    for (int64_t r = static_cast<int64_t>(n) - 1; r >= 0; --r) {
        Complex v = b[static_cast<size_t>(r)];
        for (uint32_t j = static_cast<uint32_t>(r) + 1; j < n; ++j) v -= a[static_cast<size_t>(r) * n + j] * b[j];
        b[static_cast<size_t>(r)] = v / a[static_cast<size_t>(r) * n + static_cast<size_t>(r)];
    }
    return true;
}

// Per-bin regularised least squares with the boost cap. `a[k*N+n]` is the channel term including
// delay, gain and polarity. Returns true if the cap was active.
bool solveBin(const Model &m, const std::vector<Complex> &a, const Complex *target, double reg, double cap, const double *weight, Complex *x) {
    const uint32_t N = m.N, K = m.K;
    std::vector<Complex> M(static_cast<size_t>(N) * N, Complex(0.0, 0.0));
    std::vector<Complex> rhs(N, Complex(0.0, 0.0));
    double power = 0.0;
    for (uint32_t n = 0; n < N; ++n) {
        for (uint32_t k = 0; k < K; ++k) {
            const Complex ck = std::conj(a[k * N + n]);
            rhs[n] += weight[k] * ck * target[k];
            for (uint32_t q = 0; q < N; ++q) M[n * N + q] += weight[k] * ck * a[k * N + q];
        }
        power += M[n * N + n].real();
    }
    const double lambda = reg * power / static_cast<double>(N) + 1e-30;
    for (uint32_t n = 0; n < N; ++n) {
        M[n * N + n] += lambda;
        rhs[n] += lambda;  // Tikhonov towards unity: a channel that cannot help keeps its response
    }

    bool fixedChannel[N60_CORRECT_MAX_BASS_CHANNELS] = {};
    bool limited = false;
    for (uint32_t pass = 0; pass <= N; ++pass) {
        uint32_t freeIdx[N60_CORRECT_MAX_BASS_CHANNELS];
        uint32_t F = 0;
        for (uint32_t n = 0; n < N; ++n) if (!fixedChannel[n]) freeIdx[F++] = n;
        if (F == 0) break;
        std::vector<Complex> sub(static_cast<size_t>(F) * F), b(F);
        for (uint32_t i = 0; i < F; ++i) {
            Complex v = rhs[freeIdx[i]];
            for (uint32_t q = 0; q < N; ++q) if (fixedChannel[q]) v -= M[freeIdx[i] * N + q] * x[q];
            b[i] = v;
            for (uint32_t j = 0; j < F; ++j) sub[i * F + j] = M[freeIdx[i] * N + freeIdx[j]];
        }
        if (!solveComplex(sub, b, F)) {
            for (uint32_t i = 0; i < F; ++i) x[freeIdx[i]] = Complex(1.0, 0.0);
            return limited;
        }
        bool violated = false;
        for (uint32_t i = 0; i < F; ++i) {
            x[freeIdx[i]] = b[i];
            if (std::abs(b[i]) > cap) violated = true;
        }
        if (!violated) break;
        // Clamp the violators to the cap (keeping their phase) and resolve the rest.
        for (uint32_t i = 0; i < F; ++i) {
            const double mag = std::abs(x[freeIdx[i]]);
            if (mag > cap) {
                x[freeIdx[i]] *= cap / mag;
                fixedChannel[freeIdx[i]] = true;
                limited = true;
            }
        }
    }
    return limited;
}

// Minimum phase of a grid magnitude (natural-log amplitude on the grid), sampled back on the grid.
bool gridMinimumPhase(const std::vector<double> &gridLog, double fs, std::vector<double> &phase) {
    uint64_t n = nextPow2(static_cast<uint64_t>(fs));
    if (n < 32768) n = 32768;
    const uint64_t half = n / 2;
    std::vector<double> logMagnitude(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(n);
        double x = f > 0.0 ? gridPosition(f) : 0.0;
        x = std::min(std::max(x, 0.0), static_cast<double>(kGrid - 1));
        const uint32_t lo = std::min<uint32_t>(static_cast<uint32_t>(std::floor(x)), kGrid - 2);
        const double fr = x - static_cast<double>(lo);
        logMagnitude[k] = gridLog[lo] + fr * (gridLog[lo + 1] - gridLog[lo]);
    }
    std::vector<double> bins;
    if (!minimumPhase(logMagnitude, n, bins)) return false;
    phase.resize(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double pos = gridFrequency(g) * static_cast<double>(n) / fs;
        const uint64_t lo = std::min<uint64_t>(static_cast<uint64_t>(std::floor(pos)), half - 1);
        const double fr = pos - static_cast<double>(lo);
        phase[g] = bins[lo] + fr * (bins[lo + 1] - bins[lo]);
    }
    return true;
}

// Weighted seat statistics over the fit band for a response table [g][k] of complex values.
struct Stats {
    double std_db = 0;
    double target_rms_db = 0;
    double level_db = 0;
};

Stats seatStats(const Model &m, const std::vector<Complex> &response /* [g][k], whole grid */) {
    Stats st;
    const uint32_t bins = m.fit1 - m.fit0 + 1;
    double offset = 0.0;
    for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
        for (uint32_t k = 0; k < m.K; ++k) {
            offset += m.w[k] * (std::log(std::max(std::abs(response[static_cast<size_t>(g) * m.K + k]), 1e-12)) - m.lnT[g]) / bins;
        }
    }
    double stdSum = 0.0, targetVar = 0.0;
    for (uint32_t g = m.fit0; g <= m.fit1; ++g) {
        double mean = 0.0;
        for (uint32_t k = 0; k < m.K; ++k) mean += m.w[k] * std::log(std::max(std::abs(response[static_cast<size_t>(g) * m.K + k]), 1e-12));
        double var = 0.0;
        for (uint32_t k = 0; k < m.K; ++k) {
            const double l = std::log(std::max(std::abs(response[static_cast<size_t>(g) * m.K + k]), 1e-12));
            var += m.w[k] * (l - mean) * (l - mean);
            const double d = l - m.lnT[g] - offset;
            targetVar += m.w[k] * d * d / bins;
        }
        stdSum += std::sqrt(var);
    }
    const double toDb = 20.0 / kLn10;
    st.std_db = stdSum / bins * toDb;
    st.target_rms_db = std::sqrt(targetVar) * toDb;
    st.level_db = offset * toDb;
    return st;
}

}  // namespace

extern "C" {

void n60_correct_bass_channel_defaults(uint32_t role, n60_correct_bass_channel *channel) {
    if (channel == nullptr) return;
    *channel = n60_correct_bass_channel{};
    channel->role = role;
    channel->free_delay = 1;
    if (role == N60_CORRECT_BASS_ROLE_SUB) {
        channel->free_gain = 1;
        channel->free_polarity = 1;
        channel->min_gain_db = -12.0;
        channel->max_gain_db = 6.0;
    }
}

void n60_correct_bass_defaults(const n60_correct_bass_channel *channels, n60_correct_bass_params *params) {
    if (params == nullptr) return;
    *params = n60_correct_bass_params{};
    params->struct_size = sizeof(n60_correct_bass_params);
    params->timing_tier = N60_CORRECT_TIMING_NONE;  // the caller sets the tier of the measurement
    params->channels = channels;
    params->crossover_hz = 80.0;
    params->fit_low_hz = 20.0;
    params->max_delay_seconds = 0.02;
    params->max_boost_db = 6.0;
    params->regularisation = 0.01;
}

int32_t n60_correct_bass_optimise(const n60_correct_problem *problem, const n60_correct_bass_params *params,
                                  n60_correct_design_grid *grids, n60_correct_bass_report *report, double *before_db,
                                  double *after_db) {
    if (params != nullptr && params->timing_tier == N60_CORRECT_TIMING_NONE) return N60_CORRECT_ERR_TIMING;
    if (params != nullptr && params->timing_tier != N60_CORRECT_TIMING_LOOPBACK && params->timing_tier != N60_CORRECT_TIMING_ACOUSTIC) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    Resolved rp;
    if (!resolveParams(problem, params, rp) || grids == nullptr || report == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    const uint32_t N = problem->channel_count, K = problem->seat_count;
    for (uint32_t n = 0; n < N; ++n) {
        if (grids[n].correction_db == nullptr || grids[n].correction_phase_rad == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    }
    const double fs = problem->sample_rate;

    Model m;
    m.N = N;
    m.K = K;
    m.fs = fs;
    m.freq.resize(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) m.freq[g] = gridFrequency(g);
    m.w.resize(K);
    double weightSum = 0.0;
    for (uint32_t k = 0; k < K; ++k) weightSum += problem->irs[k].weight;
    for (uint32_t k = 0; k < K; ++k) m.w[k] = problem->irs[k].weight / weightSum;
    m.lnT.assign(kGrid, 0.0);
    if (params->target_points > 0) {
        for (uint32_t g = 0; g < kGrid; ++g) {
            const double db = interpolateLogFrequency(params->target_frequencies_hz, params->target_gain_db, params->target_points, m.freq[g], 0.0);
            m.lnT[g] = db * kLn10 / 20.0;
        }
    }
    const auto gridIndexUp = [](double hz) {
        return static_cast<uint32_t>(std::max(0.0, std::ceil(gridPosition(hz) - 1e-9)));
    };
    const auto gridIndexDown = [](double hz) {
        return static_cast<uint32_t>(std::min<double>(kGrid - 1, std::max(0.0, std::floor(gridPosition(hz) + 1e-9))));
    };
    m.fit0 = gridIndexUp(rp.fit_low);
    m.fit1 = gridIndexDown(rp.fit_high);
    m.solve0 = m.fit0;
    m.solve1 = std::max(m.fit1, gridIndexDown(rp.fir_high * kThirdOctave));
    if (m.fit1 < m.fit0 + 8) return N60_CORRECT_ERR_ARGUMENT;

    // Measured responses on the grid, with the analytic crossover folded in.
    m.B.assign(static_cast<size_t>(kGrid) * K * N, Complex(0.0, 0.0));
    std::vector<Complex> spectrum;
    for (uint32_t n = 0; n < N; ++n) {
        const bool highPass = params->channels[n].role == N60_CORRECT_BASS_ROLE_MAIN;
        for (uint32_t k = 0; k < K; ++k) {
            if (!irOnGrid(problem->irs[static_cast<size_t>(n) * K + k], fs, rp.ir_seconds, spectrum)) return N60_CORRECT_ERR_ALLOC;
            for (uint32_t g = 0; g < kGrid; ++g) m.b(g, k, n) = crossoverResponse(highPass, m.freq[g], rp.crossover) * spectrum[g];
        }
    }
    for (const Complex &v : m.B) if (!finite(v.real()) || !finite(v.imag())) return N60_CORRECT_ERR_NONFINITE;

    // Step (i): fixed starts, best final cost wins (earlier start on ties).
    Setting start0;
    for (uint32_t n = 0; n < N; ++n) {
        start0.gain_db[n] = clampd(0.0, params->channels[n].min_gain_db, params->channels[n].max_gain_db);
        if (!params->channels[n].free_gain) start0.gain_db[n] = 0.0;
    }
    Setting start1 = start0;
    {
        double arrival[N60_CORRECT_MAX_BASS_CHANNELS];
        double latest = 0.0;
        for (uint32_t n = 0; n < N; ++n) {
            double a = 0.0;
            for (uint32_t k = 0; k < K; ++k) a += m.w[k] * problem->irs[static_cast<size_t>(n) * K + k].arrival_frames;
            arrival[n] = a / fs;
            latest = std::max(latest, arrival[n]);
        }
        for (uint32_t n = 0; n < N; ++n) {
            if (params->channels[n].free_delay) start1.delay[n] = clampd(latest - arrival[n], 0.0, rp.max_delay);
        }
    }
    const Setting unaligned = Setting{};  // no delay, 0 dB, normal polarity: the uncorrected system
    Setting best = start0;
    double bestCost = optimiseFrom(m, params->channels, rp.max_delay, best);
    {
        Setting candidate = start1;
        const double cost = optimiseFrom(m, params->channels, rp.max_delay, candidate);
        if (cost < bestCost - 1e-15) { best = candidate; bestCost = cost; }
    }
    // Deployed delay is a whole number of frames; the earliest channel is zero.
    double minDelay = best.delay[0];
    for (uint32_t n = 1; n < N; ++n) minDelay = std::min(minDelay, best.delay[n]);
    uint32_t delayFrames[N60_CORRECT_MAX_BASS_CHANNELS];
    for (uint32_t n = 0; n < N; ++n) {
        const double frames = std::llround((best.delay[n] - minDelay) * fs);
        delayFrames[n] = static_cast<uint32_t>(std::max(0.0, frames));
        best.delay[n] = static_cast<double>(delayFrames[n]) / fs;
    }

    // Response tables for statistics and prediction: [g][k].
    const auto table = [&](const Setting &s, const std::vector<std::vector<Complex>> *x) {
        std::vector<Complex> out(static_cast<size_t>(kGrid) * K);
        for (uint32_t g = 0; g < kGrid; ++g) {
            for (uint32_t k = 0; k < K; ++k) {
                Complex e(0.0, 0.0);
                for (uint32_t n = 0; n < N; ++n) {
                    Complex term = channelFactor(s, n, m.freq[g]) * m.b(g, k, n);
                    if (x != nullptr) term *= (*x)[n][g];
                    e += term;
                }
                out[static_cast<size_t>(g) * K + k] = e;
            }
        }
        return out;
    };
    const std::vector<Complex> beforeTable = table(unaligned, nullptr);
    const std::vector<Complex> alignedTable = table(best, nullptr);
    const Stats beforeStats = seatStats(m, beforeTable);
    const Stats alignedStats = seatStats(m, alignedTable);

    // Step (ii): per-bin target at the fitted level; each seat keeps its own phase so the solve spends its
    // freedom on the magnitudes (refined by reweighting).
    const double level = alignedStats.level_db * kLn10 / 20.0;
    std::vector<Complex> xs(static_cast<size_t>(kGrid) * N, Complex(1.0, 0.0));  // [g][n], solved filter
    std::vector<uint8_t> limitedBin(kGrid, 0);
    const double cap = std::pow(10.0, rp.max_boost / 20.0);
    for (uint32_t g = m.solve0; g <= m.solve1; ++g) {
        const double amp = std::exp(level + m.lnT[g]);
        Complex target[kMaxSeats];
        for (uint32_t k = 0; k < K; ++k) {
            const Complex e = alignedTable[static_cast<size_t>(g) * K + k];
            target[k] = std::abs(e) > 1e-12 ? (amp / std::abs(e)) * e : Complex(amp, 0.0);
        }
        std::vector<Complex> a(static_cast<size_t>(K) * N);
        for (uint32_t n = 0; n < N; ++n) {
            const Complex factor = channelFactor(best, n, m.freq[g]);
            for (uint32_t k = 0; k < K; ++k) a[k * N + n] = factor * m.b(g, k, n);
        }
        // Log-magnitude error of a candidate against the target level over the seats.
        const double lnAmp = std::log(amp);
        const auto logError = [&](const Complex *cand) {
            double err = 0.0;
            for (uint32_t k = 0; k < K; ++k) {
                Complex e(0.0, 0.0);
                for (uint32_t n = 0; n < N; ++n) e += a[k * N + n] * cand[n];
                const double d = std::log(std::max(std::abs(e), 1e-12)) - lnAmp;
                err += m.w[k] * d * d;
            }
            return err;
        };
        Complex x[N60_CORRECT_MAX_BASS_CHANNELS];
        for (uint32_t n = 0; n < N; ++n) x[n] = Complex(1.0, 0.0);
        double bestError = logError(x);
        bool bestLimited = false;
        // Candidates: regularisation ladder, each refined by reweighting the seats by 1/|E|^2 so the
        // least-squares error follows the log magnitude; a candidate is kept only if it beats the
        // current best (unity first), so the filter never worsens a bin.
        for (int rung = 0; rung < 4; ++rung) {
            Complex cand[N60_CORRECT_MAX_BASS_CHANNELS];
            for (uint32_t n = 0; n < N; ++n) cand[n] = Complex(1.0, 0.0);
            double weight[kMaxSeats];
            for (uint32_t k = 0; k < K; ++k) weight[k] = m.w[k];
            bool limited = false;
            Complex seatTarget[kMaxSeats];
            for (uint32_t k = 0; k < K; ++k) seatTarget[k] = target[k];
            for (int pass = 0; pass < 6; ++pass) {
                limited = solveBin(m, a, seatTarget, rp.reg * std::pow(4.0, rung), cap, weight, cand);
                for (uint32_t k = 0; k < K; ++k) {
                    Complex e(0.0, 0.0);
                    for (uint32_t n = 0; n < N; ++n) e += a[k * N + n] * cand[n];
                    const double mag = std::max(std::abs(e), 0.25 * amp);
                    weight[k] = m.w[k] * amp * amp / (mag * mag);
                    if (std::abs(e) > 1e-12) seatTarget[k] = (amp / std::abs(e)) * e;  // keep each seat's own phase
                }
            }
            const double err = logError(cand);
            if (err < bestError - 1e-12) {
                bestError = err;
                bestLimited = limited;
                for (uint32_t n = 0; n < N; ++n) x[n] = cand[n];
            }
        }
        if (bestLimited) limitedBin[g] = 1;
        for (uint32_t n = 0; n < N; ++n) xs[static_cast<size_t>(g) * N + n] = x[n];
    }

    // The per-bin solutions are independent; smooth each channel's log magnitude and unit phasor over
    // +-3 bins (a sixteenth of an octave, triangular) so the filter is realisable in a latency budget.
    {
        std::vector<Complex> smoothed(xs.size(), Complex(1.0, 0.0));
        for (uint32_t n = 0; n < N; ++n) {
            for (uint32_t g = m.solve0; g <= m.solve1; ++g) {
                double logSum = 0.0, weightSum2 = 0.0;
                Complex phasorSum(0.0, 0.0);
                for (int j = -3; j <= 3; ++j) {
                    const int64_t at = static_cast<int64_t>(g) + j;
                    if (at < m.solve0 || at > m.solve1) continue;
                    const double wt = 4.0 - std::abs(j);
                    const Complex v = xs[static_cast<size_t>(at) * N + n];
                    logSum += wt * std::log(std::max(std::abs(v), 1e-9));
                    phasorSum += wt * v / std::max(std::abs(v), 1e-9);
                    weightSum2 += wt;
                }
                const double ph = std::abs(phasorSum) > 1e-12 ? std::arg(phasorSum) : 0.0;
                smoothed[static_cast<size_t>(g) * N + n] = std::polar(std::exp(logSum / weightSum2), ph);
            }
        }
        xs = smoothed;
    }

    // Edge windows (third-octave raised cosine to unity), then the grid designs.
    const double windowLow = rp.fit_low / kThirdOctave, windowHigh = rp.fir_high * kThirdOctave;
    std::vector<std::vector<Complex>> filter(N, std::vector<Complex>(kGrid, Complex(1.0, 0.0)));
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double win = edgeWindow(m.freq[g], windowLow, windowHigh);
        if (win <= 0.0 || g < m.solve0 || g > m.solve1) continue;
        for (uint32_t n = 0; n < N; ++n) filter[n][g] = Complex(1.0, 0.0) + win * (xs[static_cast<size_t>(g) * N + n] - Complex(1.0, 0.0));
    }
    n60_correct_bass_report out{};
    out.channel_count = N;
    out.seat_count = K;
    double headroom = 0.0;
    for (uint32_t n = 0; n < N; ++n) {
        std::vector<double> logMag(kGrid), extra(kGrid), minPhase;
        for (uint32_t g = 0; g < kGrid; ++g) logMag[g] = std::log(std::max(std::abs(filter[n][g]), 1e-9));
        if (!gridMinimumPhase(logMag, fs, minPhase)) return N60_CORRECT_ERR_ALLOC;
        double previous = 0.0, offset = 0.0, peak = -1e9, peakGain = -1e9;
        for (uint32_t g = 0; g < kGrid; ++g) {
            double e = std::arg(filter[n][g]) - minPhase[g];
            if (g > 0) {
                while (e + offset - previous > kPi) offset -= 2.0 * kPi;
                while (e + offset - previous < -kPi) offset += 2.0 * kPi;
            }
            previous = e + offset;
            extra[g] = previous;
            const double db = logMag[g] * 20.0 / kLn10;
            grids[n].correction_db[g] = db;
            grids[n].correction_phase_rad[g] = extra[g];
            peak = std::max(peak, db);
            peakGain = std::max(peakGain, db + best.gain_db[n]);
        }
        n60_correct_bass_channel_result &res = out.channels[n];
        res.delay_frames = delayFrames[n];
        res.delay_seconds = best.delay[n];
        res.gain_db = best.gain_db[n];
        res.polarity_invert = best.invert[n] ? 1u : 0u;
        res.peak_boost_db = peak;
        res.peak_gain_db = peakGain;
        res.headroom_db = std::max(0.0, peakGain);
        headroom = std::max(headroom, res.headroom_db);
        if (grids[n].coherence != nullptr) for (uint32_t g = 0; g < kGrid; ++g) grids[n].coherence[g] = 0.0;
        if (grids[n].measured_db != nullptr) for (uint32_t g = 0; g < kGrid; ++g) grids[n].measured_db[g] = 0.0;
        if (grids[n].seat_spread_db != nullptr) for (uint32_t g = 0; g < kGrid; ++g) grids[n].seat_spread_db[g] = 0.0;
        if (grids[n].boost_limit_db != nullptr) for (uint32_t g = 0; g < kGrid; ++g) grids[n].boost_limit_db[g] = rp.max_boost;
    }

    const std::vector<Complex> afterTable = table(best, &filter);
    const Stats afterStats = seatStats(m, afterTable);
    out.seat_std_before_db = beforeStats.std_db;
    out.seat_std_aligned_db = alignedStats.std_db;
    out.seat_std_after_db = afterStats.std_db;
    out.target_rms_before_db = beforeStats.target_rms_db;
    out.target_rms_after_db = afterStats.target_rms_db;
    out.reference_level_db = alignedStats.level_db;
    out.headroom_db = headroom;
    for (uint32_t g = 0; g < kGrid; ++g) out.boost_limited_bins += limitedBin[g];
    if (before_db != nullptr || after_db != nullptr) {
        const double toDb = 20.0 / kLn10;
        for (uint32_t k = 0; k < K; ++k) {
            for (uint32_t g = 0; g < kGrid; ++g) {
                if (before_db != nullptr) before_db[static_cast<size_t>(k) * kGrid + g] = toDb * std::log(std::max(std::abs(beforeTable[static_cast<size_t>(g) * K + k]), 1e-12));
                if (after_db != nullptr) after_db[static_cast<size_t>(k) * kGrid + g] = toDb * std::log(std::max(std::abs(afterTable[static_cast<size_t>(g) * K + k]), 1e-12));
            }
        }
    }
    *report = out;
    return N60_CORRECT_OK;
}

}  // extern "C"
