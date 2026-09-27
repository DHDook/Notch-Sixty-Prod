#include "N60RealtimeAudioBridge.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    float left;
    float right;
} N60StereoFrame;

typedef struct {
    const float *left;
    const float *right;
    UInt32 leftStride;
    UInt32 rightStride;
    UInt32 frameCount;
} N60InputBufferView;

typedef struct {
    float *left;
    float *right;
    UInt32 leftStride;
    UInt32 rightStride;
    UInt32 frameCount;
} N60OutputBufferView;

typedef struct {
    float currentGain;
    float startGain;
    float targetGain;
    uint32_t totalFrames;
    uint32_t remainingFrames;
    uint64_t appliedCommandSequence;
} N60TransitionRampRuntime;

typedef struct {
    uint32_t totalFrames;
    uint32_t remainingFrames;
    uint64_t appliedCommandSequence;
} N60StartupFadeRuntime;

struct N60RealtimeAudioBridge {
    uint32_t capacityFrames;
    N60StereoFrame *frames;
    N60RenderKernel *renderKernel;

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

    // Control-plane command payload plus an even/odd sequence. The output
    // callback latches a stable command once per callback and then advances a
    // plain callback-local runtime. This keeps atomics out of the per-sample
    // transition path while allowing commands to arrive concurrently.
    _Atomic uint64_t transitionCommandSequence;
    _Atomic uint32_t transitionTargetGainBits;
    _Atomic uint32_t transitionFramesTotal;
    _Atomic uint32_t transitionGainBits;
    _Atomic uint32_t transitionFramesRemaining;
    N60TransitionRampRuntime transitionRuntime;

    _Atomic uint32_t outputGateMinimumBufferedFrames;
    _Atomic bool outputGateOpen;
    _Atomic uint64_t startupFadeCommandSequence;
    _Atomic uint32_t startupFadeFramesTotal;
    N60StartupFadeRuntime startupFadeRuntime;
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

static float clamp_gain(float gain) {
    if (!isfinite(gain)) return 0.0f;
    if (gain < 0.0f) return 0.0f;
    if (gain > 1.0f) return 1.0f;
    return gain;
}

static void zero_output(AudioBufferList *bufferList) {
    if (bufferList == NULL) return;
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static bool make_input_buffer_view(
    const AudioBufferList *bufferList,
    N60InputBufferView *view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60InputBufferView){0};

    if (bufferList->mNumberBuffers == 1) {
        const AudioBuffer *buffer = &bufferList->mBuffers[0];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) return false;
        const float *samples = (const float *)buffer->mData;
        view->left = samples;
        view->right = samples + 1;
        view->leftStride = 2;
        view->rightStride = 2;
        view->frameCount = buffer->mDataByteSize / (UInt32)(sizeof(float) * 2);
        return true;
    }

    if (bufferList->mNumberBuffers >= 2) {
        const AudioBuffer *left = &bufferList->mBuffers[0];
        const AudioBuffer *right = &bufferList->mBuffers[1];
        if (left->mData == NULL || right->mData == NULL
            || left->mNumberChannels < 1 || right->mNumberChannels < 1) {
            return false;
        }
        UInt32 leftFrames = left->mDataByteSize
            / (UInt32)(sizeof(float) * left->mNumberChannels);
        UInt32 rightFrames = right->mDataByteSize
            / (UInt32)(sizeof(float) * right->mNumberChannels);
        view->left = (const float *)left->mData;
        view->right = (const float *)right->mData;
        view->leftStride = left->mNumberChannels;
        view->rightStride = right->mNumberChannels;
        view->frameCount = leftFrames < rightFrames ? leftFrames : rightFrames;
        return true;
    }

    return false;
}

