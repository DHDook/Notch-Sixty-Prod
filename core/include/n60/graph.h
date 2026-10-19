/*
 * libn60core: versioned C interface to the unified N-channel graph (E6 S2, E21).
 *
 * Plain C types only, opaque handles, explicit struct sizes and an ABI version,
 * so the macOS Swift shell, a Linux test host and any future shell call the same
 * entry points. No Apple type appears here or anywhere in the core.
 *
 * Threading: build, retire and post_params belong to the control thread.
 * process is the only call made from the realtime thread. It never allocates,
 * locks, throws or logs. Buffers are planar (non-interleaved) 32-bit float, one
 * pointer per channel, processed a whole block at a time.
 *
 * S2 skeleton: the graph has no stages and passes audio through. Latency is 0.
 */
#ifndef N60_GRAPH_H
#define N60_GRAPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any incompatible change to a struct or function below. */
#define N60_GRAPH_ABI_VERSION 1u

typedef struct n60_graph n60_graph; /* opaque */

typedef enum n60_status {
    N60_STATUS_OK = 0,
    N60_STATUS_ABI_MISMATCH = 1, /* desc.abiVersion or desc.structSize is not what this library supports */
    N60_STATUS_BAD_ARGUMENT = 2, /* null pointer, zero or out-of-range size, frames > maxBlockFrames */
    N60_STATUS_OUT_OF_MEMORY = 3,
    N60_STATUS_UNSUPPORTED = 4   /* valid request this build cannot honour yet (no such stage) */
} n60_status;

/* Limits accepted by n60_graph_build. */
#define N60_GRAPH_MAX_CHANNELS 64u
#define N60_GRAPH_MAX_BLOCK_FRAMES (1u << 20)
#define N60_GRAPH_MIN_SAMPLE_RATE 8000.0
#define N60_GRAPH_MAX_SAMPLE_RATE 768000.0

typedef struct n60_graph_desc {
    uint32_t structSize;      /* sizeof(n60_graph_desc) as seen by the caller */
    uint32_t abiVersion;      /* N60_GRAPH_ABI_VERSION as seen by the caller */
    double sampleRate;        /* Hz, native device rate; no resampling inside the graph */
    uint32_t maxBlockFrames;  /* process accepts any block from 1 to this */
    uint32_t inputChannels;
    uint32_t outputChannels;
} n60_graph_desc;

/* One parameter target for a stage (latest wins, coalesced at block start). */
typedef struct n60_param_record {
    uint32_t stageId;
    uint32_t paramIndex;
    float value;
    uint32_t reserved; /* must be 0 */
} n60_param_record;

/* ABI version of the loaded library; compare with N60_GRAPH_ABI_VERSION. */
uint32_t n60_graph_abi_version(void);

/* Control thread. Allocates everything the graph will ever need. On success
 * *outGraph owns it; on failure *outGraph is NULL (when outGraph itself is valid). */
n60_status n60_graph_build(const n60_graph_desc *desc, n60_graph **outGraph);

/* Realtime thread. in[c] / out[c] each point at `frames` floats; in has
 * inputChannels entries and out has outputChannels entries. In-place use (in[c]
 * == out[c]) is allowed. frames == 0 is a no-op. Pass-through copies channel c to
 * channel c; output channels with no input are written with silence. Buffers of
 * different channels must not overlap. Callers must not pass NULL pointers. */
n60_status n60_graph_process(n60_graph *graph, const float *const *in, float *const *out, uint32_t frames);

/* Control thread. Posts parameter targets for the live graph. The skeleton has no
 * stages, so any non-empty batch returns N60_STATUS_UNSUPPORTED and applies nothing. */
n60_status n60_graph_post_params(n60_graph *graph, const n60_param_record *records, uint32_t count);

/* Control thread. Frees the graph, only after the realtime thread has stopped
 * using it (E6 S3 adds the epoch acknowledgement). NULL is allowed. */
void n60_graph_retire(n60_graph *graph);

/* Total latency in frames from input to output for the live graph (0 here). */
uint32_t n60_graph_latency_frames(const n60_graph *graph);

#ifdef __cplusplus
}
#endif

#endif /* N60_GRAPH_H */
