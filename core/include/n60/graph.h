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
#define N60_GRAPH_ABI_VERSION 14u

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
    N60_STAGE_AMBIENT = 18,       /* position 16. Ambient compensation: ramped level plus low-shelf, peaking and high-shelf bands. */
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
    N60_STAGE_FINAL_METER = 31,   /* position 31. Meter rules; read with n60_graph_read_meter. */
    /* ABI v6 matrix stage (E6 S7). See "Binaural" below. */
    N60_STAGE_BINAURAL = 32,      /* position 17.5: after CORE_DYNAMICS, before SYMMETRY. N source lanes in, two lanes out. */
    /* ABI v11 (E6 S8d group 3). */
    N60_STAGE_FRAC_DELAY = 33,    /* position 24, with DELAY. Fractional delay: Thiran all-pass. See "Fractional delay" below. */
    /* ABI v12 (E6 S8d group 4). */
    N60_STAGE_STEREO_CROSSOVER = 34,/* position 13, with BASS_MGMT. Pair stage: stereo crossover. See "Stereo crossover" below. */
    /* ABI v13 (E6 S8e). */
    N60_STAGE_EXTERNAL = 35,        /* position 12.5: after METER_OUT, before BASS_MGMT. Host-supplied processor. See "External processor" below. */
    /* ABI v14 (E11 S7). */
    N60_STAGE_GENERATOR = 36        /* position 3.5: after GAIN, before DENOISER. Test-signal source. See "Generator" below. */
} n60_stage_kind;

/* Generator (ABI v14). A source that replaces program audio on its lanes, ahead of every correction stage and
 * therefore ahead of PROTECTION, so it reaches the speakers through the same path as music. Lanes: laneMask,
 * or laneA (one lane or N60_LANE_ALL). Each selected lane has its own uncorrelated stream. paramCount 11:
 *  [0] type: N60_GENERATOR_*  [1] level dBFS RMS (live, -120..0)  [2] ceiling dBFS RMS (-60..-6; the level is
 *  clamped to it)  [3] sine Hz (1..0.45 fs)  [4] low edge Hz, [5] high edge Hz (band-limited pink: 10..0.45 fs,
 *  high >= 1.05 low; each edge is the -3 dB point of a 4th-order slope)  [6] period in frames (periodic pink:
 *  power of two, 256..1048576)  [7] seed (integer 0..16777216)  [8] mute other lanes while playing (0/1)
 *  [9] active (live, 0/1)  [10] auto-stop seconds (0.001..600).
 * Starting, stopping and level changes ramp over 100 ms (program audio crossfades to the source). A rising edge of
 * [9] from silence restarts the stream from its seed. After the auto-stop time the source fades out and stays
 * silent until [9] goes 0 then 1. Output is clamped to +-1. Sine level is RMS (peak = RMS x sqrt 2). */
#define N60_GENERATOR_WHITE 0u
#define N60_GENERATOR_PINK 1u
#define N60_GENERATOR_BAND_PINK 2u
#define N60_GENERATOR_SINE 3u
#define N60_GENERATOR_PERIODIC_PINK 4u

/* External processor (ABI v13). The graph calls back into the host for work the core cannot do itself and must
 * not know about (the macOS app's Audio Unit rack). The stage sits between the playback half and the system half
 * of the chain, as the rack does in the stereo kernel. desc: laneA / laneMask select the lanes it covers
 * (laneCount must equal the processor's channel count, else the stage passes audio through), capacityFrames =
 * the processor's declared latency in frames (0..N60_GRAPH_MAX_DELAY_FRAMES, added to the path latency), paramCount 1,
 * params[0] = active (0 bypass, 1 process; live, a 0/1 switch applied at the next block). At most one EXTERNAL
 * stage per graph. The callback itself is not part of a snapshot: n60_graph_set_external_processor registers it
 * for the whole graph (control thread, IO stopped or the previous callback cleared first).
 * The callback runs on the realtime thread inside n60_graph_process, so it must obey the realtime rules itself.
 * It processes `frames` frames of `channels` planar lanes in place (in and out are the same pointers) and returns
 * non-zero on success. On failure the stage outputs silence for the block and counts a fault.
 * Rebuild fade: the callback is called once per block, by the live snapshot only. While a rebuild runs, the
 * incoming snapshot's EXTERNAL stage adds the processor's effect (output minus input) from the live snapshot's
 * call instead of calling the host a second time; when the live snapshot has no active EXTERNAL stage the
 * incoming one passes audio through until it becomes live. */
