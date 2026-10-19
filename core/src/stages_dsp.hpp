// libn60core ABI v3 stages (E6 S4): compressor, expander, dynamic EQ, spectral
// denoiser and program FIR. Declarations shared with snapshot.cpp, which owns the
// arena layout and the stage table.
#ifndef N60_CORE_STAGES_DSP_HPP
#define N60_CORE_STAGES_DSP_HPP

#include "snapshot.hpp"

namespace n60 {

bool isDspKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of one ABI v3 stage.
n60_status validateDspStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state.
void dspSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void dspInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runDsp(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateDspParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Frames of latency one lane of this stage adds.
uint32_t dspLatency(const SnapHeader *h, const StageRec &r);

}  // namespace n60

#endif