static bool make_output_buffer_view(
    AudioBufferList *bufferList,
    N60OutputBufferView *view
) {
    if (bufferList == NULL || view == NULL) return false;
    *view = (N60OutputBufferView){0};

    if (bufferList->mNumberBuffers == 1) {
        AudioBuffer *buffer = &bufferList->mBuffers[0];
        if (buffer->mData == NULL || buffer->mNumberChannels != 2) return false;
        float *samples = (float *)buffer->mData;
        view->left = samples;
        view->right = samples + 1;
        view->leftStride = 2;
        view->rightStride = 2;
        view->frameCount = buffer->mDataByteSize / (UInt32)(sizeof(float) * 2);
        return true;
    }

    if (bufferList->mNumberBuffers >= 2) {
        AudioBuffer *left = &bufferList->mBuffers[0];
        AudioBuffer *right = &bufferList->mBuffers[1];
        if (left->mData == NULL || right->mData == NULL
            || left->mNumberChannels < 1 || right->mNumberChannels < 1) {
            return false;
        }
        UInt32 leftFrames = left->mDataByteSize
            / (UInt32)(sizeof(float) * left->mNumberChannels);
        UInt32 rightFrames = right->mDataByteSize
            / (UInt32)(sizeof(float) * right->mNumberChannels);
        view->left = (float *)left->mData;
        view->right = (float *)right->mData;
        view->leftStride = left->mNumberChannels;
        view->rightStride = right->mNumberChannels;
        view->frameCount = leftFrames < rightFrames ? leftFrames : rightFrames;
        return true;
    }

    return false;
}

static void begin_command_write(_Atomic uint64_t *sequence) {
    // Single control-plane writer contract: odd means a payload write is in
    // progress; even means readers may latch it.
    atomic_fetch_add_explicit(sequence, 1, memory_order_acq_rel);
}

static void end_command_write(_Atomic uint64_t *sequence) {
    atomic_fetch_add_explicit(sequence, 1, memory_order_release);
}

static void latch_transition_command(N60RealtimeAudioBridge *bridge) {
    uint64_t before = atomic_load_explicit(&bridge->transitionCommandSequence, memory_order_acquire);
    if ((before & 1u) != 0 || before == bridge->transitionRuntime.appliedCommandSequence) return;

    uint32_t targetBits = atomic_load_explicit(&bridge->transitionTargetGainBits, memory_order_relaxed);
    uint32_t totalFrames = atomic_load_explicit(&bridge->transitionFramesTotal, memory_order_relaxed);
    uint64_t after = atomic_load_explicit(&bridge->transitionCommandSequence, memory_order_acquire);
    if (before != after || (after & 1u) != 0) return;

    N60TransitionRampRuntime *runtime = &bridge->transitionRuntime;
    runtime->appliedCommandSequence = after;
    runtime->startGain = runtime->currentGain;
    runtime->targetGain = bits_to_float(targetBits);
    runtime->totalFrames = totalFrames;
    runtime->remainingFrames = totalFrames;
    if (totalFrames == 0 || runtime->currentGain == runtime->targetGain) {
        runtime->currentGain = runtime->targetGain;
        runtime->startGain = runtime->targetGain;
        runtime->remainingFrames = 0;
    }
}

static void latch_startup_fade_command(N60RealtimeAudioBridge *bridge) {
    uint64_t before = atomic_load_explicit(&bridge->startupFadeCommandSequence, memory_order_acquire);
    if ((before & 1u) != 0 || before == bridge->startupFadeRuntime.appliedCommandSequence) return;

    uint32_t totalFrames = atomic_load_explicit(&bridge->startupFadeFramesTotal, memory_order_relaxed);
    uint64_t after = atomic_load_explicit(&bridge->startupFadeCommandSequence, memory_order_acquire);
    if (before != after || (after & 1u) != 0) return;

    bridge->startupFadeRuntime.appliedCommandSequence = after;
    bridge->startupFadeRuntime.totalFrames = totalFrames;
    bridge->startupFadeRuntime.remainingFrames = totalFrames;
}

static float next_transition_gain(N60TransitionRampRuntime *runtime) {
    if (runtime->remainingFrames == 0 || runtime->totalFrames == 0) {
        return runtime->currentGain;
    }

    uint32_t completed = runtime->totalFrames - runtime->remainingFrames + 1;
    float mix = (float)completed / (float)runtime->totalFrames;
    runtime->currentGain = runtime->startGain + (runtime->targetGain - runtime->startGain) * mix;
    runtime->remainingFrames -= 1;
    if (runtime->remainingFrames == 0) runtime->currentGain = runtime->targetGain;
    return runtime->currentGain;
}

static float startup_fade_gain(N60StartupFadeRuntime *runtime, float masterGain) {
    if (runtime->remainingFrames == 0 || runtime->totalFrames == 0) return masterGain;

    uint32_t completed = runtime->totalFrames - runtime->remainingFrames + 1;
    float ramp = (float)completed / (float)runtime->totalFrames;
    runtime->remainingFrames -= 1;
    return masterGain * ramp;
}

