// Crossover feasibility (E21 S9b, n60/speaker.h section 4).
//
// The port of SpeakerOptimizerCrossoverFeasibilityDesigner's maths in the same order of operations. The caller keeps the
// evidence qualification and the arrival-gap check. Offline only: control or worker thread, never an audio callback.
// Portable: no Apple framework.
#include <cmath>
#include <cstdint>
#include <vector>

#include "n60/speaker.h"

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Eval {
    double summed_db;
    double peak_above_db;
};

struct Pt {
    double re, im;
};

Pt rotate(double re, double im, double phase) {
    const double c = std::cos(phase), s = std::sin(phase);
    return {re * c - im * s, re * s + im * c};
}

Eval evaluateSeat(const n60_speaker_crossover_problem &p, uint32_t seat, double relative_delay_ms, bool invert, double unknown_ms) {
    const double delay_main = std::fmax(0.0, relative_delay_ms) / 1000.0;
    const double delay_sub = (std::fmax(0.0, -relative_delay_ms) + unknown_ms) / 1000.0;
    const size_t base = static_cast<size_t>(seat) * p.point_count;
    double summed_power = 0.0, max_above = 0.0;
    for (uint32_t i = 0; i < p.point_count; ++i) {
        const double f = p.frequency_hz[i];
        const Pt m = rotate(p.main_real[base + i], p.main_imag[base + i], -2.0 * kPi * f * delay_main);
        const Pt s = rotate(p.sub_real[base + i], p.sub_imag[base + i], -2.0 * kPi * f * delay_sub);
        const double polarity = invert ? -1.0 : 1.0;
        const double sr = m.re + polarity * s.re, si = m.im + polarity * s.im;
        const double power = sr * sr + si * si;
        summed_power += power;
        const double strongest = std::fmax(m.re * m.re + m.im * m.im, s.re * s.re + s.im * s.im);
        const double above = 10.0 * std::log10(std::fmax(power, 1e-24) / std::fmax(strongest, 1e-24));
        max_above = std::fmax(max_above, above);
    }
    return {10.0 * std::log10(std::fmax(summed_power / static_cast<double>(p.point_count), 1e-24)), max_above};
}

double weighted(const std::vector<double> &levels, const double *weights) {
    double sum = 0.0;
    for (size_t i = 0; i < levels.size(); ++i) sum += levels[i] * weights[i];
    return sum;
}

bool problemOk(const n60_speaker_crossover_problem *p) {
    return p && p->seat_count > 0 && p->point_count > 0 && p->frequency_hz && p->main_real && p->main_imag && p->sub_real &&
           p->sub_imag && p->seat_weight && n60_speaker_crossover_options_valid(&p->options, p->sample_rate) == 1;
}

struct Interp {
    double re, im;
};

bool interpolateComplex(double f, const double *grid, const double *mags, const double *phases, uint32_t n, Interp *out) {
    if (n < 2 || f < grid[0] || f > grid[n - 1]) return false;
    uint32_t lower = 0, upper = n - 1;
    while (upper - lower > 1) {
        const uint32_t mid = (lower + upper) / 2;
        if (grid[mid] <= f) lower = mid; else upper = mid;
    }
    const double octave_gap = std::log2(grid[upper] / grid[lower]);
    if (!std::isfinite(octave_gap) || !(octave_gap > 0.0) || octave_gap > 0.30) return false;
    const double fraction = std::log(f / grid[lower]) / std::log(grid[upper] / grid[lower]);
    const double magnitude = mags[lower] + fraction * (mags[upper] - mags[lower]);
    const double delta = std::atan2(std::sin(phases[upper] - phases[lower]), std::cos(phases[upper] - phases[lower]));
    const double phase = phases[lower] + fraction * delta;
    const double amp = std::pow(10.0, magnitude / 20.0);
    if (!std::isfinite(amp) || !std::isfinite(phase) || !(amp > 0.0)) return false;
    *out = {amp * std::cos(phase), amp * std::sin(phase)};
    return true;
}

}  // namespace

