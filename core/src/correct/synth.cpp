// Rate-specific synthesis, declared latency and the pre-ringing audit (E10 S1, design note 4).
//
// A grid design is a magnitude (dB) and an extra phase on the 1/48-octave grid. Synthesis
// builds the minimum phase of the magnitude by real cepstrum, adds the extra phase, takes the
// impulse and places it L frames late. Content that falls before the start of the filter is
// tapered with a half-Hann ramp so it fits the budget. The declared latency is L, exactly.
#include <algorithm>
#include <cmath>

#include "common.hpp"
#include "../halfband.hpp"
#include "../measure/offline_fft.hpp"

namespace {

using namespace n60::correct;
using n60::fft::offline::Cplx;

constexpr uint64_t kMaxTransform = 1ull << 22;

bool validSynth(const n60_correct_synth_params *p) {
    if (p == nullptr) return false;
    if (p->mode != N60_CORRECT_MODE_MIN_PHASE && p->mode != N60_CORRECT_MODE_MIXED_PHASE) return false;
    if (!std::isfinite(p->sample_rate) || p->sample_rate < 8000.0 || p->sample_rate > 768000.0) return false;
    if (p->tap_count == 0 || p->tap_count > N60_CORRECT_MAX_TAPS) return false;
    if (!std::isfinite(p->latency_seconds) || p->latency_seconds < 0.0 || p->latency_seconds > 1.0) return false;
    if (!std::isfinite(p->tail_taper_fraction) || p->tail_taper_fraction < 0.0 || p->tail_taper_fraction > 0.5) return false;
    return true;
}

constexpr uint32_t kStageMaxTaps = 32768;
constexpr double kHandOverStart = 0.10;  // of fs / D
constexpr double kHandOverEnd = 0.18;

double handOver(double hz, double lowRate) {
    const double a = kHandOverStart * lowRate, b = kHandOverEnd * lowRate;
    if (hz <= a) return 1.0;
    if (hz >= b) return 0.0;
    return 0.5 * (1.0 + std::cos(kPi * (hz - a) / (b - a)));
}

// In-band response of the stage's decimate-then-interpolate cascade (real, positive: the alignment delay is the stage's
// latency): each half-band stage filters twice at its own input rate.
double resamplerResponse(double hz, double rate, uint32_t levels) {
    static const std::vector<float> odd = [] {
        std::vector<float> v(2 * n60::kHalfbandK);
        n60::halfbandOddTaps(v.data());
        return v;
    }();
    double r = 1.0;
    double stageRate = rate;
    for (uint32_t k = 0; k < levels; ++k) {
        const double w = 2.0 * kPi * hz / stageRate;
        double a = 0.5;
        for (uint32_t i = 0; i < odd.size(); ++i) {
            a += static_cast<double>(odd[i]) * std::cos(w * (static_cast<double>(2 * i + 1) - 2.0 * n60::kHalfbandK));
        }
        r *= a * a;
        stageRate *= 0.5;
    }
    return r;
}

uint32_t levelsOf(uint32_t d) {
    uint32_t l = 0;
    while ((1u << l) < d) ++l;
    return l;
}

}  // namespace

