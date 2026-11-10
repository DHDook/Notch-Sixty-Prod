// Predicted treated impulse response (E19 S1, design note 2).
//
// For one seat: the sum over sources of plant_s * filter_s, where the plant is the measured raw IR of
// source s at that seat (already convolved with the known downstream chain by the caller) and the filter
// is that source's treatment filter. Works at the device rate or at the low rate fs/D: the maths has no
// rate in it, the caller keeps plants and filters at one rate. Offline, control thread only (allocates).
//
// A one-tap filter is applied directly (identity filters give exactly the measured sum, scaled filters
// exactly the scaled sum). Longer filters use double-precision FFT convolution, accumulated in the
// spectrum domain so one inverse transform serves all sources.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;

bool validSources(uint32_t sourceCount, const float *const *plants, const uint64_t *plantCounts,
                  const float *const *filters, const uint64_t *filterCounts) {
    if (sourceCount < 1 || sourceCount > N60_MEASURE_PREDICT_MAX_SOURCES) return false;
    if (plants == nullptr || plantCounts == nullptr || filters == nullptr || filterCounts == nullptr) return false;
    for (uint32_t s = 0; s < sourceCount; ++s) {
        if (plants[s] == nullptr || plantCounts[s] == 0 || filters[s] == nullptr || filterCounts[s] == 0) return false;
        for (uint64_t i = 0; i < plantCounts[s]; ++i) if (!std::isfinite(plants[s][i])) return false;
        for (uint64_t i = 0; i < filterCounts[s]; ++i) if (!std::isfinite(filters[s][i])) return false;
    }
    return true;
}

uint64_t convLength(uint32_t sourceCount, const uint64_t *plantCounts, const uint64_t *filterCounts) {
    uint64_t longest = 0;
    for (uint32_t s = 0; s < sourceCount; ++s) longest = std::max(longest, plantCounts[s] + filterCounts[s] - 1);
    return longest;
}

}  // namespace

extern "C" {

int32_t n60_measure_predict_treated_length(uint32_t source_count, const uint64_t *plant_counts,
                                           const uint64_t *filter_counts, uint64_t *frames_out) {
    if (frames_out == nullptr || plant_counts == nullptr || filter_counts == nullptr ||
        source_count < 1 || source_count > N60_MEASURE_PREDICT_MAX_SOURCES) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    for (uint32_t s = 0; s < source_count; ++s) if (plant_counts[s] == 0 || filter_counts[s] == 0) return N60_MEASURE_ERR_ARGUMENT;
    *frames_out = convLength(source_count, plant_counts, filter_counts);
    return N60_MEASURE_OK;
}

int32_t n60_measure_predict_treated_ir(uint32_t source_count, const float *const *plants, const uint64_t *plant_counts,
                                       const float *const *filters, const uint64_t *filter_counts,
                                       float *out, uint64_t capacity, uint64_t *count_out) {
    if (out == nullptr || count_out == nullptr ||
        !validSources(source_count, plants, plant_counts, filters, filter_counts)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const uint64_t total = convLength(source_count, plant_counts, filter_counts);
    if (capacity < total) return N60_MEASURE_ERR_CAPACITY;

    std::vector<double> acc(total, 0.0);
    uint64_t n = 2;
    bool anyFft = false;
    for (uint32_t s = 0; s < source_count; ++s) {
        if (filter_counts[s] > 1) {
            anyFft = true;
            while (n < plant_counts[s] + filter_counts[s] - 1) n <<= 1;
        }
    }
    if (anyFft && n > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;

    std::vector<Cplx> sum;
    if (anyFft) sum.assign(n / 2 + 1, Cplx{0.0, 0.0});
    std::vector<double> padded;
    std::vector<Cplx> a, b;
    for (uint32_t s = 0; s < source_count; ++s) {
        const uint64_t pc = plant_counts[s], fc = filter_counts[s];
        if (fc == 1) {
            const double g = filters[s][0];
            for (uint64_t i = 0; i < pc; ++i) acc[i] += g * static_cast<double>(plants[s][i]);
            continue;
        }
        padded.assign(n, 0.0);
        for (uint64_t i = 0; i < pc; ++i) padded[i] = plants[s][i];
        if (!n60::fft::offline::realForward(padded.data(), n, a)) return N60_MEASURE_ERR_ALLOC;
        padded.assign(n, 0.0);
        for (uint64_t i = 0; i < fc; ++i) padded[i] = filters[s][i];
        if (!n60::fft::offline::realForward(padded.data(), n, b)) return N60_MEASURE_ERR_ALLOC;
        for (size_t k = 0; k < sum.size(); ++k) {
            sum[k].re += a[k].re * b[k].re - a[k].im * b[k].im;
            sum[k].im += a[k].re * b[k].im + a[k].im * b[k].re;
        }
    }
    if (anyFft) {
        std::vector<double> time;
        if (!n60::fft::offline::realInverse(sum, n, time)) return N60_MEASURE_ERR_ALLOC;
        for (uint64_t i = 0; i < total; ++i) acc[i] += time[i];
    }
    for (uint64_t i = 0; i < total; ++i) out[i] = static_cast<float>(acc[i]);
    *count_out = total;
    return N60_MEASURE_OK;
}

}  // extern "C"
