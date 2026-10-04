#ifndef N60MIMOCorrection_h
#define N60MIMOCorrection_h

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIMO_MAX_FREQUENCY_BINS 64u
#define N60_MIMO_MAX_MEASUREMENTS N60_MAX_PROGRAM_CHANNELS
#define N60_MIMO_MAX_SOURCES N60_MAX_PROGRAM_CHANNELS
#define N60_MIMO_MIN_PIVOT_POWER 1.0e-16

typedef struct {
    double real;
    double imaginary;
} N60MIMOComplex;

typedef struct {
    uint32_t sourceCount;
    uint32_t measurementCount;
    uint32_t frequencyCount;
    double sampleRate;
    float frequenciesHz[N60_MIMO_MAX_FREQUENCY_BINS];
    float measurementWeights[N60_MIMO_MAX_MEASUREMENTS];
    /// Frequency-major H[m,s]: measured complex transfer from source s to measurement m.
    N60MIMOComplex measured[
        N60_MIMO_MAX_FREQUENCY_BINS * N60_MIMO_MAX_MEASUREMENTS * N60_MIMO_MAX_SOURCES
    ];
} N60MIMOTransferSet;

typedef struct {
    double regularization;
    double maximumCoefficientGainDB;
} N60MIMODesignSettings;

typedef struct {
    uint32_t sourceCount;
    uint32_t targetCount;
    uint32_t frequencyCount;
    /// Frequency-major C[s,t]: source-domain correction matrix per target program lane.
    N60MIMOComplex correction[
        N60_MIMO_MAX_FREQUENCY_BINS * N60_MIMO_MAX_SOURCES * N60_MIMO_MAX_SOURCES
    ];
    /// Uniform per-target safety scale applied when any matrix coefficient would
    /// exceed the configured gain bound. This preserves matrix direction rather
    /// than independently clipping coefficients and corrupting spatial nulls.
    float targetSafetyScale[N60_MIMO_MAX_FREQUENCY_BINS][N60_MIMO_MAX_SOURCES];
    double weightedResidualPower[N60_MIMO_MAX_FREQUENCY_BINS];
} N60MIMOCorrectionDesign;

static inline N60MIMOComplex N60MIMOComplexAdd(N60MIMOComplex lhs, N60MIMOComplex rhs) {
    return (N60MIMOComplex){lhs.real + rhs.real, lhs.imaginary + rhs.imaginary};
}

static inline N60MIMOComplex N60MIMOComplexSubtract(N60MIMOComplex lhs, N60MIMOComplex rhs) {
    return (N60MIMOComplex){lhs.real - rhs.real, lhs.imaginary - rhs.imaginary};
}

static inline N60MIMOComplex N60MIMOComplexMultiply(N60MIMOComplex lhs, N60MIMOComplex rhs) {
    return (N60MIMOComplex){
        lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
        lhs.real * rhs.imaginary + lhs.imaginary * rhs.real,
    };
}

static inline N60MIMOComplex N60MIMOComplexScale(N60MIMOComplex value, double scale) {
    return (N60MIMOComplex){value.real * scale, value.imaginary * scale};
}

static inline N60MIMOComplex N60MIMOComplexConjugate(N60MIMOComplex value) {
    return (N60MIMOComplex){value.real, -value.imaginary};
}

static inline double N60MIMOComplexPower(N60MIMOComplex value) {
    return value.real * value.real + value.imaginary * value.imaginary;
}

static inline N60MIMOComplex N60MIMOComplexDivide(N60MIMOComplex numerator, N60MIMOComplex denominator) {
    const double power = N60MIMOComplexPower(denominator);
    if (!isfinite(power) || power <= N60_MIMO_MIN_PIVOT_POWER) return (N60MIMOComplex){0};
    return (N60MIMOComplex){
        (numerator.real * denominator.real + numerator.imaginary * denominator.imaginary) / power,
        (numerator.imaginary * denominator.real - numerator.real * denominator.imaginary) / power,
    };
}

static inline size_t N60MIMOMeasuredOffset(uint32_t frequency, uint32_t measurement, uint32_t source) {
    return ((size_t)frequency * N60_MIMO_MAX_MEASUREMENTS + measurement) * N60_MIMO_MAX_SOURCES + source;
}

static inline size_t N60MIMOCorrectionOffset(uint32_t frequency, uint32_t source, uint32_t target) {
    return ((size_t)frequency * N60_MIMO_MAX_SOURCES + source) * N60_MIMO_MAX_SOURCES + target;
}

static inline N60MIMODesignSettings N60MIMODesignSettingsMakeDefault(void) {
    return (N60MIMODesignSettings){
        .regularization = 1.0e-3,
        .maximumCoefficientGainDB = 6.0,
    };
}