extern "C" {

void n60_speaker_crossover_defaults(n60_speaker_crossover_options *o) {
    if (!o) return;
    o->center_hz = 80.0;
    o->band_width_octaves = 1.0;
    o->frequency_point_count = 32;
    o->maximum_additional_delay_ms = 8.0;
    o->delay_step_ms = 0.25;
    o->maximum_arrival_gap_ms = 25.0;
    o->maximum_seat_regression_db = 1.0;
    o->minimum_aggregate_improvement_db = 0.25;
    o->maximum_modeled_sum_above_strongest_db = 6.5;
}

int32_t n60_speaker_crossover_options_valid(const n60_speaker_crossover_options *o, double sr) {
    if (!o) return 0;
    auto in = [](double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; };
    return std::isfinite(sr) && sr >= 16000.0 && in(o->center_hz, 35, 250) && in(o->band_width_octaves, 0.5, 1.5) &&
           o->frequency_point_count >= 16 && o->frequency_point_count <= 64 && in(o->maximum_additional_delay_ms, 0, 12) &&
           in(o->delay_step_ms, 0.125, 1) && in(o->maximum_arrival_gap_ms, 0, 40) && in(o->maximum_seat_regression_db, 0, 2) &&
           in(o->minimum_aggregate_improvement_db, 0, 2) && in(o->maximum_modeled_sum_above_strongest_db, 0, 6.5) &&
           o->center_hz * std::pow(2.0, o->band_width_octaves / 2.0) < sr * 0.48;
}

int32_t n60_speaker_crossover_frequencies(const n60_speaker_crossover_options *o, double *out, uint32_t capacity) {
    if (!o || !out || o->frequency_point_count < 2 || capacity < o->frequency_point_count) return N60_SPEAKER_ERR_ARGUMENT;
    const double low = o->center_hz / std::pow(2.0, o->band_width_octaves / 2.0);
    const double high = o->center_hz * std::pow(2.0, o->band_width_octaves / 2.0);
    for (uint32_t i = 0; i < o->frequency_point_count; ++i)
        out[i] = low * std::pow(high / low, static_cast<double>(i) / static_cast<double>(o->frequency_point_count - 1));
    return N60_SPEAKER_OK;
}

int32_t n60_speaker_crossover_response(const double *grid, uint32_t grid_count, uint32_t captures, const double *mags,
                                       const double *phases, double arrival, const double *freqs, uint32_t count, double *re,
                                       double *im) {
    if (!grid || !mags || !phases || !freqs || !re || !im || captures == 0 || grid_count < 2 || !std::isfinite(arrival))
        return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t k = 0; k < count; ++k) {
        double sr = 0.0, si = 0.0;
        for (uint32_t c = 0; c < captures; ++c) {
            Interp point{};
            if (!interpolateComplex(freqs[k], grid, mags + static_cast<size_t>(c) * grid_count,
                                    phases + static_cast<size_t>(c) * grid_count, grid_count, &point))
                return N60_SPEAKER_ERR_ARGUMENT;
            sr += point.re / static_cast<double>(captures);
            si += point.im / static_cast<double>(captures);
        }
        const Pt r = rotate(sr, si, -2.0 * kPi * freqs[k] * arrival);
        re[k] = r.re;
        im[k] = r.im;
    }
    return N60_SPEAKER_OK;
}

int32_t n60_speaker_crossover_evaluate(const n60_speaker_crossover_problem *p, double delay_ms, int32_t invert, double unknown_ms,
                                       double *level, double *peak) {
    if (!problemOk(p) || !level || !peak) return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t s = 0; s < p->seat_count; ++s) {
        const Eval e = evaluateSeat(*p, s, delay_ms, invert != 0, unknown_ms);
        level[s] = e.summed_db;
        peak[s] = e.peak_above_db;
    }
    return N60_SPEAKER_OK;
}

int32_t n60_speaker_crossover_search(const n60_speaker_crossover_problem *p, n60_speaker_crossover_result *r) {
    if (!problemOk(p) || !r || !r->baseline_level_db || !r->selected_level_db || !r->selected_peak_above_db)
        return N60_SPEAKER_ERR_ARGUMENT;
    const n60_speaker_crossover_options &o = p->options;
    const uint32_t seats = p->seat_count;
    std::vector<double> baseline(seats), levels(seats);
    std::vector<Eval> evals(seats), bestEvals(seats);
    for (uint32_t s = 0; s < seats; ++s) {
        evals[s] = evaluateSeat(*p, s, 0.0, false, 0.0);
        baseline[s] = evals[s].summed_db;
        r->baseline_level_db[s] = baseline[s];
    }
    const double baseline_aggregate = weighted(baseline, p->seat_weight);
    bool have = false;
    double best_delay = 0.0, best_improvement = 0.0;
    bool best_invert = false;
    const int steps = static_cast<int>(std::floor(o.maximum_additional_delay_ms / o.delay_step_ms));
    for (int i = -steps; i <= steps; ++i) {
        const double offset = static_cast<double>(i) * o.delay_step_ms;
        for (int inv = 0; inv < 2; ++inv) {
            if (offset == 0.0 && inv == 0) continue;
            bool ok = true;
            for (uint32_t s = 0; s < seats; ++s) {
                evals[s] = evaluateSeat(*p, s, offset, inv != 0, 0.0);
                levels[s] = evals[s].summed_db;
            }
            const double improvement = weighted(levels, p->seat_weight) - baseline_aggregate;
            if (!std::isfinite(improvement)) ok = false;
            for (uint32_t s = 0; ok && s < seats; ++s)
                if (!(levels[s] - baseline[s] >= -o.maximum_seat_regression_db)) ok = false;
            for (uint32_t s = 0; ok && s < seats; ++s)
                if (!(std::isfinite(evals[s].peak_above_db) && evals[s].peak_above_db <= o.maximum_modeled_sum_above_strongest_db))
                    ok = false;
            if (!ok) continue;
            const bool superior = !have || improvement > best_improvement + 1e-7 ||
                                  (std::fabs(improvement - best_improvement) <= 1e-7 && std::fabs(offset) < std::fabs(best_delay));
            if (superior) {
                have = true;
                best_delay = offset;
                best_invert = inv != 0;
                best_improvement = improvement;
                bestEvals = evals;
            }
        }
    }
    const bool accepted = have && best_improvement >= o.minimum_aggregate_improvement_db;
    r->accepted = accepted ? 1u : 0u;
    r->delay_ms = accepted ? best_delay : 0.0;
    r->invert_sub_polarity = accepted && best_invert ? 1u : 0u;
    r->aggregate_improvement_db = accepted ? best_improvement : 0.0;
    double max_above = 0.0;
    for (uint32_t s = 0; s < seats; ++s) {
        // Not accepted: the baseline evaluation (offset 0, no inversion) is the selected one.
        const Eval use = accepted ? bestEvals[s] : evaluateSeat(*p, s, 0.0, false, 0.0);
        r->selected_level_db[s] = use.summed_db;
        r->selected_peak_above_db[s] = use.peak_above_db;
        max_above = s == 0 ? use.peak_above_db : std::fmax(max_above, use.peak_above_db);
    }
    r->maximum_sum_above_strongest_db = seats == 0 ? 0.0 : max_above;
    return N60_SPEAKER_OK;
}

