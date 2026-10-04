#ifndef N60MultiSubOptimizer_h
#define N60MultiSubOptimizer_h

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60MultichannelCalibration.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MULTI_SUB_PI 3.14159265358979323846

typedef struct {
    float minimumGainDB;
    float maximumGainDB;
    float gainStepDB;
    float maximumAdditionalDelayMs;
    float delayStepMs;
    uint32_t coordinatePasses;
    float targetErrorWeight;
    float seatVarianceWeight;
    float boostRegularization;
    float minimumEQDB;
    float maximumEQDB;
    float eqStepDB;
    uint32_t eqPasses;
    float eqRegularization;
    float eqSmoothness;
} N60MultiSubOptimizationSettings;

typedef struct {
    uint32_t subwooferCount;
    uint32_t frequencyCount;
    float gainDB[N60_MAX_SUBWOOFER_OUTPUTS];
    float additionalDelayMs[N60_MAX_SUBWOOFER_OUTPUTS];
    bool polarityInverted[N60_MAX_SUBWOOFER_OUTPUTS];
    /// Frequency-domain correction targets for the later bounded PEQ/FIR fitter.
    /// They are not raw realtime filters and must not be applied sample-by-sample.
    float perSubEQTargetDB[N60_MAX_SUBWOOFER_OUTPUTS][N60_CALIBRATION_MAX_FREQUENCY_BINS];
    float objective;
    float weightedTargetErrorDBSquared;
    float seatVarianceDBSquared;
} N60MultiSubOptimizationResult;

static inline N60MultiSubOptimizationSettings N60MultiSubOptimizationSettingsMakeDefault(void) {
    return (N60MultiSubOptimizationSettings){
        .minimumGainDB = -12.0f,
        .maximumGainDB = 3.0f,
        .gainStepDB = 1.0f,
        .maximumAdditionalDelayMs = 20.0f,
        .delayStepMs = 0.25f,
        .coordinatePasses = 3u,
        .targetErrorWeight = 1.0f,
        .seatVarianceWeight = 1.5f,
        .boostRegularization = 0.02f,
        .minimumEQDB = -8.0f,
        .maximumEQDB = 3.0f,
        .eqStepDB = 1.0f,
        .eqPasses = 2u,
        .eqRegularization = 0.03f,
        .eqSmoothness = 0.08f,
    };
}

static inline bool N60MultiSubOptimizationSettingsIsValid(
    N60MultiSubOptimizationSettings settings
) {
    return isfinite(settings.minimumGainDB)
        && isfinite(settings.maximumGainDB)
        && settings.maximumGainDB >= settings.minimumGainDB
        && isfinite(settings.gainStepDB)
        && settings.gainStepDB > 0.0f
        && isfinite(settings.maximumAdditionalDelayMs)
        && settings.maximumAdditionalDelayMs >= 0.0f
        && isfinite(settings.delayStepMs)
        && settings.delayStepMs > 0.0f
        && settings.coordinatePasses > 0u
        && settings.coordinatePasses <= 8u
        && isfinite(settings.targetErrorWeight)
        && settings.targetErrorWeight > 0.0f
        && isfinite(settings.seatVarianceWeight)
        && settings.seatVarianceWeight >= 0.0f
        && isfinite(settings.boostRegularization)
        && settings.boostRegularization >= 0.0f
        && isfinite(settings.minimumEQDB)
        && isfinite(settings.maximumEQDB)
        && settings.maximumEQDB >= settings.minimumEQDB
        && isfinite(settings.eqStepDB)
        && settings.eqStepDB > 0.0f
        && settings.eqPasses <= 8u
        && isfinite(settings.eqRegularization)
        && settings.eqRegularization >= 0.0f
        && isfinite(settings.eqSmoothness)
        && settings.eqSmoothness >= 0.0f;
}

static inline bool N60MultiSubFindSourceIndices(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t subwooferCount,
    uint32_t * _Nonnull sourceIndices
) {
    if (matrix == NULL
        || sourceIndices == NULL
        || subwooferCount == 0u
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS) {
        return false;
    }
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        const int32_t index = N60MultichannelCalibrationSourceIndexForSubwoofer(matrix, sub);
        if (index < 0) return false;
        sourceIndices[sub] = (uint32_t)index;
    }
    return true;
}

