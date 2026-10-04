#ifndef N60MultichannelCalibration_h
#define N60MultichannelCalibration_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60MultichannelBassManagement.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CALIBRATION_MAX_SEATS 8u
#define N60_CALIBRATION_MAX_SOURCES (N60_MAX_PROGRAM_CHANNELS + N60_MAX_SUBWOOFER_OUTPUTS)
#define N60_CALIBRATION_MAX_FREQUENCY_BINS 128u
#define N60_CALIBRATION_MAX_TRIM_ATTENUATION_DB 24.0f

typedef enum {
    N60CalibrationSourceKindProgramSpeaker = 0,
    N60CalibrationSourceKindSubwoofer = 1,
} N60CalibrationSourceKind;

typedef struct {
    N60CalibrationSourceKind kind;
    N60ProgramChannelRole role;
    uint32_t subwooferIndex;
} N60CalibrationSourceDescriptor;

typedef struct {
    bool included;
    float weight;
} N60CalibrationSeat;

typedef struct {
    bool valid;
    uint32_t directArrivalFrame;
    int8_t directPolarity;
    float broadbandLevelDB;
    float magnitudeDB[N60_CALIBRATION_MAX_FREQUENCY_BINS];
    float phaseRadians[N60_CALIBRATION_MAX_FREQUENCY_BINS];
} N60CalibrationMeasuredResponse;

typedef struct {
    double sampleRate;
    uint32_t seatCount;
    uint32_t sourceCount;
    uint32_t frequencyCount;
    float frequenciesHz[N60_CALIBRATION_MAX_FREQUENCY_BINS];
    N60CalibrationSeat seats[N60_CALIBRATION_MAX_SEATS];
    N60CalibrationSourceDescriptor sources[N60_CALIBRATION_MAX_SOURCES];
    N60CalibrationMeasuredResponse responses[N60_CALIBRATION_MAX_SOURCES][N60_CALIBRATION_MAX_SEATS];
} N60MultichannelCalibrationMatrix;

typedef struct {
    bool valid;
    float trimDB;
    uint32_t delayFrames;
    bool polarityInverted;
    float weightedArrivalFrame;
    float weightedLevelDB;
    float seatVarianceDBSquared;
} N60SpeakerAlignmentResult;

typedef struct {
    uint32_t sourceCount;
    uint32_t referenceArrivalFrame;
    float commonLevelDB;
    N60SpeakerAlignmentResult sources[N60_CALIBRATION_MAX_SOURCES];
} N60SpeakerAlignmentPlan;

static inline bool N60CalibrationSourceDescriptorIsValid(
    N60CalibrationSourceDescriptor source,
    uint32_t subwooferCount
) {
    switch (source.kind) {
    case N60CalibrationSourceKindProgramSpeaker:
        return N60ProgramChannelRoleIsSemantic(source.role)
            && source.role != N60ProgramChannelRoleLowFrequencyEffects;
    case N60CalibrationSourceKindSubwoofer:
        return source.role == N60ProgramChannelRoleUnused
            && source.subwooferIndex < subwooferCount;
    default:
        return false;
    }
}

