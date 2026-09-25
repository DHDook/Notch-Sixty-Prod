#ifndef N60Dynamics_h
#define N60Dynamics_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool enabled;
    float thresholdDB;
    float ratio;
    float kneeWidthDB;
    float makeupGainDB;
    float attackCoefficient;
    float releaseCoefficient;
} N60CompressorSnapshot;

typedef struct {
    bool enabled;
    float thresholdDB;
    float ratio;
    float rangeDB;
    float attackCoefficient;
    float releaseCoefficient;
} N60ExpanderSnapshot;

typedef struct {
    bool enabled;
    float thresholdDBFS;
    float hysteresisDB;
    uint32_t holdFrames;
    float fadeOutCoefficient;
    float fadeInCoefficient;
    float detectorAttackCoefficient;
    float detectorReleaseCoefficient;
} N60PauseGateSnapshot;

typedef struct {
    N60CompressorSnapshot compressor;
    N60ExpanderSnapshot expander;
    N60PauseGateSnapshot pauseGate;
    float bypassTransitionCoefficient;
} N60DynamicsSnapshot;

typedef struct {
    float compressorGainDB;
    float expanderGainDB;
    float pauseGateGain;
    float gateDetectorEnvelope;
    uint32_t gateBelowThresholdFrames;
    bool gateOpen;
} N60DynamicsRuntime;

typedef struct {
    float compressorGainReductionDB;
    float expanderAttenuationDB;
    float pauseGateGain;
    bool pauseGateOpen;
} N60DynamicsTelemetry;

N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate);

bool N60DynamicsSnapshotSetCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB
);

bool N60DynamicsSnapshotSetExpander(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs
);

bool N60DynamicsSnapshotSetPauseGate(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDBFS,
    float holdMs,
    float fadeOutAttackMs,
    float fadeInReleaseMs,
    float hysteresisDB
);

bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot);
void N60DynamicsRuntimeReset(N60DynamicsRuntime * _Nonnull runtime);
void N60DynamicsProcessStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
N60DynamicsTelemetry N60DynamicsRuntimeTelemetry(const N60DynamicsRuntime * _Nonnull runtime);

#ifdef __cplusplus
}
#endif

#endif
