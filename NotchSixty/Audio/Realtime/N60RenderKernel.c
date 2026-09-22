#include "N60RenderKernel.h"

#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_SNAPSHOT_SLOT_COUNT 2
#define N60_SNAPSHOT_ACQUIRE_ATTEMPTS 3
#define N60_EQ_TRANSITION_SECONDS 0.005
#define N60_GAIN_TRANSITION_SECONDS 0.005
#define N60_EQ_MIN_TRANSITION_FRAMES 32
#define N60_EQ_MAX_TRANSITION_FRAMES 4096
#define N60_GAIN_MIN_TRANSITION_FRAMES 32
#define N60_GAIN_MAX_TRANSITION_FRAMES 4096

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

typedef struct {
    float current;
    float start;
    float target;
    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
} N60SmoothedGain;

struct N60RenderKernel {
    N60SnapshotSlot slots[N60_SNAPSHOT_SLOT_COUNT];
    _Atomic uint32_t activeSlot;
    _Atomic uint64_t nextGeneration;

    N60EQBandRuntime eqRuntime[N60_MAX_EQ_BANDS];
    N60SmoothedGain inputGain;
    N60SmoothedGain headroomGain;
    N60SmoothedGain outputGain;
    uint64_t preparedGeneration;
    double preparedSampleRate;
    bool preparedGraphBypassed;
    bool preparedEQBypassed;

    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t sanitizedNonFiniteSamples;
    _Atomic uint64_t flushedDenormalSamples;
    _Atomic uint64_t snapshotReadMisses;

    _Atomic uint32_t inputPeakLeftBits;
    _Atomic uint32_t inputPeakRightBits;
    _Atomic uint32_t inputRMSLeftBits;
    _Atomic uint32_t inputRMSRightBits;
    _Atomic uint64_t inputOverRangeSamples;

    _Atomic uint32_t postEQPeakLeftBits;
    _Atomic uint32_t postEQPeakRightBits;
    _Atomic uint32_t postEQRMSLeftBits;
    _Atomic uint32_t postEQRMSRightBits;
    _Atomic uint64_t postEQOverRangeSamples;

