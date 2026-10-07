#include "N60AmbientMonitorBridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const float *samples;
    uint32_t stride;
    uint32_t frameCount;
} N60AmbientInputView;

struct N60AmbientMonitorBridge {
    float *frames;
    uint32_t capacityFrames;
    uint32_t mask;
    uint32_t inputChannelIndex;

    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupportedBufferLayouts;
};

static bool is_power_of_two(uint32_t value) {
    return value > 0 && (value & (value - 1u)) == 0u;
}

static bool make_input_channel_view(
    const AudioBufferList *bufferList,
    uint32_t channelIndex,
    N60AmbientInputView *view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60AmbientInputView){0};

    uint32_t remainingChannel = channelIndex;
    for (UInt32 bufferIndex = 0;
         bufferIndex < bufferList->mNumberBuffers;
         ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0) continue;
        if (remainingChannel >= buffer->mNumberChannels) {
            remainingChannel -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;

        uint32_t bytesPerFrame =
            (uint32_t)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0
            || (buffer->mDataByteSize % bytesPerFrame) != 0) {
            return false;
        }

        view->samples =
            ((const float *)buffer->mData) + remainingChannel;
        view->stride = buffer->mNumberChannels;
        view->frameCount = buffer->mDataByteSize / bytesPerFrame;
        return true;
    }
    return false;
}

static uint32_t process_strided(
    N60AmbientMonitorBridge *bridge,
    const float *samples,
    uint32_t stride,
    uint32_t frameCount
) {
    if (bridge == NULL || samples == NULL || stride == 0
        || frameCount == 0) {
        return 0;
    }

    uint64_t writeIndex = atomic_load_explicit(
        &bridge->writeIndex,
        memory_order_relaxed
    );
    uint64_t readIndex = atomic_load_explicit(
        &bridge->readIndex,
        memory_order_acquire
    );
    uint64_t used = writeIndex - readIndex;
    uint32_t writable = used < bridge->capacityFrames
        ? bridge->capacityFrames - (uint32_t)used
        : 0;
    uint32_t accepted =
        frameCount < writable ? frameCount : writable;

    const float *source = samples;
    for (uint32_t frame = 0; frame < accepted; ++frame) {
        bridge->frames[(uint32_t)(writeIndex + frame) & bridge->mask]
            = *source;
        source += stride;
    }

    if (accepted > 0) {
        atomic_store_explicit(
            &bridge->writeIndex,
            writeIndex + accepted,
            memory_order_release
        );
        atomic_fetch_add_explicit(
            &bridge->capturedFrames,
            accepted,
            memory_order_relaxed
        );
    }
    if (accepted < frameCount) {
        atomic_fetch_add_explicit(
            &bridge->droppedFrames,
            frameCount - accepted,
            memory_order_relaxed
        );
    }
    return accepted;
}

N60AmbientMonitorBridge *N60AmbientMonitorBridgeCreate(
    uint32_t capacityFrames,
    uint32_t inputChannelIndex
) {
    if (!is_power_of_two(capacityFrames) || capacityFrames < 256u) {
        return NULL;
    }

    N60AmbientMonitorBridge *bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL) return NULL;

    bridge->frames = calloc(capacityFrames, sizeof(float));
    if (bridge->frames == NULL) {
        free(bridge);
        return NULL;
    }
    bridge->capacityFrames = capacityFrames;
    bridge->mask = capacityFrames - 1u;
    bridge->inputChannelIndex = inputChannelIndex;
    N60AmbientMonitorBridgeReset(bridge);
    return bridge;
}

void N60AmbientMonitorBridgeDestroy(N60AmbientMonitorBridge *bridge) {
    if (bridge == NULL) return;
    free(bridge->frames);
    free(bridge);
}