extern "C" {

void n60_correct_synth_defaults(uint32_t mode, double sample_rate, uint32_t tap_count, double latency_seconds,
                                n60_correct_synth_params *params) {
    if (params == nullptr) return;
    *params = n60_correct_synth_params{};
    params->struct_size = sizeof(n60_correct_synth_params);
    params->mode = mode;
    params->sample_rate = sample_rate;
    params->tap_count = tap_count;
    params->latency_seconds = latency_seconds;
    params->tail_taper_fraction = 0.10;
}

int32_t n60_correct_synthesize(const n60_correct_synth_params *params, const n60_correct_design_grid *grid,
                               float *taps, uint64_t capacity, n60_correct_synth_report *report) {
    if (!validSynth(params) || grid == nullptr || grid->correction_db == nullptr || grid->correction_phase_rad == nullptr ||
        taps == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (capacity < params->tap_count) return N60_CORRECT_ERR_CAPACITY;
    const double fs = params->sample_rate;
    const uint64_t tapCount = params->tap_count;
    const uint64_t latency = static_cast<uint64_t>(std::llround(params->latency_seconds * fs));
    if (latency + 64 >= tapCount) return N60_CORRECT_ERR_ARGUMENT;
    const bool mixed = params->mode == N60_CORRECT_MODE_MIXED_PHASE;

    const uint64_t size = nextPow2(std::max<uint64_t>(16384, tapCount * 8));
    if (size > kMaxTransform) return N60_CORRECT_ERR_SIZE;
    const uint64_t half = size / 2;
    std::vector<double> logMagnitude(half + 1), extra(half + 1, 0.0);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(size);
        logMagnitude[k] = dbToNeper(interpolateGrid(grid->correction_db, f, 0.0));
        if (mixed) extra[k] = interpolateGrid(grid->correction_phase_rad, f, 0.0);
    }
    std::vector<double> phase;
    if (!minimumPhase(logMagnitude, size, phase)) return N60_CORRECT_ERR_ALLOC;
    std::vector<Cplx> spectrum(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double amplitude = std::exp(logMagnitude[k]);
        const double p = (k == 0 || k == half) ? 0.0 : phase[k] + extra[k];
        spectrum[k] = Cplx{amplitude * std::cos(p), amplitude * std::sin(p)};
    }
    std::vector<double> impulse;
    if (!n60::fft::offline::realInverse(spectrum, size, impulse)) return N60_CORRECT_ERR_ALLOC;

    // Delay by L (circular shift), taper the part that precedes the start of the filter.
    std::vector<double> out(tapCount);
    for (uint64_t n = 0; n < tapCount; ++n) {
        const uint64_t index = (n + size - latency) % size;
        double v = impulse[index];
        if (n < latency) v *= 0.5 * (1.0 - std::cos(kPi * static_cast<double>(n) / static_cast<double>(latency)));
        out[n] = v;
    }
    const int64_t taper = std::min<int64_t>(static_cast<int64_t>(tapCount) - 1,
                                            std::max<int64_t>(1, static_cast<int64_t>(static_cast<double>(tapCount) * params->tail_taper_fraction)));
    if (params->tail_taper_fraction > 0.0) {
        const int64_t start = static_cast<int64_t>(tapCount) - taper;
        for (int64_t i = start; i < static_cast<int64_t>(tapCount); ++i) {
            const double position = static_cast<double>(i - start + 1) / static_cast<double>(taper);
            out[static_cast<size_t>(i)] *= 0.5 + 0.5 * std::cos(kPi * position);
        }
    }
    for (uint64_t n = 0; n < tapCount; ++n) {
        if (!std::isfinite(out[n])) return N60_CORRECT_ERR_NONFINITE;
        taps[n] = static_cast<float>(out[n]);
    }

    if (report != nullptr) {
        *report = n60_correct_synth_report{};
        report->declared_latency_frames = static_cast<uint32_t>(latency);
        if (latency > 0) {
            report->effective_latency_frames = report->declared_latency_frames;
        } else {
            uint64_t peakAt = 0;
            for (uint64_t n = 1; n < tapCount; ++n) {
                if (std::fabs(taps[n]) > std::fabs(taps[peakAt])) peakAt = n;
            }
            report->effective_latency_frames = static_cast<uint32_t>(peakAt);
        }
        std::vector<double> padded(size, 0.0);
        for (uint64_t n = 0; n < tapCount; ++n) padded[n] = static_cast<double>(taps[n]);
        std::vector<Cplx> response;
        if (!n60::fft::offline::realForward(padded.data(), size, response)) return N60_CORRECT_ERR_ALLOC;
        double peak = 0.0;
        for (const Cplx &c : response) peak = std::max(peak, std::hypot(c.re, c.im));
        report->peak_gain_db = peak > 1.0 ? 20.0 * std::log10(peak) : 0.0;
    }
    return N60_CORRECT_OK;
}

uint32_t n60_correct_two_band_decimation(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate < 16000.0) return 1;
    uint32_t d = 1;
    while (d < 32 && sample_rate / static_cast<double>(d) > 13000.0) d *= 2;
    return d;
}

