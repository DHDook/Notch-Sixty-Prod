#ifndef N60LiveNChannelBridge_h
#define N60LiveNChannelBridge_h

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelRenderCore.h"
#include "N60ProgramTransport.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t captureCallbacks;
    uint64_t outputCallbacks;
    uint64_t renderedFrames;
    uint64_t renderFailures;
    uint64_t outputWriteFailures;
    uint64_t gatedOutputCallbacks;
    uint64_t gatedOutputFrames;
    bool outputGateOpen;
    N60ProgramTransportSnapshot transport;
} N60LiveNChannelBridgeSnapshot;

typedef struct N60LiveNChannelBridge {
    N60ProgramTransport * _Nullable transport;
    N60LiveNChannelRenderRuntime * _Nullable renderRuntime;
    N60ProgramInputMap inputMap;
    N60LiveNChannelRenderGraph graph;

    uint32_t outputGateMinimumBufferedFrames;
    uint32_t startupFadeFrames;
    uint32_t startupFadeRemaining;

    _Atomic bool outputGateOpen;
    _Atomic uint32_t outputGainBits;
    _Atomic uint64_t captureCallbacks;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t renderFailures;
    _Atomic uint64_t outputWriteFailures;
    _Atomic uint64_t gatedOutputCallbacks;
    _Atomic uint64_t gatedOutputFrames;
} N60LiveNChannelBridge;

static inline uint32_t N60LiveNChannelFloatToBits(float value) {
    uint32_t bits = 0u;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float N60LiveNChannelBitsToFloat(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline float N60LiveNChannelClampOutputGain(float gain) {
    if (!isfinite(gain) || gain < 0.0f) return 0.0f;
    return gain > 1.0f ? 1.0f : gain;
}

static inline bool N60LiveNChannelInputMapMatchesGraph(
    const N60ProgramInputMap * _Nullable inputMap,
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    return inputMap != NULL
        && graph != NULL
        && inputMap->valid
        && N60LiveNChannelLayoutsEqual(&inputMap->canonicalLayout, &graph->programLayout);
}

/// Control-plane creation. The returned bridge is an opt-in live N-channel
/// callback engine; PR61 does not replace the shipping stereo bridge by default.
static inline N60LiveNChannelBridge * _Nullable N60LiveNChannelBridgeCreate(
    uint32_t transportCapacityFrames,
    N60ProgramInputMap inputMap,
    N60LiveNChannelRenderGraph graph,
    uint32_t outputGateMinimumBufferedFrames,
    uint32_t startupFadeFrames
) {
    if (transportCapacityFrames == 0u
        || outputGateMinimumBufferedFrames > transportCapacityFrames
        || !N60LiveNChannelRenderGraphIsValid(&graph)
        || !N60LiveNChannelInputMapMatchesGraph(&inputMap, &graph)) {
        return NULL;
    }

    N60LiveNChannelBridge * _Nullable bridge =
        (N60LiveNChannelBridge *)calloc(1u, sizeof(N60LiveNChannelBridge));
    if (bridge == NULL) return NULL;

    bridge->transport = N60ProgramTransportCreate(
        transportCapacityFrames,
        graph.programLayout
    );
    bridge->renderRuntime = N60LiveNChannelRenderRuntimeCreate();
    if (bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || !N60LiveNChannelRenderRuntimePrepare(bridge->renderRuntime, &graph)) {
        N60ProgramTransportDestroy(bridge->transport);
        N60LiveNChannelRenderRuntimeDestroy(bridge->renderRuntime);
        free(bridge);
        return NULL;
    }

    bridge->inputMap = inputMap;
    bridge->graph = graph;
    bridge->outputGateMinimumBufferedFrames = outputGateMinimumBufferedFrames;
    bridge->startupFadeFrames = startupFadeFrames;
    bridge->startupFadeRemaining = 0u;
    atomic_store_explicit(
        &bridge->outputGateOpen,
        outputGateMinimumBufferedFrames == 0u,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->outputGainBits,
        N60LiveNChannelFloatToBits(1.0f),
        memory_order_relaxed
    );
    return bridge;
}

static inline void N60LiveNChannelBridgeDestroy(
    N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    N60ProgramTransportDestroy(bridge->transport);
    N60LiveNChannelRenderRuntimeDestroy(bridge->renderRuntime);
    bridge->transport = NULL;
    bridge->renderRuntime = NULL;
    free(bridge);
}

/// Control-plane reset. Producer/consumer callbacks must be stopped.
static inline bool N60LiveNChannelBridgeReset(
    N60LiveNChannelBridge * _Nonnull bridge
) {
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || !N60LiveNChannelRenderRuntimePrepare(bridge->renderRuntime, &bridge->graph)) {
        return false;
    }
    N60ProgramTransportReset(bridge->transport);
    bridge->startupFadeRemaining = 0u;
    atomic_store_explicit(
        &bridge->outputGateOpen,
        bridge->outputGateMinimumBufferedFrames == 0u,
        memory_order_release
    );
    atomic_store_explicit(&bridge->captureCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderFailures, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputWriteFailures, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputFrames, 0u, memory_order_relaxed);
    return true;
}

static inline void N60LiveNChannelBridgeSetOutputGain(
    N60LiveNChannelBridge * _Nullable bridge,
    float gain
) {
    if (bridge == NULL) return;
    atomic_store_explicit(
        &bridge->outputGainBits,
        N60LiveNChannelFloatToBits(N60LiveNChannelClampOutputGain(gain)),
        memory_order_release
    );
}

static inline N60LiveNChannelBridgeSnapshot N60LiveNChannelBridgeGetSnapshot(
    const N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60LiveNChannelBridgeSnapshot){0};
    return (N60LiveNChannelBridgeSnapshot){
        .captureCallbacks = atomic_load_explicit(&bridge->captureCallbacks, memory_order_relaxed),
        .outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed),
        .renderedFrames = atomic_load_explicit(&bridge->renderedFrames, memory_order_relaxed),
        .renderFailures = atomic_load_explicit(&bridge->renderFailures, memory_order_relaxed),
        .outputWriteFailures = atomic_load_explicit(&bridge->outputWriteFailures, memory_order_relaxed),
        .gatedOutputCallbacks = atomic_load_explicit(
            &bridge->gatedOutputCallbacks,
            memory_order_relaxed
        ),
        .gatedOutputFrames = atomic_load_explicit(
            &bridge->gatedOutputFrames,
            memory_order_relaxed
        ),
        .outputGateOpen = atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire),
        .transport = N60ProgramTransportGetSnapshot(bridge->transport),
    };
}

