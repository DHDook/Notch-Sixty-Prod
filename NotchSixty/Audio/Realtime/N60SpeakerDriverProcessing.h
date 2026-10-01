#ifndef N60SpeakerDriverProcessing_h
#define N60SpeakerDriverProcessing_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "N60Biquad.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_SPEAKER_DRIVER_BUS_COUNT 9u
#define N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS 8u
// 50 ms at the product's validated 384 kHz ceiling, plus one guard frame.
#define N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES 19201u

typedef struct {
    bool enabled;
    uint32_t eqSectionCount;
    N60BiquadCoefficients eqSections[N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS];
    float trimLinear;
    bool polarityInverted;
    uint32_t integerDelayFrames;
    float fractionalDelay;
    float fractionalAllPassCoefficient;
    bool limiterEnabled;
    float limiterThresholdLinear;
    float limiterReleaseCoefficient;
} N60SpeakerDriverBusSnapshot;

typedef struct {
    bool valid;
    bool enabled;
    N60SpeakerDriverBusSnapshot buses[N60_SPEAKER_DRIVER_BUS_COUNT];
} N60SpeakerDriverProcessingSnapshot;

typedef struct {
    N60BiquadState eqStates[N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS];
    float delayLine[N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES];
    uint32_t delayWriteIndex;
    float fractionalInputHistory;
    float fractionalOutputHistory;
    float limiterGain;
} N60SpeakerDriverBusRuntime;

typedef struct {
    N60SpeakerDriverProcessingSnapshot snapshot;
    N60SpeakerDriverBusRuntime buses[N60_SPEAKER_DRIVER_BUS_COUNT];
} N60SpeakerDriverProcessingRuntime;

static inline N60SpeakerDriverProcessingSnapshot
N60SpeakerDriverProcessingSnapshotMakeBypassed(void) {
    N60SpeakerDriverProcessingSnapshot snapshot = {0};
    snapshot.valid = true;
    snapshot.enabled = false;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        snapshot.buses[bus].trimLinear = 1.0f;
        snapshot.buses[bus].limiterThresholdLinear = 1.0f;
        snapshot.buses[bus].limiterReleaseCoefficient = 0.999f;
        for (uint32_t index = 0; index < N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS; ++index) {
            snapshot.buses[bus].eqSections[index] = N60BiquadCoefficientsMakeIdentity();
        }
    }
    return snapshot;
}

static inline bool N60SpeakerDriverProcessingSnapshotSetBus(
    N60SpeakerDriverProcessingSnapshot *snapshot,
    uint32_t busIndex,
    bool enabled,
    const N60BiquadCoefficients *eqSections,
    uint32_t eqSectionCount,
    float trimLinear,
    bool polarityInverted,
    uint32_t integerDelayFrames,
    float fractionalDelay,
    bool limiterEnabled,
    float limiterThresholdLinear,
    float limiterReleaseCoefficient
) {
    if (snapshot == NULL || !snapshot->valid
        || busIndex >= N60_SPEAKER_DRIVER_BUS_COUNT
        || eqSectionCount > N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS
        || (eqSectionCount > 0 && eqSections == NULL)
        || !isfinite(trimLinear) || trimLinear < 0.0f
        || integerDelayFrames >= N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES
        || !isfinite(fractionalDelay) || fractionalDelay < 0.0f || fractionalDelay >= 1.0f
        || !isfinite(limiterThresholdLinear) || limiterThresholdLinear <= 0.0f
        || limiterThresholdLinear > 1.0f
        || !isfinite(limiterReleaseCoefficient)
        || limiterReleaseCoefficient < 0.0f || limiterReleaseCoefficient >= 1.0f) {
        return false;
    }

    N60SpeakerDriverBusSnapshot configured = {0};
    configured.enabled = enabled;
    configured.eqSectionCount = eqSectionCount;
    configured.trimLinear = trimLinear;
    configured.polarityInverted = polarityInverted;
    configured.integerDelayFrames = integerDelayFrames;
    configured.fractionalDelay = fractionalDelay;
    configured.fractionalAllPassCoefficient = fractionalDelay > 1.0e-7f
        ? (1.0f - fractionalDelay) / (1.0f + fractionalDelay)
        : 0.0f;
    configured.limiterEnabled = limiterEnabled;
    configured.limiterThresholdLinear = limiterThresholdLinear;
    configured.limiterReleaseCoefficient = limiterReleaseCoefficient;
    for (uint32_t index = 0; index < N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS; ++index) {
        configured.eqSections[index] = index < eqSectionCount
            ? eqSections[index]
            : N60BiquadCoefficientsMakeIdentity();
    }

    snapshot->buses[busIndex] = configured;
    if (enabled) snapshot->enabled = true;
    return true;
}

