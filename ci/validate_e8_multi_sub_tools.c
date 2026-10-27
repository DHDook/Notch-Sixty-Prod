// E8 A4/A6a: the multi-sub optimiser and calibration matrix cover 8 subwoofers, and the delay, gain and polarity
// search is the deterministic multi-start search of n60/correct.h section 6.
//
// Synthetic rooms (modal magnitude per sub and seat, per-sub arrival, wiring polarity) are generated at each
// standard rate. Checks: never worse than the A4 greedy search (ci/reference), within 0.1 dB^2 of brute force on
// the delay/polarity grid, constraints (grid, minimum delay 0, delay span bound, hold-out on a denser bin grid),
// determinism, the compute bound, recorded goldens (--print-goldens regenerates them), the 7-8-sub subset rule
// and the 9-sub refusal.
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "N60MultiSubOptimizer.h"
#include "reference/n60_multisub_greedy_reference.h"

#define MAXBINS 128u
#define BINS 8u
#define SEATS 4u

static const double kRates[8] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const float kFrequencies[BINS] = {30, 40, 50, 60, 70, 80, 90, 100};

typedef struct {
    double depthDB;       // modal ripple depth
    double seatDelayMs;   // arrival offset per seat
    double staggerMs;     // arrival offset per sub (sub % 4)
    uint32_t wiringSeed;  // 0: alternating wiring polarity; else seeded random wiring
} Room;

static const Room kRooms[3] = {{0.0, 0.0, 0.0, 0}, {3.0, 0.2, 0.0, 0}, {3.0, 0.2, 1.0, 0}};

