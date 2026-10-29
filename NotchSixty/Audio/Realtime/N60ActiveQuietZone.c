#include "N60ActiveQuietZone.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
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

bool N60ActiveQuietZoneSnapshotSetPeakCap(
    N60ActiveQuietZoneSnapshot *snapshot,
    float peakCapLinear
) {
    if (snapshot == NULL || !isfinite(peakCapLinear) || peakCapLinear <= 0.0f) {
        return false;
    }
    const float hardLimit =
        linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS);
    snapshot->peakCapLinear =
        peakCapLinear < hardLimit ? peakCapLinear : hardLimit;
    return true;
}

bool N60ActiveQuietZoneSnapshotSet(
    N60ActiveQuietZoneSnapshot *snapshot,
    const N60ActiveQuietZoneToneSnapshot *tones,
    uint32_t toneCount,
    uint32_t transitionFrames,
    double sampleRate,
    bool enabled
) {
    if (snapshot == NULL
        || toneCount > N60_ACTIVE_QUIET_ZONE_MAX_TONES
        || transitionFrames == 0u
        || !isfinite(sampleRate)
        || sampleRate <= 0.0
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
        N60ActiveQuietZoneToneSnapshot preparedTone = tone;
        const double phaseIncrement =
            N60_AQZ_TWO_PI * tone.frequencyHz / sampleRate;
        preparedTone.incrementCosine = cos(phaseIncrement);
        preparedTone.incrementSine = sin(phaseIncrement);
        if (!isfinite(preparedTone.incrementCosine)
            || !isfinite(preparedTone.incrementSine)) {
            return false;
        }
        prepared.tones[index] = preparedTone;
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
    runtime->peakCapLinear =
        snapshot->peakCapLinear > 0.0f
            ? snapshot->peakCapLinear
            : linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS);
    // E4 S18a: this retargets to the offline gains. A valid mailbox record of the same arm is
    // applied again by ApplyMailbox in the same callback, before any frame is rendered.
    runtime->mailboxReapply = runtime->mailboxRecordValid && snapshot->enabled;
    if (!snapshot->enabled) runtime->mailboxRecordValid = false;

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
                tone->oscillatorCosine = 1.0;
                tone->oscillatorSine = 0.0;
                tone->incrementCosine =
                    target->incrementCosine;
                tone->incrementSine =
                    target->incrementSine;
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
            tone->oscillatorCosine = 1.0;
            tone->oscillatorSine = 0.0;
            tone->incrementCosine = 1.0;
            tone->incrementSine = 0.0;
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
        const double cosine = tone->oscillatorCosine;
        const double sine = tone->oscillatorSine;
        outputLeft +=
            tone->currentLeftReal * (float)cosine
            - tone->currentLeftImaginary * (float)sine;
        outputRight +=
            tone->currentRightReal * (float)cosine
            - tone->currentRightImaginary * (float)sine;

        const double nextCosine =
            cosine * tone->incrementCosine
            - sine * tone->incrementSine;
        const double nextSine =
            sine * tone->incrementCosine
            + cosine * tone->incrementSine;
        tone->oscillatorCosine = nextCosine;
        tone->oscillatorSine = nextSine;
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

    // Clamp every sample to the snapshot's cap (the always-on -40 dBFS in the app), never
    // above the compile-time aggregate limit. An unscheduled runtime uses the limit.
    // Schedule and SnapshotSetPeakCap already bound the cap by the aggregate limit; only an
    // unscheduled runtime (cap 0) falls back to it here.
    float limit = runtime->peakCapLinear;
    if (!(limit > 0.0f)) {
        limit = linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS);
    }
    if (outputLeft > limit) { outputLeft = limit; runtime->clampedSamples += 1u; }
    if (outputLeft < -limit) { outputLeft = -limit; runtime->clampedSamples += 1u; }
    if (outputRight > limit) { outputRight = limit; runtime->clampedSamples += 1u; }
    if (outputRight < -limit) { outputRight = -limit; runtime->clampedSamples += 1u; }

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


/* ---- E4 S18a: gain mailbox ------------------------------------------------------------------ */

