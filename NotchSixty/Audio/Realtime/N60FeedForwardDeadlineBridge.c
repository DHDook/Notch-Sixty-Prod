#include "N60FeedForwardDeadlineBridge.h"
#include "N60FeedForwardPreviewFIR.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>

struct N60FeedForwardDeadlineBridge {
    N60FFDeadlinePlan plan;
    N60FFDeadlineRecord *records;
    N60FeedForwardPreviewFIR *fir;
    uint32_t capacity;
    uint32_t mask;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t accepted;
    _Atomic uint64_t rejected;
    _Atomic int firstFault;
    _Atomic bool halted;
    _Atomic uint32_t maximumObservedStereoSumMicro;
    _Atomic uint32_t faultFadeFramesRemaining;
    bool hasPrevious;
    double lastReferenceFrame;
    double lastAcousticSeconds;
    double lastEvaluationSeconds;
    uint64_t lastOutputFrame;
    bool hasOutputAnchor;
    double lastOutputAnchorFrame;
    double lastOutputAnchorSeconds;
};

static bool finite_nonnegative(double n) {
    return isfinite(n) && n >= 0;
}

static bool valid_plan(const N60FFDeadlinePlan *p) {
    if (!p || !p->routeLeaseToken || !p->synchronizedClockToken ||
        !isfinite(p->sampleRate) || p->sampleRate < 8000 ||
        p->sampleRate > 192000 ||
        !finite_nonnegative(p->conservativeNoiseLeadSeconds) ||
        !finite_nonnegative(p->referenceAcquisitionSeconds) ||
        !finite_nonnegative(p->processingSeconds) ||
        !finite_nonnegative(p->commandToSeatSeconds) ||
        !finite_nonnegative(p->totalSafetyGuardSeconds) ||
        p->referenceAcquisitionSeconds <= 0 ||
        p->processingSeconds <= 0 || p->commandToSeatSeconds <= 0 ||
        p->totalSafetyGuardSeconds < 0.002 ||
        p->conservativeNoiseLeadSeconds > 1.0 ||
        p->referenceAcquisitionSeconds > 0.25 ||
        p->processingSeconds > 0.25 || p->commandToSeatSeconds > 0.5 ||
        p->totalSafetyGuardSeconds > 0.1) return false;
    return p->conservativeNoiseLeadSeconds >
        p->referenceAcquisitionSeconds + p->processingSeconds +
        p->commandToSeatSeconds + p->totalSafetyGuardSeconds;
}

N60FeedForwardDeadlineBridge *N60FFDeadlineBridgeCreate(
    uint32_t capacity,
    const N60FFDeadlinePlan *plan,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount
) {
    if (!valid_plan(plan) || !leftTaps || !rightTaps ||
        tapCount == 0 || tapCount > N60_FF_DEADLINE_MAX_TAPS ||
        capacity < 256 || capacity > N60_FF_DEADLINE_MAX_FRAMES ||
        (capacity & (capacity - 1u)) != 0) return NULL;

    N60FeedForwardDeadlineBridge *b = calloc(1u, sizeof(*b));
    if (!b) return NULL;
    b->records = calloc(capacity, sizeof(*b->records));
    b->fir = N60FeedForwardPreviewFIRCreate();
    if (!b->records || !b->fir ||
        !N60FeedForwardPreviewFIRConfigure(
            b->fir, leftTaps, rightTaps, tapCount
        )) {
        N60FeedForwardPreviewFIRDestroy(b->fir);
        free(b->records);
        free(b);
        return NULL;
    }
    b->capacity = capacity;
    b->mask = capacity - 1u;
    b->plan = *plan;
    return b;
}

void N60FFDeadlineBridgeDestroy(N60FeedForwardDeadlineBridge *b) {
    if (!b) return;
    N60FeedForwardPreviewFIRDestroy(b->fir);
    free(b->records);
    free(b);
}

