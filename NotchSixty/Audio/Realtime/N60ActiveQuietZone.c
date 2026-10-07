#include "N60ActiveQuietZone.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#define N60_AQZ_TWO_PI 6.283185307179586476925286766559

static float linear_from_db(double db) {
    return (float)pow(10.0, db / 20.0);
}

static float complex_magnitude(float real, float imaginary) {
    return hypotf(real, imaginary);
}

static bool finite_tone(
    const N60ActiveQuietZoneToneSnapshot *tone
) {
    return tone != NULL
        && isfinite(tone->frequencyHz)
        && isfinite(tone->leftReal)
        && isfinite(tone->leftImaginary)
        && isfinite(tone->rightReal)
        && isfinite(tone->rightImaginary);
}

N60ActiveQuietZoneSnapshot
N60ActiveQuietZoneSnapshotMakeBypassed(void) {
    N60ActiveQuietZoneSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.toneCount = 0u;
    snapshot.transitionFrames = 1u;
    return snapshot;
}

bool N60ActiveQuietZoneSnapshotSet(
    N60ActiveQuietZoneSnapshot *snapshot,
    const N60ActiveQuietZoneToneSnapshot *tones,
    uint32_t toneCount,
    uint32_t transitionFrames,
    bool enabled
) {
    if (snapshot == NULL
        || toneCount > N60_ACTIVE_QUIET_ZONE_MAX_TONES
        || transitionFrames == 0u
        || (enabled && (toneCount == 0u || tones == NULL))) {
        return false;
    }

    N60ActiveQuietZoneSnapshot prepared =
        N60ActiveQuietZoneSnapshotMakeBypassed();
    prepared.enabled = enabled;
    prepared.toneCount = enabled ? toneCount : 0u;
    prepared.transitionFrames = transitionFrames;

    const float maximumTonePeak =
        linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_TONE_PEAK_DBFS);
    const float maximumAggregatePeak =
        linear_from_db(
            N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS
        );
    float aggregateLeft = 0.0f;
    float aggregateRight = 0.0f;

    for (uint32_t index = 0u;
         index < prepared.toneCount;
         ++index) {
        const N60ActiveQuietZoneToneSnapshot tone = tones[index];
        if (!finite_tone(&tone)
            || tone.frequencyHz < N60_ACTIVE_QUIET_ZONE_MIN_HZ
            || tone.frequencyHz > N60_ACTIVE_QUIET_ZONE_MAX_HZ) {
            return false;
        }
        const float leftMagnitude =
            complex_magnitude(tone.leftReal, tone.leftImaginary);
        const float rightMagnitude =
            complex_magnitude(tone.rightReal, tone.rightImaginary);
        if (!isfinite(leftMagnitude)
            || !isfinite(rightMagnitude)
            || leftMagnitude > maximumTonePeak + 1.0e-7f
            || rightMagnitude > maximumTonePeak + 1.0e-7f) {
            return false;
        }
        aggregateLeft += leftMagnitude;
        aggregateRight += rightMagnitude;
        if (aggregateLeft > maximumAggregatePeak + 1.0e-7f
            || aggregateRight > maximumAggregatePeak + 1.0e-7f) {
            return false;
        }
        prepared.tones[index] = tone;
    }

    *snapshot = prepared;
    return true;
}

void N60ActiveQuietZoneRuntimeReset(
    N60ActiveQuietZoneRuntime *runtime,
    double sampleRate
) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    runtime->sampleRate =
        isfinite(sampleRate) && sampleRate > 0
            ? sampleRate
            : 48000.0;
}

static bool runtime_is_silent(
    const N60ActiveQuietZoneToneRuntime *tone
) {
    const float epsilon = 1.0e-8f;
    return fabsf(tone->currentLeftReal) <= epsilon
        && fabsf(tone->currentLeftImaginary) <= epsilon
        && fabsf(tone->currentRightReal) <= epsilon
        && fabsf(tone->currentRightImaginary) <= epsilon
        && tone->transitionFramesRemaining == 0u;
}

static void schedule_tone(
    N60ActiveQuietZoneToneRuntime *runtime,
    const N60ActiveQuietZoneToneSnapshot *target,
    uint32_t transitionFrames,
    bool enabled
) {
    runtime->startLeftReal = runtime->currentLeftReal;
    runtime->startLeftImaginary =
        runtime->currentLeftImaginary;
    runtime->startRightReal = runtime->currentRightReal;
    runtime->startRightImaginary =
        runtime->currentRightImaginary;

    runtime->targetLeftReal =
        enabled && target != NULL ? target->leftReal : 0.0f;
    runtime->targetLeftImaginary =
        enabled && target != NULL
            ? target->leftImaginary
            : 0.0f;
    runtime->targetRightReal =
        enabled && target != NULL ? target->rightReal : 0.0f;
    runtime->targetRightImaginary =
        enabled && target != NULL
            ? target->rightImaginary
            : 0.0f;
    runtime->transitionFramesTotal =
        transitionFrames > 0u ? transitionFrames : 1u;
    runtime->transitionFramesRemaining =
        runtime->transitionFramesTotal;
}

