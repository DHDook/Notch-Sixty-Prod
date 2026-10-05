#include "N60AdaptiveSampleRate.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_PI 3.14159265358979323846264338327950288
#define N60_ASRC_KAISER_BETA 10.0
#define N60_ASRC_NYQUIST_FRACTION 0.95

struct N60AdaptiveSRC {
    N60AdaptiveSRCConfiguration configuration;
    float *ring;
    float *phaseTable;
    uint32_t tablePhaseStride;
    double nominalStep;
    double sourcePosition;
    N60AdaptiveClockController clockController;

    _Atomic uint64_t writeIndex;
    _Atomic uint64_t reclaimIndex;
    // Consumer publishes the integer source position so the producer can
    // publish startup fill safely without reading consumer-owned doubles.
    _Atomic uint64_t sourceBaseIndex;
    _Atomic uint64_t pushedInputFrames;
    _Atomic uint64_t producedOutputFrames;
    _Atomic uint64_t droppedInputFrames;
    _Atomic uint64_t starvedOutputFrames;

    _Atomic uint64_t effectiveStepBits;
    _Atomic uint64_t correctionPPMBits;
    _Atomic uint64_t normalizedErrorBits;
    _Atomic uint32_t bufferedFrames;
    _Atomic uint64_t controllerSaturationEvents;
};

