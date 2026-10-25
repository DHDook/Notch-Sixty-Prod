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

/* E11 S9b: at most this many inputs beyond the primary microphone (so 16 seats in all). */
#define N60_TARGETED_MAX_EXTRA_INPUTS 15u

typedef struct {
    uint32_t frameCursor;
    uint32_t totalFrameCount;
    uint32_t capturedFrames;
    uint32_t referenceCapturedFrames;
    uint32_t outputChannelIndex;
    uint64_t callbacks;
    uint64_t unsupportedBufferLayouts;
    bool complete;
    /* E11 S9b: inputs beyond the primary, and the fewest frames captured by any of them. */
    uint32_t extraInputCount;
    uint32_t extraCapturedFramesMin;
} N60TargetedRoomMeasurementBridgeSnapshot;

typedef struct N60TargetedRoomMeasurementBridge {
    float * _Nullable sweepSamples;
    float * _Nullable capture;
    float * _Nullable referenceCapture;
    uint32_t sweepFrameCount;
    uint32_t leadInFrames;
    uint32_t tailFrames;
    uint32_t captureFrameCount;
    uint32_t inputChannelIndex;
    uint32_t referenceInputChannelIndex;
    bool hasReferenceInput;
    uint32_t outputChannelIndex;
    /* E11 S2: optional second output program (the timing-reference chirp) played on its own
     * output channel in the same pass. Preallocated and copied on the control plane. */
    float * _Nullable referenceProgram;
    uint32_t referenceProgramFrames;
    uint32_t referenceProgramStartFrame;
    uint32_t referenceOutputChannelIndex;
    bool hasReferenceProgram;
    /* E11 S9b: K-input capture. Extra seats are captured on the same timeline as the primary
     * microphone; buffers are allocated on the control plane. */
    uint32_t extraInputCount;
    uint32_t extraInputChannelIndex[N60_TARGETED_MAX_EXTRA_INPUTS];
    float * _Nullable extraCapture[N60_TARGETED_MAX_EXTRA_INPUTS];
    _Atomic uint32_t extraCapturedFrames[N60_TARGETED_MAX_EXTRA_INPUTS];
    _Atomic uint32_t frameCursor;
    _Atomic uint32_t capturedFrames;
    _Atomic uint32_t referenceCapturedFrames;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupportedBufferLayouts;
    _Atomic bool complete;
} N60TargetedRoomMeasurementBridge;

static inline void N60TargetedRoomMeasurementBridgeDestroy(
    N60TargetedRoomMeasurementBridge * _Nullable bridge
);

static inline void N60TargetedRoomMeasurementBridgeReset(
    N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    if (bridge->capture != NULL) {
        memset(bridge->capture, 0, sizeof(float) * bridge->captureFrameCount);
    }
    if (bridge->referenceCapture != NULL) {
        memset(bridge->referenceCapture, 0, sizeof(float) * bridge->captureFrameCount);
    }
    for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
        if (bridge->extraCapture[k] != NULL) {
            memset(bridge->extraCapture[k], 0, sizeof(float) * bridge->captureFrameCount);
        }
        atomic_store_explicit(&bridge->extraCapturedFrames[k], 0u, memory_order_relaxed);
    }
    atomic_store_explicit(&bridge->frameCursor, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->capturedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->referenceCapturedFrames, 0u, memory_order_relaxed);
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
    bridge->referenceInputChannelIndex = 0u;
    bridge->hasReferenceInput = false;
    bridge->outputChannelIndex = outputChannelIndex;
    N60TargetedRoomMeasurementBridgeReset(bridge);
    return bridge;
}

static inline N60TargetedRoomMeasurementBridge * _Nullable
N60TargetedRoomMeasurementBridgeCreateDualInput(
    const float * _Nonnull sweepSamples,
    uint32_t sweepFrameCount,
    uint32_t leadInFrames,
    uint32_t tailFrames,
    uint32_t microphoneInputChannelIndex,
    uint32_t referenceInputChannelIndex,
    uint32_t outputChannelIndex
) {
    if (microphoneInputChannelIndex == referenceInputChannelIndex) return NULL;
    N60TargetedRoomMeasurementBridge *bridge =
        N60TargetedRoomMeasurementBridgeCreate(
            sweepSamples,
            sweepFrameCount,
            leadInFrames,
            tailFrames,
            microphoneInputChannelIndex,
            outputChannelIndex
        );
    if (bridge == NULL) return NULL;
    bridge->referenceCapture =
        (float *)calloc((size_t)bridge->captureFrameCount, sizeof(float));
    if (bridge->referenceCapture == NULL) {
        N60TargetedRoomMeasurementBridgeDestroy(bridge);
        return NULL;
    }
    bridge->referenceInputChannelIndex = referenceInputChannelIndex;
    bridge->hasReferenceInput = true;
    N60TargetedRoomMeasurementBridgeReset(bridge);
    return bridge;
}

