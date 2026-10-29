#include "N60RealtimeAudioBridge.h"

#include "n60/graph.h"

#include <math.h>
#include <stddef.h>
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
    N60CrossoverPreciseState lowerLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerLowMono[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperHighRight[N60_MAX_CROSSOVER_SECTIONS];
    // Tri-amp phase compensation: the low band passes through the upper
    // crossover's all-pass (LP2 + HP2) so the three bands sum flat.
    N60CrossoverPreciseState lowAllPassLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState subPhaseAlignment;
} N60SpeakerBusSplitterRuntime;


// E6 S8b2c: capacity of each latency-alignment delay ring (power of two). The applied
// alignment is clamped to the warm-up length (rings must be full of live data when a fade
// starts) and to N60_ALIGN_RING_FRAMES - 2 (linear-interpolated read).
#define N60_ALIGN_RING_FRAMES 16384u
#define N60_ALIGN_RING_MASK (N60_ALIGN_RING_FRAMES - 1u)

// E6 S8: an alternate render path through libn60core. The attachment is built and freed
// on the control thread only; the audio callback loads the pointer (acquire) and calls
// n60_graph_process on planar scratch whose lifetime the callback does not own.
// The attachment (and its scratch) is allocated once on first attach and lives until the
// bridge is destroyed, so the callback can never touch freed memory.
//
// E6 S8b: the control thread only states a wish (`wantGraph`); the callback owns the
// hand-over. The side that is taking over is first run cold-to-warm on the live input for
// `warmFrames` with its output discarded, then crossfaded in over `fadeFrames` while the
// other side keeps running, so neither attach nor detach steps or restarts from stale
// state. The kernel is cold-started (N60RenderKernelColdStart) before it takes over; the
// graph keeps its state but is warmed the same way because it was not processed meanwhile.
// E6 S8d: the spectral-denoiser noise profile is the one thing that is not discarded or left stale at a
// hand-over: it is copied from the side that was rendering to the side that takes over.
typedef struct N60UnifiedGraphAttachment {
    _Atomic(n60_graph *) graph;
    _Atomic bool wantGraph;
    _Atomic uint32_t publishedMixBits;  // callback -> control, for diagnostics and tests
    float *scratch;       // 4 * maxFrames floats: planar in (2 lanes) then planar out (2 lanes)
    // E6 S8b2c: latency alignment across the hand-over fade. Four delay rings of
    // N60_ALIGN_RING_FRAMES (kernel L, kernel R, graph L, graph R), allocated with the scratch.
    // The control thread publishes the graph's latency; the callback reads the kernel's from
    // its own snapshot and slews a delay on the lower-latency side across the fade.
    float *alignRing;
    uint32_t lastKernelLatency;  // callback-owned: last kernel latency read from a snapshot
    _Atomic int32_t publishedAlignFrames;  // callback -> control: latched graph - kernel latency
    uint32_t alignWrite;       // callback-owned ring write index
    int32_t alignLatched;      // callback-owned: graph - kernel latency used for the current fade
    uint32_t maxFrames;
    uint32_t warmFrames;
    uint32_t fadeFrames;
    // Callback-owned hand-over state (control thread touches it only while IO is stopped).
    float mix;            // weight of the graph output, 0 = kernel only, 1 = graph only
    uint32_t graphWarmLeft;
    uint32_t kernelWarmLeft;
    bool graphCold;       // graph was not processed since it was last idle
    bool kernelCold;      // kernel was not processed since it was last idle
    // E6 S8d: the denoiser noise profile in transit between the two sides at a hand-over, the same bytes seen
    // as either side's type. Preallocated with the attachment; callback-owned.
    union {
        n60_denoiser_state graph;
        N60SpectralDenoiserProfileState kernel;
    } profileHandover;
} N60UnifiedGraphAttachment;

_Static_assert(sizeof(n60_denoiser_state) == sizeof(N60SpectralDenoiserProfileState),
               "kernel and graph denoiser profile states must share a layout");
_Static_assert(offsetof(n60_denoiser_state, fftSize) == offsetof(N60SpectralDenoiserProfileState, fftSize),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, flags) == offsetof(N60SpectralDenoiserProfileState, flags),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, adaptiveFrames) == offsetof(N60SpectralDenoiserProfileState, adaptiveFrames),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, adaptiveTarget) == offsetof(N60SpectralDenoiserProfileState, adaptiveTarget),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, adaptiveBlocks) == offsetof(N60SpectralDenoiserProfileState, adaptiveBlocks),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, lastRevision) == offsetof(N60SpectralDenoiserProfileState, lastRevision),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, captureCollected) == offsetof(N60SpectralDenoiserProfileState, captureCollected),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, captureTarget) == offsetof(N60SpectralDenoiserProfileState, captureTarget),
               "kernel and graph denoiser profile header fields must line up");
_Static_assert(offsetof(n60_denoiser_state, noise) == offsetof(N60SpectralDenoiserProfileState, noise)
               && offsetof(n60_denoiser_state, adaptiveMin) == offsetof(N60SpectralDenoiserProfileState, adaptiveMinimum)
               && offsetof(n60_denoiser_state, captureSum) == offsetof(N60SpectralDenoiserProfileState, captureSum),
               "kernel and graph denoiser profile arrays must line up");

