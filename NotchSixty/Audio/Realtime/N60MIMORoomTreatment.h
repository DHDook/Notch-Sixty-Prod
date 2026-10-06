#ifndef N60MIMORoomTreatment_h
#define N60MIMORoomTreatment_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60MIMOCorrection.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIMO_ROOM_TREATMENT_DEFAULT_MIN_HZ 20.0
#define N60_MIMO_ROOM_TREATMENT_DEFAULT_MAX_HZ 150.0
#define N60_MIMO_ROOM_TREATMENT_ROBUSTNESS_CASES 4u
#define N60_MIMO_ROOM_TREATMENT_EPSILON 1.0e-18

typedef struct {
    double regularization;
    double maximumCoefficientGainDB;
    /// Bound on sum_s |C[s,t]|^2 for every target column, expressed as power gain.
    double maximumAggregateSourceGainDB;
    /// Conservative attenuation applied to the weighted geometric-mean target.
    double targetHeadroomDB;
    double minimumPredictedImprovementDB;
    /// Positive value allows a small worst-case degradation under deterministic
    /// plant perturbation. Zero requires every robustness case to be no worse
    /// than the untreated field relative to the same target.
    double maximumRobustnessDegradationDB;
    double robustnessMagnitudeFraction;
    double robustnessPhaseDegrees;
    double minimumColumnSafetyScale;
} N60MIMORoomTreatmentSettings;

typedef struct {
    bool accepted;
    double targetMagnitudeMean;
    double untreatedResidualPower;
    double candidateResidualPower;
    double candidateImprovementDB;
    double worstCaseRelativeDegradationDB;
    double maximumCoefficientMagnitude;
    double maximumColumnPower;
    double minimumAppliedSafetyScale;
} N60MIMORoomTreatmentFrequencyReport;

typedef struct {
    uint32_t sourceCount;
    uint32_t measurementCount;
    uint32_t frequencyCount;
    uint32_t acceptedFrequencyCount;
    /// Safe correction matrix. Rejected frequency bins are exact identity.
    N60MIMOCorrectionDesign correction;
    N60MIMORoomTreatmentFrequencyReport reports[N60_MIMO_MAX_FREQUENCY_BINS];
} N60MIMORoomTreatmentDesign;

static inline N60MIMORoomTreatmentSettings N60MIMORoomTreatmentSettingsMakeDefault(void) {
    return (N60MIMORoomTreatmentSettings){
        .regularization = 2.0e-2,
        .maximumCoefficientGainDB = 0.0,
        .maximumAggregateSourceGainDB = 0.0,
        .targetHeadroomDB = 0.0,
        .minimumPredictedImprovementDB = 1.0,
        .maximumRobustnessDegradationDB = 1.0,
        .robustnessMagnitudeFraction = 0.10,
        .robustnessPhaseDegrees = 5.0,
        .minimumColumnSafetyScale = 0.25,
    };
}

static inline bool N60MIMORoomTreatmentSettingsIsValid(
    N60MIMORoomTreatmentSettings settings
) {
    return isfinite(settings.regularization)
        && settings.regularization > 0.0
        && settings.regularization <= 1.0e6
        && isfinite(settings.maximumCoefficientGainDB)
        && settings.maximumCoefficientGainDB >= 0.0
        && settings.maximumCoefficientGainDB <= 12.0
        && isfinite(settings.maximumAggregateSourceGainDB)
        && settings.maximumAggregateSourceGainDB >= 0.0
        && settings.maximumAggregateSourceGainDB <= 12.0
        && isfinite(settings.targetHeadroomDB)
        && settings.targetHeadroomDB >= 0.0
        && settings.targetHeadroomDB <= 18.0
        && isfinite(settings.minimumPredictedImprovementDB)
        && settings.minimumPredictedImprovementDB >= 0.0
        && settings.minimumPredictedImprovementDB <= 24.0
        && isfinite(settings.maximumRobustnessDegradationDB)
        && settings.maximumRobustnessDegradationDB >= 0.0
        && settings.maximumRobustnessDegradationDB <= 12.0
        && isfinite(settings.robustnessMagnitudeFraction)
        && settings.robustnessMagnitudeFraction >= 0.0
        && settings.robustnessMagnitudeFraction <= 0.50
        && isfinite(settings.robustnessPhaseDegrees)
        && settings.robustnessPhaseDegrees >= 0.0
        && settings.robustnessPhaseDegrees <= 30.0
        && isfinite(settings.minimumColumnSafetyScale)
        && settings.minimumColumnSafetyScale > 0.0
        && settings.minimumColumnSafetyScale <= 1.0;
}