typedef int (*n60_external_process_fn)(void *context, const float *const *in, float *const *out, uint32_t channels,
                                       uint32_t frames);

/* Stereo crossover (ABI v12). Pair stage (laneA, laneB). params: [0] frequency Hz (>0, below Nyquist),
 * [1] topology 0 LR24 or 1 LR48, [2] monitor mode 0 recombined, 1 mains only, 2 sub only, [3] sub gain (linear,
 * >= 0), [4] sub polarity inverted (0/1), [5] sub phase alignment on (0/1), [6] alignment Hz, [7] alignment Q.
 * paramCount 8, all fixed at build time. Mains are a high-pass per lane, the sub is (A + B) * 0.5 through the
 * low-pass (then the all-pass), gain and polarity. Double-precision sections with a float result between them.
 * Latency 0. Reset clears the section states. */

/* Fractional delay (ABI v11). params: [0] whole frames, the integer part of the requested delay
 * (0..8190), [1] fraction (0..1). The core designs the same causal Thiran all-pass (highest stable
 * order up to 3, exact integer delays bypass the all-pass) the stereo kernel uses, in double, and
 * runs it in float. paramCount 2, no capacityFrames, one independent delay line per lane. Both
 * params are topology: a change is a new snapshot (the host fades the rebuild). Latency is [0]. State (an 8192-frame ring, about 21 ms at 384 kHz, and the all-pass history, float like the kernel) is zeroed at snapshot build and never rebuilt in place.
 *
 * Lane selection for the ABI v3 stages (DENOISER, DYN_EQ, FIR, COMPRESSOR, EXPANDER):
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
 *  changes). paramCount 9. Live: [2]..[8]. Since ABI v9 the noise profile (captured or learned), its counters and
 *  the last profile revision survive a rebuild of the same quality, and are kept while the stage is absent (the
 *  kernel keeps them while the denoiser is off; see parkFftSize). A quality change starts a fresh profile. Sqrt-Hann STFT at 50% overlap, linked
 *  Wiener gain over all selected lanes. Latency fftSize frames.
 *
 * Program FIR. params = the taps (1..32768 floats), identical on every selected lane.
 *  Uniformly partitioned convolution, 256-frame partitions: latency 256 frames plus
 *  capacityFrames, which for this kind is the filter's own declared group delay (it is
 *  reported, never applied). Taps are not live: publish a new snapshot. Since ABI v10 a rebuild that leaves a FIR
 *  stage unchanged (same stage id, taps and lanes) copies its running state into the new snapshot, so the convolver
 *  does not restart; a new or changed FIR warms silently for its full tap length (+256 frames) before the crossfade.
 *  Only partitions written since the stage last started (or since n60_graph_invalidate_history) are accumulated. */