bool N60ActiveQuietZoneRuntimeSchedule(
    N60ActiveQuietZoneRuntime *runtime,
    const N60ActiveQuietZoneSnapshot *snapshot,
    double sampleRate
) {
    if (runtime == NULL
        || snapshot == NULL
        || !isfinite(sampleRate)
        || sampleRate <= 0
        || snapshot->toneCount > N60_ACTIVE_QUIET_ZONE_MAX_TONES) {
        return false;
    }

    if (fabs(runtime->sampleRate - sampleRate) > 0.5) {
        N60ActiveQuietZoneRuntimeReset(runtime, sampleRate);
    }
    runtime->sampleRate = sampleRate;

    for (uint32_t index = 0u;
         index < N60_ACTIVE_QUIET_ZONE_MAX_TONES;
         ++index) {
        N60ActiveQuietZoneToneRuntime *tone =
            &runtime->tones[index];
        const bool targetEnabled =
            snapshot->enabled && index < snapshot->toneCount;
        const N60ActiveQuietZoneToneSnapshot *target =
            targetEnabled ? &snapshot->tones[index] : NULL;

        if (targetEnabled) {
            if (!finite_tone(target)
                || target->frequencyHz >= sampleRate * 0.5) {
                return false;
            }
            if (tone->active
                && fabs(
                    tone->frequencyHz - target->frequencyHz
                ) > 0.001
                && !runtime_is_silent(tone)) {
                // Do not jump an active oscillator to another phase/frequency.
                // Fade/disarm must complete before a new target frequency.
                return false;
            }
            if (!tone->active || runtime_is_silent(tone)) {
                tone->frequencyHz = target->frequencyHz;
                tone->phaseRadians = 0.0;
                tone->currentLeftReal = 0.0f;
                tone->currentLeftImaginary = 0.0f;
                tone->currentRightReal = 0.0f;
                tone->currentRightImaginary = 0.0f;
                tone->active = true;
            }
        }

        if (!targetEnabled && !tone->active) {
            continue;
        }
        schedule_tone(
            tone,
            target,
            snapshot->transitionFrames,
            targetEnabled
        );
    }
    return true;
}

static void advance_coefficient_transition(
    N60ActiveQuietZoneToneRuntime *tone
) {
    if (tone->transitionFramesRemaining == 0u) {
        return;
    }
    const uint32_t completed =
        tone->transitionFramesTotal
        - tone->transitionFramesRemaining
        + 1u;
    const float mix =
        (float)completed / (float)tone->transitionFramesTotal;
    tone->currentLeftReal =
        tone->startLeftReal
        + (tone->targetLeftReal - tone->startLeftReal) * mix;
    tone->currentLeftImaginary =
        tone->startLeftImaginary
        + (
            tone->targetLeftImaginary
            - tone->startLeftImaginary
        ) * mix;
    tone->currentRightReal =
        tone->startRightReal
        + (tone->targetRightReal - tone->startRightReal) * mix;
    tone->currentRightImaginary =
        tone->startRightImaginary
        + (
            tone->targetRightImaginary
            - tone->startRightImaginary
        ) * mix;
    tone->transitionFramesRemaining -= 1u;
    if (tone->transitionFramesRemaining == 0u) {
        tone->currentLeftReal = tone->targetLeftReal;
        tone->currentLeftImaginary = tone->targetLeftImaginary;
        tone->currentRightReal = tone->targetRightReal;
        tone->currentRightImaginary = tone->targetRightImaginary;
        if (runtime_is_silent(tone)) {
            tone->active = false;
            tone->phaseRadians = 0.0;
            tone->frequencyHz = 0.0;
        }
    }
}

void N60ActiveQuietZoneRuntimeProcessFrame(
    N60ActiveQuietZoneRuntime *runtime,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float outputLeft = 0.0f;
    float outputRight = 0.0f;
    for (uint32_t index = 0u;
         index < N60_ACTIVE_QUIET_ZONE_MAX_TONES;
         ++index) {
        N60ActiveQuietZoneToneRuntime *tone =
            &runtime->tones[index];
        if (!tone->active) continue;

        advance_coefficient_transition(tone);
        const double phase = tone->phaseRadians;
        const float cosine = (float)cos(phase);
        const float sine = (float)sin(phase);
        outputLeft +=
            tone->currentLeftReal * cosine
            - tone->currentLeftImaginary * sine;
        outputRight +=
            tone->currentRightReal * cosine
            - tone->currentRightImaginary * sine;

        tone->phaseRadians +=
            N60_AQZ_TWO_PI
            * tone->frequencyHz
            / runtime->sampleRate;
        if (tone->phaseRadians >= N60_AQZ_TWO_PI) {
            tone->phaseRadians -= N60_AQZ_TWO_PI;
        }
    }

    if (!isfinite(outputLeft)) {
        outputLeft = 0.0f;
        runtime->sanitizedSamples += 1u;
    }
    if (!isfinite(outputRight)) {
        outputRight = 0.0f;
        runtime->sanitizedSamples += 1u;
    }

    const float aggregateLimit =
        linear_from_db(
            N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS
        );
    if (outputLeft > aggregateLimit) outputLeft = aggregateLimit;
    if (outputLeft < -aggregateLimit) outputLeft = -aggregateLimit;
    if (outputRight > aggregateLimit) outputRight = aggregateLimit;
    if (outputRight < -aggregateLimit) outputRight = -aggregateLimit;

    runtime->lastLeft = outputLeft;
    runtime->lastRight = outputRight;
    runtime->processedFrames += 1u;
    *left = outputLeft;
    *right = outputRight;
}

void N60ActiveQuietZoneRuntimeLastFrame(
    const N60ActiveQuietZoneRuntime *runtime,
    float *left,
    float *right
) {
    if (left != NULL) {
        *left = runtime != NULL ? runtime->lastLeft : 0.0f;
    }
    if (right != NULL) {
        *right = runtime != NULL ? runtime->lastRight : 0.0f;
    }
}
