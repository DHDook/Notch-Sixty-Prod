#ifndef N60AdaptiveSampleRate_h
#define N60AdaptiveSampleRate_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ADAPTIVE_SRC_MAX_CHANNELS 40u
#define N60_ADAPTIVE_SRC_DEFAULT_TAPS 64u
#define N60_ADAPTIVE_SRC_DEFAULT_PHASES 2048u
#define N60_ADAPTIVE_SRC_MAX_TAPS 128u
#define N60_ADAPTIVE_SRC_MAX_PHASES 4096u

typedef struct {
    double targetBufferedFrames;
    double proportionalGainPPM;
    double integralGainPPMPerSecond;
    double maximumCorrectionPPM;
    double slewLimitPPMPerSecond;
} N60AdaptiveClockPolicy;

typedef struct {
    N60AdaptiveClockPolicy policy;
    double integralPPM;
    double correctionPPM;
    double lastNormalizedError;
    uint64_t saturationEvents;
} N60AdaptiveClockController;

typedef struct {
    double inputSampleRate;
    double outputSampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t targetBufferedFrames;
    uint32_t tapCount;
    uint32_t phaseCount;
    double maximumCorrectionPPM;
    double proportionalGainPPM;
    double integralGainPPMPerSecond;
    double slewLimitPPMPerSecond;
} N60AdaptiveSRCConfiguration;

typedef struct {
    bool valid;
    double inputSampleRate;
    double outputSampleRate;
    double nominalInputFramesPerOutputFrame;
    double effectiveInputFramesPerOutputFrame;
    double correctionPPM;
    double normalizedBufferError;
    uint32_t targetBufferedFrames;
    uint32_t bufferedFrames;
    uint64_t pushedInputFrames;
    uint64_t producedOutputFrames;
    uint64_t droppedInputFrames;
    uint64_t starvedOutputFrames;
    uint64_t controllerSaturationEvents;
} N60AdaptiveSRCSnapshot;

typedef struct N60AdaptiveSRC N60AdaptiveSRC;

N60AdaptiveClockPolicy N60AdaptiveClockPolicyMakeDefault(double targetBufferedFrames);
bool N60AdaptiveClockControllerConfigure(
    N60AdaptiveClockController *controller,
    N60AdaptiveClockPolicy policy
);
void N60AdaptiveClockControllerReset(N60AdaptiveClockController *controller);
double N60AdaptiveClockControllerUpdate(
    N60AdaptiveClockController *controller,
    double actualBufferedFrames,
    double elapsedSeconds
);

N60AdaptiveSRCConfiguration N60AdaptiveSRCConfigurationMakeDefault(
    double inputSampleRate,
    double outputSampleRate,
    uint32_t channelCount,
    uint32_t capacityFrames,
    uint32_t targetBufferedFrames
);
bool N60AdaptiveSRCConfigurationIsValid(N60AdaptiveSRCConfiguration configuration);

// Control-plane allocation/preparation. Coefficient tables and the input ring
// are allocated and initialized here; never call Create/Destroy/Reset from an
// audio callback.
N60AdaptiveSRC *N60AdaptiveSRCCreate(N60AdaptiveSRCConfiguration configuration);
void N60AdaptiveSRCDestroy(N60AdaptiveSRC *src);
void N60AdaptiveSRCReset(N60AdaptiveSRC *src);

// Realtime-safe SPSC producer/consumer API. Push and Pull perform no allocation,
// deallocation, blocking locks, logging, or system calls. The producer may be a
// capture callback and the consumer an output callback. Input/output samples are
// interleaved by channel. Pull may return fewer than requested frames until the
// symmetric interpolation kernel has enough future input support.
uint32_t N60AdaptiveSRCPushInterleaved(
    N60AdaptiveSRC *src,
    const float *input,
    uint32_t inputFrames
);
uint32_t N60AdaptiveSRCPullInterleaved(
    N60AdaptiveSRC *src,
    float *output,
    uint32_t requestedOutputFrames
);

N60AdaptiveSRCSnapshot N60AdaptiveSRCGetSnapshot(const N60AdaptiveSRC *src);
bool N60AdaptiveSRCRealtimeAtomicsAreLockFree(const N60AdaptiveSRC *src);
uint32_t N60AdaptiveSRCLatencyInputFrames(const N60AdaptiveSRC *src);

#ifdef __cplusplus
}
#endif

#endif
