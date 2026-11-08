// libn60core ABI v23 image stages (E6 S12b): stereo mode and widener (N60_STAGE_IMAGE), de-harsh and de-esser
// (N60_STAGE_DEESS), ported from the stereo kernel's core dynamics frame (N60Dynamics.c).
// Declarations shared with snapshot.cpp, which owns the arena layout and the stage table.
#ifndef N60_CORE_STAGES_IMAGE_HPP
#define N60_CORE_STAGES_IMAGE_HPP

#include "snapshot.hpp"

namespace n60 {

bool isImageKind(uint32_t kind);

// Control thread. Checks lanes (a pair), parameter count and ranges.
n60_status validateImageStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Pure range check of one parameter for a kind, shared by build-time validation and live edits.
bool imageParamOk(uint32_t kind, uint32_t idx, float value, double sampleRate);

// Control thread. Bytes of per-lane state (0) and of stage-shared state.
void imageSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void imageInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the pair.
void runImage(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range check for one parameter (see validateParam).
n60_status validateImageParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Control thread. De-esser gain reduction (either lane of the pair; grMaxDb reset by the read).
bool readDeEss(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out);

}  // namespace n60

#endif