static inline double N60MIMORoomTreatmentMagnitude(N60MIMOComplex value) {
    return sqrt(N60MIMOComplexPower(value));
}

static inline N60MIMOComplex N60MIMORoomTreatmentUnitPhase(N60MIMOComplex value) {
    const double magnitude = N60MIMORoomTreatmentMagnitude(value);
    if (!isfinite(magnitude) || magnitude <= N60_MIMO_ROOM_TREATMENT_EPSILON) {
        return (N60MIMOComplex){1.0, 0.0};
    }
    return N60MIMOComplexScale(value, 1.0 / magnitude);
}

static inline double N60MIMORoomTreatmentDBRatio(double numerator, double denominator) {
    const double safeNumerator = fmax(numerator, N60_MIMO_ROOM_TREATMENT_EPSILON);
    const double safeDenominator = fmax(denominator, N60_MIMO_ROOM_TREATMENT_EPSILON);
    return 10.0 * log10(safeNumerator / safeDenominator);
}

static inline void N60MIMORoomTreatmentSetIdentityAtFrequency(
    uint32_t frequency,
    uint32_t sourceCount,
    N60MIMOCorrectionDesign * _Nonnull correction
) {
    for (uint32_t target = 0u; target < sourceCount; ++target) {
        correction->targetSafetyScale[frequency][target] = 1.0f;
        for (uint32_t source = 0u; source < sourceCount; ++source) {
            correction->correction[
                N60MIMOCorrectionOffset(frequency, source, target)
            ] = (N60MIMOComplex){
                .real = source == target ? 1.0 : 0.0,
                .imaginary = 0.0,
            };
        }
    }
}

static inline double N60MIMORoomTreatmentResidualPower(
    const N60MIMOTransferSet * _Nonnull transfer,
    const N60MIMOComplex * _Nonnull desired,
    const N60MIMOCorrectionDesign * _Nullable correction,
    uint32_t frequency
) {
    const uint32_t n = transfer->sourceCount;
    const uint32_t m = transfer->measurementCount;
    double residual = 0.0;
    double totalWeight = 0.0;

    for (uint32_t measurement = 0u; measurement < m; ++measurement) {
        const double weight = transfer->measurementWeights[measurement];
        if (weight <= 0.0) continue;
        totalWeight += weight;
        for (uint32_t target = 0u; target < n; ++target) {
            N60MIMOComplex predicted = {0};
            if (correction == NULL) {
                predicted = transfer->measured[
                    N60MIMOMeasuredOffset(frequency, measurement, target)
                ];
            } else {
                for (uint32_t source = 0u; source < n; ++source) {
                    predicted = N60MIMOComplexAdd(
                        predicted,
                        N60MIMOComplexMultiply(
                            transfer->measured[
                                N60MIMOMeasuredOffset(frequency, measurement, source)
                            ],
                            correction->correction[
                                N60MIMOCorrectionOffset(frequency, source, target)
                            ]
                        )
                    );
                }
            }
            const N60MIMOComplex targetValue = desired[
                ((size_t)frequency * N60_MIMO_MAX_MEASUREMENTS + measurement)
                    * N60_MIMO_MAX_SOURCES + target
            ];
            residual += weight * N60MIMOComplexPower(
                N60MIMOComplexSubtract(predicted, targetValue)
            );
        }
    }

    if (totalWeight <= 0.0) return INFINITY;
    return residual / (totalWeight * (double)n);
}