static inline void N60MultiSubComplexContribution(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const N60CalibrationMeasuredResponse * _Nonnull response,
    uint32_t frequencyIndex,
    float gainDB,
    float additionalDelayMs,
    bool polarityInverted,
    float eqDB,
    double * _Nonnull realOut,
    double * _Nonnull imaginaryOut
) {
    const double frequencyHz = matrix->frequenciesHz[frequencyIndex];
    const double magnitudeLinear = pow(
        10.0,
        ((double)response->magnitudeDB[frequencyIndex] + (double)gainDB + (double)eqDB) / 20.0
    );
    const double measuredDelaySeconds = (double)response->directArrivalFrame / matrix->sampleRate;
    const double additionalDelaySeconds = (double)additionalDelayMs * 0.001;
    double phase = (double)response->phaseRadians[frequencyIndex]
        - 2.0 * N60_MULTI_SUB_PI * frequencyHz * (measuredDelaySeconds + additionalDelaySeconds);
    if (polarityInverted) phase += N60_MULTI_SUB_PI;
    *realOut = magnitudeLinear * cos(phase);
    *imaginaryOut = magnitudeLinear * sin(phase);
}

static inline bool N60MultiSubEvaluateFrequency(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const uint32_t * _Nonnull sourceIndices,
    uint32_t subwooferCount,
    const float * _Nonnull targetMagnitudeDB,
    const N60MultiSubOptimizationSettings * _Nonnull settings,
    const N60MultiSubOptimizationResult * _Nonnull result,
    uint32_t frequencyIndex,
    float * _Nonnull targetErrorOut,
    float * _Nonnull seatVarianceOut
) {
    if (matrix == NULL
        || sourceIndices == NULL
        || targetMagnitudeDB == NULL
        || settings == NULL
        || result == NULL
        || targetErrorOut == NULL
        || seatVarianceOut == NULL
        || frequencyIndex >= matrix->frequencyCount) {
        return false;
    }

    const float totalWeight = N60CalibrationIncludedWeight(matrix);
    if (!isfinite(totalWeight) || totalWeight <= 0.0f) return false;

    float seatDB[N60_CALIBRATION_MAX_SEATS] = {0};
    float weightedMeanDB = 0.0f;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
        double sumReal = 0.0;
        double sumImaginary = 0.0;
        for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
            const N60CalibrationMeasuredResponse *response =
                &matrix->responses[sourceIndices[sub]][seat];
            if (!response->valid) return false;
            double real = 0.0;
            double imaginary = 0.0;
            N60MultiSubComplexContribution(
                matrix,
                response,
                frequencyIndex,
                result->gainDB[sub],
                result->additionalDelayMs[sub],
                result->polarityInverted[sub],
                result->perSubEQTargetDB[sub][frequencyIndex],
                &real,
                &imaginary
            );
            sumReal += real;
            sumImaginary += imaginary;
        }
        const double magnitude = hypot(sumReal, sumImaginary);
        const float db = (float)(20.0 * log10(fmax(magnitude, 1.0e-12)));
        seatDB[seat] = db;
        weightedMeanDB += db * (matrix->seats[seat].weight / totalWeight);
    }

    float variance = 0.0f;
    float targetError = 0.0f;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
        const float normalized = matrix->seats[seat].weight / totalWeight;
        const float meanDifference = seatDB[seat] - weightedMeanDB;
        const float targetDifference = seatDB[seat] - targetMagnitudeDB[frequencyIndex];
        variance += normalized * meanDifference * meanDifference;
        targetError += normalized * targetDifference * targetDifference;
    }
    *targetErrorOut = targetError;
    *seatVarianceOut = variance;
    return true;
}

static inline float N60MultiSubEvaluateObjective(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const uint32_t * _Nonnull sourceIndices,
    uint32_t subwooferCount,
    const float * _Nonnull targetMagnitudeDB,
    const N60MultiSubOptimizationSettings * _Nonnull settings,
    const N60MultiSubOptimizationResult * _Nonnull result,
    float * _Nullable targetErrorOut,
    float * _Nullable seatVarianceOut
) {
    if (matrix == NULL
        || sourceIndices == NULL
        || targetMagnitudeDB == NULL
        || settings == NULL
        || result == NULL) {
        return INFINITY;
    }

    float targetError = 0.0f;
    float variance = 0.0f;
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        float binError = 0.0f;
        float binVariance = 0.0f;
        if (!N60MultiSubEvaluateFrequency(
                matrix,
                sourceIndices,
                subwooferCount,
                targetMagnitudeDB,
                settings,
                result,
                frequency,
                &binError,
                &binVariance)) {
            return INFINITY;
        }
        targetError += binError / (float)matrix->frequencyCount;
        variance += binVariance / (float)matrix->frequencyCount;
    }

    float regularization = 0.0f;
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        const float boost = fmaxf(0.0f, result->gainDB[sub]);
        regularization += settings->boostRegularization * boost * boost;
        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            const float eq = result->perSubEQTargetDB[sub][frequency];
            regularization += settings->eqRegularization * eq * eq
                / (float)(subwooferCount * matrix->frequencyCount);
            if (frequency > 0u) {
                const float delta = eq - result->perSubEQTargetDB[sub][frequency - 1u];
                regularization += settings->eqSmoothness * delta * delta
                    / (float)(subwooferCount * matrix->frequencyCount);
            }
        }
    }

    if (targetErrorOut != NULL) *targetErrorOut = targetError;
    if (seatVarianceOut != NULL) *seatVarianceOut = variance;
    return settings->targetErrorWeight * targetError
        + settings->seatVarianceWeight * variance
        + regularization;
}

