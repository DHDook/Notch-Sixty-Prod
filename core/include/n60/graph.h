/*
 * libn60core: versioned C interface to the unified N-channel graph (E6 S2, E21).
 *
 * Plain C types only, opaque handles, explicit struct sizes and an ABI version,
 * so the macOS Swift shell, a Linux test host and any future shell call the same
 * entry points. No Apple type appears here or anywhere in the core.
 *
 * Threading: every call except n60_graph_process belongs to the control thread
 * (one control thread at a time). n60_graph_process is the only call made from
 * the realtime thread. It never allocates, locks, throws or logs. Buffers are
 * planar (non-interleaved) 32-bit float, one pointer per channel, processed a
 * whole block at a time.
 *
 * E6 S3 model. The graph handle is a host that owns immutable topology
 * snapshots (one arena allocation each, built off the realtime thread). A new
 * topology is published with n60_graph_publish and adopted by the next process
 * call with a single atomic pointer exchange; the superseded snapshot comes back
 * through a retire queue and is freed by n60_graph_collect on the control thread.
 * Parameters travel through a lock-free mailbox (n60_graph_post_params) and are
 * coalesced, latest wins, at the start of a block. A graph with no stages passes
 * audio through unchanged.
 *
 * Lane stages work in place on the output lanes: lane c carries input channel c
 * (output lanes with no input carry silence), so stage lane indexes are output
 * channel indexes.
 */
#ifndef N60_GRAPH_H
#define N60_GRAPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any incompatible change to a struct or function below. */
#define N60_GRAPH_ABI_VERSION 5u

typedef struct n60_graph n60_graph; /* opaque */

typedef enum n60_status {
    N60_STATUS_OK = 0,
    N60_STATUS_ABI_MISMATCH = 1, /* desc.abiVersion or desc.structSize is not what this library supports */
    N60_STATUS_BAD_ARGUMENT = 2, /* null pointer, zero or out-of-range size, frames > maxBlockFrames */
    N60_STATUS_OUT_OF_MEMORY = 3,
    N60_STATUS_UNSUPPORTED = 4,  /* valid request this build cannot honour (for example a parameter that needs a topology change) */
    N60_STATUS_QUEUE_FULL = 5    /* mailbox or retire queue full; nothing was applied, retry after the realtime thread ran or after collect */
} n60_status;

/* Limits accepted by n60_graph_build. */
#define N60_GRAPH_MAX_CHANNELS 64u
#define N60_GRAPH_MAX_BLOCK_FRAMES (1u << 20)
#define N60_GRAPH_MIN_SAMPLE_RATE 8000.0
#define N60_GRAPH_MAX_SAMPLE_RATE 768000.0

/* Stage kinds. A graph accepts stages only in non-decreasing order of the position listed
 * here (the kernel's lane order); several stages of one kind may follow each other. The
 * numeric values are identifiers, not the order: the ABI v3 kinds 9..13 slot in between. */
