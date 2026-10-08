#include "N60RealtimeAudioBridge.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static _Atomic bool gMeteringDemand = false;
static _Atomic bool gOutputVUMeterDemand = false;

#define N60_ANALYSIS_CAPTURE_MASK (N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES - 1u)
_Static_assert(
    (N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES & N60_ANALYSIS_CAPTURE_MASK) == 0u,
    "analysis capture capacity must remain a power of two"
);

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

typedef struct {
    N60SpeakerBusSplitterSnapshot snapshot;
    N60BiquadState lowerLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerLowMono[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState subPhaseAlignment;
} N60SpeakerBusSplitterRuntime;


struct N60RealtimeAudioBridge {
    uint32_t capacityFrames;
    N60StereoFrame *frames;
    N60AdaptiveSRC *adaptiveSRC;
    float *adaptiveCaptureScratch;
    float *adaptiveOutputScratch;
    N60RenderKernel *renderKernel;
    N60AudioUnitLiveRackProcessor audioUnitRack;
    float *audioUnitRackScratch;
    N60StereoPlaybackFrame *audioUnitRackPlaybackFrames;
    N60SameDeviceOutputMap sameDeviceOutputMap;
    N60SpeakerBusSplitterRuntime speakerBusSplitter;
    N60SpeakerDriverProcessingRuntime speakerDriverProcessing;

    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;

    _Atomic uint64_t captureCallbacks;
    _Atomic uint64_t outputCallbacks;
    N60FeedForwardOutputTiming feedForwardOutputTiming;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t deliveredFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t overrunFrames;
    _Atomic uint64_t unsupportedBufferLayouts;
    _Atomic uint64_t gatedOutputCallbacks;
    _Atomic uint64_t gatedOutputFrames;

    _Atomic uint32_t outputGainBits;

    // Output-only production VU telemetry. The callback accumulates in locals
    // and publishes one bounded atomic snapshot per callback, never per sample.
    _Atomic uint32_t outputVUPeakLeftBits;
    _Atomic uint32_t outputVUPeakRightBits;
    _Atomic uint32_t outputVURMSLeftBits;
    _Atomic uint32_t outputVURMSRightBits;
    _Atomic uint64_t outputVUOverRangeSamples;

    // Demand-gated Input/DSP-Output analysis capture. This is a bounded
    // single-producer/single-consumer ring: the audio callback never waits
    // and never overwrites unread data; the control plane drains it.
    N60AnalysisFrame *analysisFrames;
    _Atomic uint32_t analysisDemandMask;
    _Atomic uint64_t analysisWriteIndex;
    _Atomic uint64_t analysisReadIndex;
    _Atomic uint64_t analysisCapturedFrames;
    _Atomic uint64_t analysisDroppedFrames;

    // Independent PR89 rendered-playback reference ring. It has its own sole
    // consumer and therefore never contends with ProductionAnalysisWorker.
    N60AmbientPlaybackReferenceFrame *ambientReferenceFrames;
    _Atomic bool ambientReferenceDemand;
    _Atomic uint64_t ambientReferenceWriteIndex;
    _Atomic uint64_t ambientReferenceReadIndex;
    _Atomic uint64_t ambientReferenceCapturedFrames;
    _Atomic uint64_t ambientReferenceDroppedFrames;

    // Independent PR90 synthesized anti-noise reference. The control plane
    // uses this phase basis without competing with PR89's program-reference
    // consumer.
    N60ActiveQuietZoneReferenceFrame *activeQuietZoneReferenceFrames;
    _Atomic bool activeQuietZoneReferenceDemand;
    _Atomic uint64_t activeQuietZoneReferenceWriteIndex;
    _Atomic uint64_t activeQuietZoneReferenceReadIndex;
    _Atomic uint64_t activeQuietZoneReferenceCapturedFrames;
    _Atomic uint64_t activeQuietZoneReferenceDroppedFrames;

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

static bool make_same_device_output_frame_count(
    const AudioBufferList *bufferList,
    uint32_t requiredPhysicalChannels,
    UInt32 *frameCountOut
) {
    if (bufferList == NULL || frameCountOut == NULL || bufferList->mNumberBuffers == 0
        || requiredPhysicalChannels == 0) return false;
    uint64_t flattenedChannels = 0;
    UInt32 frameCount = UINT32_MAX;
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) return false;
        UInt32 bytesPerFrame = (UInt32)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0 || (buffer->mDataByteSize % bytesPerFrame) != 0) return false;
        UInt32 bufferFrames = buffer->mDataByteSize / bytesPerFrame;
        if (bufferFrames < frameCount) frameCount = bufferFrames;
        flattenedChannels += buffer->mNumberChannels;
    }
    if (flattenedChannels < requiredPhysicalChannels || frameCount == UINT32_MAX) return false;
    *frameCountOut = frameCount;
    return true;
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

static void publish_output_vu_meter(
    N60RealtimeAudioBridge *bridge,
    float peakLeft,
    float peakRight,
    double squareSumLeft,
    double squareSumRight,
    uint64_t overRangeSamples,
    uint32_t frameCount
) {
    if (bridge == NULL || frameCount == 0) return;
    float rmsLeft = (float)sqrt(squareSumLeft / (double)frameCount);
    float rmsRight = (float)sqrt(squareSumRight / (double)frameCount);
    atomic_store_explicit(&bridge->outputVUPeakLeftBits, float_to_bits(peakLeft), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVUPeakRightBits, float_to_bits(peakRight), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVURMSLeftBits, float_to_bits(rmsLeft), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVURMSRightBits, float_to_bits(rmsRight), memory_order_relaxed);
    atomic_fetch_add_explicit(&bridge->outputVUOverRangeSamples, overRangeSamples, memory_order_relaxed);
}

static float process_splitter_sections(
    const N60BiquadCoefficients *coefficients,
    N60BiquadState *states,
    uint32_t count,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < count; ++index) {
        output = N60BiquadProcessSample(coefficients[index], &states[index], output);
    }
    return output;
}