/*
 * E11 S9b, control plane: K simultaneous inputs. `inputChannelIndices[0]` is the primary seat
 * (captured as before); the rest are extra seats. Channels must be distinct. Returns NULL for
 * a bad argument, more than 16 inputs, a duplicate channel or an allocation failure.
 */
static inline N60TargetedRoomMeasurementBridge * _Nullable
N60TargetedRoomMeasurementBridgeCreateMultiInput(
    const float * _Nonnull sweepSamples,
    uint32_t sweepFrameCount,
    uint32_t leadInFrames,
    uint32_t tailFrames,
    const uint32_t * _Nonnull inputChannelIndices,
    uint32_t inputCount,
    uint32_t outputChannelIndex
) {
    if (inputChannelIndices == NULL || inputCount == 0u
        || inputCount > N60_TARGETED_MAX_EXTRA_INPUTS + 1u) return NULL;
    for (uint32_t i = 0; i < inputCount; ++i) {
        for (uint32_t j = i + 1u; j < inputCount; ++j) {
            if (inputChannelIndices[i] == inputChannelIndices[j]) return NULL;
        }
    }
    N60TargetedRoomMeasurementBridge *bridge = N60TargetedRoomMeasurementBridgeCreate(
        sweepSamples, sweepFrameCount, leadInFrames, tailFrames, inputChannelIndices[0],
        outputChannelIndex);
    if (bridge == NULL) return NULL;
    for (uint32_t k = 0; k + 1u < inputCount; ++k) {
        bridge->extraCapture[k] = (float *)calloc((size_t)bridge->captureFrameCount, sizeof(float));
        if (bridge->extraCapture[k] == NULL) {
            bridge->extraInputCount = k;
            N60TargetedRoomMeasurementBridgeDestroy(bridge);
            return NULL;
        }
        bridge->extraInputChannelIndex[k] = inputChannelIndices[k + 1u];
        bridge->extraInputCount = k + 1u;
    }
    N60TargetedRoomMeasurementBridgeReset(bridge);
    return bridge;
}

static inline void N60TargetedRoomMeasurementBridgeDestroy(
    N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    for (uint32_t k = 0; k < N60_TARGETED_MAX_EXTRA_INPUTS; ++k) {
        free(bridge->extraCapture[k]);
        bridge->extraCapture[k] = NULL;
    }
    free(bridge->referenceProgram);
    free(bridge->referenceCapture);
    free(bridge->capture);
    free(bridge->sweepSamples);
    bridge->referenceProgram = NULL;
    bridge->referenceCapture = NULL;
    bridge->capture = NULL;
    bridge->sweepSamples = NULL;
    free(bridge);
}

/*
 * Control plane, before the IOProc starts: attaches a second output program that is played on
 * `outputChannelIndex` starting at timeline frame `startFrame` (frames before and after it, and
 * past the program, are silent). Returns false, leaving the bridge unchanged, for a bad
 * argument, the same channel as the primary output, or an allocation failure.
 * Attach once, before start: it is not safe against a running IOProc. The program must already be at
 * the device rate; the channel must exist on the output device (a missing channel is counted in
 * unsupportedBufferLayouts). Reset keeps the program so a pass can be repeated.
 */