static inline bool N60MIMOTransferSetIsValid(const N60MIMOTransferSet * _Nullable transfer) {
    if (transfer == NULL
        || transfer->sourceCount == 0u
        || transfer->sourceCount > N60_MIMO_MAX_SOURCES
        || transfer->measurementCount == 0u
        || transfer->measurementCount > N60_MIMO_MAX_MEASUREMENTS
        || transfer->frequencyCount == 0u
        || transfer->frequencyCount > N60_MIMO_MAX_FREQUENCY_BINS
        || !isfinite(transfer->sampleRate)
        || transfer->sampleRate <= 0.0) {
        return false;
    }
    float previous = 0.0f;
    bool hasWeight = false;
    for (uint32_t measurement = 0; measurement < transfer->measurementCount; ++measurement) {
        const float weight = transfer->measurementWeights[measurement];
        if (!isfinite(weight) || weight < 0.0f) return false;
        if (weight > 0.0f) hasWeight = true;
    }
    if (!hasWeight) return false;
    for (uint32_t frequency = 0; frequency < transfer->frequencyCount; ++frequency) {
        const float hz = transfer->frequenciesHz[frequency];
        if (!isfinite(hz) || hz <= previous || hz >= transfer->sampleRate * 0.5) return false;
        previous = hz;
        for (uint32_t measurement = 0; measurement < transfer->measurementCount; ++measurement) {
            for (uint32_t source = 0; source < transfer->sourceCount; ++source) {
                const N60MIMOComplex value = transfer->measured[
                    N60MIMOMeasuredOffset(frequency, measurement, source)
                ];
                if (!isfinite(value.real) || !isfinite(value.imaginary)) return false;
            }
        }
    }
    return true;
}

static inline bool N60MIMODesignSettingsIsValid(N60MIMODesignSettings settings) {
    return isfinite(settings.regularization)
        && settings.regularization > 0.0
        && settings.regularization <= 1.0e6
        && isfinite(settings.maximumCoefficientGainDB)
        && settings.maximumCoefficientGainDB >= 0.0
        && settings.maximumCoefficientGainDB <= 24.0;
}

static inline bool N60MIMOSolveComplexSystem(
    uint32_t size,
    uint32_t rightHandColumns,
    N60MIMOComplex (* _Nonnull matrix)[N60_MIMO_MAX_SOURCES],
    N60MIMOComplex (* _Nonnull right)[N60_MIMO_MAX_SOURCES]
) {
    if (size == 0u || size > N60_MIMO_MAX_SOURCES || rightHandColumns > N60_MIMO_MAX_SOURCES) return false;
    for (uint32_t pivot = 0; pivot < size; ++pivot) {
        uint32_t bestRow = pivot;
        double bestPower = N60MIMOComplexPower(matrix[pivot][pivot]);
        for (uint32_t row = pivot + 1u; row < size; ++row) {
            const double power = N60MIMOComplexPower(matrix[row][pivot]);
            if (power > bestPower) {
                bestPower = power;
                bestRow = row;
            }
        }
        if (!isfinite(bestPower) || bestPower <= N60_MIMO_MIN_PIVOT_POWER) return false;
        if (bestRow != pivot) {
            for (uint32_t column = 0; column < size; ++column) {
                const N60MIMOComplex temp = matrix[pivot][column];
                matrix[pivot][column] = matrix[bestRow][column];
                matrix[bestRow][column] = temp;
            }
            for (uint32_t column = 0; column < rightHandColumns; ++column) {
                const N60MIMOComplex temp = right[pivot][column];
                right[pivot][column] = right[bestRow][column];
                right[bestRow][column] = temp;
            }
        }

        const N60MIMOComplex diagonal = matrix[pivot][pivot];
        for (uint32_t column = pivot; column < size; ++column) {
            matrix[pivot][column] = N60MIMOComplexDivide(matrix[pivot][column], diagonal);
        }
        for (uint32_t column = 0; column < rightHandColumns; ++column) {
            right[pivot][column] = N60MIMOComplexDivide(right[pivot][column], diagonal);
        }

        for (uint32_t row = 0; row < size; ++row) {
            if (row == pivot) continue;
            const N60MIMOComplex factor = matrix[row][pivot];
            if (N60MIMOComplexPower(factor) <= N60_MIMO_MIN_PIVOT_POWER) {
                matrix[row][pivot] = (N60MIMOComplex){0};
                continue;
            }
            for (uint32_t column = pivot; column < size; ++column) {
                matrix[row][column] = N60MIMOComplexSubtract(
                    matrix[row][column],
                    N60MIMOComplexMultiply(factor, matrix[pivot][column])
                );
            }
            for (uint32_t column = 0; column < rightHandColumns; ++column) {
                right[row][column] = N60MIMOComplexSubtract(
                    right[row][column],
                    N60MIMOComplexMultiply(factor, right[pivot][column])
                );
            }
        }
    }
    return true;
}

