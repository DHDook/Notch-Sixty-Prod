// Multi-subwoofer optimiser glue (E21 S7b, n60/correct.h section 9).
//
// The port of N60MultiSubOptimize from the legacy N60MultiSubOptimizer.h: the table build, the call into the section 6
// searches and the final objective, in the legacy single and double precision order so results match it. Standalone:
// not merged with n60_correct_bass_optimise (E21 Q5 is unanswered). Offline only (control or worker thread); allocates
// at entry with malloc and reports N60_CORRECT_ERR_ALLOC. Portable: no Apple framework.
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "n60/correct.h"

namespace {

constexpr double kPi = 3.14159265358979323846;

struct Free {
    void *p = nullptr;
    ~Free() { std::free(p); }
};

bool used(const n60_correct_multisub_opt_problem &p, uint32_t seat) { return p.seat_weight[seat] > 0.0f; }

// One sub at one seat and bin: the complex contribution (legacy N60MultiSubComplexContribution).
void contribution(const n60_correct_multisub_opt_problem &p, uint32_t sub, uint32_t seat, uint32_t bin, float gainDb,
                  float delayMs, bool inverted, float eqDb, double &re, double &im) {
    const size_t at = (static_cast<size_t>(sub) * p.seat_count + seat) * p.bin_count + bin;
    const double frequency = p.frequency_hz[bin];
    const double magnitude = std::pow(
        10.0, (static_cast<double>(p.magnitude_db[at]) + static_cast<double>(gainDb) + static_cast<double>(eqDb)) / 20.0);
    const double measuredDelay = static_cast<double>(p.arrival_frame[static_cast<size_t>(sub) * p.seat_count + seat]) / p.sample_rate;
    const double extra = static_cast<double>(delayMs) * 0.001;
    double phase = static_cast<double>(p.phase_rad[at]) - 2.0 * kPi * frequency * (measuredDelay + extra);
    if (inverted) phase += kPi;
    re = magnitude * std::cos(phase);
    im = magnitude * std::sin(phase);
}

// Legacy N60MultiSubEvaluateFrequency. False when a used response is invalid.
bool evaluateBin(const n60_correct_multisub_opt_problem &p, const n60_correct_multisub_opt_result &r, float totalWeight,
                 uint32_t bin, float &targetError, float &variance) {
    float seatDb[64] = {0};
    float mean = 0.0f;
    for (uint32_t seat = 0; seat < p.seat_count; ++seat) {
        if (!used(p, seat)) continue;
        double sumRe = 0.0, sumIm = 0.0;
        for (uint32_t sub = 0; sub < p.sub_count; ++sub) {
            if (p.valid[static_cast<size_t>(sub) * p.seat_count + seat] == 0) return false;
            double re = 0.0, im = 0.0;
            contribution(p, sub, seat, bin, r.gain_db[sub], r.additional_delay_ms[sub], r.polarity_inverted[sub] != 0,
                         r.eq_target_db[sub][bin], re, im);
            sumRe += re;
            sumIm += im;
        }
        const double magnitude = std::hypot(sumRe, sumIm);
        const float db = static_cast<float>(20.0 * std::log10(std::fmax(magnitude, 1.0e-12)));
        seatDb[seat] = db;
        mean += db * (p.seat_weight[seat] / totalWeight);
    }
    float var = 0.0f, err = 0.0f;
    for (uint32_t seat = 0; seat < p.seat_count; ++seat) {
        if (!used(p, seat)) continue;
        const float normalised = p.seat_weight[seat] / totalWeight;
        const float meanDiff = seatDb[seat] - mean;
        const float targetDiff = seatDb[seat] - p.target_db[bin];
        var += normalised * meanDiff * meanDiff;
        err += normalised * targetDiff * targetDiff;
    }
    targetError = err;
    variance = var;
    return true;
}

float objective(const n60_correct_multisub_opt_problem &p, const n60_correct_multisub_opt_result &r, float totalWeight,
                float *targetErrorOut, float *varianceOut) {
    const n60_correct_multisub_opt_settings &s = p.settings;
    float targetError = 0.0f, variance = 0.0f;
    for (uint32_t bin = 0; bin < p.bin_count; ++bin) {
        float e = 0.0f, v = 0.0f;
        if (!evaluateBin(p, r, totalWeight, bin, e, v)) return INFINITY;
        targetError += e / static_cast<float>(p.bin_count);
        variance += v / static_cast<float>(p.bin_count);
    }
    float regularisation = 0.0f;
    for (uint32_t sub = 0; sub < p.sub_count; ++sub) {
        const float boost = std::fmax(0.0f, r.gain_db[sub]);
        regularisation += s.boost_regularisation * boost * boost;
        for (uint32_t bin = 0; bin < p.bin_count; ++bin) {
            const float eq = r.eq_target_db[sub][bin];
            regularisation += s.eq_regularisation * eq * eq / static_cast<float>(p.sub_count * p.bin_count);
            if (bin > 0) {
                const float delta = eq - r.eq_target_db[sub][bin - 1];
                regularisation += s.eq_smoothness * delta * delta / static_cast<float>(p.sub_count * p.bin_count);
            }
        }
    }
    if (targetErrorOut != nullptr) *targetErrorOut = targetError;
    if (varianceOut != nullptr) *varianceOut = variance;
    return s.target_error_weight * targetError + s.seat_variance_weight * variance + regularisation;
}

bool checkProblem(const n60_correct_multisub_opt_problem *p, const n60_correct_multisub_opt_result *r) {
    if (p == nullptr || r == nullptr || p->struct_size < sizeof *p || r->struct_size < sizeof *r) return false;
    if (p->sub_count == 0 || p->sub_count > N60_CORRECT_MULTISUB_MAX_SUBS || p->seat_count == 0 || p->seat_count > 64 ||
        p->bin_count == 0 || p->bin_count > N60_CORRECT_MULTISUB_OPT_MAX_BINS)
        return false;
    if (p->frequency_hz == nullptr || p->target_db == nullptr || p->seat_weight == nullptr || p->magnitude_db == nullptr ||
        p->phase_rad == nullptr || p->arrival_frame == nullptr || p->valid == nullptr)
        return false;
    if (!std::isfinite(p->sample_rate) || !(p->sample_rate > 0.0)) return false;
    if (!n60_correct_multisub_opt_settings_valid(&p->settings)) return false;
    float previous = 0.0f;
    for (uint32_t b = 0; b < p->bin_count; ++b) {
        const float f = p->frequency_hz[b];
        if (!std::isfinite(f) || f <= previous || f >= static_cast<float>(p->sample_rate * 0.5) || !std::isfinite(p->target_db[b]))
            return false;
        previous = f;
    }
    bool any = false;
    for (uint32_t s = 0; s < p->seat_count; ++s) {
        if (!std::isfinite(p->seat_weight[s]) || p->seat_weight[s] < 0.0f) return false;
        if (p->seat_weight[s] > 0.0f) any = true;
    }
    if (!any) return false;
    for (uint32_t sub = 0; sub < p->sub_count; ++sub)
        for (uint32_t seat = 0; seat < p->seat_count; ++seat) {
            if (p->seat_weight[seat] <= 0.0f) continue;
            if (p->valid[static_cast<size_t>(sub) * p->seat_count + seat] == 0) return false;
            const size_t base = (static_cast<size_t>(sub) * p->seat_count + seat) * p->bin_count;
            for (uint32_t b = 0; b < p->bin_count; ++b)
                if (!std::isfinite(p->magnitude_db[base + b]) || !std::isfinite(p->phase_rad[base + b])) return false;
        }
    return true;
}

// Fills the [sub][seat][bin] table for the search or the EQ stage.
void fillTable(const n60_correct_multisub_opt_problem &p, const n60_correct_multisub_opt_result &r, bool applied,
               double *re, double *im) {
    for (uint32_t sub = 0; sub < p.sub_count; ++sub)
        for (uint32_t seat = 0; seat < p.seat_count; ++seat)
            for (uint32_t bin = 0; bin < p.bin_count; ++bin) {
                const size_t index = (static_cast<size_t>(sub) * p.seat_count + seat) * p.bin_count + bin;
                double a = 0.0, b = 0.0;
                if (used(p, seat))
                    contribution(p, sub, seat, bin, applied ? r.gain_db[sub] : 0.0f, applied ? r.additional_delay_ms[sub] : 0.0f,
                                 applied && r.polarity_inverted[sub] != 0, 0.0f, a, b);
                re[index] = a;
                im[index] = b;
            }
}

}  // namespace

