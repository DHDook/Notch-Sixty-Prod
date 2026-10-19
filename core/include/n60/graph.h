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
#define N60_GRAPH_ABI_VERSION 2u

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

/* Stage kinds, in the only order a graph accepts them (the kernel's fixed lane order). */
typedef enum n60_stage_kind {
    N60_STAGE_SANITISE = 1,   /* NaN and Inf become 0; counted. No params. */
    N60_STAGE_METER_IN = 2,   /* peak and RMS per lane, audio untouched. No params. */
    N60_STAGE_GAIN = 3,       /* input gain x headroom. params[0] = linear gain, ramped over 5 ms. */
    N60_STAGE_MS_ENCODE = 4,  /* group stage on lanes (laneA, laneB): M = (A+B)/2, S = (A-B)/2. No params. */
    N60_STAGE_PEQ = 5,        /* up to 16 sections, double precision. params = 4 per section: type, Hz, dB, Q. */
    N60_STAGE_MS_DECODE = 6,  /* inverse of the matching encode on the same lanes: A = M+S, B = M-S. */
    N60_STAGE_METER_OUT = 7,  /* post-EQ meter, like METER_IN. */
    N60_STAGE_DELAY = 8       /* integer delay. params[0] = frames (0..capacityFrames); changes crossfade over 5 ms. */
} n60_stage_kind;

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
    uint32_t capacityFrames;  /* DELAY: largest delay this stage can ever be set to; otherwise 0 */
    const float *params;      /* initial parameter values (copied) */
    uint32_t paramCount;
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
 * Adoption starts the new snapshot from fresh state (filters, delays, meters, gain at
 * its target), so a topology change is not click-free; parameter edits that must be
 * smooth go through n60_graph_post_params. Parameter records posted before a publish
 * are dropped at adoption: repeat them in the new descriptor. */
n60_status n60_graph_publish(n60_graph *graph, const n60_graph_desc *desc);

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
 * Live parameters in S3: GAIN params[0] (linear, 0..10000) and DELAY params[0]
 * (frames, rounded, 0..capacityFrames). Anything else that needs a new topology
 * (PEQ, M/S, ...) returns N60_STATUS_UNSUPPORTED; publish a new snapshot instead.
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

/* Largest total delay in frames over the output lanes for the live graph (the sum
 * of that lane's DELAY stages; 0 with none). Updated by the realtime thread when
 * it adopts a snapshot or applies a delay parameter. */
uint32_t n60_graph_latency_frames(const n60_graph *graph);

#ifdef __cplusplus
}
#endif

#endif /* N60_GRAPH_H */