// Single-producer, single-consumer latest-value exchange (triple buffer): the writer fills the
// back slot and publishes it; the reader takes the newest published slot, if any.
struct N60ActiveQuietZoneGainMailbox {
    N60ActiveQuietZoneGainRecord slots[3];
    uint32_t back;     // writer only
    uint32_t front;    // reader only
    _Atomic uint32_t middle;  // slot index | 4 when fresh
    uint64_t sequence; // writer only
    _Atomic uint64_t published;
    _Atomic uint64_t applied;
    _Atomic uint64_t clamped;
    _Atomic uint64_t ignoredStaleGeneration;
    _Atomic uint64_t ignoredToneMismatch;
    _Atomic uint64_t ignoredNonFinite;
    _Atomic uint64_t ignoredNotEnabled;
};

#define N60_AQZ_MAILBOX_FRESH 4u
#define N60_AQZ_MAILBOX_INDEX 3u

N60ActiveQuietZoneGainMailbox *N60ActiveQuietZoneGainMailboxCreate(void) {
    N60ActiveQuietZoneGainMailbox *mailbox = calloc(1, sizeof(*mailbox));
    if (mailbox == NULL) return NULL;
    mailbox->back = 0u;
    mailbox->front = 2u;
    atomic_init(&mailbox->middle, 1u);
    return mailbox;
}

void N60ActiveQuietZoneGainMailboxDestroy(N60ActiveQuietZoneGainMailbox *mailbox) {
    free(mailbox);
}

uint64_t N60ActiveQuietZoneGainMailboxPublish(
    N60ActiveQuietZoneGainMailbox *mailbox,
    const N60ActiveQuietZoneGainRecord *record
) {
    if (mailbox == NULL || record == NULL
        || record->toneCount > N60_ACTIVE_QUIET_ZONE_MAX_TONES) {
        return 0u;
    }
    N60ActiveQuietZoneGainRecord *slot = &mailbox->slots[mailbox->back];
    *slot = *record;
    slot->sequence = ++mailbox->sequence;
    const uint32_t previous = atomic_exchange_explicit(
        &mailbox->middle, mailbox->back | N60_AQZ_MAILBOX_FRESH, memory_order_acq_rel);
    mailbox->back = previous & N60_AQZ_MAILBOX_INDEX;
    atomic_fetch_add_explicit(&mailbox->published, 1u, memory_order_relaxed);
    return mailbox->sequence;
}

N60ActiveQuietZoneMailboxStats N60ActiveQuietZoneGainMailboxStats(
    const N60ActiveQuietZoneGainMailbox *mailbox
) {
    N60ActiveQuietZoneMailboxStats stats = {0};
    if (mailbox == NULL) return stats;
    N60ActiveQuietZoneGainMailbox *m = (N60ActiveQuietZoneGainMailbox *)mailbox;
    stats.published = atomic_load_explicit(&m->published, memory_order_relaxed);
    stats.applied = atomic_load_explicit(&m->applied, memory_order_relaxed);
    stats.clamped = atomic_load_explicit(&m->clamped, memory_order_relaxed);
    stats.ignoredStaleGeneration =
        atomic_load_explicit(&m->ignoredStaleGeneration, memory_order_relaxed);
    stats.ignoredToneMismatch =
        atomic_load_explicit(&m->ignoredToneMismatch, memory_order_relaxed);
    stats.ignoredNonFinite =
        atomic_load_explicit(&m->ignoredNonFinite, memory_order_relaxed);
    stats.ignoredNotEnabled =
        atomic_load_explicit(&m->ignoredNotEnabled, memory_order_relaxed);
    return stats;
}

static bool mailbox_acquire(
    N60ActiveQuietZoneGainMailbox *mailbox,
    N60ActiveQuietZoneGainRecord *out
) {
    if ((atomic_load_explicit(&mailbox->middle, memory_order_relaxed)
         & N60_AQZ_MAILBOX_FRESH) == 0u) {
        return false;
    }
    const uint32_t previous = atomic_exchange_explicit(
        &mailbox->middle, mailbox->front, memory_order_acq_rel);
    mailbox->front = previous & N60_AQZ_MAILBOX_INDEX;
    *out = mailbox->slots[mailbox->front];
    return true;
}

static bool record_is_finite(const N60ActiveQuietZoneGainRecord *record) {
    if (!isfinite(record->attemptCapLinear) || record->attemptCapLinear < 0.0f) return false;
    for (uint32_t t = 0u; t < record->toneCount; ++t) {
        if (!isfinite(record->frequencyHz[t])) return false;
        for (uint32_t g = 0u; g < 4u; ++g) {
            if (!isfinite(record->gain[t][g])) return false;
        }
    }
    return true;
}

