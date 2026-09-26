#ifndef N60FractionalDelay_h
#define N60FractionalDelay_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_INTERCHANNEL_DELAY_MAX_MS 20.0
#define N60_FRACTIONAL_DELAY_CAPACITY 8192u
#define N60_FRACTIONAL_DELAY_MAX_ORDER 3u
#define N60_FRACTIONAL_DELAY_COMMON_FRAMES 2u

typedef struct {
    uint32_t integerFrames;
    uint32_t order;
    float denominator[N60_FRACTIONAL_DELAY_MAX_ORDER + 1u];
} N60FractionalDelayTap;

typedef struct {
    float inputHistory[N60_FRACTIONAL_DELAY_MAX_ORDER];
    float outputHistory[N60_FRACTIONAL_DELAY_MAX_ORDER];
} N60FractionalDelayAllPassState;

typedef struct {
    bool enabled;
    double signedDelayMs;
    uint32_t commonLatencyFrames;
    N60FractionalDelayTap left;
    N60FractionalDelayTap right;
} N60InterChannelDelaySnapshot;

typedef struct {
    float historyLeft[N60_FRACTIONAL_DELAY_CAPACITY];
    float historyRight[N60_FRACTIONAL_DELAY_CAPACITY];
    uint32_t writeIndex;

    N60InterChannelDelaySnapshot current;
    N60InterChannelDelaySnapshot pending;
    N60InterChannelDelaySnapshot queued;
    N60FractionalDelayAllPassState currentLeftState;
    N60FractionalDelayAllPassState currentRightState;
    N60FractionalDelayAllPassState pendingLeftState;
    N60FractionalDelayAllPassState pendingRightState;

    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
    uint32_t queuedTransitionFrames;
    bool hasQueued;
} N60InterChannelDelayRuntime;

static inline N60FractionalDelayTap N60FractionalDelayTapMakeInteger(uint32_t frames) {
    N60FractionalDelayTap tap = {0};
    tap.integerFrames = frames;
    tap.order = 0;
    tap.denominator[0] = 1.0f;
    return tap;
}

static inline double N60FractionalDelayBinomial(uint32_t n, uint32_t k) {
    static const double table[4][4] = {
        {1.0, 0.0, 0.0, 0.0},
        {1.0, 1.0, 0.0, 0.0},
        {1.0, 2.0, 1.0, 0.0},
        {1.0, 3.0, 3.0, 1.0},
    };
    return n <= 3u && k <= n ? table[n][k] : 0.0;
}

// Control-plane design of a causal Thiran all-pass approximation for totalFrames.
// Exact integer delays bypass the all-pass completely. For fractional delays, use
// the highest stable order available without changing the requested total delay.
static inline bool N60FractionalDelayTapMake(double totalFrames, N60FractionalDelayTap *tap) {
    if (tap == NULL || !isfinite(totalFrames) || totalFrames < 0.0
        || totalFrames >= (double)(N60_FRACTIONAL_DELAY_CAPACITY - 1u)) {
        return false;
    }

    double floorFramesDouble = floor(totalFrames);
    uint32_t floorFrames = (uint32_t)floorFramesDouble;
    double fraction = totalFrames - floorFramesDouble;
    if (fraction < 1.0e-6 || (1.0 - fraction) < 1.0e-6) {
        uint32_t rounded = (uint32_t)llround(totalFrames);
        *tap = N60FractionalDelayTapMakeInteger(rounded);
        return rounded < N60_FRACTIONAL_DELAY_CAPACITY;
    }

    uint32_t order = floorFrames >= 2u ? 3u : floorFrames + 1u;
    uint32_t integerFrames = floorFrames - (order - 1u);
    double desiredAllPassDelay = (double)(order - 1u) + fraction;

    N60FractionalDelayTap designed = {0};
    designed.integerFrames = integerFrames;
    designed.order = order;
    designed.denominator[0] = 1.0f;

    for (uint32_t k = 1; k <= order; ++k) {
        double product = 1.0;
        for (uint32_t n = 0; n <= order; ++n) {
            double numerator = desiredAllPassDelay - (double)order + (double)n;
            double denominator = desiredAllPassDelay - (double)order + (double)k + (double)n;
            if (!isfinite(denominator) || fabs(denominator) < 1.0e-12) return false;
            product *= numerator / denominator;
        }
        double coefficient = ((k & 1u) ? -1.0 : 1.0)
            * N60FractionalDelayBinomial(order, k)
            * product;
        if (!isfinite(coefficient) || fabs(coefficient) >= 1.0) return false;
        designed.denominator[k] = (float)coefficient;
    }

    *tap = designed;
    return true;
}

