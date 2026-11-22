// Cross-domain classifier, early-window magnitude and design-engine preview scoring (E21 S9b, n60/speaker.h sections 5
// to 7). The ports of the Speaker Optimizer's Swift maths in the same order of operations. Offline only: control or
// worker thread, never an audio callback. Portable: no Apple framework.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "n60/speaker.h"

namespace {

constexpr double kPi = 3.14159265358979323846;

bool in(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }

// Gaussian log-frequency smoothing; the shared kernel of the classifier residual and the preview target.
void smooth(const double *f, const double *m, uint32_t n, double octaves, double *out) {
    std::vector<double> logs(n);
    for (uint32_t i = 0; i < n; ++i) logs[i] = std::log2(f[i]);
    for (uint32_t i = 0; i < n; ++i) {
        double sum = 0.0, weights = 0.0;
        for (uint32_t k = 0; k < n; ++k) {
            const double d = (logs[k] - logs[i]) / octaves;
            if (std::fabs(d) > 4.0) continue;
            const double w = std::exp(-0.5 * d * d);
            sum += m[k] * w;
            weights += w;
        }
        out[i] = weights > 0.0 ? sum / weights : m[i];
    }
}

uint32_t classifyPoint(double near, double seat_mean, double spread, const n60_speaker_classify_options &o) {
    const double significant = o.significant_deviation_db;
    const bool near_sig = std::fabs(near) >= significant;
    const bool seat_sig = std::fabs(seat_mean) >= significant;
    const bool same_direction = (near == 0.0 || seat_mean == 0.0) ? false : (near > 0.0) == (seat_mean > 0.0);
    const bool agrees = std::fabs(near - seat_mean) <= o.speaker_agreement_tolerance_db;
    if (near_sig && seat_sig && same_direction && agrees && spread <= o.maximum_persistent_seat_spread_db)
        return N60_SPEAKER_CLASS_PERSISTENT;
    if (std::fabs(near) <= o.near_speaker_flat_tolerance_db && (seat_sig || spread >= o.room_seat_spread_threshold_db))
        return N60_SPEAKER_CLASS_ROOM_SEAT;
    if (std::fabs(near) < significant && std::fabs(seat_mean) < significant && spread < o.room_seat_spread_threshold_db)
        return N60_SPEAKER_CLASS_NO_DEVIATION;
    return N60_SPEAKER_CLASS_AMBIGUOUS;
}

double rmse(const double *mag, const double *target, const double *correction, uint32_t n) {
    double sum = 0.0;
    for (uint32_t i = 0; i < n; ++i) {
        const double r = mag[i] + correction[i] - target[i];
        sum += r * r;
    }
    return std::sqrt(sum / static_cast<double>(n));
}

double weightedRmse(const double *seat_db, const double *weights, uint32_t seats, uint32_t n, const double *target,
                    const double *correction) {
    double mse = 0.0;
    for (uint32_t s = 0; s < seats; ++s) {
        const double e = rmse(seat_db + static_cast<size_t>(s) * n, target, correction, n);
        mse += weights[s] * e * e;
    }
    return std::sqrt(mse);
}

}  // namespace

