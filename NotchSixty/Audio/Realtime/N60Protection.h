#ifndef N60_PROTECTION_H
#define N60_PROTECTION_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_PROTECTION_MAX_SAMPLE_RATE 384000.0
#define N60_PROTECTION_MAX_LOOKAHEAD_MS 20.0f
#define N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES 32768u

typedef enum {
    N60OversamplingFactor1x = 1,
    N60OversamplingFactor2x = 2,
    N60OversamplingFactor4x = 4,
} N60OversamplingFactor;

typedef enum {
    N60GainRiderSpeedFast = 0,
    N60GainRiderSpeedMedium = 1,
    N60GainRiderSpeedSlow = 2,
} N60GainRiderSpeed;

typedef enum {
    N60ClipperCurveQuadratic = 0,
    N60ClipperCurveCubic = 1,
    N60ClipperCurveSine = 2,
    N60ClipperCurveAsymmetricTube = 3,
} N60ClipperCurveType;

typedef struct {
    double sampleRate;
    N60OversamplingFactor oversamplingFactor;
    N60OversamplingFactor effectiveFactor;
    uint32_t latencyFrames;

    bool softClipperEnabled;
    float clipperDriveLinear;
    float clipperThresholdLinear;
    float clipperKneeSmooth;
    N60ClipperCurveType clipperCurve;
    float clipperCompensationLinear;
    float clipperAsymmetryTrimDB;

    bool limiterEnabled;
    float limiterCeilingLinear;
    float limiterAttackMs;
    float limiterReleaseMs;
    float limiterLookAheadMs;
    uint32_t limiterLookAheadFrames;
    uint32_t limiterLookAheadHighSamples;
    uint32_t limiterAttackHighSamples;
    float limiterReleaseCoefficientHigh;
    bool truePeakGuardEnabled;

    bool gainRiderEnabled;
    float gainRiderTargetGRDB;
    float gainRiderMaxReductionDB;
    N60GainRiderSpeed gainRiderSpeed;
    float gainRiderMeasurementCoefficient;
    float gainRiderResponseCoefficient;
} N60ProtectionSnapshot;

typedef struct N60ProtectionRuntime N60ProtectionRuntime;

typedef struct {
    float inputTruePeakLinear;
    float outputTruePeakLinear;
    float limiterGainReductionDB;
    uint64_t limiterSafetyClampSamples;
    float gainRiderAttenuationDB;
    float sustainedLimiterGainReductionDB;
    bool truePeakGuardActive;
} N60ProtectionTelemetry;

N60ProtectionSnapshot N60ProtectionSnapshotMakeBypassed(double sampleRate);

bool N60ProtectionSnapshotSetOversamplingFactor(
    N60ProtectionSnapshot *snapshot,
    N60OversamplingFactor factor
);

bool N60ProtectionSnapshotSetSoftClipper(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float driveDB,
    float thresholdDB,
    float kneeSmooth,
    N60ClipperCurveType curve,
    bool autoCompensateGain
);

bool N60ProtectionSnapshotSetSoftClipperAdvanced(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float driveDB,
    float thresholdDB,
    float kneeSmooth,
    N60ClipperCurveType curve,
    bool autoCompensateGain,
    float asymmetryTrimDB
);

bool N60ProtectionSnapshotSetLimiter(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float ceilingDB,
    float attackMs,
    float releaseMs,
    float lookAheadMs
);

bool N60ProtectionSnapshotSetLimiterAdvanced(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float ceilingDB,
    float attackMs,
    float releaseMs,
    float lookAheadMs,
    bool truePeakGuardEnabled
);

bool N60ProtectionSnapshotSetGainRider(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float targetGainReductionDB,
    float maxReductionDB,
    N60GainRiderSpeed speed
);

bool N60ProtectionSnapshotIsValid(const N60ProtectionSnapshot *snapshot);
uint32_t N60ProtectionSnapshotLatencyFrames(const N60ProtectionSnapshot *snapshot);

N60ProtectionRuntime *N60ProtectionRuntimeCreate(void);
void N60ProtectionRuntimeDestroy(N60ProtectionRuntime *runtime);
void N60ProtectionRuntimeReset(N60ProtectionRuntime *runtime);
void N60ProtectionRuntimeBeginBuffer(N60ProtectionRuntime *runtime);
N60ProtectionTelemetry N60ProtectionRuntimeTelemetry(const N60ProtectionRuntime *runtime);

void N60ProtectionProcessStereoFrame(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot,
    float *left,
    float *right
);

#ifdef __cplusplus
}
#endif

#endif