typedef enum n60_stage_kind {
    N60_STAGE_SANITISE = 1,   /* position 1. NaN and Inf become 0; counted. No params. */
    N60_STAGE_METER_IN = 2,   /* position 2. Peak and RMS per lane, audio untouched. No params. */
    N60_STAGE_GAIN = 3,       /* position 3. Input gain x headroom. params[0] = linear gain, ramped over 5 ms. */
    N60_STAGE_DENOISER = 11,  /* position 4. Spectral denoiser, linked across its lanes. See "Denoiser" below. */
    N60_STAGE_MS_ENCODE = 4,  /* position 5. Group stage on lanes (laneA, laneB): M = (A+B)/2, S = (A-B)/2. No params. */
    N60_STAGE_PEQ = 5,        /* position 6. Up to 16 sections, double precision. params = 4 per section: type, Hz, dB, Q. */
    N60_STAGE_DYN_EQ = 10,    /* position 7. Dynamic EQ bands. See "Dynamic EQ" below. */
    N60_STAGE_MS_DECODE = 6,  /* position 8. Inverse of the matching encode on the same lanes: A = M+S, B = M-S. */
    N60_STAGE_FIR = 9,        /* position 9. Program FIR. params = taps. See "Program FIR" below. */
    N60_STAGE_COMPRESSOR = 12,/* position 10. See "Compressor" below. */
    N60_STAGE_EXPANDER = 13,  /* position 11. See "Expander" below. */
    N60_STAGE_METER_OUT = 7,  /* position 12. Post-EQ meter, like METER_IN. */
    /* ABI v4 system stages (E6 S5), in processing order. See "System stages" below. */
    N60_STAGE_BASS_MGMT = 17,     /* position 13. Multichannel bass management and crossover. */
    N60_STAGE_ROOM_FIR = 14,      /* position 14. Room-correction convolver (Program FIR rules). */
    N60_STAGE_SPEAKER_IR = 15,    /* position 15. Speaker IR convolver (Program FIR rules). */
    N60_STAGE_AMBIENT = 18,       /* position 16. Ambient compensation: ramped level plus three peaking bands. */
    N60_STAGE_CORE_DYNAMICS = 16, /* position 17. Post-EQ core dynamics (Compressor rules). */
    N60_STAGE_SYMMETRY = 20,      /* position 18. Pair stage: symmetry position gains. */
    N60_STAGE_CROSSFEED = 21,     /* position 19. Pair stage: speaker crossfeed. */
    N60_STAGE_CROSSTALK = 22,     /* position 20. Pair stage: crosstalk cancellation. */
    N60_STAGE_OUTPUT_GAIN = 19,   /* position 21. Output gain and balance (GAIN rules, one lane per stage for balance). */
    N60_STAGE_HEADPHONE = 23,     /* position 22. Pair stage: headphone crossfeed and channel correction. */
    N60_STAGE_PAUSE_GATE = 24,    /* position 23. Linked silence gate. */
    N60_STAGE_DELAY = 8,          /* position 24. Integer delay. params[0] = frames (0..capacityFrames); changes crossfade over 5 ms.
                                   * (Position 13 before ABI v4: ICD and master gain now precede protection.) */
    N60_STAGE_ANC_GUARD = 25,     /* position 25. ANC howl guard on the anti-noise lane. */
    N60_STAGE_ANC_INJECT = 26,    /* position 26. ANC injection point; silent unless authorised in the snapshot. */
    N60_STAGE_PROTECTION = 27,    /* position 27. Limiter and true-peak guard; the last audio-modifying stage. */
    N60_STAGE_MUTE = 28,          /* position 28. Ramped mute. */
    N60_STAGE_ANC_CAPTURE = 29,   /* position 29. ANC reference capture point. */
    N60_STAGE_FINAL_SANITISE = 30,/* position 30. Sanitise rules. */
    N60_STAGE_FINAL_METER = 31    /* position 31. Meter rules; read with n60_graph_read_meter. */
} n60_stage_kind;

/* Lane selection for the ABI v3 stages (DENOISER, DYN_EQ, FIR, COMPRESSOR, EXPANDER):
 * laneMask != 0 selects exactly the lanes whose bit is set (bit c = output lane c; laneA
 * must then be 0); otherwise laneA picks one lane or N60_LANE_ALL. Stages that link lanes
 * (see each kind) treat the selected lanes as one group, so one stage with N60_LANE_ALL
 * or a mask is the way to build a linked N-channel dynamics group. Every other stage
 * kind requires laneMask == 0.
 *
 * Compressor. params: [0] threshold dB (-96..0), [1] ratio (1..100), [2] knee dB (0..24),
 *  [3] attack ms (0.05..1000), [4] release ms (1..5000), [5] makeup dB (-24..24),
 *  [6] topology (0 feed-forward, 1 feedback), [7] program-dependent release (0/1),
 *  [8] sidechain high-pass Hz (0 = off, up to 300), [9] linked (0/1; 1 = one detector
 *  and one gain for the whole lane group). paramCount 10. Live: [0]..[8]. Peak detector,
 *  dB-domain gain smoothing, soft knee, as in the stereo kernel path.
 *
 * Expander / gate. params: [0] threshold dB (-120..0), [1] ratio (1..20), [2] range dB
 *  (-96..0), [3] attack ms, [4] release ms (as above), [5] linked (0/1). paramCount 6.
 *  Live: [0]..[4].
 *
 * Dynamic EQ. params: [0] linked (0/1), then per band 15 values: shape (0 peak, 1 low
 *  shelf, 2 high shelf, 3 notch, 4 band pass, 5 tilt), Hz (20..20000, below Nyquist),
 *  Q (0.4..8), static dB (-18..6), threshold dB (-60..0), ratio (1..10), range dB
 *  (-24..0), attack ms (1..100), release ms (10..1000), direction (0 cut, 1 boost,
 *  2 both; a notch must be 0), boost threshold dB (-60..0), boost ratio (1..10), max
 *  boost dB (0..12), detector (0 peak, 1 RMS), RMS window ms (5..200). One to 64 bands
 *  in series. Live: everything except [0], shape and direction. The kernel's Mid/Side
 *  domain is not a mode here: put the stage between M/S encode and decode.
 *
 * Denoiser. params: [0] tuning (0 natural, 1 standard, 2 aggressive, 3 dehiss, 4 custom
 *  = standard), [1] quality (0/1/2 = FFT 1024/2048/4096), [2] reduction (0..1),
 *  [3] threshold dBFS (-96..-30), [4] protected range on (0/1), [5] protected low Hz,
 *  [6] protected high Hz (below Nyquist), [7] profile command (0 none, 1 capture,
 *  2 reset), [8] profile revision (integer 0..16777216; a command runs when this
 *  changes). paramCount 9. Live: [2]..[8]. Sqrt-Hann STFT at 50% overlap, linked
 *  Wiener gain over all selected lanes. Latency fftSize frames.
 *
 * Program FIR. params = the taps (1..32768 floats), identical on every selected lane.
 *  Uniformly partitioned convolution, 256-frame partitions: latency 256 frames plus
 *  capacityFrames, which for this kind is the filter's own declared group delay (it is
 *  reported, never applied). Taps are not live: publish a new snapshot. */