static void publish_transition_runtime(
    N60RealtimeAudioBridge *bridge,
    const N60TransitionRampRuntime *runtime
) {
    atomic_store_explicit(
        &bridge->transitionGainBits,
        float_to_bits(runtime->currentGain),
        memory_order_release
    );
    atomic_store_explicit(
        &bridge->transitionFramesRemaining,
        runtime->remainingFrames,
        memory_order_release
    );
}

N60RealtimeAudioBridge *N60RealtimeAudioBridgeCreate(uint32_t capacityFrames) {
    if (capacityFrames == 0) return NULL;
    N60RealtimeAudioBridge *bridge = calloc(1, sizeof(N60RealtimeAudioBridge));
    if (bridge == NULL) return NULL;

    bridge->frames = calloc(capacityFrames, sizeof(N60StereoFrame));
    if (bridge->frames == NULL) {
        free(bridge);
        return NULL;
    }

    bridge->renderKernel = N60RenderKernelCreate();
    if (bridge->renderKernel == NULL) {
        free(bridge->frames);
        free(bridge);
        return NULL;
    }

    bridge->capacityFrames = capacityFrames;
    bridge->transitionRuntime.currentGain = 1.0f;
    bridge->transitionRuntime.startGain = 1.0f;
    bridge->transitionRuntime.targetGain = 1.0f;
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionTargetGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_relaxed);
    return bridge;
}

void N60RealtimeAudioBridgeDestroy(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return;
    N60RenderKernelDestroy(bridge->renderKernel);
    free(bridge->frames);
    free(bridge);
}

void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return;

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

    atomic_store_explicit(&bridge->transitionCommandSequence, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionTargetGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionFramesTotal, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionFramesRemaining, 0, memory_order_relaxed);
    bridge->transitionRuntime = (N60TransitionRampRuntime){
        .currentGain = 1.0f,
        .startGain = 1.0f,
        .targetGain = 1.0f,
    };

    atomic_store_explicit(&bridge->outputGateMinimumBufferedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
    atomic_store_explicit(&bridge->startupFadeCommandSequence, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->startupFadeFramesTotal, 0, memory_order_relaxed);
    bridge->startupFadeRuntime = (N60StartupFadeRuntime){0};

    N60RenderKernelReset(bridge->renderKernel);
}

void N60RealtimeAudioBridgeSetOutputGain(N60RealtimeAudioBridge *bridge, float gain) {
    if (bridge == NULL) return;
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(gain), memory_order_release);
}

void N60RealtimeAudioBridgeSetTransitionGainImmediate(N60RealtimeAudioBridge *bridge, float gain) {
    if (bridge == NULL) return;
    float clamped = clamp_gain(gain);
    uint32_t bits = float_to_bits(clamped);

    begin_command_write(&bridge->transitionCommandSequence);
    atomic_store_explicit(&bridge->transitionTargetGainBits, bits, memory_order_relaxed);
    atomic_store_explicit(&bridge->transitionFramesTotal, 0, memory_order_relaxed);
    end_command_write(&bridge->transitionCommandSequence);

    // Snapshot telemetry reflects the command immediately; the callback-owned
    // runtime consumes the command at its next bounded latch point.
    atomic_store_explicit(&bridge->transitionGainBits, bits, memory_order_release);
    atomic_store_explicit(&bridge->transitionFramesRemaining, 0, memory_order_release);
}

void N60RealtimeAudioBridgeRampTransitionGain(
    N60RealtimeAudioBridge *bridge,
    float targetGain,
    uint32_t transitionFrames
) {
    if (bridge == NULL) return;
    float target = clamp_gain(targetGain);
    if (transitionFrames == 0) {
        N60RealtimeAudioBridgeSetTransitionGainImmediate(bridge, target);
        return;
    }

    begin_command_write(&bridge->transitionCommandSequence);
    atomic_store_explicit(
        &bridge->transitionTargetGainBits,
        float_to_bits(target),
        memory_order_relaxed
    );
    atomic_store_explicit(&bridge->transitionFramesTotal, transitionFrames, memory_order_relaxed);
    end_command_write(&bridge->transitionCommandSequence);

    atomic_store_explicit(&bridge->transitionFramesRemaining, transitionFrames, memory_order_release);
}

