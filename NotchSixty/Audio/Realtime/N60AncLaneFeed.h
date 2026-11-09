#ifndef N60AncLaneFeed_h
#define N60AncLaneFeed_h

#include <stdbool.h>
#include <stdint.h>

#include "N60ActiveQuietZone.h"
#include "N60FeedForwardLive.h"
// The crossover headers are C first; their zero initialisers are fine in C++ too.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#endif
#include "N60SpeakerBusSplitter.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__clang__)
#define N60_ALF_NONNULL _Nonnull
#define N60_ALF_NULLABLE _Nullable
#else
#define N60_ALF_NONNULL
#define N60_ALF_NULLABLE
#endif

/*
 * E26 S7b (G1): the host feed for the anti-noise lanes. C interface over a C++20 core (n60_anc_lane_feed.cpp),
 * no Apple framework. It is the profile graph's EXTERNAL processor (position 12.5, after the playback DSP and
 * before BASS_MGMT): `N60AncLaneFeedProcess` has the N60AncLaneFeedInnerFn signature. Its channels are the
 * programme left and right (read, passed through untouched) and three actuator source lanes (written): the left
 * main, the right main and the sub. The graph's ANC_GUARD, ANC_INJECT and the output stages take them from there.
 *
 * Per frame, in the stereo kernel's order (docs/epics/E26.md, S7b design b): programme accumulation for the tonal
 * telemetry, tonal synthesis (N60ActiveQuietZone), the live feed-forward sample (N60FeedForwardLive), their sum,
 * the lease/fade gain, then the production speaker bus splitter (N60SpeakerBusSplitter.h, the splitter
 * N60SpeakerBusRenderFeed renders sweeps through). Left lane = LeftLow + LeftMid + LeftHigh, right likewise, sub lane =
 * SubMono: the sums the measured path uses, so the path the sweeps measured is the path the anti-noise plays.
 *
 * Safety (nothing here arms by itself):
 *  - Output is exactly zero until Arm is called, while the lease is absent or expired, and after Disarm.
 *  - Arm fades the output in over fadeInSeconds (default 3 s, arming condition of 2 Nov 2026). Disarm and an
 *    expired lease fade it out over 20 ms without a rebuild. A renewed lease fades back in over the same 3 s.
 *  - Reset (rebuild, rate change, stop) clears the arm, the lease and every history. Nothing re-arms.
 *  - The feed-forward filter's own 3 s arm ramp is replaced by the feed's gain (it is created with the minimum).
 *
 * Realtime contract (AGENTS.md section 4):
 *  - Allocation: everything is allocated in Create (control thread), sized for maxBlockFrames. Process never
 *    allocates, frees, locks or logs.
 *  - Synchronisation: SetTonalSnapshot (triple buffer), the gain mailbox, the telemetry ring, the reference
 *    ring, Arm / Disarm / lease / host time are lock-free single-writer paths; Process is the only reader.
 *  - Latency: 0 frames (the splitter and the tonal runtime add none; the feed-forward filter adds none).
 *  - Sample rates: 8 kHz to 768 kHz, any block size (long blocks are chunked to maxBlockFrames).
 *  - Channels: the callback's channel count must equal the configured count; otherwise Process returns 0
 *    (the graph then outputs silence for the block and counts a fault).
 *  - Reset: IO stopped (or the audio thread), with the lease renewer and the reference pump stopped. Clears audio
 *    state, the arm, the lease and the reference ring; keeps the tonal snapshot, the weights, the echo model and
 *    the splitter configuration. The pump must restart from N60AncLaneFeedReferenceOutputIndex (0 after Reset).
 *  - Lease: checked per frame; the 20 ms fade-out starts at the expiry frame.
 *  - Reference ring: 65536 frames (1.37 s at 48 kHz, 170 ms at 384 kHz); the pump must stay within that lead.
 */

typedef struct N60AncLaneFeed N60AncLaneFeed;

