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
#include "jobs.hpp"
#include "platform/rt.hpp"
#include "platform/rt_libc.hpp"
#include "platform/rt_clock.hpp"

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
    uint32_t phase;      // E20 S5: 0 = runs on the calling thread; n > 0 = member of parallel phase n (consecutive stages with the same n)
    uint32_t carrySrc;   // ABI v20 (E9 S2): 1 + index of the stage in the outgoing snapshot a lazy FIR carry copies from (0 = none)
};

// ABI v13. The host callback of the EXTERNAL stage, owned by the graph handle (snapshots hold a pointer to it).
struct ExternalSlot {
    std::atomic<n60_external_process_fn> fn{nullptr};
    void *context = nullptr;      // written before fn is stored
    uint32_t channels = 0;
    float *delta = nullptr;       // channels * deltaStride floats: the processor's effect on the live block
    uint32_t deltaStride = 0;     // maxBlockFrames
    uint32_t deltaFrames = 0;     // realtime thread only: frames of valid delta this block (0 = none)
    std::atomic<uint64_t> calls{0};
    std::atomic<uint64_t> faults{0};
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
    uint32_t fadeLinear;  // E27 S3b: 1 = linear fade law (correlated old/new), 0 = equal-power
    uint32_t historyEpoch;  // ABI v10: bumped (realtime thread) to drop the FIR input history; lanes compare it
    uint32_t follower;      // ABI v13: realtime thread only; 1 while this snapshot is the incoming side of a rebuild
    uint32_t firScheme;     // ABI v20: 0 uniform FIR engine, 1 non-uniform (N60_FIR_SCHEME_*)
    uint32_t pad2;
    ExternalSlot *external; // ABI v13: the graph's EXTERNAL callback slot (set by the graph before publication)
    uint64_t *rtBudget;     // E9 S2: bytes of bulk clearing / copying left in this callback (the graph's; null = unlimited)
};

// PEQ parameters per section (type, Hz, dB, Q); the coefficient region holds one PeqSec per section.
constexpr uint32_t kPeqParamsPerSection = 4;

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
bool designBiquad(uint32_t type, double rate, double f, double gainDb, double q, double out[5]) N60_RT_NONBLOCKING;

// Control thread. Validates the description (everything in n60_graph_desc) and builds
// the snapshot. Never touches live state.
n60_status buildSnapshot(const n60_graph_desc &desc, uint32_t epoch, SnapHeader **out);
n60_status validateDesc(const n60_graph_desc &desc);
void freeSnapshot(SnapHeader *snap);

// Realtime thread. Runs the stages in place on `lanes` (outputChannels pointers).
// follower: the incoming side of a rebuild (see "External processor" in graph.h).
// jobs (E20 S5): when set and it has workers, phases of lane-independent stages run as one job per lane (jobs.hpp).
void runSnapshot(SnapHeader *snap, float *const *lanes, uint32_t frames,
                 std::atomic<uint64_t> &sanitisedSamples, bool follower = false, JobHost *jobs = nullptr) N60_RT_NONBLOCKING;

// Control or realtime thread (pure). Checks one live parameter edit against the stage's
// kind and ranges: OK, BAD_ARGUMENT (index or value out of range) or UNSUPPORTED (the
// parameter needs a new topology). Reads only immutable snapshot fields.
n60_status validateParam(const SnapHeader *snap, const StageRec &stage, uint32_t paramIndex, float value);

// Realtime thread. Applies one mailbox record; false when it no longer fits. Sets
// *latencyMayChange when the applied parameter can change the reported latency.
bool applyParam(SnapHeader *snap, uint32_t stageId, uint32_t paramIndex, float value, bool *latencyMayChange) N60_RT_NONBLOCKING;
uint32_t snapshotLatency(const SnapHeader *snap) N60_RT_NONBLOCKING;
// Frames of latency each of the N60_GRAPH_MAX_CHANNELS lanes has accumulated before stage index `upTo`.
void snapshotLaneLatency(const SnapHeader *snap, uint32_t upTo, uint32_t *perLane);

// Realtime thread (E9 S2c, closes G7; S2d, closes G9). The stages before index `i` of `to` are the same stages as in
// `from` (the caller has checked kind, id, lanes and parameters).
//
// upstreamStateCarriable: true when every stateful stage in [first, i) can be given the outgoing instance's running
// state, so a lazily carried FIR behind them sees the same input in both instances. Carried kinds: GAIN and
// OUTPUT_GAIN, PEQ (with its coefficient block), COMPRESSOR, CORE_DYNAMICS, EXPANDER, DYN_EQ, BASS_MGMT,
// STEREO_CROSSOVER, AMBIENT and CLEANUP (lanes plus shared block, copied whole; DELAY ranks after every FIR kind, so it is never upstream). Stateless kinds (sanitise,
// meters, M/S, analyser taps) need nothing. False for any other stateful kind (the denoiser included), for a stage
// whose bytes exceed `budget` together (`unbudgeted`: no limit), and for an upstream FIR unless firExact[j] says it was
// copied whole; the caller then does not run the FIR in lockstep and it warms in full. Pure: copies nothing.
bool upstreamStateCarriable(const SnapHeader *from, const SnapHeader *to, uint32_t i, uint64_t budget, bool unbudgeted,
                            uint32_t first, const uint8_t *firExact) N60_RT_NONBLOCKING;
// Copies that state (call only after upstreamStateCarriable). The bytes are deducted from `*budget` (saturating; null =
// unbudgeted). Stages before `first` are skipped (already copied for an earlier FIR). Returns the stages copied.
uint32_t carryUpstreamState(SnapHeader *from, SnapHeader *to, uint32_t i, uint64_t *budget, uint32_t first = 0) N60_RT_NONBLOCKING;

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