/// Builds a conservative magnitude target for each semantic/physical source.
///
/// For source t, the target magnitude is the weighted geometric mean of
/// |H[m,t]| across measurement seats, attenuated by targetHeadroomDB. The
/// measured phase at each seat is retained. This avoids asking the optimizer to
/// flatten propagation phase or to aggressively fill deep spatial nulls while
/// still giving the MIMO solver a common low-frequency magnitude objective.
static inline bool N60MIMORoomTreatmentBuildSpatialTarget(
    const N60MIMOTransferSet * _Nonnull transfer,
    N60MIMORoomTreatmentSettings settings,
    N60MIMOComplex * _Nonnull desiredOut,
    double * _Nullable targetMagnitudeMeanOut
) {
    if (transfer == NULL
        || desiredOut == NULL
        || !N60MIMOTransferSetIsValid(transfer)
        || !N60MIMORoomTreatmentSettingsIsValid(settings)) {
        return false;
    }

    memset(
        desiredOut,
        0,
        sizeof(N60MIMOComplex)
            * N60_MIMO_MAX_FREQUENCY_BINS
            * N60_MIMO_MAX_MEASUREMENTS
            * N60_MIMO_MAX_SOURCES
    );

    const double headroomScale = pow(10.0, -settings.targetHeadroomDB / 20.0);
    for (uint32_t frequency = 0u; frequency < transfer->frequencyCount; ++frequency) {
        double frequencyTargetSum = 0.0;
        for (uint32_t target = 0u; target < transfer->sourceCount; ++target) {
            double weightedLogMagnitude = 0.0;
            double totalWeight = 0.0;
            for (uint32_t measurement = 0u; measurement < transfer->measurementCount; ++measurement) {
                const double weight = transfer->measurementWeights[measurement];
                if (weight <= 0.0) continue;
                const double magnitude = fmax(
                    N60MIMORoomTreatmentMagnitude(
                        transfer->measured[
                            N60MIMOMeasuredOffset(frequency, measurement, target)
                        ]
                    ),
                    N60_MIMO_ROOM_TREATMENT_EPSILON
                );
                weightedLogMagnitude += weight * log(magnitude);
                totalWeight += weight;
            }
            if (totalWeight <= 0.0) return false;
            const double targetMagnitude =
                exp(weightedLogMagnitude / totalWeight) * headroomScale;
            if (!isfinite(targetMagnitude)
                || targetMagnitude <= N60_MIMO_ROOM_TREATMENT_EPSILON) {
                return false;
            }
            frequencyTargetSum += targetMagnitude;

            for (uint32_t measurement = 0u; measurement < transfer->measurementCount; ++measurement) {
                const N60MIMOComplex measured = transfer->measured[
                    N60MIMOMeasuredOffset(frequency, measurement, target)
                ];
                desiredOut[
                    ((size_t)frequency * N60_MIMO_MAX_MEASUREMENTS + measurement)
                        * N60_MIMO_MAX_SOURCES + target
                ] = N60MIMOComplexScale(
                    N60MIMORoomTreatmentUnitPhase(measured),
                    targetMagnitude
                );
            }
        }
        if (targetMagnitudeMeanOut != NULL) {
            targetMagnitudeMeanOut[frequency] =
                frequencyTargetSum / (double)transfer->sourceCount;
        }
    }
    return true;
}

static inline void N60MIMORoomTreatmentApplyAggregatePowerBound(
    uint32_t frequency,
    uint32_t sourceCount,
    N60MIMORoomTreatmentSettings settings,
    N60MIMOCorrectionDesign * _Nonnull correction,
    double * _Nonnull maximumCoefficientMagnitudeOut,
    double * _Nonnull maximumColumnPowerOut,
    double * _Nonnull minimumSafetyScaleOut
) {
    const double maximumColumnPower = pow(
        10.0,
        settings.maximumAggregateSourceGainDB / 10.0
    );
    double largestCoefficient = 0.0;
    double largestColumnPower = 0.0;
    double minimumSafetyScale = 1.0;

    for (uint32_t target = 0u; target < sourceCount; ++target) {
        double columnPower = 0.0;
        for (uint32_t source = 0u; source < sourceCount; ++source) {
            const N60MIMOComplex coefficient = correction->correction[
                N60MIMOCorrectionOffset(frequency, source, target)
            ];
            columnPower += N60MIMOComplexPower(coefficient);
        }
        const double aggregateScale = columnPower > maximumColumnPower
            ? sqrt(maximumColumnPower / columnPower)
            : 1.0;
        if (aggregateScale < 1.0) {
            correction->targetSafetyScale[frequency][target] *= (float)aggregateScale;
            for (uint32_t source = 0u; source < sourceCount; ++source) {
                const size_t offset = N60MIMOCorrectionOffset(
                    frequency,
                    source,
                    target
                );
                correction->correction[offset] = N60MIMOComplexScale(
                    correction->correction[offset],
                    aggregateScale
                );
            }
            columnPower *= aggregateScale * aggregateScale;
        }

        if (columnPower > largestColumnPower) largestColumnPower = columnPower;
        const double safety = correction->targetSafetyScale[frequency][target];
        if (safety < minimumSafetyScale) minimumSafetyScale = safety;
        for (uint32_t source = 0u; source < sourceCount; ++source) {
            const double magnitude = N60MIMORoomTreatmentMagnitude(
                correction->correction[
                    N60MIMOCorrectionOffset(frequency, source, target)
                ]
            );
            if (magnitude > largestCoefficient) largestCoefficient = magnitude;
        }
    }

    *maximumCoefficientMagnitudeOut = largestCoefficient;
    *maximumColumnPowerOut = largestColumnPower;
    *minimumSafetyScaleOut = minimumSafetyScale;
}

