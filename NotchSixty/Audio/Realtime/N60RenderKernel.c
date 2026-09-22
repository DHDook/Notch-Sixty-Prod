#include "N60RenderKernel.h"

#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_SNAPSHOT_SLOT_COUNT 2
#define N60_SNAPSHOT_ACQUIRE_ATTEMPTS 3
#define N60_EQ_TRANSITION_SECONDS 0.005
#define N60_EQ_MIN_TRANSITION_FRAMES 32
#define N60_EQ_MAX_TRANSITION_FRAMES 4096

typedef struct {
    N60DSPGraphSnapshot snapshot;
    _Atomic uint32_t readers;
} N60SnapshotSlot;

typedef struct {
    N60BiquadCoefficients currentCoefficients;
    N60BiquadCoefficients pendingCoefficients;
    N60BiquadState currentLeft;
    N60BiquadState currentRight;
    N60BiquadState pendingLeft;
    N60BiquadState pendingRight;
    bool currentEnabled;
    bool pendingEnabled;
    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
} N60EQBandRuntime;

struct N60RenderKernel {
    N60SnapshotSlot slots[N60_SNAPSHOT_SLOT_COUNT];
    _Atomic uint32_t activeSlot;
    _Atomic uint64_t nextGeneration;

    N60EQBandRuntime eqRuntime[N60_MAX_EQ_BANDS];
    uint64_t preparedGeneration;
    double preparedSampleRate;
    bool preparedGraphBypassed;
    bool preparedEQBypassed;

    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t sanitizedNonFiniteSamples;
    _Atomic uint64_t flushedDenormalSamples;
    _Atomic uint64_t snapshotReadMisses;
};

static bool coefficients_are_finite(N60BiquadCoefficients coefficients) {
    return isfinite(coefficients.b0)
        && isfinite(coefficients.b1)
        && isfinite(coefficients.b2)
        && isfinite(coefficients.a1)
        && isfinite(coefficients.a2);
}

static bool coefficients_equal(N60BiquadCoefficients lhs, N60BiquadCoefficients rhs) {
    return lhs.b0 == rhs.b0
        && lhs.b1 == rhs.b1
        && lhs.b2 == rhs.b2
        && lhs.a1 == rhs.a1
        && lhs.a2 == rhs.a2;
}

static bool band_snapshot_is_valid(N60BiquadBandSnapshot band, double sampleRate) {
    if (!band.enabled) {
        return true;
    }

    return isfinite(band.frequencyHz)
        && band.frequencyHz > 0.0
        && band.frequencyHz < sampleRate * 0.5
        && isfinite(band.gainDB)
        && isfinite(band.q)
        && band.q > 0.0
        && coefficients_are_finite(band.coefficients);
}

static bool snapshot_is_valid(N60DSPGraphSnapshot snapshot) {
    if (!isfinite(snapshot.sampleRate)
        || snapshot.sampleRate <= 0.0
        || snapshot.channelCount != 2
        || !isfinite(snapshot.inputGainLinear)
        || !isfinite(snapshot.outputGainLinear)
        || snapshot.eqBandCount > N60_MAX_EQ_BANDS) {
        return false;
    }

    for (uint32_t index = 0; index < snapshot.eqBandCount; ++index) {
        if (!band_snapshot_is_valid(snapshot.eqBands[index], snapshot.sampleRate)) {
            return false;
        }
    }
    return true;
}

static uint32_t transition_frames_for_sample_rate(double sampleRate) {
    double requested = sampleRate * N60_EQ_TRANSITION_SECONDS;
    if (requested < (double)N60_EQ_MIN_TRANSITION_FRAMES) {
        return N60_EQ_MIN_TRANSITION_FRAMES;
    }
    if (requested > (double)N60_EQ_MAX_TRANSITION_FRAMES) {
        return N60_EQ_MAX_TRANSITION_FRAMES;
    }
    return (uint32_t)llround(requested);
}

static void clear_state(N60BiquadState *state) {
    state->z1 = 0.0f;
    state->z2 = 0.0f;
}

