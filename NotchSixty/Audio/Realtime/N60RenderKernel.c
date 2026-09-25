#include "N60RenderKernel.h"

#include <limits.h>
#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_SNAPSHOT_SLOT_COUNT 2
#define N60_SNAPSHOT_ACQUIRE_ATTEMPTS 3
#define N60_EQ_TRANSITION_SECONDS 0.005
#define N60_GAIN_TRANSITION_SECONDS 0.005
#define N60_CROSSOVER_TRANSITION_SECONDS 0.008
#define N60_EQ_MIN_TRANSITION_FRAMES 32
#define N60_EQ_MAX_TRANSITION_FRAMES 4096
#define N60_GAIN_MIN_TRANSITION_FRAMES 32
#define N60_GAIN_MAX_TRANSITION_FRAMES 4096
#define N60_CROSSOVER_MIN_TRANSITION_FRAMES 64
#define N60_CROSSOVER_MAX_TRANSITION_FRAMES 8192

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
    uint8_t currentChannelMask;
    uint8_t pendingChannelMask;
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

typedef struct {
    N60CrossoverSnapshot snapshot;
    N60BiquadState mainsLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState mainsRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState subMono[N60_MAX_CROSSOVER_SECTIONS];
} N60CrossoverPathRuntime;

typedef struct {
    N60CrossoverPathRuntime current;
    N60CrossoverPathRuntime pending;
    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
} N60CrossoverRuntime;

struct N60RenderKernel {
    N60SnapshotSlot slots[N60_SNAPSHOT_SLOT_COUNT];
    _Atomic uint32_t activeSlot;
    _Atomic uint64_t nextGeneration;

    N60EQBandRuntime eqRuntime[N60_MAX_EQ_RENDER_SLOTS];
    N60CrossoverRuntime crossoverRuntime;
    N60PartitionedConvolver *convolver;
    N60PartitionedConvolver *roomCorrectionConvolver;
    N60SmoothedGain inputGain;
    N60SmoothedGain headroomGain;
    N60SmoothedGain outputGain;
    N60SmoothedGain masterGain;
    N60SmoothedGain balanceGainLeft;
    N60SmoothedGain balanceGainRight;
    uint64_t preparedGeneration;
    double preparedSampleRate;
    bool preparedGraphBypassed;
    bool preparedEQBypassed;

    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t sanitizedNonFiniteSamples;
    _Atomic uint64_t flushedDenormalSamples;
    _Atomic uint64_t snapshotReadMisses;
    _Atomic uint64_t convolutionProgramMisses;
    _Atomic uint64_t roomCorrectionProgramMisses;

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
    return N60BiquadCoefficientsAreFinite(coefficients);
}

static bool coefficients_equal(N60BiquadCoefficients lhs, N60BiquadCoefficients rhs) {
    return lhs.b0 == rhs.b0
        && lhs.b1 == rhs.b1
        && lhs.b2 == rhs.b2
        && lhs.a1 == rhs.a1
        && lhs.a2 == rhs.a2;
}

static bool channel_mask_is_valid(uint8_t channelMask) {
    return channelMask != 0 && (channelMask & ~N60_EQ_CHANNEL_STEREO) == 0;
}

static bool band_snapshot_is_valid(N60BiquadBandSnapshot band, double sampleRate) {
    if (!band.enabled) return true;
    return isfinite(band.frequencyHz)
        && band.frequencyHz > 0.0
        && band.frequencyHz < sampleRate * 0.5
        && isfinite(band.gainDB)
        && isfinite(band.q)
        && band.q > 0.0
        && coefficients_are_finite(band.coefficients);
}

static bool crossover_snapshot_is_valid(N60CrossoverSnapshot crossover, double sampleRate) {
    if (!isfinite(crossover.frequencyHz)
        || crossover.frequencyHz <= 0.0
        || !isfinite(crossover.subGainLinear)
        || crossover.subGainLinear < 0.0f
        || crossover.monitorMode < N60CrossoverMonitorModeRecombined
        || crossover.monitorMode > N60CrossoverMonitorModeSubOnly) {
        return false;
    }

    if (!crossover.enabled) return true;
    if (crossover.frequencyHz >= sampleRate * 0.5
        || crossover.sectionCount == 0
        || crossover.sectionCount > N60_MAX_CROSSOVER_SECTIONS) {
        return false;
    }

    uint32_t expectedSections = crossover.topology == N60CrossoverTopologyLinkwitzRiley24 ? 2
        : crossover.topology == N60CrossoverTopologyLinkwitzRiley48 ? 4
        : 0;
    if (expectedSections == 0 || crossover.sectionCount != expectedSections) return false;

    for (uint32_t index = 0; index < crossover.sectionCount; ++index) {
        if (!coefficients_are_finite(crossover.mainsHighPass[index])
            || !coefficients_are_finite(crossover.subLowPass[index])) {
            return false;
        }
    }
    return true;
}

