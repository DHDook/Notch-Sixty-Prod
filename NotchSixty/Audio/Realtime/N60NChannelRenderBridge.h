#ifndef N60NChannelRenderBridge_h
#define N60NChannelRenderBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60ProgramTransport.h"
#include "N60NChannelDSPPipeline.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ACOUSTIC_OUTPUT_MAX_ROUTES (N60_MAX_PROGRAM_CHANNELS + N60_MAX_SUBWOOFER_OUTPUTS)

typedef enum {
    N60AcousticOutputRouteProgramSpeaker = 0,
    N60AcousticOutputRouteSubwoofer = 1,
} N60AcousticOutputRouteKind;

typedef struct {
    N60AcousticOutputRouteKind kind;
    N60ProgramChannelRole role;
    uint32_t subwooferIndex;
    uint32_t physicalChannelIndex;
} N60AcousticOutputRoute;

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    N60ProgramChannelLayout programLayout;
    uint32_t subwooferCount;
    uint32_t routeCount;
    N60AcousticOutputRoute routes[N60_ACOUSTIC_OUTPUT_MAX_ROUTES];
} N60AcousticOutputMap;

typedef struct {
    uint64_t outputCallbacks;
    uint64_t processedFrames;
    uint64_t silentUnderrunFrames;
    uint64_t processingFailures;
    uint64_t unsupportedBufferLayouts;
} N60NChannelRenderBridgeSnapshot;

typedef struct {
    N60ProgramTransport * _Nullable transport;
    N60ProgramInputMap inputMap;
} N60NChannelCaptureContext;

typedef struct N60NChannelRenderBridge {
    N60ProgramTransport * _Nullable transport;
    N60NChannelDSPPipelineSnapshot pipelineSnapshot;
    N60NChannelDSPPipelineRuntime * _Nullable pipelineRuntime;
    N60AcousticOutputMap outputMap;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t processedFrames;
    _Atomic uint64_t silentUnderrunFrames;
    _Atomic uint64_t processingFailures;
    _Atomic uint64_t unsupportedBufferLayouts;
} N60NChannelRenderBridge;

static inline bool N60AcousticOutputMapCompile(
    N60ProgramChannelLayout programLayout,
    uint32_t subwooferCount,
    uint32_t physicalChannelCount,
    const N60AcousticOutputRoute * _Nonnull routes,
    uint32_t routeCount,
    N60AcousticOutputMap * _Nonnull mapOut
) {
    if (routes == NULL
        || mapOut == NULL
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS
        || physicalChannelCount == 0u
        || routeCount == 0u
        || routeCount > N60_ACOUSTIC_OUTPUT_MAX_ROUTES) {
        return false;
    }

    uint32_t requiredProgramSpeakers = programLayout.channelCount
        - (N60NChannelLayoutContainsLFE(&programLayout) ? 1u : 0u);
    if (routeCount != requiredProgramSpeakers + subwooferCount) return false;

    bool programMapped[N60_MAX_PROGRAM_CHANNELS] = {false};
    bool subMapped[N60_MAX_SUBWOOFER_OUTPUTS] = {false};
    N60AcousticOutputMap result = {0};
    result.physicalChannelCount = physicalChannelCount;
    result.programLayout = programLayout;
    result.subwooferCount = subwooferCount;
    result.routeCount = routeCount;

    for (uint32_t routeIndex = 0; routeIndex < routeCount; ++routeIndex) {
        const N60AcousticOutputRoute route = routes[routeIndex];
        if (route.physicalChannelIndex >= physicalChannelCount) return false;
        for (uint32_t previous = 0; previous < routeIndex; ++previous) {
            if (routes[previous].physicalChannelIndex == route.physicalChannelIndex) return false;
        }

        if (route.kind == N60AcousticOutputRouteProgramSpeaker) {
            if (!N60ProgramChannelRoleIsSemantic(route.role)
                || route.role == N60ProgramChannelRoleLowFrequencyEffects
                || route.subwooferIndex != UINT32_MAX) {
                return false;
            }
            const int32_t programIndex = N60ProgramChannelLayoutIndexOfRole(&programLayout, route.role);
            if (programIndex < 0 || programMapped[(uint32_t)programIndex]) return false;
            programMapped[(uint32_t)programIndex] = true;
        } else if (route.kind == N60AcousticOutputRouteSubwoofer) {
            if (route.role != N60ProgramChannelRoleUnused
                || route.subwooferIndex >= subwooferCount
                || subMapped[route.subwooferIndex]) {
                return false;
            }
            subMapped[route.subwooferIndex] = true;
        } else {
            return false;
        }
        result.routes[routeIndex] = route;
    }

    for (uint32_t program = 0; program < programLayout.channelCount; ++program) {
        if (programLayout.channels[program] == N60ProgramChannelRoleLowFrequencyEffects) continue;
        if (!programMapped[program]) return false;
    }
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        if (!subMapped[sub]) return false;
    }
    result.valid = true;
    *mapOut = result;
    return true;
}

