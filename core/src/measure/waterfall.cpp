// Cumulative spectral decay (waterfall) and spectrogram of an impulse response (E11 S4,
// design note 9). Offline only: allocates, deterministic, double precision.
//
// Waterfall: every slice shares one fixed window end; slice i starts i steps after the direct
// arrival, with a short half-Hann rise ending at its start and a half-Hann fall over the last
// quarter of the fixed window. Power is smoothed in fractions of an octave on a log grid.
// Spectrogram: Hann STFT with 75 % overlap. Ref: Harris (1978) windows; the CSD of
// Berman and Fincham (1977).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "band_mean.hpp"
#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;
using n60::measure::BandMean;
constexpr double kPi = 3.14159265358979323846264338327950288;

bool validWaterfall(const n60_measure_waterfall_params *p) {
    return p != nullptr && std::isfinite(p->sample_rate) && p->sample_rate >= 8000 && p->sample_rate <= 768000 &&
           std::isfinite(p->step_seconds) && p->step_seconds > 0 && p->slice_count >= 1 && p->slice_count <= 256 &&
           std::isfinite(p->window_seconds) && p->window_seconds > p->step_seconds &&
           std::isfinite(p->rise_seconds) && p->rise_seconds >= 0 && p->rise_seconds <= 0.01 &&
           std::isfinite(p->smoothing_octaves) && p->smoothing_octaves >= 0 && p->smoothing_octaves <= 2 &&
           p->points_per_octave >= 1 && p->points_per_octave <= 96 && std::isfinite(p->min_hz) && p->min_hz > 0 &&
           std::isfinite(p->max_hz) && p->max_hz > p->min_hz * 1.5 && p->max_hz < p->sample_rate * 0.5;
}

uint32_t gridPoints(const n60_measure_waterfall_params *p) {
    return static_cast<uint32_t>(std::floor(std::log2(p->max_hz / p->min_hz) * p->points_per_octave + 1e-9)) + 1;
}

bool validSpectrogram(const n60_measure_spectrogram_params *p) {
    return p != nullptr && std::isfinite(p->sample_rate) && p->sample_rate >= 8000 && p->sample_rate <= 768000 &&
           std::isfinite(p->window_seconds) && p->window_seconds >= 16.0 / p->sample_rate && p->window_seconds <= 2.0 &&
           std::isfinite(p->max_hz) && p->max_hz >= 0 && p->max_hz < p->sample_rate * 0.5;
}

uint64_t nextPow2(uint64_t v) {
    uint64_t m = 2;
    while (m < v) m <<= 1;
    return m;
}

}  // namespace

