#ifndef N60FeedForwardLive_h
#define N60FeedForwardLive_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__clang__)
#define N60_FFL_NONNULL _Nonnull
#define N60_FFL_NULLABLE _Nullable
#else
#define N60_FFL_NONNULL
#define N60_FFL_NULLABLE
#endif

/*
 * E4 S25a: live broadband feed-forward filter. C interface over a C++20 core (n60_ff_live.cpp).
 * Not wired into the render kernel yet; S25b wires it (reference crossing, mailbox feed, arm gate
 * from the S24 lead, flag e4.feedforward-live).
 *
 * Design (docs/epics/E4.md, "S25r design note", owner decision 31 Oct 2026, option 2): the
 * shadow adapts W at fd = fs / D, D = floor(fs / 4000), up to 512 taps. This filter applies W at
 * the native rate with no added delay, by splitting it into non-uniform partitions:
 *  - Head: weights 0..T0-1 (T0 = 2 * kernelHalf fd samples, 2 ms) as a native-rate FIR of
 *    (2 T0 - 1) D + 1 taps, each fd weight spread by the chain kernel c = decimator * interpolator
 *    (Blackman-windowed sinc, cutoff 0.5 fd, 2 kernelHalf D + 1 taps each).
 *  - Tail: weights T0..K-1 at fd on the decimated reference, interpolated back. The chain delay
 *    2 kernelHalf D native frames equals the T0 fd samples the head replaced, so the sum has the
 *    ideal response sum_i w[i] c(n - i D) for n >= 0: the seam is exact up to the time-variance of
 *    decimation, which is below -70 dB for content under 0.15 fd (600 Hz) given the stopband of c.
 *  - Added delay: 0 frames. The first tap acts on the current input sample.
 * Valid for weights that carry content below about 0.15 fd (the ANC band, 20-500 Hz).
 *
 * Realtime contract:
 *  - Allocation: all storage is allocated in Create and the control-plane call SetWeights; Process
 *    never allocates, locks or logs. Process copies at most two weight sets (about 14 KB) when a
 *    new set arrives.
 *  - Synchronisation: SetWeights (control thread, single writer) publishes through a lock-free
 *    triple buffer; Process (audio thread, single reader) takes the newest set and crossfades to
 *    it over swapFadeSeconds. Arm, Disarm, MarkReferenceLost are atomic flags.
 *  - Cost: (2 T0 - 1) D + 1 multiply-adds per native frame and output channel for the head
 *    (1,441 at 384 kHz, 169 at 44.1 kHz), about 9 + 9 per frame for the decimator and
 *    interpolator, and 512 per fd sample for the tail. Head cost grows with the rate.
 *  - Sample rates 8 kHz to 768 kHz, any block size (long blocks are chunked internally to
 *    maxBlockFrames). One reference channel in, two anti-noise channels out.
 *  - Reset: Reset clears all histories and the output ramp, keeps weights and the arm request.
 *
 * Safety: output ramps in over 50 ms after Arm and out over 10 ms on Disarm or a trip. Trips:
 * reference lost (MarkReferenceLost), non-finite input or output. A trip stays until Reset and
 * Arm. Output is clamped to +-peakLimit (linear full scale); clamped samples are counted.
 */

typedef struct N60FeedForwardLive N60FeedForwardLive;

typedef struct {
    double sampleRate;          /* 8 kHz to 768 kHz */
    uint32_t maxBlockFrames;    /* 16 to 16384; Process chunks longer calls */
    uint32_t kernelHalf;        /* 0 = default 4; 3 to 4, fd samples (the interpolator keeps 9 phases) of one chain half-kernel */
    double swapFadeSeconds;     /* 0 = default 0.01 */
    double peakLimit;           /* linear full scale, (0, 1] */
} N60FeedForwardLiveConfig;

enum {
    N60FeedForwardLiveMaxTaps = 512,
    N60FeedForwardLiveIdle = 0,
    N60FeedForwardLiveArmed = 1,
    N60FeedForwardLiveTripped = 2,

    N60FeedForwardLiveArmOK = 0,
    N60FeedForwardLiveArmShortLead = 1,
    N60FeedForwardLiveArmNoWeights = 2,
    N60FeedForwardLiveArmTripped = 3,

    N60FeedForwardLiveTripNone = 0,
    N60FeedForwardLiveTripReferenceLost = 1,
    N60FeedForwardLiveTripNonFinite = 2
};

typedef struct {
    uint32_t state;             /* Idle, Armed, Tripped */
    uint32_t tripReason;
    uint32_t decimation;        /* D */
    uint32_t headTaps;
    uint32_t tailTaps;          /* of the newest set */
    uint32_t chainDelayFrames;  /* native frames of decimator + interpolator (tail offset) */
    uint32_t addedDelayFrames;  /* always 0 */
    uint64_t setsApplied;
    uint64_t clampedSamples;
    float outputPeak;           /* largest absolute output since Reset */
    float gain;                 /* current ramp, 0 to 1 */
} N60FeedForwardLiveStatus;

bool N60FeedForwardLiveConfigIsValid(const N60FeedForwardLiveConfig * N60_FFL_NULLABLE config);

N60FeedForwardLive * N60_FFL_NULLABLE N60FeedForwardLiveCreate(
    const N60FeedForwardLiveConfig * N60_FFL_NULLABLE config);
void N60FeedForwardLiveDestroy(N60FeedForwardLive * N60_FFL_NULLABLE live);

/* Control thread. Weights are fd-rate taps (1 to 512) per speaker. Returns false for a bad count
   or non-finite value. */
bool N60FeedForwardLiveSetWeights(N60FeedForwardLive * N60_FFL_NONNULL live,
                                  const float * N60_FFL_NONNULL left,
                                  const float * N60_FFL_NONNULL right, uint32_t count);

/* Control thread. The gate: refused (not armed) while leadSeconds < requiredSeconds, which is the
   S24 lead budget; also refused with no weights, or while tripped. */
uint32_t N60FeedForwardLiveArm(N60FeedForwardLive * N60_FFL_NONNULL live, double leadSeconds,
                               double requiredSeconds);
void N60FeedForwardLiveDisarm(N60FeedForwardLive * N60_FFL_NONNULL live);

/* Any thread. The reference stream dropped or restarted: fade to silence and trip. */
void N60FeedForwardLiveMarkReferenceLost(N60FeedForwardLive * N60_FFL_NONNULL live);

/* Audio thread. Writes the anti-noise for `frames` reference samples into left and right
   (overwrites). Silence while idle or tripped (after the ramp). */
void N60FeedForwardLiveProcess(N60FeedForwardLive * N60_FFL_NONNULL live,
                               const float * N60_FFL_NONNULL reference,
                               float * N60_FFL_NONNULL left, float * N60_FFL_NONNULL right,
                               uint32_t frames);

/* Audio thread, or control thread only while Process is not running (it clears audio state). */
void N60FeedForwardLiveReset(N60FeedForwardLive * N60_FFL_NONNULL live);
N60FeedForwardLiveStatus N60FeedForwardLiveGetStatus(const N60FeedForwardLive * N60_FFL_NONNULL live);

#ifdef __cplusplus
}
#endif

#endif