/* System stages (ABI v4). Lane rules: BASS_MGMT, PAUSE_GATE and ANC_CAPTURE take laneMask; AMBIENT, MUTE and
 * PROTECTION take laneMask or laneA/N60_LANE_ALL; SYMMETRY, CROSSFEED, CROSSTALK and HEADPHONE are pair
 * stages on (laneA, laneB); ANC_GUARD and ANC_INJECT address one lane with laneA. ROOM_FIR, SPEAKER_IR,
 * CORE_DYNAMICS, OUTPUT_GAIN, FINAL_SANITISE and FINAL_METER follow the FIR, COMPRESSOR, GAIN, SANITISE and
 * METER_OUT rules. A "live" parameter may be posted; the rest need a new snapshot (UNSUPPORTED).
 *
 * BASS_MGMT (mask = main lanes). params: [0] crossover Hz (live), [1] redirect dB (live, -24..12),
 *  [2] sub 0 lane, [3] LFE lane (-1 none; may equal a sub lane), [4] LFE low-pass Hz (live, 20..500),
 *  [5] LFE gain dB (live, -24..24), [6] sub 0 gain dB (live, -60..24), [7] sub 0 polarity (0 normal, 1 invert; live),
 *  [8] sub 0 EQ section count n0 (0..8), then 4 per section (type, Hz, dB, Q; Hz, dB and Q are live, type is not).
 *  Mains get a Linkwitz-Riley 4 high-pass, their low-pass is summed (x redirect) with the LFE low-pass into ONE bass
 *  sum. ABI v7 (E6 S7b): that sum drives 1 to 8 sub lanes. After sub 0's sections an optional extension follows:
 *  [9+4*n0] extension word w (0..15): m = w mod 8 extra subs (0..7), and w >= 8 selects host-weighted mode. Then
 *  for each extra sub: lane, gain dB (live), polarity (live), section count n (0..8), then 4 per section. paramCount
 *  is 9+4*n0 for one sub (identical to ABI v6), otherwise the sum of the blocks. Each sub is bass sum * norm * its
 *  gain * its polarity, then its sections in order. Default mode: norm = 1/N (N = sub count), matching the shipping
 *  engine's 1/N redirect, so N coherent subs sum to the level of one; norm is exactly 1 for one sub, which keeps the
 *  v6 list bit-identical. Host-weighted mode (w >= 8, for room optimisation): norm = 1 and the per-sub gains are
 *  used as given. The mode is part of the topology: changing it, the sub count, lanes or section counts needs a new
 *  snapshot (rebuild fade; a live post to w is UNSUPPORTED). Sub lanes are replaced, must be distinct and outside
 *  the mask; the LFE lane is cleared unless it is a sub lane. A live edit ramps over the ramp window (gain,
 *  polarity: a flip passes through zero) or crossfades the section's coefficients (Hz, dB, Q). Per-sub delay is a
 *  DELAY stage on the sub lane (rank 24, after this stage).
 *  No added latency.
 * AMBIENT. params: [0] level dB (live, -60..24), then low-shelf, peaking and high-shelf bands (Hz, dB, Q). paramCount 10.
 * SYMMETRY. params: [0] position -1..1 (live). CROSSFEED. params: [0] amount 0..0.5 (live).
 * CROSSTALK. params: [0] shadow low-pass Hz 200..2000 (live), [1] amount 0..1 (live).
 * HEADPHONE (pair A, B). params: [0] headroom dB (-30..0), [1] crossfeed amount 0..1 (live), [2] angle 15..90 deg,
 *  [3] radius 0.06..0.12 m, [4] crossfeed low-pass Hz (200..2000), [5] gain A dB, [6] gain B dB (live, -24..24),
 *  [7] polarity A, [8] polarity B (0/1), [9] sections nA, [10] sections nB (0..16), then 4 per section (A, then B).
 * PAUSE_GATE (linked). params: [0] threshold dBFS (-120..-20), [1] hysteresis dB (0..24), [2] hold ms (0..5000),
 *  [3] fade-out ms (0.05..1000), [4] fade-in ms (0.05..5000). paramCount 5. Starts open.
 * PROTECTION (linked over its lanes). params: [0] limiter on (0/1), [1] ceiling dB (live, -20..0), [2] attack ms
 *  (live, 0.1..50), [3] release ms (live, 5..500), [4] look-ahead ms (0..20), [5] true-peak guard (0/1),
 *  [6] oversampling 1/2/4. paramCount 7 (limiter only) or 18 (ABI v12, with the soft clipper and gain rider):
 *  [7] clipper on (0/1), [8] drive dB (0..12), [9] threshold dB (-6..0), [10] knee 0..1, [11] curve 0..3
 *  (quadratic, cubic, sine, asymmetric tube), [12] auto compensation (0/1), [13] asymmetry trim dB (-3..3),
 *  [14] gain rider on (0/1), [15] target reduction dB (0.5..6), [16] max reduction dB (3..12), [17] speed 0/1/2
 *  (3, 10, 30 s). With the limiter and guard both on the factor is 4. Latency is the half-band delay (32 at 2x,
 *  48 at 4x) plus ceil(look-ahead high samples / factor) frames. With the limiter off the stage is a bypass
 *  unless the clipper is on, when it runs at factor [6]. The clipper acts per oversampled sample before the
 *  limiter; the rider (active only with the limiter on) scales each frame by the sustained limiter reduction
 *  before oversampling. Its state is carried across a rebuild.
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
/* Binaural (ABI v6, matrix stage). laneMask = the N source lanes (virtual speakers, in layout order);
 * laneA / laneB = the left / right ear output lanes (distinct, any lane, may be source lanes). The stage
 * reads every source lane, writes the two ear signals into laneA and laneB, and clears every other source
 * lane, so the host reads the ears from those two output channels. The graph's channel counts stay fixed
 * for the handle: a binaural graph is built with outputChannels >= the source count and the host listens to
 * the two ear lanes. Each source is convolved with its own pair of ear impulse responses (uniformly
 * partitioned, 128-frame partitions, 256-point FFT), so the stage matches the shipping N60BinauralRenderer.
 * params: [0] head yaw deg (live, -720..720), [1] head pitch deg (live, -180..180), [2] head roll deg
 *  (live, -180..180), [3] taps per impulse response (1..8192), [4] orientation sets O (1..64),
 *  [5] yaw of set 0 in deg (-360..360), [6] yaw step between sets in deg ((0,360], or 0..360 when O = 1),
 *  [7] wrap (0/1; 1 = the O sets cover a full circle and the last neighbours the first),
 *  [8] equal-ear source index (-1 none, else 0..N-1: that source's two responses are averaged and used for
 *  both ears, as the kernel does for the LFE), [9] declared extra latency of the responses in frames
 *  (0..N60_GRAPH_MAX_DELAY_FRAMES; reported, never applied), then 10 + (set, source, ear, tap) floats:
 *  paramCount = 10 + O * N * 2 * taps, set-major, then source, then ear (0 left, 1 right), then tap.
 * Cost: the whole partition runs at the 128th frame of each block (spiky for small host buffers); it scales with
 * sources x partitions x 129 bins x 2 ears, doubled for a two-set blend and again while the head moves. Hosts
 * budget taps and source counts accordingly (rebuild CPU-budget refusal covers publishes). Responses must be finite.
 * Head tracking: the host posts yaw (and pitch and roll) through the mailbox like any live parameter.
 * Set k is the response set for head yaw = [5] + k * [6]. The live yaw is slew-smoothed (about 10 ms) into a
 * fractional set position and the two neighbouring sets are blended in the frequency domain, per 128-frame
 * block; while the position is moving the output fades linearly across the block from the previous
 * position's blend to the new one, so there is no step at block boundaries. Pitch and roll are accepted and stored for the host (and for later elevation sets) but do not yet
 * change the rendering. Latency 128 frames plus [9]. Not live: taps, sets, responses and every other
 * parameter (publish a new snapshot; the rebuild fade makes that click-free). */