static inline bool N60TargetedRoomMeasurementBridgeAttachReferenceProgram(
    N60TargetedRoomMeasurementBridge * _Nullable bridge,
    const float * _Nullable samples,
    uint32_t frameCount,
    uint32_t startFrame,
    uint32_t outputChannelIndex
) {
    if (bridge == NULL || samples == NULL || frameCount == 0u) return false;
    if (outputChannelIndex == bridge->outputChannelIndex) return false;
    if ((uint64_t)startFrame + (uint64_t)frameCount > (uint64_t)bridge->captureFrameCount) return false;
    float *copy = (float *)malloc(sizeof(float) * frameCount);
    if (copy == NULL) return false;
    memcpy(copy, samples, sizeof(float) * frameCount);
    free(bridge->referenceProgram);
    bridge->referenceProgram = copy;
    bridge->referenceProgramFrames = frameCount;
    bridge->referenceProgramStartFrame = startFrame;
    bridge->referenceOutputChannelIndex = outputChannelIndex;
    bridge->hasReferenceProgram = true;
    return true;
}

static inline N60TargetedRoomMeasurementBridgeSnapshot N60TargetedRoomMeasurementBridgeGetSnapshot(
    const N60TargetedRoomMeasurementBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60TargetedRoomMeasurementBridgeSnapshot){0};
    uint32_t extraMin = bridge->extraInputCount == 0u ? 0u : UINT32_MAX;
    for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
        const uint32_t n = atomic_load_explicit(&bridge->extraCapturedFrames[k], memory_order_acquire);
        if (n < extraMin) extraMin = n;
    }
    return (N60TargetedRoomMeasurementBridgeSnapshot){
        .extraInputCount = bridge->extraInputCount,
        .extraCapturedFramesMin = extraMin,
        .frameCursor = atomic_load_explicit(&bridge->frameCursor, memory_order_acquire),
        .totalFrameCount = bridge->captureFrameCount,
        .capturedFrames = atomic_load_explicit(&bridge->capturedFrames, memory_order_acquire),
        .referenceCapturedFrames = atomic_load_explicit(
            &bridge->referenceCapturedFrames,
            memory_order_acquire
        ),
        .outputChannelIndex = bridge->outputChannelIndex,
        .callbacks = atomic_load_explicit(&bridge->callbacks, memory_order_relaxed),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &bridge->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
        .complete = atomic_load_explicit(&bridge->complete, memory_order_acquire),
    };
}

/*
 * Realtime. Allocation: none. Synchronisation: the only shared state is the atomics below, one
 * writer (this callback), read by the control thread after the pass. Latency: none added.
 * Rate and channel assumptions: native device rate, strided float32; `referenceOutput` is
 * required exactly when the bridge has a reference program. Reset: N60TargetedRoomMeasurementBridgeReset
 * on the control thread while the IOProc is stopped.
 */