extern "C" {

void n60_speaker_classify_defaults(n60_speaker_classify_options *o) {
    if (!o) return;
    o->smoothing_octaves = 1.0 / 3.0;
    o->significant_deviation_db = 1.5;
    o->near_speaker_flat_tolerance_db = 0.75;
    o->speaker_agreement_tolerance_db = 1.0;
    o->maximum_persistent_seat_spread_db = 1.0;
    o->room_seat_spread_threshold_db = 1.5;
    o->minimum_point_count = 16;
}

int32_t n60_speaker_classify_options_valid(const n60_speaker_classify_options *o) {
    if (!o) return 0;
    return in(o->smoothing_octaves, 0.15, 1.0) && in(o->significant_deviation_db, 0.5, 6.0) &&
           in(o->near_speaker_flat_tolerance_db, 0.0, o->significant_deviation_db) &&
           in(o->speaker_agreement_tolerance_db, 0.25, 3.0) && in(o->maximum_persistent_seat_spread_db, 0.25, 3.0) &&
           in(o->room_seat_spread_threshold_db, 0.5, 6.0) && o->minimum_point_count >= 8;
}

int32_t n60_speaker_mean_interpolated(const double *grid, uint32_t n, const double *mags, uint32_t captures, const double *at,
                                      uint32_t count, double *out) {
    if (!grid || !mags || !at || !out || n < 2 || captures == 0) return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(grid[i]) || !(grid[i] > 0.0)) return N60_SPEAKER_ERR_ARGUMENT;
        if (i > 0 && !(grid[i - 1] < grid[i])) return N60_SPEAKER_ERR_ARGUMENT;
    }
    for (size_t i = 0; i < static_cast<size_t>(n) * captures; ++i)
        if (!std::isfinite(mags[i])) return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t k = 0; k < count; ++k) {
        const double f = at[k];
        if (!(f >= grid[0]) || !(f <= grid[n - 1])) return N60_SPEAKER_ERR_ARGUMENT;
        double sum = 0.0;
        for (uint32_t c = 0; c < captures; ++c) {
            const double *m = mags + static_cast<size_t>(c) * n;
            double v;
            if (f == grid[0]) {
                v = m[0];
            } else if (f == grid[n - 1]) {
                v = m[n - 1];
            } else {
                uint32_t low = 0, high = n - 1;
                while (high - low > 1) {
                    const uint32_t mid = (low + high) / 2;
                    if (grid[mid] <= f) low = mid; else high = mid;
                }
                const double left = std::log(grid[low]), right = std::log(grid[high]);
                const double fraction = (std::log(f) - left) / (right - left);
                v = m[low] + fraction * (m[high] - m[low]);
            }
            sum += v;
        }
        out[k] = sum / static_cast<double>(captures);
    }
    return N60_SPEAKER_OK;
}

int32_t n60_speaker_local_residual(const double *f, const double *m, uint32_t n, double octaves, double *out) {
    if (!f || !m || !out || n == 0 || !in(octaves, 0.15, 1.0)) return N60_SPEAKER_ERR_ARGUMENT;
    std::vector<double> smoothed(n);
    smooth(f, m, n, octaves, smoothed.data());
    for (uint32_t i = 0; i < n; ++i) out[i] = m[i] - smoothed[i];
    return N60_SPEAKER_OK;
}

int32_t n60_speaker_cross_domain_classify(const n60_speaker_cross_domain_problem *p, n60_speaker_cross_domain_point *points) {
    if (!p || !points || !p->frequency_hz || !p->characterization_db || !p->seat_db || p->point_count == 0 || p->seat_count == 0)
        return N60_SPEAKER_ERR_ARGUMENT;
    if (!n60_speaker_classify_options_valid(&p->options)) return N60_SPEAKER_ERR_SETTINGS;
    const uint32_t n = p->point_count, seats = p->seat_count;
    std::vector<double> near(n);
    std::vector<std::vector<double>> seat(seats, std::vector<double>(n));
    int32_t status = n60_speaker_local_residual(p->frequency_hz, p->characterization_db, n, p->options.smoothing_octaves, near.data());
    if (status != N60_SPEAKER_OK) return status;
    for (uint32_t s = 0; s < seats; ++s) {
        status = n60_speaker_local_residual(p->frequency_hz, p->seat_db + static_cast<size_t>(s) * n, n,
                                            p->options.smoothing_octaves, seat[s].data());
        if (status != N60_SPEAKER_OK) return status;
    }
    for (uint32_t i = 0; i < n; ++i) {
        double sum = 0.0;
        for (uint32_t s = 0; s < seats; ++s) sum += seat[s][i];
        const double mean = sum / static_cast<double>(seats);
        double var = 0.0;
        for (uint32_t s = 0; s < seats; ++s) var += (seat[s][i] - mean) * (seat[s][i] - mean);
        const double spread = std::sqrt(std::fmax(0.0, var / static_cast<double>(seats)));
        points[i].characterization_residual_db = near[i];
        points[i].listening_mean_residual_db = mean;
        points[i].listening_seat_spread_db = spread;
        points[i].classification = classifyPoint(near[i], mean, spread, p->options);
    }
    return N60_SPEAKER_OK;
}

void n60_speaker_early_window_defaults(n60_speaker_early_window_settings *s) {
    if (!s) return;
    s->pre_arrival_ms = 0.75;
    s->post_arrival_ms = 6.0;
    s->fade_out_ms = 1.5;
    s->minimum_cycles = 2.0;
}