/* The graph's external-processor callback signature (n60/graph.h), repeated so this header stays standalone. */
typedef int (*N60AncLaneFeedInnerFn)(void * N60_ALF_NULLABLE context, const float * N60_ALF_NONNULL const * N60_ALF_NONNULL in,
                                     float * N60_ALF_NONNULL const * N60_ALF_NONNULL out, uint32_t channels, uint32_t frames);

enum {
    N60AncLaneFeedMaxBlockFrames = 8192,
    N60AncLaneFeedMaxChannels = 16,
    /* The reference ring holds the programme the speakers will play ahead of the output index. A pump must keep its
       lead below this: 65536 frames is 0.17 s at 384 kHz and 1.5 s at 44.1 kHz. A push past the ring is trimmed
       (the late frames are dropped, not overwritten), and the filter counts an underrun. */
    N60AncLaneFeedReferenceRingFrames = 65536
};

typedef struct {
    double sampleRate;               /* 8 kHz to 768 kHz */
    uint32_t maxBlockFrames;         /* 16 to N60AncLaneFeedMaxBlockFrames */
    uint32_t channels;               /* the callback's channel count, 5 to N60AncLaneFeedMaxChannels */
    uint32_t programmeLeft;          /* channel indexes in the callback arrays; all five distinct, < channels */
    uint32_t programmeRight;
    uint32_t sourceLeft;
    uint32_t sourceRight;
    uint32_t sourceSub;
    N60SpeakerBusSplitterSnapshot splitter; /* enabled mains + sub (N60SpeakerCrossoverModeMainsSub) */
    float peakLimit;                 /* linear full scale per source lane, (0, 1]; 0 = 1 */
    double fadeInSeconds;            /* 0 = default 3 s; else 0.01 to 30 */
    bool directStereo;               /* E6 S12h part 2b: channels >= 4, no sub lane (sourceSub unused), no splitter; the
                                        anti-noise pair is written to sourceLeft/Right unsplit, as the stereo kernel adds it */
    bool feedForward;                /* create the live feed-forward filter and its reference ring */
} N60AncLaneFeedConfig;

/* E26 S7b2c (G26): reference taps for the tonal controller and the live reference pump, the profile session's
   counterparts of the stereo bridge's rings (same meaning, same frame layout). All three are recorded in Process
   only while the control thread asks for them (SetTapDemand). Single reader: the control thread. */
typedef struct {
    float left;
    float right;
} N60AncLaneFeedFramePair;

typedef struct {
    uint64_t outputHostTime;   /* the output buffer's host time (0 = none) */
    uint64_t firstFrameIndex;  /* index of the first frame this callback wrote to the drive ring */
    uint32_t frames;
    uint32_t reserved;         /* low 32 bits of the reference output index at the start of the chunk */
} N60AncLaneFeedAnchor;

typedef enum {
    N60AncLaneFeedTapAmbient = 0,      /* what the speakers get before the split: programme (at the volume) plus anti-noise */
    N60AncLaneFeedTapQuietZone = 1,    /* the anti-noise pair alone, before the split */
    N60AncLaneFeedTapSpeakerDrive = 2  /* as Ambient, anchored per chunk (the pump's output-clock fit and the echo model) */
} N60AncLaneFeedTap;

enum {
    N60AncLaneFeedTapRingFrames = 131072,
    N60AncLaneFeedDriveRingFrames = 262144,
    N60AncLaneFeedAnchorRingEntries = 4096
};

typedef struct {
    bool enabled;
    uint32_t availableFrames;
    uint32_t availableAnchors;       /* SpeakerDrive only */
    uint64_t capturedFrames;
    uint64_t droppedFrames;          /* frames of chunks not recorded because the ring was full */
    uint64_t droppedAnchors;
} N60AncLaneFeedTapSnapshot;

typedef struct {
    bool armed;
    bool leaseActive;                /* a lease was renewed and has not expired */
    float gain;                      /* the fade/lease gain now, 0 to 1 */
    uint64_t renderedFrames;
    uint64_t leaseExpiries;
    uint64_t referenceUnderruns;
    uint64_t clampedSamples;
    uint64_t faults;                 /* Process calls refused (wrong channel count, null lane) */
    uint64_t nonFiniteSamples;       /* programme or anti-noise samples that were NaN or infinite and were zeroed */
} N60AncLaneFeedStatus;