void N60ActiveQuietZoneRuntimeApplyMailbox(
    N60ActiveQuietZoneRuntime *runtime,
    N60ActiveQuietZoneGainMailbox *mailbox,
    const N60ActiveQuietZoneSnapshot *snapshot,
    double sampleRate
) {
    if (runtime == NULL || mailbox == NULL || snapshot == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0) {
        return;
    }
    N60ActiveQuietZoneGainRecord fresh;
    const bool isFresh = mailbox_acquire(mailbox, &fresh);
    if (isFresh) {
        runtime->mailboxRecord = fresh;
        runtime->mailboxRecordValid = true;
        runtime->mailboxReapply = true;
        runtime->mailboxSequence = fresh.sequence;
    }
    if (!runtime->mailboxRecordValid || !runtime->mailboxReapply) return;
    runtime->mailboxReapply = false;

    const N60ActiveQuietZoneGainRecord *record = &runtime->mailboxRecord;
    if (!snapshot->enabled || snapshot->toneCount == 0u) {
        runtime->mailboxRecordValid = false;
        if (isFresh) atomic_fetch_add_explicit(&mailbox->ignoredNotEnabled, 1u, memory_order_relaxed);
        return;
    }
    if (record->armGeneration == 0u || record->armGeneration != snapshot->armGeneration) {
        runtime->mailboxRecordValid = false;
        if (isFresh) {
            atomic_fetch_add_explicit(&mailbox->ignoredStaleGeneration, 1u, memory_order_relaxed);
        }
        return;
    }
    bool matches = record->toneCount == snapshot->toneCount
        && record->toneCount <= N60_ACTIVE_QUIET_ZONE_MAX_TONES;
    for (uint32_t t = 0u; matches && t < record->toneCount; ++t) {
        matches = isfinite(record->frequencyHz[t])
            && fabs(record->frequencyHz[t] - snapshot->tones[t].frequencyHz) <= 0.001;
    }
    if (!matches) {
        runtime->mailboxRecordValid = false;
        if (isFresh) atomic_fetch_add_explicit(&mailbox->ignoredToneMismatch, 1u, memory_order_relaxed);
        return;
    }
    if (!record_is_finite(record)) {
        runtime->mailboxRecordValid = false;
        if (isFresh) atomic_fetch_add_explicit(&mailbox->ignoredNonFinite, 1u, memory_order_relaxed);
        return;
    }

    // Limits: the lower of the always-on limits, the snapshot cap and the attempt cap.
    float aggregateLimit = linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS);
    float toneLimit = linear_from_db(N60_ACTIVE_QUIET_ZONE_MAX_TONE_PEAK_DBFS);
    if (snapshot->peakCapLinear > 0.0f && snapshot->peakCapLinear < aggregateLimit) {
        aggregateLimit = snapshot->peakCapLinear;
    }
    if (record->attemptCapLinear > 0.0f && record->attemptCapLinear < aggregateLimit) {
        aggregateLimit = record->attemptCapLinear;
    }
    if (toneLimit > aggregateLimit) toneLimit = aggregateLimit;

    float gain[N60_ACTIVE_QUIET_ZONE_MAX_TONES][4];
    memcpy(gain, record->gain, sizeof(gain));
    bool clamped = false;
    float sum[2] = {0.0f, 0.0f};
    for (uint32_t t = 0u; t < record->toneCount; ++t) {
        for (uint32_t channel = 0u; channel < 2u; ++channel) {
            float *re = &gain[t][channel * 2u];
            float *im = &gain[t][channel * 2u + 1u];
            float magnitude = complex_magnitude(*re, *im);
            if (magnitude > toneLimit) {
                const float scale = toneLimit / magnitude;
                *re *= scale;
                *im *= scale;
                magnitude = toneLimit;
                clamped = true;
            }
            sum[channel] += magnitude;
        }
    }
    for (uint32_t channel = 0u; channel < 2u; ++channel) {
        if (sum[channel] > aggregateLimit) {
            const float scale = aggregateLimit / sum[channel];
            for (uint32_t t = 0u; t < record->toneCount; ++t) {
                gain[t][channel * 2u] *= scale;
                gain[t][channel * 2u + 1u] *= scale;
            }
            clamped = true;
        }
    }

    double frames = floor(sampleRate * N60_ACTIVE_QUIET_ZONE_MAILBOX_CROSSFADE_SECONDS + 0.5);
    if (frames < 1.0) frames = 1.0;
    for (uint32_t t = 0u; t < record->toneCount; ++t) {
        N60ActiveQuietZoneToneRuntime *tone = &runtime->tones[t];
        if (!tone->active) continue;
        N60ActiveQuietZoneToneSnapshot target = snapshot->tones[t];
        target.leftReal = gain[t][0];
        target.leftImaginary = gain[t][1];
        target.rightReal = gain[t][2];
        target.rightImaginary = gain[t][3];
        schedule_tone(tone, &target, (uint32_t)frames, true);
    }
    if (record->attemptCapLinear > 0.0f && record->attemptCapLinear < runtime->peakCapLinear) {
        runtime->peakCapLinear = record->attemptCapLinear;
    }
    if (isFresh) {
        atomic_fetch_add_explicit(&mailbox->applied, 1u, memory_order_relaxed);
        if (clamped) atomic_fetch_add_explicit(&mailbox->clamped, 1u, memory_order_relaxed);
    }
}

