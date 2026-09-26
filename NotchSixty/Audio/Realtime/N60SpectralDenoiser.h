#ifndef N60SpectralDenoiser_h
#define N60SpectralDenoiser_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_DENOISER_MAX_FFT_SIZE 4096u
#define N60_DENOISER_MAX_BINS (N60_DENOISER_MAX_FFT_SIZE / 2u + 1u)

typedef enum {
    N60DenoiserQualityQuality = 0,
    N60DenoiserQualityHigh = 1,
    N60DenoiserQualityUltra = 2,
} N60DenoiserQuality;

typedef enum {
    N60DenoiserTuningNatural = 0,
    N60DenoiserTuningStandard = 1,
    N60DenoiserTuningAggressive = 2,
    N60DenoiserTuningDehiss = 3,
    N60DenoiserTuningCustom = 4,
} N60DenoiserTuning;

typedef enum {
    N60DenoiserProfileCommandNone = 0,
    N60DenoiserProfileCommandCapture = 1,
    N60DenoiserProfileCommandReset = 2,
} N60DenoiserProfileCommand;

typedef struct {
    double sampleRate;
    bool enabled;
    N60DenoiserTuning tuning;
    N60DenoiserQuality quality;
    float reductionAmount;
    float thresholdDBFS;
    bool protectedRangeEnabled;
    float protectedLowHz;
    float protectedHighHz;
    uint32_t profileRevision;
    N60DenoiserProfileCommand profileCommand;
    uint32_t fftSize;
    uint32_t hopSize;
    uint32_t latencyFrames;
    float minimumGain;
    float decisionDirectedAlpha;
    float suppressionAttack;
    float suppressionRelease;
    uint32_t spectralSmoothingRadius;
    float dehissStrength;
} N60SpectralDenoiserSnapshot;

typedef struct {
    bool profileReady;
    bool capturedProfile;
    bool captureActive;
    float captureProgress;
    float estimatedNoiseDBFS;
    float meanSuppressionDB;
    float maxSuppressionDB;
    uint32_t fftSize;
    uint32_t hopSize;
    uint32_t latencyFrames;
    uint64_t spectralFramesProcessed;
} N60SpectralDenoiserTelemetry;

typedef struct N60SpectralDenoiserRuntime N60SpectralDenoiserRuntime;

N60SpectralDenoiserSnapshot N60SpectralDenoiserSnapshotMakeBypassed(double sampleRate);

bool N60SpectralDenoiserSnapshotConfigure(
    N60SpectralDenoiserSnapshot *snapshot,
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

bool N60SpectralDenoiserSnapshotIsValid(
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate
);

N60SpectralDenoiserRuntime *N60SpectralDenoiserCreate(void);
void N60SpectralDenoiserDestroy(N60SpectralDenoiserRuntime *runtime);
void N60SpectralDenoiserReset(N60SpectralDenoiserRuntime *runtime);

void N60SpectralDenoiserProcessStereoFrame(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
);

N60SpectralDenoiserTelemetry N60SpectralDenoiserRuntimeTelemetry(
    const N60SpectralDenoiserRuntime *runtime
);

#ifdef __cplusplus
}
#endif

#endif /* N60SpectralDenoiser_h */
