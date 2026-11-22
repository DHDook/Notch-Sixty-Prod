// E21 S7b: behavioural harness for n60_correct_multisub_optimise (n60/correct.h section 9), through the C ABI, for 1 to 8
// subs at the eight standard device rates. References are written here: the objective is recomputed from the returned
// settings with an independent double-precision evaluator, never from the implementation.
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/correct.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

struct Fixture {
    uint32_t subs, seats = 3, bins = 40;
    double rate;
    std::vector<float> freq, target, weight, mag, phase;
    std::vector<uint32_t> arrival;
    std::vector<uint8_t> valid;
    n60_correct_multisub_opt_problem p{};
};

static void build(Fixture &f, uint32_t subs, double rate) {
    f.subs = subs;
    f.rate = rate;
    for (uint32_t b = 0; b < f.bins; ++b) {
        f.freq.push_back(static_cast<float>(20.0 * std::pow(180.0 / 20.0, b / 39.0)));
        f.target.push_back(-2.0f);
    }
    f.weight = {1.0f, 0.5f, 0.75f};
    for (uint32_t s = 0; s < subs; ++s)
        for (uint32_t n = 0; n < f.seats; ++n) {
            f.arrival.push_back(static_cast<uint32_t>(rate * (0.006 + 0.0007 * s + 0.0003 * n)));
            f.valid.push_back(1);
            for (uint32_t b = 0; b < f.bins; ++b) {
                f.mag.push_back(-4.0f + 0.8f * s + 6.0f * std::exp(-std::pow((b - 12.0 - 3 * n) / 5.0, 2)));
                f.phase.push_back(static_cast<float>(0.2 * s - 0.01 * b + 0.1 * n));
            }
        }
    f.p.struct_size = sizeof f.p;
    f.p.sub_count = subs;
    f.p.seat_count = f.seats;
    f.p.bin_count = f.bins;
    f.p.sample_rate = rate;
    f.p.frequency_hz = f.freq.data();
    f.p.target_db = f.target.data();
    f.p.seat_weight = f.weight.data();
    f.p.magnitude_db = f.mag.data();
    f.p.phase_rad = f.phase.data();
    f.p.arrival_frame = f.arrival.data();
    f.p.valid = f.valid.data();
    n60_correct_multisub_opt_defaults(&f.p.settings);
    f.p.settings.maximum_gain_db = 0;
    f.p.settings.maximum_eq_db = 0;
}

// Independent evaluator: seat levels from the returned settings, double precision.
static double referenceObjective(const Fixture &f, const n60_correct_multisub_opt_result &r) {
    const auto &s = f.p.settings;
    double total = 0;
    for (float w : f.weight) total += w;
    double err = 0, var = 0;
    for (uint32_t b = 0; b < f.bins; ++b) {
        std::vector<double> db(f.seats);
        double mean = 0;
        for (uint32_t n = 0; n < f.seats; ++n) {
            double re = 0, im = 0;
            for (uint32_t u = 0; u < f.subs; ++u) {
                const size_t at = (static_cast<size_t>(u) * f.seats + n) * f.bins + b;
                const double m = std::pow(10.0, (f.mag[at] + r.gain_db[u] + r.eq_target_db[u][b]) / 20.0);
                double ph = f.phase[at] - 2 * M_PI * f.freq[b] * (f.arrival[u * f.seats + n] / f.rate + r.additional_delay_ms[u] * 1e-3);
                if (r.polarity_inverted[u]) ph += M_PI;
                re += m * std::cos(ph);
                im += m * std::sin(ph);
            }
            db[n] = 20 * std::log10(std::fmax(std::hypot(re, im), 1e-12));
            mean += db[n] * f.weight[n] / total;
        }
        for (uint32_t n = 0; n < f.seats; ++n) {
            const double w = f.weight[n] / total;
            var += w * (db[n] - mean) * (db[n] - mean) / f.bins;
            err += w * (db[n] - f.target[b]) * (db[n] - f.target[b]) / f.bins;
        }
    }
    double reg = 0;
    for (uint32_t u = 0; u < f.subs; ++u) {
        reg += s.boost_regularisation * std::pow(std::fmax(0.0f, r.gain_db[u]), 2);
        for (uint32_t b = 0; b < f.bins; ++b) {
            reg += s.eq_regularisation * r.eq_target_db[u][b] * r.eq_target_db[u][b] / (f.subs * f.bins);
            if (b) {
                const double d = r.eq_target_db[u][b] - r.eq_target_db[u][b - 1];
                reg += s.eq_smoothness * d * d / (f.subs * f.bins);
            }
        }
    }
    return s.target_error_weight * err + s.seat_variance_weight * var + reg;
}