extern "C" {

void n60_measure_waterfall_defaults(double sample_rate, uint32_t room, n60_measure_waterfall_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_waterfall_params{};
    p->sample_rate = sample_rate;
    p->arrival_index = UINT64_MAX;
    p->step_seconds = room ? 0.02 : 0.0003;
    p->slice_count = room ? 30 : 40;
    p->window_seconds = p->step_seconds * p->slice_count * (room ? 2.0 : 3.0);
    p->rise_seconds = 0.0001;
    p->smoothing_octaves = 1.0 / 24.0;
    p->points_per_octave = 24;
    p->min_hz = 20.0;
    p->max_hz = std::min(20000.0, 0.45 * sample_rate);
}

int32_t n60_measure_waterfall_describe(const n60_measure_waterfall_params *p, n60_measure_waterfall_info *info) {
    if (!validWaterfall(p) || info == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *info = n60_measure_waterfall_info{};
    info->point_count = gridPoints(p);
    info->slice_count = p->slice_count;
    return N60_MEASURE_OK;
}

int32_t n60_measure_waterfall_analyze(const n60_measure_waterfall_params *p, const float *ir, uint64_t count,
                                      double *frequency_hz, double *out_db, uint64_t out_capacity,
                                      n60_measure_waterfall_info *info) {
    if (!validWaterfall(p) || ir == nullptr || frequency_hz == nullptr || out_db == nullptr || info == nullptr ||
        count < 64) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const double fs = p->sample_rate;
    *info = n60_measure_waterfall_info{};
    info->point_count = gridPoints(p);
    info->slice_count = p->slice_count;
    const uint64_t cells = static_cast<uint64_t>(info->point_count) * p->slice_count;
    if (out_capacity < cells) return N60_MEASURE_ERR_CAPACITY;

    uint64_t arrival = p->arrival_index;
    if (arrival == UINT64_MAX) {
        double best = -1.0;
        for (uint64_t i = 0; i < count; ++i) {
            const double a = std::fabs(static_cast<double>(ir[i]));
            if (a > best) { best = a; arrival = i; }
        }
    }
    if (arrival >= count) return N60_MEASURE_ERR_ARGUMENT;
    const uint64_t end = std::min<uint64_t>(count, arrival + static_cast<uint64_t>(std::llround(p->window_seconds * fs)));
    if (end <= arrival + 16) return N60_MEASURE_ERR_SIZE;
    info->arrival_index = arrival;
    info->end_index = end;

    const uint64_t span = end - arrival;
    const uint64_t riseFrames = static_cast<uint64_t>(std::llround(p->rise_seconds * fs));
    const uint64_t fallFrames = std::max<uint64_t>(1, span / 4);
    const uint64_t m = nextPow2(std::max<uint64_t>(2 * (span + riseFrames), static_cast<uint64_t>(fs / 8.0)));
    if (m > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
    const double binHz = fs / static_cast<double>(m);
    const double half = std::pow(2.0, p->smoothing_octaves / 2.0);

    for (uint32_t k = 0; k < info->point_count; ++k) {
        frequency_hz[k] = p->min_hz * std::pow(2.0, static_cast<double>(k) / p->points_per_octave);
    }

    double peak = 0.0;
    std::vector<double> buffer(m);
    std::vector<double> power;
    std::vector<Cplx> spectrum;
    for (uint32_t s = 0; s < p->slice_count; ++s) {
        double *row = out_db + static_cast<uint64_t>(s) * info->point_count;
        const uint64_t start = arrival + static_cast<uint64_t>(std::llround(static_cast<double>(s) * p->step_seconds * fs));
        if (start + 16 > end) {
            for (uint32_t k = 0; k < info->point_count; ++k) row[k] = N60_MEASURE_NO_DATA_DB;
            continue;
        }
        const uint64_t first = start >= riseFrames ? start - riseFrames : 0;
        const uint64_t rise = start - first;
        const uint64_t fall = std::min<uint64_t>(fallFrames, (end - start) / 2);
        std::fill(buffer.begin(), buffer.end(), 0.0);
        for (uint64_t i = first; i < end; ++i) {
            double w = 1.0;
            if (i < start) {
                w = 0.5 * (1.0 - std::cos(kPi * (static_cast<double>(i - first) + 0.5) / static_cast<double>(rise)));
            } else if (i + fall >= end) {
                w = 0.5 * (1.0 + std::cos(kPi * (static_cast<double>(i + fall - end) + 0.5) / static_cast<double>(fall)));
            }
            buffer[i - first] = w * static_cast<double>(ir[i]);
        }
        if (!n60::fft::offline::realForward(buffer.data(), m, spectrum)) return N60_MEASURE_ERR_ALLOC;
        power.resize(spectrum.size());
        for (size_t b = 0; b < spectrum.size(); ++b) power[b] = spectrum[b].re * spectrum[b].re + spectrum[b].im * spectrum[b].im;
        const BandMean band(power, binHz);
        for (uint32_t k = 0; k < info->point_count; ++k) {
            const double f = frequency_hz[k];
            const double level = band.mean(f / half, f * half, f);
            row[k] = 10.0 * std::log10(std::max(level, 1e-300));
            peak = std::max(peak, row[k]);
        }
    }
    for (uint64_t c = 0; c < cells; ++c) {
        if (out_db[c] == N60_MEASURE_NO_DATA_DB) continue;
        out_db[c] = std::max(-200.0, out_db[c] - peak);
    }
    return N60_MEASURE_OK;
}

void n60_measure_spectrogram_defaults(double sample_rate, n60_measure_spectrogram_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_spectrogram_params{};
    p->sample_rate = sample_rate;
    p->window_seconds = 0.01;
    p->max_hz = 0.0;
}

int32_t n60_measure_spectrogram_describe(const n60_measure_spectrogram_params *p, uint64_t count,
                                         n60_measure_spectrogram_info *info) {
    if (!validSpectrogram(p) || info == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    const double fs = p->sample_rate;
    const uint64_t begin = p->begin_index;
    const uint64_t end = p->end_index == 0 ? count : std::min(p->end_index, count);
    if (begin >= end) return N60_MEASURE_ERR_ARGUMENT;
    uint64_t window = static_cast<uint64_t>(std::llround(p->window_seconds * fs));
    window = std::max<uint64_t>(16, window & ~uint64_t{3});
    const uint64_t fft = nextPow2(window);
    if (fft > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
    const uint64_t hop = window / 4;
    const uint64_t length = end - begin;
    const uint64_t frames = length <= window ? 1 : (length - window) / hop + 1;
    const double maxHz = p->max_hz > 0 ? p->max_hz : std::min(20000.0, 0.45 * fs);
    *info = n60_measure_spectrogram_info{};
    info->window_frames = static_cast<uint32_t>(window);
    info->hop_frames = static_cast<uint32_t>(hop);
    info->fft_size = static_cast<uint32_t>(fft);
    info->hz_per_bin = fs / static_cast<double>(fft);
    info->bin_count = static_cast<uint32_t>(std::min<uint64_t>(fft / 2 + 1, static_cast<uint64_t>(maxHz / info->hz_per_bin) + 1));
    info->frame_count = static_cast<uint32_t>(std::min<uint64_t>(frames, 0xFFFFFFFFu));
    info->begin_index = begin;
    return N60_MEASURE_OK;
}

int32_t n60_measure_spectrogram_analyze(const n60_measure_spectrogram_params *p, const float *ir, uint64_t count,
                                        double *out_db, uint64_t out_capacity, n60_measure_spectrogram_info *info) {
    if (ir == nullptr || out_db == nullptr || info == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    const int32_t status = n60_measure_spectrogram_describe(p, count, info);
    if (status != N60_MEASURE_OK) return status;
    const uint64_t cells = static_cast<uint64_t>(info->frame_count) * info->bin_count;
    if (out_capacity < cells) return N60_MEASURE_ERR_CAPACITY;
    const uint64_t end = p->end_index == 0 ? count : std::min(p->end_index, count);
    const uint64_t window = info->window_frames;
    std::vector<double> hann(window);
    for (uint64_t i = 0; i < window; ++i) hann[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(window));
    std::vector<double> buffer(info->fft_size);
    std::vector<Cplx> spectrum;
    double peak = 0.0;
    for (uint32_t j = 0; j < info->frame_count; ++j) {
        const uint64_t start = info->begin_index + static_cast<uint64_t>(j) * info->hop_frames;
        std::fill(buffer.begin(), buffer.end(), 0.0);
        for (uint64_t i = 0; i < window && start + i < end; ++i) buffer[i] = hann[i] * static_cast<double>(ir[start + i]);
        if (!n60::fft::offline::realForward(buffer.data(), info->fft_size, spectrum)) return N60_MEASURE_ERR_ALLOC;
        double *row = out_db + static_cast<uint64_t>(j) * info->bin_count;
        for (uint32_t b = 0; b < info->bin_count; ++b) {
            row[b] = 20.0 * std::log10(std::max(std::hypot(spectrum[b].re, spectrum[b].im), 1e-300));
            peak = std::max(peak, row[b]);
        }
    }
    for (uint64_t c = 0; c < cells; ++c) out_db[c] = std::max(-200.0, out_db[c] - peak);
    return N60_MEASURE_OK;
}

}  // extern "C"