/// Offline regularized least-squares MIMO designer:
/// C = (Hᴴ W H + λI)^−1 Hᴴ W D.
/// `desired` is frequency-major D[m,t] with targetCount == sourceCount. The
/// caller defines the physical target policy; this layer does not invent a room-
/// correction target matrix. Regularization is mandatory and matrix columns are
/// uniformly safety-scaled instead of independently coefficient-clipped.
static inline bool N60MIMODesignRegularizedCorrection(
    const N60MIMOTransferSet * _Nonnull transfer,
    const N60MIMOComplex * _Nonnull desired,
    N60MIMODesignSettings settings,
    N60MIMOCorrectionDesign * _Nonnull designOut
) {
    if (transfer == NULL
        || desired == NULL
        || designOut == NULL
        || !N60MIMOTransferSetIsValid(transfer)
        || !N60MIMODesignSettingsIsValid(settings)) {
        return false;
    }
    const uint32_t n = transfer->sourceCount;
    const uint32_t m = transfer->measurementCount;
    const uint32_t targetCount = n;
    const double maximumCoefficient = pow(10.0, settings.maximumCoefficientGainDB / 20.0);
    N60MIMOCorrectionDesign design = {0};
    design.sourceCount = n;
    design.targetCount = targetCount;
    design.frequencyCount = transfer->frequencyCount;

    for (uint32_t frequency = 0; frequency < transfer->frequencyCount; ++frequency) {
        N60MIMOComplex normal[N60_MIMO_MAX_SOURCES][N60_MIMO_MAX_SOURCES] = {0};
        N60MIMOComplex rhs[N60_MIMO_MAX_SOURCES][N60_MIMO_MAX_SOURCES] = {0};

        for (uint32_t row = 0; row < n; ++row) {
            for (uint32_t column = 0; column < n; ++column) {
                N60MIMOComplex sum = {0};
                for (uint32_t measurement = 0; measurement < m; ++measurement) {
                    const double weight = transfer->measurementWeights[measurement];
                    const N60MIMOComplex hRow = transfer->measured[
                        N60MIMOMeasuredOffset(frequency, measurement, row)
                    ];
                    const N60MIMOComplex hColumn = transfer->measured[
                        N60MIMOMeasuredOffset(frequency, measurement, column)
                    ];
                    sum = N60MIMOComplexAdd(
                        sum,
                        N60MIMOComplexScale(
                            N60MIMOComplexMultiply(N60MIMOComplexConjugate(hRow), hColumn),
                            weight
                        )
                    );
                }
                if (row == column) sum.real += settings.regularization;
                normal[row][column] = sum;
            }

            for (uint32_t target = 0; target < targetCount; ++target) {
                N60MIMOComplex sum = {0};
                for (uint32_t measurement = 0; measurement < m; ++measurement) {
                    const double weight = transfer->measurementWeights[measurement];
                    const N60MIMOComplex h = transfer->measured[
                        N60MIMOMeasuredOffset(frequency, measurement, row)
                    ];
                    const N60MIMOComplex d = desired[
                        ((size_t)frequency * N60_MIMO_MAX_MEASUREMENTS + measurement)
                            * N60_MIMO_MAX_SOURCES + target
                    ];
                    if (!isfinite(d.real) || !isfinite(d.imaginary)) return false;
                    sum = N60MIMOComplexAdd(
                        sum,
                        N60MIMOComplexScale(
                            N60MIMOComplexMultiply(N60MIMOComplexConjugate(h), d),
                            weight
                        )
                    );
                }
                rhs[row][target] = sum;
            }
        }

        if (!N60MIMOSolveComplexSystem(n, targetCount, normal, rhs)) return false;

        for (uint32_t target = 0; target < targetCount; ++target) {
            double largestMagnitude = 0.0;
            for (uint32_t source = 0; source < n; ++source) {
                const double magnitude = sqrt(N60MIMOComplexPower(rhs[source][target]));
                if (!isfinite(magnitude)) return false;
                if (magnitude > largestMagnitude) largestMagnitude = magnitude;
            }
            const double safetyScale = largestMagnitude > maximumCoefficient
                ? maximumCoefficient / largestMagnitude
                : 1.0;
            design.targetSafetyScale[frequency][target] = (float)safetyScale;
            for (uint32_t source = 0; source < n; ++source) {
                design.correction[N60MIMOCorrectionOffset(frequency, source, target)] =
                    N60MIMOComplexScale(rhs[source][target], safetyScale);
            }
        }

        double residual = 0.0;
        double totalWeight = 0.0;
        for (uint32_t measurement = 0; measurement < m; ++measurement) {
            const double weight = transfer->measurementWeights[measurement];
            if (weight <= 0.0) continue;
            totalWeight += weight;
            for (uint32_t target = 0; target < targetCount; ++target) {
                N60MIMOComplex predicted = {0};
                for (uint32_t source = 0; source < n; ++source) {
                    predicted = N60MIMOComplexAdd(
                        predicted,
                        N60MIMOComplexMultiply(
                            transfer->measured[N60MIMOMeasuredOffset(frequency, measurement, source)],
                            design.correction[N60MIMOCorrectionOffset(frequency, source, target)]
                        )
                    );
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
        if (totalWeight <= 0.0) return false;
        design.weightedResidualPower[frequency] = residual / (totalWeight * (double)targetCount);
        if (!isfinite(design.weightedResidualPower[frequency])) return false;
    }

    *designOut = design;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
