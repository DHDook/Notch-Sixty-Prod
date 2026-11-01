#ifndef N60LevelSessionProc_h
#define N60LevelSessionProc_h

#include <stdbool.h>
#include <stdint.h>

#include "n60/measure.h"

#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* E24 S1: the Level step's and the Generator card's measurement-owned render path (design note 3). One IOProc on the
 * calibration aggregate renders a generator-only libn60core graph onto the chosen physical output channels and pushes
 * the microphone channel into an `n60_monitor_ring` that the SPL/RTA worker drains. The graph is built, and the ring
 * and context are allocated, off the realtime thread. The generator stage owns the clamp, the 100 ms ramps and the
 * auto-stop; this file adds none of that.
 *
 * Realtime: allocation none (scratch planes are allocated in Create); synchronisation: relaxed/acquire atomics and the
 * ring's wait-free push; latency: one callback; rates: any (the graph decides); channels: 1 to
 * N60_LEVEL_SESSION_MAX_LANES output lanes, one microphone channel; reset: the graph is rebuilt by the owner. */
#define N60_LEVEL_SESSION_MAX_LANES 32u

typedef struct N60LevelSessionContext N60LevelSessionContext;

typedef struct {
    uint64_t callbacks;
    uint64_t unsupportedBufferLayouts;
    uint64_t processFailures;
    uint64_t framesRendered;
    bool stopRequested;
    /* True once a whole block rendered after the stop request was silent. */
    bool rampDone;
    /* Largest absolute sample written in the most recent callback. */
    float lastPeak;
} N60LevelSessionSnapshot;

/* graph: an `n60_graph *` whose input and output channel counts both equal laneCount (inputs are fed silence). The
 * owner keeps the graph and the ring alive until the context is destroyed. outputChannels[lane] is the physical output
 * channel lane `lane` plays on. */
N60LevelSessionContext * _Nullable N60LevelSessionContextCreate(
    void * _Nonnull graph,
    n60_monitor_ring * _Nullable ring,
    uint32_t inputChannel,
    const uint32_t * _Nonnull outputChannels,
    uint32_t laneCount,
    uint32_t maxBlockFrames
);
void N60LevelSessionContextDestroy(N60LevelSessionContext * _Nullable context);
/* Control plane, before the IOProc starts: the microphone channel inside the (aggregate) input. */
void N60LevelSessionContextSetInputChannel(N60LevelSessionContext * _Nonnull context, uint32_t inputChannel);
/* Control plane, after posting the generator's active=0: tells the callback to watch for the ramp to reach silence. */
void N60LevelSessionContextRequestStop(N60LevelSessionContext * _Nonnull context);
N60LevelSessionSnapshot N60LevelSessionContextSnapshot(const N60LevelSessionContext * _Nonnull context);

/* Portable core of the callback. mic may be NULL. lanes[i] is the first sample of lane i's output channel and
 * strides[i] its interleave stride; a NULL lane is counted as an unsupported layout and skipped. Returns frames
 * rendered. */
uint32_t N60LevelSessionProcess(
    N60LevelSessionContext * _Nonnull context,
    const float * _Nullable mic,
    uint32_t micStride,
    float * _Nullable const * _Nonnull lanes,
    const uint32_t * _Nonnull strides,
    uint32_t frames
);

#if defined(__APPLE__)
OSStatus N60LevelSessionIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);
#endif

#ifdef __cplusplus
}
#endif

#endif