static inline N60MIMOComplex N60MIMORoomTreatmentPerturb(
    N60MIMOComplex value,
    uint32_t measurement,
    uint32_t source,
    uint32_t scenario,
    N60MIMORoomTreatmentSettings settings
) {
    const double magnitudePattern =
        ((measurement + source + scenario) & 1u) == 0u ? 1.0 : -1.0;
    const double phasePattern =
        ((measurement * 3u + source + scenario) & 1u) == 0u ? 1.0 : -1.0;
    const double magnitudeScale =
        1.0 + magnitudePattern * settings.robustnessMagnitudeFraction;
    const double phaseRadians = phasePattern
        * settings.robustnessPhaseDegrees
        * (3.14159265358979323846 / 180.0);
    const N60MIMOComplex rotation = {
        .real = cos(phaseRadians),
        .imaginary = sin(phaseRadians),
    };
    return N60MIMOComplexScale(
        N60MIMOComplexMultiply(value, rotation),
        magnitudeScale
    );
}

static inline double N60MIMORoomTreatmentWorstCaseRelativeDegradationDB(
    const N60MIMOTransferSet * _Nonnull transfer,
    const N60MIMOComplex * _Nonnull desired,
    const N60MIMOCorrectionDesign * _Nonnull correction,
    uint32_t frequency,
    N60MIMORoomTreatmentSettings settings
) {
    double worst = -INFINITY;

    for (uint32_t scenario = 0u;
         scenario < N60_MIMO_ROOM_TREATMENT_ROBUSTNESS_CASES;
         ++scenario) {
        double untreated = 0.0;
        double treated = 0.0;
        double totalWeight = 0.0;

        for (uint32_t measurement = 0u;
             measurement < transfer->measurementCount;
             ++measurement) {
            const double weight = transfer->measurementWeights[measurement];
            if (weight <= 0.0) continue;
            totalWeight += weight;

            for (uint32_t target = 0u; target < transfer->sourceCount; ++target) {
                const N60MIMOComplex targetValue = desired[
                    ((size_t)frequency * N60_MIMO_MAX_MEASUREMENTS + measurement)
                        * N60_MIMO_MAX_SOURCES + target
                ];

                const N60MIMOComplex untreatedValue =
                    N60MIMORoomTreatmentPerturb(
                        transfer->measured[
                            N60MIMOMeasuredOffset(frequency, measurement, target)
                        ],
                        measurement,
                        target,
                        scenario,
                        settings
                    );
                untreated += weight * N60MIMOComplexPower(
                    N60MIMOComplexSubtract(untreatedValue, targetValue)
                );

                N60MIMOComplex treatedValue = {0};
                for (uint32_t source = 0u;
                     source < transfer->sourceCount;
                     ++source) {
                    const N60MIMOComplex perturbed =
                        N60MIMORoomTreatmentPerturb(
                            transfer->measured[
                                N60MIMOMeasuredOffset(frequency, measurement, source)
                            ],
                            measurement,
                            source,
                            scenario,
                            settings
                        );
                    treatedValue = N60MIMOComplexAdd(
                        treatedValue,
                        N60MIMOComplexMultiply(
                            perturbed,
                            correction->correction[
                                N60MIMOCorrectionOffset(frequency, source, target)
                            ]
                        )
                    );
                }
                treated += weight * N60MIMOComplexPower(
                    N60MIMOComplexSubtract(treatedValue, targetValue)
                );
            }
        }

        if (totalWeight <= 0.0) return INFINITY;
        const double relative = N60MIMORoomTreatmentDBRatio(
            treated,
            untreated
        );
        if (relative > worst) worst = relative;
    }

    return worst;
}