static void halt_bridge(N60FeedForwardDeadlineBridge *b, N60FFDeadlineFault why) {
    if (!b || atomic_load_explicit(&b->halted, memory_order_acquire)) return;
    atomic_store_explicit(&b->firstFault, (int)why, memory_order_relaxed);
    atomic_store_explicit(&b->faultFadeFramesRemaining,
                          N60_FF_SHADOW_FADE_FRAMES, memory_order_relaxed);
    atomic_fetch_add_explicit(&b->rejected, 1, memory_order_relaxed);
    N60FeedForwardPreviewFIRReset(b->fir);
    // Consumer may race with this halt; it always rechecks halted before
    // returning any metadata. No audio exists in the ring.
    atomic_store_explicit(&b->halted, true, memory_order_release);
}

void N60FFDeadlineBridgeStop(N60FeedForwardDeadlineBridge *b) {
    // Only call after producer stops; this is a terminal state.
    halt_bridge(b, N60FFDeadlineFaultStopped);
}

bool N60FFDeadlineBridgeAdvanceFaultFade(
    N60FeedForwardDeadlineBridge *b, uint32_t frames
) {
    if (!b || !frames ||
        !atomic_load_explicit(&b->halted, memory_order_acquire)) return false;
    const uint32_t remaining = atomic_load_explicit(
        &b->faultFadeFramesRemaining, memory_order_relaxed);
    const uint32_t advanced = frames < remaining ? frames : remaining;
    atomic_store_explicit(&b->faultFadeFramesRemaining,
                          remaining - advanced, memory_order_release);
    return true;
}