void N60RealtimeAudioBridgeConfigureOutputGate(
    N60RealtimeAudioBridge *bridge,
    uint32_t minimumBufferedFrames,
    uint32_t fadeInFrames
) {
    if (bridge == NULL) return;

    atomic_store_explicit(
        &bridge->outputGateMinimumBufferedFrames,
        minimumBufferedFrames,
        memory_order_relaxed
    );
    begin_command_write(&bridge->startupFadeCommandSequence);
    atomic_store_explicit(&bridge->startupFadeFramesTotal, fadeInFrames, memory_order_relaxed);
    end_command_write(&bridge->startupFadeCommandSequence);
    atomic_store_explicit(
        &bridge->outputGateOpen,
        minimumBufferedFrames == 0,
        memory_order_release
    );
}

bool N60RealtimeAudioBridgePrepareConvolutionProgram(
    N60RealtimeAudioBridge *bridge,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPrepareConvolutionProgram(
        bridge->renderKernel,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}

bool N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
    N60RealtimeAudioBridge *bridge,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPrepareRoomCorrectionProgram(
        bridge->renderKernel,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}

bool N60RealtimeAudioBridgePrepareSpeakerIRProgram(
    N60RealtimeAudioBridge *bridge,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPrepareSpeakerIRProgram(
        bridge->renderKernel,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}

bool N60RealtimeAudioBridgePublishDSPGraph(
    N60RealtimeAudioBridge *bridge,
    N60DSPGraphSnapshot snapshot
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPublishSnapshot(bridge->renderKernel, snapshot);
}

N60RealtimeAudioBridgeSnapshot N60RealtimeAudioBridgeGetSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    N60RealtimeAudioBridgeSnapshot snapshot = {0};
    if (bridge == NULL) return snapshot;

    snapshot.captureCallbacks = atomic_load_explicit(&bridge->captureCallbacks, memory_order_relaxed);
    snapshot.outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed);
    snapshot.capturedFrames = atomic_load_explicit(&bridge->capturedFrames, memory_order_relaxed);
    snapshot.deliveredFrames = atomic_load_explicit(&bridge->deliveredFrames, memory_order_relaxed);
    snapshot.underrunFrames = atomic_load_explicit(&bridge->underrunFrames, memory_order_relaxed);
    snapshot.overrunFrames = atomic_load_explicit(&bridge->overrunFrames, memory_order_relaxed);
    snapshot.unsupportedBufferLayouts = atomic_load_explicit(
        &bridge->unsupportedBufferLayouts,
        memory_order_relaxed
    );
    snapshot.gatedOutputCallbacks = atomic_load_explicit(
        &bridge->gatedOutputCallbacks,
        memory_order_relaxed
    );
    snapshot.gatedOutputFrames = atomic_load_explicit(
        &bridge->gatedOutputFrames,
        memory_order_relaxed
    );
    snapshot.outputGateOpen = atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire);
    snapshot.transitionGain = bits_to_float(
        atomic_load_explicit(&bridge->transitionGainBits, memory_order_acquire)
    );
    snapshot.transitionFramesRemaining = atomic_load_explicit(
        &bridge->transitionFramesRemaining,
        memory_order_acquire
    );

    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    uint64_t buffered = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (buffered > bridge->capacityFrames) buffered = bridge->capacityFrames;
    snapshot.bufferedFrames = (uint32_t)buffered;
    return snapshot;
}

