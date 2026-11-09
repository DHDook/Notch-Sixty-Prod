// libn60core ABI v22 cleanup stage (E6 S12a): DC offset filter, infrasonic high-pass cascade, mains hum notch
// (with the retune crossfade) and mains hum detector, ported from the stereo kernel's pre-EQ block (N60Dynamics.c).
// Declarations shared with snapshot.cpp, which owns the arena layout and the stage table.
#ifndef N60_CORE_STAGES_CLEANUP_HPP
#define N60_CORE_STAGES_CLEANUP_HPP

#include "snapshot.hpp"

namespace n60 {

bool isCleanupKind(uint32_t kind);

// Control thread. Checks lanes (a pair), parameter count and ranges of a cleanup stage.
n60_status validateCleanupStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state (0) and of stage-shared state.
void cleanupSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void cleanupInit(SnapHeader *h, const StageRec &r);

// Realtime thread, at adopt (E6 S12f2, G7): a cleanup stage of `to` starts from the running state of the stage with the
// same id in `from`: DC, infrasonic and notch filter state, the mix fades (including one in flight), the retune
// crossfade and the hum detector window. Coefficients stay the new snapshot's own. Bounded copies, no allocation.
// Returns the bytes of running state it copied, for the caller to charge to the callback budget (G38).
uint64_t cleanupCarry(SnapHeader *from, SnapHeader *to);

// Realtime thread. Runs the stage in place over `frames` frames of the pair.
void runCleanup(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range check for one parameter (see validateParam).
n60_status validateCleanupParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Control thread. Detector telemetry of the newest snapshot (relaxed atomics written by the realtime thread).
bool readMains(const SnapHeader *h, uint32_t stageId, n60_mains_readback *out);

}  // namespace n60

#endif
