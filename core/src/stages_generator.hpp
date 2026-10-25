// libn60core ABI v14 generator stage (E11 S7): a test-signal source in the graph chain. Declarations shared with
// snapshot.cpp, which owns the arena layout and the stage table.
#ifndef N60_CORE_STAGES_GENERATOR_HPP
#define N60_CORE_STAGES_GENERATOR_HPP

#include "snapshot.hpp"

namespace n60 {

bool isGeneratorKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of a generator stage.
n60_status validateGeneratorStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state.
void generatorSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled). Builds the noise table.
void generatorInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runGenerator(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateGeneratorParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

}  // namespace n60

#endif
