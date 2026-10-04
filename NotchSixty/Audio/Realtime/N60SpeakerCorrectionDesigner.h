#ifndef N60SpeakerCorrectionDesigner_h
#define N60SpeakerCorrectionDesigner_h

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

#define N60_SPEAKER_CORRECTION_MAX_BANDS 8u
#define N60_SPEAKER_CORRECTION_PI 3.14159265358979323846

typedef struct {
    uint32_t maximumBandCount;
    float maximumBoostDB;
    float maximumCutDB;
    float minimumCorrectionHz;
    float maximumCorrectionHz;
    float minimumUsefulErrorDB;
    float correctionDamping;
    float defaultQ;
    float minimumBandSpacingOctaves;
} N60SpeakerCorrectionSettings;

typedef struct {
    bool valid;
    N60ProgramChannelRole role;
    float trimDB;
    uint32_t delayFrames;
    bool polarityInverted;
    uint32_t bandCount;
    N60BiquadBandSnapshot bands[N60_SPEAKER_CORRECTION_MAX_BANDS];
    float preCorrectionRMSErrorDB;
    float postCorrectionRMSErrorDB;
    float seatVarianceDBSquared;
} N60SpeakerCorrectionSourceDesign;

typedef struct {
    uint32_t sourceCount;
    N60SpeakerCorrectionSourceDesign sources[N60_MAX_PROGRAM_CHANNELS];
} N60SpeakerCorrectionPlan;

static inline N60SpeakerCorrectionSettings N60SpeakerCorrectionSettingsMakeDefault(void) {
    return (N60SpeakerCorrectionSettings){
        .maximumBandCount = 6u,
        .maximumBoostDB = 3.0f,
        .maximumCutDB = 10.0f,
        .minimumCorrectionHz = 20.0f,
        .maximumCorrectionHz = 20000.0f,
        .minimumUsefulErrorDB = 0.75f,
        .correctionDamping = 0.72f,
        .defaultQ = 1.15f,
        .minimumBandSpacingOctaves = 0.28f,
    };
}

static inline bool N60SpeakerCorrectionSettingsIsValid(
    N60SpeakerCorrectionSettings settings,
    double sampleRate
) {
    return settings.maximumBandCount > 0u
        && settings.maximumBandCount <= N60_SPEAKER_CORRECTION_MAX_BANDS
        && isfinite(settings.maximumBoostDB)
        && settings.maximumBoostDB >= 0.0f
        && settings.maximumBoostDB <= 12.0f
        && isfinite(settings.maximumCutDB)
        && settings.maximumCutDB >= 0.0f
        && settings.maximumCutDB <= 24.0f
        && isfinite(settings.minimumCorrectionHz)
        && settings.minimumCorrectionHz > 0.0f
        && isfinite(settings.maximumCorrectionHz)
        && settings.maximumCorrectionHz > settings.minimumCorrectionHz
        && settings.maximumCorrectionHz < (float)(sampleRate * 0.5)
        && isfinite(settings.minimumUsefulErrorDB)
        && settings.minimumUsefulErrorDB >= 0.0f
        && isfinite(settings.correctionDamping)
        && settings.correctionDamping > 0.0f
        && settings.correctionDamping <= 1.0f
        && isfinite(settings.defaultQ)
        && settings.defaultQ >= 0.25f
        && settings.defaultQ <= 8.0f
        && isfinite(settings.minimumBandSpacingOctaves)
        && settings.minimumBandSpacingOctaves >= 0.0f
        && settings.minimumBandSpacingOctaves <= 2.0f;
}

static inline float N60SpeakerCorrectionClampGain(
    float requestedGainDB,
    N60SpeakerCorrectionSettings settings
) {
    if (requestedGainDB > settings.maximumBoostDB) return settings.maximumBoostDB;
    if (requestedGainDB < -settings.maximumCutDB) return -settings.maximumCutDB;
    return requestedGainDB;
}

static inline float N60SpeakerCorrectionBiquadMagnitudeDB(
    N60BiquadCoefficients coefficients,
    double sampleRate,
    double frequencyHz
) {
    const double omega = 2.0 * N60_SPEAKER_CORRECTION_PI * frequencyHz / sampleRate;
    const double cosine = cos(omega);
    const double sine = sin(omega);
    const double cos2 = cos(2.0 * omega);
    const double sin2 = sin(2.0 * omega);

    const double numeratorReal = coefficients.b0
        + coefficients.b1 * cosine
        + coefficients.b2 * cos2;
    const double numeratorImaginary = -coefficients.b1 * sine
        - coefficients.b2 * sin2;
    const double denominatorReal = 1.0
        + coefficients.a1 * cosine
        + coefficients.a2 * cos2;
    const double denominatorImaginary = -coefficients.a1 * sine
        - coefficients.a2 * sin2;

    const double numeratorPower = numeratorReal * numeratorReal
        + numeratorImaginary * numeratorImaginary;
    const double denominatorPower = denominatorReal * denominatorReal
        + denominatorImaginary * denominatorImaginary;
    if (!isfinite(numeratorPower)
        || !isfinite(denominatorPower)
        || numeratorPower <= 0.0
        || denominatorPower <= 1.0e-30) {
        return 0.0f;
    }
    return (float)(10.0 * log10(numeratorPower / denominatorPower));
}