static void testParity() {
    for (double rate : kRates)
        for (uint32_t subs = 1; subs <= 8; ++subs) {
            Fixture f;
            build(f, subs, rate);
            n60_correct_multisub_opt_result a{}, b{};
            a.struct_size = b.struct_size = sizeof a;
            CHECK(n60_correct_multisub_optimise(&f.p, &a) == N60_CORRECT_OK, "optimise %g Hz, %u subs", rate, subs);
            CHECK(n60_correct_multisub_optimise(&f.p, &b) == N60_CORRECT_OK, "second run");
            CHECK(a.objective == b.objective && std::memcmp(a.eq_target_db, b.eq_target_db, sizeof a.eq_target_db) == 0,
                  "deterministic %g Hz, %u subs", rate, subs);
            const double ref = referenceObjective(f, a);
            CHECK(std::fabs(ref - a.objective) <= 1e-3 * std::fmax(1.0, ref), "objective %g vs %g (%g Hz, %u subs)", a.objective, ref, rate, subs);
            CHECK(a.sub_count == subs && a.bin_count == f.bins, "counts");
            float smallest = 1e9f;
            for (uint32_t u = 0; u < subs; ++u) {
                smallest = std::fmin(smallest, a.additional_delay_ms[u]);
                CHECK(a.gain_db[u] >= -12.0f && a.gain_db[u] <= 0.0f, "gain range");
                CHECK(a.additional_delay_ms[u] >= 0 && a.additional_delay_ms[u] <= 20.0f, "delay range");
                for (uint32_t k = 0; k < f.bins; ++k) CHECK(a.eq_target_db[u][k] >= -8.0f && a.eq_target_db[u][k] <= 0.0f, "eq range");
            }
            CHECK(smallest == 0.0f, "smallest delay shifted to 0 (%g)", smallest);
            // Optimising must not be worse than doing nothing (all gains 0, no delay, no EQ).
            n60_correct_multisub_opt_result zero{};
            zero.sub_count = subs;
            CHECK(referenceObjective(f, a) <= referenceObjective(f, zero) + 1e-9, "better than untreated");
        }
}

static void testEqOff() {
    Fixture f;
    build(f, 3, 48000);
    f.p.settings.eq_passes = 0;
    n60_correct_multisub_opt_result r{};
    r.struct_size = sizeof r;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_OK, "eq off");
    bool zero = true;
    for (uint32_t u = 0; u < 3; ++u)
        for (uint32_t b = 0; b < f.bins; ++b) zero = zero && r.eq_target_db[u][b] == 0.0f;
    CHECK(zero && r.eq_search_evaluations == 0, "EQ stage skipped");
}

static void testIterationCap() {
    Fixture f;
    build(f, 4, 96000);
    f.p.settings.search_starts = 64;
    f.p.settings.search_rounds = 64;
    f.p.settings.search_evaluation_budget = 3000;
    f.p.settings.eq_search_evaluation_budget = 3000;
    n60_correct_multisub_opt_result r{};
    r.struct_size = sizeof r;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_OK, "capped");
    CHECK(r.search_budget_exhausted == 1, "delay search budget stops the search");
    CHECK(r.search_starts_run < 64, "starts run %u below the 64 asked for", r.search_starts_run);
    // The budget is checked between rounds, so the overshoot is bounded by one round, not unbounded.
    CHECK(r.search_evaluations < 3000u * 20u, "evaluations %llu bounded", static_cast<unsigned long long>(r.search_evaluations));
    CHECK(r.eq_search_budget_exhausted == 1, "EQ budget stops the search");
    CHECK(std::isfinite(r.objective), "finite result at the cap");
    // A larger budget never gives a worse objective.
    f.p.settings.search_evaluation_budget = 2000000u;
    f.p.settings.eq_search_evaluation_budget = 4000000u;
    n60_correct_multisub_opt_result full{};
    full.struct_size = sizeof full;
    CHECK(n60_correct_multisub_optimise(&f.p, &full) == N60_CORRECT_OK, "uncapped");
    CHECK(full.objective <= r.objective + 1e-4f, "uncapped %g not worse than capped %g", full.objective, r.objective);
}

static void testExcludedSeatAndErrors() {
    Fixture f;
    build(f, 2, 48000);
    f.weight[1] = 0.0f;
    f.valid[0 * f.seats + 1] = 0;  // an excluded seat may have an invalid response
    f.valid[1 * f.seats + 1] = 0;
    n60_correct_multisub_opt_result r{};
    r.struct_size = sizeof r;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_OK, "excluded seat with invalid response");
    f.valid[0] = 0;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_ERR_ARGUMENT, "invalid used response");
    f.valid[0] = 1;
    f.weight = {0.0f, 0.0f, 0.0f};
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_ERR_ARGUMENT, "no weight");
    f.weight = {1.0f, 1.0f, 1.0f};
    f.p.sub_count = 9;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_ERR_ARGUMENT, "nine subs");
    f.p.sub_count = 2;
    f.p.settings.gain_step_db = 0.0f;
    CHECK(n60_correct_multisub_optimise(&f.p, &r) == N60_CORRECT_ERR_ARGUMENT, "bad settings");
    CHECK(n60_correct_multisub_optimise(nullptr, &r) == N60_CORRECT_ERR_ARGUMENT, "null");
    n60_correct_multisub_opt_settings d{};
    n60_correct_multisub_opt_defaults(&d);
    CHECK(n60_correct_multisub_opt_settings_valid(&d) == 1, "defaults valid");
    d.minimum_eq_db = -20.0f;
    CHECK(n60_correct_multisub_opt_settings_valid(&d) == 0, "EQ floor below -12 dB");
}

int main() {
    testParity();
    testEqOff();
    testIterationCap();
    testExcludedSeatAndErrors();
    if (failures) { std::fprintf(stderr, "%d failures\n", failures); return 1; }
    std::puts("ok");
    return 0;
}