static inline uint32_t N60TargetedRoomMeasurementProcessSeatsStrided(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphone,
    uint32_t microphoneStride,
    const float * _Nullable reference,
    uint32_t referenceStride,
    const float * _Nullable const * _Nullable extraInputs,
    const uint32_t * _Nullable extraStrides,
    float * _Nonnull output,
    uint32_t outputStride,
    float * _Nullable referenceOutput,
    uint32_t referenceOutputStride,
    uint32_t frameCount
) {
    if (bridge == NULL || microphone == NULL || output == NULL) return 0u;
    if (bridge->extraInputCount > 0u && (extraInputs == NULL || extraStrides == NULL)) return 0u;
    if (bridge->hasReferenceProgram
        && (referenceOutput == NULL || bridge->referenceProgram == NULL)) return 0u;
    if (bridge->hasReferenceInput
        && (reference == NULL || bridge->referenceCapture == NULL)) return 0u;

    uint32_t cursor = atomic_load_explicit(&bridge->frameCursor, memory_order_relaxed);
    const uint32_t remaining = cursor < bridge->captureFrameCount
        ? bridge->captureFrameCount - cursor : 0u;
    const uint32_t consumed = frameCount < remaining ? frameCount : remaining;
    uint32_t captured = atomic_load_explicit(
        &bridge->capturedFrames, memory_order_relaxed
    );
    uint32_t referenceCaptured = atomic_load_explicit(
        &bridge->referenceCapturedFrames, memory_order_relaxed
    );
    uint32_t extraCaptured[N60_TARGETED_MAX_EXTRA_INPUTS];
    for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
        extraCaptured[k] = atomic_load_explicit(&bridge->extraCapturedFrames[k], memory_order_relaxed);
    }
    const uint32_t sweepStart = bridge->leadInFrames;
    const uint32_t sweepEnd = sweepStart + bridge->sweepFrameCount;

    const float *input = microphone;
    const float *referenceInput = reference;
    float *destination = output;
    float *referenceDestination = referenceOutput;
    const uint32_t programStart = bridge->referenceProgramStartFrame;
    const uint32_t programEnd = programStart + bridge->referenceProgramFrames;
    for (uint32_t offset = 0; offset < consumed; ++offset) {
        const uint32_t timelineFrame = cursor + offset;
        float sample = 0.0f;
        if (timelineFrame >= sweepStart && timelineFrame < sweepEnd) {
            sample = bridge->sweepSamples[timelineFrame - sweepStart];
        }
        *destination = sample;
        if (bridge->hasReferenceProgram) {
            *referenceDestination =
                (timelineFrame >= programStart && timelineFrame < programEnd)
                ? bridge->referenceProgram[timelineFrame - programStart] : 0.0f;
            referenceDestination += referenceOutputStride;
        }
        if (timelineFrame == captured) {
            bridge->capture[captured] = *input;
            captured += 1u;
        }
        if (bridge->hasReferenceInput && timelineFrame == referenceCaptured) {
            bridge->referenceCapture[referenceCaptured] = *referenceInput;
            referenceCaptured += 1u;
        }
        for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
            if (timelineFrame == extraCaptured[k]) {
                bridge->extraCapture[k][extraCaptured[k]] = extraInputs[k][(size_t)offset * extraStrides[k]];
                extraCaptured[k] += 1u;
            }
        }
        input += microphoneStride;
        if (referenceInput != NULL) referenceInput += referenceStride;
        destination += outputStride;
    }
    for (uint32_t offset = consumed; offset < frameCount; ++offset) {
        *destination = 0.0f;
        destination += outputStride;
        if (bridge->hasReferenceProgram) {
            *referenceDestination = 0.0f;
            referenceDestination += referenceOutputStride;
        }
    }

    cursor += consumed;
    bool extrasComplete = true;
    for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
        atomic_store_explicit(&bridge->extraCapturedFrames[k], extraCaptured[k], memory_order_release);
        if (extraCaptured[k] != bridge->captureFrameCount) extrasComplete = false;
    }
    atomic_store_explicit(&bridge->capturedFrames, captured, memory_order_release);
    atomic_store_explicit(
        &bridge->referenceCapturedFrames,
        referenceCaptured,
        memory_order_release
    );
    atomic_store_explicit(&bridge->frameCursor, cursor, memory_order_release);
    const bool primaryComplete =
        cursor == bridge->captureFrameCount
        && captured == bridge->captureFrameCount
        && extrasComplete;
    const bool referenceComplete =
        !bridge->hasReferenceInput
        || referenceCaptured == bridge->captureFrameCount;
    atomic_store_explicit(
        &bridge->complete,
        primaryComplete && referenceComplete,
        memory_order_release
    );
    return consumed;
}

static inline uint32_t N60TargetedRoomMeasurementProcessProgramStrided(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphone,
    uint32_t microphoneStride,
    const float * _Nullable reference,
    uint32_t referenceStride,
    float * _Nonnull output,
    uint32_t outputStride,
    float * _Nullable referenceOutput,
    uint32_t referenceOutputStride,
    uint32_t frameCount
) {
    return N60TargetedRoomMeasurementProcessSeatsStrided(
        bridge, microphone, microphoneStride, reference, referenceStride, NULL, NULL,
        output, outputStride, referenceOutput, referenceOutputStride, frameCount);
}

static inline uint32_t N60TargetedRoomMeasurementProcessDualStrided(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphone,
    uint32_t microphoneStride,
    const float * _Nullable reference,
    uint32_t referenceStride,
    float * _Nonnull output,
    uint32_t outputStride,
    uint32_t frameCount
) {
    return N60TargetedRoomMeasurementProcessProgramStrided(
        bridge, microphone, microphoneStride, reference, referenceStride,
        output, outputStride, NULL, 0u, frameCount);
}