/* System stages (ABI v4). Lane rules: BASS_MGMT, PAUSE_GATE and ANC_CAPTURE take laneMask; AMBIENT, MUTE and
 * PROTECTION take laneMask or laneA/N60_LANE_ALL; SYMMETRY, CROSSFEED, CROSSTALK and HEADPHONE are pair
 * stages on (laneA, laneB); ANC_GUARD and ANC_INJECT address one lane with laneA. ROOM_FIR, SPEAKER_IR,
 * CORE_DYNAMICS, OUTPUT_GAIN, FINAL_SANITISE and FINAL_METER follow the FIR, COMPRESSOR, GAIN, SANITISE and
 * METER_OUT rules. A "live" parameter may be posted; the rest need a new snapshot (UNSUPPORTED).
 *
 * BASS_MGMT (mask = main lanes). params: [0] crossover Hz (live), [1] redirect dB (live, -24..12),
 *  [2] sub lane, [3] LFE lane (-1 none; may equal the sub lane), [4] LFE low-pass Hz (live, 20..500),
 *  [5] LFE gain dB (live, -24..24), [6] sub gain dB (live, -60..24), [7] sub polarity (0 normal, 1 invert),
 *  [8] sub EQ section count n (0..4), then 4 per section (type, Hz, dB, Q). paramCount 9+4n.
 *  Mains get a Linkwitz-Riley 4 high-pass, their low-pass is summed (x redirect) with the LFE low-pass into
 *  the sub lane, which is replaced. The sub and LFE lanes must not be in the mask. Sub delay is a DELAY stage.
 * AMBIENT. params: [0] level dB (live, -60..24), then three peaking bands (Hz, dB, Q). paramCount 10.
 * SYMMETRY. params: [0] position -1..1 (live). CROSSFEED. params: [0] amount 0..0.5 (live).
 * CROSSTALK. params: [0] shadow low-pass Hz 200..2000 (live), [1] amount 0..1 (live).
 * HEADPHONE (pair A, B). params: [0] headroom dB (-24..0), [1] crossfeed amount 0..1 (live), [2] angle 15..90 deg,
 *  [3] radius 0.06..0.12 m, [4] crossfeed low-pass Hz (200..2000), [5] gain A dB, [6] gain B dB (live, -24..24),
 *  [7] polarity A, [8] polarity B (0/1), [9] sections nA, [10] sections nB (0..16), then 4 per section (A, then B).
 * PAUSE_GATE (linked). params: [0] threshold dBFS (-120..-20), [1] hysteresis dB (0..24), [2] hold ms (0..5000),
 *  [3] fade-out ms (0.05..1000), [4] fade-in ms (0.05..5000). paramCount 5. Starts open.
 * PROTECTION (linked over its lanes). params: [0] limiter on (0/1), [1] ceiling dB (live, -20..0), [2] attack ms
 *  (live, 0.1..50), [3] release ms (live, 5..500), [4] look-ahead ms (0..20), [5] true-peak guard (0/1),
 *  [6] oversampling 1/2/4. paramCount 7. With the limiter and guard both on the factor is 4. Latency is the
 *  half-band delay (32 at 2x, 48 at 4x) plus ceil(look-ahead high samples / factor) frames. The kernel's soft
 *  clipper and gain rider are not part of this stage.
 * MUTE. params: [0] muted (0/1, live); 10 ms ramp.
 * ANC_GUARD (laneA = anti-noise lane, modified in place; the error and reference lanes are read-only).
 *  params: [0] error lane (-1 none), [1] reference lane (-1 none), [2] growth dB per 20 ms (0.5..40),
 *  [3] growth blocks (1..10), [4] reference allowance dB (0..20), [5] error rise dB (0.5..40), [6] error rise
 *  blocks (1..10), [7] output ceiling (0..1], [8] activity floor dB (-160..0), [9] mute ramp s (0.001..0.1),
 *  [10] has baseline (0/1), [11] rearm revision (live; a change re-arms), [12..27] baseline dB per band
 *  (-200..0). paramCount 28. Status through n60_graph_read_guard.
 * ANC_INJECT (laneA = target speaker lane). params: [0] source lane, [1] authorised (0/1, NOT live, default 0),
 *  [2] gain dB (live, -96..0), [3] re-arm revision (optional, live, integer 0..16777216; a change after a
 *  rebuild lets injection resume, see n60_rebuild_status). paramCount 3 or 4. Adds the source lane into the target only when authorised, and always clears the
 *  source lane. Authorisation exists only as this snapshot value; the core never sets it.
 * ANC_CAPTURE (mask). capacityFrames = ring length per lane (1..4194304). params: [0] authorised (0/1, NOT live,
 *  default 0): nothing is written when 0. Read with n60_graph_read_capture. */