typedef struct N60UnifiedGraphPlan {
    N60UnifiedGraphAttachment *attachment;
    n60_graph *graph;
    bool graphRunning;
    bool kernelRunning;
    float mixStep;        // signed per-frame change of mix once the warm-up has run out
} N60UnifiedGraphPlan;

struct N60RealtimeAudioBridge {
    _Atomic(N60UnifiedGraphAttachment *) unifiedGraph;
    _Atomic uint32_t unifiedGraphLatency;  // control -> callback: attached graph's latency frames
    void *rackBoundGraph;                  // E6 S8e: control-thread only; the graph whose callback points at this bridge
    _Atomic bool unifiedGraphHostsRack;    // E6 S8e: the graph's EXTERNAL stage calls this bridge's AU rack
    double graphRackSampleTime;            // callback thread only: output sample time of the graph chunk being rendered
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
    const N60CrossoverPreciseCoefficients *coefficients,
    N60CrossoverPreciseState *states,
    uint32_t count,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < count; ++index) {
        output = N60CrossoverPreciseProcessSample(coefficients[index], &states[index], output);
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
            subMono = N60CrossoverPreciseProcessSample(
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

    if (snapshot->mode == N60SpeakerCrossoverModeBiAmp) {
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftLow, lowLeft);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightLow, lowRight);
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

    // Tri-amp Linkwitz-Riley tree:
    //   low  = LP1 · (LP2 + HP2)   (upper all-pass compensation)
    //   mid  = HP1 · LP2
    //   high = HP1 · HP2
    // so low + mid + high = AP1 · AP2, an all-pass with flat magnitude.
    lowLeft = process_splitter_sections(
            snapshot->upperLowPass, runtime->lowAllPassLowLeft,
            snapshot->upperSectionCount, lowLeft
        )
        + process_splitter_sections(
            snapshot->upperHighPass, runtime->lowAllPassHighLeft,
            snapshot->upperSectionCount, lowLeft
        );
    lowRight = process_splitter_sections(
            snapshot->upperLowPass, runtime->lowAllPassLowRight,
            snapshot->upperSectionCount, lowRight
        )
        + process_splitter_sections(
            snapshot->upperHighPass, runtime->lowAllPassHighRight,
            snapshot->upperSectionCount, lowRight
        );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftLow, lowLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightLow, lowRight);

    const float upperLeft = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighLeft,
        snapshot->lowerSectionCount, left
    );
    const float upperRight = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighRight,
        snapshot->lowerSectionCount, right
    );
    const float midLeft = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowLeft,
        snapshot->upperSectionCount, upperLeft
    );
    const float midRight = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowRight,
        snapshot->upperSectionCount, upperRight
    );
    const float highLeft = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighLeft,
        snapshot->upperSectionCount, upperLeft
    );
    const float highRight = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighRight,
        snapshot->upperSectionCount, upperRight
    );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftMid, midLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightMid, midRight);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, highLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, highRight);
}

static void free_unified_attachment(N60UnifiedGraphAttachment *attachment) {
    if (attachment == NULL) return;
    free(attachment->alignRing);
    free(attachment->scratch);
    free(attachment);
}

bool N60RealtimeAudioBridgeSetUnifiedGraph(
    N60RealtimeAudioBridge *bridge,
    void *graph,
    uint32_t maxFrames,
    double sampleRate
) {
    if (bridge == NULL) return false;
    N60UnifiedGraphAttachment *attachment = atomic_load_explicit(
        &bridge->unifiedGraph, memory_order_acquire
    );
    if (graph == NULL) {
        // Detach: the callback warms the kernel and fades to it. The graph pointer stays
        // valid for that fade; the owner releases it with ReleaseUnifiedGraph once IO stops.
        if (attachment != NULL) {
            atomic_store_explicit(&attachment->wantGraph, false, memory_order_release);
        }
        return true;
    }
    if (maxFrames == 0u || maxFrames > (1u << 20)) return false;
    if (!(sampleRate >= 8000.0 && sampleRate <= 768000.0)) return false;
    const uint32_t warmFrames = (uint32_t)(sampleRate * 0.050);
    const uint32_t fadeFrames = (uint32_t)(sampleRate * 0.020);
    if (attachment == NULL) {
        attachment = calloc(1, sizeof(N60UnifiedGraphAttachment));
        if (attachment == NULL) return false;
        attachment->scratch = calloc((size_t)maxFrames * 4u, sizeof(float));
        if (attachment->scratch == NULL) {
            free(attachment);
            return false;
        }
        attachment->alignRing = calloc((size_t)N60_ALIGN_RING_FRAMES * 4u, sizeof(float));
        if (attachment->alignRing == NULL) {
            free(attachment->scratch);
            free(attachment);
            return false;
        }
        attachment->maxFrames = maxFrames;
        attachment->warmFrames = warmFrames;
        attachment->fadeFrames = fadeFrames;
        attachment->graphCold = true;
        atomic_store_explicit(&attachment->graph, (n60_graph *)graph, memory_order_relaxed);
        atomic_store_explicit(&attachment->wantGraph, true, memory_order_relaxed);
        atomic_store_explicit(&bridge->unifiedGraph, attachment, memory_order_release);
        return true;
    }
    // The scratch size and the warm-up/fade lengths are fixed by the first attach; a graph built
    // for larger blocks or another sample rate is refused (Release first, with IO stopped).
    if (maxFrames > attachment->maxFrames) return false;
    if (warmFrames != attachment->warmFrames || fadeFrames != attachment->fadeFrames) return false;
    // A different graph object is accepted only once the previous hand-over has fully ended
    // (not wanted, mix published as 0), so the callback never sees the pointer change mid-use.
    if (atomic_load_explicit(&attachment->graph, memory_order_relaxed) != (n60_graph *)graph) {
        if (atomic_load_explicit(&attachment->wantGraph, memory_order_acquire)
            || atomic_load_explicit(&attachment->publishedMixBits, memory_order_relaxed) != 0u) {
            return false;
        }
        atomic_store_explicit(&attachment->graph, (n60_graph *)graph, memory_order_release);
        attachment->graphCold = true;
    }
    atomic_store_explicit(&attachment->wantGraph, true, memory_order_release);
    return true;
}