    _Atomic uint32_t outputPeakLeftBits;
    _Atomic uint32_t outputPeakRightBits;
    _Atomic uint32_t outputRMSLeftBits;
    _Atomic uint32_t outputRMSRightBits;
    _Atomic uint64_t outputOverRangeSamples;
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
        || snapshot.inputGainLinear < 0.0f
        || !isfinite(snapshot.headroomGainLinear)
        || snapshot.headroomGainLinear < 0.0f
        || !isfinite(snapshot.outputGainLinear)
        || snapshot.outputGainLinear < 0.0f
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

static uint32_t transition_frames(
    double sampleRate,
    double seconds,
    uint32_t minimumFrames,
    uint32_t maximumFrames
) {
    double requested = sampleRate * seconds;
    if (requested < (double)minimumFrames) {
        return minimumFrames;
    }
    if (requested > (double)maximumFrames) {
        return maximumFrames;
    }
    return (uint32_t)llround(requested);
}

static uint32_t eq_transition_frames_for_sample_rate(double sampleRate) {
    return transition_frames(
        sampleRate,
        N60_EQ_TRANSITION_SECONDS,
        N60_EQ_MIN_TRANSITION_FRAMES,
        N60_EQ_MAX_TRANSITION_FRAMES
    );
}

static uint32_t gain_transition_frames_for_sample_rate(double sampleRate) {
    return transition_frames(
        sampleRate,
        N60_GAIN_TRANSITION_SECONDS,
        N60_GAIN_MIN_TRANSITION_FRAMES,
        N60_GAIN_MAX_TRANSITION_FRAMES
    );
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

static void reset_smoothed_gain(N60SmoothedGain *gain, float value) {
    gain->current = value;
    gain->start = value;
    gain->target = value;
    gain->transitionFramesTotal = 0;
    gain->transitionFramesRemaining = 0;
}

static void schedule_gain_transition(N60SmoothedGain *gain, float target, uint32_t transitionFrames) {
    if (gain->target == target && gain->transitionFramesRemaining == 0) {
        return;
    }
    gain->start = gain->current;
    gain->target = target;
    gain->transitionFramesTotal = transitionFrames > 0 ? transitionFrames : 1;
    gain->transitionFramesRemaining = gain->transitionFramesTotal;
}

static float next_gain_value(N60SmoothedGain *gain) {
    if (gain->transitionFramesRemaining == 0) {
        gain->current = gain->target;
        return gain->current;
    }

    uint32_t completed = gain->transitionFramesTotal - gain->transitionFramesRemaining + 1;
    float mix = (float)completed / (float)gain->transitionFramesTotal;
    gain->current = gain->start + (gain->target - gain->start) * mix;
    gain->transitionFramesRemaining -= 1;
    if (gain->transitionFramesRemaining == 0) {
        gain->current = gain->target;
    }
    return gain->current;
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

static void prepare_runtime_for_snapshot(
    N60RenderKernel *kernel,
    const N60DSPGraphSnapshot *snapshot
) {
    if (kernel->preparedGeneration == snapshot->generation) {
        return;
    }

    bool firstPreparation = kernel->preparedGeneration == 0;
    bool sampleRateChanged = kernel->preparedSampleRate != 0.0
        && fabs(kernel->preparedSampleRate - snapshot->sampleRate) > 0.5;
    bool leavingGraphBypass = kernel->preparedGraphBypassed && !snapshot->bypassed;
    bool leavingEQBypass = kernel->preparedEQBypassed && !snapshot->eqBypassed;

    uint32_t gainFrames = snapshot->gainTransitionFrames > 0
        ? snapshot->gainTransitionFrames
        : gain_transition_frames_for_sample_rate(snapshot->sampleRate);

    if (firstPreparation || sampleRateChanged) {
        reset_smoothed_gain(&kernel->inputGain, snapshot->inputGainLinear);
        reset_smoothed_gain(&kernel->headroomGain, snapshot->headroomGainLinear);
        reset_smoothed_gain(&kernel->outputGain, snapshot->outputGainLinear);
    } else {
        schedule_gain_transition(&kernel->inputGain, snapshot->inputGainLinear, gainFrames);
        schedule_gain_transition(&kernel->headroomGain, snapshot->headroomGainLinear, gainFrames);
        schedule_gain_transition(&kernel->outputGain, snapshot->outputGainLinear, gainFrames);
    }

    if (sampleRateChanged || leavingGraphBypass || leavingEQBypass) {
        reset_eq_runtime(kernel);
    }

    if (!snapshot->bypassed && !snapshot->eqBypassed) {
        uint32_t transitionFrames = snapshot->eqTransitionFrames > 0
            ? snapshot->eqTransitionFrames
            : eq_transition_frames_for_sample_rate(snapshot->sampleRate);

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

static void meter_sample(
    float left,
    float right,
    float *peakLeft,
    float *peakRight,
    double *squareSumLeft,
    double *squareSumRight,
    uint64_t *overRangeSamples
) {
    float absLeft = fabsf(left);
    float absRight = fabsf(right);
    if (absLeft > *peakLeft) {
        *peakLeft = absLeft;
    }
    if (absRight > *peakRight) {
        *peakRight = absRight;
    }
    *squareSumLeft += (double)left * (double)left;
    *squareSumRight += (double)right * (double)right;
    if (absLeft > 1.0f) {
        *overRangeSamples += 1;
    }
    if (absRight > 1.0f) {
        *overRangeSamples += 1;
    }
}

static void publish_meter(
    _Atomic uint32_t *peakLeftBits,
    _Atomic uint32_t *peakRightBits,
    _Atomic uint32_t *rmsLeftBits,
    _Atomic uint32_t *rmsRightBits,
    _Atomic uint64_t *overRangeSamples,
    float peakLeft,
    float peakRight,
    double squareSumLeft,
    double squareSumRight,
    uint64_t overRangeCount,
    uint32_t frameCount
) {
    float rmsLeft = frameCount > 0 ? (float)sqrt(squareSumLeft / (double)frameCount) : 0.0f;
    float rmsRight = frameCount > 0 ? (float)sqrt(squareSumRight / (double)frameCount) : 0.0f;
    atomic_store_explicit(peakLeftBits, float_to_bits(peakLeft), memory_order_relaxed);
    atomic_store_explicit(peakRightBits, float_to_bits(peakRight), memory_order_relaxed);
    atomic_store_explicit(rmsLeftBits, float_to_bits(rmsLeft), memory_order_relaxed);
    atomic_store_explicit(rmsRightBits, float_to_bits(rmsRight), memory_order_relaxed);
    atomic_fetch_add_explicit(overRangeSamples, overRangeCount, memory_order_relaxed);
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
    snapshot.headroomGainLinear = 1.0f;
    snapshot.outputGainLinear = 1.0f;
    snapshot.bypassed = false;
    snapshot.latencyFrames = 0;
    snapshot.generation = 0;
    snapshot.gainTransitionFrames = gain_transition_frames_for_sample_rate(sampleRate);
    snapshot.eqBypassed = false;
    snapshot.eqBandCount = 0;
    snapshot.eqTransitionFrames = eq_transition_frames_for_sample_rate(sampleRate);
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
    reset_smoothed_gain(&kernel->inputGain, 1.0f);
    reset_smoothed_gain(&kernel->headroomGain, 1.0f);
    reset_smoothed_gain(&kernel->outputGain, 1.0f);
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
    reset_smoothed_gain(&kernel->inputGain, 1.0f);
    reset_smoothed_gain(&kernel->headroomGain, 1.0f);
    reset_smoothed_gain(&kernel->outputGain, 1.0f);
    kernel->preparedGeneration = 0;
    kernel->preparedSampleRate = 0.0;
    kernel->preparedGraphBypassed = false;
    kernel->preparedEQBypassed = false;
    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->sanitizedNonFiniteSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->flushedDenormalSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->snapshotReadMisses, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputPeakLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputPeakRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputRMSLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputRMSRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->inputOverRangeSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->postEQPeakLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->postEQPeakRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->postEQRMSLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->postEQRMSRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->postEQOverRangeSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->outputPeakLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->outputPeakRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->outputRMSLeftBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->outputRMSRightBits, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->outputOverRangeSamples, 0, memory_order_relaxed);
}

bool N60RenderKernelPublishSnapshot(N60RenderKernel *kernel, N60DSPGraphSnapshot snapshot) {
    if (kernel == NULL || !snapshot_is_valid(snapshot)) {
        return false;
    }

    uint32_t active = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
    uint32_t inactive = active == 0 ? 1 : 0;
    N60SnapshotSlot *slot = &kernel->slots[inactive];

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
        prepare_runtime_for_snapshot(kernel, &context.snapshot);
    }
    return context;
}

void N60RenderKernelProcessStereoFrameInContext(
    N60RenderKernel *kernel,
    N60RenderKernelRenderContext *context,
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

    meter_sample(
        left,
        right,
        &context->inputPeakLeft,
        &context->inputPeakRight,
        &context->inputSquareSumLeft,
        &context->inputSquareSumRight,
        &context->inputOverRangeSamples
    );

    if (context->acquired && !context->snapshot.bypassed) {
        float inputGain = next_gain_value(&kernel->inputGain);
        float headroomGain = next_gain_value(&kernel->headroomGain);
        left *= inputGain * headroomGain;
        right *= inputGain * headroomGain;

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

        meter_sample(
            left,
            right,
            &context->postEQPeakLeft,
            &context->postEQPeakRight,
            &context->postEQSquareSumLeft,
            &context->postEQSquareSumRight,
            &context->postEQOverRangeSamples
        );

        float outputGain = next_gain_value(&kernel->outputGain);
        left *= outputGain;
        right *= outputGain;
    } else {
        meter_sample(
            left,
            right,
            &context->postEQPeakLeft,
            &context->postEQPeakRight,
            &context->postEQSquareSumLeft,
            &context->postEQSquareSumRight,
            &context->postEQOverRangeSamples
        );
    }

    left = sanitize_sample(kernel, left);
    right = sanitize_sample(kernel, right);

    meter_sample(
        left,
        right,
        &context->outputPeakLeft,
        &context->outputPeakRight,
        &context->outputSquareSumLeft,
        &context->outputSquareSumRight,
        &context->outputOverRangeSamples
    );
    context->meteredFrames += 1;

    *outputLeft = left;
    *outputRight = right;
}

void N60RenderKernelEndRender(
    N60RenderKernel *kernel,
    N60RenderKernelRenderContext *context,
    uint32_t renderedFrames
) {
    if (kernel == NULL || context == NULL) {
        return;
    }

    publish_meter(
        &kernel->inputPeakLeftBits,
        &kernel->inputPeakRightBits,
        &kernel->inputRMSLeftBits,
        &kernel->inputRMSRightBits,
        &kernel->inputOverRangeSamples,
        context->inputPeakLeft,
        context->inputPeakRight,
        context->inputSquareSumLeft,
        context->inputSquareSumRight,
        context->inputOverRangeSamples,
        context->meteredFrames
    );
    publish_meter(
        &kernel->postEQPeakLeftBits,
        &kernel->postEQPeakRightBits,
        &kernel->postEQRMSLeftBits,
        &kernel->postEQRMSRightBits,
        &kernel->postEQOverRangeSamples,
        context->postEQPeakLeft,
        context->postEQPeakRight,
        context->postEQSquareSumLeft,
        context->postEQSquareSumRight,
        context->postEQOverRangeSamples,
        context->meteredFrames
    );
    publish_meter(
        &kernel->outputPeakLeftBits,
        &kernel->outputPeakRightBits,
        &kernel->outputRMSLeftBits,
        &kernel->outputRMSRightBits,
        &kernel->outputOverRangeSamples,
        context->outputPeakLeft,
        context->outputPeakRight,
        context->outputSquareSumLeft,
        context->outputSquareSumRight,
        context->outputOverRangeSamples,
        context->meteredFrames
    );

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

static N60StereoMeterReading load_meter_reading(
    const _Atomic uint32_t *peakLeftBits,
    const _Atomic uint32_t *peakRightBits,
    const _Atomic uint32_t *rmsLeftBits,
    const _Atomic uint32_t *rmsRightBits,
    const _Atomic uint64_t *overRangeSamples
) {
    N60StereoMeterReading reading = {0};
    reading.peakLeft = bits_to_float(atomic_load_explicit(peakLeftBits, memory_order_relaxed));
    reading.peakRight = bits_to_float(atomic_load_explicit(peakRightBits, memory_order_relaxed));
    reading.rmsLeft = bits_to_float(atomic_load_explicit(rmsLeftBits, memory_order_relaxed));
    reading.rmsRight = bits_to_float(atomic_load_explicit(rmsRightBits, memory_order_relaxed));
    reading.overRangeSamples = atomic_load_explicit(overRangeSamples, memory_order_relaxed);
    return reading;
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
        diagnostics.inputGainLinear = context.snapshot.inputGainLinear;
        diagnostics.headroomGainLinear = context.snapshot.headroomGainLinear;
        diagnostics.outputGainLinear = context.snapshot.outputGainLinear;
        diagnostics.eqBypassed = context.snapshot.eqBypassed;
        diagnostics.eqBandCount = context.snapshot.eqBandCount;
        N60RenderKernelEndRender(mutableKernel, &context, 0);
    }

    diagnostics.renderedFrames = atomic_load_explicit(&kernel->renderedFrames, memory_order_relaxed);
    diagnostics.sanitizedNonFiniteSamples = atomic_load_explicit(&kernel->sanitizedNonFiniteSamples, memory_order_relaxed);
    diagnostics.flushedDenormalSamples = atomic_load_explicit(&kernel->flushedDenormalSamples, memory_order_relaxed);
    diagnostics.snapshotReadMisses = atomic_load_explicit(&kernel->snapshotReadMisses, memory_order_relaxed);
    diagnostics.inputMeter = load_meter_reading(
        &kernel->inputPeakLeftBits,
        &kernel->inputPeakRightBits,
        &kernel->inputRMSLeftBits,
        &kernel->inputRMSRightBits,
        &kernel->inputOverRangeSamples
    );
    diagnostics.postEQMeter = load_meter_reading(
        &kernel->postEQPeakLeftBits,
        &kernel->postEQPeakRightBits,
        &kernel->postEQRMSLeftBits,
        &kernel->postEQRMSRightBits,
        &kernel->postEQOverRangeSamples
    );
    diagnostics.outputMeter = load_meter_reading(
        &kernel->outputPeakLeftBits,
        &kernel->outputPeakRightBits,
        &kernel->outputRMSLeftBits,
        &kernel->outputRMSRightBits,
        &kernel->outputOverRangeSamples
    );
    return diagnostics;
}
