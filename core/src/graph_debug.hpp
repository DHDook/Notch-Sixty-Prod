// Test-only view of the graph host (E9 S2). Not part of the C ABI: the tests link libn60core and include this.
#ifndef N60_CORE_GRAPH_DEBUG_HPP
#define N60_CORE_GRAPH_DEBUG_HPP

#include <cstdint>

#include "n60/graph.h"

// Most bytes of bulk clearing and carry copying any one n60_graph_process call has done since build.
extern "C" uint64_t n60_graph_debug_peak_rt_bytes(const n60_graph *graph);

#endif