/// Offline-only bounded MIMO room-treatment candidate designer.
///
/// Accepted bins retain the regularized MIMO matrix. Rejected bins are replaced
/// with exact identity so a future compiler cannot accidentally deploy an
/// untrusted frequency-domain candidate.
///
/// This function does not create FIR/IIR filters and does not touch live audio.
static inline bool N60MIMORoomTreatmentDesignSpatialEqualization(
    const N60MIMOTransferSet * _Nonnull transfer,
    N60MIMORoomTreatmentSettings settings,
    N60MIMORoomTreatmentDesign * _Nonnull designOut
) {
    if (transfer == NULL
        || designOut == NULL
        || !N60MIMOTransferSetIsValid(transfer)
        || !N60MIMORoomTreatmentSettingsIsValid(settings)) {
        return false;
    }

    const size_t desiredCount =
        (size_t)N60_MIMO_MAX_FREQUENCY_BINS
        * N60_MIMO_MAX_MEASUREMENTS
        * N60_MIMO_MAX_SOURCES;
    N60MIMOComplex *desired = (N60MIMOComplex *)calloc(
        desiredCount,
        sizeof(N60MIMOComplex)
    );
    if (desired == NULL) return false;

    double targetMagnitudeMean[N60_MIMO_MAX_FREQUENCY_BINS] = {0};
    if (!N60MIMORoomTreatmentBuildSpatialTarget(
            transfer,
            settings,
            desired,
            targetMagnitudeMean)) {
        free(desired);
        return false;
    }

    N60MIMODesignSettings core = N60MIMODesignSettingsMakeDefault();
    core.regularization = settings.regularization;
    core.maximumCoefficientGainDB = settings.maximumCoefficientGainDB;

    memset(designOut, 0, sizeof(*designOut));
    designOut->sourceCount = transfer->sourceCount;
    designOut->measurementCount = transfer->measurementCount;
    designOut->frequencyCount = transfer->frequencyCount;

    if (!N60MIMODesignRegularizedCorrection(
            transfer,
            desired,
            core,
            &designOut->correction)) {
        free(desired);
        memset(designOut, 0, sizeof(*designOut));
        return false;
    }

    for (uint32_t frequency = 0u;
         frequency < transfer->frequencyCount;
         ++frequency) {
        double maximumCoefficientMagnitude = 0.0;
        double maximumColumnPower = 0.0;
        double minimumSafetyScale = 1.0;
        N60MIMORoomTreatmentApplyAggregatePowerBound(
            frequency,
            transfer->sourceCount,
            settings,
            &designOut->correction,
            &maximumCoefficientMagnitude,
            &maximumColumnPower,
            &minimumSafetyScale
        );

        const double untreated = N60MIMORoomTreatmentResidualPower(
            transfer,
            desired,
            NULL,
            frequency
        );
        const double candidate = N60MIMORoomTreatmentResidualPower(
            transfer,
            desired,
            &designOut->correction,
            frequency
        );
        if (!isfinite(untreated)
            || !isfinite(candidate)
            || untreated <= 0.0
            || candidate < 0.0) {
            free(desired);
            memset(designOut, 0, sizeof(*designOut));
            return false;
        }

        const double improvement = N60MIMORoomTreatmentDBRatio(
            untreated,
            candidate
        );
        const double worstCaseDegradation =
            N60MIMORoomTreatmentWorstCaseRelativeDegradationDB(
                transfer,
                desired,
                &designOut->correction,
                frequency,
                settings
            );
        const bool accepted =
            improvement >= settings.minimumPredictedImprovementDB
            && worstCaseDegradation <= settings.maximumRobustnessDegradationDB
            && minimumSafetyScale >= settings.minimumColumnSafetyScale;

        designOut->reports[frequency] = (N60MIMORoomTreatmentFrequencyReport){
            .accepted = accepted,
            .targetMagnitudeMean = targetMagnitudeMean[frequency],
            .untreatedResidualPower = untreated,
            .candidateResidualPower = candidate,
            .candidateImprovementDB = improvement,
            .worstCaseRelativeDegradationDB = worstCaseDegradation,
            .maximumCoefficientMagnitude = maximumCoefficientMagnitude,
            .maximumColumnPower = maximumColumnPower,
            .minimumAppliedSafetyScale = minimumSafetyScale,
        };

        if (accepted) {
            designOut->acceptedFrequencyCount += 1u;
        } else {
            N60MIMORoomTreatmentSetIdentityAtFrequency(
                frequency,
                transfer->sourceCount,
                &designOut->correction
            );
            designOut->correction.weightedResidualPower[frequency] = untreated;
        }
    }

    free(desired);
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