static bool convolution_snapshot_is_valid(N60ConvolutionGraphState convolution) {
    if (!convolution.enabled) return true;
    if (convolution.programSlot >= N60_CONVOLUTION_PROGRAM_SLOTS
        || convolution.programGeneration == 0
        || convolution.tapCount == 0
        || convolution.tapCount > N60_CONVOLUTION_MAX_TAPS
        || convolution.partitionCount == 0
        || convolution.partitionCount > N60_CONVOLUTION_MAX_PARTITIONS
        || convolution.engineLatencyFrames != N60_CONVOLUTION_PARTITION_FRAMES) {
        return false;
    }
    uint32_t expectedPartitions = (convolution.tapCount + N60_CONVOLUTION_PARTITION_FRAMES - 1u)
        / N60_CONVOLUTION_PARTITION_FRAMES;
    return convolution.partitionCount == expectedPartitions;
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
        || !isfinite(snapshot.masterGainLinear)
        || snapshot.masterGainLinear < 0.0f
        || snapshot.masterGainLinear > 1.0f
        || !isfinite(snapshot.balanceGainLeftLinear)
        || snapshot.balanceGainLeftLinear < 0.0f
        || snapshot.balanceGainLeftLinear > 1.0f
        || !isfinite(snapshot.balanceGainRightLinear)
        || snapshot.balanceGainRightLinear < 0.0f
        || snapshot.balanceGainRightLinear > 1.0f
        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS
        || !crossover_snapshot_is_valid(snapshot.crossover, snapshot.sampleRate)
        || !convolution_snapshot_is_valid(snapshot.convolution)
        || !convolution_snapshot_is_valid(snapshot.roomCorrection)) {
        return false;
    }

    for (uint32_t index = 0; index < snapshot.eqBandCount; ++index) {
        if (!band_snapshot_is_valid(snapshot.eqBands[index], snapshot.sampleRate)) return false;
        if (snapshot.eqBands[index].enabled && !channel_mask_is_valid(snapshot.eqBandChannelMasks[index])) return false;
    }
    return true;
}

static uint32_t transition_frames(double sampleRate, double seconds, uint32_t minimumFrames, uint32_t maximumFrames) {
    double requested = sampleRate * seconds;
    if (requested < (double)minimumFrames) return minimumFrames;
    if (requested > (double)maximumFrames) return maximumFrames;
    return (uint32_t)llround(requested);
}

static uint32_t eq_transition_frames_for_sample_rate(double sampleRate) {
    return transition_frames(sampleRate, N60_EQ_TRANSITION_SECONDS, N60_EQ_MIN_TRANSITION_FRAMES, N60_EQ_MAX_TRANSITION_FRAMES);
}

static uint32_t gain_transition_frames_for_sample_rate(double sampleRate) {
    return transition_frames(sampleRate, N60_GAIN_TRANSITION_SECONDS, N60_GAIN_MIN_TRANSITION_FRAMES, N60_GAIN_MAX_TRANSITION_FRAMES);
}

static uint32_t crossover_transition_frames_for_sample_rate(double sampleRate) {
    return transition_frames(sampleRate, N60_CROSSOVER_TRANSITION_SECONDS, N60_CROSSOVER_MIN_TRANSITION_FRAMES, N60_CROSSOVER_MAX_TRANSITION_FRAMES);
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
    runtime->currentChannelMask = 0;
    runtime->pendingChannelMask = 0;
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static void reset_eq_runtime(N60RenderKernel *kernel) {
    for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) reset_band_runtime(&kernel->eqRuntime[index]);
}

static void reset_smoothed_gain(N60SmoothedGain *gain, float value) {
    gain->current = value;
    gain->start = value;
    gain->target = value;
    gain->transitionFramesTotal = 0;
    gain->transitionFramesRemaining = 0;
}

static void schedule_gain_transition(N60SmoothedGain *gain, float target, uint32_t transitionFrames) {
    if (gain->target == target && gain->transitionFramesRemaining == 0) return;
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
    if (gain->transitionFramesRemaining == 0) gain->current = gain->target;
    return gain->current;
}

