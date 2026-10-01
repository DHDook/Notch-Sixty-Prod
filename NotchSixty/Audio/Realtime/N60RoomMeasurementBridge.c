#include "N60RoomMeasurementBridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const float *samples;
    uint32_t stride;
    uint32_t frameCount;
} N60MeasurementInputChannelView;

typedef struct {
    float *samples;
    uint32_t stride;
    uint32_t frameCount;
} N60MeasurementOutputChannelView;

struct N60RoomMeasurementBridge {
    float *sweepSamples;
    float *leftCapture;
    float *rightCapture;
    uint32_t sweepFrameCount;
    uint32_t leadInFrames;
    uint32_t tailFrames;
    uint32_t settlingFrames;
    uint32_t captureFrameCount;
    uint32_t rightCaptureStartFrame;
    uint32_t totalFrameCount;
    uint32_t inputChannelIndex;

    _Atomic uint32_t frameCursor;
    _Atomic uint32_t leftCapturedFrames;
    _Atomic uint32_t rightCapturedFrames;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupportedBufferLayouts;
    _Atomic bool complete;
};

static void zero_output(AudioBufferList *bufferList) {
    if (bufferList == NULL) return;
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static bool make_input_channel_view(
    const AudioBufferList *bufferList,
    uint32_t channelIndex,
    N60MeasurementInputChannelView *view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60MeasurementInputChannelView){0};

    uint32_t remainingChannel = channelIndex;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0) continue;
        if (remainingChannel >= buffer->mNumberChannels) {
            remainingChannel -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        uint32_t bytesPerFrame = (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0 || (buffer->mDataByteSize % bytesPerFrame) != 0) return false;
        view->samples = ((const float *)buffer->mData) + remainingChannel;
        view->stride = buffer->mNumberChannels;
        view->frameCount = buffer->mDataByteSize / bytesPerFrame;
        return true;
    }
    return false;
}

static bool make_output_channel_view(
    AudioBufferList *bufferList,
    uint32_t channelIndex,
    N60MeasurementOutputChannelView *view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60MeasurementOutputChannelView){0};

    uint32_t remainingChannel = channelIndex;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0) continue;
        if (remainingChannel >= buffer->mNumberChannels) {
            remainingChannel -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        uint32_t bytesPerFrame = (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0 || (buffer->mDataByteSize % bytesPerFrame) != 0) return false;
        view->samples = ((float *)buffer->mData) + remainingChannel;
        view->stride = buffer->mNumberChannels;
        view->frameCount = buffer->mDataByteSize / bytesPerFrame;
        return true;
    }
    return false;
}