bool N60FFDeadlineBridgeProcess(
    N60FeedForwardDeadlineBridge *b,
    const N60FFDeadlineReference *r,
    const N60FFDeadlineOutputWitness *o
) {
    if (!b || atomic_load_explicit(&b->halted, memory_order_acquire))
        return false;
    if (!r || !o) {
        halt_bridge(b, N60FFDeadlineFaultBadReference);
        return false;
    }
    const N60FFDeadlinePlan *p = &b->plan;
    if (o->routeLeaseToken != p->routeLeaseToken ||
        o->synchronizedClockToken != p->synchronizedClockToken ||
        !isfinite(o->sampleRate) ||
        fabs(o->sampleRate - p->sampleRate) >= 0.5) {
        halt_bridge(b, N60FFDeadlineFaultRouteChange);
        return false;
    }
    if (!finite_nonnegative(r->referenceFrame) ||
        !finite_nonnegative(r->acousticAtHostSeconds) ||
        !finite_nonnegative(r->availableAtHostSeconds) ||
        !finite_nonnegative(r->evaluatedAtHostSeconds) ||
        !isfinite(r->referenceSample) ||
        fabsf(r->referenceSample) > 1.0f ||
        r->acousticAtHostSeconds > r->availableAtHostSeconds ||
        r->availableAtHostSeconds > r->evaluatedAtHostSeconds ||
        r->availableAtHostSeconds - r->acousticAtHostSeconds >
            p->referenceAcquisitionSeconds + 0.002) {
        halt_bridge(b, N60FFDeadlineFaultBadReference);
        return false;
    }
    if (!finite_nonnegative(o->firstFrame) ||
        !finite_nonnegative(o->firstFrameHostSeconds) ||
        !finite_nonnegative(o->witnessedAtSeconds) ||
        o->firstFrame > 1.0e12 ||
        r->evaluatedAtHostSeconds < o->witnessedAtSeconds ||
        r->evaluatedAtHostSeconds - o->witnessedAtSeconds > 0.050 ||
        fabs(o->firstFrameHostSeconds - o->witnessedAtSeconds) > 0.050) {
        halt_bridge(b, N60FFDeadlineFaultStaleWitness);
        return false;
    }

    if (b->hasPrevious &&
        (fabs(r->referenceFrame - b->lastReferenceFrame - 1.0) > 0.05 ||
         fabs((r->acousticAtHostSeconds - b->lastAcousticSeconds)
              * p->sampleRate - 1.0) > 0.05 ||
         r->evaluatedAtHostSeconds < b->lastEvaluationSeconds)) {
        halt_bridge(b, N60FFDeadlineFaultClockDiscontinuity);
        return false;
    }
    // A fresh output-clock anchor must agree with the previous anchor's
    // frame/host-time mapping. Reject hot-swaps even if route tokens are
    // incorrectly reused by a caller.
    if (b->hasOutputAnchor &&
        fabs((o->firstFrame - b->lastOutputAnchorFrame) / p->sampleRate -
             (o->firstFrameHostSeconds - b->lastOutputAnchorSeconds)) >
             0.0005) {
        halt_bridge(b, N60FFDeadlineFaultClockDiscontinuity);
        return false;
    }

    const double deadline = r->acousticAtHostSeconds +
        p->conservativeNoiseLeadSeconds - p->commandToSeatSeconds -
        p->totalSafetyGuardSeconds;
    const double earliest = fmax(
        r->evaluatedAtHostSeconds,
        r->availableAtHostSeconds + p->processingSeconds
    );
    if (!isfinite(deadline) || deadline <= earliest) {
        halt_bridge(b, N60FFDeadlineFaultMissedDeadline);
        return false;
    }
    // Round DOWN to the nearest output sample, never after the deadline.
    // Floor the absolute sample frame once to avoid fractional-frame drift.
    const double planned = floor(o->firstFrame +
        (deadline - o->firstFrameHostSeconds) * p->sampleRate);
    if (!finite_nonnegative(planned) || planned > 1.0e12) {
        halt_bridge(b, N60FFDeadlineFaultStaleWitness);
        return false;
    }
    const double at = o->firstFrameHostSeconds +
        (planned - o->firstFrame) / p->sampleRate;
    if (!isfinite(at) || at < earliest || at > deadline ||
        (b->hasPrevious && (uint64_t)planned <= b->lastOutputFrame)) {
        halt_bridge(b, N60FFDeadlineFaultMissedDeadline);
        return false;
    }

    const uint64_t write =
        atomic_load_explicit(&b->writeIndex, memory_order_relaxed);
    const uint64_t read =
        atomic_load_explicit(&b->readIndex, memory_order_acquire);
    if (write - read >= b->capacity) {
        halt_bridge(b, N60FFDeadlineFaultOverflow);
        return false;
    }

    // Native FIR runs on preallocated state, no memory allocation. Its
    // anti-noise outputs are local, immediately discarded, never queued.
    float discardedLeft = 0, discardedRight = 0;
    N60FeedForwardPreviewFIRProcessFrame(
        b->fir, r->referenceSample, &discardedLeft, &discardedRight
    );
    // Fail instead of treating native FIR limiting as an acceptable live
    // output condition. Both speaker channels share the total headroom.
    const N60FeedForwardPreviewFIRSnapshot firState =
        N60FeedForwardPreviewFIRGetSnapshot(b->fir);
    const float sum = fabsf(discardedLeft) + fabsf(discardedRight);
    if (!isfinite(discardedLeft) || !isfinite(discardedRight) ||
        !isfinite(sum) ||
        fabsf(discardedLeft) > N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK ||
        fabsf(discardedRight) > N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK ||
        sum > N60_FF_SHADOW_MAX_STEREO_SUM ||
        firState.sanitizedInputs != 0 ||
        firState.limitedOutputFrames != 0) {
        halt_bridge(b, N60FFDeadlineFaultOutputEnvelope);
        return false;
    }
    // Quantized diagnostic peak only. No raw anti-noise PCM escapes.
    const uint32_t currentPeak = (uint32_t)roundf(sum * 1000000.0f);
    const uint32_t previousPeak = atomic_load_explicit(
        &b->maximumObservedStereoSumMicro, memory_order_relaxed);
    if (currentPeak > previousPeak) {
        atomic_store_explicit(&b->maximumObservedStereoSumMicro,
                              currentPeak, memory_order_relaxed);
    }

    b->records[(uint32_t)write & b->mask] = (N60FFDeadlineRecord){
        .referenceFrame = r->referenceFrame,
        .hypotheticalOutputFrame = (uint64_t)planned,
        .hypotheticalOutputTimeSeconds = at,
        .estimatedProcessingSlackSeconds = at - earliest,
    };
    b->hasPrevious = true;
    b->lastReferenceFrame = r->referenceFrame;
    b->lastAcousticSeconds = r->acousticAtHostSeconds;
    b->lastEvaluationSeconds = r->evaluatedAtHostSeconds;
    b->lastOutputFrame = (uint64_t)planned;
    b->hasOutputAnchor = true;
    b->lastOutputAnchorFrame = o->firstFrame;
    b->lastOutputAnchorSeconds = o->firstFrameHostSeconds;
    atomic_store_explicit(&b->writeIndex, write + 1u, memory_order_release);
    atomic_fetch_add_explicit(&b->accepted, 1u, memory_order_relaxed);
    return true;
}