N60RenderKernelDiagnostics N60RealtimeAudioBridgeGetRenderDiagnostics(
    const N60RealtimeAudioBridge *bridge
) {
    if (bridge == NULL || bridge->renderKernel == NULL) {
        N60RenderKernelDiagnostics diagnostics = {0};
        return diagnostics;
    }
    return N60RenderKernelGetDiagnostics(bridge->renderKernel);
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
    if (bridge == NULL || inInputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1, memory_order_relaxed);

    N60InputBufferView inputView = {0};
    if (!make_input_buffer_view(inInputData, &inputView)) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }
    UInt32 frameCount = inputView.frameCount;

    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_relaxed);
    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_acquire);
    uint64_t used = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    uint64_t available = used < bridge->capacityFrames ? bridge->capacityFrames - used : 0;
    UInt32 framesToWrite = frameCount < available ? frameCount : (UInt32)available;
    uint32_t ringWriteIndex = (uint32_t)(writeIndex % bridge->capacityFrames);
    const float *inputLeft = inputView.left;
    const float *inputRight = inputView.right;

    for (UInt32 frameIndex = 0; frameIndex < framesToWrite; ++frameIndex) {
        N60StereoFrame frame = {*inputLeft, *inputRight};
        inputLeft += inputView.leftStride;
        inputRight += inputView.rightStride;
        bridge->frames[ringWriteIndex] = frame;
        ringWriteIndex += 1u;
        if (ringWriteIndex == bridge->capacityFrames) ringWriteIndex = 0u;
    }

    atomic_store_explicit(&bridge->writeIndex, writeIndex + framesToWrite, memory_order_release);
    atomic_fetch_add_explicit(&bridge->capturedFrames, framesToWrite, memory_order_relaxed);
    if (framesToWrite < frameCount) {
        atomic_fetch_add_explicit(
            &bridge->overrunFrames,
            frameCount - framesToWrite,
            memory_order_relaxed
        );
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
    if (bridge == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1, memory_order_relaxed);

    N60OutputBufferView outputView = {0};
    if (!make_output_buffer_view(outOutputData, &outputView)) {
        zero_output(outOutputData);
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }
    UInt32 frameCount = outputView.frameCount;

    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_relaxed);
    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;

    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        uint32_t gateMinimum = atomic_load_explicit(
            &bridge->outputGateMinimumBufferedFrames,
            memory_order_relaxed
        );
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
    float masterGain = bits_to_float(
        atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire)
    );

    latch_transition_command(bridge);
    latch_startup_fade_command(bridge);
    N60TransitionRampRuntime transitionRamp = bridge->transitionRuntime;
    N60StartupFadeRuntime startupFade = bridge->startupFadeRuntime;

    N60RenderKernelRenderContext renderContext = N60RenderKernelBeginRender(bridge->renderKernel);
    UInt32 renderedFrames = 0;
    uint32_t ringReadIndex = (uint32_t)(readIndex % bridge->capacityFrames);
    float *outputLeft = outputView.left;
    float *outputRight = outputView.right;
    for (UInt32 frameIndex = 0; frameIndex < framesToRead; ++frameIndex) {
        N60StereoFrame frame = bridge->frames[ringReadIndex];
        ringReadIndex += 1u;
        if (ringReadIndex == bridge->capacityFrames) ringReadIndex = 0u;
        N60StereoFrame processed;
        N60RenderKernelProcessStereoFrameInContext(
            bridge->renderKernel,
            &renderContext,
            frame.left,
            frame.right,
            &processed.left,
            &processed.right
        );

        float transitionGain = next_transition_gain(&transitionRamp);
        float gain = startup_fade_gain(&startupFade, masterGain) * transitionGain;
        *outputLeft = processed.left * gain;
        *outputRight = processed.right * gain;
        outputLeft += outputView.leftStride;
        outputRight += outputView.rightStride;
        renderedFrames += 1;
    }

    N60RenderKernelEndRender(bridge->renderKernel, &renderContext, renderedFrames);

    // Transition ramps live on the physical output timeline, not only on the
    // subset of frames for which captured program audio was available. Advance
    // through zero-filled output too so the control plane can receive a rendered
    // completion acknowledgement even during silence or a transient underrun.
    for (UInt32 frameIndex = framesToRead; frameIndex < frameCount; ++frameIndex) {
        (void)next_transition_gain(&transitionRamp);
        *outputLeft = 0.0f;
        *outputRight = 0.0f;
        outputLeft += outputView.leftStride;
        outputRight += outputView.rightStride;
    }

    bridge->transitionRuntime = transitionRamp;
    bridge->startupFadeRuntime = startupFade;
    publish_transition_runtime(bridge, &transitionRamp);

    atomic_store_explicit(&bridge->readIndex, readIndex + framesToRead, memory_order_release);
    atomic_fetch_add_explicit(&bridge->deliveredFrames, framesToRead, memory_order_relaxed);
    if (framesToRead < frameCount) {
        atomic_fetch_add_explicit(
            &bridge->underrunFrames,
            frameCount - framesToRead,
            memory_order_relaxed
        );
    }
    return noErr;
}