bool N60AncLaneFeedConfigIsValid(const N60AncLaneFeedConfig * N60_ALF_NULLABLE config);

/* Control thread. NULL for an invalid config or when memory runs out. */
N60AncLaneFeed * N60_ALF_NULLABLE N60AncLaneFeedCreate(const N60AncLaneFeedConfig * N60_ALF_NULLABLE config);
void N60AncLaneFeedDestroy(N60AncLaneFeed * N60_ALF_NULLABLE feed);

/* Audio thread (the graph's EXTERNAL callback). Reads the programme lanes, writes the three source lanes; the
   other channels are left alone. in and out may be the same pointers. Returns non-zero on success. */
int N60AncLaneFeedProcess(void * N60_ALF_NULLABLE context, const float * N60_ALF_NONNULL const * N60_ALF_NONNULL in,
                          float * N60_ALF_NONNULL const * N60_ALF_NONNULL out, uint32_t channels, uint32_t frames);

/* Control thread, IO stopped or the callback not running. Runs `process` in place on lanes 0 and 1 (2 channels, the
   programme pair; programmeLeft/Right must be 0 and 1) at the start of every Process, before the anti-noise is made, so
   the AU rack can share the graph's single EXTERNAL stage. Its failure fails the block. NULL clears. Returns false when
   the lane layout does not allow it. */
/* Control thread, only while the graph that runs this feed is not rendering (a fresh graph before attach): the function and
   context are plain fields read by the callback. */
bool N60AncLaneFeedSetInnerProcessor(N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedInnerFn N60_ALF_NULLABLE process,
                                     void * N60_ALF_NULLABLE context);

/* Control thread, single writer. The tonal canceller's snapshot (enabled, tones, caps, arm generation); the
   audio thread takes the newest at the start of its next block, as the kernel does on a snapshot change. */
bool N60AncLaneFeedSetTonalSnapshot(N60AncLaneFeed * N60_ALF_NONNULL feed,
                                    const N60ActiveQuietZoneSnapshot * N60_ALF_NONNULL snapshot);
/* The adaptive gain mailbox and the phase-anchor telemetry ring the existing worker already uses. Owned by the
   feed; valid until Destroy. */
N60ActiveQuietZoneGainMailbox * N60_ALF_NONNULL N60AncLaneFeedMailbox(N60AncLaneFeed * N60_ALF_NONNULL feed);
N60ActiveQuietZoneTelemetry * N60_ALF_NONNULL N60AncLaneFeedTelemetry(N60AncLaneFeed * N60_ALF_NONNULL feed);
/* Any thread, once per callback before the graph runs: the output buffer's host time (0 = none, no telemetry). */
void N60AncLaneFeedSetHostTime(N60AncLaneFeed * N60_ALF_NONNULL feed, uint64_t hostTime);

/* Control thread. Arm starts the fade-in; it does not create a lease, so the output stays zero until
   RenewLease. Disarm fades out in 20 ms and disarms the feed-forward filter. */
void N60AncLaneFeedArm(N60AncLaneFeed * N60_ALF_NONNULL feed);
void N60AncLaneFeedDisarm(N60AncLaneFeed * N60_ALF_NONNULL feed);
/* Dead-man lease (E4 S14): the anti-noise plays for durationFrames of rendered frames from now. Renew about once
   a second. Release removes the lease, which silences the output (unlike the kernel's, which stops enforcing). */
void N60AncLaneFeedRenewLease(N60AncLaneFeed * N60_ALF_NONNULL feed, uint64_t durationFrames);
void N60AncLaneFeedReleaseLease(N60AncLaneFeed * N60_ALF_NONNULL feed);

/* Feed-forward (feedForward = true; otherwise these refuse). Same contracts as N60FeedForwardLive.h; the ring and
   output index follow N60RenderKernelFeedForwardLive*. */