#define N60_GRAPH_BINAURAL_PARTITION_FRAMES 128u
#define N60_GRAPH_BINAURAL_MAX_TAPS 8192u
#define N60_GRAPH_BINAURAL_MAX_SETS 64u
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
    /* ABI v9: what the legacy kernel's denoiser sees while it is switched off, so a graph without a DENOISER
     * stage keeps the profile the kernel would keep. parkFftSize 0 = not tracked (1024, 2048 or 4096 otherwise,
     * the FFT size of the quality setting), parkRevision / parkCommand = the profile revision and command (0 none,
     * 1 capture, 2 reset). Ignored when the description has a DENOISER stage. A change publishes a new snapshot. */
    uint32_t parkFftSize;
    uint32_t parkRevision;
    uint32_t parkCommand;
    uint32_t reserved2;           /* must be 0 */
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

/* ABI v9. The learned or captured noise profile of a DENOISER stage, as a plain value. The same layout the
 * kernel's denoiser exports, so the two engines hand a profile to each other at a switch. fftSize 0 = no
 * state (a fresh profile). flags: 1 profile ready, 2 captured, 4 capture active, 8 adaptive block fresh. */
#define N60_DENOISER_STATE_MAX_BINS 2049u
typedef struct n60_denoiser_state {
    uint32_t fftSize;
    uint32_t flags;
    uint32_t adaptiveFrames;
    uint32_t adaptiveTarget;
    uint32_t adaptiveBlocks;
    uint32_t lastRevision;
    uint32_t captureCollected;
    uint32_t captureTarget;
    float noise[N60_DENOISER_STATE_MAX_BINS];
    float adaptiveMin[N60_DENOISER_STATE_MAX_BINS];
    float captureSum[N60_DENOISER_STATE_MAX_BINS];
} n60_denoiser_state;

