// Minimum-phase synthesis and shared maths (E10 S1, design notes 1 and 4).
//
// The synthesis is the port of RoomCorrectionFIRDesigner.synthesize: log-magnitude, real
// cepstrum, fold to causal, exponentiate, inverse transform, truncate, half-Hann tail fade.
// The Swift designer runs it in single precision; this runs it in double so the two agree to
// well inside 0.01 dB and 0.5 degrees.
#include <algorithm>
#include <cmath>

#include "common.hpp"
#include "../measure/offline_fft.hpp"

namespace n60::correct {

using n60::fft::offline::Cplx;

double interpolateLogFrequency(const double *frequencies, const double *values, size_t count, double hz,
                               double outside) {
    if (count == 0 || !(hz > 0.0) || hz < frequencies[0] || hz > frequencies[count - 1]) return outside;
    if (hz == frequencies[0]) return values[0];
    if (hz == frequencies[count - 1]) return values[count - 1];
    size_t upper = 1;
    while (upper < count && frequencies[upper] < hz) ++upper;
    if (upper >= count) return outside;
    const size_t lower = upper - 1;
    const double denominator = std::log(frequencies[upper]) - std::log(frequencies[lower]);
    if (!(denominator > 0.0)) return values[lower];
    const double fraction = (std::log(hz) - std::log(frequencies[lower])) / denominator;
    return values[lower] + fraction * (values[upper] - values[lower]);
}

double interpolateGrid(const double *values, double hz, double outside) {
    if (!(hz > 0.0)) return outside;
    const double x = gridPosition(hz);
    if (x < 0.0 || x > static_cast<double>(N60_CORRECT_GRID_POINTS - 1)) return outside;
    const uint32_t lower = std::min<uint32_t>(static_cast<uint32_t>(std::floor(x)), N60_CORRECT_GRID_POINTS - 2);
    const double fraction = x - static_cast<double>(lower);
    return values[lower] + fraction * (values[lower + 1] - values[lower]);
}

bool minimumPhase(const std::vector<double> &log_magnitude, uint64_t n, std::vector<double> &phase) {
    const uint64_t half = n / 2;
    if (log_magnitude.size() != half + 1) return false;
    std::vector<Cplx> spectrum(half + 1);
    for (uint64_t k = 0; k <= half; ++k) spectrum[k] = Cplx{log_magnitude[k], 0.0};
    std::vector<double> cepstrum;
    if (!n60::fft::offline::realInverse(spectrum, n, cepstrum)) return false;
    // Fold to a causal cepstrum.
    for (uint64_t i = 1; i < half; ++i) cepstrum[i] *= 2.0;
    for (uint64_t i = half + 1; i < n; ++i) cepstrum[i] = 0.0;
    std::vector<Cplx> folded;
    if (!n60::fft::offline::realForward(cepstrum.data(), n, folded)) return false;
    phase.resize(half + 1);
    for (uint64_t k = 0; k <= half; ++k) phase[k] = folded[k].im;
    return true;
}

void smoothPower(std::vector<double> &power, int half_width) {
    if (half_width <= 0) return;
    const int n = static_cast<int>(power.size());
    std::vector<double> prefix(static_cast<size_t>(n) + 1, 0.0);
    for (int i = 0; i < n; ++i) prefix[static_cast<size_t>(i) + 1] = prefix[static_cast<size_t>(i)] + power[static_cast<size_t>(i)];
    for (int i = 0; i < n; ++i) {
        const int lo = std::max(0, i - half_width);
        const int hi = std::min(n - 1, i + half_width);
        power[static_cast<size_t>(i)] = (prefix[static_cast<size_t>(hi) + 1] - prefix[static_cast<size_t>(lo)]) /
                                         static_cast<double>(hi - lo + 1);
    }
}

double edgeWindow(double hz, double low_hz, double high_hz) {
    if (!(hz > low_hz) || !(hz < high_hz)) return 0.0;
    double w = 1.0;
    const double third = 1.0 / 3.0;
    const double lowX = std::log2(hz / low_hz) / third;
    if (lowX < 1.0) w *= 0.5 * (1.0 - std::cos(kPi * lowX));
    const double highX = std::log2(high_hz / hz) / third;
    if (highX < 1.0) w *= 0.5 * (1.0 - std::cos(kPi * highX));
    return w;
}

}  // namespace n60::correct

namespace {

using n60::correct::kPi;
using n60::fft::offline::Cplx;

constexpr double kDefaultTaper = 0.10;

bool validMinPhaseParams(const n60_correct_minphase_params *p) {
    if (p == nullptr) return false;
    if (!std::isfinite(p->sample_rate) || p->sample_rate < 8000.0 || p->sample_rate > 768000.0) return false;
    if (p->tap_count == 0 || p->tap_count > N60_CORRECT_MAX_TAPS) return false;
    if (!std::isfinite(p->low_hz) || !std::isfinite(p->high_hz) || !(p->low_hz >= 0.0) || !(p->high_hz > p->low_hz)) return false;
    if (!(p->high_hz < p->sample_rate * 0.5)) return false;
    if (!std::isfinite(p->tail_taper_fraction) || p->tail_taper_fraction < 0.0 || p->tail_taper_fraction > 0.5) return false;
    return true;
}

}  // namespace

