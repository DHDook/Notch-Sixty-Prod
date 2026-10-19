// libn60core graph skeleton (E6 S2). Portable C++20: standard library only,
// no Apple framework. Compiled without exceptions or RTTI.
//
// Realtime documentation (docs/REALTIME_RULES.md):
//  - allocation: build allocates once (control thread); process allocates nothing.
//  - synchronisation: none in process; the graph is immutable after build.
//  - latency: 0 frames (no stages).
//  - sample rate: any rate in [8 kHz, 768 kHz]; unused by the pass-through.
//  - channels: 1..N60_GRAPH_MAX_CHANNELS in and out, independent.
//  - reset: nothing to reset; stages added later own their reset.
#include "n60/graph.h"

#include <cmath>
#include <cstddef>
#include <cstring>
#include <new>

struct n60_graph {
    n60_graph_desc desc;
};

namespace {

bool validChannels(uint32_t n) { return n >= 1 && n <= N60_GRAPH_MAX_CHANNELS; }

}  // namespace

extern "C" {

uint32_t n60_graph_abi_version(void) { return N60_GRAPH_ABI_VERSION; }

n60_status n60_graph_build(const n60_graph_desc *desc, n60_graph **outGraph) {
    if (outGraph == nullptr) return N60_STATUS_BAD_ARGUMENT;
    *outGraph = nullptr;
    if (desc == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (desc->abiVersion != N60_GRAPH_ABI_VERSION || desc->structSize != sizeof(n60_graph_desc)) {
        return N60_STATUS_ABI_MISMATCH;
    }
    if (!std::isfinite(desc->sampleRate) || desc->sampleRate < N60_GRAPH_MIN_SAMPLE_RATE ||
        desc->sampleRate > N60_GRAPH_MAX_SAMPLE_RATE) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (desc->maxBlockFrames < 1 || desc->maxBlockFrames > N60_GRAPH_MAX_BLOCK_FRAMES ||
        !validChannels(desc->inputChannels) || !validChannels(desc->outputChannels)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    n60_graph *graph = new (std::nothrow) n60_graph{*desc};
    if (graph == nullptr) return N60_STATUS_OUT_OF_MEMORY;
    *outGraph = graph;
    return N60_STATUS_OK;
}

n60_status n60_graph_process(n60_graph *graph, const float *const *in, float *const *out, uint32_t frames) {
    if (graph == nullptr || in == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (frames > graph->desc.maxBlockFrames) return N60_STATUS_BAD_ARGUMENT;
    if (frames == 0) return N60_STATUS_OK;
    const uint32_t inCount = graph->desc.inputChannels;
    const uint32_t outCount = graph->desc.outputChannels;
    const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
    for (uint32_t c = 0; c < outCount; ++c) {
        float *dst = out[c];
        if (dst == nullptr) return N60_STATUS_BAD_ARGUMENT;
        if (c < inCount) {
            const float *src = in[c];
            if (src == nullptr) return N60_STATUS_BAD_ARGUMENT;
            if (src != dst) std::memmove(dst, src, bytes);
        } else {
            std::memset(dst, 0, bytes);
        }
    }
    return N60_STATUS_OK;
}

n60_status n60_graph_post_params(n60_graph *graph, const n60_param_record *records, uint32_t count) {
    if (graph == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (count == 0) return N60_STATUS_OK;
    if (records == nullptr) return N60_STATUS_BAD_ARGUMENT;
    return N60_STATUS_UNSUPPORTED;
}

void n60_graph_retire(n60_graph *graph) { delete graph; }

uint32_t n60_graph_latency_frames(const n60_graph *graph) {
    (void)graph;  // no stages yet, so no latency
    return 0u;
}

}  // extern "C"