/* ABI version of the loaded library; compare with N60_GRAPH_ABI_VERSION. */
uint32_t n60_graph_abi_version(void);

/* Control thread. Validates desc and allocates everything the graph will ever need.
 * On success *outGraph owns it; on failure *outGraph is NULL (when outGraph itself
 * is valid). The rate and channel counts are fixed for the life of the handle. */
n60_status n60_graph_build(const n60_graph_desc *desc, n60_graph **outGraph);

/* Realtime thread only (the thread that calls n60_graph_process; bounded copies, no allocation). Copies the
 * denoiser profile of the live graph into *out: the DENOISER stage's, or the one kept while the stage is absent.
 * Returns 1 when there is one, 0 when not (then *out is untouched). */
int n60_graph_denoiser_export(n60_graph *graph, n60_denoiser_state *out);

/* ABI v10 (E6 S8d). Realtime thread only. Drops the input history of every FIR / ROOM_FIR / SPEAKER_IR stage of the
 * live graph (and the incoming and waiting snapshots of a rebuild) in O(1): the stages restart from silence the next time they run, so a
 * graph that was not rendering does not replay stale audio when it takes over. Nothing is cleared or allocated here. */
void n60_graph_invalidate_history(n60_graph *graph);

/* ABI v10. Realtime thread only. Input frames the FIR stages of the live, incoming and waiting snapshots need to be fully warm (longest taps plus
 * one 256-frame partition; 0 when there is none). A host that renders the graph silently before it takes over should
 * warm it at least this long. */
uint32_t n60_graph_history_frames(n60_graph *graph);

/* Realtime thread only. `in` must come from a denoiser export (the counters and arrays are trusted, not
 * range-checked). Makes `in` the graph's profile (stage or parked, and the incoming snapshot of a
 * rebuild). fftSize 0 clears it. A state of another FFT size than the stage's is dropped. */
void n60_graph_denoiser_import(n60_graph *graph, const n60_denoiser_state *in);

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
 * instantly (not click-free, and without the silent warm-up, so a new or changed FIR is heard partially built).
 * cpuBudgetPercent: 0 = off (default); otherwise a rebuild is refused,
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

/* ===== ABI v8 (E6 S8c): dynamics, true-peak and over-range readbacks ===========================
 * Same pattern as n60_graph_read_meter: control thread only, reads the newest published snapshot,
 * non-blocking (relaxed atomics written by the realtime thread), and peaks, reductions and counts
 * are reset by the read. All values are 0 until the realtime thread has rendered that snapshot. */
