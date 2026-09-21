#include "N60RealtimeAudioBridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    float left;
    float right;
} N60StereoFrame;

struct N60RealtimeAudioBridge {
    uint32_t capacityFrames;
    N60StereoFrame *frames;

    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;

    _Atomic uint64_t captureCallbacks;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t deliveredFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t overrunFrames;
    _Atomic uint64_t unsupportedBufferLayouts;
    _Atomic uint64_t gatedOutputCallbacks;
    _Atomic uint64_t gatedOutputFrames;

    _Atomic uint32_t outputGainBits;
    _Atomic uint32_t outputGateMinimumBufferedFrames;
    _Atomic bool outputGateOpen;
};

static uint32_t float_to_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float bits_to_float(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void zero_output(AudioBufferList *bufferList) {
    if (bufferList == NULL) {
        return;
    }

    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static bool read_input_frame(const AudioBufferList *bufferList, UInt32 frameIndex, N60StereoFrame *frame) {
    if (bufferList == NULL || frame == NULL) {
        return false;
    }

    if (bufferList->mNumberBuffers == 1) {
        const AudioBuffer *buffer = &bufferList->mBuffers[0];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) {
            return false;
        }
        const float *samples = (const float *)buffer->mData;
        frame->left = samples[frameIndex * 2];
        frame->right = samples[frameIndex * 2 + 1];
        return true;
    }

    if (bufferList->mNumberBuffers >= 2) {
        const AudioBuffer *left = &bufferList->mBuffers[0];
        const AudioBuffer *right = &bufferList->mBuffers[1];
        if (left->mData == NULL || right->mData == NULL || left->mNumberChannels < 1 || right->mNumberChannels < 1) {
            return false;
        }
        frame->left = ((const float *)left->mData)[frameIndex];
        frame->right = ((const float *)right->mData)[frameIndex];
        return true;
    }

    return false;
}

static bool write_output_frame(AudioBufferList *bufferList, UInt32 frameIndex, N60StereoFrame frame, float gain) {
    if (bufferList == NULL) {
        return false;
    }

    frame.left *= gain;
    frame.right *= gain;

    if (bufferList->mNumberBuffers == 1) {
        AudioBuffer *buffer = &bufferList->mBuffers[0];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) {
            return false;
        }
        float *samples = (float *)buffer->mData;
        samples[frameIndex * 2] = frame.left;
        samples[frameIndex * 2 + 1] = frame.right;
        return true;
    }

    if (bufferList->mNumberBuffers >= 2) {
        AudioBuffer *left = &bufferList->mBuffers[0];
        AudioBuffer *right = &bufferList->mBuffers[1];
        if (left->mData == NULL || right->mData == NULL || left->mNumberChannels < 1 || right->mNumberChannels < 1) {
            return false;
        }
        ((float *)left->mData)[frameIndex] = frame.left;
        ((float *)right->mData)[frameIndex] = frame.right;
        return true;
    }

    return false;
}

N60RealtimeAudioBridge *N60RealtimeAudioBridgeCreate(uint32_t capacityFrames) {
    if (capacityFrames == 0) {
        return NULL;
    }

    N60RealtimeAudioBridge *bridge = calloc(1, sizeof(N60RealtimeAudioBridge));
    if (bridge == NULL) {
        return NULL;
    }

    bridge->frames = calloc(capacityFrames, sizeof(N60StereoFrame));
    if (bridge->frames == NULL) {
        free(bridge);
        return NULL;
    }

    bridge->capacityFrames = capacityFrames;
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_relaxed);
    return bridge;
}

void N60RealtimeAudioBridgeDestroy(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }
    free(bridge->frames);
    free(bridge);
}

void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) {
        return;
    }

    atomic_store_explicit(&bridge->writeIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->readIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->captureCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->capturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->deliveredFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->underrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->overrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->unsupportedBufferLayouts, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateMinimumBufferedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
}

void N60RealtimeAudioBridgeSetOutputGain(N60RealtimeAudioBridge *bridge, float gain) {
    if (bridge == NULL) {
        return;
    }
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(gain), memory_order_release);
}

void N60RealtimeAudioBridgeConfigureOutputGate(N60RealtimeAudioBridge *bridge, uint32_t minimumBufferedFrames) {
    if (bridge == NULL) {
        return;
    }

    atomic_store_explicit(&bridge->outputGateMinimumBufferedFrames, minimumBufferedFrames, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateOpen, minimumBufferedFrames == 0, memory_order_release);
}