// E6 S8e. Callback thread (called by the graph's EXTERNAL stage). Interleaves the planar lanes, runs the AU rack in
// slices of at most its maximumFramesPerSlice, and writes the result back to the lanes. Uses the rack scratch (the
// rack branch and this path never run in the same block). Returns 0 on any rack failure; the graph then outputs
// silence for the block and counts a fault. Allocation: none. Locks: none. Latency: the rack's own.
static int graph_rack_trampoline(
    void *context,
    const float *const *in,
    float *const *out,
    uint32_t channels,
    uint32_t frames
) {
    N60RealtimeAudioBridge *bridge = (N60RealtimeAudioBridge *)context;
    if (bridge == NULL || channels != 2u || bridge->audioUnitRackScratch == NULL
        || !N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)) {
        return 0;
    }
    const uint32_t maxSlice = bridge->audioUnitRack.maximumFramesPerSlice;
    float *scratch = bridge->audioUnitRackScratch;
    for (uint32_t start = 0; start < frames;) {
        uint32_t n = frames - start;
        if (n > maxSlice) n = maxSlice;
        for (uint32_t i = 0; i < n; ++i) {
            scratch[2u * i] = in[0][start + i];
            scratch[2u * i + 1u] = in[1][start + i];
        }
        if (!N60AudioUnitLiveRackProcess(
                &bridge->audioUnitRack, scratch, scratch, n, 2u,
                bridge->graphRackSampleTime + (double)start)) {
            return 0;
        }
        for (uint32_t i = 0; i < n; ++i) {
            out[0][start + i] = scratch[2u * i];
            out[1][start + i] = scratch[2u * i + 1u];
        }
        start += n;
    }
    return 1;
}

bool N60RealtimeAudioBridgeBindRackToGraph(N60RealtimeAudioBridge *bridge, void *graph) {
    if (bridge == NULL || graph == NULL
        || !N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)
        || bridge->audioUnitRackScratch == NULL) {
        return false;
    }
    if (n60_graph_set_external_processor((n60_graph *)graph, graph_rack_trampoline, bridge, 2u) != N60_STATUS_OK) {
        return false;
    }
    bridge->rackBoundGraph = graph;
    atomic_store_explicit(&bridge->unifiedGraphHostsRack, true, memory_order_release);
    return true;
}

void N60RealtimeAudioBridgeUnbindRackFromGraph(N60RealtimeAudioBridge *bridge, void *graph) {
    if (bridge == NULL) return;
    atomic_store_explicit(&bridge->unifiedGraphHostsRack, false, memory_order_release);
    if (graph == NULL) graph = bridge->rackBoundGraph;
    if (graph != NULL) {
        (void)n60_graph_set_external_processor((n60_graph *)graph, NULL, NULL, 0u);
    }
    bridge->rackBoundGraph = NULL;
}

void N60RealtimeAudioBridgeSetUnifiedGraphLatency(
    N60RealtimeAudioBridge *bridge,
    uint32_t latencyFrames
) {
    if (bridge == NULL) return;
    atomic_store_explicit(&bridge->unifiedGraphLatency, latencyFrames, memory_order_relaxed);
}

int32_t N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(const N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return 0;
    N60UnifiedGraphAttachment *attachment = atomic_load_explicit(
        (_Atomic(N60UnifiedGraphAttachment *) *)&bridge->unifiedGraph, memory_order_acquire
    );
    if (attachment == NULL) return 0;
    return atomic_load_explicit(&attachment->publishedAlignFrames, memory_order_relaxed);
}

