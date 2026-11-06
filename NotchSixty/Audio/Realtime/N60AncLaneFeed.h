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
 * before BASS_MGMT): `N60AncLaneFeedProcess` has the n60_external_process_fn signature. Its channels are the
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

enum {
    N60AncLaneFeedMaxBlockFrames = 8192,
    N60AncLaneFeedMaxChannels = 16,
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
    bool feedForward;                /* create the live feed-forward filter and its reference ring */
} N60AncLaneFeedConfig;

typedef struct {
    bool armed;
    bool leaseActive;                /* a lease was renewed and has not expired */
    float gain;                      /* the fade/lease gain now, 0 to 1 */
    uint64_t renderedFrames;
    uint64_t leaseExpiries;
    uint64_t referenceUnderruns;
    uint64_t clampedSamples;
    uint64_t faults;                 /* Process calls refused (wrong channel count, null lane); non-finite samples are zeroed silently */
} N60AncLaneFeedStatus;

bool N60AncLaneFeedConfigIsValid(const N60AncLaneFeedConfig * N60_ALF_NULLABLE config);

/* Control thread. NULL for an invalid config or when memory runs out. */
N60AncLaneFeed * N60_ALF_NULLABLE N60AncLaneFeedCreate(const N60AncLaneFeedConfig * N60_ALF_NULLABLE config);
void N60AncLaneFeedDestroy(N60AncLaneFeed * N60_ALF_NULLABLE feed);

/* Audio thread (the graph's EXTERNAL callback). Reads the programme lanes, writes the three source lanes; the
   other channels are left alone. in and out may be the same pointers. Returns non-zero on success. */
int N60AncLaneFeedProcess(void * N60_ALF_NULLABLE context, const float * N60_ALF_NONNULL const * N60_ALF_NONNULL in,
                          float * N60_ALF_NONNULL const * N60_ALF_NONNULL out, uint32_t channels, uint32_t frames);

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
N60FeedForwardLiveStatus N60AncLaneFeedFeedForwardStatus(const N60AncLaneFeed * N60_ALF_NONNULL feed);

/* Audio thread, or control thread only while Process is not running. */
void N60AncLaneFeedReset(N60AncLaneFeed * N60_ALF_NONNULL feed);
N60AncLaneFeedStatus N60AncLaneFeedGetStatus(const N60AncLaneFeed * N60_ALF_NONNULL feed);

#ifdef __cplusplus
}
#endif

#endif
