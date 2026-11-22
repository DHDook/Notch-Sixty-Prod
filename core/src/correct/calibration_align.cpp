// Multichannel calibration alignment maths (E21 S7a, n60/correct.h section 8).
//
// The port of the numbers-to-numbers part of MultichannelCalibrationDesigner.swift and the speaker alignment plan of
// the legacy N60MultichannelCalibration.h. Single-precision arithmetic in the legacy order. Offline only: control or
// worker thread, never called from an audio callback. Portable: no Apple framework.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <numeric>
#include <vector>

#include "n60/correct.h"

namespace {

float includedWeight(const float *w, uint32_t n) {
    float total = 0.0f;
    for (uint32_t i = 0; i < n; ++i)
        if (w[i] > 0.0f) total += w[i];
    return total;
}

}  // namespace

extern "C" {

int32_t n60_correct_calib_grid(double min_hz, double max_hz, uint32_t count, float *out) {
    if (out == nullptr || count < 2 || !std::isfinite(min_hz) || !std::isfinite(max_hz) || !(min_hz > 0.0) ||
        !(max_hz > min_hz))
        return N60_CORRECT_ERR_ARGUMENT;
    const double ratio = max_hz / min_hz;
    for (uint32_t i = 0; i < count; ++i)
        out[i] = static_cast<float>(min_hz * std::pow(ratio, static_cast<double>(i) / static_cast<double>(count - 1)));
    return N60_CORRECT_OK;
}

int32_t n60_correct_calib_direct_polarity(const float *impulse, uint64_t count, uint64_t arrival_frame) {
    if (impulse == nullptr || count == 0) return 1;
    const uint64_t start = std::min<uint64_t>(arrival_frame, count - 1);
    const uint64_t end = std::min<uint64_t>(count, start + 16);
    float peak = impulse[start];
    for (uint64_t i = start; i < end; ++i)
        if (std::fabs(impulse[i]) > std::fabs(peak)) peak = impulse[i];
    return peak < 0.0f ? -1 : 1;
}

float n60_correct_calib_broadband_level_db(const float *frequency_hz, const float *magnitude_db, uint32_t count, int32_t is_sub) {
    if (frequency_hz == nullptr || magnitude_db == nullptr || count == 0) return 0.0f;
    const float low = is_sub ? 25.0f : 100.0f;
    const float high = is_sub ? 200.0f : 10000.0f;
    float total = 0.0f, n = 0.0f;
    for (uint32_t i = 0; i < count; ++i) {
        if (frequency_hz[i] >= low && frequency_hz[i] <= high) {
            total += magnitude_db[i];
            n += 1.0f;
        }
    }
    if (n > 0.0f) return total / n;
    float all = 0.0f;
    for (uint32_t i = 0; i < count; ++i) all += magnitude_db[i];
    return all / static_cast<float>(count);
}

int32_t n60_correct_calib_align(const n60_correct_calib_align_problem *p, n60_correct_calib_align_result *r) {
    if (p == nullptr || r == nullptr || r->sources == nullptr || p->seat_weight == nullptr || p->source_is_speaker == nullptr ||
        p->arrival_frame == nullptr || p->polarity == nullptr || p->level_db == nullptr || p->seat_count == 0 ||
        p->source_count == 0)
        return N60_CORRECT_ERR_ARGUMENT;
    for (uint32_t s = 0; s < p->seat_count; ++s)
        if (!std::isfinite(p->seat_weight[s])) return N60_CORRECT_ERR_NONFINITE;
    const float totalWeight = includedWeight(p->seat_weight, p->seat_count);
    if (!std::isfinite(totalWeight) || totalWeight <= 0.0f) return N60_CORRECT_ERR_ARGUMENT;
    for (uint32_t i = 0; i < p->source_count * p->seat_count; ++i)
        if (!std::isfinite(p->level_db[i])) return N60_CORRECT_ERR_NONFINITE;

    std::memset(r->sources, 0, sizeof(n60_correct_calib_align_source) * p->source_count);
    float latestArrival = 0.0f;
    float quietest = INFINITY;
    bool any = false;
    for (uint32_t src = 0; src < p->source_count; ++src) {
        if (!p->source_is_speaker[src]) continue;
        float arrival = 0.0f, level = 0.0f, positive = 0.0f, negative = 0.0f;
        for (uint32_t seat = 0; seat < p->seat_count; ++seat) {
            const float w = p->seat_weight[seat];
            if (w <= 0.0f) continue;
            const size_t k = static_cast<size_t>(src) * p->seat_count + seat;
            const float normalized = w / totalWeight;
            arrival += static_cast<float>(p->arrival_frame[k]) * normalized;
            level += p->level_db[k] * normalized;
            if (p->polarity[k] > 0) positive += w;
            else negative += w;
        }
        n60_correct_calib_align_source &o = r->sources[src];
        o.valid = 1;
        o.weighted_arrival_frame = arrival;
        o.weighted_level_db = level;
        o.polarity_inverted = negative > positive ? 1u : 0u;
        if (arrival > latestArrival) latestArrival = arrival;
        if (level < quietest) quietest = level;
        any = true;
    }
    if (!any || !std::isfinite(quietest)) return N60_CORRECT_ERR_ARGUMENT;

    r->reference_arrival_frame = static_cast<uint32_t>(std::ceil(latestArrival));
    r->common_level_db = quietest;
    for (uint32_t src = 0; src < p->source_count; ++src) {
        n60_correct_calib_align_source &o = r->sources[src];
        if (!o.valid) continue;
        const float delay = std::fmax(0.0f, static_cast<float>(r->reference_arrival_frame) - o.weighted_arrival_frame);
        o.delay_frames = static_cast<uint32_t>(std::llround(delay));
        o.trim_db = quietest - o.weighted_level_db;
        if (o.trim_db < -N60_CORRECT_CALIB_MAX_TRIM_ATTENUATION_DB) o.trim_db = -N60_CORRECT_CALIB_MAX_TRIM_ATTENUATION_DB;
        float variance = 0.0f;
        for (uint32_t seat = 0; seat < p->seat_count; ++seat) {
            const float w = p->seat_weight[seat];
            if (w <= 0.0f) continue;
            const float normalized = w / totalWeight;
            const float difference = p->level_db[static_cast<size_t>(src) * p->seat_count + seat] - o.weighted_level_db;
            variance += normalized * difference * difference;
        }
        o.seat_variance_db2 = variance;
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_calib_timing_offsets(const n60_correct_calib_timing_problem *p, double *speaker_ms, double *sub_ms) {
    if (p == nullptr || speaker_ms == nullptr || sub_ms == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    *speaker_ms = 0.0;
    *sub_ms = 0.0;
    if (p->sub_count == 0) return N60_CORRECT_OK;
    if (p->seat_weight == nullptr || p->arrival_frame == nullptr || p->additional_delay_ms == nullptr || p->seat_count == 0 ||
        !std::isfinite(p->sample_rate) || !(p->sample_rate > 0.0))
        return N60_CORRECT_ERR_ARGUMENT;
    for (uint32_t s = 0; s < p->seat_count; ++s)
        if (!std::isfinite(p->seat_weight[s])) return N60_CORRECT_ERR_NONFINITE;
    const double total = static_cast<double>(includedWeight(p->seat_weight, p->seat_count));
    if (!(total > 0.0)) return N60_CORRECT_ERR_ARGUMENT;
    double latest = 0.0;
    for (uint32_t sub = 0; sub < p->sub_count; ++sub) {
        double weighted = 0.0;
        for (uint32_t seat = 0; seat < p->seat_count; ++seat) {
            const double w = static_cast<double>(p->seat_weight[seat]);
            if (!(p->seat_weight[seat] > 0.0f)) continue;
            weighted += static_cast<double>(p->arrival_frame[static_cast<size_t>(sub) * p->seat_count + seat]) * w / total;
        }
        weighted += static_cast<double>(p->additional_delay_ms[sub]) * p->sample_rate / 1000.0;
        latest = std::max(latest, weighted);
    }
    const double reference = static_cast<double>(p->speaker_reference_arrival_frame);
    if (latest > reference) *speaker_ms = (latest - reference) / p->sample_rate * 1000.0;
    else *sub_ms = (reference - latest) / p->sample_rate * 1000.0;
    return N60_CORRECT_OK;
}

int32_t n60_correct_calib_sub_eq_fit(const float *f, const float *t, uint32_t count, float min_hz, float max_hz, uint32_t max_bands,
                                     double *out_f, double *out_g, double *out_q, uint32_t *out_count) {
    if (out_count == nullptr || out_f == nullptr || out_g == nullptr || out_q == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    *out_count = 0;
    if (count == 0) return N60_CORRECT_OK;
    if (f == nullptr || t == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    std::vector<uint32_t> candidates;
    for (uint32_t i = 0; i < count; ++i)
        if (f[i] >= min_hz && f[i] <= max_hz && std::isfinite(t[i]) && t[i] <= -0.75f) candidates.push_back(i);
    std::stable_sort(candidates.begin(), candidates.end(), [&](uint32_t a, uint32_t b) { return t[a] < t[b]; });
    std::vector<double> chosen, gains;
    for (uint32_t i : candidates) {
        if (chosen.size() >= max_bands) break;
        const double frequency = static_cast<double>(f[i]);
        bool apart = true;
        for (double c : chosen)
            if (!(std::fabs(std::log2(frequency / c)) >= 0.33)) { apart = false; break; }
        if (!apart) continue;
        chosen.push_back(frequency);
        gains.push_back(std::max(-8.0, std::min(0.0, static_cast<double>(t[i]) * 0.72)));
    }
    std::vector<uint32_t> order(chosen.size());
    std::iota(order.begin(), order.end(), 0u);
    std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) { return chosen[a] < chosen[b]; });
    for (size_t k = 0; k < order.size(); ++k) {
        out_f[k] = chosen[order[k]];
        out_g[k] = gains[order[k]];
        out_q[k] = 1.15;
    }
    *out_count = static_cast<uint32_t>(order.size());
    return N60_CORRECT_OK;
}

}  // extern "C"