static inline float N60MultiSubEvaluateOneFrequencyObjective(
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

/// Offline/control-plane coordinate optimizer. It first alternates polarity/delay
/// and broad gain per physical sub, then derives a smooth bounded frequency-domain
/// correction target per sub. The EQ target is intentionally a design target, not
/// a realtime graphic EQ; a later bounded PEQ/FIR fitter converts it into deployable
/// filters while preserving the PR55 per-sub processing contract.
static inline bool N60MultiSubOptimize(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t subwooferCount,
    const float * _Nonnull targetMagnitudeDB,
    N60MultiSubOptimizationSettings settings,
    N60MultiSubOptimizationResult * _Nonnull resultOut
) {
    if (matrix == NULL
        || targetMagnitudeDB == NULL
        || resultOut == NULL
        || subwooferCount == 0u
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS
        || !N60MultiSubOptimizationSettingsIsValid(settings)
        || !N60MultichannelCalibrationMatrixIsValid(matrix, subwooferCount)) {
        return false;
    }
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        if (!isfinite(targetMagnitudeDB[frequency])) return false;
    }

    uint32_t sourceIndices[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    if (!N60MultiSubFindSourceIndices(matrix, subwooferCount, sourceIndices)) return false;

    N60MultiSubOptimizationResult result = {0};
    result.subwooferCount = subwooferCount;
    result.frequencyCount = matrix->frequencyCount;

    for (uint32_t pass = 0; pass < settings.coordinatePasses; ++pass) {
        for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
            float bestObjective = INFINITY;
            float bestDelay = result.additionalDelayMs[sub];
            bool bestPolarity = result.polarityInverted[sub];

            const uint32_t delaySteps = (uint32_t)floorf(
                settings.maximumAdditionalDelayMs / settings.delayStepMs + 0.5f
            );
            for (uint32_t polarity = 0; polarity < 2u; ++polarity) {
                for (uint32_t step = 0; step <= delaySteps; ++step) {
                    N60MultiSubOptimizationResult candidate = result;
                    candidate.polarityInverted[sub] = polarity != 0u;
                    candidate.additionalDelayMs[sub] = fminf(
                        settings.maximumAdditionalDelayMs,
                        (float)step * settings.delayStepMs
                    );
                    const float objective = N60MultiSubEvaluateObjective(
                        matrix,
                        sourceIndices,
                        subwooferCount,
                        targetMagnitudeDB,
                        &settings,
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
                (settings.maximumGainDB - settings.minimumGainDB) / settings.gainStepDB + 0.5f
            );
            for (uint32_t step = 0; step <= gainSteps; ++step) {
                N60MultiSubOptimizationResult candidate = result;
                candidate.gainDB[sub] = fminf(
                    settings.maximumGainDB,
                    settings.minimumGainDB + (float)step * settings.gainStepDB
                );
                const float objective = N60MultiSubEvaluateObjective(
                    matrix,
                    sourceIndices,
                    subwooferCount,
                    targetMagnitudeDB,
                    &settings,
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

    for (uint32_t pass = 0; pass < settings.eqPasses; ++pass) {
        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
                float bestObjective = INFINITY;
                float bestEQ = result.perSubEQTargetDB[sub][frequency];
                const uint32_t eqSteps = (uint32_t)floorf(
                    (settings.maximumEQDB - settings.minimumEQDB) / settings.eqStepDB + 0.5f
                );
                for (uint32_t step = 0; step <= eqSteps; ++step) {
                    N60MultiSubOptimizationResult candidate = result;
                    candidate.perSubEQTargetDB[sub][frequency] = fminf(
                        settings.maximumEQDB,
                        settings.minimumEQDB + (float)step * settings.eqStepDB
                    );
                    const float objective = N60MultiSubEvaluateOneFrequencyObjective(
                        matrix,
                        sourceIndices,
                        subwooferCount,
                        targetMagnitudeDB,
                        &settings,
                        &candidate,
                        frequency,
                        sub
                    );
                    if (objective < bestObjective) {
                        bestObjective = objective;
                        bestEQ = candidate.perSubEQTargetDB[sub][frequency];
                    }
                }
                result.perSubEQTargetDB[sub][frequency] = bestEQ;
            }
        }
    }

    result.objective = N60MultiSubEvaluateObjective(
        matrix,
        sourceIndices,
        subwooferCount,
        targetMagnitudeDB,
        &settings,
        &result,
        &result.weightedTargetErrorDBSquared,
        &result.seatVarianceDBSquared
    );
    if (!isfinite(result.objective)) return false;
    *resultOut = result;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