static uint32_t process_strided(
    N60RoomMeasurementBridge *bridge,
    const float *microphone,
    uint32_t microphoneStride,
    float *outputLeft,
    uint32_t outputLeftStride,
    float *outputRight,
    uint32_t outputRightStride,
    uint32_t frameCount
) {
    if (bridge == NULL || microphone == NULL || outputLeft == NULL || outputRight == NULL) return 0;

    uint32_t cursor = atomic_load_explicit(&bridge->frameCursor, memory_order_relaxed);
    uint32_t remaining = cursor < bridge->totalFrameCount
        ? bridge->totalFrameCount - cursor
        : 0;
    uint32_t consumed = frameCount < remaining ? frameCount : remaining;

    uint32_t leftCaptured = atomic_load_explicit(&bridge->leftCapturedFrames, memory_order_relaxed);
    uint32_t rightCaptured = atomic_load_explicit(&bridge->rightCapturedFrames, memory_order_relaxed);

    uint32_t leftSweepStart = bridge->leadInFrames;
    uint32_t leftSweepEnd = leftSweepStart + bridge->sweepFrameCount;
    uint32_t rightSweepStart = bridge->rightCaptureStartFrame + bridge->leadInFrames;
    uint32_t rightSweepEnd = rightSweepStart + bridge->sweepFrameCount;
    uint32_t rightCaptureEnd = bridge->rightCaptureStartFrame + bridge->captureFrameCount;

    const float *input = microphone;
    float *left = outputLeft;
    float *right = outputRight;

    for (uint32_t offset = 0; offset < consumed; ++offset) {
        uint32_t timelineFrame = cursor + offset;
        float leftSample = 0.0f;
        float rightSample = 0.0f;

        if (timelineFrame >= leftSweepStart && timelineFrame < leftSweepEnd) {
            leftSample = bridge->sweepSamples[timelineFrame - leftSweepStart];
        } else if (timelineFrame >= rightSweepStart && timelineFrame < rightSweepEnd) {
            rightSample = bridge->sweepSamples[timelineFrame - rightSweepStart];
        }

        *left = leftSample;
        *right = rightSample;

        if (timelineFrame < bridge->captureFrameCount) {
            uint32_t captureIndex = timelineFrame;
            if (captureIndex == leftCaptured) {
                bridge->leftCapture[captureIndex] = *input;
                leftCaptured += 1u;
            }
        } else if (timelineFrame >= bridge->rightCaptureStartFrame
                   && timelineFrame < rightCaptureEnd) {
            uint32_t captureIndex = timelineFrame - bridge->rightCaptureStartFrame;
            if (captureIndex == rightCaptured) {
                bridge->rightCapture[captureIndex] = *input;
                rightCaptured += 1u;
            }
        }

        input += microphoneStride;
        left += outputLeftStride;
        right += outputRightStride;
    }

    for (uint32_t offset = consumed; offset < frameCount; ++offset) {
        *left = 0.0f;
        *right = 0.0f;
        left += outputLeftStride;
        right += outputRightStride;
    }

    cursor += consumed;
    atomic_store_explicit(&bridge->leftCapturedFrames, leftCaptured, memory_order_release);
    atomic_store_explicit(&bridge->rightCapturedFrames, rightCaptured, memory_order_release);
    atomic_store_explicit(&bridge->frameCursor, cursor, memory_order_release);

    bool complete = cursor == bridge->totalFrameCount
        && leftCaptured == bridge->captureFrameCount
        && rightCaptured == bridge->captureFrameCount;
    atomic_store_explicit(&bridge->complete, complete, memory_order_release);
    return consumed;
}

N60RoomMeasurementBridge *N60RoomMeasurementBridgeCreate(
    const float *sweepSamples,
    uint32_t sweepFrameCount,
    uint32_t leadInFrames,
    uint32_t tailFrames,
    uint32_t settlingFrames,
    uint32_t inputChannelIndex
) {
    if (sweepSamples == NULL || sweepFrameCount == 0) return NULL;

    uint64_t captureFrames64 = (uint64_t)leadInFrames
        + (uint64_t)sweepFrameCount
        + (uint64_t)tailFrames;
    uint64_t totalFrames64 = captureFrames64 * 2u + (uint64_t)settlingFrames;
    if (captureFrames64 == 0 || captureFrames64 > UINT32_MAX || totalFrames64 > UINT32_MAX) {
        return NULL;
    }

    N60RoomMeasurementBridge *bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL) return NULL;

    bridge->sweepSamples = malloc(sizeof(float) * sweepFrameCount);
    bridge->leftCapture = calloc((size_t)captureFrames64, sizeof(float));
    bridge->rightCapture = calloc((size_t)captureFrames64, sizeof(float));
    if (bridge->sweepSamples == NULL || bridge->leftCapture == NULL || bridge->rightCapture == NULL) {
        N60RoomMeasurementBridgeDestroy(bridge);
        return NULL;
    }

    memcpy(bridge->sweepSamples, sweepSamples, sizeof(float) * sweepFrameCount);
    bridge->sweepFrameCount = sweepFrameCount;
    bridge->leadInFrames = leadInFrames;
    bridge->tailFrames = tailFrames;
    bridge->settlingFrames = settlingFrames;
    bridge->captureFrameCount = (uint32_t)captureFrames64;
    bridge->rightCaptureStartFrame = bridge->captureFrameCount + settlingFrames;
    bridge->totalFrameCount = (uint32_t)totalFrames64;
    bridge->inputChannelIndex = inputChannelIndex;
    N60RoomMeasurementBridgeReset(bridge);
    return bridge;
}

void N60RoomMeasurementBridgeDestroy(N60RoomMeasurementBridge *bridge) {
    if (bridge == NULL) return;
    free(bridge->sweepSamples);
    free(bridge->leftCapture);
    free(bridge->rightCapture);
    free(bridge);
}

