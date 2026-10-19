// libn60core topology snapshot (E6 S3, design note section 2).
//
// One snapshot is one arena allocation made on the control thread: header, stage
// table, parameter blocks and per-stage state (filter memory, delay lines, meters)
// all addressed by 32-bit offsets from the header, so there are no pointers inside.
// After publication only the realtime thread touches the mutable parts (state and
// parameter targets); meters are atomics the control thread may read.
#ifndef N60_CORE_SNAPSHOT_HPP
#define N60_CORE_SNAPSHOT_HPP

#include <atomic>
#include <cstdint>

#include "n60/graph.h"

namespace n60 {

struct StageRec {
    uint32_t kind;
    uint32_t id;
    uint32_t laneA;
    uint32_t laneB;
    uint32_t laneFirst;  // first output lane the stage runs on
    uint32_t laneCount;  // lanes it runs on (1, or all output lanes)
    uint32_t paramCount;
    uint32_t paramsOff;  // float[paramCount], live targets
    uint32_t stateOff;   // laneCount records of stateStride bytes
    uint32_t stateStride;
    uint32_t capacity;   // DELAY: capacity in frames
    uint32_t coefOff;    // PEQ: double[sections][5] (b0 b1 b2 a1 a2)
    float applied;       // last target the state acted on (GAIN, DELAY)
    uint32_t pad;
};

struct SnapHeader {
    uint32_t abiVersion;
    uint32_t epoch;
    double sampleRate;
    uint32_t maxBlockFrames;
    uint32_t inputChannels;
    uint32_t outputChannels;
    uint32_t stageCount;
    uint32_t stageTableOff;
    uint32_t rampFrames;  // 5 ms, clamped to 32..4096 frames
    uint32_t rawPad;      // bytes from the raw allocation to this header
    uint32_t pad;
};

// Control thread. Validates the description (everything in n60_graph_desc) and builds
// the snapshot. Never touches live state.
n60_status buildSnapshot(const n60_graph_desc &desc, uint32_t epoch, SnapHeader **out);
n60_status validateDesc(const n60_graph_desc &desc);
void freeSnapshot(SnapHeader *snap);

// Realtime thread. Runs the stages in place on `lanes` (outputChannels pointers).
void runSnapshot(SnapHeader *snap, float *const *lanes, uint32_t frames,
                 std::atomic<uint64_t> &sanitisedSamples);

// Realtime thread. Applies one mailbox record; false when it no longer fits.
bool applyParam(SnapHeader *snap, uint32_t stageId, uint32_t paramIndex, float value);
uint32_t snapshotLatency(const SnapHeader *snap);

// Control thread (immutable fields only).
const StageRec *findStage(const SnapHeader *snap, uint32_t stageId);
bool readMeter(SnapHeader *snap, uint32_t stageId, uint32_t lane, float *peak, float *rms);

}  // namespace n60

#endif
