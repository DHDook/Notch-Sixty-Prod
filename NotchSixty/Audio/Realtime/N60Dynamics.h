#ifndef N60Dynamics_h
#define N60Dynamics_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"
#include "N60Crossover.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MULTIBAND_BAND_COUNT 3
#define N60_MAX_INFRASONIC_SECTIONS 8

typedef enum {
    N60InfrasonicSlope24DBPerOctave = 0,
    N60InfrasonicSlope48DBPerOctave = 1,
    N60InfrasonicSlope96DBPerOctave = 2,
} N60InfrasonicSlope;

typedef struct {
    bool enabled;
    float poleCoefficient;
} N60DCOffsetFilterSnapshot;

typedef struct {
    bool enabled;
    double cutoffHz;
    N60InfrasonicSlope slope;
    uint32_t sectionCount;
    N60BiquadCoefficients highPass[N60_MAX_INFRASONIC_SECTIONS];
} N60InfrasonicFilterSnapshot;

typedef struct {
    bool enabled;
    float strength;
    N60BiquadCoefficients lowShelf;
    N60BiquadCoefficients highShelf;
} N60LoudnessContourSnapshot;

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
    bool dynamicEQMode;
    double frequencyHz;
    float thresholdDB;
    float ratio;
    float attackCoefficient;
    float releaseCoefficient;
    N60BiquadCoefficients sidechainHighPass;
    N60BiquadCoefficients sidechainLowPass;
} N60DeEsserSnapshot;

typedef struct {
    bool enabled;
    double lowMidFrequencyHz;
    double midHighFrequencyHz;
    N60CrossoverTopology topology;
    uint32_t sectionCount;
    float thresholdDB[N60_MULTIBAND_BAND_COUNT];
    float ratio;
    float kneeWidthDB;
    float attackCoefficient;
    float releaseCoefficient;
    N60BiquadCoefficients lowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients highPass[N60_MAX_CROSSOVER_SECTIONS];
} N60MultibandCompressorSnapshot;

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
    N60DCOffsetFilterSnapshot dcOffsetFilter;
    N60InfrasonicFilterSnapshot infrasonicFilter;
    N60LoudnessContourSnapshot loudnessContour;
    N60DeEsserSnapshot deEsser;
    N60MultibandCompressorSnapshot multibandCompressor;
    N60CompressorSnapshot compressor;
    N60ExpanderSnapshot expander;
    N60PauseGateSnapshot pauseGate;
    float bypassTransitionCoefficient;
} N60DynamicsSnapshot;

typedef struct {
    float dcPreviousInputLeft;
    float dcPreviousInputRight;
    float dcPreviousOutputLeft;
    float dcPreviousOutputRight;
    float dcMix;
    N60BiquadState infrasonicLeft[N60_MAX_INFRASONIC_SECTIONS];
    N60BiquadState infrasonicRight[N60_MAX_INFRASONIC_SECTIONS];
    float infrasonicMix;
    N60BiquadState loudnessLowShelfLeft;
    N60BiquadState loudnessLowShelfRight;
    N60BiquadState loudnessHighShelfLeft;
    N60BiquadState loudnessHighShelfRight;
    float loudnessMix;
    float deEsserGainDB;
    N60BiquadState deEsserHighPassLeft;
    N60BiquadState deEsserHighPassRight;
    N60BiquadState deEsserLowPassLeft;
    N60BiquadState deEsserLowPassRight;
    float multibandGainDB[N60_MULTIBAND_BAND_COUNT];
    N60BiquadState multibandLowPassLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState multibandLowPassRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState multibandHighPassLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState multibandHighPassRight[N60_MAX_CROSSOVER_SECTIONS];
    float compressorGainDB;
    float expanderGainDB;
    float pauseGateGain;
    float gateDetectorEnvelope;
    uint32_t gateBelowThresholdFrames;
    bool gateOpen;
} N60DynamicsRuntime;

typedef struct {
    float deEsserGainReductionDB;
    float multibandLowGainReductionDB;
    float multibandMidGainReductionDB;
    float multibandHighGainReductionDB;
    float compressorGainReductionDB;
    float expanderAttenuationDB;
    float pauseGateGain;
    bool pauseGateOpen;
} N60DynamicsTelemetry;

N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate);

bool N60DynamicsSnapshotSetDCOffsetFilter(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled
);

bool N60DynamicsSnapshotSetInfrasonicFilter(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double cutoffHz,
    N60InfrasonicSlope slope
);

bool N60DynamicsSnapshotSetLoudnessContour(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float strength
);

bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
);

bool N60DynamicsSnapshotSetMultibandCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology topology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB
);

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
void N60DynamicsProcessPreEQStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
void N60DynamicsProcessPauseGateStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
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