/* ---- E4 S18a: phase-anchor telemetry ring --------------------------------------------------- */

struct N60ActiveQuietZoneTelemetry {
    N60ActiveQuietZoneTelemetryRecord records[N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY];
    _Atomic uint64_t head;  // producer
    _Atomic uint64_t tail;  // consumer
    _Atomic uint64_t dropped;
};

N60ActiveQuietZoneTelemetry *N60ActiveQuietZoneTelemetryCreate(void) {
    return calloc(1, sizeof(N60ActiveQuietZoneTelemetry));
}

void N60ActiveQuietZoneTelemetryDestroy(N60ActiveQuietZoneTelemetry *ring) {
    free(ring);
}

bool N60ActiveQuietZoneTelemetryPush(
    N60ActiveQuietZoneTelemetry *ring,
    const N60ActiveQuietZoneTelemetryRecord *record
) {
    if (ring == NULL || record == NULL) return false;
    const uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    const uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY) {
        atomic_fetch_add_explicit(&ring->dropped, 1u, memory_order_relaxed);
        return false;
    }
    ring->records[head % N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY] = *record;
    atomic_store_explicit(&ring->head, head + 1u, memory_order_release);
    return true;
}

bool N60ActiveQuietZoneTelemetryPop(
    N60ActiveQuietZoneTelemetry *ring,
    N60ActiveQuietZoneTelemetryRecord *record
) {
    if (ring == NULL || record == NULL) return false;
    const uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    const uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (tail == head) return false;
    *record = ring->records[tail % N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY];
    atomic_store_explicit(&ring->tail, tail + 1u, memory_order_release);
    return true;
}

uint64_t N60ActiveQuietZoneTelemetryDropped(const N60ActiveQuietZoneTelemetry *ring) {
    if (ring == NULL) return 0u;
    return atomic_load_explicit(&((N60ActiveQuietZoneTelemetry *)ring)->dropped, memory_order_relaxed);
}

bool N60ActiveQuietZoneRuntimeCaptureTelemetry(
    const N60ActiveQuietZoneRuntime *runtime,
    uint64_t hostTime,
    uint64_t renderedFrame,
    N60ActiveQuietZoneTelemetryRecord *record
) {
    if (runtime == NULL || record == NULL || hostTime == 0u) return false;
    memset(record, 0, sizeof(*record));
    record->hostTime = hostTime;
    record->renderedFrame = renderedFrame;
    uint32_t count = 0u;
    for (uint32_t t = 0u; t < N60_ACTIVE_QUIET_ZONE_MAX_TONES; ++t) {
        const N60ActiveQuietZoneToneRuntime *tone = &runtime->tones[t];
        if (!tone->active) continue;
        count = t + 1u;
        record->frequencyHz[t] = tone->frequencyHz;
        record->phasorCosine[t] = tone->oscillatorCosine;
        record->phasorSine[t] = tone->oscillatorSine;
        record->gain[t][0] = tone->currentLeftReal;
        record->gain[t][1] = tone->currentLeftImaginary;
        record->gain[t][2] = tone->currentRightReal;
        record->gain[t][3] = tone->currentRightImaginary;
    }
    record->toneCount = count;
    return count > 0u;
}