void N60RealtimeAudioBridgeReleaseUnifiedGraph(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return;
    // The graph's callback points at this bridge, so it is cleared whenever the bridge lets go of the graph.
    N60RealtimeAudioBridgeUnbindRackFromGraph(bridge, NULL);
    N60UnifiedGraphAttachment *attachment = atomic_load_explicit(
        &bridge->unifiedGraph, memory_order_acquire
    );
    if (attachment == NULL) return;
    atomic_store_explicit(&attachment->wantGraph, false, memory_order_release);
    atomic_store_explicit(&attachment->graph, NULL, memory_order_release);
    attachment->mix = 0.0f;
    attachment->graphWarmLeft = 0u;
    attachment->kernelWarmLeft = 0u;
    attachment->graphCold = true;
    attachment->kernelCold = true;
    atomic_store_explicit(&attachment->publishedMixBits, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->unifiedGraphLatency, 0u, memory_order_relaxed);
    memset(attachment->alignRing, 0, (size_t)N60_ALIGN_RING_FRAMES * 4u * sizeof(float));
    attachment->lastKernelLatency = 0u;
    atomic_store_explicit(&attachment->publishedAlignFrames, 0, memory_order_relaxed);
    attachment->alignLatched = 0;
}

bool N60RealtimeAudioBridgeUnifiedGraphActive(const N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return false;
    N60UnifiedGraphAttachment *attachment = atomic_load_explicit(
        (_Atomic(N60UnifiedGraphAttachment *) *)&bridge->unifiedGraph, memory_order_acquire
    );
    return attachment != NULL
        && atomic_load_explicit(&attachment->graph, memory_order_acquire) != NULL
        && atomic_load_explicit(&attachment->wantGraph, memory_order_acquire);
}