static inline uint32_t N60TargetedRoomMeasurementProcessStrided(
    N60TargetedRoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphone,
    uint32_t microphoneStride,
    float * _Nonnull output,
    uint32_t outputStride,
    uint32_t frameCount
) {
    return N60TargetedRoomMeasurementProcessDualStrided(
        bridge,
        microphone,
        microphoneStride,
        NULL,
        0u,
        output,
        outputStride,
        frameCount
    );
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

/* Control plane, after the pass: copies extra seat `index` (0 is the second seat overall). */
static inline uint32_t N60TargetedRoomMeasurementBridgeCopyExtraCapture(
    const N60TargetedRoomMeasurementBridge * _Nullable bridge,
    uint32_t index,
    float * _Nonnull destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || index >= bridge->extraInputCount || bridge->extraCapture[index] == NULL
        || destination == NULL || capacityFrames == 0u) return 0u;
    const uint32_t available = atomic_load_explicit(&bridge->extraCapturedFrames[index], memory_order_acquire);
    const uint32_t count = available < capacityFrames ? available : capacityFrames;
    memcpy(destination, bridge->extraCapture[index], sizeof(float) * count);
    return count;
}

static inline uint32_t N60TargetedRoomMeasurementBridgeCopyReferenceCapture(
    const N60TargetedRoomMeasurementBridge * _Nullable bridge,
    float * _Nonnull destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || !bridge->hasReferenceInput
        || bridge->referenceCapture == NULL
        || destination == NULL || capacityFrames == 0u) return 0u;
    const uint32_t available = atomic_load_explicit(
        &bridge->referenceCapturedFrames,
        memory_order_acquire
    );
    const uint32_t count =
        available < capacityFrames ? available : capacityFrames;
    memcpy(destination, bridge->referenceCapture, sizeof(float) * count);
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
    N60TargetedMeasurementInputView reference = {0};
    N60TargetedMeasurementOutputView output = {0};
    N60TargetedMeasurementOutputView referenceOutput = {0};
    const float * _Nullable extraSamples[N60_TARGETED_MAX_EXTRA_INPUTS];
    uint32_t extraStrides[N60_TARGETED_MAX_EXTRA_INPUTS];
    uint32_t extraFrames = UINT32_MAX;
    bool extrasOK = true;
    for (uint32_t k = 0; k < bridge->extraInputCount; ++k) {
        N60TargetedMeasurementInputView view = {0};
        if (!N60TargetedRoomMeasurementMakeInputView(
                inInputData, bridge->extraInputChannelIndex[k], &view)) {
            extrasOK = false;
            break;
        }
        extraSamples[k] = view.samples;
        extraStrides[k] = view.stride;
        if (view.frameCount < extraFrames) extraFrames = view.frameCount;
    }
    if (!extrasOK || !N60TargetedRoomMeasurementMakeInputView(
            inInputData,
            bridge->inputChannelIndex,
            &input)
        || (bridge->hasReferenceInput
            && !N60TargetedRoomMeasurementMakeInputView(
                inInputData,
                bridge->referenceInputChannelIndex,
                &reference))
        || !N60TargetedRoomMeasurementMakeOutputView(
            outOutputData,
            bridge->outputChannelIndex,
            &output)
        || (bridge->hasReferenceProgram
            && !N60TargetedRoomMeasurementMakeOutputView(
                outOutputData,
                bridge->referenceOutputChannelIndex,
                &referenceOutput))) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1u, memory_order_relaxed);
        return noErr;
    }

    uint32_t frameCount = input.frameCount < output.frameCount
        ? input.frameCount : output.frameCount;
    if (bridge->hasReferenceInput && reference.frameCount < frameCount) {
        frameCount = reference.frameCount;
    }
    if (bridge->extraInputCount > 0u && extraFrames < frameCount) frameCount = extraFrames;
    if (frameCount == 0u) return noErr;
    if (bridge->hasReferenceProgram && referenceOutput.frameCount < frameCount) {
        frameCount = referenceOutput.frameCount;
    }
    (void)N60TargetedRoomMeasurementProcessSeatsStrided(
        bridge,
        input.samples,
        input.stride,
        bridge->hasReferenceInput ? reference.samples : NULL,
        bridge->hasReferenceInput ? reference.stride : 0u,
        bridge->extraInputCount > 0u ? extraSamples : NULL,
        bridge->extraInputCount > 0u ? extraStrides : NULL,
        output.samples,
        output.stride,
        bridge->hasReferenceProgram ? referenceOutput.samples : NULL,
        bridge->hasReferenceProgram ? referenceOutput.stride : 0u,
        frameCount
    );
    return noErr;
}

#endif

#ifdef __cplusplus
}
#endif

#endif
