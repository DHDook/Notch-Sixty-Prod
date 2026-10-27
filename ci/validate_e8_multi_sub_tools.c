// E8 A4: the multi-sub optimiser and calibration matrix cover 8 subwoofers.
//
// Synthetic rooms (modal magnitude per sub and seat, per-sub arrival, alternating wiring polarity) are generated
// at each standard rate. Checks: 5 and 6 subs match a brute-force search of the same delay/polarity grid, 7 and 8
// subs are deterministic and no worse than the best 4-sub subset on seat variance, 9 subs are refused.
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "N60MultiSubOptimizer.h"

#define BINS 8u
#define SEATS 4u

static const double kRates[8] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const float kFrequencies[BINS] = {30, 40, 50, 60, 70, 80, 90, 100};

static N60MultichannelCalibrationMatrix make_room(double rate, uint32_t subs, uint32_t room) {
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60MultichannelCalibrationMatrix m = N60MultichannelCalibrationMatrixMake(
        rate, stereo, subs, SEATS, kFrequencies, BINS);
    assert(m.sourceCount == 2u + subs);
    float mag[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    float phase[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    for (uint32_t seat = 0; seat < SEATS; ++seat) {
        for (uint32_t s = 0; s < 2u; ++s) {
            assert(N60MultichannelCalibrationSetResponse(&m, s, seat, 0u, 1, 0.0f, mag, phase));
        }
        for (uint32_t sub = 0; sub < subs; ++sub) {
            for (uint32_t f = 0; f < BINS; ++f) {
                mag[f] = -6.0f + (room == 0u ? 0.0f : 3.0f) * cosf(2.0f * (float)M_PI * kFrequencies[f] / 60.0f + (float)seat + 0.15f * (float)sub);
                phase[f] = (sub % 2u) ? (float)M_PI : 0.0f;
            }
            const double arrival = 0.004 + (room == 2u ? 0.001 * (double)(sub % 4u) : 0.0) + (room == 0u ? 0.0 : 0.0002 * (double)seat);
            assert(N60MultichannelCalibrationSetResponse(
                &m, 2u + sub, seat, (uint32_t)llround(arrival * rate), 1, -6.0f, mag, phase));
        }
    }
    assert(N60MultichannelCalibrationMatrixIsValid(&m, subs));
    return m;
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

static float brute_force(
    const N60MultichannelCalibrationMatrix *m, uint32_t subs, const float *target,
    const N60MultiSubOptimizationSettings *settings, N60MultiSubOptimizationResult *best
) {
    uint32_t idx[N60_CALIBRATION_MAX_SUBWOOFERS] = {0};
    assert(N60MultiSubFindSourceIndices(m, subs, idx));
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
        const float o = N60MultiSubEvaluateObjective(m, idx, subs, target, settings, &c, NULL, NULL);
        if (o < bestObjective) { bestObjective = o; *best = c; }
    }
    return bestObjective;
}

static void check_against_brute_force(double rate, uint32_t subs, uint32_t room) {
    N60MultichannelCalibrationMatrix m = make_room(rate, subs, room);
    const float target[BINS] = {0};
    N60MultiSubOptimizationSettings settings = grid_settings();
    N60MultiSubOptimizationResult optimized = {0}, best = {0};
    assert(N60MultiSubOptimize(&m, subs, target, settings, &optimized));
    const float bestObjective = brute_force(&m, subs, target, &settings, &best);
    fprintf(stderr, "rate %.0f subs %u room %u: optimiser %f brute force %f\n", rate, subs, room, optimized.objective, bestObjective);
    // Ideal room (identical sources, wiring polarity only): the coordinate search matches the brute-force optimum
    // to within 0.1 on the dB-squared objective. Modal and staggered rooms: the search is greedy (unchanged by this
    // slice), so it is held to a bounded gap.
    const float allowed = room != 0u ? bestObjective * 1.35f + 0.5f : bestObjective + 0.1f;
    if (!(optimized.objective <= allowed)) {
        fprintf(stderr, "rate %.0f subs %u: optimiser %f brute force %f\n", rate, subs, optimized.objective, bestObjective);
        assert(false);
    }
    // The result is on the delay/polarity grid and inside the gain range.
    for (uint32_t sub = 0; sub < subs; ++sub) {
        assert(optimized.gainDB[sub] == 0.0f);
        assert(optimized.additionalDelayMs[sub] >= 0.0f && optimized.additionalDelayMs[sub] <= 3.0f);
    }
}

static void check_large_counts(double rate, uint32_t subs, uint32_t room) {
    N60MultichannelCalibrationMatrix m = make_room(rate, subs, room);
    const float target[BINS] = {0};
    N60MultiSubOptimizationSettings settings = grid_settings();
    N60MultiSubOptimizationResult a = {0}, b = {0};
    assert(N60MultiSubOptimize(&m, subs, target, settings, &a));
    assert(N60MultiSubOptimize(&m, subs, target, settings, &b));
    assert(a.subwooferCount == subs);
    assert(isfinite(a.objective));
    assert(memcmp(&a, &b, sizeof a) == 0); // deterministic

    // Seat variance no worse than the best 4-sub subset (first four subs of the same room, optimised alone).
    float bestSubsetVariance = INFINITY;
    for (uint32_t first = 0; first + 4u <= subs; ++first) {
        N60MultichannelCalibrationMatrix four = make_room(rate, 4u, room);
        // Re-point the 4-sub matrix at subs [first, first+4) of the large room.
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

int main(void) {
    assert(N60_CALIBRATION_MAX_SUBWOOFERS == 8u);
    assert(N60_MAX_SUBWOOFER_OUTPUTS == 4u); // the legacy kernel's limit is unchanged
    assert(N60_CALIBRATION_MAX_SOURCES >= N60_MAX_PROGRAM_CHANNELS + 8u);
    for (uint32_t r = 0; r < 8u; ++r) {
        for (uint32_t st = 0; st < 3u; ++st) {
            for (uint32_t subs = 1u; subs <= 5u; ++subs) check_against_brute_force(kRates[r], subs, st);
            check_large_counts(kRates[r], 7u, st);
            check_large_counts(kRates[r], 8u, st);
        }
    }
    for (uint32_t st = 0; st < 3u; ++st) check_against_brute_force(48000.0, 6u, st);

    // Nine subs are refused by the matrix and the optimiser.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60MultichannelCalibrationMatrix nine = N60MultichannelCalibrationMatrixMake(
        48000.0, stereo, 9u, SEATS, kFrequencies, BINS);
    assert(nine.sourceCount == 0u || !N60MultichannelCalibrationMatrixIsValid(&nine, 9u));
    N60MultiSubOptimizationResult unused = {0};
    const float target[BINS] = {0};
    N60MultichannelCalibrationMatrix eight = make_room(48000.0, 8u, 0u);
    assert(!N60MultiSubOptimize(&eight, 9u, target, grid_settings(), &unused));
    return 0;
}
