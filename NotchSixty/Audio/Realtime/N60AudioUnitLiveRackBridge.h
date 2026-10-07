#ifndef N60AudioUnitLiveRackBridge_h
#define N60AudioUnitLiveRackBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_AUDIO_UNIT_LIVE_RACK_MAX_SLOTS 8u

typedef enum {
    N60AudioUnitLiveRackFaultNone = 0,
    N60AudioUnitLiveRackFaultRenderStatus = 1,
    N60AudioUnitLiveRackFaultNonFiniteOutput = 2,
    N60AudioUnitLiveRackFaultRuntimeInvariant = 3,
    N60AudioUnitLiveRackFaultCPUOverrun = 4,
} N60AudioUnitLiveRackFaultReason;

typedef struct N60AudioUnitLiveRackFaultLatch N60AudioUnitLiveRackFaultLatch;

typedef struct {
    uint64_t faultCount;
    uint32_t lastSlotIndex;
    N60AudioUnitLiveRackFaultReason lastReason;
    int32_t lastRenderStatus;
} N60AudioUnitLiveRackFaultSnapshot;

N60AudioUnitLiveRackFaultLatch * _Nullable
N60AudioUnitLiveRackFaultLatchCreate(void);

void N60AudioUnitLiveRackFaultLatchDestroy(
    N60AudioUnitLiveRackFaultLatch * _Nullable latch
);

void N60AudioUnitLiveRackFaultLatchRecord(
    N60AudioUnitLiveRackFaultLatch * _Nullable latch,
    uint32_t slotIndex,
    N60AudioUnitLiveRackFaultReason reason,
    int32_t renderStatus
);

N60AudioUnitLiveRackFaultSnapshot
N60AudioUnitLiveRackFaultLatchGetSnapshot(
    const N60AudioUnitLiveRackFaultLatch * _Nullable latch
);

typedef bool (*N60AudioUnitLiveRackProcessFunction)(
    void * _Nullable context,
    const float * _Nonnull inputInterleaved,
    float * _Nonnull outputInterleaved,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
);

typedef struct {
    void * _Nullable context;
    N60AudioUnitLiveRackProcessFunction _Nullable process;
    uint32_t channelCount;
    uint32_t maximumFramesPerSlice;
    uint64_t latencyFrames;
} N60AudioUnitLiveRackProcessor;

static inline bool N60AudioUnitLiveRackProcessorIsValid(
    const N60AudioUnitLiveRackProcessor * _Nullable processor
) {
    return processor != NULL
        && processor->context != NULL
        && processor->process != NULL
        && processor->channelCount > 0u
        && processor->channelCount <= 32u
        && processor->maximumFramesPerSlice >= 16u
        && processor->maximumFramesPerSlice <= 65536u;
}

static inline bool N60AudioUnitLiveRackProcess(
    const N60AudioUnitLiveRackProcessor * _Nonnull processor,
    const float * _Nonnull inputInterleaved,
    float * _Nonnull outputInterleaved,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
) {
    return N60AudioUnitLiveRackProcessorIsValid(processor)
        && inputInterleaved != NULL
        && outputInterleaved != NULL
        && frameCount <= processor->maximumFramesPerSlice
        && channelCount == processor->channelCount
        && processor->process(
            processor->context,
            inputInterleaved,
            outputInterleaved,
            frameCount,
            channelCount,
            sampleTime
        );
}

#ifdef __cplusplus
}
#endif

#endif