static inline bool N60AcousticOutputMapMatchesPipeline(
    const N60AcousticOutputMap * _Nullable map,
    const N60NChannelDSPPipelineSnapshot * _Nullable pipeline
) {
    if (map == NULL || pipeline == NULL || !map->valid) return false;
    const uint32_t expectedSubs = pipeline->bassManagementEnabled
        ? pipeline->bassManagement.subwooferCount
        : 0u;
    return map->subwooferCount == expectedSubs
        && N60ProgramChannelLayoutsEqual(&map->programLayout, &pipeline->layout);
}

static inline bool N60AcousticOutputMapWriteFrame(
    const N60AcousticOutputMap * _Nonnull map,
    const N60AcousticOutputFrame * _Nonnull frame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex
) {
    if (map == NULL
        || frame == NULL
        || outputData == NULL
        || !map->valid
        || map->subwooferCount != frame->subwooferCount
        || !N60ProgramChannelLayoutsEqual(&map->programLayout, &frame->layout)
        || !N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) {
        return false;
    }
    for (uint32_t routeIndex = 0; routeIndex < map->routeCount; ++routeIndex) {
        const N60AcousticOutputRoute route = map->routes[routeIndex];
        float sample = 0.0f;
        if (route.kind == N60AcousticOutputRouteProgramSpeaker) {
            const int32_t program = N60ProgramChannelLayoutIndexOfRole(&frame->layout, route.role);
            if (program < 0) return false;
            sample = frame->programSpeakers[(uint32_t)program];
        } else {
            if (route.subwooferIndex >= frame->subwooferCount) return false;
            sample = frame->subwoofers[route.subwooferIndex];
        }
        if (!N60ProgramTransportWriteFlattenedSample(
                outputData,
                route.physicalChannelIndex,
                frameIndex,
                isfinite(sample) ? sample : 0.0f)) {
            return false;
        }
    }
    return true;
}

static inline void N60NChannelZeroOutput(AudioBufferList * _Nullable outputData) {
    if (outputData == NULL) return;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0u) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static inline bool N60NChannelCaptureContextMake(
    N60ProgramTransport * _Nonnull transport,
    N60ProgramInputMap inputMap,
    N60NChannelCaptureContext * _Nonnull contextOut
) {
    if (transport == NULL
        || contextOut == NULL
        || !inputMap.valid
        || !N60ProgramTransportLayoutMatches(transport, &inputMap.canonicalLayout)) {
        return false;
    }
    *contextOut = (N60NChannelCaptureContext){
        .transport = transport,
        .inputMap = inputMap,
    };
    return true;
}

static inline N60NChannelRenderBridge * _Nullable N60NChannelRenderBridgeCreate(
    N60ProgramTransport * _Nonnull transport,
    N60NChannelDSPPipelineSnapshot pipelineSnapshot,
    N60AcousticOutputMap outputMap
) {
    if (transport == NULL
        || !N60NChannelDSPPipelineSnapshotIsValid(&pipelineSnapshot)
        || !N60ProgramTransportLayoutMatches(transport, &pipelineSnapshot.layout)
        || !N60AcousticOutputMapMatchesPipeline(&outputMap, &pipelineSnapshot)) {
        return NULL;
    }
    N60NChannelRenderBridge * _Nullable bridge =
        (N60NChannelRenderBridge *)calloc(1u, sizeof(N60NChannelRenderBridge));
    if (bridge == NULL) return NULL;
    bridge->pipelineRuntime = N60NChannelDSPPipelineRuntimeCreate();
    if (bridge->pipelineRuntime == NULL
        || !N60NChannelDSPPipelineRuntimePrepare(bridge->pipelineRuntime, &pipelineSnapshot)) {
        N60NChannelDSPPipelineRuntimeDestroy(bridge->pipelineRuntime);
        free(bridge);
        return NULL;
    }
    bridge->transport = transport;
    bridge->pipelineSnapshot = pipelineSnapshot;
    bridge->outputMap = outputMap;
    return bridge;
}