static void promote_pending_filter(N60EQBandRuntime *runtime) {
    if (runtime->transitionFramesRemaining == 0) return;
    runtime->currentCoefficients = runtime->pendingCoefficients;
    runtime->currentLeft = runtime->pendingLeft;
    runtime->currentRight = runtime->pendingRight;
    runtime->currentEnabled = runtime->pendingEnabled;
    runtime->currentChannelMask = runtime->pendingChannelMask;
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static void schedule_band_transition(
    N60EQBandRuntime *runtime,
    bool enabled,
    uint8_t channelMask,
    N60BiquadCoefficients coefficients,
    uint32_t transitionFrames
) {
    promote_pending_filter(runtime);
    if (runtime->currentEnabled == enabled
        && runtime->currentChannelMask == channelMask
        && (!enabled || coefficients_equal(runtime->currentCoefficients, coefficients))) {
        return;
    }
    runtime->pendingEnabled = enabled;
    runtime->pendingChannelMask = enabled ? channelMask : 0;
    runtime->pendingCoefficients = enabled ? coefficients : N60BiquadCoefficientsMakeIdentity();
    runtime->pendingLeft = runtime->currentLeft;
    runtime->pendingRight = runtime->currentRight;
    runtime->transitionFramesTotal = transitionFrames > 0 ? transitionFrames : 1;
    runtime->transitionFramesRemaining = runtime->transitionFramesTotal;
}

static void reset_crossover_path(N60CrossoverPathRuntime *path, N60CrossoverSnapshot snapshot) {
    memset(path, 0, sizeof(*path));
    path->snapshot = snapshot;
}

static void reset_crossover_runtime(N60CrossoverRuntime *runtime, N60CrossoverSnapshot snapshot) {
    reset_crossover_path(&runtime->current, snapshot);
    reset_crossover_path(&runtime->pending, snapshot);
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static bool crossover_snapshots_equal(N60CrossoverSnapshot lhs, N60CrossoverSnapshot rhs) {
    if (lhs.enabled != rhs.enabled
        || lhs.frequencyHz != rhs.frequencyHz
        || lhs.topology != rhs.topology
        || lhs.monitorMode != rhs.monitorMode
        || lhs.subGainLinear != rhs.subGainLinear
        || lhs.subPolarityInverted != rhs.subPolarityInverted
        || lhs.sectionCount != rhs.sectionCount) {
        return false;
    }
    for (uint32_t index = 0; index < lhs.sectionCount; ++index) {
        if (!coefficients_equal(lhs.mainsHighPass[index], rhs.mainsHighPass[index])
            || !coefficients_equal(lhs.subLowPass[index], rhs.subLowPass[index])) return false;
    }
    return true;
}

static void promote_pending_crossover(N60CrossoverRuntime *runtime) {
    if (runtime->transitionFramesRemaining == 0) return;
    runtime->current = runtime->pending;
    runtime->transitionFramesTotal = 0;
    runtime->transitionFramesRemaining = 0;
}

static void schedule_crossover_transition(N60CrossoverRuntime *runtime, N60CrossoverSnapshot snapshot, uint32_t transitionFrames) {
    promote_pending_crossover(runtime);
    if (crossover_snapshots_equal(runtime->current.snapshot, snapshot)) return;
    reset_crossover_path(&runtime->pending, snapshot);
    runtime->transitionFramesTotal = transitionFrames > 0 ? transitionFrames : 1;
    runtime->transitionFramesRemaining = runtime->transitionFramesTotal;
}

static void prepare_runtime_for_snapshot(N60RenderKernel *kernel, const N60DSPGraphSnapshot *snapshot) {
    if (kernel->preparedGeneration == snapshot->generation) return;

    bool firstPreparation = kernel->preparedGeneration == 0;
    bool sampleRateChanged = kernel->preparedSampleRate != 0.0 && fabs(kernel->preparedSampleRate - snapshot->sampleRate) > 0.5;
    bool leavingGraphBypass = kernel->preparedGraphBypassed && !snapshot->bypassed;
    bool leavingEQBypass = kernel->preparedEQBypassed && !snapshot->eqBypassed;

    uint32_t gainFrames = snapshot->gainTransitionFrames > 0 ? snapshot->gainTransitionFrames : gain_transition_frames_for_sample_rate(snapshot->sampleRate);
    if (firstPreparation || sampleRateChanged) {
        reset_smoothed_gain(&kernel->inputGain, snapshot->inputGainLinear);
        reset_smoothed_gain(&kernel->headroomGain, snapshot->headroomGainLinear);
        reset_smoothed_gain(&kernel->outputGain, snapshot->outputGainLinear);
        reset_smoothed_gain(&kernel->masterGain, snapshot->masterGainLinear);
        reset_smoothed_gain(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear);
        reset_smoothed_gain(&kernel->balanceGainRight, snapshot->balanceGainRightLinear);
    } else {
        schedule_gain_transition(&kernel->inputGain, snapshot->inputGainLinear, gainFrames);
        schedule_gain_transition(&kernel->headroomGain, snapshot->headroomGainLinear, gainFrames);
        schedule_gain_transition(&kernel->outputGain, snapshot->outputGainLinear, gainFrames);
        schedule_gain_transition(&kernel->masterGain, snapshot->masterGainLinear, gainFrames);
        schedule_gain_transition(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear, gainFrames);
        schedule_gain_transition(&kernel->balanceGainRight, snapshot->balanceGainRightLinear, gainFrames);
    }

    if (sampleRateChanged || leavingGraphBypass || leavingEQBypass) reset_eq_runtime(kernel);
    if (!snapshot->bypassed && !snapshot->eqBypassed) {
        uint32_t eqFrames = snapshot->eqTransitionFrames > 0 ? snapshot->eqTransitionFrames : eq_transition_frames_for_sample_rate(snapshot->sampleRate);
        for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
            bool enabled = false;
            uint8_t channelMask = 0;
            N60BiquadCoefficients coefficients = N60BiquadCoefficientsMakeIdentity();
            if (index < snapshot->eqBandCount) {
                enabled = snapshot->eqBands[index].enabled;
                channelMask = snapshot->eqBandChannelMasks[index];
                coefficients = snapshot->eqBands[index].coefficients;
            }
            schedule_band_transition(&kernel->eqRuntime[index], enabled, channelMask, coefficients, eqFrames);
        }
    } else {
        reset_eq_runtime(kernel);
    }

    if (firstPreparation || sampleRateChanged || leavingGraphBypass) {
        reset_crossover_runtime(&kernel->crossoverRuntime, snapshot->crossover);
    } else {
        uint32_t crossoverFrames = snapshot->crossoverTransitionFrames > 0
            ? snapshot->crossoverTransitionFrames
            : crossover_transition_frames_for_sample_rate(snapshot->sampleRate);
        schedule_crossover_transition(&kernel->crossoverRuntime, snapshot->crossover, crossoverFrames);
    }

    kernel->preparedGeneration = snapshot->generation;
    kernel->preparedSampleRate = snapshot->sampleRate;
    kernel->preparedGraphBypassed = snapshot->bypassed;
    kernel->preparedEQBypassed = snapshot->eqBypassed;
}

static float process_eq_band(N60EQBandRuntime *runtime, float input, uint8_t channelBit) {
    bool leftChannel = channelBit == N60_EQ_CHANNEL_LEFT;
    N60BiquadState *currentState = leftChannel ? &runtime->currentLeft : &runtime->currentRight;
    N60BiquadState *pendingState = leftChannel ? &runtime->pendingLeft : &runtime->pendingRight;
    bool currentApplies = runtime->currentEnabled && (runtime->currentChannelMask & channelBit) != 0;
    bool pendingApplies = runtime->pendingEnabled && (runtime->pendingChannelMask & channelBit) != 0;
    float currentOutput = currentApplies ? N60BiquadProcessSample(runtime->currentCoefficients, currentState, input) : input;
    if (runtime->transitionFramesRemaining == 0) return currentOutput;
    float pendingOutput = pendingApplies ? N60BiquadProcessSample(runtime->pendingCoefficients, pendingState, input) : input;
    uint32_t completed = runtime->transitionFramesTotal - runtime->transitionFramesRemaining + 1;
    float mix = (float)completed / (float)runtime->transitionFramesTotal;
    return currentOutput + (pendingOutput - currentOutput) * mix;
}

static void advance_eq_transitions(N60RenderKernel *kernel) {
    for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
        N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
        if (runtime->transitionFramesRemaining == 0) continue;
        runtime->transitionFramesRemaining -= 1;
        if (runtime->transitionFramesRemaining == 0) {
            runtime->currentCoefficients = runtime->pendingCoefficients;
            runtime->currentLeft = runtime->pendingLeft;
            runtime->currentRight = runtime->pendingRight;
            runtime->currentEnabled = runtime->pendingEnabled;
            runtime->currentChannelMask = runtime->pendingChannelMask;
            runtime->transitionFramesTotal = 0;
            if (!runtime->currentEnabled || (runtime->currentChannelMask & N60_EQ_CHANNEL_LEFT) == 0) clear_state(&runtime->currentLeft);
            if (!runtime->currentEnabled || (runtime->currentChannelMask & N60_EQ_CHANNEL_RIGHT) == 0) clear_state(&runtime->currentRight);
        }
    }
}

