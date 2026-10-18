#include "N60FeedForwardReferenceBridge.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct N60FeedForwardReferenceBridge {
    N60FeedForwardReferenceFrame *frames;
    float *errors;  /* pair mode only; same indices as frames */
    uint32_t capacity;
    uint32_t mask;
    uint32_t inputChannel;
    uint32_t errorChannel;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t receivedFrames;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t invalidTimestamps;
    _Atomic uint64_t unsupportedBufferLayouts;
};

static bool is_power_of_two(uint32_t value) {
    return value >= 256 && (value & (value - 1u)) == 0;
}

N60FeedForwardReferenceBridge *N60FeedForwardReferenceBridgeCreate(
    uint32_t capacityFrames,
    uint32_t inputChannelIndex
) {
    if (!is_power_of_two(capacityFrames)) return NULL;
    N60FeedForwardReferenceBridge *bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL) return NULL;
    bridge->frames = calloc(capacityFrames, sizeof(*bridge->frames));
    if (bridge->frames == NULL) {
        free(bridge);
        return NULL;
    }
    bridge->capacity = capacityFrames;
    bridge->mask = capacityFrames - 1;
    bridge->inputChannel = inputChannelIndex;
    return bridge;
}

N60FeedForwardReferenceBridge *N60FeedForwardReferenceBridgeCreatePair(
    uint32_t capacityFrames,
    uint32_t referenceChannelIndex,
    uint32_t errorChannelIndex
) {
    if (referenceChannelIndex == errorChannelIndex) return NULL;
    N60FeedForwardReferenceBridge *bridge =
        N60FeedForwardReferenceBridgeCreate(capacityFrames, referenceChannelIndex);
    if (bridge == NULL) return NULL;
    bridge->errors = calloc(capacityFrames, sizeof(*bridge->errors));
    if (bridge->errors == NULL) {
        N60FeedForwardReferenceBridgeDestroy(bridge);
        return NULL;
    }
    bridge->errorChannel = errorChannelIndex;
    return bridge;
}

bool N60FeedForwardReferenceBridgeIsPair(const N60FeedForwardReferenceBridge *bridge) {
    return bridge != NULL && bridge->errors != NULL;
}

void N60FeedForwardReferenceBridgeDestroy(N60FeedForwardReferenceBridge *bridge) {
    if (bridge == NULL) return;
    free(bridge->frames);
    free(bridge->errors);
    free(bridge);
}

void N60FeedForwardReferenceBridgeReset(N60FeedForwardReferenceBridge *bridge) {
    if (bridge == NULL) return;
    memset(bridge->frames, 0, bridge->capacity * sizeof(*bridge->frames));
    if (bridge->errors != NULL) {
        memset(bridge->errors, 0, bridge->capacity * sizeof(*bridge->errors));
    }
    atomic_store(&bridge->writeIndex, 0);
    atomic_store(&bridge->readIndex, 0);
    atomic_store(&bridge->receivedFrames, 0);
    atomic_store(&bridge->droppedFrames, 0);
    atomic_store(&bridge->callbacks, 0);
    atomic_store(&bridge->invalidTimestamps, 0);
    atomic_store(&bridge->unsupportedBufferLayouts, 0);
}

N60FeedForwardReferenceSnapshot N60FeedForwardReferenceBridgeGetSnapshot(
    const N60FeedForwardReferenceBridge *bridge
) {
    if (bridge == NULL) return (N60FeedForwardReferenceSnapshot){0};
    uint64_t w = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    uint64_t available = w - r;
    return (N60FeedForwardReferenceSnapshot){
        .availableFrames = (uint32_t)(
            available < bridge->capacity ? available : bridge->capacity
        ),
        .capacityFrames = bridge->capacity,
        .receivedFrames = atomic_load(&bridge->receivedFrames),
        .droppedFrames = atomic_load(&bridge->droppedFrames),
        .callbacks = atomic_load(&bridge->callbacks),
        .invalidTimestamps = atomic_load(&bridge->invalidTimestamps),
        .unsupportedBufferLayouts = atomic_load(&bridge->unsupportedBufferLayouts),
    };
}

/* error / errorStride: the error channel in pair mode, else NULL / 0. */
static uint32_t process(
    N60FeedForwardReferenceBridge *bridge,
    const float *input,
    uint32_t stride,
    const float *error,
    uint32_t errorStride,
    uint32_t count,
    uint64_t host,
    double sampleTime
) {
    if (bridge == NULL || input == NULL || stride == 0 || count == 0) return 0;
    if ((bridge->errors != NULL) != (error != NULL) || (error != NULL && errorStride == 0)) {
        return 0;
    }
    if (host == 0 || !isfinite(sampleTime) || sampleTime < 0) {
        atomic_fetch_add_explicit(&bridge->invalidTimestamps, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bridge->droppedFrames, count, memory_order_relaxed);
        return 0;
    }
    const uint64_t w = atomic_load_explicit(&bridge->writeIndex, memory_order_relaxed);
    const uint64_t r = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    const uint64_t used = w - r;
    const uint32_t space = used < bridge->capacity
        ? bridge->capacity - (uint32_t)used : 0;
    const uint32_t accepted = count < space ? count : space;
    for (uint32_t i = 0; i < accepted; ++i) {
        float x = input[(size_t)i * stride];
        if (!isfinite(x) || (error != NULL && !isfinite(error[(size_t)i * errorStride]))) {
            atomic_fetch_add_explicit(&bridge->droppedFrames, count, memory_order_relaxed);
            return 0;
        }
    }
    for (uint32_t i = 0; i < accepted; ++i) {
        bridge->frames[(uint32_t)(w + i) & bridge->mask] =
            (N60FeedForwardReferenceFrame){
                .sample = input[(size_t)i * stride],
                .firstFrameHostTime = host,
                .firstFrameSampleTime = sampleTime,
                .frameOffset = i,
            };
        if (error != NULL) {
            bridge->errors[(uint32_t)(w + i) & bridge->mask] = error[(size_t)i * errorStride];
        }
    }
    if (accepted > 0) {
        atomic_store_explicit(&bridge->writeIndex, w + accepted, memory_order_release);
        atomic_fetch_add_explicit(&bridge->receivedFrames, accepted, memory_order_relaxed);
    }
    if (accepted < count) {
        atomic_fetch_add_explicit(&bridge->droppedFrames, count - accepted, memory_order_relaxed);
    }
    return accepted;
}

