#ifndef N60DynamicEQ_h
#define N60DynamicEQ_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_DYNAMIC_EQ_MAX_BANDS 64u

typedef enum {
    N60DynamicEQDirectionCutOnly = 0,
    N60DynamicEQDirectionBoostOnly = 1,
    N60DynamicEQDirectionBoth = 2,
} N60DynamicEQDirection;

typedef enum {
    N60DynamicEQDetectorPeak = 0,
    N60DynamicEQDetectorRMS = 1,
} N60DynamicEQDetectorMode;

typedef enum {
    N60DynamicEQDomainLinkedStereo = 0,
    N60DynamicEQDomainDualMono = 1,
    N60DynamicEQDomainMidSide = 2,
} N60DynamicEQDomain;

typedef enum {
    N60DynamicEQLanePrimary = 0,
    N60DynamicEQLaneSecondary = 1,
} N60DynamicEQLane;

typedef enum {
    N60DynamicEQShapePeak = 0,
    N60DynamicEQShapeLowShelf = 1,
    N60DynamicEQShapeHighShelf = 2,
    N60DynamicEQShapeNotch = 3,
    N60DynamicEQShapeBandPass = 4,
    N60DynamicEQShapeTilt = 5,
} N60DynamicEQShape;

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} N60DynamicEQBiquadCoefficients;

typedef struct {
    bool enabled;
    N60DynamicEQShape shape;
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
    N60DynamicEQBiquadCoefficients basisPrimary;
    N60DynamicEQBiquadCoefficients basisSecondary;
} N60DynamicEQBandSnapshot;

typedef struct {
    bool enabled;
    N60DynamicEQDomain domain;
    double sampleRate;
    uint32_t bandCount;
    uint32_t secondaryBandCount;
    float bypassTransitionCoefficient;
    N60DynamicEQBandSnapshot bands[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBandSnapshot secondaryBands[N60_DYNAMIC_EQ_MAX_BANDS];
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

    N60DynamicEQBiquadState processPrimaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processPrimaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processSecondaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processSecondaryRight[N60_DYNAMIC_EQ_MAX_BANDS];

    N60DynamicEQBiquadState secondaryAnalysisLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryAnalysisRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessPrimaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessPrimaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessSecondaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessSecondaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryRmsPower[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryDynamicGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryStaticGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryWetMix[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryDetectorLevelDBFS[N60_DYNAMIC_EQ_MAX_BANDS];

    float maxAbsDynamicGainDB;
    uint32_t activeBandCount;
    N60DynamicEQDomain currentDomain;
    bool domainInitialized;
} N60DynamicEQRuntime;

typedef struct {
    uint32_t activeBandCount;
    float maxAbsDynamicGainDB;
} N60DynamicEQTelemetry;

N60DynamicEQSnapshot N60DynamicEQSnapshotMakeBypassed(double sampleRate);
bool N60DynamicEQSnapshotSetEnabled(N60DynamicEQSnapshot *snapshot, bool enabled);
bool N60DynamicEQSnapshotSetDomain(N60DynamicEQSnapshot *snapshot, N60DynamicEQDomain domain);
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
bool N60DynamicEQSnapshotSetBandForLane(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    N60DynamicEQLane lane,
    uint32_t index,
    bool enabled,
    N60DynamicEQShape shape,
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