static void process_crossover_path(
    N60CrossoverPathRuntime *path,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (!path->snapshot.enabled) {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
        return;
    }

    float mainsLeft = inputLeft;
    float mainsRight = inputRight;
    float subMono = (inputLeft + inputRight) * 0.5f;
    for (uint32_t index = 0; index < path->snapshot.sectionCount; ++index) {
        mainsLeft = N60BiquadProcessSample(path->snapshot.mainsHighPass[index], &path->mainsLeft[index], mainsLeft);
        mainsRight = N60BiquadProcessSample(path->snapshot.mainsHighPass[index], &path->mainsRight[index], mainsRight);
        subMono = N60BiquadProcessSample(path->snapshot.subLowPass[index], &path->subMono[index], subMono);
    }
    subMono *= path->snapshot.subGainLinear;
    if (path->snapshot.subPolarityInverted) subMono = -subMono;

    switch (path->snapshot.monitorMode) {
    case N60CrossoverMonitorModeMainsOnly:
        *outputLeft = mainsLeft;
        *outputRight = mainsRight;
        break;
    case N60CrossoverMonitorModeSubOnly:
        *outputLeft = subMono;
        *outputRight = subMono;
        break;
    case N60CrossoverMonitorModeRecombined:
    default:
        *outputLeft = mainsLeft + subMono;
        *outputRight = mainsRight + subMono;
        break;
    }
}