static double clamp_double(double value, double lower, double upper) {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

static uint64_t double_to_bits(double value) {
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static double bits_to_double(uint64_t bits) {
    double value = 0.0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static double bessel_i0(double value) {
    // Stable power-series evaluation. This is used only while the control plane
    // prepares the immutable Kaiser-window coefficient table.
    double sum = 1.0;
    double term = 1.0;
    double y = value * value * 0.25;
    for (uint32_t k = 1; k <= 40u; ++k) {
        double kd = (double)k;
        term *= y / (kd * kd);
        sum += term;
        if (term <= sum * 1.0e-16) break;
    }
    return sum;
}

static double normalized_sinc(double value) {
    if (fabs(value) < 1.0e-12) return 1.0;
    double angle = N60_PI * value;
    return sin(angle) / angle;
}

static bool finite_positive(double value) {
    return isfinite(value) && value > 0.0;
}

N60AdaptiveClockPolicy N60AdaptiveClockPolicyMakeDefault(double targetBufferedFrames) {
    return (N60AdaptiveClockPolicy){
        .targetBufferedFrames = targetBufferedFrames,
        .proportionalGainPPM = 300.0,
        .integralGainPPMPerSecond = 90.0,
        .maximumCorrectionPPM = 1000.0,
        .slewLimitPPMPerSecond = 120.0,
    };
}

static bool clock_policy_is_valid(N60AdaptiveClockPolicy policy) {
    return finite_positive(policy.targetBufferedFrames)
        && isfinite(policy.proportionalGainPPM) && policy.proportionalGainPPM >= 0.0
        && isfinite(policy.integralGainPPMPerSecond) && policy.integralGainPPMPerSecond >= 0.0
        && finite_positive(policy.maximumCorrectionPPM)
        && finite_positive(policy.slewLimitPPMPerSecond);
}

bool N60AdaptiveClockControllerConfigure(
    N60AdaptiveClockController *controller,
    N60AdaptiveClockPolicy policy
) {
    if (controller == NULL || !clock_policy_is_valid(policy)) return false;
    *controller = (N60AdaptiveClockController){0};
    controller->policy = policy;
    return true;
}

void N60AdaptiveClockControllerReset(N60AdaptiveClockController *controller) {
    if (controller == NULL) return;
    N60AdaptiveClockPolicy policy = controller->policy;
    *controller = (N60AdaptiveClockController){0};
    controller->policy = policy;
}

double N60AdaptiveClockControllerUpdate(
    N60AdaptiveClockController *controller,
    double actualBufferedFrames,
    double elapsedSeconds
) {
    if (controller == NULL || !clock_policy_is_valid(controller->policy)
        || !isfinite(actualBufferedFrames) || actualBufferedFrames < 0.0
        || !finite_positive(elapsedSeconds)) {
        return controller != NULL ? controller->correctionPPM : 0.0;
    }

    const N60AdaptiveClockPolicy policy = controller->policy;
    double error = (actualBufferedFrames - policy.targetBufferedFrames)
        / policy.targetBufferedFrames;
    error = clamp_double(error, -2.0, 2.0);
    controller->lastNormalizedError = error;

    controller->integralPPM += policy.integralGainPPMPerSecond * error * elapsedSeconds;
    controller->integralPPM = clamp_double(
        controller->integralPPM,
        -policy.maximumCorrectionPPM,
        policy.maximumCorrectionPPM
    );

    double proportional = policy.proportionalGainPPM * error;
    double desired = proportional + controller->integralPPM;
    double clampedDesired = clamp_double(
        desired,
        -policy.maximumCorrectionPPM,
        policy.maximumCorrectionPPM
    );
    if (clampedDesired != desired) {
        // Back-calculate the integral term at saturation so a long excursion
        // cannot wind the controller up and cause a slow recovery later.
        controller->saturationEvents += 1u;
        controller->integralPPM = clamp_double(
            clampedDesired - proportional,
            -policy.maximumCorrectionPPM,
            policy.maximumCorrectionPPM
        );
    }

    double maxDelta = policy.slewLimitPPMPerSecond * elapsedSeconds;
    double delta = clamp_double(
        clampedDesired - controller->correctionPPM,
        -maxDelta,
        maxDelta
    );
    controller->correctionPPM += delta;
    controller->correctionPPM = clamp_double(
        controller->correctionPPM,
        -policy.maximumCorrectionPPM,
        policy.maximumCorrectionPPM
    );
    return controller->correctionPPM;
}

N60AdaptiveSRCConfiguration N60AdaptiveSRCConfigurationMakeDefault(
    double inputSampleRate,
    double outputSampleRate,
    uint32_t channelCount,
    uint32_t capacityFrames,
    uint32_t targetBufferedFrames
) {
    N60AdaptiveClockPolicy policy = N60AdaptiveClockPolicyMakeDefault((double)targetBufferedFrames);
    return (N60AdaptiveSRCConfiguration){
        .inputSampleRate = inputSampleRate,
        .outputSampleRate = outputSampleRate,
        .channelCount = channelCount,
        .capacityFrames = capacityFrames,
        .targetBufferedFrames = targetBufferedFrames,
        .tapCount = N60_ADAPTIVE_SRC_DEFAULT_TAPS,
        .phaseCount = N60_ADAPTIVE_SRC_DEFAULT_PHASES,
        .maximumCorrectionPPM = policy.maximumCorrectionPPM,
        .proportionalGainPPM = policy.proportionalGainPPM,
        .integralGainPPMPerSecond = policy.integralGainPPMPerSecond,
        .slewLimitPPMPerSecond = policy.slewLimitPPMPerSecond,
    };
}

bool N60AdaptiveSRCConfigurationIsValid(N60AdaptiveSRCConfiguration configuration) {
    if (!finite_positive(configuration.inputSampleRate)
        || !finite_positive(configuration.outputSampleRate)
        || configuration.channelCount == 0u
        || configuration.channelCount > N60_ADAPTIVE_SRC_MAX_CHANNELS
        || configuration.capacityFrames < 256u
        || configuration.targetBufferedFrames == 0u
        || configuration.targetBufferedFrames >= configuration.capacityFrames
        || configuration.tapCount < 16u
        || configuration.tapCount > N60_ADAPTIVE_SRC_MAX_TAPS
        || (configuration.tapCount & 1u) != 0u
        || configuration.phaseCount < 64u
        || configuration.phaseCount > N60_ADAPTIVE_SRC_MAX_PHASES
        || !finite_positive(configuration.maximumCorrectionPPM)
        || configuration.maximumCorrectionPPM > 5000.0
        || !isfinite(configuration.proportionalGainPPM)
        || configuration.proportionalGainPPM < 0.0
        || !isfinite(configuration.integralGainPPMPerSecond)
        || configuration.integralGainPPMPerSecond < 0.0
        || !finite_positive(configuration.slewLimitPPMPerSecond)) {
        return false;
    }
    uint32_t minimumHeadroom = configuration.tapCount * 2u;
    return configuration.capacityFrames > configuration.targetBufferedFrames + minimumHeadroom;
}

static bool build_phase_table(N60AdaptiveSRC *src) {
    const N60AdaptiveSRCConfiguration configuration = src->configuration;
    const uint32_t taps = configuration.tapCount;
    const uint32_t phases = configuration.phaseCount;
    const uint32_t half = taps / 2u;
    const double outOverIn = configuration.outputSampleRate / configuration.inputSampleRate;
    const double cutoff = N60_ASRC_NYQUIST_FRACTION * (outOverIn < 1.0 ? outOverIn : 1.0);
    const double i0Beta = bessel_i0(N60_ASRC_KAISER_BETA);

    for (uint32_t phase = 0u; phase <= phases; ++phase) {
        double fraction = (double)phase / (double)phases;
        double sum = 0.0;
        float *row = src->phaseTable + (size_t)phase * src->tablePhaseStride;
        for (uint32_t tap = 0u; tap < taps; ++tap) {
            int32_t offset = (int32_t)tap - ((int32_t)half - 1);
            double distance = (double)offset - fraction;
            double normalizedDistance = distance / (double)half;
            double window = 0.0;
            if (fabs(normalizedDistance) <= 1.0) {
                double radial = 1.0 - normalizedDistance * normalizedDistance;
                if (radial < 0.0) radial = 0.0;
                window = bessel_i0(N60_ASRC_KAISER_BETA * sqrt(radial)) / i0Beta;
            }
            double coefficient = cutoff * normalized_sinc(cutoff * distance) * window;
            row[tap] = (float)coefficient;
            sum += coefficient;
        }
        if (!isfinite(sum) || fabs(sum) < 1.0e-12) return false;
        double inverse = 1.0 / sum;
        for (uint32_t tap = 0u; tap < taps; ++tap) {
            row[tap] = (float)((double)row[tap] * inverse);
        }
    }
    return true;
}

static uint32_t current_buffered_frames(const N60AdaptiveSRC *src, uint64_t writeIndex) {
    uint64_t base = atomic_load_explicit(&src->sourceBaseIndex, memory_order_acquire);
    uint64_t buffered64 = writeIndex > base ? writeIndex - base : 0u;
    return buffered64 > UINT32_MAX ? UINT32_MAX : (uint32_t)buffered64;
}

static void publish_runtime_snapshot(N60AdaptiveSRC *src, uint64_t writeIndex) {
    atomic_store_explicit(
        &src->bufferedFrames,
        current_buffered_frames(src, writeIndex),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &src->effectiveStepBits,
        double_to_bits(src->nominalStep * (1.0 + src->clockController.correctionPPM * 1.0e-6)),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &src->correctionPPMBits,
        double_to_bits(src->clockController.correctionPPM),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &src->normalizedErrorBits,
        double_to_bits(src->clockController.lastNormalizedError),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &src->controllerSaturationEvents,
        src->clockController.saturationEvents,
        memory_order_relaxed
    );
}

N60AdaptiveSRC *N60AdaptiveSRCCreate(N60AdaptiveSRCConfiguration configuration) {
    if (!N60AdaptiveSRCConfigurationIsValid(configuration)) return NULL;

    N60AdaptiveSRC *src = (N60AdaptiveSRC *)calloc(1u, sizeof(N60AdaptiveSRC));
    if (src == NULL) return NULL;
    src->configuration = configuration;
    src->tablePhaseStride = configuration.tapCount;
    src->nominalStep = configuration.inputSampleRate / configuration.outputSampleRate;

    size_t sampleCount = (size_t)configuration.capacityFrames * configuration.channelCount;
    size_t tableCount = ((size_t)configuration.phaseCount + 1u) * configuration.tapCount;
    src->ring = (float *)calloc(sampleCount, sizeof(float));
    src->phaseTable = (float *)calloc(tableCount, sizeof(float));
    if (src->ring == NULL || src->phaseTable == NULL) {
        N60AdaptiveSRCDestroy(src);
        return NULL;
    }

    N60AdaptiveClockPolicy policy = {
        .targetBufferedFrames = (double)configuration.targetBufferedFrames,
        .proportionalGainPPM = configuration.proportionalGainPPM,
        .integralGainPPMPerSecond = configuration.integralGainPPMPerSecond,
        .maximumCorrectionPPM = configuration.maximumCorrectionPPM,
        .slewLimitPPMPerSecond = configuration.slewLimitPPMPerSecond,
    };
    if (!N60AdaptiveClockControllerConfigure(&src->clockController, policy)
        || !build_phase_table(src)) {
        N60AdaptiveSRCDestroy(src);
        return NULL;
    }

    atomic_init(&src->writeIndex, 0u);
    atomic_init(&src->reclaimIndex, 0u);
    atomic_init(&src->sourceBaseIndex, 0u);
    atomic_init(&src->pushedInputFrames, 0u);
    atomic_init(&src->producedOutputFrames, 0u);
    atomic_init(&src->droppedInputFrames, 0u);
    atomic_init(&src->starvedOutputFrames, 0u);
    atomic_init(&src->effectiveStepBits, double_to_bits(src->nominalStep));
    atomic_init(&src->correctionPPMBits, double_to_bits(0.0));
    atomic_init(&src->normalizedErrorBits, double_to_bits(0.0));
    atomic_init(&src->bufferedFrames, 0u);
    atomic_init(&src->controllerSaturationEvents, 0u);

    if (!N60AdaptiveSRCRealtimeAtomicsAreLockFree(src)) {
        N60AdaptiveSRCDestroy(src);
        return NULL;
    }
    return src;
}

void N60AdaptiveSRCDestroy(N60AdaptiveSRC *src) {
    if (src == NULL) return;
    free(src->ring);
    free(src->phaseTable);
    free(src);
}

void N60AdaptiveSRCReset(N60AdaptiveSRC *src) {
    if (src == NULL) return;
    size_t sampleCount = (size_t)src->configuration.capacityFrames * src->configuration.channelCount;
    memset(src->ring, 0, sampleCount * sizeof(float));
    src->sourcePosition = 0.0;
    N60AdaptiveClockControllerReset(&src->clockController);
    atomic_store_explicit(&src->writeIndex, 0u, memory_order_release);
    atomic_store_explicit(&src->reclaimIndex, 0u, memory_order_release);
    atomic_store_explicit(&src->sourceBaseIndex, 0u, memory_order_release);
    atomic_store_explicit(&src->pushedInputFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&src->producedOutputFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&src->droppedInputFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&src->starvedOutputFrames, 0u, memory_order_relaxed);
    publish_runtime_snapshot(src, 0u);
}

uint32_t N60AdaptiveSRCPushInterleaved(
    N60AdaptiveSRC *src,
    const float *input,
    uint32_t inputFrames
) {
    if (src == NULL || input == NULL || inputFrames == 0u) return 0u;
    const uint32_t channels = src->configuration.channelCount;
    const uint32_t capacity = src->configuration.capacityFrames;
    uint64_t write = atomic_load_explicit(&src->writeIndex, memory_order_relaxed);
    uint64_t reclaim = atomic_load_explicit(&src->reclaimIndex, memory_order_acquire);
    uint64_t occupied = write >= reclaim ? write - reclaim : 0u;
    uint64_t available64 = occupied < capacity ? (uint64_t)capacity - occupied : 0u;
    uint32_t accepted = inputFrames;
    if ((uint64_t)accepted > available64) accepted = (uint32_t)available64;

    for (uint32_t frame = 0u; frame < accepted; ++frame) {
        uint32_t ringFrame = (uint32_t)((write + frame) % capacity);
        float *destination = src->ring + (size_t)ringFrame * channels;
        const float *source = input + (size_t)frame * channels;
        memcpy(destination, source, (size_t)channels * sizeof(float));
    }

    if (accepted > 0u) {
        uint64_t publishedWrite = write + accepted;
        atomic_store_explicit(&src->writeIndex, publishedWrite, memory_order_release);
        atomic_fetch_add_explicit(&src->pushedInputFrames, accepted, memory_order_relaxed);

    }
    if (accepted < inputFrames) {
        atomic_fetch_add_explicit(
            &src->droppedInputFrames,
            (uint64_t)(inputFrames - accepted),
            memory_order_relaxed
        );
    }
    return accepted;
}

static float ring_sample(
    const N60AdaptiveSRC *src,
    int64_t absoluteFrame,
    uint32_t channel
) {
    if (absoluteFrame < 0) return 0.0f;
    uint32_t ringFrame = (uint32_t)((uint64_t)absoluteFrame % src->configuration.capacityFrames);
    return src->ring[(size_t)ringFrame * src->configuration.channelCount + channel];
}

uint32_t N60AdaptiveSRCPullInterleaved(
    N60AdaptiveSRC *src,
    float *output,
    uint32_t requestedOutputFrames
) {
    if (src == NULL || output == NULL || requestedOutputFrames == 0u) return 0u;

    const N60AdaptiveSRCConfiguration configuration = src->configuration;
    const uint32_t taps = configuration.tapCount;
    const uint32_t half = taps / 2u;
    const uint32_t phases = configuration.phaseCount;
    const uint32_t channels = configuration.channelCount;
    uint64_t write = atomic_load_explicit(&src->writeIndex, memory_order_acquire);

    uint64_t baseForBuffer = src->sourcePosition > 0.0
        ? (uint64_t)floor(src->sourcePosition)
        : 0u;
    double buffered = write > baseForBuffer ? (double)(write - baseForBuffer) : 0.0;
    double elapsed = (double)requestedOutputFrames / configuration.outputSampleRate;
    double correctionPPM = N60AdaptiveClockControllerUpdate(
        &src->clockController,
        buffered,
        elapsed
    );
    double step = src->nominalStep * (1.0 + correctionPPM * 1.0e-6);

    uint32_t produced = 0u;
    for (; produced < requestedOutputFrames; ++produced) {
        double position = src->sourcePosition;
        int64_t center = (int64_t)floor(position);
        int64_t rightEdge = center + (int64_t)half;
        if (rightEdge < 0 || (uint64_t)rightEdge >= write) break;

        double fraction = position - floor(position);
        double phasePosition = fraction * (double)phases;
        uint32_t phase = (uint32_t)floor(phasePosition);
        if (phase >= phases) phase = phases - 1u;
        float phaseMix = (float)(phasePosition - (double)phase);
        const float *row0 = src->phaseTable + (size_t)phase * src->tablePhaseStride;
        const float *row1 = src->phaseTable + (size_t)(phase + 1u) * src->tablePhaseStride;
        int64_t leftEdge = center - ((int64_t)half - 1);

        for (uint32_t channel = 0u; channel < channels; ++channel) {
            double sum = 0.0;
            for (uint32_t tap = 0u; tap < taps; ++tap) {
                float coefficient = row0[tap] + (row1[tap] - row0[tap]) * phaseMix;
                sum += (double)ring_sample(src, leftEdge + (int64_t)tap, channel)
                    * (double)coefficient;
            }
            output[(size_t)produced * channels + channel] = (float)sum;
        }
        src->sourcePosition += step;
    }

    if (produced > 0u) {
        atomic_fetch_add_explicit(&src->producedOutputFrames, produced, memory_order_relaxed);
        uint64_t sourceBase = src->sourcePosition > 0.0
            ? (uint64_t)floor(src->sourcePosition)
            : 0u;
        atomic_store_explicit(&src->sourceBaseIndex, sourceBase, memory_order_release);
        int64_t reclaimSigned = (int64_t)sourceBase - (int64_t)half - 2;
        uint64_t reclaim = reclaimSigned > 0 ? (uint64_t)reclaimSigned : 0u;
        atomic_store_explicit(&src->reclaimIndex, reclaim, memory_order_release);
    }
    if (produced < requestedOutputFrames) {
        atomic_fetch_add_explicit(
            &src->starvedOutputFrames,
            (uint64_t)(requestedOutputFrames - produced),
            memory_order_relaxed
        );
    }

    publish_runtime_snapshot(src, write);
    return produced;
}

N60AdaptiveSRCSnapshot N60AdaptiveSRCGetSnapshot(const N60AdaptiveSRC *src) {
    if (src == NULL) return (N60AdaptiveSRCSnapshot){0};
    return (N60AdaptiveSRCSnapshot){
        .valid = true,
        .inputSampleRate = src->configuration.inputSampleRate,
        .outputSampleRate = src->configuration.outputSampleRate,
        .nominalInputFramesPerOutputFrame = src->nominalStep,
        .effectiveInputFramesPerOutputFrame = bits_to_double(
            atomic_load_explicit(&src->effectiveStepBits, memory_order_relaxed)
        ),
        .correctionPPM = bits_to_double(
            atomic_load_explicit(&src->correctionPPMBits, memory_order_relaxed)
        ),
        .normalizedBufferError = bits_to_double(
            atomic_load_explicit(&src->normalizedErrorBits, memory_order_relaxed)
        ),
        .targetBufferedFrames = src->configuration.targetBufferedFrames,
        // Compute fill from separately published producer/consumer indices so
        // startup can observe capture progress before the first Pull call.
        .bufferedFrames = current_buffered_frames(
            src,
            atomic_load_explicit(&src->writeIndex, memory_order_acquire)
        ),
        .pushedInputFrames = atomic_load_explicit(&src->pushedInputFrames, memory_order_relaxed),
        .producedOutputFrames = atomic_load_explicit(&src->producedOutputFrames, memory_order_relaxed),
        .droppedInputFrames = atomic_load_explicit(&src->droppedInputFrames, memory_order_relaxed),
        .starvedOutputFrames = atomic_load_explicit(&src->starvedOutputFrames, memory_order_relaxed),
        .controllerSaturationEvents = atomic_load_explicit(
            &src->controllerSaturationEvents,
            memory_order_relaxed
        ),
    };
}

bool N60AdaptiveSRCRealtimeAtomicsAreLockFree(const N60AdaptiveSRC *src) {
    if (src == NULL) return false;
    return atomic_is_lock_free(&src->writeIndex)
        && atomic_is_lock_free(&src->reclaimIndex)
        && atomic_is_lock_free(&src->sourceBaseIndex)
        && atomic_is_lock_free(&src->pushedInputFrames)
        && atomic_is_lock_free(&src->effectiveStepBits)
        && atomic_is_lock_free(&src->bufferedFrames);
}

uint32_t N60AdaptiveSRCLatencyInputFrames(const N60AdaptiveSRC *src) {
    if (src == NULL) return 0u;
    return src->configuration.tapCount / 2u;
}
