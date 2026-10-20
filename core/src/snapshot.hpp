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
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "n60/graph.h"

namespace n60 {

struct StageRec {
    uint64_t laneMask;   // ABI v3 lane set (0 = laneA / laneFirst + laneCount)
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
    uint32_t coefOff;    // PEQ: PeqSec[sections] (live and incoming biquad coefficients, crossfade counter)
    uint32_t sharedOff;  // ABI v3 stages: state shared by all of the stage's lanes
    float applied;       // last target the state acted on (GAIN, DELAY)
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
    uint32_t parkFftSize;   // ABI v9: the kernel denoiser's view while it is off (0 = not tracked)
    uint32_t parkRevision;
    uint32_t parkCommand;
    uint32_t fadeFrames;  // rebuild crossfade length when this snapshot is adopted (0 = instant swap)
    uint32_t historyEpoch;  // ABI v10: bumped (realtime thread) to drop the FIR input history; lanes compare it
};

inline uint8_t *bytes(SnapHeader *h) { return reinterpret_cast<uint8_t *>(h); }
inline const uint8_t *bytes(const SnapHeader *h) { return reinterpret_cast<const uint8_t *>(h); }
inline StageRec *stages(SnapHeader *h) { return reinterpret_cast<StageRec *>(bytes(h) + h->stageTableOff); }
inline const StageRec *stages(const SnapHeader *h) {
    return reinterpret_cast<const StageRec *>(bytes(h) + h->stageTableOff);
}
inline float *paramsOf(SnapHeader *h, const StageRec &s) { return reinterpret_cast<float *>(bytes(h) + s.paramsOff); }
inline const float *paramsOf(const SnapHeader *h, const StageRec &s) {
    return reinterpret_cast<const float *>(bytes(h) + s.paramsOff);
}
inline uint8_t *laneState(SnapHeader *h, const StageRec &s, uint32_t laneIndex) {
    return bytes(h) + s.stateOff + size_t(laneIndex) * s.stateStride;
}
inline uint8_t *sharedState(SnapHeader *h, const StageRec &s) { return bytes(h) + s.sharedOff; }

// The k-th output lane of a stage.
inline uint32_t laneOf(const StageRec &r, uint32_t k) {
    if (r.laneMask == 0) return r.laneFirst + k;
    uint64_t m = r.laneMask;
    while (k-- != 0) m &= m - 1;
    return static_cast<uint32_t>(std::countr_zero(m));
}

// RBJ Audio EQ Cookbook biquad, normalised by a0 (b0 b1 b2 a1 a2), double precision.
bool designBiquad(uint32_t type, double rate, double f, double gainDb, double q, double out[5]);

// Control thread. Validates the description (everything in n60_graph_desc) and builds
// the snapshot. Never touches live state.
n60_status buildSnapshot(const n60_graph_desc &desc, uint32_t epoch, SnapHeader **out);
n60_status validateDesc(const n60_graph_desc &desc);
void freeSnapshot(SnapHeader *snap);

// Realtime thread. Runs the stages in place on `lanes` (outputChannels pointers).
void runSnapshot(SnapHeader *snap, float *const *lanes, uint32_t frames,
                 std::atomic<uint64_t> &sanitisedSamples);

// Control or realtime thread (pure). Checks one live parameter edit against the stage's
// kind and ranges: OK, BAD_ARGUMENT (index or value out of range) or UNSUPPORTED (the
// parameter needs a new topology). Reads only immutable snapshot fields.
n60_status validateParam(const SnapHeader *snap, const StageRec &stage, uint32_t paramIndex, float value);

// Realtime thread. Applies one mailbox record; false when it no longer fits. Sets
// *latencyMayChange when the applied parameter can change the reported latency.
bool applyParam(SnapHeader *snap, uint32_t stageId, uint32_t paramIndex, float value, bool *latencyMayChange);
uint32_t snapshotLatency(const SnapHeader *snap);

// Control thread (immutable fields only).
const StageRec *findStage(const SnapHeader *snap, uint32_t stageId);
bool readMeter(SnapHeader *snap, uint32_t stageId, uint32_t lane, float *peak, float *rms);
// ABI v8 (E6 S8c). Control thread: over-range count of a meter stage lane (reset by the read), and the
// dynamics readback of a compressor, expander or protection stage lane (grMaxDb, peaks reset by the read).
bool readOverRange(SnapHeader *snap, uint32_t stageId, uint32_t lane, uint64_t *count);
bool readDynamics(SnapHeader *snap, uint32_t stageId, uint32_t lane, n60_dynamics_readback *out);

// Non-negative floats order like their bit patterns, so a peak-hold is an atomic max on the bits. The realtime
// thread raises it; the control thread resets it with exchange(0). Wait-free on the realtime side apart from
// the (bounded, lock-free) compare-exchange retry against the one reader.
inline uint32_t floatToBits(float v) {
    uint32_t b;
    std::memcpy(&b, &v, sizeof b);
    return b;
}
inline float bitsToFloat(uint32_t b) {
    float v;
    std::memcpy(&v, &b, sizeof v);
    return v;
}
inline void atomicMaxFloat(std::atomic<uint32_t> &a, float v) {
    const uint32_t nb = floatToBits(v);
    uint32_t seen = a.load(std::memory_order_relaxed);
    while (nb > seen && !a.compare_exchange_weak(seen, nb, std::memory_order_relaxed)) {
    }
}

}  // namespace n60

#endif