static void process_crossover(N60CrossoverRuntime *runtime, float inputLeft, float inputRight, float *outputLeft, float *outputRight) {
    float currentLeft = inputLeft;
    float currentRight = inputRight;
    process_crossover_path(&runtime->current, inputLeft, inputRight, &currentLeft, &currentRight);
    if (runtime->transitionFramesRemaining == 0) {
        *outputLeft = currentLeft;
        *outputRight = currentRight;
        return;
    }

    float pendingLeft = inputLeft;
    float pendingRight = inputRight;
    process_crossover_path(&runtime->pending, inputLeft, inputRight, &pendingLeft, &pendingRight);
    uint32_t completed = runtime->transitionFramesTotal - runtime->transitionFramesRemaining + 1;
    float mix = (float)completed / (float)runtime->transitionFramesTotal;
    *outputLeft = currentLeft + (pendingLeft - currentLeft) * mix;
    *outputRight = currentRight + (pendingRight - currentRight) * mix;

    runtime->transitionFramesRemaining -= 1;
    if (runtime->transitionFramesRemaining == 0) {
        runtime->current = runtime->pending;
        runtime->transitionFramesTotal = 0;
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

static void meter_sample(float left, float right, float *peakLeft, float *peakRight, double *squareSumLeft, double *squareSumRight, uint64_t *overRangeSamples) {
    float absLeft = fabsf(left);
    float absRight = fabsf(right);
    if (absLeft > *peakLeft) *peakLeft = absLeft;
    if (absRight > *peakRight) *peakRight = absRight;
    *squareSumLeft += (double)left * (double)left;
    *squareSumRight += (double)right * (double)right;
    if (absLeft > 1.0f) *overRangeSamples += 1;
    if (absRight > 1.0f) *overRangeSamples += 1;
}

static void publish_meter(_Atomic uint32_t *peakLeftBits, _Atomic uint32_t *peakRightBits, _Atomic uint32_t *rmsLeftBits, _Atomic uint32_t *rmsRightBits, _Atomic uint64_t *overRangeSamples, float peakLeft, float peakRight, double squareSumLeft, double squareSumRight, uint64_t overRangeCount, uint32_t frameCount) {
    if (frameCount == 0) return;
    float rmsLeft = (float)sqrt(squareSumLeft / (double)frameCount);
    float rmsRight = (float)sqrt(squareSumRight / (double)frameCount);
    atomic_store_explicit(peakLeftBits, float_to_bits(peakLeft), memory_order_relaxed);
    atomic_store_explicit(peakRightBits, float_to_bits(peakRight), memory_order_relaxed);
    atomic_store_explicit(rmsLeftBits, float_to_bits(rmsLeft), memory_order_relaxed);
    atomic_store_explicit(rmsRightBits, float_to_bits(rmsRight), memory_order_relaxed);
    atomic_fetch_add_explicit(overRangeSamples, overRangeCount, memory_order_relaxed);
}

static N60RenderKernelRenderContext acquire_render_context(N60RenderKernel *kernel) {
    N60RenderKernelRenderContext context = {0};
    if (kernel == NULL) return context;
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

static uint64_t convolution_state_latency(N60ConvolutionGraphState state) {
    return state.enabled
        ? (uint64_t)state.engineLatencyFrames + state.declaredLatencyFrames
        : 0;
}

static bool set_convolution_graph_state(
    N60DSPGraphSnapshot *snapshot,
    N60ConvolutionGraphState *stateDestination,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
) {
    if (snapshot == NULL || stateDestination == NULL) return false;

    uint64_t previousLatency = convolution_state_latency(*stateDestination);
    uint64_t baseLatency = snapshot->latencyFrames >= previousLatency
        ? (uint64_t)snapshot->latencyFrames - previousLatency
        : 0;

    N60ConvolutionGraphState state = {0};
    state.enabled = enabled;
    state.programSlot = programSlot;
    state.programGeneration = programInfo.generation;
    state.tapCount = programInfo.tapCount;
    state.partitionCount = programInfo.partitionCount;
    state.engineLatencyFrames = programInfo.engineLatencyFrames;
    state.declaredLatencyFrames = programInfo.declaredLatencyFrames;

    if (enabled && (!programInfo.prepared
        || programSlot >= N60_CONVOLUTION_PROGRAM_SLOTS
        || programInfo.generation == 0
        || programInfo.tapCount == 0
        || programInfo.engineLatencyFrames != N60_CONVOLUTION_PARTITION_FRAMES)) {
        return false;
    }

    uint64_t newLatency = enabled
        ? (uint64_t)programInfo.engineLatencyFrames + programInfo.declaredLatencyFrames
        : 0;
    if (baseLatency + newLatency > UINT32_MAX) return false;
    *stateDestination = state;
    snapshot->latencyFrames = (uint32_t)(baseLatency + newLatency);
    return true;
}

static bool prepared_program_matches_graph_state(
    const N60PartitionedConvolver *convolver,
    N60ConvolutionGraphState state
) {
    if (!state.enabled) return true;
    if (convolver == NULL
        || !N60PartitionedConvolverProgramMatches(convolver, state.programSlot, state.programGeneration)) {
        return false;
    }
    N60ConvolutionProgramInfo info = N60PartitionedConvolverProgramInfo(convolver, state.programSlot);
    return info.tapCount == state.tapCount
        && info.partitionCount == state.partitionCount
        && info.engineLatencyFrames == state.engineLatencyFrames
        && info.declaredLatencyFrames == state.declaredLatencyFrames;
}

static bool prepare_program(
    N60PartitionedConvolver *convolver,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (convolver == NULL) return false;
    uint64_t generation = 0;
    if (!N60PartitionedConvolverPrepareProgram(
            convolver,
            slot,
            leftTaps,
            rightTaps,
            tapCount,
            declaredLatencyFrames,
            &generation)) {
        return false;
    }
    N60ConvolutionProgramInfo info = N60PartitionedConvolverProgramInfo(convolver, slot);
    if (info.generation != generation) return false;
    if (programInfoOut != NULL) *programInfoOut = info;
    return true;
}

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate) {
    N60DSPGraphSnapshot snapshot = {0};
    snapshot.sampleRate = sampleRate;
    snapshot.channelCount = 2;
    snapshot.inputGainLinear = 1.0f;
    snapshot.headroomGainLinear = 1.0f;
    snapshot.outputGainLinear = 1.0f;
    snapshot.masterGainLinear = 1.0f;
    snapshot.balanceGainLeftLinear = 1.0f;
    snapshot.balanceGainRightLinear = 1.0f;
    snapshot.bypassed = false;
    snapshot.latencyFrames = 0;
    snapshot.generation = 0;
    snapshot.gainTransitionFrames = gain_transition_frames_for_sample_rate(sampleRate);
    snapshot.eqBypassed = false;
    snapshot.eqBandCount = 0;
    snapshot.eqTransitionFrames = eq_transition_frames_for_sample_rate(sampleRate);
    snapshot.crossoverTransitionFrames = crossover_transition_frames_for_sample_rate(sampleRate);
    snapshot.crossover = N60CrossoverSnapshotMakeBypassed();
    snapshot.convolution.enabled = false;
    snapshot.convolution.programSlot = N60_CONVOLUTION_NO_PROGRAM;
    snapshot.roomCorrection.enabled = false;
    snapshot.roomCorrection.programSlot = N60_CONVOLUTION_NO_PROGRAM;
    return snapshot;
}

void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {
    if (snapshot == NULL) return;
    memset(snapshot->eqBands, 0, sizeof(snapshot->eqBands));
    memset(snapshot->eqBandChannelMasks, 0, sizeof(snapshot->eqBandChannelMasks));
    snapshot->eqBandCount = 0;
}

bool N60DSPGraphSnapshotSetEQBandForChannels(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (snapshot == NULL || bandIndex >= N60_MAX_EQ_RENDER_SLOTS) return false;
    if (enabled && !channel_mask_is_valid(channelMask)) return false;
    N60BiquadBandSnapshot band = {0};
    if (!N60BiquadBandSnapshotMake(type, snapshot->sampleRate, frequencyHz, gainDB, q, enabled, &band)) return false;
    snapshot->eqBands[bandIndex] = band;
    snapshot->eqBandChannelMasks[bandIndex] = enabled ? channelMask : 0;
    if (snapshot->eqBandCount <= bandIndex) snapshot->eqBandCount = bandIndex + 1;
    return true;
}

bool N60DSPGraphSnapshotSetEQBand(N60DSPGraphSnapshot *snapshot, uint32_t bandIndex, N60BiquadFilterType type, double frequencyHz, double gainDB, double q, bool enabled) {
    return N60DSPGraphSnapshotSetEQBandForChannels(
        snapshot,
        bandIndex,
        N60_EQ_CHANNEL_STEREO,
        type,
        frequencyHz,
        gainDB,
        q,
        enabled
    );
}

bool N60DSPGraphSnapshotSetCrossover(N60DSPGraphSnapshot *snapshot, double frequencyHz, N60CrossoverTopology topology, N60CrossoverMonitorMode monitorMode, float subGainLinear, bool subPolarityInverted, bool enabled) {
    if (snapshot == NULL) return false;
    N60CrossoverSnapshot crossover = {0};
    if (!N60CrossoverSnapshotMake(snapshot->sampleRate, frequencyHz, topology, monitorMode, subGainLinear, subPolarityInverted, enabled, &crossover)) return false;
    snapshot->crossover = crossover;
    return true;
}

bool N60DSPGraphSnapshotSetConvolutionProgram(
    N60DSPGraphSnapshot *snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
) {
    if (snapshot == NULL) return false;
    return set_convolution_graph_state(
        snapshot,
        &snapshot->convolution,
        programSlot,
        programInfo,
        enabled
    );
}

bool N60DSPGraphSnapshotSetRoomCorrectionProgram(
    N60DSPGraphSnapshot *snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
) {
    if (snapshot == NULL) return false;
    return set_convolution_graph_state(
        snapshot,
        &snapshot->roomCorrection,
        programSlot,
        programInfo,
        enabled
    );
}

N60RenderKernel *N60RenderKernelCreate(void) {
    N60RenderKernel *kernel = calloc(1, sizeof(N60RenderKernel));
    if (kernel == NULL) return NULL;
    kernel->convolver = N60PartitionedConvolverCreate();
    if (kernel->convolver == NULL) {
        free(kernel);
        return NULL;
    }
    kernel->roomCorrectionConvolver = N60PartitionedConvolverCreate();
    if (kernel->roomCorrectionConvolver == NULL) {
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
    initial.generation = 1;
    kernel->slots[0].snapshot = initial;
    kernel->slots[1].snapshot = initial;
    atomic_store_explicit(&kernel->activeSlot, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->nextGeneration, 1, memory_order_relaxed);
    reset_eq_runtime(kernel);
    reset_crossover_runtime(&kernel->crossoverRuntime, initial.crossover);
    reset_smoothed_gain(&kernel->inputGain, 1.0f);
    reset_smoothed_gain(&kernel->headroomGain, 1.0f);
    reset_smoothed_gain(&kernel->outputGain, 1.0f);
    reset_smoothed_gain(&kernel->masterGain, 1.0f);
    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);
    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);
    return kernel;
}

void N60RenderKernelDestroy(N60RenderKernel *kernel) {
    if (kernel == NULL) return;
    N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
    N60PartitionedConvolverDestroy(kernel->convolver);
    free(kernel);
}

void N60RenderKernelReset(N60RenderKernel *kernel) {
    if (kernel == NULL) return;
    reset_eq_runtime(kernel);
    reset_crossover_runtime(&kernel->crossoverRuntime, N60CrossoverSnapshotMakeBypassed());
    N60PartitionedConvolverReset(kernel->convolver);
    N60PartitionedConvolverReset(kernel->roomCorrectionConvolver);
    reset_smoothed_gain(&kernel->inputGain, 1.0f);
    reset_smoothed_gain(&kernel->headroomGain, 1.0f);
    reset_smoothed_gain(&kernel->outputGain, 1.0f);
    reset_smoothed_gain(&kernel->masterGain, 1.0f);
    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);
    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);
    kernel->preparedGeneration = 0;
    kernel->preparedSampleRate = 0.0;
    kernel->preparedGraphBypassed = false;
    kernel->preparedEQBypassed = false;
    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->sanitizedNonFiniteSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->flushedDenormalSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->snapshotReadMisses, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->convolutionProgramMisses, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->roomCorrectionProgramMisses, 0, memory_order_relaxed);
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