typedef struct n60_dynamics_readback {
    uint32_t structSize;      /* sizeof(n60_dynamics_readback) as seen by the caller */
    uint32_t kind;            /* the stage's canonical kind: COMPRESSOR (also CORE_DYNAMICS), EXPANDER or PROTECTION */
    float grMaxDb;            /* deepest gain reduction (>= 0 dB) since the previous read; reset by the read */
    float grNowDb;            /* reduction at the end of the most recently rendered block (not reset) */
    float inTruePeak;         /* PROTECTION: largest |x| at the oversampled input of the limiter (factor 1 = sample peak), linear, since the previous read */
    float outTruePeak;        /* PROTECTION: the same after the limiter (factor 1 = sample peak) */
    uint32_t guardActive;     /* PROTECTION: 1 when the limiter runs with oversampling (the true-peak guard) */
    uint32_t reserved;
} n60_dynamics_readback;

/* Reads a COMPRESSOR, CORE_DYNAMICS, EXPANDER or PROTECTION stage for one output lane. A linked group
 * reports its shared gain reduction on every lane it covers; the protection limiter is linked across its
 * lanes, so grMaxDb and grNowDb are the same for all of them while the true peaks are per lane. Gain
 * reduction is max(0, -gain dB) with the stage's make-up gain included, as in the stereo kernel.
 * BAD_ARGUMENT for another kind of stage or a lane the stage does not cover; ABI_MISMATCH on structSize. */
n60_status n60_graph_read_dynamics(n60_graph *graph, uint32_t stageId, uint32_t lane, n60_dynamics_readback *out);

/* Reads the over-range counter of a METER_IN, METER_OUT or FINAL_METER stage lane: samples with
 * |x| > 1.0 since the previous read (reset by the read). */
n60_status n60_graph_read_over_range(n60_graph *graph, uint32_t stageId, uint32_t lane, uint64_t *count);

void n60_graph_get_stats(const n60_graph *graph, n60_graph_stats *outStats);

/* Control thread. Frees the graph and every snapshot, only after the realtime
 * thread has stopped using it. NULL is allowed. */
void n60_graph_retire(n60_graph *graph);

/* ABI v13. Control thread. Registers (process != NULL) or clears (NULL) the host callback of the graph's EXTERNAL
 * stage. channels is 1..N60_GRAPH_MAX_CHANNELS. Allocates the rebuild-fade scratch, so it is not realtime. Change it
 * only while the realtime thread is not inside n60_graph_process, or clear it before the context is freed. */
n60_status n60_graph_set_external_processor(n60_graph *graph, n60_external_process_fn process, void *context,
                                            uint32_t channels);
/* Calls made to the callback and failures (callback returned 0) since registration. Safe at any time. */
void n60_graph_external_stats(const n60_graph *graph, uint64_t *calls, uint64_t *faults);

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

/* ===== ABI v6 (E6 S7): program layouts and the graph builder ================================
 * Stereo is the 2-channel layout {FL, FR}; 5.1 and larger layouts are lists of semantic roles
 * (the numbering matches the app's N60ProgramChannelRole, so the shell converts by value).
 * n60_layout_graph_build turns a layout and a render mode into a ready n60_graph_desc: the same
 * builder produces stereo, 5.1 and larger speaker graphs and the binaural graph; switching mode is
 * publishing the other description (a topology rebuild with the fade). Control thread only. */
#define N60_LAYOUT_MAX_CHANNELS 32u