static inline float N60SpeakerCorrectionPlanResponseDB(
    const N60SpeakerCorrectionSourceDesign * _Nonnull design,
    double sampleRate,
    double frequencyHz
) {
    if (design == NULL) return 0.0f;
    float result = 0.0f;
    for (uint32_t band = 0; band < design->bandCount; ++band) {
        if (!design->bands[band].enabled) continue;
        result += N60SpeakerCorrectionBiquadMagnitudeDB(
            design->bands[band].coefficients,
            sampleRate,
            frequencyHz
        );
    }
    return result;
}

static inline float N60SpeakerCorrectionRMSError(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const float * _Nonnull measuredMagnitudeDB,
    const float * _Nonnull targetMagnitudeDB,
    const N60SpeakerCorrectionSourceDesign * _Nonnull design,
    N60SpeakerCorrectionSettings settings
) {
    double sumSquared = 0.0;
    uint32_t count = 0u;
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        const float hz = matrix->frequenciesHz[frequency];
        if (hz < settings.minimumCorrectionHz || hz > settings.maximumCorrectionHz) continue;
        const float correction = N60SpeakerCorrectionPlanResponseDB(
            design,
            matrix->sampleRate,
            hz
        );
        const double error = (double)targetMagnitudeDB[frequency]
            - ((double)measuredMagnitudeDB[frequency] + (double)correction);
        sumSquared += error * error;
        count += 1u;
    }
    if (count == 0u) return INFINITY;
    return (float)sqrt(sumSquared / (double)count);
}

static inline bool N60SpeakerCorrectionFrequencyIsSpaced(
    const N60SpeakerCorrectionSourceDesign * _Nonnull design,
    float frequencyHz,
    float minimumBandSpacingOctaves
) {
    if (minimumBandSpacingOctaves <= 0.0f) return true;
    for (uint32_t band = 0; band < design->bandCount; ++band) {
        const float existing = (float)design->bands[band].frequencyHz;
        if (existing <= 0.0f) continue;
        const float octaves = fabsf(log2f(frequencyHz / existing));
        if (octaves < minimumBandSpacingOctaves) return false;
    }
    return true;
}

static inline bool N60SpeakerCorrectionMakePeakingBand(
    double sampleRate,
    float frequencyHz,
    float gainDB,
    float q,
    N60BiquadBandSnapshot * _Nonnull bandOut
) {
    if (bandOut == NULL) return false;
    N60BiquadCoefficients coefficients = {0};
    if (!N60BiquadDesign(
            N60BiquadFilterTypePeaking,
            sampleRate,
            frequencyHz,
            gainDB,
            q,
            &coefficients)) {
        return false;
    }
    *bandOut = (N60BiquadBandSnapshot){
        .enabled = true,
        .type = N60BiquadFilterTypePeaking,
        .frequencyHz = frequencyHz,
        .gainDB = gainDB,
        .q = q,
        .coefficients = coefficients,
    };
    return true;
}