static uint64_t splitmix(uint64_t *x) {
    *x += 0x9E3779B97F4A7C15ull;
    uint64_t z = *x;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static double unit(uint64_t *x) { return (double)(splitmix(x) >> 11) * (1.0 / 9007199254740992.0); }

static Room seeded_room(uint32_t seed) {
    uint64_t x = 0xA6A0000000ull + seed;
    Room r;
    r.depthDB = 0.5 + 5.5 * unit(&x);
    r.seatDelayMs = 0.5 * unit(&x);
    r.staggerMs = 2.0 * unit(&x);
    r.wiringSeed = seed + 1u;
    return r;
}

static N60MultichannelCalibrationMatrix make_room_ext(
    double rate, uint32_t subs, Room room, uint32_t seats, const float *freqs, uint32_t bins
) {
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60MultichannelCalibrationMatrix m = N60MultichannelCalibrationMatrixMake(rate, stereo, subs, seats, freqs, bins);
    assert(m.sourceCount == 2u + subs);
    float mag[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    float phase[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    uint64_t wiring = 0x5EED0000ull + room.wiringSeed;
    bool inverted[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
    for (uint32_t sub = 0; sub < subs; ++sub) {
        inverted[sub] = room.wiringSeed == 0u ? (sub % 2u) != 0u : (splitmix(&wiring) & 1u) != 0u;
    }
    for (uint32_t seat = 0; seat < seats; ++seat) {
        for (uint32_t s = 0; s < 2u; ++s) {
            assert(N60MultichannelCalibrationSetResponse(&m, s, seat, 0u, 1, 0.0f, mag, phase));
        }
        for (uint32_t sub = 0; sub < subs; ++sub) {
            for (uint32_t f = 0; f < bins; ++f) {
                mag[f] = -6.0f + (float)room.depthDB * cosf(2.0f * (float)M_PI * freqs[f] / 60.0f + (float)seat + 0.15f * (float)sub);
                phase[f] = inverted[sub] ? (float)M_PI : 0.0f;
            }
            const double arrival = 0.004 + 0.001 * room.staggerMs * (double)(sub % 4u) + 0.001 * room.seatDelayMs * (double)seat;
            assert(N60MultichannelCalibrationSetResponse(
                &m, 2u + sub, seat, (uint32_t)llround(arrival * rate), 1, -6.0f, mag, phase));
        }
    }
    assert(N60MultichannelCalibrationMatrixIsValid(&m, subs));
    return m;
}

static N60MultichannelCalibrationMatrix make_room(double rate, uint32_t subs, Room room) {
    return make_room_ext(rate, subs, room, SEATS, kFrequencies, BINS);
}

static N60MultiSubOptimizationSettings grid_settings(void) {
    N60MultiSubOptimizationSettings s = N60MultiSubOptimizationSettingsMakeDefault();
    s.minimumGainDB = 0.0f;
    s.maximumGainDB = 0.0f;
    s.maximumAdditionalDelayMs = 3.0f;
    s.delayStepMs = 1.0f;
    s.coordinatePasses = 4u;
    s.eqPasses = 0u;
    return s;
}

static N60MultiSubOptimizationSettings search_only_defaults(void) {
    N60MultiSubOptimizationSettings s = N60MultiSubOptimizationSettingsMakeDefault();
    s.eqPasses = 0u;
    return s;
}

static float objective_of(
    const N60MultichannelCalibrationMatrix *m, uint32_t subs, const float *target,
    const N60MultiSubOptimizationSettings *settings, const N60MultiSubOptimizationResult *r
) {
    uint32_t idx[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
    assert(N60MultiSubFindSourceIndices(m, subs, idx));
    return N60MultiSubEvaluateObjective(m, idx, subs, target, settings, r, NULL, NULL);
}

static float greedy_objective(
    const N60MultichannelCalibrationMatrix *m, uint32_t subs, const float *target,
    const N60MultiSubOptimizationSettings *settings, N60MultiSubOptimizationResult *out
) {
    uint32_t idx[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
    assert(N60MultiSubFindSourceIndices(m, subs, idx));
    N60MultiSubOptimizationResult g = {0};
    g.subwooferCount = subs;
    g.frequencyCount = m->frequencyCount;
    N60MultiSubGreedyReference(m, idx, subs, target, settings, &g);
    if (out != NULL) *out = g;
    return objective_of(m, subs, target, settings, &g);
}

static float brute_force(
    const N60MultichannelCalibrationMatrix *m, uint32_t subs, const float *target,
    const N60MultiSubOptimizationSettings *settings
) {
    uint64_t total = 1;
    for (uint32_t i = 0; i < subs; ++i) total *= 8u; // 4 delays x 2 polarities
    float bestObjective = INFINITY;
    for (uint64_t code = 0; code < total; ++code) {
        N60MultiSubOptimizationResult c = {0};
        c.subwooferCount = subs;
        c.frequencyCount = m->frequencyCount;
        uint64_t rest = code;
        for (uint32_t sub = 0; sub < subs; ++sub) {
            c.polarityInverted[sub] = (rest & 1u) != 0u;
            c.additionalDelayMs[sub] = (float)((rest >> 1) & 3u);
            rest >>= 3;
        }
        const float o = objective_of(m, subs, target, settings, &c);
        if (o < bestObjective) bestObjective = o;
    }
    return bestObjective;
}

static bool not_worse(float newer, float older) { return newer <= older * 1.00001f + 1.0e-4f; }

static void check_never_worse(double rate, uint32_t subs, Room room, const N60MultiSubOptimizationSettings *settings, const char *tag) {
    N60MultichannelCalibrationMatrix m = make_room(rate, subs, room);
    const float target[BINS] = {0};
    N60MultiSubOptimizationResult r = {0};
    assert(N60MultiSubOptimize(&m, subs, target, *settings, &r));
    const float greedy = greedy_objective(&m, subs, target, settings, NULL);
    if (!not_worse(r.objective, greedy)) {
        fprintf(stderr, "%s rate %.0f subs %u: new %f greedy %f\n", tag, rate, subs, r.objective, greedy);
        assert(false);
    }
}

static void check_constraints(const N60MultiSubOptimizationResult *r, uint32_t subs, const N60MultiSubOptimizationSettings *s, float spanLimitMs) {
    float minDelay = INFINITY, maxDelay = 0.0f;
    for (uint32_t sub = 0; sub < subs; ++sub) {
        const float steps = r->additionalDelayMs[sub] / s->delayStepMs;
        assert(fabsf(steps - roundf(steps)) < 1.0e-3f || r->additionalDelayMs[sub] == s->maximumAdditionalDelayMs);
        assert(r->gainDB[sub] >= s->minimumGainDB && r->gainDB[sub] <= s->maximumGainDB);
        const float gsteps = (r->gainDB[sub] - s->minimumGainDB) / s->gainStepDB;
        assert(fabsf(gsteps - roundf(gsteps)) < 1.0e-3f || r->gainDB[sub] == s->maximumGainDB);
        minDelay = fminf(minDelay, r->additionalDelayMs[sub]);
        maxDelay = fmaxf(maxDelay, r->additionalDelayMs[sub]);
    }
    assert(minDelay == 0.0f);
    assert(maxDelay - minDelay <= spanLimitMs + 1.0e-4f);
}

static void check_against_brute_force(double rate, uint32_t subs, Room room) {
    N60MultichannelCalibrationMatrix m = make_room(rate, subs, room);
    const float target[BINS] = {0};
    N60MultiSubOptimizationSettings settings = grid_settings();
    N60MultiSubOptimizationResult optimized = {0};
    assert(N60MultiSubOptimize(&m, subs, target, settings, &optimized));
    const float bestObjective = brute_force(&m, subs, target, &settings);
    if (!(optimized.objective <= bestObjective + 0.1f)) {
        fprintf(stderr, "rate %.0f subs %u depth %f seat %f stag %f wiring %u: optimiser %f brute force %f\n", rate, subs, room.depthDB, room.seatDelayMs, room.staggerMs, room.wiringSeed, optimized.objective, bestObjective);
        assert(false);
    }
    check_constraints(&optimized, subs, &settings, 3.0f);
    for (uint32_t sub = 0; sub < subs; ++sub) assert(optimized.gainDB[sub] == 0.0f);
}

static void check_holdout(double rate, uint32_t subs, Room room, const N60MultiSubOptimizationSettings *settings) {
    // Optimise on the 8 measured bins; judge on a 4x denser grid of the same analytic room.
    float dense[4u * BINS];
    for (uint32_t i = 0; i < 4u * BINS; ++i) dense[i] = 30.0f + 70.0f * (float)i / (float)(4u * BINS - 1u);
    N60MultichannelCalibrationMatrix coarse = make_room(rate, subs, room);
    N60MultichannelCalibrationMatrix fine = make_room_ext(rate, subs, room, SEATS, dense, 4u * BINS);
    const float target[4u * BINS] = {0};
    N60MultiSubOptimizationResult r = {0};
    assert(N60MultiSubOptimize(&coarse, subs, target, *settings, &r));
    N60MultiSubOptimizationResult g = {0};
    greedy_objective(&coarse, subs, target, settings, &g);
    const float fineNew = objective_of(&fine, subs, target, settings, &r);
    const float fineGreedy = objective_of(&fine, subs, target, settings, &g);
    if (!(fineNew <= 1.1f * fineGreedy + 0.1f)) {
        fprintf(stderr, "hold-out rate %.0f subs %u: new %f greedy %f\n", rate, subs, fineNew, fineGreedy);
        assert(false);
    }
}

static bool same_design(const N60MultiSubOptimizationResult *a, const N60MultiSubOptimizationResult *b, uint32_t subs) {
    return memcmp(a->gainDB, b->gainDB, subs * sizeof(float)) == 0
        && memcmp(a->additionalDelayMs, b->additionalDelayMs, subs * sizeof(float)) == 0
        && memcmp(a->polarityInverted, b->polarityInverted, subs * sizeof(bool)) == 0
        && memcmp(&a->objective, &b->objective, sizeof(float)) == 0
        && memcmp(a->perSubEQTargetDB, b->perSubEQTargetDB, sizeof a->perSubEQTargetDB) == 0
        && a->searchEvaluations == b->searchEvaluations;
}

static void check_large_counts(double rate, uint32_t subs, Room room) {
    N60MultichannelCalibrationMatrix m = make_room(rate, subs, room);
    const float target[BINS] = {0};
    N60MultiSubOptimizationSettings settings = grid_settings();
    N60MultiSubOptimizationResult a = {0}, b = {0};
    assert(N60MultiSubOptimize(&m, subs, target, settings, &a));
    assert(N60MultiSubOptimize(&m, subs, target, settings, &b));
    assert(a.subwooferCount == subs);
    assert(isfinite(a.objective));
    assert(same_design(&a, &b, subs)); // deterministic

    // Seat variance no worse than the best 4-sub subset (4 consecutive subs of the same room, optimised alone).
    float bestSubsetVariance = INFINITY;
    for (uint32_t first = 0; first + 4u <= subs; ++first) {
        N60MultichannelCalibrationMatrix four = make_room(rate, 4u, room);
        for (uint32_t k = 0; k < 4u; ++k) {
            for (uint32_t seat = 0; seat < SEATS; ++seat) {
                four.responses[2u + k][seat] = m.responses[2u + first + k][seat];
            }
        }
        N60MultiSubOptimizationResult r = {0};
        assert(N60MultiSubOptimize(&four, 4u, target, settings, &r));
        uint32_t idx[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
        assert(N60MultiSubFindSourceIndices(&four, 4u, idx));
        float err = 0, var = 0;
        N60MultiSubEvaluateObjective(&four, idx, 4u, target, &settings, &r, &err, &var);
        if (var < bestSubsetVariance) bestSubsetVariance = var;
    }
    uint32_t idx[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
    assert(N60MultiSubFindSourceIndices(&m, subs, idx));
    float err = 0, var = 0;
    N60MultiSubEvaluateObjective(&m, idx, subs, target, &settings, &a, &err, &var);
    if (!(var <= bestSubsetVariance + 0.1f)) {
        fprintf(stderr, "rate %.0f subs %u: variance %f best 4-sub subset %f\n", rate, subs, var, bestSubsetVariance);
        assert(false);
    }

    // Default settings with the EQ stage also complete and stay finite with 8 subs.
    N60MultiSubOptimizationSettings full = N60MultiSubOptimizationSettingsMakeDefault();
    N60MultiSubOptimizationResult f = {0};
    assert(N60MultiSubOptimize(&m, subs, target, full, &f));
    assert(isfinite(f.objective));
    for (uint32_t sub = 0; sub < subs; ++sub) {
        for (uint32_t bin = 0; bin < BINS; ++bin) assert(isfinite(f.perSubEQTargetDB[sub][bin]));
    }
}

static void check_sparse_bins(void) {
    // Bin spacing 20 Hz: a phase wrap between bins is invisible beyond 0.5 / 20 Hz = 25 ms.
    float sparse[BINS];
    for (uint32_t i = 0; i < BINS; ++i) sparse[i] = 40.0f + 20.0f * (float)i;
    N60MultiSubOptimizationSettings s = N60MultiSubOptimizationSettingsMakeDefault();
    s.maximumAdditionalDelayMs = 60.0f;
    s.eqPasses = 0u;
    for (uint32_t subs = 2u; subs <= 6u; subs += 2u) {
        for (uint32_t k = 0; k < 4u; ++k) {
            N60MultichannelCalibrationMatrix m = make_room_ext(48000.0, subs, k == 0 ? kRooms[2] : seeded_room(40u + k), SEATS, sparse, BINS);
            const float target[BINS] = {0};
            N60MultiSubOptimizationResult r = {0};
            assert(N60MultiSubOptimize(&m, subs, target, s, &r));
            check_constraints(&r, subs, &s, 25.0f);
        }
    }
}

static void check_compute_bound(void) {
    // 8 subs x 8 seats x 128 bins at defaults.
    float freqs[MAXBINS];
    for (uint32_t i = 0; i < MAXBINS; ++i) freqs[i] = 20.0f + (float)i;
    N60MultichannelCalibrationMatrix m = make_room_ext(48000.0, 8u, kRooms[2], 8u, freqs, MAXBINS);
    float target[MAXBINS] = {0};
    N60MultiSubOptimizationSettings s = N60MultiSubOptimizationSettingsMakeDefault();
    s.eqPasses = 0u;
    N60MultiSubOptimizationResult r = {0};
    const clock_t t0 = clock();
    assert(N60MultiSubOptimize(&m, 8u, target, s, &r));
    const double seconds = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("benchmark multisub search 8 subs x 8 seats x 128 bins: %.3f s, %llu candidate evaluations, %u starts\n",
        seconds, (unsigned long long)r.searchEvaluations, r.searchStartsRun);
    assert(r.searchEvaluations > 0u);
    assert(r.searchEvaluations <= (uint64_t)s.searchEvaluationBudget + 10000u); // stops between rounds
    // A budget of 1000: flagged, and still no worse than the greedy phase.
    N60MultiSubOptimizationSettings tiny = s;
    tiny.searchEvaluationBudget = 1000u;
    N60MultiSubOptimizationResult t = {0};
    assert(N60MultiSubOptimize(&m, 8u, target, tiny, &t));
    assert(t.searchBudgetExhausted);
    assert(t.searchStartsRun == 1u);
    const float greedy = greedy_objective(&m, 8u, target, &tiny, NULL);
    assert(not_worse(t.objective, greedy));
}

// ---- goldens -------------------------------------------------------------------------------------------------

#include "golden_e8_multi_sub_search.inc"

static void golden_run(uint32_t subs, uint32_t room, uint32_t rateIndex, uint32_t eq, N60MultiSubOptimizationResult *r) {
    N60MultichannelCalibrationMatrix m = make_room(kRates[rateIndex], subs, kRooms[room]);
    const float target[BINS] = {0};
    N60MultiSubOptimizationSettings s = N60MultiSubOptimizationSettingsMakeDefault();
    if (!eq) s.eqPasses = 0u;
    memset(r, 0, sizeof *r);
    assert(N60MultiSubOptimize(&m, subs, target, s, r));
}

static void print_goldens(void) {
    printf("// Generated by `validate_e8_multi_sub_tools --print-goldens` (E8 A6a). Regenerate only on purpose.\n");
    printf("typedef struct { uint8_t subs, room, rate, eq; float gain[4]; float delay[4]; uint8_t polarity[4]; double objective; } GoldenCase;\n");
    printf("static const GoldenCase kGoldens[] = {\n");
    const uint32_t rates[2] = {1u, 7u};
    for (uint32_t subs = 1; subs <= 4; ++subs)
        for (uint32_t room = 0; room < 3; ++room)
            for (uint32_t ri = 0; ri < 2; ++ri)
                for (uint32_t eq = 0; eq < 2; ++eq) {
                    N60MultiSubOptimizationResult r;
                    golden_run(subs, room, rates[ri], eq, &r);
                    printf("    {%u, %u, %u, %u, {", subs, room, rates[ri], eq);
                    for (uint32_t i = 0; i < 4; ++i) printf("%.9ef%s", i < subs ? r.gainDB[i] : 0.0f, i < 3 ? ", " : "");
                    printf("}, {");
                    for (uint32_t i = 0; i < 4; ++i) printf("%.9ef%s", i < subs ? r.additionalDelayMs[i] : 0.0f, i < 3 ? ", " : "");
                    printf("}, {");
                    for (uint32_t i = 0; i < 4; ++i) printf("%u%s", i < subs && r.polarityInverted[i] ? 1u : 0u, i < 3 ? ", " : "");
                    printf("}, %.9g},\n", (double)r.objective);
                }
    printf("};\n");
}

static void check_goldens(void) {
    const size_t count = sizeof kGoldens / sizeof kGoldens[0];
    assert(count == 4u * 3u * 2u * 2u);
    for (size_t c = 0; c < count; ++c) {
        const GoldenCase *g = &kGoldens[c];
        N60MultiSubOptimizationResult r;
        golden_run(g->subs, g->room, g->rate, g->eq, &r);
        for (uint32_t i = 0; i < g->subs; ++i) {
            if (r.gainDB[i] != g->gain[i] || r.additionalDelayMs[i] != g->delay[i]
                || (uint8_t)r.polarityInverted[i] != g->polarity[i]) {
                fprintf(stderr, "golden %zu (subs %u room %u rate %u eq %u) sub %u differs\n", c, g->subs, g->room, g->rate, g->eq, i);
                assert(false);
            }
        }
        if (fabs((double)r.objective - g->objective) > 1.0e-4 * (1.0 + fabs(g->objective))) {
            fprintf(stderr, "golden %zu objective %f expected %f\n", c, r.objective, g->objective);
            assert(false);
        }
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--print-goldens") == 0) {
        print_goldens();
        return 0;
    }
    assert(N60_CALIBRATION_MAX_SUBWOOFERS == 8u);
    assert(N60_MAX_SUBWOOFER_OUTPUTS == 4u); // the legacy kernel's limit is unchanged
    assert(N60_CALIBRATION_MAX_SOURCES >= N60_MAX_PROGRAM_CHANNELS + 8u);
    const N60MultiSubOptimizationSettings grid = grid_settings();
    const N60MultiSubOptimizationSettings defaults = search_only_defaults();

    for (uint32_t r = 0; r < 8u; ++r) {
        for (uint32_t st = 0; st < 3u; ++st) {
            for (uint32_t subs = 1u; subs <= 8u; ++subs) {
                check_never_worse(kRates[r], subs, kRooms[st], &grid, "grid");
                check_never_worse(kRates[r], subs, kRooms[st], &defaults, "defaults");
            }
            for (uint32_t subs = 1u; subs <= 5u; ++subs) check_against_brute_force(kRates[r], subs, kRooms[st]);
            check_large_counts(kRates[r], 7u, kRooms[st]);
            check_large_counts(kRates[r], 8u, kRooms[st]);
            check_holdout(kRates[r], 4u, kRooms[st], &grid);
            check_holdout(kRates[r], 4u, kRooms[st], &defaults);
        }
    }
    for (uint32_t st = 0; st < 3u; ++st) check_against_brute_force(48000.0, 6u, kRooms[st]);

    // Seeded random rooms at 48 kHz: 16 per count, never worse; brute force for 1-4 subs.
    for (uint32_t seed = 0; seed < 16u; ++seed) {
        const Room room = seeded_room(seed);
        for (uint32_t subs = 1u; subs <= 8u; ++subs) {
            check_never_worse(48000.0, subs, room, &grid, "seeded grid");
            check_never_worse(48000.0, subs, room, &defaults, "seeded defaults");
        }
        for (uint32_t subs = 1u; subs <= 4u; ++subs) check_against_brute_force(48000.0, subs, room);
        check_holdout(48000.0, 4u, room, &defaults);
    }

    check_sparse_bins();
    check_compute_bound();
    check_goldens();

    // Calling 8, 1, then 8 subs gives the same 8-sub bits.
    {
        N60MultichannelCalibrationMatrix eight = make_room(48000.0, 8u, kRooms[2]);
        N60MultichannelCalibrationMatrix one = make_room(48000.0, 1u, kRooms[2]);
        const float target[BINS] = {0};
        N60MultiSubOptimizationResult a = {0}, b = {0}, c = {0};
        assert(N60MultiSubOptimize(&eight, 8u, target, defaults, &a));
        assert(N60MultiSubOptimize(&one, 1u, target, defaults, &c));
        assert(N60MultiSubOptimize(&eight, 8u, target, defaults, &b));
        assert(same_design(&a, &b, 8u));
    }

    // Nine subs are refused by the matrix and the optimiser.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60MultichannelCalibrationMatrix nine = N60MultichannelCalibrationMatrixMake(
        48000.0, stereo, 9u, SEATS, kFrequencies, BINS);
    assert(nine.sourceCount == 0u || !N60MultichannelCalibrationMatrixIsValid(&nine, 9u));
    N60MultiSubOptimizationResult unused = {0};
    const float target[BINS] = {0};
    N60MultichannelCalibrationMatrix eight = make_room(48000.0, 8u, kRooms[0]);
    assert(!N60MultiSubOptimize(&eight, 9u, target, grid_settings(), &unused));
    // Invalid new settings are refused.
    N60MultiSubOptimizationSettings bad = grid_settings();
    bad.searchStarts = 0u;
    assert(!N60MultiSubOptimize(&eight, 8u, target, bad, &unused));
    bad = grid_settings();
    bad.searchRounds = 65u;
    assert(!N60MultiSubOptimize(&eight, 8u, target, bad, &unused));
    return 0;
}