int32_t n60_correct_synthesize_two_band(const n60_correct_synth_params *params, const n60_correct_design_grid *grid,
                                        float *fullTaps, uint64_t fullCapacity, float *lowTaps, uint64_t lowCapacity,
                                        n60_correct_two_band_report *report) {
    if (!validSynth(params) || grid == nullptr || grid->correction_db == nullptr || grid->correction_phase_rad == nullptr ||
        fullTaps == nullptr || lowTaps == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const double fs = params->sample_rate;
    const uint32_t D = n60_correct_two_band_decimation(fs);
    if (D < 2) return N60_CORRECT_ERR_ARGUMENT;
    const uint64_t span = params->tap_count;
    const uint64_t latency = static_cast<uint64_t>(std::llround(params->latency_seconds * fs));
    if (latency + 64 >= span) return N60_CORRECT_ERR_ARGUMENT;
    const bool mixed = params->mode == N60_CORRECT_MODE_MIXED_PHASE;
    const uint64_t ramp = mixed ? std::min<uint64_t>(latency, static_cast<uint64_t>(std::llround(0.25 * static_cast<double>(latency)))) : 0;
    const uint64_t extra = latency - ramp;
    if (extra > (1ull << 22)) return N60_CORRECT_ERR_SIZE;
    const uint64_t fullCount = std::min<uint64_t>(kStageMaxTaps, span - extra);
    const uint64_t lowCount = std::min<uint64_t>(kStageMaxTaps, (span + D - 1) / D);
    if (fullCapacity < fullCount || lowCapacity < lowCount) return N60_CORRECT_ERR_CAPACITY;
    const uint32_t levels = levelsOf(D);
    const double lowRate = fs / static_cast<double>(D);

    const uint64_t size = nextPow2(std::max<uint64_t>(16384, span * 8));
    if (size > kMaxTransform) return N60_CORRECT_ERR_SIZE;
    const uint64_t half = size / 2;
    std::vector<double> logMagnitude(half + 1), extraPhase(half + 1, 0.0);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(size);
        logMagnitude[k] = dbToNeper(interpolateGrid(grid->correction_db, f, 0.0));
        if (mixed) extraPhase[k] = interpolateGrid(grid->correction_phase_rad, f, 0.0);
    }
    std::vector<double> phase;
    if (!minimumPhase(logMagnitude, size, phase)) return N60_CORRECT_ERR_ALLOC;
    std::vector<Cplx> fullSpectrum(half + 1), lowSpectrum(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(size);
        const double amplitude = std::exp(logMagnitude[k]);
        const double p = (k == 0 || k == half) ? 0.0 : phase[k] + extraPhase[k];
        const Cplx t{amplitude * std::cos(p), amplitude * std::sin(p)};
        const double w = handOver(f, lowRate);
        fullSpectrum[k] = Cplx{t.re * (1.0 - w), t.im * (1.0 - w)};
        if (w > 0.0) {
            const double r = 1.0 / resamplerResponse(f, fs, levels);
            lowSpectrum[k] = Cplx{t.re * w * r, t.im * w * r};
        } else {
            lowSpectrum[k] = Cplx{0.0, 0.0};
        }
    }
    std::vector<double> fullImpulse, lowImpulse;
    if (!n60::fft::offline::realInverse(fullSpectrum, size, fullImpulse) ||
        !n60::fft::offline::realInverse(lowSpectrum, size, lowImpulse)) {
        return N60_CORRECT_ERR_ALLOC;
    }
    fullSpectrum.clear();
    lowSpectrum.clear();

    auto preTaper = [&](uint64_t absolute) {  // absolute full-rate time from the filter start
        return absolute < latency ? 0.5 * (1.0 - std::cos(kPi * static_cast<double>(absolute) / static_cast<double>(latency))) : 1.0;
    };
    auto tailTaper = [&](std::vector<double> &v) {
        const int64_t count = static_cast<int64_t>(v.size());
        if (params->tail_taper_fraction <= 0.0 || count < 2) return;
        const int64_t taper = std::min<int64_t>(count - 1, std::max<int64_t>(1, static_cast<int64_t>(static_cast<double>(count) * params->tail_taper_fraction)));
        const int64_t start = count - taper;
        for (int64_t i = start; i < count; ++i) {
            const double position = static_cast<double>(i - start + 1) / static_cast<double>(taper);
            v[static_cast<size_t>(i)] *= 0.5 + 0.5 * std::cos(kPi * position);
        }
    };
    std::vector<double> full(fullCount), low(lowCount);
    for (uint64_t n = 0; n < fullCount; ++n) {
        const uint64_t absolute = n + extra;
        double v = fullImpulse[(absolute + size - latency) % size] * preTaper(absolute);
        if (n < ramp) v *= 0.5 * (1.0 - std::cos(kPi * static_cast<double>(n) / static_cast<double>(ramp)));
        full[n] = v;
    }
    for (uint64_t m = 0; m < lowCount; ++m) {
        const uint64_t absolute = m * D;
        low[m] = static_cast<double>(D) * lowImpulse[(absolute + size - latency) % size] * preTaper(absolute);
    }
    tailTaper(full);
    tailTaper(low);
    for (uint64_t n = 0; n < fullCount; ++n) {
        if (!std::isfinite(full[n])) return N60_CORRECT_ERR_NONFINITE;
        fullTaps[n] = static_cast<float>(full[n]);
    }
    for (uint64_t m = 0; m < lowCount; ++m) {
        if (!std::isfinite(low[m])) return N60_CORRECT_ERR_NONFINITE;
        lowTaps[m] = static_cast<float>(low[m]);
    }
    if (report != nullptr) {
        *report = n60_correct_two_band_report{};
        report->decimation = D;
        report->extra_delay_frames = static_cast<uint32_t>(extra);
        report->full_tap_count = static_cast<uint32_t>(fullCount);
        report->low_tap_count = static_cast<uint32_t>(lowCount);
        report->declared_latency_frames = static_cast<uint32_t>(latency);
        std::vector<double> freqs(2048), mag(2048), ph(2048);
        for (size_t i = 0; i < freqs.size(); ++i) freqs[i] = 20.0 * std::pow(0.45 * fs / 20.0, static_cast<double>(i) / 2047.0);
        const int32_t status = n60_correct_two_band_response(fs, D, static_cast<uint32_t>(extra), static_cast<uint32_t>(latency), fullTaps,
                                                              static_cast<uint32_t>(fullCount), lowTaps, static_cast<uint32_t>(lowCount),
                                                              freqs.data(), 2048, mag.data(), ph.data());
        if (status != N60_CORRECT_OK) return status;
        double peak = 0.0;
        for (double m : mag) peak = std::max(peak, m);
        report->peak_gain_db = peak > 0.0 ? peak : 0.0;
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_synthesize_linear_phase(double fs, uint32_t groupDelay, n60_correct_amplitude_fn amplitude, void *user,
                                            float *fullTaps, uint64_t fullCapacity, float *lowTaps, uint64_t lowCapacity,
                                            n60_correct_two_band_report *report) {
    if (amplitude == nullptr || fullTaps == nullptr || !std::isfinite(fs) || fs < 8000.0 || fs > 768000.0 || groupDelay < 1 ||
        groupDelay > (1u << 18)) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const uint64_t latency = groupDelay;
    const uint64_t span = 2 * latency + 1;
    const bool two = span > kStageMaxTaps;
    const uint32_t D = two ? n60_correct_two_band_decimation(fs) : 1;
    if (two && (D < 2 || lowTaps == nullptr)) return N60_CORRECT_ERR_ARGUMENT;
    const uint64_t window = 2 * latency;
    auto blackman = [&](uint64_t a) {  // a in [0, 2L]; 1 at the centre
        if (a > window) return 0.0;
        const double x = 2.0 * kPi * static_cast<double>(a) / static_cast<double>(window);
        return 0.42 - 0.5 * std::cos(x) + 0.08 * std::cos(2.0 * x);
    };
    const uint64_t keep = two ? std::min<uint64_t>(latency, static_cast<uint64_t>(std::llround(0.01 * fs))) : latency;
    const uint64_t extra = latency - keep;
    const uint64_t fullCount = two ? std::min<uint64_t>(kStageMaxTaps, 2 * keep + 1) : span;
    const uint64_t lowCount = two ? std::min<uint64_t>(kStageMaxTaps, (span + D - 1) / D) : 0;
    if (fullCapacity < fullCount || lowCapacity < lowCount) return N60_CORRECT_ERR_CAPACITY;
    const uint64_t size = nextPow2(std::max<uint64_t>(16384, span * 4));
    if (size > kMaxTransform) return N60_CORRECT_ERR_SIZE;
    const uint64_t half = size / 2;
    const double lowRate = fs / static_cast<double>(D);
    const uint32_t levels = levelsOf(D);
    std::vector<Cplx> fullSpectrum(half + 1), lowSpectrum(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(size);
        const double a = amplitude(f, user);
        if (!std::isfinite(a) || a < 0.0) return N60_CORRECT_ERR_NONFINITE;
        const double w = two ? handOver(f, lowRate) : 0.0;
        fullSpectrum[k] = Cplx{a * (1.0 - w), 0.0};
        lowSpectrum[k] = Cplx{w > 0.0 ? a * w / resamplerResponse(f, fs, levels) : 0.0, 0.0};
    }
    std::vector<double> fullImpulse, lowImpulse;
    if (!n60::fft::offline::realInverse(fullSpectrum, size, fullImpulse)) return N60_CORRECT_ERR_ALLOC;
    if (two && !n60::fft::offline::realInverse(lowSpectrum, size, lowImpulse)) return N60_CORRECT_ERR_ALLOC;
    for (uint64_t n = 0; n < fullCount; ++n) {
        const uint64_t absolute = n + extra;
        const double v = fullImpulse[(absolute + size - latency) % size] * blackman(absolute);
        if (!std::isfinite(v)) return N60_CORRECT_ERR_NONFINITE;
        fullTaps[n] = static_cast<float>(v);
    }
    for (uint64_t m = 0; m < lowCount; ++m) {
        const uint64_t absolute = m * D;
        const double v = static_cast<double>(D) * lowImpulse[(absolute + size - latency) % size] * blackman(absolute);
        if (!std::isfinite(v)) return N60_CORRECT_ERR_NONFINITE;
        lowTaps[m] = static_cast<float>(v);
    }
    if (report != nullptr) {
        *report = n60_correct_two_band_report{};
        report->decimation = D;
        report->extra_delay_frames = static_cast<uint32_t>(extra);
        report->full_tap_count = static_cast<uint32_t>(fullCount);
        report->low_tap_count = static_cast<uint32_t>(lowCount);
        report->declared_latency_frames = groupDelay;
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_two_band_response(double fs, uint32_t D, uint32_t extra, uint32_t latency, const float *fullTaps,
                                      uint32_t fullCount, const float *lowTaps, uint32_t lowCount, const double *frequencies,
                                      uint32_t count, double *magnitudeDb, double *phaseRad) {
    if (!std::isfinite(fs) || fs < 8000.0 || D < 1 || D > 32 || (D & (D - 1)) != 0 || fullTaps == nullptr || fullCount == 0 ||
        (D > 1 && (lowTaps == nullptr || lowCount == 0)) || frequencies == nullptr || magnitudeDb == nullptr || phaseRad == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const uint32_t levels = levelsOf(D);
    const double lowRate = fs / static_cast<double>(D);
    for (uint32_t i = 0; i < count; ++i) {
        const double f = frequencies[i];
        if (!(f > 0.0) || f > 0.5 * fs) return N60_CORRECT_ERR_ARGUMENT;
        const double w = 2.0 * kPi * f / fs;
        // Direct sums with a rotating phasor would drift; recompute the angle per tap in blocks.
        double re = 0.0, im = 0.0;
        for (uint32_t n = 0; n < fullCount; ++n) {
            const double a = w * static_cast<double>(static_cast<uint64_t>(n) + extra);
            re += static_cast<double>(fullTaps[n]) * std::cos(a);
            im -= static_cast<double>(fullTaps[n]) * std::sin(a);
        }
        if (D > 1 && f < kHandOverEnd * lowRate * 1.05) {
            double lr = 0.0, li = 0.0;
            for (uint32_t m = 0; m < lowCount; ++m) {
                const double a = w * static_cast<double>(static_cast<uint64_t>(m) * D);
                lr += static_cast<double>(lowTaps[m]) * std::cos(a);
                li -= static_cast<double>(lowTaps[m]) * std::sin(a);
            }
            const double r = resamplerResponse(f, fs, levels);
            re += lr * r;
            im += li * r;
        }
        // Remove the declared latency.
        const double a = w * static_cast<double>(latency);
        const double c = std::cos(a), s = std::sin(a);
        const double rr = re * c - im * s, ri = re * s + im * c;
        magnitudeDb[i] = 20.0 * std::log10(std::max(std::hypot(rr, ri), 1e-12));
        phaseRad[i] = std::atan2(ri, rr);
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_audit_prering(const n60_correct_seat_ir *seat, double sample_rate, const float *taps,
                                  uint32_t tap_count, double low_hz, double high_hz,
                                  n60_correct_prering_report *report) {
    if (seat == nullptr || seat->ir == nullptr || seat->frames < 64 || taps == nullptr || tap_count == 0 || report == nullptr ||
        !std::isfinite(sample_rate) || sample_rate < 8000.0 || !(low_hz > 0.0) || !(high_hz > low_hz)) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    *report = n60_correct_prering_report{};
    report->limit_db = -30.0;
    report->first_failed_band = -1;

    const uint64_t length = seat->frames + tap_count;
    const uint64_t size = nextPow2(length + 16);
    if (size > n60::fft::offline::kMaxSize) return N60_CORRECT_ERR_SIZE;
    std::vector<double> a(size, 0.0), b(size, 0.0);
    for (uint64_t i = 0; i < seat->frames; ++i) a[i] = seat->ir[i];
    for (uint64_t i = 0; i < tap_count; ++i) b[i] = taps[i];
    std::vector<Cplx> sa, sb;
    if (!n60::fft::offline::realForward(a.data(), size, sa) || !n60::fft::offline::realForward(b.data(), size, sb)) {
        return N60_CORRECT_ERR_ALLOC;
    }
    std::vector<Cplx> product(sa.size());
    for (size_t k = 0; k < sa.size(); ++k) {
        product[k] = Cplx{sa[k].re * sb[k].re - sa[k].im * sb[k].im, sa[k].re * sb[k].im + sa[k].im * sb[k].re};
    }
    sa.clear(); sb.clear(); a.clear(); b.clear();

    const double binHz = sample_rate / static_cast<double>(size);
    const double ceiling = std::min({high_hz, 20000.0, 0.45 * sample_rate});
    const double allowedRatio = std::pow(10.0, report->limit_db / 20.0);
    std::vector<Cplx> band(product.size()), quadrature(product.size());
    std::vector<double> x, y;
    for (int k = -17; k <= 13; ++k) {
        const double centre = 1000.0 * std::exp2(static_cast<double>(k) / 3.0);
        if (centre < low_hz || centre > ceiling) continue;
        if (report->band_count >= N60_CORRECT_MAX_BANDS) break;
        // Gaussian band in linear frequency: third-octave wide (-3 dB at +-1/6 octave) and its
        // envelope is a Gaussian in time with sigma_t = 1 / (2 pi sigma_f), known analytically.
        const double sigmaF = 0.139 * centre;
        // The allowed spread is 1.25x the ideal impulse's: magnitude shaping inside a band (the
        // correction itself) widens a band's pulse a little, and that is not pre-ringing.
        const double sigmaT = 1.25 / (2.0 * kPi * sigmaF);
        const uint64_t lo = static_cast<uint64_t>(std::max(0.0, std::floor((centre - 7.0 * sigmaF) / binHz)));
        const uint64_t hi = std::min<uint64_t>(product.size() - 1, static_cast<uint64_t>(std::ceil((centre + 7.0 * sigmaF) / binHz)));
        std::fill(band.begin(), band.end(), Cplx{0.0, 0.0});
        std::fill(quadrature.begin(), quadrature.end(), Cplx{0.0, 0.0});
        for (uint64_t bin = std::max<uint64_t>(lo, 1); bin <= hi && bin + 1 < product.size(); ++bin) {
            const double d = (static_cast<double>(bin) * binHz - centre) / sigmaF;
            const double m = std::exp(-0.5 * d * d);
            band[bin] = Cplx{product[bin].re * m, product[bin].im * m};
            quadrature[bin] = Cplx{product[bin].im * m, -product[bin].re * m};  // multiply by -j
        }
        if (!n60::fft::offline::realInverse(band, size, x) || !n60::fft::offline::realInverse(quadrature, size, y)) {
            return N60_CORRECT_ERR_ALLOC;
        }
        std::vector<double> envelope(size);
        uint64_t peakIndex = 0;
        double peak = 0.0;
        for (uint64_t i = 0; i < size; ++i) {
            envelope[i] = std::hypot(x[i], y[i]);
            if (envelope[i] > peak) { peak = envelope[i]; peakIndex = i; }
        }
        n60_correct_prering_band &out = report->bands[report->band_count];
        out.centre_hz = centre;
        out.window_seconds = std::max(0.002, 2.0 / centre);
        out.level_db = -300.0;
        out.margin_db = -300.0;
        if (peak > 0.0) {
            const uint64_t bound = static_cast<uint64_t>(std::ceil(out.window_seconds * sample_rate));
            if (peakIndex > bound) {
                for (uint64_t i = 0; i + bound < peakIndex; ++i) {
                    const double e = envelope[i];
                    if (e < peak * 1e-9) continue;
                    const double dt = static_cast<double>(peakIndex - i) / sample_rate;
                    const double spread = std::exp(-0.5 * (dt / sigmaT) * (dt / sigmaT));
                    const double allowed = peak * (allowedRatio + spread);
                    out.level_db = std::max(out.level_db, 20.0 * std::log10(e / peak));
                    out.margin_db = std::max(out.margin_db, 20.0 * std::log10(e / allowed));
                }
            }
        }
        out.failed = out.margin_db > 0.0 ? 1u : 0u;
        if (out.failed) {
            ++report->failed_count;
            if (report->first_failed_band < 0) report->first_failed_band = static_cast<int32_t>(report->band_count);
        }
        ++report->band_count;
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_design_channel_taps(const n60_correct_problem *problem, uint32_t channel,
                                        const n60_correct_design_params *design,
                                        const n60_correct_synth_params *synth, float *taps, uint64_t capacity,
                                        n60_correct_channel_report *report) {
    if (problem == nullptr || design == nullptr || synth == nullptr || taps == nullptr || report == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    if (synth->sample_rate != problem->sample_rate || synth->mode != design->mode) return N60_CORRECT_ERR_ARGUMENT;
    *report = n60_correct_channel_report{};
    report->prering.first_failed_band = -1;
    std::vector<double> db(N60_CORRECT_GRID_POINTS), phase(N60_CORRECT_GRID_POINTS);
    n60_correct_design_grid grid{};
    grid.correction_db = db.data();
    grid.correction_phase_rad = phase.data();
    int32_t status = n60_correct_design_channel(problem, channel, design, &grid);
    if (status != N60_CORRECT_OK) return status;
    status = n60_correct_synthesize(synth, &grid, taps, capacity, &report->synth);
    if (status != N60_CORRECT_OK) return status;
    if (design->mode == N60_CORRECT_MODE_MIN_PHASE) return N60_CORRECT_OK;
    const n60_correct_seat_ir &main = problem->irs[static_cast<size_t>(channel) * problem->seat_count + problem->main_seat];
    status = n60_correct_audit_prering(&main, problem->sample_rate, taps, synth->tap_count, design->correction_low_hz,
                                       design->correction_high_hz, &report->prering);
    if (status != N60_CORRECT_OK) return status;
    return report->prering.failed_count > 0 ? N60_CORRECT_ERR_PRERINGING : N60_CORRECT_OK;
}

}  // extern "C"
