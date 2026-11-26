#ifndef N60GraphAudioUnitRack_h
#define N60GraphAudioUnitRack_h

// E23 K1c: the N-lane host adapter that lets the unified graph's EXTERNAL stage call the Audio Unit rack.
//
// This is macOS backend glue (the rack is an AU render block), so it lives here and not in core/ or Realtime/.
// The graph hands the callback planar lanes; the rack wants interleaved frames in slices of at most its
// maximumFramesPerSlice. The adapter interleaves, runs the rack slice by slice and writes the result back.
//
// Realtime contract (AGENTS.md 4):
//   Allocation: none in N60GraphAudioUnitRackProcess; Create and Destroy allocate and run on the control thread.
//   Synchronisation: no locks. Bind and Unbind run on the control thread with IO stopped (or the callback cleared
//     first). The block sample time is a relaxed atomic written by the IO thread before the graph renders.
//   Latency: the rack's own reported latency, declared once on the graph's EXTERNAL stage (the caller reads it
//     from N60GraphAudioUnitRackLatencyFrames; nothing else adds it).
//   Sample rate: agnostic; the rack was prepared for the device rate by the session.
//   Channels: 1 to 32 (the rack's own limit, under N60_GRAPH_MAX_CHANNELS), equal to the EXTERNAL stage's lane count.
//   Reset: the graph calls the callback only for the live snapshot, so a rebuild or fade-in never reaches the rack
//     with stale state; a rack failure returns 0 so the graph silences that block and counts a fault; the next block calls the
//     rack again with no adapter state to recover.

#include <stdbool.h>
#include <stdint.h>

#include "../Realtime/N60AudioUnitLiveRackBridge.h"
#include "n60/graph.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct N60GraphAudioUnitRack N60GraphAudioUnitRack;

/// Control thread. Copies `processor` and allocates the interleaved scratch (maximumFramesPerSlice x channels).
/// NULL when the processor is invalid.
N60GraphAudioUnitRack * _Nullable N60GraphAudioUnitRackCreate(const N60AudioUnitLiveRackProcessor * _Nonnull processor);

/// Control thread. Clears a still-bound graph callback first, then frees.
void N60GraphAudioUnitRackDestroy(N60GraphAudioUnitRack * _Nullable rack);

uint32_t N60GraphAudioUnitRackChannelCount(const N60GraphAudioUnitRack * _Nullable rack);
uint32_t N60GraphAudioUnitRackMaximumFramesPerSlice(const N60GraphAudioUnitRack * _Nullable rack);
uint64_t N60GraphAudioUnitRackLatencyFrames(const N60GraphAudioUnitRack * _Nullable rack);

/// Control thread, IO stopped. Registers the adapter as the graph's EXTERNAL-stage callback over
/// `N60GraphAudioUnitRackChannelCount(rack)` lanes. Binding the same graph again is a no-op that succeeds.
bool N60GraphAudioUnitRackBind(N60GraphAudioUnitRack * _Nullable rack, n60_graph * _Nullable graph);

/// Control thread. Clears the callback if this adapter is bound. Safe to call when not bound.
void N60GraphAudioUnitRackUnbind(N60GraphAudioUnitRack * _Nullable rack);

/// The graph the adapter is bound to, or NULL.
n60_graph * _Nullable N60GraphAudioUnitRackBoundGraph(const N60GraphAudioUnitRack * _Nullable rack);

/// IO thread, before n60_graph_process: the host sample time of the first frame of the block.
void N60GraphAudioUnitRackSetBlockSampleTime(N60GraphAudioUnitRack * _Nullable rack, double sampleTime);

/// n60_external_process_fn. Realtime thread, inside n60_graph_process. `context` is the adapter. Processes the lanes
/// in place (in and out may be the same pointers) and returns 0 on any rack failure.
int N60GraphAudioUnitRackProcess(
    void *context,
    const float * _Nonnull const * _Nonnull in,
    float * _Nonnull const * _Nonnull out,
    uint32_t channels,
    uint32_t frames
);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
