// libn60core ABI v32 MIMO room treatment stage (E19 S4). Declarations shared with snapshot.cpp and graph.cpp, which own
// the arena layout, the stage table and the rebuild. The contract, parameter layout and realtime documentation are in
// n60/graph.h ("MIMO treatment"); the design maths are in n60/mimo.h.
#ifndef N60_CORE_STAGES_MIMO_HPP
#define N60_CORE_STAGES_MIMO_HPP

#include "snapshot.hpp"
#include "platform/rt.hpp"

namespace n60 {

bool isMimoKind(uint32_t kind) N60_RT_NONBLOCKING;

// Control thread. Checks lanes, parameter count and ranges.
n60_status validateMimoStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state (none) and of stage-shared state, from the validated parameters.
void mimoSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is built (arena zeroed, StageRec filled): resampler kernel, filter spectra, plan.
void mimoInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of its lanes.
void runMimo(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING;

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateMimoParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING;

// Frames of latency the stage adds to each of its lanes (L).
uint32_t mimoLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING;

// Realtime thread. A rebuild starts: every MIMO stage of `h` is held (its delta fades out in 10 ms and stays muted until
// the host disarms and re-arms). silentNow: the instance has never been audible, so the delta starts at zero. Returns the
// number of stages.
uint32_t mimoRebuildMute(SnapHeader *h, bool silentNow) N60_RT_NONBLOCKING;

// Control thread.
bool readMimo(SnapHeader *h, uint32_t stageId, n60_mimo_readback *out);

}  // namespace n60

#endif