int32_t n60_speaker_early_window_settings_valid(const n60_speaker_early_window_settings *s) {
    if (!s) return 0;
    return in(s->pre_arrival_ms, 0.0, 2.0) && in(s->post_arrival_ms, 3.0, 12.0) && std::isfinite(s->fade_out_ms) &&
           s->fade_out_ms >= 0.25 && s->fade_out_ms <= s->post_arrival_ms * 0.5 && in(s->minimum_cycles, 1.0, 4.0);
}

int32_t n60_speaker_early_window(const float *ir, uint32_t ir_count, double sr, double arrival_seconds, double usable_low,
                                 double usable_high, const double *tf, uint32_t tf_count,
                                 const n60_speaker_early_window_settings *settings, double *magnitude_db,
                                 n60_speaker_early_window_result *result) {
    if (!ir || !tf || !magnitude_db || !result || !settings || ir_count == 0 || tf_count == 0) return N60_SPEAKER_ERR_ARGUMENT;
    if (!n60_speaker_early_window_settings_valid(settings)) return N60_SPEAKER_ERR_SETTINGS;
    if (!std::isfinite(sr) || !(sr > 0.0)) return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t i = 0; i < ir_count; ++i)
        if (!std::isfinite(ir[i])) return N60_SPEAKER_ERR_NONFINITE;
    const double arrival_double = arrival_seconds * sr;
    if (!std::isfinite(arrival_seconds) || arrival_seconds < 0.0 || !std::isfinite(arrival_double) ||
        arrival_double >= 4.0e9)
        return N60_SPEAKER_ERR_ARRIVAL;
    const int64_t arrival = static_cast<int64_t>(std::llround(arrival_double));
    if (arrival < 0 || arrival >= static_cast<int64_t>(ir_count)) return N60_SPEAKER_ERR_ARRIVAL;

    const int64_t pre = static_cast<int64_t>(std::llround(settings->pre_arrival_ms * sr / 1000.0));
    const int64_t post = static_cast<int64_t>(std::llround(settings->post_arrival_ms * sr / 1000.0));
    const int64_t fade = std::max<int64_t>(1, static_cast<int64_t>(std::llround(settings->fade_out_ms * sr / 1000.0)));
    if (post < 2) return N60_SPEAKER_ERR_SETTINGS;
    const int64_t start = std::max<int64_t>(0, arrival - pre);
    const int64_t end = arrival + post + 1;
    if (end > static_cast<int64_t>(ir_count)) return N60_SPEAKER_ERR_SHORT;
    const double actual_post = static_cast<double>(end - arrival - 1) / sr;
    const double actual_pre = static_cast<double>(arrival - start) / sr;
    if (!(actual_post > 0.0)) return N60_SPEAKER_ERR_SHORT;

    const double gate_low = settings->minimum_cycles / actual_post;
    const double low = std::fmax(usable_low, gate_low);
    const double high = std::fmin(usable_high, sr * 0.49);
    if (!std::isfinite(low) || !std::isfinite(high) || !(low > 0.0) || !(high > low)) return N60_SPEAKER_ERR_BAND;

    uint32_t first = tf_count, count = 0;
    for (uint32_t i = 0; i < tf_count; ++i)
        if (tf[i] >= low && tf[i] <= high) {
            if (count == 0) first = i;
            ++count;
        }
    if (count < 8 || !(tf[first + count - 1] > tf[first])) return N60_SPEAKER_ERR_BAND;

    const int64_t taper_start = std::max(arrival, end - 1 - fade);
    for (uint32_t k = 0; k < count; ++k) {
        const double frequency = tf[first + k];
        double re = 0.0, im = 0.0;
        for (int64_t frame = start; frame < end; ++frame) {
            double weight;
            if (frame < arrival && arrival > start) {
                const double x = static_cast<double>(frame - start) / static_cast<double>(arrival - start);
                weight = 0.5 - 0.5 * std::cos(kPi * x);
            } else if (frame > taper_start && end - 1 > taper_start) {
                const double x = static_cast<double>(frame - taper_start) / static_cast<double>(end - 1 - taper_start);
                weight = 0.5 + 0.5 * std::cos(kPi * x);
            } else {
                weight = 1.0;
            }
            const double value = static_cast<double>(ir[frame]) * weight;
            const double phase = -2.0 * kPi * frequency * static_cast<double>(frame) / sr;
            re += value * std::cos(phase);
            im += value * std::sin(phase);
        }
        magnitude_db[first + k] = 20.0 * std::log10(std::fmax(std::hypot(re, im), 1.0e-12));
    }
    result->first_index = first;
    result->count = count;
    result->retained_pre_arrival_ms = actual_pre * 1000.0;
    result->retained_post_arrival_ms = actual_post * 1000.0;
    return N60_SPEAKER_OK;
}

