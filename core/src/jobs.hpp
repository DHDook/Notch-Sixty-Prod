// libn60core parallel render jobs (E20 S5, design note 8). Header-only; the stage knowledge lives in snapshot.cpp.
//
// Realtime documentation (AGENTS.md section 4):
//  - allocation: none on the realtime path. The per-thread FFT scratch is allocated with the graph handle.
//  - synchronisation: one 64-bit claim word (generation | next job | job count) advanced by compare-and-swap, one
//    completion counter, atomics only. A phase descriptor is written by the calling thread before the claim word is
//    published (release) and read by a worker only after it wins a claim (acquire); a phase cannot end while one of its
//    jobs is unclaimed or running, so the descriptor is stable for every reader. The caller never waits for a job nobody
//    has claimed, so an absent or slow-to-wake worker cannot deadlock it.
//  - latency: none added; a phase finishes inside the callback.
//  - sample rate / channels: any; one job per output lane of the phase, at most 64.
//  - reset: nothing to reset; a new snapshot brings its own phases.
#ifndef N60_CORE_JOBS_HPP
#define N60_CORE_JOBS_HPP

#include <atomic>
#include <cstdint>

#include "n60/graph.h"
#include "platform/rt.hpp"

namespace n60 {

struct SnapHeader;

constexpr uint32_t kMaxPhaseStages = 8;

// One published phase: stages [first, first + count) of the snapshot, run lane by lane.
struct PhaseDesc {
    SnapHeader *snap;
    float *const *lanes;
    uint32_t frames;
    uint32_t first;
    uint32_t count;
    uint64_t laneUnion;                // output lanes any stage of the phase touches; job j is the j-th set bit
    uint64_t skip[kMaxPhaseStages];    // per stage, bit k: lane k of the stage is still clearing its history (silent)
};

struct JobHost {
    // Control writes, realtime reads.
    std::atomic<uint32_t> workers{0};
    std::atomic<n60_graph_wake_fn> wake{nullptr};
    void *wakeContext = nullptr;  // written before `wake` is stored
    // Realtime and worker threads.
    std::atomic<uint32_t> active{0};  // 1 while a callback is rendering and workers may claim
    alignas(64) std::atomic<uint64_t> claim{0};  // generation << 32 | next job << 16 | job count
    alignas(64) std::atomic<uint32_t> done{0};
    alignas(64) PhaseDesc phase{};
    // Calling thread only.
    uint32_t generation = 0;
    bool woken = false;
    // Per-thread FFT scratch, slot 0 is the calling thread. Allocated by the graph.
    uint8_t *scratchBase = nullptr;
    uint8_t *scratch[N60_GRAPH_MAX_WORKERS + 1] = {};
    // Counters.
    std::atomic<uint64_t> parallelPhases{0}, jobsOnWorkers{0}, jobsOnCaller{0}, lateJoins{0}, wakes{0};
};

// Calling thread. Ends the callback: workers stop claiming. Cheap when nothing woke them.
void jobHostEnd(JobHost &j) N60_RT_NONBLOCKING;
// Worker thread. Claims and runs jobs of the current phase while a callback is active; returns jobs run.
uint32_t jobHostWorkerRun(JobHost &j, uint32_t workerIndex) N60_RT_NONBLOCKING;

}  // namespace n60

#endif