static void process_speaker_bus_splitter(
    N60SpeakerBusSplitterRuntime *runtime,
    float left,
    float right,
    N60SpeakerBusFrame *frame
) {
    *frame = N60SpeakerBusFrameMakeSilence();
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftFullRange, left);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightFullRange, right);
    if (!runtime->snapshot.enabled) return;

    const N60SpeakerBusSplitterSnapshot *snapshot = &runtime->snapshot;
    if (snapshot->mode == N60SpeakerCrossoverModeMainsSub) {
        float mainsLeft = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float mainsRight = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        float subMono = 0.5f * (left + right);
        subMono = process_splitter_sections(
            snapshot->lowerLowPass, runtime->lowerLowMono,
            snapshot->lowerSectionCount, subMono
        );
        if (snapshot->subPhaseAlignmentEnabled) {
            subMono = N60BiquadProcessSample(
                snapshot->subPhaseAlignmentAllPass,
                &runtime->subPhaseAlignment,
                subMono
            );
        }
        subMono *= snapshot->subGainLinear;
        if (snapshot->subPolarityInverted) subMono = -subMono;
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, mainsLeft);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, mainsRight);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusSubMono, subMono);
        return;
    }

    float lowLeft = process_splitter_sections(
        snapshot->lowerLowPass, runtime->lowerLowLeft,
        snapshot->lowerSectionCount, left
    );
    float lowRight = process_splitter_sections(
        snapshot->lowerLowPass, runtime->lowerLowRight,
        snapshot->lowerSectionCount, right
    );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftLow, lowLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightLow, lowRight);

    if (snapshot->mode == N60SpeakerCrossoverModeBiAmp) {
        float highLeft = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float highRight = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, highLeft);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, highRight);
        return;
    }

    float midLeft = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighLeft,
        snapshot->lowerSectionCount, left
    );
    float midRight = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighRight,
        snapshot->lowerSectionCount, right
    );
    midLeft = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowLeft,
        snapshot->upperSectionCount, midLeft
    );
    midRight = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowRight,
        snapshot->upperSectionCount, midRight
    );
    float highLeft = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighLeft,
        snapshot->upperSectionCount, left
    );
    float highRight = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighRight,
        snapshot->upperSectionCount, right
    );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftMid, midLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightMid, midRight);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, highLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, highRight);
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

    bridge->analysisFrames = calloc(N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES, sizeof(N60AnalysisFrame));
    if (bridge->analysisFrames == NULL) {
        free(bridge->frames);
        free(bridge);
        return NULL;
    }

    bridge->ambientReferenceFrames = calloc(
        N60_AMBIENT_REFERENCE_CAPACITY_FRAMES,
        sizeof(N60AmbientPlaybackReferenceFrame)
    );
    if (bridge->ambientReferenceFrames == NULL) {
        free(bridge->analysisFrames);
        free(bridge->frames);
        free(bridge);
        return NULL;
    }

    bridge->activeQuietZoneReferenceFrames = calloc(
        N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES,
        sizeof(N60ActiveQuietZoneReferenceFrame)
    );
    if (bridge->activeQuietZoneReferenceFrames == NULL) {
        free(bridge->ambientReferenceFrames);
        free(bridge->analysisFrames);
        free(bridge->frames);
        free(bridge);
        return NULL;
    }

    bridge->renderKernel = N60RenderKernelCreate();
    if (bridge->renderKernel == NULL) {
        free(bridge->activeQuietZoneReferenceFrames);
        free(bridge->ambientReferenceFrames);
        free(bridge->analysisFrames);
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
    N60AdaptiveSRCDestroy(bridge->adaptiveSRC);
    N60RenderKernelDestroy(bridge->renderKernel);
    free(bridge->adaptiveCaptureScratch);
    free(bridge->adaptiveOutputScratch);
    free(bridge->audioUnitRackScratch);
    free(bridge->audioUnitRackPlaybackFrames);
    free(bridge->activeQuietZoneReferenceFrames);
    free(bridge->ambientReferenceFrames);
    free(bridge->analysisFrames);
    free(bridge->frames);
    free(bridge);
}

void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return;

    atomic_store_explicit(&bridge->writeIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->readIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->captureCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputCallbacks, 0, memory_order_relaxed);
    N60FeedForwardOutputTimingReset(&bridge->feedForwardOutputTiming);
    atomic_store_explicit(&bridge->capturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->deliveredFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->underrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->overrunFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->unsupportedBufferLayouts, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputGainBits, float_to_bits(1.0f), memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVUPeakLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVUPeakRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVURMSLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVURMSRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputVUOverRangeSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->analysisDemandMask, N60_ANALYSIS_DEMAND_NONE, memory_order_release);
    atomic_store_explicit(&bridge->analysisWriteIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->analysisReadIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->analysisCapturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->analysisDroppedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->ambientReferenceDemand, false, memory_order_release);
    atomic_store_explicit(&bridge->ambientReferenceWriteIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->ambientReferenceReadIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->ambientReferenceCapturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->ambientReferenceDroppedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->activeQuietZoneReferenceDemand, false, memory_order_release);
    atomic_store_explicit(&bridge->activeQuietZoneReferenceWriteIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->activeQuietZoneReferenceReadIndex, 0, memory_order_release);
    atomic_store_explicit(&bridge->activeQuietZoneReferenceCapturedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&bridge->activeQuietZoneReferenceDroppedFrames, 0, memory_order_relaxed);

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

    if (bridge->adaptiveSRC != NULL) {
        N60AdaptiveSRCReset(bridge->adaptiveSRC);
    }
    N60RenderKernelReset(bridge->renderKernel);
}

bool N60RealtimeAudioBridgeConfigureAdaptiveSampleRate(
    N60RealtimeAudioBridge *bridge,
    double inputSampleRate,
    double outputSampleRate,
    uint32_t targetBufferedInputFrames
) {
    if (bridge == NULL || bridge->adaptiveSRC != NULL
        || !isfinite(inputSampleRate) || inputSampleRate <= 0.0
        || !isfinite(outputSampleRate) || outputSampleRate <= 0.0) {
        return false;
    }
    if (fabs(inputSampleRate - outputSampleRate) < 0.5) {
        return true;
    }

    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        inputSampleRate,
        outputSampleRate,
        2u,
        bridge->capacityFrames,
        targetBufferedInputFrames
    );
    N60AdaptiveSRC *adaptiveSRC = N60AdaptiveSRCCreate(configuration);
    if (adaptiveSRC == NULL) return false;

    size_t scratchSamples = (size_t)bridge->capacityFrames * 2u;
    float *captureScratch = (float *)calloc(scratchSamples, sizeof(float));
    float *outputScratch = (float *)calloc(scratchSamples, sizeof(float));
    if (captureScratch == NULL || outputScratch == NULL) {
        free(captureScratch);
        free(outputScratch);
        N60AdaptiveSRCDestroy(adaptiveSRC);
        return false;
    }

    bridge->adaptiveSRC = adaptiveSRC;
    bridge->adaptiveCaptureScratch = captureScratch;
    bridge->adaptiveOutputScratch = outputScratch;
    return true;
}

bool N60RealtimeAudioBridgeAdaptiveSampleRateEnabled(
    const N60RealtimeAudioBridge *bridge
) {
    return bridge != NULL && bridge->adaptiveSRC != NULL;
}

bool N60RealtimeAudioBridgeConfigureAudioUnitRack(
    N60RealtimeAudioBridge *bridge,
    N60AudioUnitLiveRackProcessor processor
) {
    if (bridge == NULL
        || bridge->audioUnitRack.context != NULL
        || !N60AudioUnitLiveRackProcessorIsValid(&processor)
        || processor.channelCount != 2u
        || processor.maximumFramesPerSlice > bridge->capacityFrames) {
        return false;
    }

    float *scratch = (float *)calloc(
        (size_t)bridge->capacityFrames * 2u,
        sizeof(float)
    );
    N60StereoPlaybackFrame *playbackFrames =
        (N60StereoPlaybackFrame *)calloc(
            bridge->capacityFrames,
            sizeof(N60StereoPlaybackFrame)
        );
    if (scratch == NULL || playbackFrames == NULL) {
        free(scratch);
        free(playbackFrames);
        return false;
    }

    bridge->audioUnitRack = processor;
    bridge->audioUnitRackScratch = scratch;
    bridge->audioUnitRackPlaybackFrames = playbackFrames;
    return true;
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

void N60RealtimeAudioBridgeSetMeteringDemand(bool enabled) {
    atomic_store_explicit(&gMeteringDemand, enabled, memory_order_release);
}

bool N60RealtimeAudioBridgeMeteringDemand(void) {
    return atomic_load_explicit(&gMeteringDemand, memory_order_acquire);
}

void N60RealtimeAudioBridgeSetOutputVUMeterDemand(bool enabled) {
    atomic_store_explicit(&gOutputVUMeterDemand, enabled, memory_order_release);
}

bool N60RealtimeAudioBridgeOutputVUMeterDemand(void) {
    return atomic_load_explicit(&gOutputVUMeterDemand, memory_order_acquire);
}

N60OutputVUMeterSnapshot N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    N60OutputVUMeterSnapshot snapshot = {0};
    if (bridge == NULL) return snapshot;
    snapshot.enabled = N60RealtimeAudioBridgeOutputVUMeterDemand();
    snapshot.peakLeft = bits_to_float(atomic_load_explicit(&bridge->outputVUPeakLeftBits, memory_order_relaxed));
    snapshot.peakRight = bits_to_float(atomic_load_explicit(&bridge->outputVUPeakRightBits, memory_order_relaxed));
    snapshot.rmsLeft = bits_to_float(atomic_load_explicit(&bridge->outputVURMSLeftBits, memory_order_relaxed));
    snapshot.rmsRight = bits_to_float(atomic_load_explicit(&bridge->outputVURMSRightBits, memory_order_relaxed));
    snapshot.overRangeSamples = atomic_load_explicit(&bridge->outputVUOverRangeSamples, memory_order_relaxed);
    return snapshot;
}