static inline bool N60FractionalDelayTapIsValid(N60FractionalDelayTap tap) {
    if (tap.integerFrames >= N60_FRACTIONAL_DELAY_CAPACITY || tap.order > N60_FRACTIONAL_DELAY_MAX_ORDER) return false;
    if (tap.order == 0u) return tap.denominator[0] == 1.0f || tap.denominator[0] == 0.0f;
    if (!isfinite(tap.denominator[0]) || fabsf(tap.denominator[0] - 1.0f) > 1.0e-6f) return false;
    for (uint32_t k = 1; k <= tap.order; ++k) {
        if (!isfinite(tap.denominator[k]) || fabsf(tap.denominator[k]) >= 1.0f) return false;
    }
    return true;
}

static inline N60InterChannelDelaySnapshot N60InterChannelDelaySnapshotMakeBypassed(void) {
    N60InterChannelDelaySnapshot snapshot = {0};
    snapshot.left = N60FractionalDelayTapMakeInteger(0u);
    snapshot.right = N60FractionalDelayTapMakeInteger(0u);
    return snapshot;
}

// Positive signedDelayMs delays R relative to L. Negative delays L relative to R.
// A common two-frame delay is added only when alignment is enabled so the
// fractional branch can use a third-order Thiran section. This common delay does
// not alter the requested inter-channel offset.
static inline bool N60InterChannelDelaySnapshotMake(
    double sampleRate,
    double signedDelayMs,
    N60InterChannelDelaySnapshot *snapshot
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(signedDelayMs)
        || signedDelayMs < -N60_INTERCHANNEL_DELAY_MAX_MS
        || signedDelayMs > N60_INTERCHANNEL_DELAY_MAX_MS) {
        return false;
    }

    if (fabs(signedDelayMs) < 1.0e-9) {
        *snapshot = N60InterChannelDelaySnapshotMakeBypassed();
        return true;
    }

    double relativeFrames = fabs(signedDelayMs) * sampleRate / 1000.0;
    double commonFrames = (double)N60_FRACTIONAL_DELAY_COMMON_FRAMES;
    N60FractionalDelayTap directTap = {0};
    N60FractionalDelayTap delayedTap = {0};
    if (!N60FractionalDelayTapMake(commonFrames, &directTap)
        || !N60FractionalDelayTapMake(commonFrames + relativeFrames, &delayedTap)) {
        return false;
    }

    N60InterChannelDelaySnapshot made = {0};
    made.enabled = true;
    made.signedDelayMs = signedDelayMs;
    made.commonLatencyFrames = N60_FRACTIONAL_DELAY_COMMON_FRAMES;
    if (signedDelayMs > 0.0) {
        made.left = directTap;
        made.right = delayedTap;
    } else {
        made.left = delayedTap;
        made.right = directTap;
    }
    *snapshot = made;
    return true;
}

static inline bool N60InterChannelDelaySnapshotIsValid(
    N60InterChannelDelaySnapshot snapshot,
    double sampleRate
) {
    if (!isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(snapshot.signedDelayMs)
        || snapshot.signedDelayMs < -N60_INTERCHANNEL_DELAY_MAX_MS
        || snapshot.signedDelayMs > N60_INTERCHANNEL_DELAY_MAX_MS
        || !N60FractionalDelayTapIsValid(snapshot.left)
        || !N60FractionalDelayTapIsValid(snapshot.right)) {
        return false;
    }
    if (!snapshot.enabled) {
        return fabs(snapshot.signedDelayMs) < 1.0e-9 && snapshot.commonLatencyFrames == 0u;
    }
    return snapshot.commonLatencyFrames == N60_FRACTIONAL_DELAY_COMMON_FRAMES;
}

static inline bool N60InterChannelDelaySnapshotsEqual(
    N60InterChannelDelaySnapshot lhs,
    N60InterChannelDelaySnapshot rhs
) {
    return lhs.enabled == rhs.enabled && lhs.signedDelayMs == rhs.signedDelayMs;
}

static inline void N60FractionalDelayAllPassStateReset(N60FractionalDelayAllPassState *state) {
    if (state != NULL) memset(state, 0, sizeof(*state));
}

static inline float N60FractionalDelayRead(
    const float *history,
    uint32_t writeIndex,
    N60FractionalDelayTap tap,
    N60FractionalDelayAllPassState *state
) {
    uint32_t readIndex = (writeIndex + N60_FRACTIONAL_DELAY_CAPACITY - tap.integerFrames)
        % N60_FRACTIONAL_DELAY_CAPACITY;
    float input = history[readIndex];
    if (tap.order == 0u) return input;

    uint32_t order = tap.order;
    float output = tap.denominator[order] * input;
    for (uint32_t k = 1; k <= order; ++k) {
        output += tap.denominator[order - k] * state->inputHistory[k - 1u]
            - tap.denominator[k] * state->outputHistory[k - 1u];
    }
    for (uint32_t k = order - 1u; k > 0u; --k) {
        state->inputHistory[k] = state->inputHistory[k - 1u];
        state->outputHistory[k] = state->outputHistory[k - 1u];
    }
    state->inputHistory[0] = input;
    state->outputHistory[0] = output;
    return output;
}

