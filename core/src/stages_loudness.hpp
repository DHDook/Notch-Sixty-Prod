// libn60core ABI v24 loudness stage (E6 S12c): loudness match, loudness contour (simple and per-band) and the dialogue
// leveler (N60_STAGE_LOUDNESS), ported from the stereo kernel's core dynamics frame (N60Dynamics.c).
// Declarations shared with snapshot.cpp and graph.cpp, which own the arena layout, the stage table and the readback API.
#ifndef N60_CORE_STAGES_LOUDNESS_HPP
#define N60_CORE_STAGES_LOUDNESS_HPP

#include "snapshot.hpp"
#include "platform/rt.hpp"

namespace n60 {

bool isLoudnessKind(uint32_t kind) N60_RT_NONBLOCKING;

// Control thread. Checks lanes (a pair), parameter count and ranges.
n60_status validateLoudnessStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Pure range check of one parameter, shared by build-time validation and live edits.
bool loudnessParamOk(const float *params, uint32_t idx, float value, double sampleRate);

// Control thread. Bytes of per-lane state (0) and of stage-shared state.
void loudnessSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void loudnessInit(SnapHeader *h, const StageRec &r);

// Realtime thread, at adopt (E6 S12h, G16): a LOUDNESS stage of `to` starts from the running state of the stage with the
// same id in `from`: K-weighting and contour and leveler filter state, the loudness mean square, the match gain, the contour
// mix and gains, the leveler envelopes and boost, and the parked flags. Coefficients and parameters stay the new snapshot's
// own. Bounded copy, no allocation. Returns the bytes copied, for the caller to charge to the callback budget (G38).
uint64_t loudnessCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING;

// Realtime thread. Runs the stage in place over `frames` frames of the pair.
void runLoudness(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING;

// Pure range check for one parameter (see validateParam).
n60_status validateLoudnessParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING;

// Control thread. The stage's telemetry as of the end of the last rendered block.
bool readLoudness(const SnapHeader *h, uint32_t stageId, n60_loudness_readback *out);

}  // namespace n60

#endif