void N60RealtimeAudioBridgeSetAnalysisDemand(
    N60RealtimeAudioBridge *bridge,
    uint32_t demandMask
) {
    if (bridge == NULL) return;
    uint32_t sanitized = demandMask & N60_ANALYSIS_DEMAND_ALL;
    atomic_store_explicit(&bridge->analysisDemandMask, sanitized, memory_order_release);
}

void N60RealtimeAudioBridgeDiscardAnalysisFrames(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return;
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->analysisWriteIndex, memory_order_acquire
    );
    atomic_store_explicit(&bridge->analysisReadIndex, writeIndex, memory_order_release);
}

uint32_t N60RealtimeAudioBridgeAnalysisDemand(const N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return N60_ANALYSIS_DEMAND_NONE;
    return atomic_load_explicit(&bridge->analysisDemandMask, memory_order_acquire);
}

N60AnalysisCaptureSnapshot N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    N60AnalysisCaptureSnapshot snapshot = {0};
    if (bridge == NULL) return snapshot;
    snapshot.demandMask = N60RealtimeAudioBridgeAnalysisDemand(bridge);
    uint64_t readIndex = atomic_load_explicit(&bridge->analysisReadIndex, memory_order_acquire);
    uint64_t writeIndex = atomic_load_explicit(&bridge->analysisWriteIndex, memory_order_acquire);
    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (available > N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES) {
        available = N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES;
    }
    snapshot.availableFrames = (uint32_t)available;
    snapshot.capturedFrames = atomic_load_explicit(&bridge->analysisCapturedFrames, memory_order_relaxed);
    snapshot.droppedFrames = atomic_load_explicit(&bridge->analysisDroppedFrames, memory_order_relaxed);
    return snapshot;
}

uint32_t N60RealtimeAudioBridgeReadAnalysisFrames(
    N60RealtimeAudioBridge *bridge,
    N60AnalysisFrame *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0) return 0;
    uint64_t readIndex = atomic_load_explicit(&bridge->analysisReadIndex, memory_order_relaxed);
    uint64_t writeIndex = atomic_load_explicit(&bridge->analysisWriteIndex, memory_order_acquire);
    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    uint32_t framesToRead = capacityFrames < available ? capacityFrames : (uint32_t)available;
    if (framesToRead == 0) return 0;
    uint32_t ringIndex = (uint32_t)readIndex & N60_ANALYSIS_CAPTURE_MASK;
    uint32_t first = framesToRead;
    uint32_t untilWrap = N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES - ringIndex;
    if (first > untilWrap) first = untilWrap;
    memcpy(destination, bridge->analysisFrames + ringIndex, first * sizeof(N60AnalysisFrame));
    if (first < framesToRead) {
        memcpy(
            destination + first,
            bridge->analysisFrames,
            (framesToRead - first) * sizeof(N60AnalysisFrame)
        );
    }
    atomic_store_explicit(&bridge->analysisReadIndex, readIndex + framesToRead, memory_order_release);
    return framesToRead;
}

void N60RealtimeAudioBridgeSetAmbientReferenceDemand(
    N60RealtimeAudioBridge *bridge,
    bool enabled
) {
    if (bridge == NULL) return;
    bool previous = atomic_exchange_explicit(
        &bridge->ambientReferenceDemand,
        enabled,
        memory_order_acq_rel
    );
    if (previous != enabled) {
        uint64_t writeIndex = atomic_load_explicit(
            &bridge->ambientReferenceWriteIndex,
            memory_order_acquire
        );
        atomic_store_explicit(
            &bridge->ambientReferenceReadIndex,
            writeIndex,
            memory_order_release
        );
    }
}

bool N60RealtimeAudioBridgeAmbientReferenceDemand(
    const N60RealtimeAudioBridge *bridge
) {
    return bridge != NULL
        && atomic_load_explicit(
            &bridge->ambientReferenceDemand,
            memory_order_acquire
        );
}

void N60RealtimeAudioBridgeDiscardAmbientReferenceFrames(
    N60RealtimeAudioBridge *bridge
) {
    if (bridge == NULL) return;
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->ambientReferenceWriteIndex,
        memory_order_acquire
    );
    atomic_store_explicit(
        &bridge->ambientReferenceReadIndex,
        writeIndex,
        memory_order_release
    );
}

N60AmbientPlaybackReferenceSnapshot
N60RealtimeAudioBridgeGetAmbientReferenceSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    N60AmbientPlaybackReferenceSnapshot snapshot = {0};
    if (bridge == NULL) return snapshot;

    snapshot.enabled = N60RealtimeAudioBridgeAmbientReferenceDemand(
        bridge
    );
    uint64_t readIndex = atomic_load_explicit(
        &bridge->ambientReferenceReadIndex,
        memory_order_acquire
    );
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->ambientReferenceWriteIndex,
        memory_order_acquire
    );
    uint64_t available =
        writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (available > N60_AMBIENT_REFERENCE_CAPACITY_FRAMES) {
        available = N60_AMBIENT_REFERENCE_CAPACITY_FRAMES;
    }
    snapshot.availableFrames = (uint32_t)available;
    snapshot.capturedFrames = atomic_load_explicit(
        &bridge->ambientReferenceCapturedFrames,
        memory_order_relaxed
    );
    snapshot.droppedFrames = atomic_load_explicit(
        &bridge->ambientReferenceDroppedFrames,
        memory_order_relaxed
    );
    return snapshot;
}

uint32_t N60RealtimeAudioBridgeReadAmbientReferenceFrames(
    N60RealtimeAudioBridge *bridge,
    N60AmbientPlaybackReferenceFrame *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0) {
        return 0;
    }
    uint64_t readIndex = atomic_load_explicit(
        &bridge->ambientReferenceReadIndex,
        memory_order_relaxed
    );
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->ambientReferenceWriteIndex,
        memory_order_acquire
    );
    uint64_t available =
        writeIndex >= readIndex ? writeIndex - readIndex : 0;
    uint32_t framesToRead =
        capacityFrames < available
            ? capacityFrames
            : (uint32_t)available;
    if (framesToRead == 0) return 0;

    uint32_t ringIndex =
        (uint32_t)readIndex
        & (N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - 1u);
    uint32_t first = framesToRead;
    uint32_t untilWrap =
        N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - ringIndex;
    if (first > untilWrap) first = untilWrap;
    memcpy(
        destination,
        bridge->ambientReferenceFrames + ringIndex,
        first * sizeof(N60AmbientPlaybackReferenceFrame)
    );
    if (first < framesToRead) {
        memcpy(
            destination + first,
            bridge->ambientReferenceFrames,
            (framesToRead - first)
                * sizeof(N60AmbientPlaybackReferenceFrame)
        );
    }
    atomic_store_explicit(
        &bridge->ambientReferenceReadIndex,
        readIndex + framesToRead,
        memory_order_release
    );
    return framesToRead;
}