void n60_speaker_preview_defaults(n60_speaker_preview_options *o) {
    if (!o) return;
    o->maximum_cut_db = 6.0;
    o->maximum_boost_db = 0.0;
    o->smoothing_octaves = 1.0 / 3.0;
    o->target_tilt_db_per_octave = 0.0;
    o->maximum_seat_degradation_db = 0.25;
}

int32_t n60_speaker_preview_options_valid(const n60_speaker_preview_options *o) {
    if (!o) return 0;
    return in(o->maximum_cut_db, 0, 12) && in(o->maximum_boost_db, 0, 3) && in(o->smoothing_octaves, 0.15, 1.0) &&
           in(o->target_tilt_db_per_octave, -3, 3) && in(o->maximum_seat_degradation_db, 0, 1);
}

int32_t n60_speaker_design_preview(const n60_speaker_preview_problem *p, n60_speaker_preview_result *r) {
    if (!p || !r || !r->target_db || !r->correction_db || !p->frequency_hz || !p->seat_db || !p->seat_weight || p->bin_count == 0 ||
        p->seat_count == 0)
        return N60_SPEAKER_ERR_ARGUMENT;
    if (!n60_speaker_preview_options_valid(&p->options)) return N60_SPEAKER_ERR_SETTINGS;
    const n60_speaker_preview_options &o = p->options;
    const uint32_t n = p->bin_count, seats = p->seat_count;
    for (uint32_t i = 0; i < n; ++i)
        if (!std::isfinite(p->frequency_hz[i]) || !(p->frequency_hz[i] > 0.0)) return N60_SPEAKER_ERR_ARGUMENT;

    std::vector<double> combined(n), smoothed(n);
    for (uint32_t i = 0; i < n; ++i) {
        double total = 0.0;
        for (uint32_t s = 0; s < seats; ++s) total += p->seat_weight[s] * p->seat_db[static_cast<size_t>(s) * n + i];
        combined[i] = total;
    }
    std::vector<double> sorted = combined;
    std::sort(sorted.begin(), sorted.end());
    const double median = sorted[sorted.size() / 2];
    for (uint32_t i = 0; i < n; ++i) r->target_db[i] = median + o.target_tilt_db_per_octave * std::log2(p->frequency_hz[i] / 1000.0);
    smooth(p->frequency_hz, combined.data(), n, o.smoothing_octaves, smoothed.data());
    for (uint32_t i = 0; i < n; ++i)
        r->correction_db[i] = std::fmin(o.maximum_boost_db, std::fmax(-o.maximum_cut_db, r->target_db[i] - smoothed[i]));

    const std::vector<double> zero(n, 0.0);
    const double before = weightedRmse(p->seat_db, p->seat_weight, seats, n, r->target_db, zero.data());
    double predicted = weightedRmse(p->seat_db, p->seat_weight, seats, n, r->target_db, r->correction_db);
    bool degrades = false;
    for (uint32_t s = 0; s < seats && !degrades; ++s) {
        const double *seat = p->seat_db + static_cast<size_t>(s) * n;
        degrades = rmse(seat, r->target_db, r->correction_db, n) > rmse(seat, r->target_db, zero.data(), n) + o.maximum_seat_degradation_db;
    }
    r->reverted = 0;
    if (!std::isfinite(predicted) || predicted > before + 1.0e-9 || degrades) {
        std::fill(r->correction_db, r->correction_db + n, 0.0);
        predicted = before;
        r->reverted = 1;
    }
    r->rmse_before_db = before;
    r->rmse_after_db = predicted;
    return N60_SPEAKER_OK;
}

}  // extern "C"