void N60AmbientMonitorBridgeReset(N60AmbientMonitorBridge *bridge) {
    if (bridge == NULL) return;
    memset(
        bridge->frames,
        0,
        sizeof(float) * bridge->capacityFrames
    );
    atomic_store_explicit(
        &bridge->writeIndex, 0, memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->readIndex, 0, memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->capturedFrames, 0, memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->droppedFrames, 0, memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->callbacks, 0, memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->unsupportedBufferLayouts, 0, memory_order_relaxed
    );
}

N60AmbientMonitorSnapshot N60AmbientMonitorBridgeGetSnapshot(
    const N60AmbientMonitorBridge *bridge
) {
    if (bridge == NULL) return (N60AmbientMonitorSnapshot){0};

    uint64_t writeIndex = atomic_load_explicit(
        &bridge->writeIndex,
        memory_order_acquire
    );
    uint64_t readIndex = atomic_load_explicit(
        &bridge->readIndex,
        memory_order_acquire
    );
    uint64_t available64 = writeIndex - readIndex;
    uint32_t available = available64 < bridge->capacityFrames
        ? (uint32_t)available64
        : bridge->capacityFrames;

    return (N60AmbientMonitorSnapshot){
        .capacityFrames = bridge->capacityFrames,
        .availableFrames = available,
        .capturedFrames = atomic_load_explicit(
            &bridge->capturedFrames,
            memory_order_relaxed
        ),
        .droppedFrames = atomic_load_explicit(
            &bridge->droppedFrames,
            memory_order_relaxed
        ),
        .callbacks = atomic_load_explicit(
            &bridge->callbacks,
            memory_order_relaxed
        ),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &bridge->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
    };
}

uint32_t N60AmbientMonitorBridgeProcessPlanar(
    N60AmbientMonitorBridge *bridge,
    const float *microphoneSamples,
    uint32_t frameCount
) {
    return process_strided(
        bridge,
        microphoneSamples,
        1u,
        frameCount
    );
}

uint32_t N60AmbientMonitorBridgeReadFrames(
    N60AmbientMonitorBridge *bridge,
    float *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0) {
        return 0;
    }

    uint64_t readIndex = atomic_load_explicit(
        &bridge->readIndex,
        memory_order_relaxed
    );
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->writeIndex,
        memory_order_acquire
    );
    uint64_t available64 = writeIndex - readIndex;
    uint32_t available = available64 < bridge->capacityFrames
        ? (uint32_t)available64
        : bridge->capacityFrames;
    uint32_t count =
        available < capacityFrames ? available : capacityFrames;

    for (uint32_t frame = 0; frame < count; ++frame) {
        destination[frame] =
            bridge->frames[(uint32_t)(readIndex + frame) & bridge->mask];
    }
    if (count > 0) {
        atomic_store_explicit(
            &bridge->readIndex,
            readIndex + count,
            memory_order_release
        );
    }
    return count;
}

void N60AmbientMonitorBridgeDiscardFrames(
    N60AmbientMonitorBridge *bridge
) {
    if (bridge == NULL) return;
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->writeIndex,
        memory_order_acquire
    );
    atomic_store_explicit(
        &bridge->readIndex,
        writeIndex,
        memory_order_release
    );
}

OSStatus N60AmbientMonitorIOProc(
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
    (void)outOutputData;
    (void)inOutputTime;

    N60AmbientMonitorBridge *bridge =
        (N60AmbientMonitorBridge *)inClientData;
    if (bridge == NULL) return noErr;

    atomic_fetch_add_explicit(
        &bridge->callbacks,
        1,
        memory_order_relaxed
    );

    N60AmbientInputView input = {0};
    if (!make_input_channel_view(
            inInputData,
            bridge->inputChannelIndex,
            &input
        )) {
        atomic_fetch_add_explicit(
            &bridge->unsupportedBufferLayouts,
            1,
            memory_order_relaxed
        );
        return noErr;
    }
    (void)process_strided(
        bridge,
        input.samples,
        input.stride,
        input.frameCount
    );
    return noErr;
}