bool N60RenderKernelPrepareConvolutionProgram(
    N60RenderKernel *kernel,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (kernel == NULL) return false;
    return prepare_program(
        kernel->convolver,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}

bool N60RenderKernelPrepareRoomCorrectionProgram(
    N60RenderKernel *kernel,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (kernel == NULL) return false;
    return prepare_program(
        kernel->roomCorrectionConvolver,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}

bool N60RenderKernelPublishSnapshot(N60RenderKernel *kernel, N60DSPGraphSnapshot snapshot) {
    if (kernel == NULL || !snapshot_is_valid(snapshot)) return false;
    if (!prepared_program_matches_graph_state(kernel->convolver, snapshot.convolution)
        || !prepared_program_matches_graph_state(kernel->roomCorrectionConvolver, snapshot.roomCorrection)) {
        return false;
    }
    uint32_t active = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
    uint32_t inactive = active == 0 ? 1 : 0;
    N60SnapshotSlot *slot = &kernel->slots[inactive];
    while (atomic_load_explicit(&slot->readers, memory_order_acquire) != 0) sched_yield();
    snapshot.generation = atomic_fetch_add_explicit(&kernel->nextGeneration, 1, memory_order_relaxed) + 1;
    slot->snapshot = snapshot;
    atomic_store_explicit(&kernel->activeSlot, inactive, memory_order_release);
    return true;
}

N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel *kernel) {
    N60RenderKernelRenderContext context = acquire_render_context(kernel);
    if (context.acquired) prepare_runtime_for_snapshot(kernel, &context.snapshot);
    return context;
}

void N60RenderKernelProcessStereoFrameInContext(N60RenderKernel *kernel, N60RenderKernelRenderContext *context, float inputLeft, float inputRight, float *outputLeft, float *outputRight) {
    if (kernel == NULL || context == NULL || outputLeft == NULL || outputRight == NULL) return;

    float left = sanitize_sample(kernel, inputLeft);
    float right = sanitize_sample(kernel, inputRight);
    meter_sample(left, right, &context->inputPeakLeft, &context->inputPeakRight, &context->inputSquareSumLeft, &context->inputSquareSumRight, &context->inputOverRangeSamples);

    if (context->acquired && !context->snapshot.bypassed) {
        float inputGain = next_gain_value(&kernel->inputGain);
        float headroomGain = next_gain_value(&kernel->headroomGain);
        left *= inputGain * headroomGain;
        right *= inputGain * headroomGain;

        if (!context->snapshot.eqBypassed) {
            for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) continue;
                left = process_eq_band(runtime, left, N60_EQ_CHANNEL_LEFT);
                right = process_eq_band(runtime, right, N60_EQ_CHANNEL_RIGHT);
            }
            advance_eq_transitions(kernel);
        }

        if (context->snapshot.convolution.enabled) {
            float convolvedLeft = left;
            float convolvedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->convolver,
                    context->snapshot.convolution.programSlot,
                    context->snapshot.convolution.programGeneration,
                    left,
                    right,
                    &convolvedLeft,
                    &convolvedRight)) {
                left = convolvedLeft;
                right = convolvedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->convolutionProgramMisses, 1, memory_order_relaxed);
            }
        }

        meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);
        process_crossover(&kernel->crossoverRuntime, left, right, &left, &right);

        if (context->snapshot.roomCorrection.enabled) {
            float correctedLeft = left;
            float correctedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->roomCorrectionConvolver,
                    context->snapshot.roomCorrection.programSlot,
                    context->snapshot.roomCorrection.programGeneration,
                    left,
                    right,
                    &correctedLeft,
                    &correctedRight)) {
                left = correctedLeft;
                right = correctedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->roomCorrectionProgramMisses, 1, memory_order_relaxed);
            }
        }

        left *= next_gain_value(&kernel->balanceGainLeft);
        right *= next_gain_value(&kernel->balanceGainRight);
        float outputGain = next_gain_value(&kernel->outputGain);
        float masterGain = next_gain_value(&kernel->masterGain);
        left *= outputGain * masterGain;
        right *= outputGain * masterGain;
    } else {
        meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);
    }

    left = sanitize_sample(kernel, left);
    right = sanitize_sample(kernel, right);
    meter_sample(left, right, &context->outputPeakLeft, &context->outputPeakRight, &context->outputSquareSumLeft, &context->outputSquareSumRight, &context->outputOverRangeSamples);
    context->meteredFrames += 1;
    *outputLeft = left;
    *outputRight = right;
}

