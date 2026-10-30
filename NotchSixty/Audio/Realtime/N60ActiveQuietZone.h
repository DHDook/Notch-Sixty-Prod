#ifndef N60ActiveQuietZone_h
#define N60ActiveQuietZone_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ACTIVE_QUIET_ZONE_MAX_TONES 4u
#define N60_ACTIVE_QUIET_ZONE_MIN_HZ 20.0
#define N60_ACTIVE_QUIET_ZONE_MAX_HZ 150.0
#define N60_ACTIVE_QUIET_ZONE_MAX_TONE_PEAK_DBFS (-24.0)
#define N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS (-18.0)
/// E4 S19: one retarget may move an active tone by at most this fraction of its current
/// frequency; the oscillator glides there phase-continuously over the mailbox crossfade.
#define N60_ACTIVE_QUIET_ZONE_GLIDE_MAX_FRACTION 0.02
/// E4 S19: the tracking range around the armed (snapshot) frequency. A mailbox record may
/// follow a drifting tone this far; a larger move needs a disarm.
#define N60_ACTIVE_QUIET_ZONE_TRACK_RANGE_FRACTION 0.10

typedef struct {
    double frequencyHz;
    float leftReal;
    float leftImaginary;
    float rightReal;
    float rightImaginary;
    // Prepared by SnapshotSet; callers may leave these zero in input values.
    double incrementCosine;
    double incrementSine;
} N60ActiveQuietZoneToneSnapshot;

