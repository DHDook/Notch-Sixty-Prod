// libn60core ABI v25 multiband compressor stage (E6 S12d): the stereo kernel's three-band compressor
// (N60_STAGE_MULTIBAND), ported from N60Dynamics.c (process_multiband_compressor).
// Declarations shared with snapshot.cpp and graph.cpp, which own the arena layout, the stage table and the readback API.
#ifndef N60_CORE_STAGES_MULTIBAND_HPP
#define N60_CORE_STAGES_MULTIBAND_HPP

#include "snapshot.hpp"

namespace n60 {

bool isMultibandKind(uint32_t kind);

// Control thread. Checks lanes (a pair), parameter count and ranges.
n60_status validateMultibandStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Pure range check of one parameter, shared by build-time validation and live edits.
bool multibandParamOk(uint32_t idx, float value, double sampleRate);

// Control thread. Bytes of per-lane state (0) and of stage-shared state.
void multibandSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void multibandInit(SnapHeader *h, const StageRec &r);

// Realtime thread, at adopt (E6 S12h, G21): a MULTIBAND stage of `to` starts from the running state of the stage with the
// same id in `from`: the crossover and band high-pass filter state, the three band gain smoothers and the parked flag.
// Coefficients stay the new snapshot's own. Bounded copy, no allocation. Returns the bytes copied, for the caller to
// charge to the callback budget (G38).
uint64_t multibandCarry(SnapHeader *from, SnapHeader *to);

// Realtime thread. Runs the stage in place over `frames` frames of the pair.
void runMultiband(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Live-edit check for one parameter (see validateParam): the two slopes are topology and are not live.
n60_status validateMultibandParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Control thread. Band gain reduction (grMaxDb reset by the read).
bool readMultiband(const SnapHeader *h, uint32_t stageId, n60_multiband_readback *out);

}  // namespace n60

#endif