#define N60_ANC_GUARD_BANDS 16u
#define N60_FIR_PARTITION_FRAMES 256u
#define N60_FIR_MAX_TAPS (128u * N60_FIR_PARTITION_FRAMES)
#define N60_DYN_EQ_MAX_BANDS 64u
#define N60_DYN_EQ_BAND_PARAMS 15u

/* PEQ section types (params[4*s]): 0 peaking, 1 low shelf, 2 high shelf, 3 low pass,
 * 4 high pass, 5 notch, 6 all pass, 7 band pass. Gain is -24..+24 dB. */
#define N60_PEQ_MAX_SECTIONS 16u
#define N60_GRAPH_MAX_STAGES 256u
#define N60_GRAPH_MAX_DELAY_FRAMES (1u << 22)
#define N60_LANE_ALL 0xFFFFFFFFu /* stage runs on every output lane, each with its own state */

typedef struct n60_stage_desc {
    uint32_t structSize;      /* sizeof(n60_stage_desc) */
    uint32_t kind;            /* n60_stage_kind */
    uint32_t stageId;         /* unique within the graph; addresses the stage in post_params */
    uint32_t laneA;           /* output lane, or N60_LANE_ALL (not for M/S stages) */
    uint32_t laneB;           /* second lane of an M/S pair, otherwise 0 */
    uint32_t capacityFrames;  /* DELAY: largest delay this stage can ever be set to; FIR: declared filter latency; otherwise 0 */
    const float *params;      /* initial parameter values (copied) */
    uint32_t paramCount;
    uint32_t reserved;        /* must be 0 */
    uint64_t laneMask;        /* ABI v3: lane set for the stages listed above; 0 = use laneA */
} n60_stage_desc;

typedef struct n60_graph_desc {
    uint32_t structSize;      /* sizeof(n60_graph_desc) as seen by the caller */
    uint32_t abiVersion;      /* N60_GRAPH_ABI_VERSION as seen by the caller */
    double sampleRate;        /* Hz, native device rate; no resampling inside the graph */
    uint32_t maxBlockFrames;  /* process accepts any block from 1 to this */
    uint32_t inputChannels;
    uint32_t outputChannels;
    const n60_stage_desc *stages; /* NULL when stageCount is 0 */
    uint32_t stageCount;
    uint32_t reserved;            /* must be 0 */
} n60_graph_desc;