static inline void N60LiveNChannelZeroOutput(AudioBufferList * _Nullable outputData) {
    if (outputData == NULL) return;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0u) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static inline bool N60LiveNChannelWritePhysicalFrame(
    const N60LiveNChannelPhysicalFrame * _Nonnull frame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex,
    float gain
) {
    if (frame == NULL
        || outputData == NULL
        || frame->physicalChannelCount == 0u
        || frame->physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || !isfinite(gain)) {
        return false;
    }
    if (!N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) return false;
    for (uint32_t physical = 0; physical < frame->physicalChannelCount; ++physical) {
        const float value = frame->values[physical] * gain;
        if (!N60ProgramTransportWriteFlattenedSample(
                outputData,
                physical,
                frameIndex,
                isfinite(value) ? value : 0.0f)) {
            return false;
        }
    }
    return true;
}

static inline float N60LiveNChannelBridgeNextOutputGain(
    N60LiveNChannelBridge * _Nonnull bridge,
    float masterGain
) {
    if (bridge == NULL || bridge->startupFadeRemaining == 0u || bridge->startupFadeFrames == 0u) {
        return masterGain;
    }
    const uint32_t completed = bridge->startupFadeFrames - bridge->startupFadeRemaining + 1u;
    const float fade = (float)completed / (float)bridge->startupFadeFrames;
    bridge->startupFadeRemaining -= 1u;
    return masterGain * fade;
}

/// Realtime capture callback: Core Audio stream order -> canonical semantic ring.
static inline OSStatus N60LiveNChannelCaptureIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;

    N60LiveNChannelBridge *bridge = (N60LiveNChannelBridge *)inClientData;
    if (bridge == NULL || bridge->transport == NULL || inInputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1u, memory_order_relaxed);
    (void)N60ProgramTransportCaptureBuffer(
        bridge->transport,
        &bridge->inputMap,
        inInputData
    );
    return noErr;
}

/// Realtime output callback. This is the first complete live N-channel callback
/// path: semantic dequeue -> PR54 lanes -> PR55 bass management -> physical map.
/// Graph/runtime mutation is intentionally forbidden while callbacks run.
static inline OSStatus N60LiveNChannelOutputIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;

    N60LiveNChannelBridge *bridge = (N60LiveNChannelBridge *)inClientData;
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || outOutputData == NULL) {
        return noErr;
    }
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1u, memory_order_relaxed);

    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(
            outOutputData,
            bridge->graph.outputMap.physicalChannelCount,
            &frameCount)) {
        N60LiveNChannelZeroOutput(outOutputData);
        atomic_fetch_add_explicit(&bridge->outputWriteFailures, 1u, memory_order_relaxed);
        return noErr;
    }

    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        const N60ProgramTransportSnapshot transport = N60ProgramTransportGetSnapshot(bridge->transport);
        if (transport.bufferedFrames >= bridge->outputGateMinimumBufferedFrames
            && transport.bufferedFrames >= frameCount) {
            atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
            bridge->startupFadeRemaining = bridge->startupFadeFrames;
        } else {
            N60LiveNChannelZeroOutput(outOutputData);
            atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
            return noErr;
        }
    }

    const float masterGain = N60LiveNChannelBitsToFloat(
        atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire)
    );

    for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        N60ProgramTransportFrame input = {0};
        (void)N60ProgramTransportDequeueFrame(bridge->transport, &input);

        N60LiveNChannelPhysicalFrame physical = {0};
        if (!N60LiveNChannelRenderProcessFrame(
                bridge->renderRuntime,
                &bridge->graph,
                &input,
                &physical,
                NULL)) {
            (void)N60ProgramTransportZeroOutputFrame(outOutputData, frameIndex);
            atomic_fetch_add_explicit(&bridge->renderFailures, 1u, memory_order_relaxed);
            continue;
        }

        const float gain = N60LiveNChannelBridgeNextOutputGain(bridge, masterGain);
        if (!N60LiveNChannelWritePhysicalFrame(&physical, outOutputData, frameIndex, gain)) {
            (void)N60ProgramTransportZeroOutputFrame(outOutputData, frameIndex);
            atomic_fetch_add_explicit(&bridge->outputWriteFailures, 1u, memory_order_relaxed);
            continue;
        }
        atomic_fetch_add_explicit(&bridge->renderedFrames, 1u, memory_order_relaxed);
    }
    return noErr;
}

#ifdef __cplusplus
}
#endif

#endif
