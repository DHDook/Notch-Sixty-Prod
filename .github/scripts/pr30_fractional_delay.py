from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Portable, independently-authored fractional-delay primitive.
# A 3rd-order Thiran all-pass is used for non-integer delay when possible.
# A 2-frame common alignment delay lets both channels use the higher-order
# approximation for sub-sample relative timing while preserving exact relative
# delay and unity magnitude. Zero configured delay remains a true bypass.
# ---------------------------------------------------------------------------
Path("NotchSixty/Audio/Realtime/N60FractionalDelay.h").write_text(r'''#ifndef N60FractionalDelay_h
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
''')


# ---------------------------------------------------------------------------
# Render graph state, validation, control-plane setter, runtime and diagnostics.
# ---------------------------------------------------------------------------
p = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
s = p.read_text()
s = replace_once(
    s,
    '#include "N60Dynamics.h"\n#include "N60Protection.h"',
    '#include "N60Dynamics.h"\n#include "N60FractionalDelay.h"\n#include "N60Protection.h"',
    "fractional delay include",
)
s = replace_once(
    s,
    """    bool bypassed;\n    N60AuditionMode auditionMode;\n    uint32_t latencyFrames;""",
    """    bool bypassed;\n    N60AuditionMode auditionMode;\n    N60InterChannelDelaySnapshot interChannelDelay;\n    uint32_t latencyFrames;""",
    "graph delay snapshot",
)
s = replace_once(
    s,
    """    bool bypassed;\n    N60AuditionMode auditionMode;\n    float inputGainLinear;""",
    """    bool bypassed;\n    N60AuditionMode auditionMode;\n    double interChannelDelayMs;\n    uint32_t interChannelAlignmentLatencyFrames;\n    float inputGainLinear;""",
    "diagnostics delay fields",
)
s = replace_once(
    s,
    """void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);\n""",
    """void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);\nbool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double signedDelayMs\n);\n""",
    "delay setter declaration",
)
p.write_text(s)

p = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
s = p.read_text()
s = replace_once(
    s,
    """    N60SmoothedGain balanceGainLeft;\n    N60SmoothedGain balanceGainRight;\n    float referenceDelayLeft""",
    """    N60SmoothedGain balanceGainLeft;\n    N60SmoothedGain balanceGainRight;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;\n    float referenceDelayLeft""",
    "delay runtime member",
)
s = replace_once(
    s,
    """        || snapshot.auditionMode < N60AuditionModeProcessed\n        || snapshot.auditionMode > N60AuditionModeDelta\n        || (snapshot.auditionMode != N60AuditionModeProcessed""",
    """        || snapshot.auditionMode < N60AuditionModeProcessed\n        || snapshot.auditionMode > N60AuditionModeDelta\n        || !N60InterChannelDelaySnapshotIsValid(snapshot.interChannelDelay, snapshot.sampleRate)\n        || (snapshot.auditionMode != N60AuditionModeProcessed""",
    "delay snapshot validation",
)
s = replace_once(
    s,
    """        reset_smoothed_gain(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear);\n        reset_smoothed_gain(&kernel->balanceGainRight, snapshot->balanceGainRightLinear);\n    } else {""",
    """        reset_smoothed_gain(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear);\n        reset_smoothed_gain(&kernel->balanceGainRight, snapshot->balanceGainRightLinear);\n        N60InterChannelDelayRuntimeReset(&kernel->interChannelDelayRuntime, snapshot->interChannelDelay);\n    } else {""",
    "first delay runtime prep",
)
s = replace_once(
    s,
    """        schedule_gain_transition(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear, gainFrames);\n        schedule_gain_transition(&kernel->balanceGainRight, snapshot->balanceGainRightLinear, gainFrames);\n    }\n\n    if (sampleRateChanged""",
    """        schedule_gain_transition(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear, gainFrames);\n        schedule_gain_transition(&kernel->balanceGainRight, snapshot->balanceGainRightLinear, gainFrames);\n        N60InterChannelDelayRuntimeSchedule(&kernel->interChannelDelayRuntime, snapshot->interChannelDelay, gainFrames);\n    }\n\n    if (sampleRateChanged""",
    "delay transition schedule",
)
s = replace_once(
    s,
    """    snapshot.bypassed = false;\n    snapshot.auditionMode = N60AuditionModeProcessed;\n    snapshot.latencyFrames = 0;""",
    """    snapshot.bypassed = false;\n    snapshot.auditionMode = N60AuditionModeProcessed;\n    snapshot.interChannelDelay = N60InterChannelDelaySnapshotMakeBypassed();\n    snapshot.latencyFrames = 0;""",
    "unity graph delay state",
)
s = replace_once(
    s,
    """void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {\n    if (snapshot == NULL) return;\n    memset(snapshot->eqBands, 0, sizeof(snapshot->eqBands));\n    memset(snapshot->eqBandChannelMasks, 0, sizeof(snapshot->eqBandChannelMasks));\n    snapshot->eqBandCount = 0;\n}\n\n""",
    """void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {\n    if (snapshot == NULL) return;\n    memset(snapshot->eqBands, 0, sizeof(snapshot->eqBands));\n    memset(snapshot->eqBandChannelMasks, 0, sizeof(snapshot->eqBandChannelMasks));\n    snapshot->eqBandCount = 0;\n}\n\nbool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,\n    double signedDelayMs\n) {\n    if (snapshot == NULL) return false;\n    N60InterChannelDelaySnapshot delay = {0};\n    if (!N60InterChannelDelaySnapshotMake(snapshot->sampleRate, signedDelayMs, &delay)) return false;\n    snapshot->interChannelDelay = delay;\n    return true;\n}\n\n""",
    "delay setter implementation",
)
s = replace_once(
    s,
    """    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);\n    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    kernel->referenceDelayWriteIndex = 0;""",
    """    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);\n    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    N60InterChannelDelayRuntimeReset(&kernel->interChannelDelayRuntime, initial.interChannelDelay);\n    kernel->referenceDelayWriteIndex = 0;""",
    "delay runtime create reset",
)
s = replace_once(
    s,
    """    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);\n    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    memset(kernel->referenceDelayLeft""",
    """    reset_smoothed_gain(&kernel->balanceGainLeft, 1.0f);\n    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    N60InterChannelDelayRuntimeReset(&kernel->interChannelDelayRuntime, N60InterChannelDelaySnapshotMakeBypassed());\n    memset(kernel->referenceDelayLeft""",
    "delay runtime explicit reset",
)
s = replace_once(
    s,
    """    } else {\n        meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);\n    }\n\n    float masterGain = next_gain_value(&kernel->masterGain);""",
    """    } else {\n        meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);\n    }\n\n    // Keep the alignment history warm even during Global Bypass, but discard the\n    // aligned copy while bypassed so Global Bypass remains the true raw escape path.\n    // Processed / Reference / Delta all receive the same speaker-alignment stage.\n    if (context->acquired) {\n        float alignedLeft = left;\n        float alignedRight = right;\n        N60InterChannelDelayRuntimeProcess(\n            &kernel->interChannelDelayRuntime, left, right, &alignedLeft, &alignedRight);\n        if (!context->snapshot.bypassed) {\n            left = alignedLeft;\n            right = alignedRight;\n        }\n    }\n\n    float masterGain = next_gain_value(&kernel->masterGain);""",
    "delay render placement",
)
s = replace_once(
    s,
    """        diagnostics.bypassed = context.snapshot.bypassed;\n        diagnostics.auditionMode = context.snapshot.auditionMode;\n        diagnostics.inputGainLinear""",
    """        diagnostics.bypassed = context.snapshot.bypassed;\n        diagnostics.auditionMode = context.snapshot.auditionMode;\n        diagnostics.interChannelDelayMs = context.snapshot.interChannelDelay.signedDelayMs;\n        diagnostics.interChannelAlignmentLatencyFrames = context.snapshot.interChannelDelay.commonLatencyFrames;\n        diagnostics.inputGainLinear""",
    "delay diagnostics",
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Swift playback control plane and graph publication.
# ---------------------------------------------------------------------------
p = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
s = p.read_text()
s = replace_once(
    s,
    """struct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n\n    var balance: Double\n    var globalBypassed: Bool\n    var auditionMode: AuditionMode\n\n    init(\n        balance: Double = 0,\n        globalBypassed: Bool = false,""",
    """struct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n    static let interChannelDelayRange = -20.0...20.0\n\n    var balance: Double\n    var interChannelDelayMs: Double\n    var globalBypassed: Bool\n    var auditionMode: AuditionMode\n\n    init(\n        balance: Double = 0,\n        interChannelDelayMs: Double = 0,\n        globalBypassed: Bool = false,""",
    "playback delay state",
)
s = replace_once(
    s,
    """        self.balance = balance\n        self.globalBypassed = globalBypassed""",
    """        self.balance = balance\n        self.interChannelDelayMs = interChannelDelayMs\n        self.globalBypassed = globalBypassed""",
    "playback delay init",
)
s = replace_once(
    s,
    """enum PlaybackControlConfigurationError: Error, LocalizedError, Equatable {\n    case invalidBalance(Double)\n\n    var errorDescription: String? {\n        switch self {\n        case .invalidBalance(let value):\n            return \"Channel balance \\(value) is outside the supported -1...+1 range.\"\n        }\n    }\n}""",
    """enum PlaybackControlConfigurationError: Error, LocalizedError, Equatable {\n    case invalidBalance(Double)\n    case invalidInterChannelDelay(Double)\n\n    var errorDescription: String? {\n        switch self {\n        case .invalidBalance(let value):\n            return \"Channel balance \\(value) is outside the supported -1...+1 range.\"\n        case .invalidInterChannelDelay(let value):\n            return \"Inter-channel delay \\(value) ms is outside the supported -20...+20 ms range.\"\n        }\n    }\n}""",
    "delay validation error",
)
# Publish the precomputed C delay snapshot from the control-plane graph builder.
s = replace_once(
    s,
    """        graph.bypassed = playbackConfiguration.globalBypassed\n        graph.auditionMode = playbackConfiguration.auditionMode.cType\n        graph.eqBypassed = bypassed""",
    """        graph.bypassed = playbackConfiguration.globalBypassed\n        graph.auditionMode = playbackConfiguration.auditionMode.cType\n        guard N60DSPGraphSnapshotSetInterChannelDelay(&graph, playbackConfiguration.interChannelDelayMs) else {\n            throw PlaybackControlConfigurationError.invalidInterChannelDelay(playbackConfiguration.interChannelDelayMs)\n        }\n        graph.eqBypassed = bypassed""",
    "publish delay snapshot",
)
p.write_text(s)

p = Path("NotchSixty/Audio/AudioIOEngine.swift")
s = p.read_text()
s = replace_once(
    s,
    """    func setChannelBalance(_ value: Double) throws {\n        guard value.isFinite, PlaybackControlConfiguration.balanceRange.contains(value) else {\n            throw PlaybackControlConfigurationError.invalidBalance(value)\n        }\n        var updated = playbackControlConfiguration\n        updated.balance = value\n        try applyPlaybackControlConfiguration(updated)\n    }\n\n    func setGlobalDSPBypassed""",
    """    func setChannelBalance(_ value: Double) throws {\n        guard value.isFinite, PlaybackControlConfiguration.balanceRange.contains(value) else {\n            throw PlaybackControlConfigurationError.invalidBalance(value)\n        }\n        var updated = playbackControlConfiguration\n        updated.balance = value\n        try applyPlaybackControlConfiguration(updated)\n    }\n\n    func setInterChannelDelayMs(_ value: Double) throws {\n        guard value.isFinite, PlaybackControlConfiguration.interChannelDelayRange.contains(value) else {\n            throw PlaybackControlConfigurationError.invalidInterChannelDelay(value)\n        }\n        var updated = playbackControlConfiguration\n        updated.interChannelDelayMs = value\n        try applyPlaybackControlConfiguration(updated)\n    }\n\n    func setGlobalDSPBypassed""",
    "delay engine setter",
)
s = replace_once(
    s,
    """        guard configuration.balance.isFinite,\n              PlaybackControlConfiguration.balanceRange.contains(configuration.balance) else {\n            throw PlaybackControlConfigurationError.invalidBalance(configuration.balance)\n        }\n\n        if let session""",
    """        guard configuration.balance.isFinite,\n              PlaybackControlConfiguration.balanceRange.contains(configuration.balance) else {\n            throw PlaybackControlConfigurationError.invalidBalance(configuration.balance)\n        }\n        guard configuration.interChannelDelayMs.isFinite,\n              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {\n            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)\n        }\n\n        if let session""",
    "delay playback validation",
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Engineering validation UI: visible from the same playback section from day one.
# ---------------------------------------------------------------------------
p = Path("NotchSixty/ContentView.swift")
s = p.read_text()
s = replace_once(
    s,
    """    private var balanceBinding: Binding<Double> {\n        Binding(get: { engine.playbackControlConfiguration.balance }, set: { try? engine.setChannelBalance($0) })\n    }\n\n\n    private var masterVolumeBinding""",
    """    private var balanceBinding: Binding<Double> {\n        Binding(get: { engine.playbackControlConfiguration.balance }, set: { try? engine.setChannelBalance($0) })\n    }\n\n    private var interChannelDelayBinding: Binding<Double> {\n        Binding(\n            get: { engine.playbackControlConfiguration.interChannelDelayMs },\n            set: { try? engine.setInterChannelDelayMs($0) }\n        )\n    }\n\n    private var masterVolumeBinding""",
    "delay UI binding",
)
s = replace_once(
    s,
    """            HStack(spacing: 12) {\n                Text(\"Balance\").frame(width: 90, alignment: .leading)\n                Text(\"L\").foregroundStyle(.secondary)\n                Slider(value: balanceBinding, in: PlaybackControlConfiguration.balanceRange, step: 0.01)\n                Text(\"R\").foregroundStyle(.secondary)\n                Text(engine.playbackControlConfiguration.balance.formatted(.number.precision(.fractionLength(2))))\n                    .monospacedDigit()\n                    .frame(width: 55)\n            }\n            Text(\"Processed runs""",
    """            HStack(spacing: 12) {\n                Text(\"Balance\").frame(width: 90, alignment: .leading)\n                Text(\"L\").foregroundStyle(.secondary)\n                Slider(value: balanceBinding, in: PlaybackControlConfiguration.balanceRange, step: 0.01)\n                Text(\"R\").foregroundStyle(.secondary)\n                Text(engine.playbackControlConfiguration.balance.formatted(.number.precision(.fractionLength(2))))\n                    .monospacedDigit()\n                    .frame(width: 55)\n            }\n            HStack(spacing: 12) {\n                Text(\"L/R delay\").frame(width: 90, alignment: .leading)\n                Text(\"Delay L\").foregroundStyle(.secondary)\n                Slider(value: interChannelDelayBinding, in: PlaybackControlConfiguration.interChannelDelayRange, step: 0.01)\n                Text(\"Delay R\").foregroundStyle(.secondary)\n                Text(\"\\(engine.playbackControlConfiguration.interChannelDelayMs, specifier: \"%+.2f\") ms\")\n                    .monospacedDigit()\n                    .frame(width: 84, alignment: .trailing)\n            }\n            Text(\"Signed speaker-alignment delay: negative delays Left; positive delays Right. Zero is transparent. Non-zero alignment uses a 2-frame common interpolation latency and fractional-sample phase-preserving timing.\")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n            Text(\"Processed runs""",
    "delay validation UI",
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Swift diagnostics wrapper.
# ---------------------------------------------------------------------------
p = Path("NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift")
s = p.read_text()
s = replace_once(
    s,
    """    let bypassed: Bool\n    let inputGainLinear: Float""",
    """    let bypassed: Bool\n    let interChannelDelayMs: Double\n    let interChannelAlignmentLatencyFrames: UInt32\n    let inputGainLinear: Float""",
    "diagnostics wrapper fields",
)
s = replace_once(
    s,
    """        bypassed = diagnostics.bypassed\n        inputGainLinear = diagnostics.inputGainLinear""",
    """        bypassed = diagnostics.bypassed\n        interChannelDelayMs = diagnostics.interChannelDelayMs\n        interChannelAlignmentLatencyFrames = diagnostics.interChannelAlignmentLatencyFrames\n        inputGainLinear = diagnostics.inputGainLinear""",
    "diagnostics wrapper init",
)
p.write_text(s)


# ---------------------------------------------------------------------------
# Deterministic timing, fractional accuracy, bypass and control-state tests.
# ---------------------------------------------------------------------------
p = Path("NotchSixtyTests/StereoPlaybackControlTests.swift")
s = p.read_text()
anchor = """    func testBalanceIsAttenuationOnlyAndCenterIsUnity() {\n"""
tests = r'''    func testZeroInterChannelDelayIsTransparent() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, 0))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<2_000 {
            let leftInput = Float(sin(Double(frame) * 0.031) * 0.6)
            let rightInput = Float(cos(Double(frame) * 0.027) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
            XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
        }
    }

    func testSignedInterChannelDelaySelectsCorrectChannelAndExactIntegerTiming() {
        for signedDelay in [5.0, -5.0] {
            guard let kernel = N60RenderKernelCreate() else {
                return XCTFail("Unable to create render kernel")
            }
            defer { N60RenderKernelDestroy(kernel) }
            var graph = N60DSPGraphSnapshotMakeUnity(48_000)
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, signedDelay))
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

            var leftImpulseIndex: Int?
            var rightImpulseIndex: Int?
            for frame in 0..<300 {
                let input: Float = frame == 0 ? 1 : 0
                var left: Float = 0
                var right: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
                if leftImpulseIndex == nil && abs(left) > 0.99 { leftImpulseIndex = frame }
                if rightImpulseIndex == nil && abs(right) > 0.99 { rightImpulseIndex = frame }
            }

            if signedDelay > 0 {
                XCTAssertEqual(leftImpulseIndex, 2)
                XCTAssertEqual(rightImpulseIndex, 242)
            } else {
                XCTAssertEqual(leftImpulseIndex, 242)
                XCTAssertEqual(rightImpulseIndex, 2)
            }
            let diagnostics = N60RenderKernelGetDiagnostics(kernel)
            XCTAssertEqual(diagnostics.interChannelDelayMs, signedDelay, accuracy: 0.000_001)
            XCTAssertEqual(diagnostics.interChannelAlignmentLatencyFrames, 2)
        }
    }

    func testFractionalInterChannelDelayTracksHalfSampleTimingWithUnityMagnitude() {
        let sampleRate = 48_000.0
        let relativeDelayFrames = 240.5
        let signedDelayMs = relativeDelayFrames / sampleRate * 1_000.0
        let frequency = 10_000.0
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, signedDelayMs))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var inputSquare = 0.0
        var rightSquare = 0.0
        var errorSquare = 0.0
        var measured = 0
        for frame in 0..<30_000 {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = Float(0.4 * sin(phase))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame > 5_000 {
                let expectedPhase = 2.0 * Double.pi * frequency
                    * (Double(frame) - relativeDelayFrames - 2.0) / sampleRate
                let expected = 0.4 * sin(expectedPhase)
                inputSquare += Double(sample * sample)
                rightSquare += Double(right * right)
                let error = Double(right) - expected
                errorSquare += error * error
                measured += 1
            }
        }
        let inputRMS = sqrt(inputSquare / Double(measured))
        let rightRMS = sqrt(rightSquare / Double(measured))
        let errorRMS = sqrt(errorSquare / Double(measured))
        XCTAssertEqual(rightRMS, inputRMS, accuracy: 0.000_2)
        XCTAssertLessThan(errorRMS, 0.002)
    }

    func testGlobalBypassRemainsRawWithInterChannelDelayConfigured() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, 12.34))
        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<4_000 {
            let leftInput = Float(sin(Double(frame) * 0.019) * 0.55)
            let rightInput = Float(cos(Double(frame) * 0.023) * 0.45)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
            XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
        }
    }

    func testInterChannelDelayRangeIsPartOfPlaybackConfiguration() {
        XCTAssertEqual(PlaybackControlConfiguration.interChannelDelayRange, -20.0...20.0)
        XCTAssertEqual(PlaybackControlConfiguration(interChannelDelayMs: 3.25).interChannelDelayMs, 3.25)
    }

'''
s = replace_once(s, anchor, tests + anchor, "fractional delay tests")
p.write_text(s)


# ---------------------------------------------------------------------------
# Documentation.
# ---------------------------------------------------------------------------
Path("docs/PHASE_TIME_ALIGNMENT.md").write_text(r'''# Phase & Time Alignment Foundation

PR30 adds two independent, commercially-authored phase/time primitives.

## All-Pass EQ

The minimum-phase EQ engine supports a second-order All-Pass section. Frequency and Q control phase rotation while magnitude remains unity. All-Pass is intentionally rejected by the current Linear Phase FIR EQ projection because that designer represents magnitude equalisation, not arbitrary phase-only requests.

## Signed inter-channel delay

`PlaybackControlConfiguration.interChannelDelayMs` supports **−20...+20 ms**:

- positive values delay **Right** relative to Left;
- negative values delay **Left** relative to Right;
- zero is a true transparent bypass.

Non-zero alignment adds the same two-frame common interpolation latency to both channels, then adds the requested relative delay to the selected channel. This allows a third-order Thiran all-pass approximation for fractional samples while keeping magnitude unity and greatly improving broadband fractional-delay accuracy over a first-order section. Exact integer delays use direct circular-buffer indexing with no all-pass section.

The two-frame common delay is local to the post-audition speaker-alignment stage. It is not added to the Processed-vs-Reference graph latency because both selected audition outputs receive the alignment stage together. Global Bypass discards the aligned copy and remains raw. Master volume remains downstream.

## Realtime contract

- fixed 8192-frame per-channel history; no callback allocation;
- delay/all-pass coefficients are designed when the immutable graph snapshot is built, not in the render callback;
- current and pending taps crossfade over the graph gain-transition window;
- rapid UI changes queue only the newest target instead of replacing an active crossfade branch;
- histories remain warm during Global Bypass so leaving bypass does not start from an empty delay line;
- no locks, logging, file/device I/O, or coefficient construction in realtime.

## Deferred related capabilities

Excess-phase correction stays with the room-correction suite because it requires phase-resolved measurement. Independent sub-bass phase alignment and multi-driver IR timing remain deferred until their physical output paths exist.
''')

p = Path("docs/PROVENANCE.md")
s = p.read_text()
if "third-order Thiran" not in s:
    s += r'''

### PR30 fractional inter-channel delay

- **Classification:** specification-derived / original commercial implementation.
- **Implementation source:** standard Thiran maximally-flat group-delay all-pass mathematics, independently implemented around the proprietary render snapshot/runtime architecture.
- **Observable legacy contract used:** signed ±20 ms user-facing range and sign convention only (positive delays Right, negative delays Left).
- **Commercial improvements:** higher-order fractional-delay approximation where possible, exact integer-delay bypass, queued click-safe transitions, explicit audition/Global-Bypass semantics, and deterministic 384 kHz-capable fixed storage.
- **Legacy implementation reuse:** none. Historical fractional-delay source/tests were not used as implementation references.
'''
p.write_text(s)

print("PR30 fractional-delay integration applied")
