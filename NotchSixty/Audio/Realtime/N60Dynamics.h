#ifndef N60Dynamics_h
#define N60Dynamics_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"
#include "N60Crossover.h"
#include "N60SpectralDenoiser.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MULTIBAND_BAND_COUNT 3
#define N60_MAX_INFRASONIC_SECTIONS 8
#define N60_MAX_MAINS_HARMONICS 16
#define N60_MAINS_DETECTOR_BIN_COUNT 25

typedef enum {
    N60InfrasonicSlope24DBPerOctave = 0,
    N60InfrasonicSlope48DBPerOctave = 1,
    N60InfrasonicSlope96DBPerOctave = 2,
} N60InfrasonicSlope;

typedef enum {
    N60StereoModeStereo = 0,
    N60StereoModeWideMono = 1,
    N60StereoModeTrueMono = 2,
} N60StereoMode;

typedef struct {
    N60StereoMode mode;
} N60StereoModeSnapshot;

typedef struct {
    bool enabled;
    bool monoLowBand;
    double lowMidFrequencyHz;
    double midHighFrequencyHz;
    float lowWidth;
    float midWidth;
    float highWidth;
    uint32_t sectionCount;
    N60BiquadCoefficients lowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients highPass[N60_MAX_CROSSOVER_SECTIONS];
} N60StereoWidenerSnapshot;

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
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} N60MainsNotchCoefficients;

typedef struct {
    double z1;
    double z2;
} N60MainsNotchState;

typedef struct {
    bool enabled;
    double fundamentalHz;
    uint32_t harmonicCount;
    float q;
    float depthsDB[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchCoefficients filters[N60_MAX_MAINS_HARMONICS];
} N60MainsNotchSnapshot;

typedef struct {
    bool enabled;
    double searchCenterHz;
    double searchStartHz;
    double binSpacingHz;
    uint32_t decimationFactor;
    uint32_t windowSamples;
    float oscillatorStepCos[N60_MAINS_DETECTOR_BIN_COUNT];
    float oscillatorStepSin[N60_MAINS_DETECTOR_BIN_COUNT];
} N60MainsHumDetectorSnapshot;

typedef struct {
    bool enabled;
    bool dialogueGateEnabled;
    float targetLUFS;
    float maxCorrectionDB;
    float attackCoefficient;
    float releaseCoefficient;
    float measurementCoefficient;
    N60BiquadCoefficients kWeightHighPass;
    N60BiquadCoefficients kWeightShelf;
} N60LoudnessMatchSnapshot;

typedef struct {
    bool enabled;
    float strength;
    float fullContourMasterGainLinear;
    float flatContourMasterGainLinear;
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
    N60StereoModeSnapshot stereoMode;
    N60StereoWidenerSnapshot stereoWidener;
    N60DCOffsetFilterSnapshot dcOffsetFilter;
    N60InfrasonicFilterSnapshot infrasonicFilter;
    N60MainsNotchSnapshot mainsNotch;
    N60MainsHumDetectorSnapshot mainsHumDetector;
    N60SpectralDenoiserSnapshot spectralDenoiser;
    N60LoudnessMatchSnapshot loudnessMatch;
    N60LoudnessContourSnapshot loudnessContour;
    N60DeEsserSnapshot deEsser;
    N60MultibandCompressorSnapshot multibandCompressor;
    N60CompressorSnapshot compressor;
    N60ExpanderSnapshot expander;
    N60PauseGateSnapshot pauseGate;
    float bypassTransitionCoefficient;
} N60DynamicsSnapshot;

typedef struct {
    float stereoMatrixLL;
    float stereoMatrixLR;
    float stereoMatrixRL;
    float stereoMatrixRR;
    float widenerLowWidth;
    float widenerMidWidth;
    float widenerHighWidth;
    N60BiquadState widenerLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState widenerHighPass[N60_MAX_CROSSOVER_SECTIONS];
    float dcPreviousInputLeft;
    float dcPreviousInputRight;
    float dcPreviousOutputLeft;
    float dcPreviousOutputRight;
    float dcMix;
    N60BiquadState infrasonicLeft[N60_MAX_INFRASONIC_SECTIONS];
    N60BiquadState infrasonicRight[N60_MAX_INFRASONIC_SECTIONS];
    float infrasonicMix;
    N60MainsNotchCoefficients mainsNotchCurrentFilters[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchCoefficients mainsNotchPendingFilters[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchRight[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchPendingLeft[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchPendingRight[N60_MAX_MAINS_HARMONICS];
    double mainsNotchCurrentFundamentalHz;
    double mainsNotchPendingFundamentalHz;
    float mainsNotchCurrentQ;
    float mainsNotchPendingQ;
    uint32_t mainsNotchCurrentHarmonicCount;
    uint32_t mainsNotchPendingHarmonicCount;
    float mainsNotchCurrentDepthsDB[N60_MAX_MAINS_HARMONICS];
    float mainsNotchPendingDepthsDB[N60_MAX_MAINS_HARMONICS];
    uint32_t mainsNotchTransitionFramesTotal;
    uint32_t mainsNotchTransitionFramesRemaining;
    bool mainsNotchInitialized;
    float mainsNotchMix;
    uint32_t mainsDetectorDecimationCounter;
    uint32_t mainsDetectorSampleCount;
    double mainsDetectorOscCos[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorOscSin[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorReal[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorImag[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorWindowEnergy;
    float mainsDetectedFrequencyHz;
    float mainsDetectionConfidence;
    N60BiquadState loudnessKWeightHighPassLeft;
    N60BiquadState loudnessKWeightHighPassRight;
    N60BiquadState loudnessKWeightShelfLeft;
    N60BiquadState loudnessKWeightShelfRight;
    float loudnessMeanSquare;
    float loudnessMatchGainDB;
    bool loudnessMeasurementPrimed;
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
    float mainsDetectedFrequencyHz;
    float mainsDetectionConfidence;
    float deEsserGainReductionDB;
    float multibandLowGainReductionDB;
    float multibandMidGainReductionDB;
    float multibandHighGainReductionDB;
    float loudnessShortTermLUFS;
    float loudnessMatchGainDB;
    float loudnessContourScale;
    float compressorGainReductionDB;
    float expanderAttenuationDB;
    float pauseGateGain;
    bool pauseGateOpen;
} N60DynamicsTelemetry;

N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate);

bool N60DynamicsSnapshotSetStereoMode(
    N60DynamicsSnapshot * _Nonnull snapshot,
    N60StereoMode mode
);

bool N60DynamicsSnapshotSetStereoWidener(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    bool monoLowBand,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    float lowWidth,
    float midWidth,
    float highWidth
);

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

bool N60DynamicsSnapshotSetMainsNotch(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double fundamentalHz,
    uint32_t harmonicCount,
    float q,
    const float * _Nonnull depthsDB,
    uint32_t depthCount
);

bool N60DynamicsSnapshotSetMainsHumDetector(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double searchCenterHz
);

bool N60DynamicsSnapshotSetSpectralDenoiser(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand
);

bool N60DynamicsSnapshotSetLoudnessMatch(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    bool dialogueGateEnabled,
    float targetLUFS,
    float maxCorrectionDB,
    float attackSeconds,
    float releaseSeconds
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
void N60DynamicsProcessCoreStereoFrameWithMasterGain(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float masterGainLinear,
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