uint32_t N60FeedForwardReferenceBridgeProcessPlanar(
    N60FeedForwardReferenceBridge *bridge,
    const float *input,
    uint32_t count,
    uint64_t host,
    double sampleTime
) {
    if (bridge == NULL || bridge->errors != NULL) return 0;
    return process(bridge, input, 1, NULL, 0, count, host, sampleTime);
}

uint32_t N60FeedForwardReferenceBridgeProcessPairPlanar(
    N60FeedForwardReferenceBridge *bridge,
    const float *reference,
    const float *error,
    uint32_t count,
    uint64_t host,
    double sampleTime
) {
    if (bridge == NULL || bridge->errors == NULL) return 0;
    return process(bridge, reference, 1, error, 1, count, host, sampleTime);
}

static uint32_t read_frames(
    N60FeedForwardReferenceBridge *bridge,
    N60FeedForwardReferenceFrame *destination,
    float *errorDestination,
    uint32_t capacityFrames
) {
    const uint64_t r = atomic_load_explicit(&bridge->readIndex, memory_order_relaxed);
    const uint64_t w = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    const uint64_t available = w - r;
    uint32_t count = available < capacityFrames ? (uint32_t)available : capacityFrames;
    if (count > bridge->capacity) count = bridge->capacity;
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t slot = (uint32_t)(r + i) & bridge->mask;
        destination[i] = bridge->frames[slot];
        if (errorDestination != NULL) errorDestination[i] = bridge->errors[slot];
    }
    if (count > 0) {
        atomic_store_explicit(&bridge->readIndex, r + count, memory_order_release);
    }
    return count;
}

uint32_t N60FeedForwardReferenceBridgeReadPair(
    N60FeedForwardReferenceBridge *bridge,
    N60FeedForwardReferenceFrame *destination,
    float *errorDestination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || bridge->errors == NULL || destination == NULL
        || errorDestination == NULL || capacityFrames == 0) return 0;
    return read_frames(bridge, destination, errorDestination, capacityFrames);
}

uint32_t N60FeedForwardReferenceBridgeRead(
    N60FeedForwardReferenceBridge *bridge,
    N60FeedForwardReferenceFrame *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0) return 0;
    return read_frames(bridge, destination, NULL, capacityFrames);
}

/* Finds one channel across the buffers: base pointer (at the channel), stride
 * and frame count. False if absent or the buffer layout is unusable. */
static bool locate_channel(
    const AudioBufferList *list,
    uint32_t channel,
    const float **base,
    uint32_t *stride,
    uint32_t *frames
) {
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
        const AudioBuffer *buffer = &list->mBuffers[i];
        if (channel >= buffer->mNumberChannels) {
            channel -= buffer->mNumberChannels;
            continue;
        }
        const uint32_t s = buffer->mNumberChannels;
        const uint32_t bytes = s * (uint32_t)sizeof(float);
        if (buffer->mData == NULL || bytes == 0 || buffer->mDataByteSize % bytes != 0) {
            return false;
        }
        *base = ((const float *)buffer->mData) + channel;
        *stride = s;
        *frames = buffer->mDataByteSize / bytes;
        return true;
    }
    return false;
}

OSStatus N60FeedForwardReferenceIOProc(
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
    (void)outOutputData;
    (void)inOutputTime;
    N60FeedForwardReferenceBridge *bridge =
        (N60FeedForwardReferenceBridge *)inClientData;
    if (bridge == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->callbacks, 1, memory_order_relaxed);
    if (inInputTime == NULL
        || (inInputTime->mFlags & kAudioTimeStampHostTimeValid) == 0
        || (inInputTime->mFlags & kAudioTimeStampSampleTimeValid) == 0) {
        atomic_fetch_add_explicit(&bridge->invalidTimestamps, 1, memory_order_relaxed);
        return noErr;
    }
    if (inInputData == NULL) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }
    const float *reference = NULL, *error = NULL;
    uint32_t stride = 0, errorStride = 0, frames = 0, errorFrames = 0;
    const bool found = locate_channel(inInputData, bridge->inputChannel, &reference, &stride, &frames)
        && (bridge->errors == NULL
            || (locate_channel(inInputData, bridge->errorChannel, &error, &errorStride, &errorFrames)
                && errorFrames == frames));
    if (!found) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }
    (void)process(
        bridge, reference, stride, error, errorStride, frames,
        inInputTime->mHostTime, inInputTime->mSampleTime
    );
    return noErr;
}