float N60RealtimeAudioBridgeUnifiedGraphMix(const N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL) return 0.0f;
    N60UnifiedGraphAttachment *attachment = atomic_load_explicit(
        (_Atomic(N60UnifiedGraphAttachment *) *)&bridge->unifiedGraph, memory_order_acquire
    );
    if (attachment == NULL) return 0.0f;
    const uint32_t bits = atomic_load_explicit(&attachment->publishedMixBits, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

// Callback. The kernel is about to take over from the graph: cold-start it, then give it the graph's denoiser
// noise profile (the cold start clears the kernel's own), so the profile survives the switch. `graph` may be NULL
// (released), in which case the kernel simply starts cold.
static void hand_denoiser_profile_to_kernel(
    N60RealtimeAudioBridge *bridge,
    N60UnifiedGraphAttachment *a,
    n60_graph *graph
) {
    bool have = graph != NULL && n60_graph_denoiser_export(graph, &a->profileHandover.graph) != 0;
    N60RenderKernelColdStart(bridge->renderKernel);
    // The convolvers keep state across a cold start (their clear is multi-MB); invalidate them in O(1) instead.
    N60RenderKernelMarkIdle(bridge->renderKernel);
    if (have) N60RenderKernelImportDenoiserProfile(bridge->renderKernel, &a->profileHandover.kernel);
}

// Callback. Decides, once per block and before the kernel renders, which sides run.
// Cold-starts the kernel when it is about to take over; never allocates or locks.
static N60UnifiedGraphPlan plan_unified_block(
    N60RealtimeAudioBridge *bridge,
    uint32_t framesToRead,
    bool eligibleBranch
) {
    N60UnifiedGraphPlan plan = {0};
    N60UnifiedGraphAttachment *a = atomic_load_explicit(&bridge->unifiedGraph, memory_order_acquire);
    plan.attachment = a;
    plan.kernelRunning = true;
    if (a == NULL) return plan;
    n60_graph *graph = atomic_load_explicit(&a->graph, memory_order_acquire);
    bool want = graph != NULL && eligibleBranch
        && atomic_load_explicit(&a->wantGraph, memory_order_acquire);
    if (graph == NULL || !eligibleBranch) {
        // No graph to hand over from (released, or a branch the graph does not serve):
        // the kernel renders, from a cold start if the graph had been rendering.
        if (a->mix > 0.0f) {
            a->mix = 0.0f;
            a->kernelWarmLeft = 0u;
            if (a->kernelCold) {
                hand_denoiser_profile_to_kernel(bridge, a, graph);
                a->kernelCold = false;
            }
        }
        a->graphWarmLeft = 0u;
        a->graphCold = true;
        return plan;
    }
    (void)framesToRead;
    plan.graph = graph;
    const float step = a->fadeFrames > 0u ? 1.0f / (float)a->fadeFrames : 1.0f;
    if (want) {
        a->kernelWarmLeft = 0u;
        if (a->graphCold) {
            // The kernel's noise profile (captured or learned) goes with the hand-over; the graph's own copy
            // is stale. A kernel that has not run yet exports a fresh profile, which is what it has.
            N60RenderKernelExportDenoiserProfile(bridge->renderKernel, &a->profileHandover.kernel);
            n60_graph_denoiser_import(graph, &a->profileHandover.graph);
            // FIR stages restart from silence (O(1), no clear) and warm for their whole tap length, so no stale
            // history from before the graph last ran is heard and the filter is fully built when it fades in.
            n60_graph_invalidate_history(graph);
            const uint32_t firFrames = n60_graph_history_frames(graph);
            a->graphWarmLeft = firFrames > a->warmFrames ? firFrames : a->warmFrames;
            a->graphCold = false;
        }
        plan.graphRunning = true;
        plan.kernelRunning = a->mix < 1.0f;
        plan.mixStep = step;
    } else if (a->mix > 0.0f) {
        a->graphWarmLeft = 0u;
        if (a->kernelCold) {
            hand_denoiser_profile_to_kernel(bridge, a, graph);
            // The kernel's convolvers restarted from silence: warm for their longest tap count.
            const uint32_t convFrames = N60RenderKernelConvolutionHistoryFrames(bridge->renderKernel);
            a->kernelWarmLeft = convFrames > a->warmFrames ? convFrames : a->warmFrames;
            a->kernelCold = false;
        }
        plan.graphRunning = true;
        plan.kernelRunning = true;
        plan.mixStep = -step;
    } else {
        a->graphWarmLeft = 0u;
        a->graphCold = true;
        plan.graph = NULL;
    }
    // A side that does not run this block is stale the next time it is needed.
    if (!plan.kernelRunning) a->kernelCold = true;
    return plan;
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
    N60RealtimeAudioBridgeUnbindRackFromGraph(bridge, NULL);
    free_unified_attachment(atomic_load_explicit(&bridge->unifiedGraph, memory_order_acquire));
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
    N60UnifiedGraphAttachment *unified = atomic_load_explicit(&bridge->unifiedGraph, memory_order_acquire);
    if (unified != NULL) {
        // The kernel was just reset; the graph starts from a warm-up again (IO is stopped).
        unified->mix = 0.0f;
        unified->graphWarmLeft = 0u;
        unified->kernelWarmLeft = 0u;
        unified->graphCold = true;
        unified->kernelCold = false;
        atomic_store_explicit(&unified->publishedMixBits, 0u, memory_order_relaxed);
    }
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

void N60RealtimeAudioBridgeRenewActiveQuietZoneLease(
    N60RealtimeAudioBridge *bridge,
    uint64_t durationFrames
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return;
    N60RenderKernelRenewActiveQuietZoneLease(bridge->renderKernel, durationFrames);
}

void N60RealtimeAudioBridgeReleaseActiveQuietZoneLease(N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL || bridge->renderKernel == NULL) return;
    N60RenderKernelReleaseActiveQuietZoneLease(bridge->renderKernel);
}

uint64_t N60RealtimeAudioBridgeActiveQuietZoneLeaseExpiryCount(const N60RealtimeAudioBridge *bridge) {
    if (bridge == NULL || bridge->renderKernel == NULL) return 0;
    return N60RenderKernelActiveQuietZoneLeaseExpiryCount(bridge->renderKernel);
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


static bool protected_measurement_bus_is_supported(
    const N60SpeakerBusSplitterSnapshot *snapshot,
    N60SpeakerOutputBus bus
) {
    if (snapshot == NULL || !snapshot->enabled) return false;
    if (snapshot->lowerSectionCount == 0u
        || snapshot->lowerSectionCount > N60_MAX_CROSSOVER_SECTIONS) {
        return false;
    }

    switch (snapshot->mode) {
    case N60SpeakerCrossoverModeBiAmp:
        return bus == N60SpeakerOutputBusLeftLow
            || bus == N60SpeakerOutputBusRightLow
            || bus == N60SpeakerOutputBusLeftHigh
            || bus == N60SpeakerOutputBusRightHigh;
    case N60SpeakerCrossoverModeTriAmp:
        if (snapshot->upperSectionCount == 0u
            || snapshot->upperSectionCount > N60_MAX_CROSSOVER_SECTIONS) {
            return false;
        }
        return bus == N60SpeakerOutputBusLeftLow
            || bus == N60SpeakerOutputBusRightLow
            || bus == N60SpeakerOutputBusLeftMid
            || bus == N60SpeakerOutputBusRightMid
            || bus == N60SpeakerOutputBusLeftHigh
            || bus == N60SpeakerOutputBusRightHigh;
    case N60SpeakerCrossoverModeMainsSub:
    default:
        return false;
    }
}

static bool protected_measurement_bus_is_left(
    N60SpeakerOutputBus bus
) {
    return bus == N60SpeakerOutputBusLeftLow
        || bus == N60SpeakerOutputBusLeftMid
        || bus == N60SpeakerOutputBusLeftHigh;
}

bool N60ProtectedSpeakerBusRenderProgram(
    const float *monoInput,
    uint32_t frameCount,
    N60SpeakerOutputBus targetBus,
    N60SpeakerBusSplitterSnapshot splitterSnapshot,
    N60SpeakerDriverProcessingSnapshot driverSnapshot,
    float *output
) {
    if (monoInput == NULL || output == NULL || frameCount == 0u
        || !protected_measurement_bus_is_supported(
            &splitterSnapshot, targetBus
        )
        || !driverSnapshot.valid || !driverSnapshot.enabled
        || targetBus < N60SpeakerOutputBusLeftLow
        || targetBus > N60SpeakerOutputBusRightHigh) {
        return false;
    }

    const uint32_t driverIndex = (uint32_t)targetBus;
    if (driverIndex >= N60_SPEAKER_DRIVER_BUS_COUNT) return false;
    const N60SpeakerDriverBusSnapshot *targetDriver =
        &driverSnapshot.buses[driverIndex];

    // A "protected driver" measurement is not allowed to silently downgrade
    // to crossover-only protection. The exact target bus must be enabled and
    // its configured limiter must remain in the rendered chain.
    if (!targetDriver->enabled || !targetDriver->limiterEnabled) {
        return false;
    }

    N60SpeakerBusSplitterRuntime splitterRuntime = {0};
    splitterRuntime.snapshot = splitterSnapshot;

    N60SpeakerDriverProcessingRuntime *driverRuntime =
        (N60SpeakerDriverProcessingRuntime *)calloc(
            1u, sizeof(N60SpeakerDriverProcessingRuntime)
        );
    if (driverRuntime == NULL) return false;
    if (!N60SpeakerDriverProcessingRuntimeConfigure(
            driverRuntime, driverSnapshot)) {
        free(driverRuntime);
        return false;
    }

    const bool left = protected_measurement_bus_is_left(targetBus);
    for (uint32_t frameIndex = 0u;
         frameIndex < frameCount;
         ++frameIndex) {
        const float input = monoInput[frameIndex];
        if (!isfinite(input)) {
            free(driverRuntime);
            return false;
        }

        N60SpeakerBusFrame frame;
        process_speaker_bus_splitter(
            &splitterRuntime,
            left ? input : 0.0f,
            left ? 0.0f : input,
            &frame
        );
        N60SpeakerDriverProcessingRuntimeProcessValues(
            driverRuntime,
            frame.values
        );
        const float rendered = N60SpeakerBusFrameGet(
            &frame, targetBus
        );
        if (!isfinite(rendered)) {
            free(driverRuntime);
            return false;
        }
        output[frameIndex] = rendered;
    }

    free(driverRuntime);
    return true;
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

// A failed rack/route render still consumed its input-domain frames through
// the playback kernel. Advance the ring so a failure costs one silent quantum
// rather than permanently adding a quantum of buffered latency.
static void consume_frames_after_failed_render(
    N60RealtimeAudioBridge *bridge,
    bool adaptiveSampleRate,
    uint64_t readIndex,
    UInt32 framesToRead
) {
    if (!adaptiveSampleRate) {
        atomic_store_explicit(&bridge->readIndex, readIndex + framesToRead, memory_order_release);
    }
}

// Matched-rate underrun: the partial block was faded out in the render loop.
// Re-arm the startup gate so playback resumes only after a full re-prime and
// with the startup fade-in, matching the adaptive-rate policy.
static void rearm_output_gate_after_underrun(N60RealtimeAudioBridge *bridge) {
    atomic_store_explicit(&bridge->outputGateOpen, false, memory_order_release);
    uint32_t fadeFrames = atomic_load_explicit(
        &bridge->startupFadeFramesTotal,
        memory_order_relaxed
    );
    bridge->startupFadeRuntime.totalFrames = fadeFrames;
    bridge->startupFadeRuntime.remainingFrames = fadeFrames;
}

// Callbacks that return early with zeroed output (gate closed, adaptive
// partial pull, failed render) are silent, so a pending transition ramp
// completes in the sample domain. Advance and acknowledge it so the control
// plane can finish a fade-down/fade-up without waiting for input to resume.
// Realtime: atomics and float arithmetic only; no allocation or locks; adds no
// latency; independent of sample rate and channel count (counted in frames);
// output-thread-only writer of transitionRuntime, as in the normal path.
static void advance_transition_through_silence(
    N60RealtimeAudioBridge *bridge,
    UInt32 frames
) {
    latch_transition_command(bridge);
    N60TransitionRampRuntime *runtime = &bridge->transitionRuntime;
    if (runtime->remainingFrames != 0 && runtime->totalFrames != 0) {
        if (frames >= runtime->remainingFrames) {
            runtime->remainingFrames = 0;
            runtime->currentGain = runtime->targetGain;
        } else {
            runtime->remainingFrames -= frames;
            uint32_t completed = runtime->totalFrames - runtime->remainingFrames;
            float mix = (float)completed / (float)runtime->totalFrames;
            runtime->currentGain = runtime->startGain
                + (runtime->targetGain - runtime->startGain) * mix;
        }
    }
    publish_transition_runtime(bridge, runtime);
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
            advance_transition_through_silence(bridge, frameCount);
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
        advance_transition_through_silence(bridge, frameCount);
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
    // Matched-rate partial block: fade the frames we have to zero instead of
    // ending them with a hard step into the silent remainder.
    const bool underrunFadeOut = !adaptiveSampleRate && framesToRead < frameCount;
    const float underrunFadeStep = underrunFadeOut && framesToRead > 0u
        ? 1.0f / (float)framesToRead
        : 0.0f;
    float underrunFade = 1.0f;

    float outputVUPeakLeft = 0.0f;
    float outputVUPeakRight = 0.0f;
    double outputVUSquareSumLeft = 0.0;
    double outputVUSquareSumRight = 0.0;
    uint64_t outputVUOverRangeSamples = 0;

    latch_transition_command(bridge);
    latch_startup_fade_command(bridge);
    N60TransitionRampRuntime transitionRamp = bridge->transitionRuntime;
    N60StartupFadeRuntime startupFade = bridge->startupFadeRuntime;

    // E6 S8b: decide the graph/kernel hand-over for this block before the kernel prepares.
    N60UnifiedGraphPlan unifiedPlan = plan_unified_block(
        bridge,
        framesToRead,
        !N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)
            || atomic_load_explicit(&bridge->unifiedGraphHostsRack, memory_order_acquire)
    );
    N60RenderKernelRenderContext renderContext =
        N60RenderKernelBeginRender(bridge->renderKernel);
    UInt32 renderedFrames = 0;
    uint32_t ringReadIndex =
        (uint32_t)(readIndex % bridge->capacityFrames);
    float *outputLeft = outputView.left;
    float *outputRight = outputView.right;
    // E6 S8e: with the graph rendering, its EXTERNAL stage hosts the rack, so the kernel rack branch runs
    // only when the graph does not.
    const bool rackConfigured =
        N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)
        && !(unifiedPlan.graphRunning && unifiedPlan.graph != NULL);
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
            advance_transition_through_silence(bridge, frameCount);
            consume_frames_after_failed_render(
                bridge, adaptiveSampleRate, readIndex, framesToRead
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
            advance_transition_through_silence(bridge, frameCount);
            consume_frames_after_failed_render(
                bridge, adaptiveSampleRate, readIndex, framesToRead
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
                * transitionGain
                * underrunFade;
            if (underrunFadeOut) {
                underrunFade -= underrunFadeStep;
                if (underrunFade < 0.0f) underrunFade = 0.0f;
            }
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
                    advance_transition_through_silence(bridge, frameCount);
                    consume_frames_after_failed_render(
                        bridge, adaptiveSampleRate, readIndex, framesToRead
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
        // E6 S8/S8b: with a unified graph attached, whole-buffer n60_graph_process calls
        // (in chunks of at most maxFrames) replace the per-frame kernel once the hand-over
        // has finished; while it is in progress both run and their outputs are crossfaded.
        // No allocation, no locks.
        N60UnifiedGraphAttachment *unified = unifiedPlan.attachment;
        const bool graphRuns = unifiedPlan.graphRunning && unifiedPlan.graph != NULL;
        const bool kernelRuns = unifiedPlan.kernelRunning;
        float mix = graphRuns ? unified->mix : 0.0f;
        uint32_t graphWarmLeft = graphRuns ? unified->graphWarmLeft : 0u;
        uint32_t kernelWarmLeft = graphRuns ? unified->kernelWarmLeft : 0u;
        // E6 S8b2c: graph minus kernel latency, latched while a fade is in progress so the
        // slewed delay cannot jump. delta > 0: the kernel leads and is delayed by delta * mix;
        // delta < 0: the graph leads and is delayed by -delta * (1 - mix). Either way the
        // delayed side is at full delay when its weight reaches zero and undelayed when it is
        // the only side audible, so no step is introduced at either end of the fade.
        int32_t alignDelta = 0;
        uint32_t alignWrite = 0u;
        float *alignRing = NULL;
        if (graphRuns) {
            alignRing = unified->alignRing;
            alignWrite = unified->alignWrite;
            if (mix > 0.0f && mix < 1.0f) {
                alignDelta = unified->alignLatched;
            } else {
                const int64_t graphLatency = (int64_t)atomic_load_explicit(
                    &bridge->unifiedGraphLatency, memory_order_relaxed
                );
                // Without a snapshot this block, keep the last kernel latency seen.
                if (renderContext.acquired && renderContext.snapshot != NULL) {
                    unified->lastKernelLatency = renderContext.snapshot->latencyFrames;
                }
                const int64_t kernelLatency = (int64_t)unified->lastKernelLatency;
                int64_t delta = graphLatency - kernelLatency;
                // The delayed side's read position moves at (1 - delta/fadeFrames) frames per
                // frame, so |delta| is capped at a quarter of the fade (at most 25% speed
                // change on a side that is fading out); a larger difference is only partly
                // compensated. The warm-up length and ring size cap it further.
                int64_t limit = (int64_t)(unified->fadeFrames / 4u);
                if (limit > (int64_t)unified->warmFrames) limit = (int64_t)unified->warmFrames;
                if (limit > (int64_t)N60_ALIGN_RING_FRAMES - 2) limit = (int64_t)N60_ALIGN_RING_FRAMES - 2;
                if (delta > limit) delta = limit;
                if (delta < -limit) delta = -limit;
                alignDelta = (int32_t)delta;
                unified->alignLatched = alignDelta;
                atomic_store_explicit(&unified->publishedAlignFrames, alignDelta, memory_order_relaxed);
            }
        }
        uint32_t graphReadPosition = ringReadIndex;
        uint32_t graphChunkStart = 0u;
        uint32_t graphChunkFrames = 0u;
        float *graphOut = graphRuns ? unified->scratch + (size_t)unified->maxFrames * 2u : NULL;
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
            N60StereoFrame processed = {0.0f, 0.0f};
            N60StereoFrame kernelFrame = {0.0f, 0.0f};
            if (graphRuns && frameIndex >= graphChunkStart + graphChunkFrames) {
                // Render the next chunk of the block through the graph.
                graphChunkStart = frameIndex;
                graphChunkFrames = framesToRead - frameIndex;
                if (graphChunkFrames > unified->maxFrames) graphChunkFrames = unified->maxFrames;
                float *planarIn = unified->scratch;
                for (uint32_t i = 0; i < graphChunkFrames; ++i) {
                    N60StereoFrame source;
                    if (adaptiveSampleRate) {
                        const size_t base = ((size_t)graphChunkStart + i) * 2u;
                        source = (N60StereoFrame){
                            bridge->adaptiveOutputScratch[base],
                            bridge->adaptiveOutputScratch[base + 1u]
                        };
                    } else {
                        source = bridge->frames[graphReadPosition];
                        graphReadPosition += 1u;
                        if (graphReadPosition == bridge->capacityFrames) graphReadPosition = 0u;
                    }
                    planarIn[i] = source.left;
                    planarIn[unified->maxFrames + i] = source.right;
                }
                bridge->graphRackSampleTime = outputSampleTime + (double)graphChunkStart;
                const float *inLanes[2] = { planarIn, planarIn + unified->maxFrames };
                float *outLanes[2] = { graphOut, graphOut + unified->maxFrames };
                // On a process error the chunk is silence, never a splice of stale state.
                if (n60_graph_process(unifiedPlan.graph, inLanes, outLanes,
                                      graphChunkFrames) != N60_STATUS_OK) {
                    memset(graphOut, 0, (size_t)graphChunkFrames * sizeof(float));
                    memset(graphOut + unified->maxFrames, 0, (size_t)graphChunkFrames * sizeof(float));
                }
            }
            if (kernelRuns || !graphRuns) {
                N60RenderKernelProcessStereoFrameInContext(
                    bridge->renderKernel,
                    &renderContext,
                    frame.left,
                    frame.right,
                    &kernelFrame.left,
                    &kernelFrame.right
                );
            }
            if (graphRuns) {
                const uint32_t offset = frameIndex - graphChunkStart;
                float graphLeft = graphOut[offset];
                float graphRight = graphOut[unified->maxFrames + offset];
                if (kernelRuns) {
                    // E6 S8b2c: record both sides, then read the leading side back through a
                    // delay slewed with the mix (linear interpolation).
                    float *kRingL = alignRing;
                    float *kRingR = alignRing + N60_ALIGN_RING_FRAMES;
                    float *gRingL = alignRing + 2u * N60_ALIGN_RING_FRAMES;
                    float *gRingR = alignRing + 3u * N60_ALIGN_RING_FRAMES;
                    kRingL[alignWrite] = kernelFrame.left;
                    kRingR[alignWrite] = kernelFrame.right;
                    gRingL[alignWrite] = graphLeft;
                    gRingR[alignWrite] = graphRight;
                    if (alignDelta != 0) {
                        const bool delayKernel = alignDelta > 0;
                        const float amount = (float)(delayKernel ? alignDelta : -alignDelta);
                        const float delay = amount * (delayKernel ? mix : 1.0f - mix);
                        const uint32_t whole = (uint32_t)delay;
                        const float frac = delay - (float)whole;
                        const uint32_t i0 = (alignWrite - whole) & N60_ALIGN_RING_MASK;
                        const uint32_t i1 = (i0 - 1u) & N60_ALIGN_RING_MASK;
                        float *ringL = delayKernel ? kRingL : gRingL;
                        float *ringR = delayKernel ? kRingR : gRingR;
                        const float dl = ringL[i0] + (ringL[i1] - ringL[i0]) * frac;
                        const float dr = ringR[i0] + (ringR[i1] - ringR[i0]) * frac;
                        if (delayKernel) {
                            kernelFrame.left = dl;
                            kernelFrame.right = dr;
                        } else {
                            graphLeft = dl;
                            graphRight = dr;
                        }
                    }
                    alignWrite = (alignWrite + 1u) & N60_ALIGN_RING_MASK;
                }
                if (kernelRuns) {
                    processed.left = kernelFrame.left + (graphLeft - kernelFrame.left) * mix;
                    processed.right = kernelFrame.right + (graphRight - kernelFrame.right) * mix;
                } else {
                    processed.left = graphLeft;
                    processed.right = graphRight;
                }
                if (graphWarmLeft > 0u) {
                    graphWarmLeft -= 1u;
                } else if (kernelWarmLeft > 0u) {
                    kernelWarmLeft -= 1u;
                } else if (unifiedPlan.mixStep != 0.0f) {
                    mix += unifiedPlan.mixStep;
                    if (mix > 1.0f) mix = 1.0f;
                    if (mix < 0.0f) mix = 0.0f;
                }
            } else {
                processed = kernelFrame;
            }

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
                * transitionGain
                * underrunFade;
            if (underrunFadeOut) {
                underrunFade -= underrunFadeStep;
                if (underrunFade < 0.0f) underrunFade = 0.0f;
            }
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
                    advance_transition_through_silence(bridge, frameCount);
                    consume_frames_after_failed_render(
                        bridge, adaptiveSampleRate, readIndex, framesToRead
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
        if (graphRuns) {
            unified->mix = mix;
            unified->graphWarmLeft = graphWarmLeft;
            unified->kernelWarmLeft = kernelWarmLeft;
            unified->alignWrite = alignWrite;
            uint32_t mixBits;
            memcpy(&mixBits, &mix, sizeof(mixBits));
            atomic_store_explicit(&unified->publishedMixBits, mixBits, memory_order_relaxed);
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
    if (underrunFadeOut) {
        rearm_output_gate_after_underrun(bridge);
    }

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