void N60RealtimeAudioBridgeSetActiveQuietZoneReferenceDemand(
    N60RealtimeAudioBridge *bridge,
    bool enabled
) {
    if (bridge == NULL) return;
    bool previous = atomic_exchange_explicit(
        &bridge->activeQuietZoneReferenceDemand,
        enabled,
        memory_order_acq_rel
    );
    if (previous != enabled) {
        uint64_t writeIndex = atomic_load_explicit(
            &bridge->activeQuietZoneReferenceWriteIndex,
            memory_order_acquire
        );
        atomic_store_explicit(
            &bridge->activeQuietZoneReferenceReadIndex,
            writeIndex,
            memory_order_release
        );
    }
}

bool N60RealtimeAudioBridgeActiveQuietZoneReferenceDemand(
    const N60RealtimeAudioBridge *bridge
) {
    return bridge != NULL
        && atomic_load_explicit(
            &bridge->activeQuietZoneReferenceDemand,
            memory_order_acquire
        );
}

void N60RealtimeAudioBridgeDiscardActiveQuietZoneReferenceFrames(
    N60RealtimeAudioBridge *bridge
) {
    if (bridge == NULL) return;
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceWriteIndex,
        memory_order_acquire
    );
    atomic_store_explicit(
        &bridge->activeQuietZoneReferenceReadIndex,
        writeIndex,
        memory_order_release
    );
}

N60ActiveQuietZoneReferenceSnapshot
N60RealtimeAudioBridgeGetActiveQuietZoneReferenceSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    N60ActiveQuietZoneReferenceSnapshot snapshot = {0};
    if (bridge == NULL) return snapshot;
    snapshot.enabled =
        N60RealtimeAudioBridgeActiveQuietZoneReferenceDemand(
            bridge
        );
    uint64_t readIndex = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceReadIndex,
        memory_order_acquire
    );
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceWriteIndex,
        memory_order_acquire
    );
    uint64_t available =
        writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (available
        > N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES) {
        available =
            N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES;
    }
    snapshot.availableFrames = (uint32_t)available;
    snapshot.capturedFrames = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceCapturedFrames,
        memory_order_relaxed
    );
    snapshot.droppedFrames = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceDroppedFrames,
        memory_order_relaxed
    );
    return snapshot;
}

uint32_t N60RealtimeAudioBridgeReadActiveQuietZoneReferenceFrames(
    N60RealtimeAudioBridge *bridge,
    N60ActiveQuietZoneReferenceFrame *destination,
    uint32_t capacityFrames
) {
    if (bridge == NULL || destination == NULL || capacityFrames == 0) {
        return 0;
    }
    uint64_t readIndex = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceReadIndex,
        memory_order_relaxed
    );
    uint64_t writeIndex = atomic_load_explicit(
        &bridge->activeQuietZoneReferenceWriteIndex,
        memory_order_acquire
    );
    uint64_t available =
        writeIndex >= readIndex ? writeIndex - readIndex : 0;
    uint32_t framesToRead =
        capacityFrames < available
            ? capacityFrames
            : (uint32_t)available;
    if (framesToRead == 0) return 0;

    uint32_t ringIndex =
        (uint32_t)readIndex
        & (
            N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
            - 1u
        );
    uint32_t first = framesToRead;
    uint32_t untilWrap =
        N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
        - ringIndex;
    if (first > untilWrap) first = untilWrap;
    memcpy(
        destination,
        bridge->activeQuietZoneReferenceFrames + ringIndex,
        first * sizeof(N60ActiveQuietZoneReferenceFrame)
    );
    if (first < framesToRead) {
        memcpy(
            destination + first,
            bridge->activeQuietZoneReferenceFrames,
            (framesToRead - first)
                * sizeof(N60ActiveQuietZoneReferenceFrame)
        );
    }
    atomic_store_explicit(
        &bridge->activeQuietZoneReferenceReadIndex,
        readIndex + framesToRead,
        memory_order_release
    );
    return framesToRead;
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
    snapshot.meteringEnabled = N60RealtimeAudioBridgeMeteringDemand();
    return N60RenderKernelPublishSnapshot(bridge->renderKernel, snapshot);
}

bool N60RealtimeAudioBridgeConfigureHeadphoneDSP(
    N60RealtimeAudioBridge *bridge,
    N60HeadphoneDSPSnapshot snapshot
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelConfigureHeadphoneDSP(bridge->renderKernel, &snapshot);
}

void N60RealtimeAudioBridgeClearHeadphoneDSP(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL || bridge->renderKernel == NULL) return;
    N60RenderKernelClearHeadphoneDSP(bridge->renderKernel);
}

N60FeedForwardOutputTimingSnapshot
N60RealtimeAudioBridgeGetFeedForwardOutputTimingSnapshot(
    const N60RealtimeAudioBridge *bridge
) {
    if (bridge == NULL) return (N60FeedForwardOutputTimingSnapshot){0};
    return N60FeedForwardOutputTimingRead(&bridge->feedForwardOutputTiming);
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
    snapshot.outputVUMeter = N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(bridge);
    snapshot.adaptiveSampleRateEnabled = bridge->adaptiveSRC != NULL;
    if (bridge->adaptiveSRC != NULL) {
        snapshot.adaptiveSampleRate = N60AdaptiveSRCGetSnapshot(bridge->adaptiveSRC);
        snapshot.bufferedFrames = snapshot.adaptiveSampleRate.bufferedFrames;
        return snapshot;
    }

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
    N60RenderKernelDiagnostics diagnostics = N60RenderKernelGetDiagnostics(bridge->renderKernel);
    N60OutputVUMeterSnapshot vu = N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(bridge);
    if (vu.enabled) {
        diagnostics.outputMeter.peakLeft = vu.peakLeft;
        diagnostics.outputMeter.peakRight = vu.peakRight;
        diagnostics.outputMeter.rmsLeft = vu.rmsLeft;
        diagnostics.outputMeter.rmsRight = vu.rmsRight;
        diagnostics.outputMeter.overRangeSamples = vu.overRangeSamples;
    }
    return diagnostics;
}

static bool speaker_bus_is_valid(N60SpeakerOutputBus bus) {
    return bus >= N60SpeakerOutputBusLeftFullRange && bus < N60SpeakerOutputBusCount;
}

N60SpeakerBusFrame N60SpeakerBusFrameMakeSilence(void) {
    N60SpeakerBusFrame frame = {0};
    return frame;
}

bool N60SpeakerBusFrameSet(
    N60SpeakerBusFrame *frame,
    N60SpeakerOutputBus bus,
    float value
) {
    if (frame == NULL || !speaker_bus_is_valid(bus) || !isfinite(value)) return false;
    frame->values[(uint32_t)bus] = value;
    return true;
}

