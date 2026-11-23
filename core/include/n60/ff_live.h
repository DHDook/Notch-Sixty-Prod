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
 * Safety: output ramps in over armRampSeconds (default 3 s) after Arm and out over 10 ms on Disarm or a trip. Trips:
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
    double armRampSeconds;      /* 0 = default 3 s (owner approval, 2 Nov 2026); else 0.01 to 30. Fade-in after Arm. */
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
    N60FeedForwardLiveTripNonFinite = 2,
    /* E4 S22b3 (echo stage): the drive no longer lines up with the reference (a callback was missed,
       cut or longer than the scratch lanes), or the subtraction is adding energy. Both latch. */
    N60FeedForwardLiveTripEchoAlignmentLost = 3,
    N60FeedForwardLiveTripEchoDiverged = 4,

    N60FeedForwardLiveEchoMaxTaps = 512,
    N60FeedForwardLiveEchoMaxBulk = 512,
    N60FeedForwardLiveEchoOff = 0,
    N60FeedForwardLiveEchoSearching = 1,
    N60FeedForwardLiveEchoLocked = 2,
    /* The peak sat at the edge the drive cannot reach yet: the reference delay is too short. */
    N60FeedForwardLiveEchoRefused = 3
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

/* E4 S22b3: the speaker-to-reference leakage model for the echo stage, at the live fd (the Swift
   feed resamples a model from another fd first). Per speaker: a bulk delay and up to 512 taps, both
   at fd. The taps are copied. */
typedef struct {
    uint32_t bulkDelay[2];
    uint32_t tapCount[2];
    const float * N60_FFL_NULLABLE taps[2];
} N60FeedForwardLiveEcho;

typedef struct {
    uint32_t state;              /* Off, Searching, Locked, Refused */
    uint32_t lagFrames;          /* locked lag beyond the model's bulk delay, native frames */
    uint32_t baseLagFrames;      /* the timing the search was centred on */
    uint32_t driveDiscontinuities;
    float peak;                  /* best normalised correlation seen, 0 to 1 */
    float drivePower;            /* mean square of the last drive block, both speakers */
    double programmeSeconds;     /* qualifying programme: searched, or (locked) since the lock */
    double bandBeforePower;      /* 31.5 to 125 Hz power of the raw reference since the lock */
    double bandAfterPower;       /* the same after subtraction */
    uint64_t searchRestarts;
} N60FeedForwardLiveEchoStatus;

/* Feed-forward live status as read from the render path (graph or kernel): filter status plus reference-ring counters. */
typedef struct {
    bool attached;
    N60FeedForwardLiveStatus filter;
    uint64_t outputIndex;           /* output frames passed since attach/reset (the reference ring's read index) */
    uint32_t referenceAheadFrames;  /* how far the pump has written beyond outputIndex */
    uint64_t referenceUnderruns;    /* callbacks whose reference block was not fully supplied */
    N60FeedForwardLiveEchoStatus echo; /* E4 S22b3 */
} N60RenderKernelFeedForwardLiveStatus;

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

/* E4 S22b3, control thread. Publishes the echo model (NULL turns the stage off). Applied by the audio
   thread only while the filter is idle (not armed, gain 0); each restarts the search. False for a
   bad count, a bulk delay or tap count over 512 or a non-finite tap. */
bool N60FeedForwardLiveSetEcho(N60FeedForwardLive * N60_FFL_NONNULL live,
                               const N60FeedForwardLiveEcho * N60_FFL_NULLABLE echo);
/* Control thread. The pump's delay in output frames (the search centre). False when over 100 ms of
   the live rate. */
bool N60FeedForwardLiveSetEchoTiming(N60FeedForwardLive * N60_FFL_NONNULL live, uint32_t baseLagFrames);
/* Audio thread, before Process. The previous callback's final output pair (the speaker drive,
   anti-noise included). A count other than the previous Process call's resets the drive line and
   drops the lock; while armed that trips EchoAlignmentLost. */
void N60FeedForwardLivePushDrive(N60FeedForwardLive * N60_FFL_NONNULL live,
                                 const float * N60_FFL_NONNULL left,
                                 const float * N60_FFL_NONNULL right, uint32_t frames);
/* Audio thread, before Process. zeroFrames > 0: this block's reference is (partly) zero-filled, so it
   is neither subtracted from nor metered. skippedFrames > 0: frames of the callback that Process will
   not see (a callback longer than the scratch lanes), a discontinuity. */
void N60FeedForwardLiveNoteReferenceGaps(N60FeedForwardLive * N60_FFL_NONNULL live, uint32_t zeroFrames,
                                         uint32_t skippedFrames);
N60FeedForwardLiveEchoStatus N60FeedForwardLiveGetEchoStatus(const N60FeedForwardLive * N60_FFL_NONNULL live);

/* Audio thread, or control thread only while Process is not running (it clears audio state). */
void N60FeedForwardLiveReset(N60FeedForwardLive * N60_FFL_NONNULL live);
N60FeedForwardLiveStatus N60FeedForwardLiveGetStatus(const N60FeedForwardLive * N60_FFL_NONNULL live);

#ifdef __cplusplus
}
#endif

#endif