bool N60AncLaneFeedSetFeedForwardWeights(N60AncLaneFeed * N60_ALF_NONNULL feed, const float * N60_ALF_NONNULL left,
                                         const float * N60_ALF_NONNULL right, uint32_t count);
uint32_t N60AncLaneFeedFeedForwardArm(N60AncLaneFeed * N60_ALF_NONNULL feed, double leadSeconds,
                                      double requiredSeconds);
void N60AncLaneFeedFeedForwardDisarm(N60AncLaneFeed * N60_ALF_NONNULL feed);
bool N60AncLaneFeedSetFeedForwardEcho(N60AncLaneFeed * N60_ALF_NONNULL feed,
                                      const N60FeedForwardLiveEcho * N60_ALF_NULLABLE echo);
bool N60AncLaneFeedSetFeedForwardEchoTiming(N60AncLaneFeed * N60_ALF_NONNULL feed, uint32_t baseLagFrames);
/* Reference pump thread (single producer). Writes `count` samples as the reference for output frames
   startIndex...; late frames drop, a gap zero-fills. Returns the next index it expects. */
uint64_t N60AncLaneFeedPushReference(N60AncLaneFeed * N60_ALF_NONNULL feed, uint64_t startIndex,
                                     const float * N60_ALF_NONNULL samples, uint32_t count);
uint64_t N60AncLaneFeedReferenceOutputIndex(const N60AncLaneFeed * N60_ALF_NONNULL feed);
/* The zero-filled reference span the echo stage skips over, [from, to) in reference frames. Control thread
   (diagnostics and tests). Returns false when there is no pending span (none pushed, or already consumed). */
bool N60AncLaneFeedReferenceZeroSpan(const N60AncLaneFeed * N60_ALF_NONNULL feed, uint64_t * N60_ALF_NONNULL from,
                                     uint64_t * N60_ALF_NONNULL to);
N60FeedForwardLiveStatus N60AncLaneFeedFeedForwardStatus(const N60AncLaneFeed * N60_ALF_NONNULL feed);

/* Control thread. Turns a tap on or off (off keeps what was recorded until Discard). */
void N60AncLaneFeedSetTapDemand(N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedTap tap, bool enabled);
N60AncLaneFeedTapSnapshot N60AncLaneFeedTapGetSnapshot(const N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedTap tap);
/* Reads up to `maximum` frames, oldest first. Returns the count. */
uint32_t N60AncLaneFeedTapRead(N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedTap tap,
                               N60AncLaneFeedFramePair * N60_ALF_NONNULL destination, uint32_t maximum);
void N60AncLaneFeedTapDiscard(N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedTap tap);
uint32_t N60AncLaneFeedAnchorsRead(N60AncLaneFeed * N60_ALF_NONNULL feed, N60AncLaneFeedAnchor * N60_ALF_NONNULL destination,
                                   uint32_t maximum);
/* Control thread. The software volume the graph applies to the programme lanes after this stage (OUTPUT_GAIN), so
   the taps and the echo drive see what the speakers get. A block-constant approximation of the graph's own ramp;
   1 by default. */
void N60AncLaneFeedSetProgrammeScale(N60AncLaneFeed * N60_ALF_NONNULL feed, float scale);
/* Matches the bridge's host-time sink signature: context is the feed. Audio thread. */
void N60AncLaneFeedHostTimeSink(void * N60_ALF_NULLABLE context, uint64_t hostTime);

/* Audio thread, or control thread only while Process is not running. The tap rings are also cleared, so the control
   thread must not be inside TapRead/TapDiscard (the host stops the reference readers first). Readers should drain
   at 10 Hz or faster: the tap rings hold 0.34 s and the drive ring 0.68 s at 384 kHz. */
void N60AncLaneFeedReset(N60AncLaneFeed * N60_ALF_NONNULL feed);
N60AncLaneFeedStatus N60AncLaneFeedGetStatus(const N60AncLaneFeed * N60_ALF_NONNULL feed);

#ifdef __cplusplus
}
#endif

#endif