N60RealtimeAudioBridgeSnapshot N60RealtimeAudioBridgeGetSnapshot(const N60RealtimeAudioBridge *bridge) {
    N60RealtimeAudioBridgeSnapshot snapshot = {0};
    if (bridge == NULL) {
        return snapshot;
    }

    snapshot.captureCallbacks = atomic_load_explicit(&bridge->captureCallbacks, memory_order_relaxed);
    snapshot.outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed);
    snapshot.capturedFrames = atomic_load_explicit(&bridge->capturedFrames, memory_order_relaxed);
    snapshot.deliveredFrames = atomic_load_explicit(&bridge->deliveredFrames, memory_order_relaxed);
    snapshot.underrunFrames = atomic_load_explicit(&bridge->underrunFrames, memory_order_relaxed);
    snapshot.overrunFrames = atomic_load_explicit(&bridge->overrunFrames, memory_order_relaxed);
    snapshot.unsupportedBufferLayouts = atomic_load_explicit(&bridge->unsupportedBufferLayouts, memory_order_relaxed);
    snapshot.gatedOutputCallbacks = atomic_load_explicit(&bridge->gatedOutputCallbacks, memory_order_relaxed);
    snapshot.gatedOutputFrames = atomic_load_explicit(&bridge->gatedOutputFrames, memory_order_relaxed);
    snapshot.outputGateOpen = atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire);

    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    uint64_t buffered = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (buffered > bridge->capacityFrames) {
        buffered = bridge->capacityFrames;
    }
    snapshot.bufferedFrames = (uint32_t)buffered;
    return snapshot;
}

OSStatus N60CaptureIOProc(
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

    N60RealtimeAudioBridge *bridge = (N60RealtimeAudioBridge *)inClientData;
    if (bridge == NULL || inInputData == NULL) {
        return noErr;
    }

    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1, memory_order_relaxed);

    UInt32 frameCount = 0;
    if (inInputData->mNumberBuffers == 1 && inInputData->mBuffers[0].mNumberChannels == 2) {
        frameCount = inInputData->mBuffers[0].mDataByteSize / (UInt32)(sizeof(float) * 2);
    } else if (inInputData->mNumberBuffers >= 2) {
        frameCount = inInputData->mBuffers[0].mDataByteSize / (UInt32)sizeof(float);
    } else {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }

    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_relaxed);
    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    uint64_t used = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    uint64_t available = used < bridge->capacityFrames ? bridge->capacityFrames - used : 0;
    UInt32 framesToWrite = frameCount < available ? frameCount : (UInt32)available;

    for (UInt32 frameIndex = 0; frameIndex < framesToWrite; ++frameIndex) {
        N60StereoFrame frame;
        if (!read_input_frame(inInputData, frameIndex, &frame)) {
            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
            return noErr;
        }
        bridge->frames[(writeIndex + frameIndex) % bridge->capacityFrames] = frame;
    }

    atomic_store_explicit(&bridge->writeIndex, writeIndex + framesToWrite, memory_order_release);
    atomic_fetch_add_explicit(&bridge->capturedFrames, framesToWrite, memory_order_relaxed);
    if (framesToWrite < frameCount) {
        atomic_fetch_add_explicit(&bridge->overrunFrames, frameCount - framesToWrite, memory_order_relaxed);
    }

    return noErr;
}

OSStatus N60OutputIOProc(
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
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;

    N60RealtimeAudioBridge *bridge = (N60RealtimeAudioBridge *)inClientData;
    if (bridge == NULL || outOutputData == NULL) {
        return noErr;
    }

    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1, memory_order_relaxed);

    UInt32 frameCount = 0;
    if (outOutputData->mNumberBuffers == 1 && outOutputData->mBuffers[0].mNumberChannels == 2) {
        frameCount = outOutputData->mBuffers[0].mDataByteSize / (UInt32)(sizeof(float) * 2);
    } else if (outOutputData->mNumberBuffers >= 2) {
        frameCount = outOutputData->mBuffers[0].mDataByteSize / (UInt32)sizeof(float);
    } else {
        zero_output(outOutputData);
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }

    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_relaxed);
    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;

    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        uint32_t gateMinimum = atomic_load_explicit(&bridge->outputGateMinimumBufferedFrames, memory_order_relaxed);
        if (available >= gateMinimum && available >= frameCount) {
            atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
        } else {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
            return noErr;
        }
    }

    UInt32 framesToRead = frameCount < available ? frameCount : (UInt32)available;
    float gain = bits_to_float(atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire));

    for (UInt32 frameIndex = 0; frameIndex < framesToRead; ++frameIndex) {
        N60StereoFrame frame = bridge->frames[(readIndex + frameIndex) % bridge->capacityFrames];
        if (!write_output_frame(outOutputData, frameIndex, frame, gain)) {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
            return noErr;
        }
    }

    for (UInt32 frameIndex = framesToRead; frameIndex < frameCount; ++frameIndex) {
        N60StereoFrame silence = {0.0f, 0.0f};
        (void)write_output_frame(outOutputData, frameIndex, silence, 1.0f);
    }

    atomic_store_explicit(&bridge->readIndex, readIndex + framesToRead, memory_order_release);
    atomic_fetch_add_explicit(&bridge->deliveredFrames, framesToRead, memory_order_relaxed);
    if (framesToRead < frameCount) {
        atomic_fetch_add_explicit(&bridge->underrunFrames, frameCount - framesToRead, memory_order_relaxed);
    }

    return noErr;
}
