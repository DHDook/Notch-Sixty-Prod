// libn60core ABI v6 matrix stage (E6 S7): the binaural renderer as a graph stage (N source lanes in,
// two ear lanes out). Declarations shared with snapshot.cpp, which owns the arena layout and the stage table.
#ifndef N60_CORE_STAGES_MATRIX_HPP
#define N60_CORE_STAGES_MATRIX_HPP

#include "snapshot.hpp"

namespace n60 {

bool isMatrixKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of a matrix stage.
n60_status validateMatrixStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state.
void matrixSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void matrixInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runMatrix(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateMatrixParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Frames of latency the stage adds between its source lanes and its ear lanes.
uint32_t matrixLatency(const SnapHeader *h, const StageRec &r);

}  // namespace n60

#endif