typedef enum n60_channel_role {
    N60_ROLE_UNUSED = 0, N60_ROLE_FRONT_LEFT = 1, N60_ROLE_FRONT_RIGHT = 2, N60_ROLE_FRONT_CENTER = 3,
    N60_ROLE_LFE = 4, N60_ROLE_SIDE_LEFT = 5, N60_ROLE_SIDE_RIGHT = 6, N60_ROLE_REAR_LEFT = 7,
    N60_ROLE_REAR_RIGHT = 8, N60_ROLE_WIDE_LEFT = 9, N60_ROLE_WIDE_RIGHT = 10,
    N60_ROLE_TOP_FRONT_LEFT = 11, N60_ROLE_TOP_FRONT_RIGHT = 12, N60_ROLE_TOP_MIDDLE_LEFT = 13,
    N60_ROLE_TOP_MIDDLE_RIGHT = 14, N60_ROLE_TOP_REAR_LEFT = 15, N60_ROLE_TOP_REAR_RIGHT = 16,
    N60_ROLE_CUSTOM_1 = 17 /* .. N60_ROLE_CUSTOM_1 + 15 = 32 */
} n60_channel_role;

typedef enum n60_layout_id {
    N60_LAYOUT_CUSTOM = 0, N60_LAYOUT_STEREO = 1, N60_LAYOUT_5_1 = 2, N60_LAYOUT_7_1 = 3,
    N60_LAYOUT_5_1_2 = 4, N60_LAYOUT_5_1_4 = 5, N60_LAYOUT_7_1_4 = 6, N60_LAYOUT_9_1_6 = 7
} n60_layout_id;

typedef struct n60_layout {
    uint32_t structSize;    /* sizeof(n60_layout) */
    uint32_t identifier;    /* n60_layout_id; a standard identifier must match its canonical role order */
    uint32_t channelCount;  /* 1..N60_LAYOUT_MAX_CHANNELS; channel c is graph lane c */
    uint32_t roles[N60_LAYOUT_MAX_CHANNELS];
} n60_layout;

/* Fills *out with a standard layout (identifier 1..7). BAD_ARGUMENT for custom or unknown identifiers. */
n60_status n60_layout_standard(uint32_t identifier, n60_layout *out);
/* OK when the structure is well formed: roles unique and semantic, standard identifiers canonical. */
n60_status n60_layout_validate(const n60_layout *layout);

#define N60_LAYOUT_MAX_PAIRS 16u
/* Pairing used for M/S and linked dynamics: (FL,FR), (SL,SR), (RL,RR), (WL,WR), (TFL,TFR), (TML,TMR),
 * (TRL,TRR) and (Custom 2k-1, Custom 2k), in that order, when both roles are present. */
typedef struct n60_layout_info {
    uint32_t structSize;     /* sizeof(n60_layout_info) */
    uint32_t pairCount;
    uint32_t pairLaneA[N60_LAYOUT_MAX_PAIRS];
    uint32_t pairLaneB[N60_LAYOUT_MAX_PAIRS];
    int32_t centerLane;      /* lane of FRONT_CENTER, or -1 */
    int32_t lfeLane;         /* lane of LFE, or -1 */
    int32_t frontLeftLane;   /* or -1 */
    int32_t frontRightLane;  /* or -1 */
    uint64_t pairedMask;     /* lanes that belong to a pair */
    uint64_t singleMask;     /* non-LFE lanes that are in no pair */
} n60_layout_info;

n60_status n60_layout_describe(const n60_layout *layout, n60_layout_info *out);

typedef enum n60_render_mode {
    N60_MODE_SPEAKERS = 0, /* every layout lane is an output (stereo, 5.1, ...) */
    N60_MODE_BINAURAL = 1  /* the layout's lanes are virtual speakers; the ears come out on lanes 0 and 1 */
} n60_render_mode;

/* Binaural response set for N60_MODE_BINAURAL: the data of the stage parameters [3]..[9] and the
 * responses, in the stage's order (set-major, then layout channel, then ear, then tap). */