float N60SpeakerBusFrameGet(
    const N60SpeakerBusFrame *frame,
    N60SpeakerOutputBus bus
) {
    if (frame == NULL || !speaker_bus_is_valid(bus)) return 0.0f;
    return frame->values[(uint32_t)bus];
}

bool N60SameDeviceOutputMapCompile(
    uint32_t physicalChannelCount,
    const N60SpeakerOutputRouteDescriptor *routes,
    uint32_t routeCount,
    N60SameDeviceOutputMap *mapOut
) {
    if (mapOut == NULL) return false;
    memset(mapOut, 0, sizeof(*mapOut));
    if (physicalChannelCount == 0
        || routes == NULL
        || routeCount < 2u
        || routeCount > N60_SPEAKER_OUTPUT_MAX_ROUTES) {
        return false;
    }

    for (uint32_t index = 0; index < routeCount; ++index) {
        N60SpeakerOutputRouteDescriptor route = routes[index];
        if (!speaker_bus_is_valid(route.bus)
            || route.physicalChannelIndex >= physicalChannelCount) {
            return false;
        }
        for (uint32_t previous = 0; previous < index; ++previous) {
            if (routes[previous].physicalChannelIndex == route.physicalChannelIndex) {
                return false;
            }
        }
        mapOut->routes[index] = route;
    }
    mapOut->physicalChannelCount = physicalChannelCount;
    mapOut->routeCount = routeCount;
    mapOut->valid = true;
    return true;
}

bool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(
    N60RealtimeAudioBridge *bridge,
    N60SameDeviceOutputMap map
) {
    if (bridge == NULL || !map.valid || map.routeCount < 2u
        || map.routeCount > N60_SPEAKER_OUTPUT_MAX_ROUTES
        || map.physicalChannelCount == 0) {
        return false;
    }
    bridge->sameDeviceOutputMap = map;
    return true;
}

bool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
    N60RealtimeAudioBridge *bridge,
    N60SpeakerBusSplitterSnapshot snapshot
) {
    if (bridge == NULL || !snapshot.enabled) return false;
    memset(&bridge->speakerBusSplitter, 0, sizeof(bridge->speakerBusSplitter));
    bridge->speakerBusSplitter.snapshot = snapshot;
    return true;
}

bool N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
    N60RealtimeAudioBridge *bridge,
    N60SpeakerDriverProcessingSnapshot snapshot
) {
    if (bridge == NULL) return false;
    return N60SpeakerDriverProcessingRuntimeConfigure(
        &bridge->speakerDriverProcessing, snapshot
    );
}

bool N60SameDeviceOutputMapValueForChannel(
    const N60SameDeviceOutputMap *map,
    const N60SpeakerBusFrame *frame,
    uint32_t physicalChannelIndex,
    float *valueOut
) {
    if (valueOut == NULL) return false;
    *valueOut = 0.0f;
    if (map == NULL || frame == NULL || !map->valid
        || physicalChannelIndex >= map->physicalChannelCount) {
        return false;
    }
    for (uint32_t index = 0; index < map->routeCount; ++index) {
        if (map->routes[index].physicalChannelIndex == physicalChannelIndex) {
            *valueOut = N60SpeakerBusFrameGet(frame, map->routes[index].bus);
            return true;
        }
    }
    return true;
}

static bool output_buffer_frame_is_addressable(
    const AudioBuffer *buffer,
    uint32_t frameIndex
) {
    if (buffer == NULL || buffer->mData == NULL || buffer->mNumberChannels == 0) return false;
    uint64_t bytesPerFrame = (uint64_t)sizeof(float) * buffer->mNumberChannels;
    uint64_t requiredBytes = ((uint64_t)frameIndex + 1u) * bytesPerFrame;
    return requiredBytes <= buffer->mDataByteSize;
}