/// Control-plane campaign model. Native LFE is not a physical acoustic source;
/// all non-LFE semantic speaker roles are measured individually, followed by
/// each physical subwoofer destination.
static inline N60MultichannelCalibrationMatrix N60MultichannelCalibrationMatrixMake(
    double sampleRate,
    N60ProgramChannelLayout programLayout,
    uint32_t subwooferCount,
    uint32_t seatCount,
    const float * _Nullable frequenciesHz,
    uint32_t frequencyCount
) {
    N60MultichannelCalibrationMatrix matrix = {0};
    if (!isfinite(sampleRate)
        || sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS
        || seatCount == 0u
        || seatCount > N60_CALIBRATION_MAX_SEATS
        || frequencyCount == 0u
        || frequencyCount > N60_CALIBRATION_MAX_FREQUENCY_BINS
        || frequenciesHz == NULL) {
        return matrix;
    }

    float previousFrequency = 0.0f;
    for (uint32_t frequency = 0; frequency < frequencyCount; ++frequency) {
        const float value = frequenciesHz[frequency];
        if (!isfinite(value)
            || value <= previousFrequency
            || value >= (float)(sampleRate * 0.5)) {
            return (N60MultichannelCalibrationMatrix){0};
        }
        matrix.frequenciesHz[frequency] = value;
        previousFrequency = value;
    }

    matrix.sampleRate = sampleRate;
    matrix.seatCount = seatCount;
    matrix.frequencyCount = frequencyCount;
    for (uint32_t seat = 0; seat < seatCount; ++seat) {
        matrix.seats[seat].included = true;
        matrix.seats[seat].weight = 1.0f;
    }

    uint32_t sourceCount = 0u;
    for (uint32_t channel = 0; channel < programLayout.channelCount; ++channel) {
        const N60ProgramChannelRole role = programLayout.channels[channel];
        if (role == N60ProgramChannelRoleLowFrequencyEffects) continue;
        if (sourceCount >= N60_CALIBRATION_MAX_SOURCES) return (N60MultichannelCalibrationMatrix){0};
        matrix.sources[sourceCount++] = (N60CalibrationSourceDescriptor){
            .kind = N60CalibrationSourceKindProgramSpeaker,
            .role = role,
            .subwooferIndex = UINT32_MAX,
        };
    }
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        if (sourceCount >= N60_CALIBRATION_MAX_SOURCES) return (N60MultichannelCalibrationMatrix){0};
        matrix.sources[sourceCount++] = (N60CalibrationSourceDescriptor){
            .kind = N60CalibrationSourceKindSubwoofer,
            .role = N60ProgramChannelRoleUnused,
            .subwooferIndex = sub,
        };
    }
    matrix.sourceCount = sourceCount;
    return matrix;
}

static inline bool N60MultichannelCalibrationSetSeat(
    N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t seatIndex,
    bool included,
    float weight
) {
    if (matrix == NULL
        || seatIndex >= matrix->seatCount
        || !isfinite(weight)
        || weight < 0.0f) {
        return false;
    }
    matrix->seats[seatIndex].included = included;
    matrix->seats[seatIndex].weight = weight;
    return true;
}

static inline bool N60MultichannelCalibrationSetResponse(
    N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t sourceIndex,
    uint32_t seatIndex,
    uint32_t directArrivalFrame,
    int8_t directPolarity,
    float broadbandLevelDB,
    const float * _Nonnull magnitudeDB,
    const float * _Nonnull phaseRadians
) {
    if (matrix == NULL
        || sourceIndex >= matrix->sourceCount
        || seatIndex >= matrix->seatCount
        || (directPolarity != 1 && directPolarity != -1)
        || !isfinite(broadbandLevelDB)
        || magnitudeDB == NULL
        || phaseRadians == NULL) {
        return false;
    }
    N60CalibrationMeasuredResponse response = {0};
    response.valid = true;
    response.directArrivalFrame = directArrivalFrame;
    response.directPolarity = directPolarity;
    response.broadbandLevelDB = broadbandLevelDB;
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        if (!isfinite(magnitudeDB[frequency]) || !isfinite(phaseRadians[frequency])) return false;
        response.magnitudeDB[frequency] = magnitudeDB[frequency];
        response.phaseRadians[frequency] = phaseRadians[frequency];
    }
    matrix->responses[sourceIndex][seatIndex] = response;
    return true;
}