extern "C" {

uint32_t n60_correct_abi_version(void) { return N60_CORRECT_ABI_VERSION; }

void n60_correct_minphase_defaults(double sample_rate, uint32_t tap_count, n60_correct_minphase_params *params) {
    if (params == nullptr) return;
    *params = n60_correct_minphase_params{};
    params->struct_size = sizeof(n60_correct_minphase_params);
    params->sample_rate = sample_rate;
    params->tap_count = tap_count;
    params->low_hz = 20.0;
    params->high_hz = 20000.0;
    params->tail_taper_fraction = kDefaultTaper;
}

uint32_t n60_correct_grid_size(void) { return N60_CORRECT_GRID_POINTS; }

int32_t n60_correct_grid_frequencies(double *frequencies_hz, uint32_t capacity) {
    if (frequencies_hz == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    if (capacity < N60_CORRECT_GRID_POINTS) return N60_CORRECT_ERR_CAPACITY;
    for (uint32_t i = 0; i < N60_CORRECT_GRID_POINTS; ++i) frequencies_hz[i] = n60::correct::gridFrequency(i);
    return N60_CORRECT_OK;
}

int32_t n60_correct_minphase_synthesize(const n60_correct_minphase_params *params,
                                        const double *frequencies_hz, const double *gain_db, uint32_t points,
                                        float *taps, uint64_t capacity) {
    if (!validMinPhaseParams(params) || taps == nullptr || (points > 0 && (frequencies_hz == nullptr || gain_db == nullptr))) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    for (uint32_t i = 0; i < points; ++i) {
        if (!std::isfinite(frequencies_hz[i]) || !std::isfinite(gain_db[i]) || !(frequencies_hz[i] > 0.0)) return N60_CORRECT_ERR_ARGUMENT;
        if (i > 0 && !(frequencies_hz[i] > frequencies_hz[i - 1])) return N60_CORRECT_ERR_ARGUMENT;
    }
    if (capacity < params->tap_count) return N60_CORRECT_ERR_CAPACITY;

    // Same transform size rule as the Swift designer: 8x the taps, at least 16384, relaxed to
    // 2x for the longest filters, never above 2^20.
    constexpr uint64_t kMaxTransform = 1ull << 20;
    const uint64_t tapCount = params->tap_count;
    const uint64_t required = std::max<uint64_t>(16384, std::min<uint64_t>(tapCount * 8, std::max<uint64_t>(tapCount * 2, kMaxTransform)));
    const uint64_t size = n60::correct::nextPow2(required);
    if (size > kMaxTransform) return N60_CORRECT_ERR_SIZE;
    const uint64_t half = size / 2;

    std::vector<double> logMagnitude(half + 1);
    for (uint64_t bin = 0; bin <= half; ++bin) {
        const double frequency = static_cast<double>(bin) * params->sample_rate / static_cast<double>(size);
        double gain = 0.0;
        if (frequency > params->low_hz && frequency < params->high_hz && frequency > 0.0) {
            gain = n60::correct::interpolateLogFrequency(frequencies_hz, gain_db, points, frequency, 0.0);
        }
        logMagnitude[bin] = n60::correct::dbToNeper(gain);
    }
    std::vector<double> phase;
    if (!n60::correct::minimumPhase(logMagnitude, size, phase)) return N60_CORRECT_ERR_ALLOC;
    std::vector<Cplx> spectrum(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double amplitude = std::exp(logMagnitude[k]);
        // The Nyquist and DC bins of a real signal are real.
        const double p = (k == 0 || k == half) ? 0.0 : phase[k];
        spectrum[k] = Cplx{amplitude * std::cos(p), amplitude * std::sin(p)};
    }
    std::vector<double> impulse;
    if (!n60::fft::offline::realInverse(spectrum, size, impulse)) return N60_CORRECT_ERR_ALLOC;

    std::vector<double> out(impulse.begin(), impulse.begin() + static_cast<std::ptrdiff_t>(tapCount));
    const int64_t taper = std::min<int64_t>(static_cast<int64_t>(tapCount) - 1,
                                            std::max<int64_t>(1, static_cast<int64_t>(static_cast<double>(tapCount) * params->tail_taper_fraction)));
    if (params->tail_taper_fraction > 0.0 && taper > 0) {
        const int64_t start = static_cast<int64_t>(tapCount) - taper;
        for (int64_t i = start; i < static_cast<int64_t>(tapCount); ++i) {
            const double position = static_cast<double>(i - start + 1) / static_cast<double>(taper);
            out[static_cast<size_t>(i)] *= 0.5 + 0.5 * std::cos(kPi * position);
        }
    }
    for (uint64_t i = 0; i < tapCount; ++i) {
        if (!std::isfinite(out[i])) return N60_CORRECT_ERR_NONFINITE;
        taps[i] = static_cast<float>(out[i]);
    }
    return N60_CORRECT_OK;
}

}  // extern "C"
