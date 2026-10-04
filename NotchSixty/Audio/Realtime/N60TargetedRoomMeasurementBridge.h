#ifndef N60TargetedRoomMeasurementBridge_h
#define N60TargetedRoomMeasurementBridge_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t frameCursor;
    uint32_t totalFrameCount;
    uint32_t capturedFrames;
    uint32_t outputChannelIndex;
    uint64_t callbacks;
    uint64_t unsupportedBufferLayouts;
    bool complete;
} N60TargetedRoomMeasurementBridgeSnapshot;

typedef struct N60TargetedRoomMeasurementBridge {
    float * _Nullable sweepSamples;
    float * _Nullable capture;
    uint32_t sweepFrameCount;
    uint32_t leadInFrames;
    uint32_t tailFrames;
    uint32_t captureFrameCount;
    uint32_t inputChannelIndex;
    uint32_t outputChannelIndex;
    _Atomic uint32_t frameCursor;
    _Atomic uint32_t capturedFrames;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupportedBufferLayouts;
    _Atomic bool complete;
} N60TargetedRoomMeasurementBridge;

static inline void N60TargetedRoomMeasurementBridgeReset(
    N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    if (bridge->capture != NULL) {
        memset(bridge->capture, 0, sizeof(float) * bridge->captureFrameCount);
    }
    atomic_store_explicit(&bridge->frameCursor, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->capturedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->callbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->unsupportedBufferLayouts, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->complete, false, memory_order_relaxed);
}

static inline N60TargetedRoomMeasurementBridge * _Nullable N60TargetedRoomMeasurementBridgeCreate(
    const float * _Nonnull sweepSamples,
    uint32_t sweepFrameCount,
    uint32_t leadInFrames,
    uint32_t tailFrames,
    uint32_t inputChannelIndex,
    uint32_t outputChannelIndex
) {
    if (sweepSamples == NULL || sweepFrameCount == 0u) return NULL;
    const uint64_t captureFrames64 = (uint64_t)leadInFrames
        + (uint64_t)sweepFrameCount
        + (uint64_t)tailFrames;
    if (captureFrames64 == 0u || captureFrames64 > UINT32_MAX) return NULL;

    N60TargetedRoomMeasurementBridge * _Nullable bridge =
        (N60TargetedRoomMeasurementBridge *)calloc(1u, sizeof(N60TargetedRoomMeasurementBridge));
    if (bridge == NULL) return NULL;
    bridge->sweepSamples = (float *)malloc(sizeof(float) * sweepFrameCount);
    bridge->capture = (float *)calloc((size_t)captureFrames64, sizeof(float));
    if (bridge->sweepSamples == NULL || bridge->capture == NULL) {
        free(bridge->capture);
        free(bridge->sweepSamples);
        free(bridge);
        return NULL;
    }
    memcpy(bridge->sweepSamples, sweepSamples, sizeof(float) * sweepFrameCount);
    bridge->sweepFrameCount = sweepFrameCount;
    bridge->leadInFrames = leadInFrames;
    bridge->tailFrames = tailFrames;
    bridge->captureFrameCount = (uint32_t)captureFrames64;
    bridge->inputChannelIndex = inputChannelIndex;
    bridge->outputChannelIndex = outputChannelIndex;
    N60TargetedRoomMeasurementBridgeReset(bridge);
    return bridge;
}

static inline void N60TargetedRoomMeasurementBridgeDestroy(
    N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    free(bridge->capture);
    free(bridge->sweepSamples);
    bridge->capture = NULL;
    bridge->sweepSamples = NULL;
    free(bridge);
}

static inline N60TargetedRoomMeasurementBridgeSnapshot N60TargetedRoomMeasurementBridgeGetSnapshot(
    const N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60TargetedRoomMeasurementBridgeSnapshot){0};
    return (N60TargetedRoomMeasurementBridgeSnapshot){
        .frameCursor = atomic_load_explicit(&bridge->frameCursor, memory_order_acquire),
        .totalFrameCount = bridge->captureFrameCount,
        .capturedFrames = atomic_load_explicit(&bridge->capturedFrames, memory_order_acquire),
        .outputChannelIndex = bridge->outputChannelIndex,
        .callbacks = atomic_load_explicit(&bridge->callbacks, memory_order_relaxed),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &bridge->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
        .complete = atomic_load_explicit(&bridge->complete, memory_order_acquire),
    };
}

