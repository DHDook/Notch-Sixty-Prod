#ifndef N60DynamicEQ_h
#define N60DynamicEQ_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_DYNAMIC_EQ_MAX_BANDS 16u

typedef enum {
    N60DynamicEQDirectionCutOnly = 0,
    N60DynamicEQDirectionBoostOnly = 1,
    N60DynamicEQDirectionBoth = 2,
} N60DynamicEQDirection;

typedef enum {
    N60DynamicEQDetectorPeak = 0,
    N60DynamicEQDetectorRMS = 1,
} N60DynamicEQDetectorMode;

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} N60DynamicEQBiquadCoefficients;

typedef struct {
    bool enabled;
    double frequencyHz;
    float q;
    float staticGainDB;
    float thresholdDB;
    float ratio;
    float rangeDB;
    float attackCoefficient;
    float releaseCoefficient;
    N60DynamicEQDirection direction;
    float boostThresholdDB;
    float boostRatio;
    float maxBoostDB;
    N60DynamicEQDetectorMode detectorMode;
    float rmsCoefficient;
    N60DynamicEQBiquadCoefficients analysisBandPass;
} N60DynamicEQBandSnapshot;

typedef struct {
    bool enabled;
    double sampleRate;
    uint32_t bandCount;
    float bypassTransitionCoefficient;
    N60DynamicEQBandSnapshot bands[N60_DYNAMIC_EQ_MAX_BANDS];
} N60DynamicEQSnapshot;

typedef struct {
    double z1;
    double z2;
} N60DynamicEQBiquadState;

typedef struct {
    N60DynamicEQBiquadState analysisLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState analysisRight[N60_DYNAMIC_EQ_MAX_BANDS];
    float rmsPower[N60_DYNAMIC_EQ_MAX_BANDS];
    float dynamicGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float staticGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float wetMix[N60_DYNAMIC_EQ_MAX_BANDS];
    float detectorLevelDBFS[N60_DYNAMIC_EQ_MAX_BANDS];
    float maxAbsDynamicGainDB;
    uint32_t activeBandCount;
} N60DynamicEQRuntime;

typedef struct {
    uint32_t activeBandCount;
    float maxAbsDynamicGainDB;
} N60DynamicEQTelemetry;

N60DynamicEQSnapshot N60DynamicEQSnapshotMakeBypassed(double sampleRate);
bool N60DynamicEQSnapshotSetEnabled(N60DynamicEQSnapshot *snapshot, bool enabled);
bool N60DynamicEQSnapshotSetBand(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    uint32_t index,
    bool enabled,
    double frequencyHz,
    float q,
    float staticGainDB,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs,
    N60DynamicEQDirection direction,
    float boostThresholdDB,
    float boostRatio,
    float maxBoostDB,
    N60DynamicEQDetectorMode detectorMode,
    float rmsWindowMs
);
bool N60DynamicEQSnapshotIsValid(N60DynamicEQSnapshot snapshot);
void N60DynamicEQRuntimeReset(N60DynamicEQRuntime *runtime);
void N60DynamicEQProcessStereoFrame(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *left,
    float *right
);
N60DynamicEQTelemetry N60DynamicEQRuntimeTelemetry(const N60DynamicEQRuntime *runtime);

#ifdef __cplusplus
}
#endif

#endif