void N60RenderKernelEndRender(N60RenderKernel *kernel, N60RenderKernelRenderContext *context, uint32_t renderedFrames) {
    if (kernel == NULL || context == NULL) return;
    publish_meter(&kernel->inputPeakLeftBits, &kernel->inputPeakRightBits, &kernel->inputRMSLeftBits, &kernel->inputRMSRightBits, &kernel->inputOverRangeSamples, context->inputPeakLeft, context->inputPeakRight, context->inputSquareSumLeft, context->inputSquareSumRight, context->inputOverRangeSamples, context->meteredFrames);
    publish_meter(&kernel->postEQPeakLeftBits, &kernel->postEQPeakRightBits, &kernel->postEQRMSLeftBits, &kernel->postEQRMSRightBits, &kernel->postEQOverRangeSamples, context->postEQPeakLeft, context->postEQPeakRight, context->postEQSquareSumLeft, context->postEQSquareSumRight, context->postEQOverRangeSamples, context->meteredFrames);
    publish_meter(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples, context->outputPeakLeft, context->outputPeakRight, context->outputSquareSumLeft, context->outputSquareSumRight, context->outputOverRangeSamples, context->meteredFrames);
    if (context->acquired && context->slotIndex < N60_SNAPSHOT_SLOT_COUNT) {
        atomic_fetch_sub_explicit(&kernel->slots[context->slotIndex].readers, 1, memory_order_release);
        context->acquired = false;
    }
    atomic_fetch_add_explicit(&kernel->renderedFrames, renderedFrames, memory_order_relaxed);
}