extern "C" {

void n60_correct_multisub_opt_defaults(n60_correct_multisub_opt_settings *s) {
    if (s == nullptr) return;
    *s = n60_correct_multisub_opt_settings{};
    s->minimum_gain_db = -12.0f;
    s->maximum_gain_db = 3.0f;
    s->gain_step_db = 1.0f;
    s->maximum_additional_delay_ms = 20.0f;
    s->delay_step_ms = 0.25f;
    s->coordinate_passes = 3;
    s->target_error_weight = 1.0f;
    s->seat_variance_weight = 1.5f;
    s->boost_regularisation = 0.02f;
    s->minimum_eq_db = -8.0f;
    s->maximum_eq_db = 3.0f;
    s->eq_step_db = 1.0f;
    s->eq_passes = 2;
    s->eq_regularisation = 0.03f;
    s->eq_smoothness = 0.08f;
    s->search_starts = 12;
    s->search_rounds = 24;
    s->search_evaluation_budget = 2000000u;
    s->maximum_eq_slope_db_per_octave = 12.0f;
    s->eq_search_rounds = 8;
    s->eq_search_evaluation_budget = 4000000u;
}

int32_t n60_correct_multisub_opt_settings_valid(const n60_correct_multisub_opt_settings *s) {
    if (s == nullptr) return 0;
    const bool ok = std::isfinite(s->minimum_gain_db) && std::isfinite(s->maximum_gain_db) &&
        s->maximum_gain_db >= s->minimum_gain_db && std::isfinite(s->gain_step_db) && s->gain_step_db > 0.0f &&
        std::isfinite(s->maximum_additional_delay_ms) && s->maximum_additional_delay_ms >= 0.0f &&
        std::isfinite(s->delay_step_ms) && s->delay_step_ms > 0.0f && s->coordinate_passes > 0 && s->coordinate_passes <= 8 &&
        std::isfinite(s->target_error_weight) && s->target_error_weight > 0.0f && std::isfinite(s->seat_variance_weight) &&
        s->seat_variance_weight >= 0.0f && std::isfinite(s->boost_regularisation) && s->boost_regularisation >= 0.0f &&
        std::isfinite(s->minimum_eq_db) && std::isfinite(s->maximum_eq_db) && s->maximum_eq_db >= s->minimum_eq_db &&
        std::isfinite(s->eq_step_db) && s->eq_step_db > 0.0f && s->eq_passes <= 8 && std::isfinite(s->eq_regularisation) &&
        s->eq_regularisation >= 0.0f && std::isfinite(s->eq_smoothness) && s->eq_smoothness >= 0.0f &&
        s->search_starts >= 1 && s->search_starts <= 64 && s->search_rounds >= 1 && s->search_rounds <= 64 &&
        s->search_evaluation_budget > 0 && s->maximum_eq_db <= 3.0f && s->minimum_eq_db >= -12.0f &&
        std::isfinite(s->maximum_eq_slope_db_per_octave) && s->maximum_eq_slope_db_per_octave >= 0.0f &&
        s->eq_search_rounds >= 1 && s->eq_search_rounds <= 32 && s->eq_search_evaluation_budget > 0 &&
        (s->maximum_eq_db - s->minimum_eq_db) / s->eq_step_db < static_cast<float>(N60_CORRECT_MULTISUB_MAX_EQ_LEVELS - 1u) &&
        s->maximum_additional_delay_ms / s->delay_step_ms < static_cast<float>(N60_CORRECT_MULTISUB_MAX_DELAYS - 1u) &&
        (s->maximum_gain_db - s->minimum_gain_db) / s->gain_step_db < static_cast<float>(N60_CORRECT_MULTISUB_MAX_GAINS - 1u);
    return ok ? 1 : 0;
}

int32_t n60_correct_multisub_optimise(const n60_correct_multisub_opt_problem *problem,
                                      n60_correct_multisub_opt_result *result) {
    if (!checkProblem(problem, result)) return N60_CORRECT_ERR_ARGUMENT;
    const n60_correct_multisub_opt_problem &p = *problem;
    const n60_correct_multisub_opt_settings &s = p.settings;
    const uint32_t subs = p.sub_count, seats = p.seat_count, bins = p.bin_count;
    const size_t table = static_cast<size_t>(subs) * seats * bins;

    n60_correct_multisub_opt_result r;
    std::memset(&r, 0, sizeof r);
    r.struct_size = sizeof r;
    r.sub_count = subs;
    r.bin_count = bins;

    // Stage 1: delay, gain and polarity.
    const uint32_t delaySteps = static_cast<uint32_t>(std::floor(s.maximum_additional_delay_ms / s.delay_step_ms + 0.5f));
    const uint32_t gainSteps = static_cast<uint32_t>(std::floor((s.maximum_gain_db - s.minimum_gain_db) / s.gain_step_db + 0.5f));
    {
        Free storage;
        storage.p = std::malloc((2 * table + 2 * static_cast<size_t>(bins) + seats + delaySteps + 1u + gainSteps + 1u) * sizeof(double));
        if (storage.p == nullptr) return N60_CORRECT_ERR_ALLOC;
        double *re = static_cast<double *>(storage.p);
        double *im = re + table;
        double *frequency = im + table;
        double *target = frequency + bins;
        double *weight = target + bins;
        double *delay = weight + seats;
        double *gain = delay + delaySteps + 1u;
        fillTable(p, r, false, re, im);
        for (uint32_t b = 0; b < bins; ++b) {
            frequency[b] = p.frequency_hz[b];
            target[b] = p.target_db[b];
        }
        for (uint32_t n = 0; n < seats; ++n) weight[n] = used(p, n) ? static_cast<double>(p.seat_weight[n]) : 0.0;
        for (uint32_t k = 0; k <= delaySteps; ++k)
            delay[k] = 0.001 * static_cast<double>(std::fmin(s.maximum_additional_delay_ms, static_cast<float>(k) * s.delay_step_ms));
        for (uint32_t k = 0; k <= gainSteps; ++k)
            gain[k] = static_cast<double>(std::fmin(s.maximum_gain_db, s.minimum_gain_db + static_cast<float>(k) * s.gain_step_db));

        n60_correct_multisub_problem q;
        std::memset(&q, 0, sizeof q);
        q.struct_size = sizeof q;
        q.sub_count = subs;
        q.seat_count = seats;
        q.bin_count = bins;
        q.response_re = re;
        q.response_im = im;
        q.frequency_hz = frequency;
        q.target_db = target;
        q.seat_weight = weight;
        q.delay_seconds = delay;
        q.delay_count = delaySteps + 1u;
        q.gain_db = gain;
        q.gain_count = gainSteps + 1u;
        q.target_error_weight = s.target_error_weight;
        q.seat_variance_weight = s.seat_variance_weight;
        q.boost_regularisation = s.boost_regularisation;
        q.greedy_passes = s.coordinate_passes;
        q.starts = s.search_starts;
        q.rounds = s.search_rounds;
        q.evaluation_budget = s.search_evaluation_budget;
        n60_correct_multisub_result found;
        std::memset(&found, 0, sizeof found);
        const int32_t status = n60_correct_multisub_search(&q, &found);
        if (status != N60_CORRECT_OK) return status;
        for (uint32_t sub = 0; sub < subs; ++sub) {
            r.gain_db[sub] = static_cast<float>(gain[found.gain_index[sub]]);
            r.additional_delay_ms[sub] =
                std::fmin(s.maximum_additional_delay_ms, static_cast<float>(found.delay_index[sub]) * s.delay_step_ms);
            r.polarity_inverted[sub] = found.polarity[sub] != 0 ? 1 : 0;
        }
        r.search_evaluations = found.evaluations;
        r.search_starts_run = found.starts_run;
        r.search_budget_exhausted = found.budget_exhausted;
    }

    // Stage 2: EQ targets with gain, delay and polarity applied.
    if (s.eq_passes > 0) {
        const uint32_t eqSteps = static_cast<uint32_t>(std::floor((s.maximum_eq_db - s.minimum_eq_db) / s.eq_step_db + 0.5f));
        Free storage, foundStorage;
        storage.p = std::malloc((2 * table + 3 * static_cast<size_t>(bins) + seats + eqSteps + 1u) * sizeof(double));
        foundStorage.p = std::malloc(sizeof(n60_correct_multisub_eq_result));
        if (storage.p == nullptr || foundStorage.p == nullptr) return N60_CORRECT_ERR_ALLOC;
        auto *found = static_cast<n60_correct_multisub_eq_result *>(foundStorage.p);
        double *re = static_cast<double *>(storage.p);
        double *im = re + table;
        double *frequency = im + table;
        double *target = frequency + bins;
        double *weight = target + bins;
        double *eq = weight + seats;
        fillTable(p, r, true, re, im);
        for (uint32_t b = 0; b < bins; ++b) {
            frequency[b] = p.frequency_hz[b];
            target[b] = p.target_db[b];
        }
        for (uint32_t n = 0; n < seats; ++n) weight[n] = used(p, n) ? static_cast<double>(p.seat_weight[n]) : 0.0;
        for (uint32_t k = 0; k <= eqSteps; ++k)
            eq[k] = static_cast<double>(std::fmin(s.maximum_eq_db, s.minimum_eq_db + static_cast<float>(k) * s.eq_step_db));
        n60_correct_multisub_eq_problem q;
        std::memset(&q, 0, sizeof q);
        q.struct_size = sizeof q;
        q.sub_count = subs;
        q.seat_count = seats;
        q.bin_count = bins;
        q.response_re = re;
        q.response_im = im;
        q.frequency_hz = frequency;
        q.target_db = target;
        q.seat_weight = weight;
        q.eq_db = eq;
        q.eq_count = eqSteps + 1u;
        q.target_error_weight = s.target_error_weight;
        q.seat_variance_weight = s.seat_variance_weight;
        q.eq_regularisation = s.eq_regularisation;
        q.eq_smoothness = s.eq_smoothness;
        q.max_slope_db_per_octave = s.maximum_eq_slope_db_per_octave;
        q.null_guard_db = 10.0;
        q.passes = s.eq_passes;
        q.rounds = s.eq_search_rounds;
        q.evaluation_budget = s.eq_search_evaluation_budget;
        const int32_t status = n60_correct_multisub_eq_search(&q, found);
        if (status != N60_CORRECT_OK) return status;
        for (uint32_t sub = 0; sub < subs; ++sub)
            for (uint32_t bin = 0; bin < bins; ++bin) r.eq_target_db[sub][bin] = static_cast<float>(eq[found->eq_index[sub][bin]]);
        r.eq_search_evaluations = found->evaluations;
        r.eq_search_budget_exhausted = found->budget_exhausted;
    }

    float totalWeight = 0.0f;
    for (uint32_t n = 0; n < seats; ++n)
        if (used(p, n)) totalWeight += p.seat_weight[n];
    r.objective = objective(p, r, totalWeight, &r.weighted_target_error_db2, &r.seat_variance_db2);
    if (!std::isfinite(r.objective)) return N60_CORRECT_ERR_NONFINITE;
    *result = r;
    return N60_CORRECT_OK;
}

}  // extern "C"