/// Offline/control-plane bounded PEQ fitter. It operates on the weighted spatial
/// magnitude response, never averages seat phase, limits boost aggressively, and
/// refuses to retain a new band unless the full-band RMS target error improves.
static inline bool N60SpeakerCorrectionDesignSource(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    uint32_t calibrationSourceIndex,
    const float * _Nonnull targetMagnitudeDB,
    const N60SpeakerAlignmentPlan * _Nullable alignment,
    N60SpeakerCorrectionSettings settings,
    N60SpeakerCorrectionSourceDesign * _Nonnull designOut
) {
    if (matrix == NULL
        || targetMagnitudeDB == NULL
        || designOut == NULL
        || calibrationSourceIndex >= matrix->sourceCount
        || matrix->sources[calibrationSourceIndex].kind != N60CalibrationSourceKindProgramSpeaker
        || !N60SpeakerCorrectionSettingsIsValid(settings, matrix->sampleRate)) {
        return false;
    }
    for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
        if (!isfinite(targetMagnitudeDB[frequency])) return false;
    }

    float measured[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    float seatVariance = 0.0f;
    if (!N60MultichannelCalibrationWeightedMagnitude(
            matrix,
            calibrationSourceIndex,
            measured,
            &seatVariance)) {
        return false;
    }

    N60SpeakerCorrectionSourceDesign design = {0};
    design.valid = true;
    design.role = matrix->sources[calibrationSourceIndex].role;
    design.seatVarianceDBSquared = seatVariance;
    if (alignment != NULL
        && calibrationSourceIndex < alignment->sourceCount
        && alignment->sources[calibrationSourceIndex].valid) {
        design.trimDB = alignment->sources[calibrationSourceIndex].trimDB;
        design.delayFrames = alignment->sources[calibrationSourceIndex].delayFrames;
        design.polarityInverted = alignment->sources[calibrationSourceIndex].polarityInverted;
    }

    design.preCorrectionRMSErrorDB = N60SpeakerCorrectionRMSError(
        matrix,
        measured,
        targetMagnitudeDB,
        &design,
        settings
    );
    if (!isfinite(design.preCorrectionRMSErrorDB)) return false;

    float bestRMS = design.preCorrectionRMSErrorDB;
    for (uint32_t iteration = 0; iteration < settings.maximumBandCount; ++iteration) {
        int32_t bestFrequencyIndex = -1;
        float bestAbsError = settings.minimumUsefulErrorDB;
        float requestedGain = 0.0f;

        for (uint32_t frequency = 0; frequency < matrix->frequencyCount; ++frequency) {
            const float hz = matrix->frequenciesHz[frequency];
            if (hz < settings.minimumCorrectionHz || hz > settings.maximumCorrectionHz) continue;
            if (!N60SpeakerCorrectionFrequencyIsSpaced(
                    &design,
                    hz,
                    settings.minimumBandSpacingOctaves)) {
                continue;
            }
            const float correction = N60SpeakerCorrectionPlanResponseDB(
                &design,
                matrix->sampleRate,
                hz
            );
            const float error = targetMagnitudeDB[frequency]
                - (measured[frequency] + correction);
            const float absoluteError = fabsf(error);
            if (absoluteError > bestAbsError) {
                bestAbsError = absoluteError;
                bestFrequencyIndex = (int32_t)frequency;
                requestedGain = error;
            }
        }
        if (bestFrequencyIndex < 0) break;

        const float frequencyHz = matrix->frequenciesHz[(uint32_t)bestFrequencyIndex];
        const float damped = requestedGain * settings.correctionDamping;
        const float gainDB = N60SpeakerCorrectionClampGain(damped, settings);
        if (fabsf(gainDB) < settings.minimumUsefulErrorDB * 0.5f) break;

        N60BiquadBandSnapshot candidateBand = {0};
        if (!N60SpeakerCorrectionMakePeakingBand(
                matrix->sampleRate,
                frequencyHz,
                gainDB,
                settings.defaultQ,
                &candidateBand)) {
            return false;
        }

        N60SpeakerCorrectionSourceDesign candidate = design;
        candidate.bands[candidate.bandCount++] = candidateBand;
        const float candidateRMS = N60SpeakerCorrectionRMSError(
            matrix,
            measured,
            targetMagnitudeDB,
            &candidate,
            settings
        );
        if (!isfinite(candidateRMS)) return false;
        if (candidateRMS + 1.0e-4f < bestRMS) {
            design = candidate;
            bestRMS = candidateRMS;
        } else {
            break;
        }
    }

    design.postCorrectionRMSErrorDB = bestRMS;
    *designOut = design;
    return true;
}

static inline bool N60SpeakerCorrectionDesignPlan(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const float * _Nonnull targetMagnitudeDB,
    N60SpeakerCorrectionSettings settings,
    N60SpeakerCorrectionPlan * _Nonnull planOut
) {
    if (matrix == NULL || targetMagnitudeDB == NULL || planOut == NULL) return false;
    N60SpeakerAlignmentPlan alignment = {0};
    if (!N60MultichannelCalibrationMakeSpeakerAlignmentPlan(matrix, &alignment)) return false;

    N60SpeakerCorrectionPlan plan = {0};
    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        if (matrix->sources[source].kind != N60CalibrationSourceKindProgramSpeaker) continue;
        if (plan.sourceCount >= N60_MAX_PROGRAM_CHANNELS) return false;
        if (!N60SpeakerCorrectionDesignSource(
                matrix,
                source,
                targetMagnitudeDB,
                &alignment,
                settings,
                &plan.sources[plan.sourceCount])) {
            return false;
        }
        plan.sourceCount += 1u;
    }
    if (plan.sourceCount == 0u) return false;
    *planOut = plan;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