void N60RenderKernelProcessStereoFrame(N60RenderKernel *kernel, float inputLeft, float inputRight, float *outputLeft, float *outputRight) {
    if (kernel == NULL || outputLeft == NULL || outputRight == NULL) return;
    N60RenderKernelRenderContext context = N60RenderKernelBeginRender(kernel);
    N60RenderKernelProcessStereoFrameInContext(kernel, &context, inputLeft, inputRight, outputLeft, outputRight);
    N60RenderKernelEndRender(kernel, &context, 1);
}

static N60StereoMeterReading load_meter_reading(const _Atomic uint32_t *peakLeftBits, const _Atomic uint32_t *peakRightBits, const _Atomic uint32_t *rmsLeftBits, const _Atomic uint32_t *rmsRightBits, const _Atomic uint64_t *overRangeSamples) {
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
    if (kernel == NULL) return diagnostics;

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
        diagnostics.masterGainLinear = context.snapshot.masterGainLinear;
        diagnostics.balanceGainLeftLinear = context.snapshot.balanceGainLeftLinear;
        diagnostics.balanceGainRightLinear = context.snapshot.balanceGainRightLinear;
        diagnostics.eqBypassed = context.snapshot.eqBypassed;
        diagnostics.eqBandCount = context.snapshot.eqBandCount;
        for (uint32_t index = 0; index < context.snapshot.eqBandCount; ++index) {
            if (!context.snapshot.eqBands[index].enabled) continue;
            uint8_t mask = context.snapshot.eqBandChannelMasks[index];
            if ((mask & N60_EQ_CHANNEL_LEFT) != 0) diagnostics.eqLeftBandCount += 1;
            if ((mask & N60_EQ_CHANNEL_RIGHT) != 0) diagnostics.eqRightBandCount += 1;
        }
        diagnostics.crossoverEnabled = context.snapshot.crossover.enabled;
        diagnostics.crossoverFrequencyHz = context.snapshot.crossover.frequencyHz;
        diagnostics.crossoverTopology = context.snapshot.crossover.topology;
        diagnostics.crossoverMonitorMode = context.snapshot.crossover.monitorMode;
        diagnostics.crossoverSubGainLinear = context.snapshot.crossover.subGainLinear;
        diagnostics.crossoverSubPolarityInverted = context.snapshot.crossover.subPolarityInverted;
        diagnostics.crossoverSectionCount = context.snapshot.crossover.sectionCount;
        diagnostics.convolutionEnabled = context.snapshot.convolution.enabled;
        diagnostics.convolutionProgramSlot = context.snapshot.convolution.programSlot;
        diagnostics.convolutionProgramGeneration = context.snapshot.convolution.programGeneration;
        diagnostics.convolutionTapCount = context.snapshot.convolution.tapCount;
        diagnostics.convolutionPartitionCount = context.snapshot.convolution.partitionCount;
        diagnostics.convolutionEngineLatencyFrames = context.snapshot.convolution.engineLatencyFrames;
        diagnostics.convolutionDeclaredLatencyFrames = context.snapshot.convolution.declaredLatencyFrames;
        diagnostics.roomCorrectionEnabled = context.snapshot.roomCorrection.enabled;
        diagnostics.roomCorrectionProgramSlot = context.snapshot.roomCorrection.programSlot;
        diagnostics.roomCorrectionProgramGeneration = context.snapshot.roomCorrection.programGeneration;
        diagnostics.roomCorrectionTapCount = context.snapshot.roomCorrection.tapCount;
        diagnostics.roomCorrectionPartitionCount = context.snapshot.roomCorrection.partitionCount;
        diagnostics.roomCorrectionEngineLatencyFrames = context.snapshot.roomCorrection.engineLatencyFrames;
        diagnostics.roomCorrectionDeclaredLatencyFrames = context.snapshot.roomCorrection.declaredLatencyFrames;
        N60RenderKernelEndRender(mutableKernel, &context, 0);
    }

    diagnostics.renderedFrames = atomic_load_explicit(&kernel->renderedFrames, memory_order_relaxed);
    diagnostics.sanitizedNonFiniteSamples = atomic_load_explicit(&kernel->sanitizedNonFiniteSamples, memory_order_relaxed);
    diagnostics.flushedDenormalSamples = atomic_load_explicit(&kernel->flushedDenormalSamples, memory_order_relaxed);
    diagnostics.snapshotReadMisses = atomic_load_explicit(&kernel->snapshotReadMisses, memory_order_relaxed);
    diagnostics.convolutionProgramMisses = atomic_load_explicit(&kernel->convolutionProgramMisses, memory_order_relaxed);
    diagnostics.roomCorrectionProgramMisses = atomic_load_explicit(&kernel->roomCorrectionProgramMisses, memory_order_relaxed);
    diagnostics.inputMeter = load_meter_reading(&kernel->inputPeakLeftBits, &kernel->inputPeakRightBits, &kernel->inputRMSLeftBits, &kernel->inputRMSRightBits, &kernel->inputOverRangeSamples);
    diagnostics.postEQMeter = load_meter_reading(&kernel->postEQPeakLeftBits, &kernel->postEQPeakRightBits, &kernel->postEQRMSLeftBits, &kernel->postEQRMSRightBits, &kernel->postEQOverRangeSamples);
    diagnostics.outputMeter = load_meter_reading(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples);
    return diagnostics;
}