typedef struct n60_binaural_profile {
    uint32_t structSize;      /* sizeof(n60_binaural_profile) */
    uint32_t taps;
    uint32_t orientations;
    float yawStartDeg;
    float yawStepDeg;
    uint32_t wrap;
    int32_t equalEarChannel;  /* layout channel index averaged to both ears (the LFE), or -1 */
    uint32_t declaredLatency;
    float headYawDeg, headPitchDeg, headRollDeg;  /* initial head pose */
    const float *responses;   /* orientations * layout.channelCount * 2 * taps floats (copied) */
} n60_binaural_profile;

/* Well known stage ids in a built description, for live posts. */
#define N60_LSTAGE_SANITISE 1u
#define N60_LSTAGE_METER_IN 2u
#define N60_LSTAGE_INPUT_GAIN 3u      /* params[0] linear gain, all lanes */
#define N60_LSTAGE_PEQ 5u             /* LANE_ALL; the per-lane stages are N60_LSTAGE_PEQ_LANE + lane */
#define N60_LSTAGE_METER_OUT 7u
#define N60_LSTAGE_BINAURAL 60u
#define N60_LSTAGE_HEADPHONE 61u
#define N60_LSTAGE_PROTECTION 62u
#define N60_LSTAGE_FINAL_SANITISE 63u
#define N60_LSTAGE_FINAL_METER 64u
#define N60_LSTAGE_OUTPUT_GAIN 65u    /* + lane (speakers: one per layout lane; binaural: lanes 0 and 1) */
#define N60_LSTAGE_MS_ENCODE 100u     /* + pair index */
#define N60_LSTAGE_MS_DECODE 120u     /* + pair index */
#define N60_LSTAGE_PAIR_DYNAMICS 140u /* + pair index: linked compressor on the pair */
#define N60_LSTAGE_LANE_DYNAMICS 160u /* + lane: compressor on an unpaired non-LFE lane */
#define N60_LSTAGE_PEQ_LANE 200u      /* + lane */
#define N60_LSTAGE_SILENCE 300u       /* + lane: gain 0 on graph lanes beyond the layout */

typedef struct n60_layout_options {
    uint32_t structSize;          /* sizeof(n60_layout_options) */
    double sampleRate;
    uint32_t maxBlockFrames;
    uint32_t graphChannels;       /* channel count of the graph handle (in = out); 0 = layout.channelCount; else >= it */
    const n60_layout *layout;
    uint32_t mode;                /* n60_render_mode */
    float inputGain;              /* linear; 0 = 1 */
    uint32_t midSide;             /* 1: encode each pair to M/S around the PEQ */
    const float *peq;             /* optional PEQ section params (4 per section), applied on every layout lane */
    uint32_t peqParamCount;
    uint32_t linkedDynamics;      /* 1: one linked compressor per pair, one per unpaired non-LFE lane */
    const float *compressor;      /* 10 compressor params, or NULL for the defaults; [9] is forced linked on pairs */
    float headphoneCrossfeed;     /* 0 = off; else crossfeed amount 0..1 on the output pair */
    float outputGain;             /* linear; 0 = 1 */
    uint32_t protection;          /* 1: limiter on the output lanes (ceiling -1 dB) */
    const n60_binaural_profile *binaural; /* required in N60_MODE_BINAURAL */
    uint32_t reserved;            /* must be 0 */
} n60_layout_options;

typedef struct n60_layout_graph n60_layout_graph; /* opaque; owns the description and its parameter storage */

/* Builds a description. OK with *out set; BAD_ARGUMENT, OUT_OF_MEMORY or the validation status of the
 * description otherwise. The description is validated by n60_graph_build / n60_graph_publish as usual. */
n60_status n60_layout_graph_build(const n60_layout_options *options, n60_layout_graph **out);
/* Valid until n60_layout_graph_free. Pass to n60_graph_build or n60_graph_publish, which copy everything. */
const n60_graph_desc *n60_layout_graph_desc(const n60_layout_graph *graph);
void n60_layout_graph_free(n60_layout_graph *graph); /* NULL allowed */

#ifdef __cplusplus
}
#endif

#endif /* N60_GRAPH_H */
