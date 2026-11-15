// Room-measurement analysis maths moved out of Swift (E21 S5): direct-arrival search, the
// analysis window, the log-grid transfer response with phase, and the stereo band spectrum of
// the program analyser. Offline / worker thread only: allocates, deterministic, double
// precision, no Apple framework. Window shape and search rules are the ones the Swift analyser
// shipped (REW-style room window: 10 ms left, 500 ms right with a half-Hann taper).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;

bool validRate(double fs) { return std::isfinite(fs) && fs >= 8000 && fs <= 768000; }

}  // namespace

extern "C" {

int32_t n60_measure_direct_arrival(const float *impulse, uint64_t count, double sample_rate,
                                   uint64_t tail_frames, uint64_t *arrival_out) {
    if (impulse == nullptr || arrival_out == nullptr || !validRate(sample_rate) || count < 2) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const uint64_t minimumSearch = static_cast<uint64_t>(std::llround(sample_rate * 0.25));
    const uint64_t searchCount = std::min<uint64_t>(count / 2, std::max<uint64_t>({tail_frames, minimumSearch, 1}));
    if (searchCount == 0) return N60_MEASURE_ERR_NO_ARRIVAL;

    float peak = 0;
    uint64_t globalPeak = 0;
    for (uint64_t i = 0; i < searchCount; ++i) {
        const float m = std::fabs(impulse[i]);
        if (m > peak) { peak = m; globalPeak = i; }
    }
    if (!std::isfinite(peak) || !(peak > 1.0e-8f)) return N60_MEASURE_ERR_NO_ARRIVAL;

    // Earliest credible onset, then the largest sample within 3 ms of it (rejects a lone
    // threshold-crossing sample while keeping the direct wavefront).
    const float threshold = peak * 0.10f;
    uint64_t onset = globalPeak;
    for (uint64_t i = 0; i < searchCount; ++i) {
        if (std::fabs(impulse[i]) >= threshold) { onset = i; break; }
    }
    const uint64_t span = std::max<uint64_t>(1, static_cast<uint64_t>(std::llround(sample_rate * 0.003)));
    const uint64_t localEnd = std::min<uint64_t>(searchCount, onset + span);
    uint64_t arrival = onset;
    float best = std::fabs(impulse[onset]);
    for (uint64_t i = onset + 1; i < localEnd; ++i) {
        const float m = std::fabs(impulse[i]);
        if (m > best) { best = m; arrival = i; }
    }
    *arrival_out = arrival;
    return N60_MEASURE_OK;
}

int32_t n60_measure_window_impulse(const float *impulse, uint64_t count, uint64_t arrival_frame,
                                   double sample_rate, float *out, uint64_t capacity) {
    if (impulse == nullptr || out == nullptr || count < 2 || !validRate(sample_rate)) return N60_MEASURE_ERR_ARGUMENT;
    if (capacity < count) return N60_MEASURE_ERR_CAPACITY;
    const int64_t n = static_cast<int64_t>(count);
    const int64_t left = std::max<int64_t>(1, std::min<int64_t>(std::llround(0.010 * sample_rate), n / 4));
    const int64_t right = std::max<int64_t>(2, std::min<int64_t>(std::llround(0.500 * sample_rate), n / 2));
    const int64_t taper = std::max<int64_t>(1, std::llround(static_cast<double>(right) * 0.25));
    const int64_t flatEnd = right - taper;
    std::fill(out, out + count, 0.0f);
    for (int64_t offset = -left; offset < right; ++offset) {
        double weight;
        if (offset < 0) {
            weight = 0.5 - 0.5 * std::cos(kPi * static_cast<double>(offset + left) / static_cast<double>(left));
        } else if (offset < flatEnd) {
            weight = 1.0;
        } else {
            weight = 0.5 + 0.5 * std::cos(kPi * static_cast<double>(offset - flatEnd) / static_cast<double>(taper));
        }
        const int64_t index = (((static_cast<int64_t>(arrival_frame) + offset) % n) + n) % n;
        out[index] = impulse[index] * static_cast<float>(weight);
    }
    return N60_MEASURE_OK;
}

int32_t n60_measure_response_grid(const n60_measure_response_params *p, const float *windowed,
                                  uint64_t transform_size, double *frequency_hz, double *magnitude_db,
                                  double *phase_rad) {
    if (p == nullptr || windowed == nullptr || frequency_hz == nullptr || magnitude_db == nullptr ||
        phase_rad == nullptr || !validRate(p->sample_rate) || p->point_count < 2 || p->point_count > 65536) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    if (!n60::fft::offline::validSize(transform_size) || transform_size < 4) return N60_MEASURE_ERR_SIZE;
    const double fs = p->sample_rate;
    const double minHz = std::max(p->start_hz, fs / static_cast<double>(transform_size));
    const double maxHz = std::min(p->end_hz, fs * 0.5 * 0.98);
    if (!std::isfinite(minHz) || !std::isfinite(maxHz) || !(minHz > 0) || !(maxHz > minHz)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    std::vector<double> x(transform_size);
    for (uint64_t i = 0; i < transform_size; ++i) x[i] = windowed[i];
    std::vector<Cplx> spec;
    if (!n60::fft::offline::realForward(x.data(), transform_size, spec)) return N60_MEASURE_ERR_ALLOC;

    const uint32_t points = p->point_count;
    const double ratio = maxHz / minHz;
    const double halfStep = std::sqrt(std::pow(ratio, 1.0 / static_cast<double>(points - 1)));
    const double binsPerHz = static_cast<double>(transform_size) / fs;
    const int64_t nyquistBin = static_cast<int64_t>(transform_size / 2);
    const double twoPi = 2.0 * kPi;

    for (uint32_t point = 0; point < points; ++point) {
        const double frequency = minHz * std::pow(ratio, static_cast<double>(point) / static_cast<double>(points - 1));
        const int64_t bin = std::min<int64_t>(nyquistBin, std::max<int64_t>(1, std::llround(frequency * binsPerHz)));
        const int64_t lower = std::max<int64_t>(1, static_cast<int64_t>(std::ceil(frequency / halfStep * binsPerHz)));
        const int64_t upper = std::min<int64_t>(nyquistBin, static_cast<int64_t>(std::floor(frequency * halfStep * binsPerHz)));
        double magnitude;
        if (upper > lower) {
            double power = 0;
            for (int64_t k = lower; k <= upper; ++k) power += spec[k].re * spec[k].re + spec[k].im * spec[k].im;
            magnitude = std::sqrt(power / static_cast<double>(upper - lower + 1));
        } else {
            magnitude = std::hypot(spec[bin].re, spec[bin].im);
        }
        if (!std::isfinite(magnitude)) magnitude = 0;
        const double delay = twoPi * static_cast<double>(bin) * static_cast<double>(p->arrival_frames) /
                             static_cast<double>(transform_size);
        double phase = std::atan2(spec[bin].im, spec[bin].re) + delay;
        while (phase > kPi) phase -= twoPi;
        while (phase < -kPi) phase += twoPi;
        frequency_hz[point] = frequency;
        magnitude_db[point] = 20.0 * std::log10(std::max(magnitude, 1.0e-12));
        phase_rad[point] = phase;
    }
    for (uint32_t i = 1; i < points; ++i) {
        double current = phase_rad[i];
        const double previous = phase_rad[i - 1];
        while (current - previous > kPi) current -= twoPi;
        while (current - previous < -kPi) current += twoPi;
        phase_rad[i] = current;
    }
    return N60_MEASURE_OK;
}

int32_t n60_measure_stereo_band_amplitude(const n60_measure_stereo_bands_params *p, const float *left,
                                          const float *right, double *frequency_hz, double *amplitude) {
    if (p == nullptr || left == nullptr || right == nullptr || frequency_hz == nullptr || amplitude == nullptr ||
        !validRate(p->sample_rate) || p->band_count < 1 || p->band_count > 4096 || !(p->min_hz > 0) ||
        !(p->max_hz > p->min_hz)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const uint64_t n = p->fft_size;
    if (!n60::fft::offline::validSize(n) || n < 8) return N60_MEASURE_ERR_SIZE;
    const double fs = p->sample_rate;

    // Symmetric Hann (denominator n - 1), as the analyser has always used.
    std::vector<double> window(n);
    double windowSum = 0;
    for (uint64_t i = 0; i < n; ++i) {
        window[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(n - 1));
        windowSum += window[i];
    }
    std::vector<double> x(n);
    std::vector<Cplx> specL, specR;
    for (uint64_t i = 0; i < n; ++i) x[i] = static_cast<double>(left[i]) * window[i];
    if (!n60::fft::offline::realForward(x.data(), n, specL)) return N60_MEASURE_ERR_ALLOC;
    for (uint64_t i = 0; i < n; ++i) x[i] = static_cast<double>(right[i]) * window[i];
    if (!n60::fft::offline::realForward(x.data(), n, specR)) return N60_MEASURE_ERR_ALLOC;

    const double scale = 2.0 / std::max(windowSum, 4.9406564584124654e-324);
    const double ratio = p->max_hz / p->min_hz;
    const int64_t half = static_cast<int64_t>(n / 2);
    const double binsPerHz = static_cast<double>(n) / fs;
    for (uint32_t band = 0; band < p->band_count; ++band) {
        const double lowerHz = p->min_hz * std::pow(ratio, static_cast<double>(band) / p->band_count);
        const double upperHz = p->min_hz * std::pow(ratio, static_cast<double>(band + 1) / p->band_count);
        const double centre = std::sqrt(lowerHz * upperHz);
        frequency_hz[band] = centre;
        int64_t first = std::max<int64_t>(1, static_cast<int64_t>(std::floor(lowerHz * binsPerHz)));
        int64_t last = std::min<int64_t>(half, static_cast<int64_t>(std::ceil(upperHz * binsPerHz)));
        if (last < first) {
            first = last = std::min<int64_t>(half, std::max<int64_t>(1, std::llround(centre * binsPerHz)));
        }
        double peak = 0;
        for (int64_t k = first; k <= last; ++k) {
            const double l2 = specL[k].re * specL[k].re + specL[k].im * specL[k].im;
            const double r2 = specR[k].re * specR[k].re + specR[k].im * specR[k].im;
            peak = std::max(peak, std::sqrt(0.5 * (l2 + r2)));
        }
        amplitude[band] = peak * scale;
    }
    return N60_MEASURE_OK;
}

}  // extern "C"