bool N60SameDeviceOutputMapWriteFrame(
    const N60SameDeviceOutputMap *map,
    const N60SpeakerBusFrame *frame,
    AudioBufferList *outputData,
    uint32_t frameIndex
) {
    if (map == NULL || frame == NULL || outputData == NULL || !map->valid
        || outputData->mNumberBuffers == 0) {
        return false;
    }

    uint64_t flattenedChannelCount = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (!output_buffer_frame_is_addressable(buffer, frameIndex)) return false;
        flattenedChannelCount += buffer->mNumberChannels;
    }
    if (flattenedChannelCount < map->physicalChannelCount) return false;

    // Silence every channel represented by this callback frame before routing.
    // This prevents stale samples on unassigned hardware channels.
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        float *samples = (float *)buffer->mData;
        uint64_t base = (uint64_t)frameIndex * buffer->mNumberChannels;
        for (UInt32 localChannel = 0; localChannel < buffer->mNumberChannels; ++localChannel) {
            samples[base + localChannel] = 0.0f;
        }
    }

    for (uint32_t routeIndex = 0; routeIndex < map->routeCount; ++routeIndex) {
        N60SpeakerOutputRouteDescriptor route = map->routes[routeIndex];
        uint32_t remainingChannel = route.physicalChannelIndex;
        for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
            AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
            if (remainingChannel < buffer->mNumberChannels) {
                float *samples = (float *)buffer->mData;
                uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remainingChannel;
                samples[sampleIndex] = N60SpeakerBusFrameGet(frame, route.bus);
                break;
            }
            remainingChannel -= buffer->mNumberChannels;
        }
    }
    return true;
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
    N60RealtimeAudioBridge *bridge = (N60RealtimeAudioBridge *)inClientData;
    if (bridge == NULL || inInputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1, memory_order_relaxed);

    N60InputBufferView inputView = {0};
    if (!make_input_buffer_view(inInputData, &inputView)) {
        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
        return noErr;
    }
    UInt32 frameCount = inputView.frameCount;
    if (bridge->adaptiveSRC != NULL) {
        UInt32 framesToStage = frameCount < bridge->capacityFrames
            ? frameCount
            : bridge->capacityFrames;
        const float *inputLeft = inputView.left;
        const float *inputRight = inputView.right;
        for (UInt32 frameIndex = 0; frameIndex < framesToStage; ++frameIndex) {
            size_t base = (size_t)frameIndex * 2u;
            bridge->adaptiveCaptureScratch[base] = *inputLeft;
            bridge->adaptiveCaptureScratch[base + 1u] = *inputRight;
            inputLeft += inputView.leftStride;
            inputRight += inputView.rightStride;
        }
        UInt32 accepted = N60AdaptiveSRCPushInterleaved(
            bridge->adaptiveSRC,
            bridge->adaptiveCaptureScratch,
            framesToStage
        );
        atomic_fetch_add_explicit(&bridge->capturedFrames, accepted, memory_order_relaxed);
        if (accepted < frameCount) {
            atomic_fetch_add_explicit(
                &bridge->overrunFrames,
                frameCount - accepted,
                memory_order_relaxed
            );
        }
        return noErr;
    }

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
    N60RealtimeAudioBridge *bridge = (N60RealtimeAudioBridge *)inClientData;
    if (bridge == NULL || outOutputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1, memory_order_relaxed);

    bool sameDeviceMultiOutput = bridge->sameDeviceOutputMap.valid;
    N60OutputBufferView outputView = {0};
    UInt32 frameCount = 0;
    if (sameDeviceMultiOutput) {
        if (!make_same_device_output_frame_count(
            outOutputData,
            bridge->sameDeviceOutputMap.physicalChannelCount,
            &frameCount
        )) {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
            return noErr;
        }
    } else {
        if (!make_output_buffer_view(outOutputData, &outputView)) {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);
            return noErr;
        }
        frameCount = outputView.frameCount;
    }

    // Passive timing witness only: no modification to program audio, DSP,
    // graph scheduling, anti-noise generation or output routing.
    N60FeedForwardOutputTimingObserve(
        &bridge->feedForwardOutputTiming, inOutputTime, frameCount
    );

    bool adaptiveSampleRate = bridge->adaptiveSRC != NULL;
    uint64_t readIndex = atomic_load_explicit(&bridge->readIndex, memory_order_relaxed);
    uint64_t writeIndex = atomic_load_explicit(&bridge->writeIndex, memory_order_acquire);
    uint64_t available = 0u;
    if (adaptiveSampleRate) {
        available = N60AdaptiveSRCGetSnapshot(bridge->adaptiveSRC).bufferedFrames;
    } else {
        available = writeIndex >= readIndex ? writeIndex - readIndex : 0u;
    }

    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        uint32_t gateMinimum = atomic_load_explicit(
            &bridge->outputGateMinimumBufferedFrames,
            memory_order_relaxed
        );
        bool gateReady = adaptiveSampleRate
            ? available >= gateMinimum
            : (available >= gateMinimum && available >= frameCount);
        if (gateReady) {
            atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
        } else {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
            return noErr;
        }
    }

    UInt32 framesToRead = adaptiveSampleRate
        ? N60AdaptiveSRCPullInterleaved(
            bridge->adaptiveSRC,
            bridge->adaptiveOutputScratch,
            frameCount
        )
        : (frameCount < available ? frameCount : (UInt32)available);

    if (adaptiveSampleRate && framesToRead < frameCount) {
        // A partial adaptive block means the FIR no longer has enough future
        // input support. Fail the entire callback closed, re-arm the startup
        // gate, and require a full input-domain re-prime before emitting audio
        // again. Discarding the partial pull is preferable to leaking a
        // discontinuous half-block into the production DSP graph.
        zero_output(outOutputData);
        N60AdaptiveSRCRelockConsumer(bridge->adaptiveSRC);
        atomic_store_explicit(&bridge->outputGateOpen, false, memory_order_release);
        uint32_t fadeFrames = atomic_load_explicit(
            &bridge->startupFadeFramesTotal,
            memory_order_relaxed
        );
        bridge->startupFadeRuntime.totalFrames = fadeFrames;
        bridge->startupFadeRuntime.remainingFrames = fadeFrames;
        atomic_fetch_add_explicit(
            &bridge->underrunFrames,
            frameCount - framesToRead,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
        return noErr;
    }

    float masterGain = bits_to_float(
        atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire)
    );
    bool outputVUMeterEnabled = N60RealtimeAudioBridgeOutputVUMeterDemand();
    uint32_t analysisDemand = atomic_load_explicit(&bridge->analysisDemandMask, memory_order_acquire);
    uint64_t analysisWriteIndex = 0;
    uint32_t analysisFramesToWrite = 0;
    uint32_t analysisRingIndex = 0;
    if (analysisDemand != N60_ANALYSIS_DEMAND_NONE) {
        analysisWriteIndex = atomic_load_explicit(&bridge->analysisWriteIndex, memory_order_relaxed);
        uint64_t analysisReadIndex = atomic_load_explicit(&bridge->analysisReadIndex, memory_order_acquire);
        uint64_t used = analysisWriteIndex >= analysisReadIndex
            ? analysisWriteIndex - analysisReadIndex
            : N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES;
        uint64_t freeFrames = used < N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES
            ? N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES - used
            : 0;
        analysisFramesToWrite = framesToRead < freeFrames ? framesToRead : (uint32_t)freeFrames;
        analysisRingIndex = (uint32_t)analysisWriteIndex & N60_ANALYSIS_CAPTURE_MASK;
    }

    bool ambientReferenceDemand = atomic_load_explicit(
        &bridge->ambientReferenceDemand,
        memory_order_acquire
    );
    uint64_t ambientReferenceWriteIndex = 0;
    uint32_t ambientReferenceFramesToWrite = 0;
    uint32_t ambientReferenceRingIndex = 0;
    if (ambientReferenceDemand) {
        ambientReferenceWriteIndex = atomic_load_explicit(
            &bridge->ambientReferenceWriteIndex,
            memory_order_relaxed
        );
        uint64_t ambientReferenceReadIndex = atomic_load_explicit(
            &bridge->ambientReferenceReadIndex,
            memory_order_acquire
        );
        uint64_t used =
            ambientReferenceWriteIndex >= ambientReferenceReadIndex
                ? ambientReferenceWriteIndex
                    - ambientReferenceReadIndex
                : N60_AMBIENT_REFERENCE_CAPACITY_FRAMES;
        uint64_t freeFrames =
            used < N60_AMBIENT_REFERENCE_CAPACITY_FRAMES
                ? N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - used
                : 0;
        ambientReferenceFramesToWrite =
            framesToRead < freeFrames
                ? framesToRead
                : (uint32_t)freeFrames;
        ambientReferenceRingIndex =
            (uint32_t)ambientReferenceWriteIndex
            & (N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - 1u);
    }

    bool activeQuietZoneReferenceDemand =
        atomic_load_explicit(
            &bridge->activeQuietZoneReferenceDemand,
            memory_order_acquire
        );
    uint64_t activeQuietZoneReferenceWriteIndex = 0;
    uint32_t activeQuietZoneReferenceFramesToWrite = 0;
    uint32_t activeQuietZoneReferenceRingIndex = 0;
    if (activeQuietZoneReferenceDemand) {
        activeQuietZoneReferenceWriteIndex =
            atomic_load_explicit(
                &bridge->activeQuietZoneReferenceWriteIndex,
                memory_order_relaxed
            );
        uint64_t activeQuietZoneReferenceReadIndex =
            atomic_load_explicit(
                &bridge->activeQuietZoneReferenceReadIndex,
                memory_order_acquire
            );
        uint64_t used =
            activeQuietZoneReferenceWriteIndex
                    >= activeQuietZoneReferenceReadIndex
                ? activeQuietZoneReferenceWriteIndex
                    - activeQuietZoneReferenceReadIndex
                : N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES;
        uint64_t freeFrames =
            used < N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
                ? N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
                    - used
                : 0;
        activeQuietZoneReferenceFramesToWrite =
            framesToRead < freeFrames
                ? framesToRead
                : (uint32_t)freeFrames;
        activeQuietZoneReferenceRingIndex =
            (uint32_t)activeQuietZoneReferenceWriteIndex
            & (
                N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
                - 1u
            );
    }
    float outputVUPeakLeft = 0.0f;
    float outputVUPeakRight = 0.0f;
    double outputVUSquareSumLeft = 0.0;
    double outputVUSquareSumRight = 0.0;
    uint64_t outputVUOverRangeSamples = 0;

    latch_transition_command(bridge);
    latch_startup_fade_command(bridge);
    N60TransitionRampRuntime transitionRamp = bridge->transitionRuntime;
    N60StartupFadeRuntime startupFade = bridge->startupFadeRuntime;

    N60RenderKernelRenderContext renderContext =
        N60RenderKernelBeginRender(bridge->renderKernel);
    UInt32 renderedFrames = 0;
    uint32_t ringReadIndex =
        (uint32_t)(readIndex % bridge->capacityFrames);
    float *outputLeft = outputView.left;
    float *outputRight = outputView.right;
    const bool rackConfigured =
        N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack);
    const double outputSampleTime =
        inOutputTime != NULL
        && (inOutputTime->mFlags & kAudioTimeStampSampleTimeValid) != 0
            ? inOutputTime->mSampleTime
            : 0.0;

    if (rackConfigured) {
        if (framesToRead > bridge->audioUnitRack.maximumFramesPerSlice
            || bridge->audioUnitRackScratch == NULL
            || bridge->audioUnitRackPlaybackFrames == NULL) {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->unsupportedBufferLayouts,
                1u,
                memory_order_relaxed
            );
            N60RenderKernelEndRender(
                bridge->renderKernel,
                &renderContext,
                0u
            );
            return noErr;
        }

        for (UInt32 frameIndex = 0;
             frameIndex < framesToRead;
             ++frameIndex) {
            N60StereoFrame frame;
            if (adaptiveSampleRate) {
                const size_t base = (size_t)frameIndex * 2u;
                frame = (N60StereoFrame){
                    bridge->adaptiveOutputScratch[base],
                    bridge->adaptiveOutputScratch[base + 1u]
                };
            } else {
                frame = bridge->frames[ringReadIndex];
                ringReadIndex += 1u;
                if (ringReadIndex == bridge->capacityFrames) {
                    ringReadIndex = 0u;
                }
            }

            N60StereoPlaybackFrame *playback =
                &bridge->audioUnitRackPlaybackFrames[frameIndex];
            N60RenderKernelProcessStereoPlaybackFrameInContext(
                bridge->renderKernel,
                &renderContext,
                frame.left,
                frame.right,
                playback
            );
            const size_t base = (size_t)frameIndex * 2u;
            bridge->audioUnitRackScratch[base] = playback->left;
            bridge->audioUnitRackScratch[base + 1u] = playback->right;
        }

        const bool processingActive =
            framesToRead > 0u
            && bridge->audioUnitRackPlaybackFrames[0].processingActive;
        if (processingActive
            && !N60AudioUnitLiveRackProcess(
                &bridge->audioUnitRack,
                bridge->audioUnitRackScratch,
                bridge->audioUnitRackScratch,
                framesToRead,
                2u,
                outputSampleTime)) {
            zero_output(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->unsupportedBufferLayouts,
                1u,
                memory_order_relaxed
            );
            N60RenderKernelEndRender(
                bridge->renderKernel,
                &renderContext,
                0u
            );
            return noErr;
        }

        for (UInt32 frameIndex = 0;
             frameIndex < framesToRead;
             ++frameIndex) {
            const N60StereoPlaybackFrame *playback =
                &bridge->audioUnitRackPlaybackFrames[frameIndex];
            const size_t base = (size_t)frameIndex * 2u;
            N60StereoFrame processed = {0};
            N60RenderKernelProcessStereoSystemFrameInContext(
                bridge->renderKernel,
                &renderContext,
                playback,
                processingActive
                    ? bridge->audioUnitRackScratch[base]
                    : playback->left,
                processingActive
                    ? bridge->audioUnitRackScratch[base + 1u]
                    : playback->right,
                &processed.left,
                &processed.right
            );

            if (frameIndex < analysisFramesToWrite) {
                bridge->analysisFrames[analysisRingIndex] =
                    (N60AnalysisFrame){
                        playback->sourceLeft,
                        playback->sourceRight,
                        processed.left,
                        processed.right
                    };
                analysisRingIndex =
                    (analysisRingIndex + 1u)
                    & N60_ANALYSIS_CAPTURE_MASK;
            }

            const float transitionGain =
                next_transition_gain(&transitionRamp);
            const float gain =
                startup_fade_gain(&startupFade, masterGain)
                * transitionGain;
            const float finalLeft = processed.left * gain;
            const float finalRight = processed.right * gain;
            if (frameIndex
                    < activeQuietZoneReferenceFramesToWrite) {
                float quietZoneLeft = 0.0f;
                float quietZoneRight = 0.0f;
                N60RenderKernelGetActiveQuietZoneReferenceFrame(
                    bridge->renderKernel,
                    &quietZoneLeft,
                    &quietZoneRight
                );
                bridge->activeQuietZoneReferenceFrames[
                    activeQuietZoneReferenceRingIndex
                ] = (N60ActiveQuietZoneReferenceFrame){
                    quietZoneLeft * gain,
                    quietZoneRight * gain
                };
                activeQuietZoneReferenceRingIndex =
                    (activeQuietZoneReferenceRingIndex + 1u)
                    & (
                        N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
                        - 1u
                    );
            }
            if (frameIndex < ambientReferenceFramesToWrite) {
                bridge->ambientReferenceFrames[
                    ambientReferenceRingIndex
                ] = (N60AmbientPlaybackReferenceFrame){
                    finalLeft,
                    finalRight
                };
                ambientReferenceRingIndex =
                    (ambientReferenceRingIndex + 1u)
                    & (N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - 1u);
            }
            if (sameDeviceMultiOutput) {
                N60SpeakerBusFrame busFrame;
                process_speaker_bus_splitter(
                    &bridge->speakerBusSplitter,
                    finalLeft,
                    finalRight,
                    &busFrame
                );
                N60SpeakerDriverProcessingRuntimeProcessValues(
                    &bridge->speakerDriverProcessing,
                    busFrame.values
                );
                if (!N60SameDeviceOutputMapWriteFrame(
                        &bridge->sameDeviceOutputMap,
                        &busFrame,
                        outOutputData,
                        frameIndex)) {
                    zero_output(outOutputData);
                    atomic_fetch_add_explicit(
                        &bridge->unsupportedBufferLayouts,
                        1u,
                        memory_order_relaxed
                    );
                    N60RenderKernelEndRender(
                        bridge->renderKernel,
                        &renderContext,
                        renderedFrames
                    );
                    return noErr;
                }
            } else {
                *outputLeft = finalLeft;
                *outputRight = finalRight;
            }
            if (outputVUMeterEnabled) {
                const float absLeft = fabsf(finalLeft);
                const float absRight = fabsf(finalRight);
                if (absLeft > outputVUPeakLeft) {
                    outputVUPeakLeft = absLeft;
                }
                if (absRight > outputVUPeakRight) {
                    outputVUPeakRight = absRight;
                }
                outputVUSquareSumLeft +=
                    (double)finalLeft * (double)finalLeft;
                outputVUSquareSumRight +=
                    (double)finalRight * (double)finalRight;
                if (absLeft > 1.0f) {
                    outputVUOverRangeSamples += 1u;
                }
                if (absRight > 1.0f) {
                    outputVUOverRangeSamples += 1u;
                }
            }
            if (!sameDeviceMultiOutput) {
                outputLeft += outputView.leftStride;
                outputRight += outputView.rightStride;
            }
            renderedFrames += 1u;
        }
    } else {
        for (UInt32 frameIndex = 0;
             frameIndex < framesToRead;
             ++frameIndex) {
            N60StereoFrame frame;
            if (adaptiveSampleRate) {
                const size_t base = (size_t)frameIndex * 2u;
                frame = (N60StereoFrame){
                    bridge->adaptiveOutputScratch[base],
                    bridge->adaptiveOutputScratch[base + 1u]
                };
            } else {
                frame = bridge->frames[ringReadIndex];
                ringReadIndex += 1u;
                if (ringReadIndex == bridge->capacityFrames) {
                    ringReadIndex = 0u;
                }
            }
            N60StereoFrame processed;
            N60RenderKernelProcessStereoFrameInContext(
                bridge->renderKernel,
                &renderContext,
                frame.left,
                frame.right,
                &processed.left,
                &processed.right
            );

            if (frameIndex < analysisFramesToWrite) {
                bridge->analysisFrames[analysisRingIndex] =
                    (N60AnalysisFrame){
                        frame.left,
                        frame.right,
                        processed.left,
                        processed.right
                    };
                analysisRingIndex =
                    (analysisRingIndex + 1u)
                    & N60_ANALYSIS_CAPTURE_MASK;
            }

            const float transitionGain =
                next_transition_gain(&transitionRamp);
            const float gain =
                startup_fade_gain(&startupFade, masterGain)
                * transitionGain;
            const float finalLeft = processed.left * gain;
            const float finalRight = processed.right * gain;
            if (frameIndex
                    < activeQuietZoneReferenceFramesToWrite) {
                float quietZoneLeft = 0.0f;
                float quietZoneRight = 0.0f;
                N60RenderKernelGetActiveQuietZoneReferenceFrame(
                    bridge->renderKernel,
                    &quietZoneLeft,
                    &quietZoneRight
                );
                bridge->activeQuietZoneReferenceFrames[
                    activeQuietZoneReferenceRingIndex
                ] = (N60ActiveQuietZoneReferenceFrame){
                    quietZoneLeft * gain,
                    quietZoneRight * gain
                };
                activeQuietZoneReferenceRingIndex =
                    (activeQuietZoneReferenceRingIndex + 1u)
                    & (
                        N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
                        - 1u
                    );
            }
            if (frameIndex < ambientReferenceFramesToWrite) {
                bridge->ambientReferenceFrames[
                    ambientReferenceRingIndex
                ] = (N60AmbientPlaybackReferenceFrame){
                    finalLeft,
                    finalRight
                };
                ambientReferenceRingIndex =
                    (ambientReferenceRingIndex + 1u)
                    & (N60_AMBIENT_REFERENCE_CAPACITY_FRAMES - 1u);
            }
            if (sameDeviceMultiOutput) {
                N60SpeakerBusFrame busFrame;
                process_speaker_bus_splitter(
                    &bridge->speakerBusSplitter,
                    finalLeft,
                    finalRight,
                    &busFrame
                );
                N60SpeakerDriverProcessingRuntimeProcessValues(
                    &bridge->speakerDriverProcessing,
                    busFrame.values
                );
                if (!N60SameDeviceOutputMapWriteFrame(
                        &bridge->sameDeviceOutputMap,
                        &busFrame,
                        outOutputData,
                        frameIndex)) {
                    zero_output(outOutputData);
                    atomic_fetch_add_explicit(
                        &bridge->unsupportedBufferLayouts,
                        1u,
                        memory_order_relaxed
                    );
                    N60RenderKernelEndRender(
                        bridge->renderKernel,
                        &renderContext,
                        renderedFrames
                    );
                    return noErr;
                }
            } else {
                *outputLeft = finalLeft;
                *outputRight = finalRight;
            }
            if (outputVUMeterEnabled) {
                const float absLeft = fabsf(finalLeft);
                const float absRight = fabsf(finalRight);
                if (absLeft > outputVUPeakLeft) {
                    outputVUPeakLeft = absLeft;
                }
                if (absRight > outputVUPeakRight) {
                    outputVUPeakRight = absRight;
                }
                outputVUSquareSumLeft +=
                    (double)finalLeft * (double)finalLeft;
                outputVUSquareSumRight +=
                    (double)finalRight * (double)finalRight;
                if (absLeft > 1.0f) {
                    outputVUOverRangeSamples += 1u;
                }
                if (absRight > 1.0f) {
                    outputVUOverRangeSamples += 1u;
                }
            }
            if (!sameDeviceMultiOutput) {
                outputLeft += outputView.leftStride;
                outputRight += outputView.rightStride;
            }
            renderedFrames += 1u;
        }
    }

    N60RenderKernelEndRender(bridge->renderKernel, &renderContext, renderedFrames);

    if (analysisDemand != N60_ANALYSIS_DEMAND_NONE) {
        atomic_store_explicit(
            &bridge->analysisWriteIndex,
            analysisWriteIndex + analysisFramesToWrite,
            memory_order_release
        );
        atomic_fetch_add_explicit(
            &bridge->analysisCapturedFrames, analysisFramesToWrite, memory_order_relaxed
        );
        if (analysisFramesToWrite < framesToRead) {
            atomic_fetch_add_explicit(
                &bridge->analysisDroppedFrames,
                framesToRead - analysisFramesToWrite,
                memory_order_relaxed
            );
        }
    }

    if (ambientReferenceDemand) {
        atomic_store_explicit(
            &bridge->ambientReferenceWriteIndex,
            ambientReferenceWriteIndex
                + ambientReferenceFramesToWrite,
            memory_order_release
        );
        atomic_fetch_add_explicit(
            &bridge->ambientReferenceCapturedFrames,
            ambientReferenceFramesToWrite,
            memory_order_relaxed
        );
        if (ambientReferenceFramesToWrite < framesToRead) {
            atomic_fetch_add_explicit(
                &bridge->ambientReferenceDroppedFrames,
                framesToRead - ambientReferenceFramesToWrite,
                memory_order_relaxed
            );
        }
    }

    if (activeQuietZoneReferenceDemand) {
        atomic_store_explicit(
            &bridge->activeQuietZoneReferenceWriteIndex,
            activeQuietZoneReferenceWriteIndex
                + activeQuietZoneReferenceFramesToWrite,
            memory_order_release
        );
        atomic_fetch_add_explicit(
            &bridge->activeQuietZoneReferenceCapturedFrames,
            activeQuietZoneReferenceFramesToWrite,
            memory_order_relaxed
        );
        if (activeQuietZoneReferenceFramesToWrite < framesToRead) {
            atomic_fetch_add_explicit(
                &bridge->activeQuietZoneReferenceDroppedFrames,
                framesToRead
                    - activeQuietZoneReferenceFramesToWrite,
                memory_order_relaxed
            );
        }
    }

    for (UInt32 frameIndex = framesToRead; frameIndex < frameCount; ++frameIndex) {
        (void)next_transition_gain(&transitionRamp);
        if (sameDeviceMultiOutput) {
            N60SpeakerBusFrame silence = N60SpeakerBusFrameMakeSilence();
            (void)N60SameDeviceOutputMapWriteFrame(
                &bridge->sameDeviceOutputMap, &silence, outOutputData, frameIndex
            );
        } else {
            *outputLeft = 0.0f;
            *outputRight = 0.0f;
            outputLeft += outputView.leftStride;
            outputRight += outputView.rightStride;
        }
    }

    if (outputVUMeterEnabled) {
        publish_output_vu_meter(
            bridge,
            outputVUPeakLeft,
            outputVUPeakRight,
            outputVUSquareSumLeft,
            outputVUSquareSumRight,
            outputVUOverRangeSamples,
            frameCount
        );
    }

    bridge->transitionRuntime = transitionRamp;
    bridge->startupFadeRuntime = startupFade;
    publish_transition_runtime(bridge, &transitionRamp);

    if (!adaptiveSampleRate) {
        atomic_store_explicit(&bridge->readIndex, readIndex + framesToRead, memory_order_release);
    }
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