typedef struct {
    bool enabled;
    uint32_t toneCount;
    uint32_t transitionFrames;
    // Output clamp (linear). 0 means the compile-time aggregate limit. Set with
    // N60ActiveQuietZoneSnapshotSetPeakCap; defence in depth behind the Swift cap.
    float peakCapLinear;
    // E4 S18a: the control plane's arm generation (0 = none). A gain-mailbox record is played
    // only while its generation equals this one; a disarm bumps it, so a late write cannot play.
    uint64_t armGeneration;
    // E4 S20: the earned cap at arm (linear). 0 = no ceiling (the clamp follows the snapshot cap
    // and the record cap directly). Above 0, the clamp is also held to a ceiling that starts here
    // for the arm generation and rises by at most 3 dB per 5 s of rendered frames toward the
    // requested cap; lower requests apply at once and never lower the ceiling.
    float initialCapLinear;
    N60ActiveQuietZoneToneSnapshot
        tones[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
} N60ActiveQuietZoneSnapshot;

typedef struct {
    double frequencyHz;
    double phaseRadians;
    double oscillatorCosine;
    double oscillatorSine;
    double incrementCosine;
    double incrementSine;
    float currentLeftReal;
    float currentLeftImaginary;
    float currentRightReal;
    float currentRightImaginary;
    float startLeftReal;
    float startLeftImaginary;
    float startRightReal;
    float startRightImaginary;
    float targetLeftReal;
    float targetLeftImaginary;
    float targetRightReal;
    float targetRightImaginary;
    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
    bool active;
    // E4 S19 glide: per frame the increment phasor is rotated by (glideRotationCosine,
    // glideRotationSine) and frequencyHz moves by glideFrequencyStep, for glideFramesRemaining
    // frames; the last frame lands on glideTargetHz and the exact target increment.
    uint32_t glideFramesRemaining;
    double glideRotationCosine;
    double glideRotationSine;
    double glideFrequencyStep;
    double glideTargetHz;
    double glideTargetIncrementCosine;
    double glideTargetIncrementSine;
} N60ActiveQuietZoneToneRuntime;

typedef struct {
    uint64_t armGeneration;
    // Assigned by Publish; ignored on input.
    uint64_t sequence;
    uint32_t toneCount;
    // Attempt cap (linear peak per channel); 0 = no extra cap beyond the snapshot's.
    float attemptCapLinear;
    double frequencyHz[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    // Per tone: left real, left imaginary, right real, right imaginary.
    float gain[N60_ACTIVE_QUIET_ZONE_MAX_TONES][4];
} N60ActiveQuietZoneGainRecord;

typedef struct {
    double sampleRate;
    N60ActiveQuietZoneToneRuntime
        tones[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    float lastLeft;
    float lastRight;
    uint64_t processedFrames;
    uint64_t sanitizedSamples;
    // Linear clamp applied to every output sample; set by Schedule from the snapshot.
    float peakCapLinear;
    // E4 S20: the clamp is min(snapshotCap, recordCap if any, ceiling if active); see Schedule.
    float snapshotCapLinear;
    float recordCapLinear;
    float ceilingLinear;
    bool ceilingActive;
    uint64_t ceilingGeneration;
    uint64_t ceilingStepFrames;
    uint64_t ceilingFramesLeft;
    // Samples that reached the clamp (diagnostic; never reset by Schedule).
    uint64_t clampedSamples;
    // E4 S18a mailbox state (render thread only). The last valid record is kept so a graph
    // re-publish within the same arm, which retargets to the offline gains, is followed by the
    // adaptive gains again in the same callback (before any frame is rendered).
    uint64_t mailboxSequence;
    bool mailboxRecordValid;
    bool mailboxReapply;
    N60ActiveQuietZoneGainRecord mailboxRecord;
} N60ActiveQuietZoneRuntime;

N60ActiveQuietZoneSnapshot
N60ActiveQuietZoneSnapshotMakeBypassed(void);

/// Sets the snapshot's output clamp. Rejects non-finite or non-positive values; values above the
/// aggregate limit are lowered to it.
bool N60ActiveQuietZoneSnapshotSetPeakCap(
    N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    float peakCapLinear
);

bool N60ActiveQuietZoneSnapshotSet(
    N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    const N60ActiveQuietZoneToneSnapshot * _Nullable tones,
    uint32_t toneCount,
    uint32_t transitionFrames,
    double sampleRate,
    bool enabled
);

void N60ActiveQuietZoneRuntimeReset(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    double sampleRate
);

/// Control-plane preparation invoked when an immutable graph snapshot changes.
/// Active frequency changes up to N60_ACTIVE_QUIET_ZONE_GLIDE_MAX_FRACTION of the tone's current
/// frequency glide there phase-continuously (E4 S19). Larger changes are fail-closed: callers must
/// first publish a zero/bypassed snapshot, allowing the current tone to fade out, before
/// introducing a different frequency in the same slot. While a valid mailbox record of the same
/// arm is held, the tone may sit anywhere within N60_ACTIVE_QUIET_ZONE_TRACK_RANGE_FRACTION of the
/// snapshot's frequency: the record, not the snapshot, then sets the frequency.
bool N60ActiveQuietZoneRuntimeSchedule(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    const N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    double sampleRate
);

/// Realtime-safe synthesis. No allocation, locks, logging, or transcendental
/// calls occur here; phase increments are prepared during Schedule().
void N60ActiveQuietZoneRuntimeProcessFrame(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    float * _Nonnull left,
    float * _Nonnull right
);

/* ---- E4 S18a: adaptive gain mailbox and phase-anchor telemetry --------------------------------
 *
 * The adaptive tonal canceller refines the gains of the tones the offline target already plays,
 * without rebuilding the graph. One writer thread (control plane or worker) publishes whole
 * records into a lock-free triple buffer; the render thread reads the newest once per callback
 * (N60ActiveQuietZoneRuntimeApplyMailbox) and retargets the tone gains through the existing
 * linear crossfade over N60_ACTIVE_QUIET_ZONE_MAILBOX_CROSSFADE_SECONDS.
 *
 * A record is ignored (counted, nothing changes) when the snapshot is not enabled, its
 * generation is 0 or differs from the snapshot's armGeneration, its tone count or any tone
 * frequency lies outside the tracking range of the snapshot's (E4 S19: +-10 %, 20 to 150 Hz, below
 * Nyquist) or more than the glide limit (2 %) from the tone now playing, or any value is non-finite. Otherwise each
 * tone's gains are limited to min(per-tone peak limit, snapshot cap, record attempt cap) and the
 * sum over tones per channel to min(aggregate limit, snapshot cap, attempt cap) by scaling; any
 * scaling counts as "clamped". The runtime's output clamp becomes the lower of the snapshot cap and
 * the attempt cap while a record is in force, and returns to the snapshot cap on Schedule (it is only ever lowered between Schedules). A sample
 * rate change clears the kept record until the worker republishes.
 *
 * Allocation: Create allocates once (control plane). Publish and Apply never allocate.
 * Synchronisation: lock-free, one writer (Publish), one reader (render thread). Stats are
 * relaxed atomics. Latency: at most one callback plus the crossfade. Rates: any, the crossfade is
 * in frames. Channels: stereo, one complex gain per tone and channel. Reset: Schedule keeps the
 * last valid record and re-applies it after a graph re-publish of the same arm; a different
 * generation, tone set, or a disabled snapshot discards it.
 */
#define N60_ACTIVE_QUIET_ZONE_MAILBOX_CROSSFADE_SECONDS 0.1


typedef struct {
    uint64_t published;
    uint64_t applied;
    uint64_t clamped;
    uint64_t ignoredStaleGeneration;
    uint64_t ignoredToneMismatch;
    uint64_t ignoredNonFinite;
    uint64_t ignoredNotEnabled;
} N60ActiveQuietZoneMailboxStats;

typedef struct N60ActiveQuietZoneGainMailbox N60ActiveQuietZoneGainMailbox;

N60ActiveQuietZoneGainMailbox * _Nullable N60ActiveQuietZoneGainMailboxCreate(void);
void N60ActiveQuietZoneGainMailboxDestroy(N60ActiveQuietZoneGainMailbox * _Nullable mailbox);
/// Single writer. Returns the assigned sequence (>= 1), or 0 for a NULL argument or tone count
/// above the maximum.
uint64_t N60ActiveQuietZoneGainMailboxPublish(
    N60ActiveQuietZoneGainMailbox * _Nonnull mailbox,
    const N60ActiveQuietZoneGainRecord * _Nonnull record
);
N60ActiveQuietZoneMailboxStats N60ActiveQuietZoneGainMailboxStats(
    const N60ActiveQuietZoneGainMailbox * _Nonnull mailbox
);

/// Render thread, once per callback after Schedule. No-op when the mailbox was never written.
void N60ActiveQuietZoneRuntimeApplyMailbox(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    N60ActiveQuietZoneGainMailbox * _Nonnull mailbox,
    const N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    double sampleRate
);

/// What the render thread was playing at the start of a callback, anchored to host time. The
/// phasor is the tone oscillator's value at the first frame; gain is the complex L/R gain playing
/// (after the kernel's crossfade, before the lease and howl-guard gains).
#define N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY 1024u
#define N60_ACTIVE_QUIET_ZONE_TELEMETRY_MIN_SPACING_SECONDS 0.005

typedef struct {
    // mHostTime of the output buffer's first frame (host ticks); 0 is never written.
    uint64_t hostTime;
    // Frames the kernel had rendered before this callback.
    uint64_t renderedFrame;
    uint32_t toneCount;
    uint32_t reserved;
    double frequencyHz[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    double phasorCosine[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    double phasorSine[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    float gain[N60_ACTIVE_QUIET_ZONE_MAX_TONES][4];
} N60ActiveQuietZoneTelemetryRecord;

typedef struct N60ActiveQuietZoneTelemetry N60ActiveQuietZoneTelemetry;

N60ActiveQuietZoneTelemetry * _Nullable N60ActiveQuietZoneTelemetryCreate(void);
void N60ActiveQuietZoneTelemetryDestroy(N60ActiveQuietZoneTelemetry * _Nullable ring);
/// Render thread (single producer). Drops the record when the ring is full (counted).
bool N60ActiveQuietZoneTelemetryPush(
    N60ActiveQuietZoneTelemetry * _Nonnull ring,
    const N60ActiveQuietZoneTelemetryRecord * _Nonnull record
);
/// Worker (single consumer). Pops the oldest record.
bool N60ActiveQuietZoneTelemetryPop(
    N60ActiveQuietZoneTelemetry * _Nonnull ring,
    N60ActiveQuietZoneTelemetryRecord * _Nonnull record
);
uint64_t N60ActiveQuietZoneTelemetryDropped(const N60ActiveQuietZoneTelemetry * _Nonnull ring);
/// Snapshot of the runtime for the telemetry record. False when no tone is active.
bool N60ActiveQuietZoneRuntimeCaptureTelemetry(
    const N60ActiveQuietZoneRuntime * _Nonnull runtime,
    uint64_t hostTime,
    uint64_t renderedFrame,
    N60ActiveQuietZoneTelemetryRecord * _Nonnull record
);

void N60ActiveQuietZoneRuntimeLastFrame(
    const N60ActiveQuietZoneRuntime * _Nonnull runtime,
    float * _Nonnull left,
    float * _Nonnull right
);

#ifdef __cplusplus
}
#endif

#endif