static inline void N60InterChannelDelayRuntimeReset(
    N60InterChannelDelayRuntime *runtime,
    N60InterChannelDelaySnapshot snapshot
) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    runtime->current = snapshot;
    runtime->pending = snapshot;
}

static inline void N60InterChannelDelayRuntimeBeginTransition(
    N60InterChannelDelayRuntime *runtime,
    N60InterChannelDelaySnapshot snapshot,
    uint32_t transitionFrames
) {
    runtime->pending = snapshot;
    N60FractionalDelayAllPassStateReset(&runtime->pendingLeftState);
    N60FractionalDelayAllPassStateReset(&runtime->pendingRightState);
    runtime->transitionFramesTotal = transitionFrames > 0u ? transitionFrames : 1u;
    runtime->transitionFramesRemaining = runtime->transitionFramesTotal;
}

// If the UI produces another target while a transition is active, queue only the
// newest target. This avoids replacing an audible crossfade branch mid-ramp.
static inline void N60InterChannelDelayRuntimeSchedule(
    N60InterChannelDelayRuntime *runtime,
    N60InterChannelDelaySnapshot snapshot,
    uint32_t transitionFrames
) {
    if (runtime == NULL) return;
    if (runtime->transitionFramesRemaining != 0u) {
        if (N60InterChannelDelaySnapshotsEqual(runtime->pending, snapshot)) return;
        runtime->queued = snapshot;
        runtime->queuedTransitionFrames = transitionFrames;
        runtime->hasQueued = true;
        return;
    }
    if (N60InterChannelDelaySnapshotsEqual(runtime->current, snapshot)) return;
    N60InterChannelDelayRuntimeBeginTransition(runtime, snapshot, transitionFrames);
}

static inline void N60InterChannelDelayRuntimePromotePending(N60InterChannelDelayRuntime *runtime) {
    runtime->current = runtime->pending;
    runtime->currentLeftState = runtime->pendingLeftState;
    runtime->currentRightState = runtime->pendingRightState;
    runtime->transitionFramesTotal = 0u;
    runtime->transitionFramesRemaining = 0u;

    if (runtime->hasQueued) {
        N60InterChannelDelaySnapshot queued = runtime->queued;
        uint32_t frames = runtime->queuedTransitionFrames;
        runtime->hasQueued = false;
        if (!N60InterChannelDelaySnapshotsEqual(runtime->current, queued)) {
            N60InterChannelDelayRuntimeBeginTransition(runtime, queued, frames);
        }
    }
}

static inline void N60InterChannelDelayRuntimeProcess(
    N60InterChannelDelayRuntime *runtime,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (runtime == NULL || outputLeft == NULL || outputRight == NULL) return;

    runtime->historyLeft[runtime->writeIndex] = inputLeft;
    runtime->historyRight[runtime->writeIndex] = inputRight;

    float currentLeft = N60FractionalDelayRead(
        runtime->historyLeft, runtime->writeIndex, runtime->current.left, &runtime->currentLeftState);
    float currentRight = N60FractionalDelayRead(
        runtime->historyRight, runtime->writeIndex, runtime->current.right, &runtime->currentRightState);

    if (runtime->transitionFramesRemaining == 0u) {
        *outputLeft = currentLeft;
        *outputRight = currentRight;
    } else {
        float pendingLeft = N60FractionalDelayRead(
            runtime->historyLeft, runtime->writeIndex, runtime->pending.left, &runtime->pendingLeftState);
        float pendingRight = N60FractionalDelayRead(
            runtime->historyRight, runtime->writeIndex, runtime->pending.right, &runtime->pendingRightState);
        uint32_t completed = runtime->transitionFramesTotal - runtime->transitionFramesRemaining + 1u;
        float mix = (float)completed / (float)runtime->transitionFramesTotal;
        *outputLeft = currentLeft + (pendingLeft - currentLeft) * mix;
        *outputRight = currentRight + (pendingRight - currentRight) * mix;
        runtime->transitionFramesRemaining -= 1u;
        if (runtime->transitionFramesRemaining == 0u) {
            N60InterChannelDelayRuntimePromotePending(runtime);
        }
    }

    runtime->writeIndex = (runtime->writeIndex + 1u) % N60_FRACTIONAL_DELAY_CAPACITY;
}

#ifdef __cplusplus
}
#endif

#endif
