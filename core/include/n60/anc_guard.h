#ifndef N60AncGuard_h
#define N60AncGuard_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Nullability qualifiers are a Clang extension; other compilers drop them. */
#if defined(__clang__)
#define N60_GUARD_NONNULL _Nonnull
#define N60_GUARD_NULLABLE _Nullable
#else
#define N60_GUARD_NONNULL
#define N60_GUARD_NULLABLE
#endif

/*
 * E4 S4: speaker-ANC instability (howl) guard with latched fail-to-mute.
 *
 * Whole-buffer, portable C interface over a C++20 core (n60_anc_guard.cpp).
 * It sits on any anti-noise path that is fed by microphones (feed-forward and
 * adaptive output) and mutes that path when it becomes unstable. Criteria and
 * timing targets: docs/ANC_QUALIFICATION.md section 3.
 *
 * Checks, evaluated every 10 ms block:
 *  - Growth: anti-noise mean square rises by more than growthDBPer20ms
 *    against the block two earlier, for growthBlocks consecutive blocks, while
 *    above the activity floor. A rise in the reference excuses at most
 *    referenceAllowanceDB of it, so a howl that loops through the reference
 *    microphone still trips.
 *  - Error rise: any of 16 bands (20-500 Hz) of the error-microphone residual
 *    exceeds its ANC-off baseline by errorRiseDB for errorRiseBlocks
 *    consecutive blocks, while the anti-noise is above the activity floor.
 *  - Per sample: a non-finite anti-noise sample (zeroed) or one above
 *    outputCeiling (clamped) trips at once, as does a non-finite reference or
 *    error sample (a failed microphone must not read as a quiet one).
 * Growth detection latency (10 ms blocks): within 50 ms for a howl at 30 Hz or
 * above growing at least 10 dB per 20 ms, or at least 20 dB per 20 ms when it
 * also loops through the reference. Slower howls, and howls near 20 Hz where
 * one cycle spans five blocks, rely on the error-rise check and the ceiling.
 * A trip ramps the anti-noise linearly to zero over muteRampSeconds and stays
 * muted until N60AncGuardRequestRearm; re-arm ramps back up over the same time.
 *
 * Contract for callers:
 *  - Anti-noise must fade in no faster than half of growthDBPer20ms, or the
 *    growth check will treat the fade-in as instability.
 *  - The error input is the residual with programme removed (echo-suppressed),
 *    not the raw microphone, so that music does not read as an error rise.
 *  - Re-arm clears the detector history, so a howl that persists through a
 *    re-arm plays for up to about 50 ms (two history blocks, three growth
 *    blocks, the ramp) unless it exceeds outputCeiling. Re-arm only after the
 *    cause has been removed.
 *
 * Realtime behaviour:
 *  - Allocation: Create allocates once on the control plane; Process,
 *    RequestRearm and ReadStatus never allocate.
 *  - Synchronisation: lock-free. Exactly one thread calls Process. Any thread
 *    may call RequestRearm and ReadStatus (atomics only).
 *  - Latency: none added; the anti-noise is modified in place.
 *  - Sample rate: fixed per guard, 8 kHz to 768 kHz. The error bands run on a
 *    boxcar-decimated copy at fs / floor(fs / 4000), so cost per second of the
 *    band analysis is the same at every rate.
 *  - Channels: one anti-noise channel per guard; use one guard per channel.
 *  - Reset: a rate change needs a new guard. Re-arm clears all detector state.
 */

#define N60_ANC_GUARD_BAND_COUNT 16u
#define N60_ANC_GUARD_BLOCK_SECONDS 0.010

typedef enum {
    N60AncGuardTripNone = 0,
    N60AncGuardTripGrowth = 1,
    N60AncGuardTripErrorRise = 2,
    N60AncGuardTripNonFinite = 3,
    N60AncGuardTripOverCeiling = 4,
} N60AncGuardTrip;

typedef struct {
    double sampleRate;
    /// Growth threshold, dB of mean square per 20 ms (default 6).
    float growthDBPer20ms;
    uint32_t growthBlocks;
    /// Largest share of anti-noise growth a reference rise can excuse, dB
    /// (default 3).
    float referenceAllowanceDB;
    /// Error-band rise over the ANC-off baseline, dB (default 6).
    float errorRiseDB;
    uint32_t errorRiseBlocks;
    /// Largest permitted anti-noise sample magnitude (default 0.5, -6 dBFS).
    float outputCeiling;
    /// Mean-square level, dB re full scale, below which the anti-noise
    /// counts as silent and the growth and error checks hold (default -60).
    float activityFloorDB;
    /// Fail-to-mute and re-arm ramp length (default 0.010 s).
    double muteRampSeconds;
    /// Per-band mean square of the error residual with ANC off, dB re full
    /// scale. The error check runs only when hasErrorBaseline is true.
    bool hasErrorBaseline;
    float errorBaselineDB[N60_ANC_GUARD_BAND_COUNT];
} N60AncGuardConfig;

typedef struct {
    N60AncGuardTrip trip;
    /// True from the trip until re-arm.
    bool tripped;
    /// True once the mute ramp has reached zero.
    bool muted;
    /// Frame (since creation or the last re-arm) at which the trip was found.
    uint64_t tripFrame;
    uint64_t processedFrames;
    uint64_t tripCount;
} N60AncGuardStatus;

typedef struct N60AncGuard N60AncGuard;

N60AncGuardConfig N60AncGuardConfigDefault(double sampleRate);
bool N60AncGuardConfigIsValid(const N60AncGuardConfig * N60_GUARD_NONNULL config);

/// Centre frequency of an error band, Hz (log-spaced 20-500 Hz).
double N60AncGuardBandCentreHz(uint32_t band);

/// Control plane. Returns NULL for an invalid configuration or no memory.
N60AncGuard * N60_GUARD_NULLABLE N60AncGuardCreate(
    const N60AncGuardConfig * N60_GUARD_NONNULL config
);
/// Control plane, after the processing thread has stopped calling Process.
void N60AncGuardDestroy(N60AncGuard * N60_GUARD_NULLABLE guard);

/// Realtime. Applies the guard to antiNoise in place. reference and error may
/// be NULL; the checks that need them are then skipped. Returns the current
/// trip state (None while healthy).
N60AncGuardTrip N60AncGuardProcess(
    N60AncGuard * N60_GUARD_NONNULL guard,
    float * N60_GUARD_NONNULL antiNoise,
    const float * N60_GUARD_NULLABLE reference,
    const float * N60_GUARD_NULLABLE error,
    uint32_t frames
);

/// Any thread. Takes effect at the start of the next Process call.
void N60AncGuardRequestRearm(N60AncGuard * N60_GUARD_NONNULL guard);

/// Any thread.
N60AncGuardStatus N60AncGuardReadStatus(const N60AncGuard * N60_GUARD_NONNULL guard);

#ifdef __cplusplus
}
#endif

#endif