static inline bool N60SpeakerDriverProcessingRuntimeConfigure(
    N60SpeakerDriverProcessingRuntime *runtime,
    N60SpeakerDriverProcessingSnapshot snapshot
) {
    if (runtime == NULL || !snapshot.valid) return false;
    memset(runtime, 0, sizeof(*runtime));
    runtime->snapshot = snapshot;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        runtime->buses[bus].limiterGain = 1.0f;
    }
    return true;
}

static inline float N60SpeakerDriverProcessEQ(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    float value = input;
    for (uint32_t index = 0; index < snapshot->eqSectionCount; ++index) {
        value = N60BiquadProcessSample(
            snapshot->eqSections[index], &runtime->eqStates[index], value
        );
    }
    return value;
}

static inline float N60SpeakerDriverProcessDelay(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    float delayed = input;
    const uint32_t delayFrames = snapshot->integerDelayFrames;
    if (delayFrames > 0) {
        uint32_t index = runtime->delayWriteIndex;
        delayed = runtime->delayLine[index];
        runtime->delayLine[index] = input;
        index += 1;
        if (index >= delayFrames) index = 0;
        runtime->delayWriteIndex = index;
    }

    if (snapshot->fractionalDelay > 1.0e-7f) {
        const float coefficient = snapshot->fractionalAllPassCoefficient;
        const float output = coefficient * delayed
            + runtime->fractionalInputHistory
            - coefficient * runtime->fractionalOutputHistory;
        runtime->fractionalInputHistory = delayed;
        runtime->fractionalOutputHistory = output;
        delayed = output;
    }
    return delayed;
}

static inline float N60SpeakerDriverProcessLimiter(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    if (!snapshot->limiterEnabled) return input;
    const float magnitude = fabsf(input);
    float gain = runtime->limiterGain;
    if (magnitude > snapshot->limiterThresholdLinear && magnitude > 0.0f) {
        const float required = snapshot->limiterThresholdLinear / magnitude;
        if (required < gain) gain = required;
    } else {
        const float release = snapshot->limiterReleaseCoefficient;
        gain = release * gain + (1.0f - release);
        if (gain > 1.0f) gain = 1.0f;
    }
    runtime->limiterGain = gain;
    return input * gain;
}

static inline void N60SpeakerDriverProcessingRuntimeProcessValues(
    N60SpeakerDriverProcessingRuntime *runtime,
    float values[N60_SPEAKER_DRIVER_BUS_COUNT]
) {
    if (runtime == NULL || values == NULL || !runtime->snapshot.enabled) return;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        const N60SpeakerDriverBusSnapshot *snapshot = &runtime->snapshot.buses[bus];
        if (!snapshot->enabled) continue;
        N60SpeakerDriverBusRuntime *busRuntime = &runtime->buses[bus];
        float value = values[bus];
        value = N60SpeakerDriverProcessEQ(snapshot, busRuntime, value);
        value = N60SpeakerDriverProcessDelay(snapshot, busRuntime, value);
        value *= snapshot->trimLinear;
        if (snapshot->polarityInverted) value = -value;
        value = N60SpeakerDriverProcessLimiter(snapshot, busRuntime, value);
        values[bus] = isfinite(value) ? value : 0.0f;
    }
}

#ifdef __cplusplus
}
#endif

#endif