void N60RoomMeasurementBridgeReset(N60RoomMeasurementBridge *bridge) {
    if (bridge == NULL) return;
    memset(bridge->leftCapture, 0, sizeof(float) * bridge->captureFrameCount);
    memset(bridge->rightCapture, 0, sizeof(float) * bridge->captureFrameCount);
    atomic_store_explicit(&bridge->frameCursor, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->leftCapturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->rightCapturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->callbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->unsupportedBufferLayouts, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->complete, false, memory_order_relaxed);
}

N60RoomMeasurementBridgeSnapshot N60RoomMeasurementBridgeGetSnapshot(
    const N60RoomMeasurementBridge *bridge
) {
    if (bridge == NULL) return (N60RoomMeasurementBridgeSnapshot){0};
    return (N60RoomMeasurementBridgeSnapshot){
        .frameCursor = atomic_load_explicit(&bridge->frameCursor, memory_order_acquire),
        .totalFrameCount = bridge->totalFrameCount,
        .leftCapturedFrames = atomic_load_explicit(&bridge->leftCapturedFrames, memory_order_acquire),
        .rightCapturedFrames = atomic_load_explicit(&bridge->rightCapturedFrames, memory_order_acquire),
        .callbacks = atomic_load_explicit(&bridge->callbacks, memory_order_relaxed),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &bridge->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
        .complete = atomic_load_explicit(&bridge->complete, memory_order_acquire),
    };
}

uint32_t N60RoomMeasurementBridgeProcessPlanar(
    N60RoomMeasurementBridge *bridge,
    const float *microphoneSamples,
    float *outputLeft,
    float *outputRight,
    uint32_t frameCount
) {
    return process_strided(
        bridge,
        microphoneSamples,
        1,
        outputLeft,
        1,
        outputRight,
        1,
        frameCount
    );
}

static uint32_t copy_capture(
    const float *source,
    uint32_t availableFrames,
    float *destination,
    uint32_t capacityFrames
) {
    if (source == NULL || destination == NULL || capacityFrames == 0) return 0;
    uint32_t count = availableFrames < capacityFrames ? availableFrames : capacityFrames;
    memcpy(destination, source, sizeof(float) * count);
    return count;
}

uint32_t N60RoomMeasurementBridgeCopyLeftCapture(
    const N60RoomMeasurementBridge *bridge,
    float *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL) return 0;
    uint32_t available = atomic_load_explicit(&bridge->leftCapturedFrames, memory_order_acquire);
    return copy_capture(bridge->leftCapture, available, destination, capacityFrames);
}

uint32_t N60RoomMeasurementBridgeCopyRightCapture(
    const N60RoomMeasurementBridge *bridge,
    float *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL) return 0;
    uint32_t available = atomic_load_explicit(&bridge->rightCapturedFrames, memory_order_acquire);
    return copy_capture(bridge->rightCapture, available, destination, capacityFrames);
}

OSStatus N60RoomMeasurementIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)inOutputTime;

    N60RoomMeasurementBridge *bridge = (N60RoomMeasurementBridge *)inClientData;
    if (bridge == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->callbacks, 1, memory_order_relaxed);

    // Always silence the complete device output first. The measurement owns only
    // the first stereo pair; auxiliary interface outputs must never contain
    // stale/uninitialized samples during calibration.
    zero_output(outOutputData);

    N60MeasurementInputChannelView input = {0};
    N60MeasurementOutputChannelView left = {0};
    N60MeasurementOutputChannelView right = {0};
    if (!make_input_channel_view(inInputData, bridge->inputChannelIndex, &input)
        || !make_output_channel_view(outOutputData, 0, &left)
        || !make_output_channel_view(outOutputData, 1, &right)) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }

    uint32_t frameCount = input.frameCount;
    if (left.frameCount < frameCount) frameCount = left.frameCount;
    if (right.frameCount < frameCount) frameCount = right.frameCount;
    if (frameCount == 0) return noErr;

    (void)process_strided(
        bridge,
        input.samples,
        input.stride,
        left.samples,
        left.stride,
        right.samples,
        right.stride,
        frameCount
    );
    return noErr;
}