void n60_speaker_sensitivity_defaults(n60_speaker_sensitivity_options *o) {
    if (!o) return;
    o->maximum_clock_offset_ms = 2.0;
    o->sample_count = 9;
    o->minimum_worst_improvement_db = 0.15;
    o->maximum_worst_seat_regression_db = 1.0;
    o->maximum_sum_above_strongest_db = 6.5;
}

int32_t n60_speaker_sensitivity_options_valid(const n60_speaker_sensitivity_options *o) {
    if (!o) return 0;
    auto in = [](double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; };
    return in(o->maximum_clock_offset_ms, 0.125, 8.0) && o->sample_count >= 3 && o->sample_count <= 33 &&
           o->sample_count % 2 == 1 && in(o->minimum_worst_improvement_db, 0, 2) &&
           in(o->maximum_worst_seat_regression_db, 0, 2) && in(o->maximum_sum_above_strongest_db, 0, 6.5);
}

int32_t n60_speaker_crossover_sensitivity(const n60_speaker_crossover_problem *p, double delay_ms, int32_t invert,
                                          const n60_speaker_sensitivity_options *o, n60_speaker_sensitivity_sample *samples,
                                          n60_speaker_sensitivity_summary *summary) {
    if (!problemOk(p) || !o || !samples || !summary) return N60_SPEAKER_ERR_ARGUMENT;
    if (!n60_speaker_sensitivity_options_valid(o)) return N60_SPEAKER_ERR_SETTINGS;
    const uint32_t seats = p->seat_count;
    std::vector<double> bl(seats), bp(seats), tl(seats), tp(seats);
    double worst_gain = INFINITY, worst_loss = 0.0, worst_peak = 0.0;
    for (uint32_t k = 0; k < o->sample_count; ++k) {
        const double shift = o->maximum_clock_offset_ms *
                             (2.0 * static_cast<double>(k) / static_cast<double>(o->sample_count - 1) - 1.0);
        n60_speaker_crossover_evaluate(p, 0.0, 0, shift, bl.data(), bp.data());
        n60_speaker_crossover_evaluate(p, delay_ms, invert, shift, tl.data(), tp.data());
        const double gain = weighted(tl, p->seat_weight) - weighted(bl, p->seat_weight);
        double loss = -INFINITY, peak = -INFINITY;
        for (uint32_t s = 0; s < seats; ++s) {
            loss = std::fmax(loss, bl[s] - tl[s]);
            peak = std::fmax(peak, tp[s]);
        }
        if (!std::isfinite(gain) || !std::isfinite(loss) || !std::isfinite(peak)) return N60_SPEAKER_ERR_NONFINITE;
        worst_gain = std::fmin(worst_gain, gain);
        worst_loss = std::fmax(worst_loss, loss);
        worst_peak = std::fmax(worst_peak, peak);
        samples[k] = {shift, gain, loss, peak};
    }
    summary->worst_improvement_db = worst_gain;
    summary->worst_seat_regression_db = worst_loss;
    summary->worst_sum_above_strongest_db = worst_peak;
    summary->reasons = 0;
    if (worst_gain < o->minimum_worst_improvement_db) summary->reasons |= N60_SPEAKER_SENSITIVITY_ERASED;
    if (worst_loss > o->maximum_worst_seat_regression_db) summary->reasons |= N60_SPEAKER_SENSITIVITY_SEAT;
    if (worst_peak > o->maximum_sum_above_strongest_db) summary->reasons |= N60_SPEAKER_SENSITIVITY_SUM;
    return N60_SPEAKER_OK;
}

}  // extern "C"