/* Counters since build. Safe to read from the control thread at any time. */
typedef struct n60_graph_stats {
    uint32_t liveEpoch;          /* epoch of the snapshot the realtime thread is rendering */
    uint32_t publishedEpoch;     /* epoch of the newest published snapshot */
    uint64_t paramsApplied;      /* mailbox records applied */
    uint64_t paramsDropped;      /* stale (older epoch) or no-longer-valid records */
    uint64_t sanitisedSamples;   /* non-finite samples replaced by the sanitise stages */
    uint64_t snapshotsRetired;   /* snapshots handed back by the realtime thread */
} n60_graph_stats;

/* ABI version of the loaded library; compare with N60_GRAPH_ABI_VERSION. */
uint32_t n60_graph_abi_version(void);

/* Control thread. Validates desc and allocates everything the graph will ever need.
 * On success *outGraph owns it; on failure *outGraph is NULL (when outGraph itself
 * is valid). The rate and channel counts are fixed for the life of the handle. */
n60_status n60_graph_build(const n60_graph_desc *desc, n60_graph **outGraph);

/* Control thread. Builds a new topology snapshot (stages, order, parameters) and
 * publishes it for the realtime thread. desc must repeat the handle's sampleRate,
 * maxBlockFrames and channel counts (those need a new graph). On any failure the
 * live graph is untouched. Returns N60_STATUS_QUEUE_FULL if too many retired
 * snapshots await n60_graph_collect. A snapshot published twice before the
 * realtime thread runs supersedes the first, which is freed without ever rendering.
 * The new snapshot has fresh state (filters, delays, meters, gain at its target). Since
 * ABI v5 it is not swapped in cold: the realtime thread renders it next to the live one
 * (silent warm-up long enough to fill its latency), then crossfades live -> new with an
 * equal-power law over the fade length (default 20 ms; see n60_rebuild_options). Both
 * graphs run during the rebuild, and the next publish waits until it finishes. Live ANC
 * injection is muted in both instances for the whole rebuild and stays muted until the
 * host posts a new re-arm revision. Parameter records posted before a publish
 * are dropped at adoption: repeat them in the new descriptor. */
n60_status n60_graph_publish(n60_graph *graph, const n60_graph_desc *desc);

/* ABI v5 rebuild policy. fadeMs: crossfade length for later publishes, 0..500, default 20; 0 swaps
 * instantly (not click-free). cpuBudgetPercent: 0 = off (default); otherwise a rebuild is refused,
 * and the live graph kept, when the measured cost of rendering both graphs during the warm-up exceeds
 * this percent of real time. */
typedef struct n60_rebuild_options {
    uint32_t structSize; /* sizeof(n60_rebuild_options) */
    float fadeMs;
    float cpuBudgetPercent;
    uint32_t reserved;   /* must be 0 */
} n60_rebuild_options;

n60_status n60_graph_set_rebuild_options(n60_graph *graph, const n60_rebuild_options *options);

/* Rebuild progress. state: 0 idle, 1 warming, 2 fading. lastResult: 0 none, 1 completed, 2 refused for
 * CPU budget, 3 cancelled because the new graph produced non-finite output; in cases 2 and 3 the live
 * graph kept running. ancStagesHeld: ANC injection stages muted by the last rebuild (they stay muted
 * until a new re-arm revision, ANC_INJECT params[3], is posted after the rebuild is idle; revisions
 * posted during a rebuild are ignored; a 3-parameter ANC_INJECT has no revision and so stays muted after
 * any rebuild). Known limits: records posted against a snapshot that is then refused or cancelled are
 * dropped and counted; a mid-fade cancel returns to the old graph at once (not crossfaded); the incoming
 * graph's latency is not compensated during the fade; the CPU budget reads steady_clock once per warm-up
 * block (the one clock read on the callback path, a documented exception). The caller sets structSize
 * before the call. */
typedef struct n60_rebuild_status {
    uint32_t structSize; /* sizeof(n60_rebuild_status) */
    uint32_t state;
    uint32_t lastResult;
    uint32_t ancStagesHeld;
    uint64_t completed;
    uint64_t refused;
    uint64_t cancelled;
    float lastWarmupCpuPercent; /* measured at the end of the last budgeted warm-up, else 0 */
    uint32_t reserved;
} n60_rebuild_status;