static inline bool N60MultichannelCalibrationMatrixIsValid(
    const N60MultichannelCalibrationMatrix * _Nullable matrix,
    uint32_t expectedSubwooferCount
) {
    if (matrix == NULL
        || !isfinite(matrix->sampleRate)
        || matrix->sampleRate <= 0.0
        || matrix->seatCount == 0u
        || matrix->seatCount > N60_CALIBRATION_MAX_SEATS
        || matrix->sourceCount == 0u
        || matrix->sourceCount > N60_CALIBRATION_MAX_SOURCES
        || matrix->frequencyCount == 0u
        || matrix->frequencyCount > N60_CALIBRATION_MAX_FREQUENCY_BINS
        || expectedSubwooferCount > N60_MAX_SUBWOOFER_OUTPUTS) {
        return false;
    }

    float previousFrequency = 0.0f;
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        const float value = matrix->frequenciesHz[frequency];
        if (!isfinite(value)
            || value <= previousFrequency
            || value >= (float)(matrix->sampleRate * 0.5)) {
            return false;
        }
        previousFrequency = value;
    }

    bool hasIncludedWeight = false;
    uint32_t subSources = 0u;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!isfinite(matrix->seats[seat].weight) || matrix->seats[seat].weight < 0.0f) return false;
        if (matrix->seats[seat].included && matrix->seats[seat].weight > 0.0f) hasIncludedWeight = true;
    }
    if (!hasIncludedWeight) return false;

    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        if (!N60CalibrationSourceDescriptorIsValid(matrix->sources[source], expectedSubwooferCount)) return false;
        if (matrix->sources[source].kind == N60CalibrationSourceKindSubwoofer) subSources += 1u;
        for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
            if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
            const N60CalibrationMeasuredResponse response = matrix->responses[source][seat];
            if (!response.valid
                || (response.directPolarity != 1 && response.directPolarity != -1)
                || !isfinite(response.broadbandLevelDB)) {
                return false;
            }
            for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
                if (!isfinite(response.magnitudeDB[frequency])
                    || !isfinite(response.phaseRadians[frequency])) {
                    return false;
                }
            }
        }
    }
    return subSources == expectedSubwooferCount;
}

static inline float N60CalibrationIncludedWeight(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix
) {
    float total = 0.0f;
    if (matrix == NULL) return total;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (matrix->seats[seat].included && matrix->seats[seat].weight > 0.0f) {
            total += matrix->seats[seat].weight;
        }
    }
    return total;
}

static inline bool N60MultichannelCalibrationWeightedMagnitude(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t sourceIndex,
    float * _Nonnull magnitudeDBOut,
    float * _Nullable seatVarianceDBSquaredOut
) {
    if (matrix == NULL
        || magnitudeDBOut == NULL
        || sourceIndex >= matrix->sourceCount) {
        return false;
    }
    const float totalWeight = N60CalibrationIncludedWeight(matrix);
    if (!isfinite(totalWeight) || totalWeight <= 0.0f) return false;

    float mean[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
        const N60CalibrationMeasuredResponse *response = &matrix->responses[sourceIndex][seat];
        if (!response->valid) return false;
        const float normalized = matrix->seats[seat].weight / totalWeight;
        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            mean[frequency] += response->magnitudeDB[frequency] * normalized;
        }
    }

    float variance = 0.0f;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
        const N60CalibrationMeasuredResponse *response = &matrix->responses[sourceIndex][seat];
        const float normalized = matrix->seats[seat].weight / totalWeight;
        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            const float difference = response->magnitudeDB[frequency] - mean[frequency];
            variance += normalized * difference * difference / (float)matrix->frequencyCount;
        }
    }

    memcpy(magnitudeDBOut, mean, matrix->frequencyCount * sizeof(float));
    if (seatVarianceDBSquaredOut != NULL) *seatVarianceDBSquaredOut = variance;
    return true;
}

