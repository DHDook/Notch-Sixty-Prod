// libn60core ABI v17 speaker-routing stages (E8 S2): ROUTE (sparse routing matrix) and XOVER (per-way crossover,
// Linkwitz transform, EQ, trim and polarity). Declarations shared with snapshot.cpp, which owns the arena layout
// and the stage table. The contract, parameter layouts and realtime documentation are in n60/graph.h
// ("Speaker routing").
#ifndef N60_CORE_STAGES_ROUTE_HPP
#define N60_CORE_STAGES_ROUTE_HPP

#include "snapshot.hpp"

namespace n60 {

bool isRouteKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of a ROUTE or XOVER stage.
n60_status validateRouteStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state.
void routeSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled). Designs the initial filters.
void routeInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runRoute(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateRouteParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

}  // namespace n60

#endif
