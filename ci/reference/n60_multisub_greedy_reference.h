// Test-only reference: the A4 greedy coordinate search for delay, gain and polarity, copied from
// NotchSixty/Audio/Realtime/N60MultiSubOptimizer.h at 1d45a01 (owner-authored; see docs/PROVENANCE.md).
// It is kept so the A6a harness can check that the new search is never worse than greedy. Do not include it
// from product code.
#ifndef N60_MULTISUB_GREEDY_REFERENCE_H
#define N60_MULTISUB_GREEDY_REFERENCE_H

#include "N60MultiSubOptimizer.h"

/// Fills gain, delay and polarity of `result` (zero-initialised by the caller) and leaves the EQ at zero.
static inline void N60MultiSubGreedyReference(
    const N60MultichannelCalibrationMatrix *matrix,
    const uint32_t *sourceIndices,
    uint32_t subwooferCount,
    const float *targetMagnitudeDB,
    const N60MultiSubOptimizationSettings *settings,
    N60MultiSubOptimizationResult *resultOut
) {
    N60MultiSubOptimizationResult result = *resultOut;
    for (uint32_t pass = 0; pass < settings->coordinatePasses; ++pass) {
        for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
            float bestObjective = INFINITY;
            float bestDelay = result.additionalDelayMs[sub];
            bool bestPolarity = result.polarityInverted[sub];

            const uint32_t delaySteps = (uint32_t)floorf(
                settings->maximumAdditionalDelayMs / settings->delayStepMs + 0.5f
            );
            for (uint32_t polarity = 0; polarity < 2u; ++polarity) {
                for (uint32_t step = 0; step <= delaySteps; ++step) {
                    N60MultiSubOptimizationResult candidate = result;
                    candidate.polarityInverted[sub] = polarity != 0u;
                    candidate.additionalDelayMs[sub] = fminf(
                        settings->maximumAdditionalDelayMs,
                        (float)step * settings->delayStepMs
                    );
                    const float objective = N60MultiSubEvaluateObjective(
                        matrix,
                        sourceIndices,
                        subwooferCount,
                        targetMagnitudeDB,
                        settings,
                        &candidate,
                        NULL,
                        NULL
                    );
                    if (objective < bestObjective) {
                        bestObjective = objective;
                        bestDelay = candidate.additionalDelayMs[sub];
                        bestPolarity = candidate.polarityInverted[sub];
                    }
                }
            }
            result.additionalDelayMs[sub] = bestDelay;
            result.polarityInverted[sub] = bestPolarity;

            bestObjective = INFINITY;
            float bestGain = result.gainDB[sub];
            const uint32_t gainSteps = (uint32_t)floorf(
                (settings->maximumGainDB - settings->minimumGainDB) / settings->gainStepDB + 0.5f
            );
            for (uint32_t step = 0; step <= gainSteps; ++step) {
                N60MultiSubOptimizationResult candidate = result;
                candidate.gainDB[sub] = fminf(
                    settings->maximumGainDB,
                    settings->minimumGainDB + (float)step * settings->gainStepDB
                );
                const float objective = N60MultiSubEvaluateObjective(
                    matrix,
                    sourceIndices,
                    subwooferCount,
                    targetMagnitudeDB,
                    settings,
                    &candidate,
                    NULL,
                    NULL
                );
                if (objective < bestObjective) {
                    bestObjective = objective;
                    bestGain = candidate.gainDB[sub];
                }
            }
            result.gainDB[sub] = bestGain;
        }
    }

    *resultOut = result;
}

#endif