/// Creates a safe speaker-alignment plan from all included seats. The latest
/// weighted acoustic arrival becomes the time reference, so compensation adds
/// delay only. The quietest weighted program speaker becomes the level reference,
/// so calibration trim never adds digital gain/headroom pressure.
static inline bool N60MultichannelCalibrationMakeSpeakerAlignmentPlan(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    N60SpeakerAlignmentPlan * _Nonnull planOut
) {
    if (matrix == NULL || planOut == NULL) return false;
    const float totalWeight = N60CalibrationIncludedWeight(matrix);
    if (!isfinite(totalWeight) || totalWeight <= 0.0f) return false;

    N60SpeakerAlignmentPlan plan = {0};
    plan.sourceCount = matrix->sourceCount;
    float latestArrival = 0.0f;
    float quietestLevel = INFINITY;
    bool hasProgramSpeaker = false;

    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        if (matrix->sources[source].kind != N60CalibrationSourceKindProgramSpeaker) continue;
        float arrival = 0.0f;
        float level = 0.0f;
        float positiveWeight = 0.0f;
        float negativeWeight = 0.0f;
        for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
            if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
            const N60CalibrationMeasuredResponse response = matrix->responses[source][seat];
            if (!response.valid) return false;
            const float normalized = matrix->seats[seat].weight / totalWeight;
            arrival += (float)response.directArrivalFrame * normalized;
            level += response.broadbandLevelDB * normalized;
            if (response.directPolarity > 0) positiveWeight += matrix->seats[seat].weight;
            else negativeWeight += matrix->seats[seat].weight;
        }
        plan.sources[source].valid = true;
        plan.sources[source].weightedArrivalFrame = arrival;
        plan.sources[source].weightedLevelDB = level;
        plan.sources[source].polarityInverted = negativeWeight > positiveWeight;
        if (arrival > latestArrival) latestArrival = arrival;
        if (level < quietestLevel) quietestLevel = level;
        hasProgramSpeaker = true;
    }
    if (!hasProgramSpeaker || !isfinite(quietestLevel)) return false;

    plan.referenceArrivalFrame = (uint32_t)ceilf(latestArrival);
    plan.commonLevelDB = quietestLevel;
    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        N60SpeakerAlignmentResult *result = &plan.sources[source];
        if (!result->valid) continue;
        const float delay = fmaxf(0.0f, (float)plan.referenceArrivalFrame - result->weightedArrivalFrame);
        result->delayFrames = (uint32_t)llroundf(delay);
        result->trimDB = quietestLevel - result->weightedLevelDB;
        if (result->trimDB < -N60_CALIBRATION_MAX_TRIM_ATTENUATION_DB) {
            result->trimDB = -N60_CALIBRATION_MAX_TRIM_ATTENUATION_DB;
        }

        float variance = 0.0f;
        for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
            if (!matrix->seats[seat].included || matrix->seats[seat].weight <= 0.0f) continue;
            const N60CalibrationMeasuredResponse response = matrix->responses[source][seat];
            const float normalized = matrix->seats[seat].weight / totalWeight;
            const float difference = response.broadbandLevelDB - result->weightedLevelDB;
            variance += normalized * difference * difference;
        }
        result->seatVarianceDBSquared = variance;
    }
    *planOut = plan;
    return true;
}

static inline int32_t N60MultichannelCalibrationSourceIndexForRole(
    const N60MultichannelCalibrationMatrix * _Nullable matrix,
    N60ProgramChannelRole role
) {
    if (matrix == NULL) return -1;
    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        if (matrix->sources[source].kind == N60CalibrationSourceKindProgramSpeaker
            && matrix->sources[source].role == role) {
            return (int32_t)source;
        }
    }
    return -1;
}

static inline int32_t N60MultichannelCalibrationSourceIndexForSubwoofer(
    const N60MultichannelCalibrationMatrix * _Nullable matrix,
    uint32_t subwooferIndex
) {
    if (matrix == NULL) return -1;
    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        if (matrix->sources[source].kind == N60CalibrationSourceKindSubwoofer
            && matrix->sources[source].subwooferIndex == subwooferIndex) {
            return (int32_t)source;
        }
    }
    return -1;
}

#ifdef __cplusplus
}
#endif

#endif