static inline uint32_t N60TargetedRoomMeasurementProcessStrided(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphone,
    uint32_t microphoneStride,
    float * _Nonnull output,
    uint32_t outputStride,
    uint32_t frameCount
) {
    if (bridge == NULL || microphone == NULL || output == NULL) return 0u;
    uint32_t cursor = atomic_load_explicit(&bridge->frameCursor, memory_order_relaxed);
    const uint32_t remaining = cursor < bridge->captureFrameCount
        ? bridge->captureFrameCount - cursor
        : 0u;
    const uint32_t consumed = frameCount < remaining ? frameCount : remaining;
    uint32_t captured = atomic_load_explicit(&bridge->capturedFrames, memory_order_relaxed);
    const uint32_t sweepStart = bridge->leadInFrames;
    const uint32_t sweepEnd = sweepStart + bridge->sweepFrameCount;

    const float *input = microphone;
    float *destination = output;
    for (uint32_t offset = 0; offset < consumed; ++offset) {
        const uint32_t timelineFrame = cursor + offset;
        float sample = 0.0f;
        if (timelineFrame >= sweepStart && timelineFrame < sweepEnd) {
            sample = bridge->sweepSamples[timelineFrame - sweepStart];
        }
        *destination = sample;
        if (timelineFrame == captured) {
            bridge->capture[captured] = *input;
            captured += 1u;
        }
        input += microphoneStride;
        destination += outputStride;
    }
    for (uint32_t offset = consumed; offset < frameCount; ++offset) {
        *destination = 0.0f;
        destination += outputStride;
    }

    cursor += consumed;
    atomic_store_explicit(&bridge->capturedFrames, captured, memory_order_release);
    atomic_store_explicit(&bridge->frameCursor, cursor, memory_order_release);
    atomic_store_explicit(
        &bridge->complete,
        cursor == bridge->captureFrameCount && captured == bridge->captureFrameCount,
        memory_order_release
    );
    return consumed;
}

static inline uint32_t N60TargetedRoomMeasurementBridgeProcessPlanar(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphoneSamples,
    float * _Nonnull outputSamples,
    uint32_t frameCount
) {
    return N60TargetedRoomMeasurementProcessStrided(
        bridge,
        microphoneSamples,
        1u,
        outputSamples,
        1u,
        frameCount
    );
}

static inline uint32_t N60TargetedRoomMeasurementBridgeCopyCapture(
    const N60TargetedRoomMeasurementBridge * _Nullable bridge,
    float * _Nonnull destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0u) return 0u;
    const uint32_t available = atomic_load_explicit(&bridge->capturedFrames, memory_order_acquire);
    const uint32_t count = available < capacityFrames ? available : capacityFrames;
    memcpy(destination, bridge->capture, sizeof(float) * count);
    return count;
}

#if defined(__APPLE__)

typedef struct {
    const float * _Nullable samples;
    uint32_t stride;
    uint32_t frameCount;
} N60TargetedMeasurementInputView;

typedef struct {
    float * _Nullable samples;
    uint32_t stride;
    uint32_t frameCount;
} N60TargetedMeasurementOutputView;

static inline void N60TargetedRoomMeasurementZeroOutput(AudioBufferList * _Nullable bufferList) {
    if (bufferList == NULL) return;
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0u) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static inline bool N60TargetedRoomMeasurementMakeInputView(
    const AudioBufferList * _Nullable bufferList,
    uint32_t channelIndex,
    N60TargetedMeasurementInputView * _Nonnull view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60TargetedMeasurementInputView){0};
    uint32_t remainingChannel = channelIndex;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0u) continue;
        if (remainingChannel >= buffer->mNumberChannels) {
            remainingChannel -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        const uint32_t bytesPerFrame = (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0u || (buffer->mDataByteSize % bytesPerFrame) != 0u) return false;
        view->samples = ((const float *)buffer->mData) + remainingChannel;
        view->stride = buffer->mNumberChannels;
        view->frameCount = buffer->mDataByteSize / bytesPerFrame;
        return true;
    }
    return false;
}

static inline bool N60TargetedRoomMeasurementMakeOutputView(
    AudioBufferList * _Nullable bufferList,
    uint32_t channelIndex,
    N60TargetedMeasurementOutputView * _Nonnull view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60TargetedMeasurementOutputView){0};
    uint32_t remainingChannel = channelIndex;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0u) continue;
        if (remainingChannel >= buffer->mNumberChannels) {
            remainingChannel -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        const uint32_t bytesPerFrame = (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0u || (buffer->mDataByteSize % bytesPerFrame) != 0u) return false;
        view->samples = ((float *)buffer->mData) + remainingChannel;
        view->stride = buffer->mNumberChannels;
        view->frameCount = buffer->mDataByteSize / bytesPerFrame;
        return true;
    }
    return false;
}

static inline OSStatus N60TargetedRoomMeasurementIOProc(
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
    (void)inOutputTime;

    N60TargetedRoomMeasurementBridge *bridge =
        (N60TargetedRoomMeasurementBridge *)inClientData;
    if (bridge == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->callbacks, 1u, memory_order_relaxed);
    N60TargetedRoomMeasurementZeroOutput(outOutputData);

    N60TargetedMeasurementInputView input = {0};
    N60TargetedMeasurementOutputView output = {0};
    if (!N60TargetedRoomMeasurementMakeInputView(
            inInputData,
            bridge->inputChannelIndex,
            &input)
        || !N60TargetedRoomMeasurementMakeOutputView(
            outOutputData,
            bridge->outputChannelIndex,
            &output)) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1u, memory_order_relaxed);
        return noErr;
    }

    const uint32_t frameCount = input.frameCount < output.frameCount
        ? input.frameCount
        : output.frameCount;
    if (frameCount == 0u) return noErr;
    (void)N60TargetedRoomMeasurementProcessStrided(
        bridge,
        input.samples,
        input.stride,
        output.samples,
        output.stride,
        frameCount
    );
    return noErr;
}

#endif

#ifdef __cplusplus
}
#endif

#endif