uint32_t N60FFDeadlineBridgeRead(
    N60FeedForwardDeadlineBridge *b,
    N60FFDeadlineRecord *destination,
    uint32_t maxRecords
) {
    if (!b || !destination || !maxRecords ||
        atomic_load_explicit(&b->halted, memory_order_acquire)) return 0;
    const uint64_t read =
        atomic_load_explicit(&b->readIndex, memory_order_relaxed);
    const uint64_t write =
        atomic_load_explicit(&b->writeIndex, memory_order_acquire);
    const uint64_t available = write - read;
    uint32_t count = (uint32_t)(available < maxRecords ? available : maxRecords);
    for (uint32_t i = 0; i < count; ++i) {
        destination[i] = b->records[(uint32_t)(read + i) & b->mask];
    }
    if (atomic_load_explicit(&b->halted, memory_order_acquire)) return 0;
    if (count) {
        atomic_store_explicit(&b->readIndex, read + count, memory_order_release);
    }
    return count;
}

N60FFDeadlineSnapshot N60FFDeadlineBridgeGetSnapshot(
    const N60FeedForwardDeadlineBridge *b
) {
    if (!b) return (N60FFDeadlineSnapshot){0};
    const uint64_t read = atomic_load_explicit(&b->readIndex, memory_order_acquire);
    const uint64_t write = atomic_load_explicit(&b->writeIndex, memory_order_acquire);
    const bool halted = atomic_load_explicit(&b->halted, memory_order_acquire);
    const uint32_t remaining = atomic_load_explicit(
        &b->faultFadeFramesRemaining, memory_order_acquire);
    return (N60FFDeadlineSnapshot){
        .queuedRecords = halted ? 0 :
            (uint32_t)((write - read) < b->capacity ? write - read : b->capacity),
        .capacityRecords = b->capacity,
        .acceptedRecords = atomic_load_explicit(&b->accepted, memory_order_relaxed),
        .rejectedRecords = atomic_load_explicit(&b->rejected, memory_order_relaxed),
        .firstFault = (N60FFDeadlineFault)atomic_load_explicit(
            &b->firstFault, memory_order_acquire
        ),
        .maximumObservedStereoSumMicro = atomic_load_explicit(
            &b->maximumObservedStereoSumMicro, memory_order_relaxed),
        .faultFadeFramesRemaining = remaining,
        .simulatedFaultFadeGain = halted
            ? (double)remaining / (double)N60_FF_SHADOW_FADE_FRAMES : 1.0,
        .simulatedBypassReached = halted && remaining == 0,
        .halted = halted,
        .outputConnected = false,
        .liveANCQualified = false,
    };
}