static inline void N60NChannelRenderBridgeDestroy(N60NChannelRenderBridge * _Nullable bridge) {
    if (bridge == NULL) return;
    N60NChannelDSPPipelineRuntimeDestroy(bridge->pipelineRuntime);
    bridge->pipelineRuntime = NULL;
    bridge->transport = NULL;
    free(bridge);
}

/// Realtime output callback primitive. An input underrun silences that hardware
/// frame and freezes DSP state, matching the current stereo bridge's fail-closed
/// behavior rather than feeding fabricated zeros through delay/filter tails.
static inline bool N60NChannelRenderBridgeProcessOutputBuffer(
    N60NChannelRenderBridge * _Nonnull bridge,
    AudioBufferList * _Nonnull outputData
) {
    if (bridge == NULL
        || outputData == NULL
        || bridge->transport == NULL
        || bridge->pipelineRuntime == NULL) {
        return false;
    }
    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(
            outputData,
            bridge->outputMap.physicalChannelCount,
            &frameCount)) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1u, memory_order_relaxed);
        N60NChannelZeroOutput(outputData);
        return false;
    }

    for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        N60ProgramTransportFrame input = {0};
        if (!N60ProgramTransportDequeueFrame(bridge->transport, &input)) {
            if (!N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) {
                N60NChannelZeroOutput(outputData);
                return false;
            }
            atomic_fetch_add_explicit(&bridge->silentUnderrunFrames, 1u, memory_order_relaxed);
            continue;
        }

        N60AcousticOutputFrame acoustic = {0};
        if (!N60NChannelDSPPipelineProcessFrame(
                bridge->pipelineRuntime,
                &bridge->pipelineSnapshot,
                input.channels,
                &acoustic)
            || !N60AcousticOutputMapWriteFrame(
                &bridge->outputMap,
                &acoustic,
                outputData,
                frameIndex)) {
            atomic_fetch_add_explicit(&bridge->processingFailures, 1u, memory_order_relaxed);
            N60NChannelZeroOutput(outputData);
            return false;
        }
        atomic_fetch_add_explicit(&bridge->processedFrames, 1u, memory_order_relaxed);
    }
    return true;
}

static inline N60NChannelRenderBridgeSnapshot N60NChannelRenderBridgeGetSnapshot(
    const N60NChannelRenderBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60NChannelRenderBridgeSnapshot){0};
    return (N60NChannelRenderBridgeSnapshot){
        .outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed),
        .processedFrames = atomic_load_explicit(&bridge->processedFrames, memory_order_relaxed),
        .silentUnderrunFrames = atomic_load_explicit(&bridge->silentUnderrunFrames, memory_order_relaxed),
        .processingFailures = atomic_load_explicit(&bridge->processingFailures, memory_order_relaxed),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &bridge->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
    };
}

static inline OSStatus N60NChannelCaptureIOProc(
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
    N60NChannelCaptureContext *context = (N60NChannelCaptureContext *)inClientData;
    if (context == NULL || context->transport == NULL || inInputData == NULL) return noErr;
    (void)N60ProgramTransportCaptureBuffer(context->transport, &context->inputMap, inInputData);
    return noErr;
}

static inline OSStatus N60NChannelOutputIOProc(
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
    N60NChannelRenderBridge *bridge = (N60NChannelRenderBridge *)inClientData;
    if (bridge == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1u, memory_order_relaxed);
    if (!N60NChannelRenderBridgeProcessOutputBuffer(bridge, outOutputData)) {
        N60NChannelZeroOutput(outOutputData);
    }
    return noErr;
}

#ifdef __cplusplus
}
#endif

#endif