static void reset_band_runtime(N60EQBandRuntime *runtime) {
    runtime->currentCoefficients = N60BiquadCoefficientsMakeIdentity();
    runtime->pendingCoefficients = N60BiquadCoefficientsMakeIdentity();
    clear_state(&runtime->currentLeft);
    clear_state(&runtime->currentRight);
    clear_state(&runtime->pendingLeft);
    clear_state(&runtime->pendingRight);
    runtime->currentEnabled = false;
    runtime->pendingEnabled = false;
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static void reset_eq_runtime(N60RenderKernel *kernel) {
    for (uint32_t index = 0; index < N60_MAX_EQ_BANDS; ++index) {
        reset_band_runtime(&kernel->eqRuntime[index]);
    }
}

static void promote_pending_filter(N60EQBandRuntime *runtime) {
    if (runtime->transitionFramesRemaining == 0) {
        return;
    }

    runtime->currentCoefficients = runtime->pendingCoefficients;
    runtime->currentLeft = runtime->pendingLeft;
    runtime->currentRight = runtime->pendingRight;
    runtime->currentEnabled = runtime->pendingEnabled;
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static void schedule_band_transition(
    N60EQBandRuntime *runtime,
    bool enabled,
    N60BiquadCoefficients coefficients,
    uint32_t transitionFrames
) {
    promote_pending_filter(runtime);

    if (runtime->currentEnabled == enabled
        && (!enabled || coefficients_equal(runtime->currentCoefficients, coefficients))) {
        return;
    }

    runtime->pendingEnabled = enabled;
    runtime->pendingCoefficients = enabled ? coefficients : N60BiquadCoefficientsMakeIdentity();
    runtime->pendingLeft = runtime->currentLeft;
    runtime->pendingRight = runtime->currentRight;
    runtime->transitionFramesTotal = transitionFrames > 0 ? transitionFrames : 1;
    runtime->transitionFramesRemaining = runtime->transitionFramesTotal;
}

static void prepare_eq_runtime_for_snapshot(
    N60RenderKernel *kernel,
    const N60DSPGraphSnapshot *snapshot
) {
    if (kernel->preparedGeneration == snapshot->generation) {
        return;
    }

    bool sampleRateChanged = kernel->preparedSampleRate != 0.0
        && fabs(kernel->preparedSampleRate - snapshot->sampleRate) > 0.5;
    bool leavingGraphBypass = kernel->preparedGraphBypassed && !snapshot->bypassed;
    bool leavingEQBypass = kernel->preparedEQBypassed && !snapshot->eqBypassed;

    if (sampleRateChanged || leavingGraphBypass || leavingEQBypass) {
        reset_eq_runtime(kernel);
    }

    if (!snapshot->bypassed && !snapshot->eqBypassed) {
        uint32_t transitionFrames = snapshot->eqTransitionFrames > 0
            ? snapshot->eqTransitionFrames
            : transition_frames_for_sample_rate(snapshot->sampleRate);

        for (uint32_t index = 0; index < N60_MAX_EQ_BANDS; ++index) {
            bool enabled = false;
            N60BiquadCoefficients coefficients = N60BiquadCoefficientsMakeIdentity();
            if (index < snapshot->eqBandCount) {
                enabled = snapshot->eqBands[index].enabled;
                coefficients = snapshot->eqBands[index].coefficients;
            }
            schedule_band_transition(&kernel->eqRuntime[index], enabled, coefficients, transitionFrames);
        }
    } else {
        reset_eq_runtime(kernel);
    }

    kernel->preparedGeneration = snapshot->generation;
    kernel->preparedSampleRate = snapshot->sampleRate;
    kernel->preparedGraphBypassed = snapshot->bypassed;
    kernel->preparedEQBypassed = snapshot->eqBypassed;
}

static float process_eq_band(
    N60EQBandRuntime *runtime,
    float input,
    bool leftChannel
) {
    N60BiquadState *currentState = leftChannel ? &runtime->currentLeft : &runtime->currentRight;
    N60BiquadState *pendingState = leftChannel ? &runtime->pendingLeft : &runtime->pendingRight;

    float currentOutput = runtime->currentEnabled
        ? N60BiquadProcessSample(runtime->currentCoefficients, currentState, input)
        : input;

    if (runtime->transitionFramesRemaining == 0) {
        return currentOutput;
    }

    float pendingOutput = runtime->pendingEnabled
        ? N60BiquadProcessSample(runtime->pendingCoefficients, pendingState, input)
        : input;

    uint32_t completed = runtime->transitionFramesTotal - runtime->transitionFramesRemaining + 1;
    float mix = (float)completed / (float)runtime->transitionFramesTotal;
    return currentOutput + (pendingOutput - currentOutput) * mix;
}

static void advance_eq_transitions(N60RenderKernel *kernel) {
    for (uint32_t index = 0; index < N60_MAX_EQ_BANDS; ++index) {
        N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
        if (runtime->transitionFramesRemaining == 0) {
            continue;
        }

        runtime->transitionFramesRemaining -= 1;
        if (runtime->transitionFramesRemaining == 0) {
            runtime->currentCoefficients = runtime->pendingCoefficients;
            runtime->currentLeft = runtime->pendingLeft;
            runtime->currentRight = runtime->pendingRight;
            runtime->currentEnabled = runtime->pendingEnabled;
            runtime->transitionFramesTotal = 0;
            if (!runtime->currentEnabled) {
                clear_state(&runtime->currentLeft);
                clear_state(&runtime->currentRight);
            }
        }
    }
}

static float sanitize_sample(N60RenderKernel *kernel, float sample) {
    if (!isfinite(sample)) {
        atomic_fetch_add_explicit(&kernel->sanitizedNonFiniteSamples, 1, memory_order_relaxed);
        return 0.0f;
    }

    if (fpclassify(sample) == FP_SUBNORMAL) {
        atomic_fetch_add_explicit(&kernel->flushedDenormalSamples, 1, memory_order_relaxed);
        return 0.0f;
    }

    return sample;
}

static N60RenderKernelRenderContext acquire_render_context(N60RenderKernel *kernel) {
    N60RenderKernelRenderContext context = {0};
    if (kernel == NULL) {
        return context;
    }

    for (uint32_t attempt = 0; attempt < N60_SNAPSHOT_ACQUIRE_ATTEMPTS; ++attempt) {
        uint32_t slotIndex = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
        N60SnapshotSlot *slot = &kernel->slots[slotIndex];

        atomic_fetch_add_explicit(&slot->readers, 1, memory_order_acq_rel);
        if (slotIndex == atomic_load_explicit(&kernel->activeSlot, memory_order_acquire)) {
            context.snapshot = slot->snapshot;
            context.slotIndex = slotIndex;
            context.acquired = true;
            return context;
        }
        atomic_fetch_sub_explicit(&slot->readers, 1, memory_order_release);
    }

    atomic_fetch_add_explicit(&kernel->snapshotReadMisses, 1, memory_order_relaxed);
    return context;
}

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate) {
    N60DSPGraphSnapshot snapshot = {0};
    snapshot.sampleRate = sampleRate;
    snapshot.channelCount = 2;
    snapshot.inputGainLinear = 1.0f;
    snapshot.outputGainLinear = 1.0f;
    snapshot.bypassed = false;
    snapshot.latencyFrames = 0;
    snapshot.generation = 0;
    snapshot.eqBypassed = false;
    snapshot.eqBandCount = 0;
    snapshot.eqTransitionFrames = transition_frames_for_sample_rate(sampleRate);
    return snapshot;
}

void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {
    if (snapshot == NULL) {
        return;
    }
    memset(snapshot->eqBands, 0, sizeof(snapshot->eqBands));
    snapshot->eqBandCount = 0;
}

bool N60DSPGraphSnapshotSetEQBand(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (snapshot == NULL || bandIndex >= N60_MAX_EQ_BANDS) {
        return false;
    }

    N60BiquadBandSnapshot band = {0};
    if (!N60BiquadBandSnapshotMake(
            type,
            snapshot->sampleRate,
            frequencyHz,
            gainDB,
            q,
            enabled,
            &band)) {
        return false;
    }

    snapshot->eqBands[bandIndex] = band;
    if (snapshot->eqBandCount <= bandIndex) {
        snapshot->eqBandCount = bandIndex + 1;
    }
    return true;
}

N60RenderKernel *N60RenderKernelCreate(void) {
    N60RenderKernel *kernel = calloc(1, sizeof(N60RenderKernel));
    if (kernel == NULL) {
        return NULL;
    }

    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
    initial.generation = 1;
    kernel->slots[0].snapshot = initial;
    kernel->slots[1].snapshot = initial;
    atomic_store_explicit(&kernel->activeSlot, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->nextGeneration, 1, memory_order_relaxed);
    reset_eq_runtime(kernel);
    return kernel;
}

void N60RenderKernelDestroy(N60RenderKernel *kernel) {
    free(kernel);
}

void N60RenderKernelReset(N60RenderKernel *kernel) {
    if (kernel == NULL) {
        return;
    }

    reset_eq_runtime(kernel);
    kernel->preparedGeneration = 0;
    kernel->preparedSampleRate = 0.0;
    kernel->preparedGraphBypassed = false;
    kernel->preparedEQBypassed = false;
    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->sanitizedNonFiniteSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->flushedDenormalSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->snapshotReadMisses, 0, memory_order_relaxed);
}

