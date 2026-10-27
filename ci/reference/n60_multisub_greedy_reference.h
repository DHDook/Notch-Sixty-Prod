// Test-only reference: the A4 greedy coordinate search for delay, gain and polarity, copied from
// NotchSixty/Audio/Realtime/N60MultiSubOptimizer.h at 1d45a01 (owner-authored; see docs/PROVENANCE.md).
// It is kept so the A6a harness can check that the new search is never worse than greedy. Do not include it
// from product code.
//
// E8 A6b: also holds the A4/A6a per-bin EQ sweep and its one-frequency objective (copied from the same file at
// 0896e59, owner-authored). The only change is the feasibility rule (slope limit and no positive level at a null
// bin) so that the reference solves the same constrained problem as the new EQ search.
#ifndef N60_MULTISUB_GREEDY_REFERENCE_H
#define N60_MULTISUB_GREEDY_REFERENCE_H

#include "N60MultiSubOptimizer.h"

#pragma clang assume_nonnull begin

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

static inline float N60MultiSubReferenceOneFrequencyObjective(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const uint32_t * _Nonnull sourceIndices,
    uint32_t subwooferCount,
    const float * _Nonnull targetMagnitudeDB,
    const N60MultiSubOptimizationSettings * _Nonnull settings,
    const N60MultiSubOptimizationResult * _Nonnull result,
    uint32_t frequencyIndex,
    uint32_t editedSubwoofer
) {
    float targetError = 0.0f;
    float variance = 0.0f;
    if (!N60MultiSubEvaluateFrequency(
            matrix,
            sourceIndices,
            subwooferCount,
            targetMagnitudeDB,
            settings,
            result,
            frequencyIndex,
            &targetError,
            &variance)) {
        return INFINITY;
    }
    const float eq = result->perSubEQTargetDB[editedSubwoofer][frequencyIndex];
    float regularization = settings->eqRegularization * eq * eq;
    if (frequencyIndex > 0u) {
        const float delta = eq - result->perSubEQTargetDB[editedSubwoofer][frequencyIndex - 1u];
        regularization += settings->eqSmoothness * delta * delta;
    }
    if (frequencyIndex + 1u < matrix->frequencyCount) {
        const float delta = eq - result->perSubEQTargetDB[editedSubwoofer][frequencyIndex + 1u];
        regularization += settings->eqSmoothness * delta * delta;
    }
    return settings->targetErrorWeight * targetError
        + settings->seatVarianceWeight * variance
        + regularization;
}


/// True when an active seat is more than `guardDB` below target at `bin` with every EQ at 0 dB.
static inline bool N60MultiSubReferenceNullBin(
    const N60MultichannelCalibrationMatrix *matrix, const uint32_t *sourceIndices, uint32_t subwooferCount,
    const float *targetMagnitudeDB, const N60MultiSubOptimizationResult *result, uint32_t bin, double guardDB
) {
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
        double sumReal = 0.0, sumImaginary = 0.0;
        for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
            double real = 0.0, imaginary = 0.0;
            N60MultiSubComplexContribution(matrix, &matrix->responses[sourceIndices[sub]][seat], bin,
                result->gainDB[sub], result->additionalDelayMs[sub], result->polarityInverted[sub], 0.0f,
                &real, &imaginary);
            sumReal += real;
            sumImaginary += imaginary;
        }
        const double db = 20.0 * log10(fmax(hypot(sumReal, sumImaginary), 1.0e-12));
        if ((double)targetMagnitudeDB[bin] - db > guardDB) return true;
    }
    return false;
}

/// Largest EQ step allowed between bin-1 and bin: max(slope * |log2(f/f_prev)|, one grid step).
static inline double N60MultiSubReferenceEQJump(
    const N60MultichannelCalibrationMatrix *matrix, const N60MultiSubOptimizationSettings *settings, uint32_t bin
) {
    const double oct = fabs(log2((double)matrix->frequenciesHz[bin] / (double)matrix->frequenciesHz[bin - 1u]));
    return fmax((double)settings->maximumEQSlopeDBPerOctave * oct, (double)settings->eqStepDB);
}

/// The A4 per-bin EQ sweep (`eqPasses` passes, local objective), restricted to feasible levels. Uses the gain,
/// delay and polarity already in `resultOut`, starts from zero EQ.
static inline void N60MultiSubEQReference(
    const N60MultichannelCalibrationMatrix *matrix, const uint32_t *sourceIndices, uint32_t subwooferCount,
    const float *targetMagnitudeDB, const N60MultiSubOptimizationSettings *settings,
    N60MultiSubOptimizationResult *resultOut
) {
    N60MultiSubOptimizationResult result = *resultOut;
    const uint32_t eqSteps = (uint32_t)floorf((settings->maximumEQDB - settings->minimumEQDB) / settings->eqStepDB + 0.5f);
    for (uint32_t pass = 0; pass < settings->eqPasses; ++pass) {
        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            const bool nullBin = N60MultiSubReferenceNullBin(
                matrix, sourceIndices, subwooferCount, targetMagnitudeDB, &result, frequency, 10.0);
            for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
                float bestObjective = INFINITY;
                float bestEQ = result.perSubEQTargetDB[sub][frequency];
                for (uint32_t step = 0; step <= eqSteps; ++step) {
                    N60MultiSubOptimizationResult candidate = result;
                    const float level = fminf(settings->maximumEQDB, settings->minimumEQDB + (float)step * settings->eqStepDB);
                    candidate.perSubEQTargetDB[sub][frequency] = level;
                    if (nullBin && level > 0.0f) continue;
                    if (frequency > 0u && fabs((double)level - (double)result.perSubEQTargetDB[sub][frequency - 1u])
                        > N60MultiSubReferenceEQJump(matrix, settings, frequency) + 1.0e-9) continue;
                    if (frequency + 1u < matrix->frequencyCount
                        && fabs((double)level - (double)result.perSubEQTargetDB[sub][frequency + 1u])
                            > N60MultiSubReferenceEQJump(matrix, settings, frequency + 1u) + 1.0e-9) continue;
                    const float objective = N60MultiSubReferenceOneFrequencyObjective(
                        matrix, sourceIndices, subwooferCount, targetMagnitudeDB, settings, &candidate, frequency, sub);
                    if (objective < bestObjective) {
                        bestObjective = objective;
                        bestEQ = level;
                    }
                }
                result.perSubEQTargetDB[sub][frequency] = bestEQ;
            }
        }
    }
    *resultOut = result;
}

#pragma clang assume_nonnull end

#endif
