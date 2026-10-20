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

// The learned or captured noise profile as a plain value, laid out like libn60core's n60_denoiser_state (E6 S8d)
// so the kernel and the graph can hand a profile to each other. fftSize 0 = no state. flags: 1 profile ready,
// 2 captured, 4 capture active, 8 adaptive block fresh.
typedef struct {
    uint32_t fftSize;
    uint32_t flags;
    uint32_t adaptiveFrames;
    uint32_t adaptiveTarget;
    uint32_t adaptiveBlocks;
    uint32_t lastRevision;
    uint32_t captureCollected;
    uint32_t captureTarget;
    float noise[N60_DENOISER_MAX_BINS];
    float adaptiveMinimum[N60_DENOISER_MAX_BINS];
    float captureSum[N60_DENOISER_MAX_BINS];
} N60SpectralDenoiserProfileState;

// Realtime thread, between blocks; bounded copies. Export reads the profile and its bookkeeping, import replaces
// them and leaves the stream state (input, overlap-add, gain history) alone.
void N60SpectralDenoiserExportProfile(const N60SpectralDenoiserRuntime *runtime, N60SpectralDenoiserProfileState *out);
void N60SpectralDenoiserImportProfile(N60SpectralDenoiserRuntime *runtime, const N60SpectralDenoiserProfileState *state);

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

// Render-kernel fast path. The caller must have already validated the immutable
// snapshot at graph publication. This avoids repeated validation/copying at audio rate.
void N60SpectralDenoiserProcessStereoFrameValidated(
    N60SpectralDenoiserRuntime *runtime,
    const N60SpectralDenoiserSnapshot *snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
);

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