bool N60RenderKernelPublishSnapshot(N60RenderKernel *kernel, N60DSPGraphSnapshot snapshot) {
    if (kernel == NULL || !snapshot_is_valid(snapshot)) {
        return false;
    }

    uint32_t active = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
    uint32_t inactive = active == 0 ? 1 : 0;
    N60SnapshotSlot *slot = &kernel->slots[inactive];

    // Publication is control-plane only. Wait for a callback that still owns
    // the inactive slot from an older graph generation to release it.
    while (atomic_load_explicit(&slot->readers, memory_order_acquire) != 0) {
        sched_yield();
    }

    snapshot.generation = atomic_fetch_add_explicit(&kernel->nextGeneration, 1, memory_order_relaxed) + 1;
    slot->snapshot = snapshot;
    atomic_store_explicit(&kernel->activeSlot, inactive, memory_order_release);
    return true;
}

N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel *kernel) {
    N60RenderKernelRenderContext context = acquire_render_context(kernel);
    if (context.acquired) {
        prepare_eq_runtime_for_snapshot(kernel, &context.snapshot);
    }
    return context;
}

void N60RenderKernelProcessStereoFrameInContext(
    N60RenderKernel *kernel,
    const N60RenderKernelRenderContext *context,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (kernel == NULL || context == NULL || outputLeft == NULL || outputRight == NULL) {
        return;
    }

    float left = sanitize_sample(kernel, inputLeft);
    float right = sanitize_sample(kernel, inputRight);

    if (context->acquired && !context->snapshot.bypassed) {
        left *= context->snapshot.inputGainLinear;
        right *= context->snapshot.inputGainLinear;

        if (!context->snapshot.eqBypassed) {
            for (uint32_t index = 0; index < N60_MAX_EQ_BANDS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) {
                    continue;
                }
                left = process_eq_band(runtime, left, true);
                right = process_eq_band(runtime, right, false);
            }
            advance_eq_transitions(kernel);
        }

        left *= context->snapshot.outputGainLinear;
        right *= context->snapshot.outputGainLinear;
    }

    *outputLeft = sanitize_sample(kernel, left);
    *outputRight = sanitize_sample(kernel, right);
}