n60_status n60_graph_get_rebuild_status(const n60_graph *graph, n60_rebuild_status *outStatus);

/* Control thread. Frees snapshots the realtime thread has retired. Returns how many. */
uint32_t n60_graph_collect(n60_graph *graph);

/* Realtime thread. in[c] / out[c] each point at `frames` floats; in has
 * inputChannels entries and out has outputChannels entries. In-place use (in[c]
 * == out[c]) is allowed. frames == 0 is a no-op. Channel c is copied to lane c;
 * output channels with no input are written with silence; then the stages run in
 * place on the output buffers. Buffers of different channels must not overlap.
 * Callers must not pass NULL pointers. */
n60_status n60_graph_process(n60_graph *graph, const float *const *in, float *const *out, uint32_t frames);

/* One parameter target for a stage (latest wins, coalesced at block start).
 * Live parameters: see each stage kind (GAIN params[0] linear 0..10000, DELAY params[0] frames rounded
 * 0..capacityFrames, PEQ every section parameter, ...). Edits are ramped or crossfaded inside the stage
 * (5 ms) and never reset state. Anything that needs a new topology returns N60_STATUS_UNSUPPORTED;
 * publish a new snapshot instead.
 * A batch is validated whole and applied all or nothing. Unknown stage ids or
 * indexes are N60_STATUS_BAD_ARGUMENT. Records are tagged with the newest
 * published epoch; the realtime thread drops records older than the snapshot it
 * renders, so a publish never inherits an earlier snapshot's pending edits. */
typedef struct n60_param_record {
    uint32_t stageId;
    uint32_t paramIndex;
    float value;
    uint32_t reserved; /* must be 0 */
} n60_param_record;

n60_status n60_graph_post_params(n60_graph *graph, const n60_param_record *records, uint32_t count);

/* Control thread. Reads a meter stage of the newest published snapshot: peak is the
 * largest absolute sample since the previous read (and is reset by this call), rms
 * is the RMS of the most recent block. Both are 0 until the realtime thread has
 * rendered that snapshot. */
n60_status n60_graph_read_meter(n60_graph *graph, uint32_t stageId, uint32_t lane, float *peak, float *rms);

void n60_graph_get_stats(const n60_graph *graph, n60_graph_stats *outStats);

/* Control thread. Frees the graph and every snapshot, only after the realtime
 * thread has stopped using it. NULL is allowed. */
void n60_graph_retire(n60_graph *graph);

/* Howl guard status (ANC_GUARD). trip: 0 none, 1 growth, 2 error rise, 3 non-finite, 4 over ceiling. */
typedef struct n60_guard_status {
    uint32_t structSize;      /* sizeof(n60_guard_status) as seen by the caller (ABI v5) */
    uint32_t trip;
    uint32_t muted;
    uint64_t tripFrame;       /* frames since arm at the trip */
    uint64_t processedFrames;
    uint64_t tripCount;
} n60_guard_status;

/* Control thread. Reads the guard stage of the newest published snapshot. */
n60_status n60_graph_read_guard(n60_graph *graph, uint32_t stageId, n60_guard_status *out);

/* Control thread. Copies `frames` captured samples of one lane of an ANC_CAPTURE stage, starting at absolute
 * sample index startSample (counted from the snapshot's first frame), into dst. *written receives the number of
 * samples written so far. N60_STATUS_UNSUPPORTED when the range is not (or no longer) in the ring. */
n60_status n60_graph_read_capture(n60_graph *graph, uint32_t stageId, uint32_t lane, uint64_t startSample,
                                  float *dst, uint32_t frames, uint64_t *written);

/* Largest total latency in frames over the output lanes for the live graph: the sum, per
 * lane, of its DELAY stages, FIR-type stages (256 + declared latency), denoiser stages (FFT
 * size) and protection stages (oversampling plus look-ahead); 0 with none. Updated by the realtime thread when
 * it adopts a snapshot or applies a delay parameter. */
uint32_t n60_graph_latency_frames(const n60_graph *graph);

#ifdef __cplusplus
}
#endif

#endif /* N60_GRAPH_H */