void N60RenderKernelEndRender(
    N60RenderKernel *kernel,
    N60RenderKernelRenderContext *context,
    uint32_t renderedFrames
) {
    if (kernel == NULL || context == NULL) {
        return;
    }

    if (context->acquired && context->slotIndex < N60_SNAPSHOT_SLOT_COUNT) {
        atomic_fetch_sub_explicit(&kernel->slots[context->slotIndex].readers, 1, memory_order_release);
        context->acquired = false;
    }
    atomic_fetch_add_explicit(&kernel->renderedFrames, renderedFrames, memory_order_relaxed);
}

void N60RenderKernelProcessStereoFrame(
    N60RenderKernel *kernel,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (kernel == NULL || outputLeft == NULL || outputRight == NULL) {
        return;
    }

    N60RenderKernelRenderContext context = N60RenderKernelBeginRender(kernel);
    N60RenderKernelProcessStereoFrameInContext(
        kernel,
        &context,
        inputLeft,
        inputRight,
        outputLeft,
        outputRight
    );
    N60RenderKernelEndRender(kernel, &context, 1);
}

N60RenderKernelDiagnostics N60RenderKernelGetDiagnostics(const N60RenderKernel *kernel) {
    N60RenderKernelDiagnostics diagnostics = {0};
    if (kernel == NULL) {
        return diagnostics;
    }

    N60RenderKernel *mutableKernel = (N60RenderKernel *)kernel;
    N60RenderKernelRenderContext context = acquire_render_context(mutableKernel);
    if (context.acquired) {
        diagnostics.publishedGeneration = context.snapshot.generation;
        diagnostics.latencyFrames = context.snapshot.latencyFrames;
        diagnostics.sampleRate = context.snapshot.sampleRate;
        diagnostics.channelCount = context.snapshot.channelCount;
        diagnostics.bypassed = context.snapshot.bypassed;
        diagnostics.eqBypassed = context.snapshot.eqBypassed;
        diagnostics.eqBandCount = context.snapshot.eqBandCount;
        N60RenderKernelEndRender(mutableKernel, &context, 0);
    }

    diagnostics.renderedFrames = atomic_load_explicit(&kernel->renderedFrames, memory_order_relaxed);
    diagnostics.sanitizedNonFiniteSamples = atomic_load_explicit(&kernel->sanitizedNonFiniteSamples, memory_order_relaxed);
    diagnostics.flushedDenormalSamples = atomic_load_explicit(&kernel->flushedDenormalSamples, memory_order_relaxed);
    diagnostics.snapshotReadMisses = atomic_load_explicit(&kernel->snapshotReadMisses, memory_order_relaxed);
    return diagnostics;
}
