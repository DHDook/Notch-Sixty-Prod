#include "N60GraphAudioUnitRack.h"

#include <stdatomic.h>
#include <stdlib.h>

struct N60GraphAudioUnitRack {
    N60AudioUnitLiveRackProcessor processor;
    float *scratch;
    n60_graph *boundGraph;
    _Atomic double blockSampleTime;
};

N60GraphAudioUnitRack *N60GraphAudioUnitRackCreate(const N60AudioUnitLiveRackProcessor *processor) {
    if (!N60AudioUnitLiveRackProcessorIsValid(processor)) return NULL;
    N60GraphAudioUnitRack *rack = (N60GraphAudioUnitRack *)calloc(1u, sizeof(N60GraphAudioUnitRack));
    if (rack == NULL) return NULL;
    rack->scratch = (float *)calloc((size_t)processor->maximumFramesPerSlice * processor->channelCount, sizeof(float));
    if (rack->scratch == NULL) {
        free(rack);
        return NULL;
    }
    rack->processor = *processor;
    atomic_init(&rack->blockSampleTime, 0.0);
    return rack;
}

void N60GraphAudioUnitRackDestroy(N60GraphAudioUnitRack *rack) {
    if (rack == NULL) return;
    N60GraphAudioUnitRackUnbind(rack);
    free(rack->scratch);
    free(rack);
}

uint32_t N60GraphAudioUnitRackChannelCount(const N60GraphAudioUnitRack *rack) {
    return rack != NULL ? rack->processor.channelCount : 0u;
}

uint32_t N60GraphAudioUnitRackMaximumFramesPerSlice(const N60GraphAudioUnitRack *rack) {
    return rack != NULL ? rack->processor.maximumFramesPerSlice : 0u;
}

uint64_t N60GraphAudioUnitRackLatencyFrames(const N60GraphAudioUnitRack *rack) {
    return rack != NULL ? rack->processor.latencyFrames : 0u;
}

bool N60GraphAudioUnitRackBind(N60GraphAudioUnitRack *rack, n60_graph *graph) {
    if (rack == NULL || graph == NULL) return false;
    if (rack->boundGraph == graph) return true;
    if (rack->boundGraph != NULL) N60GraphAudioUnitRackUnbind(rack);
    if (n60_graph_set_external_processor(graph, N60GraphAudioUnitRackProcess, rack, rack->processor.channelCount)
        != N60_STATUS_OK) {
        return false;
    }
    rack->boundGraph = graph;
    return true;
}

void N60GraphAudioUnitRackUnbind(N60GraphAudioUnitRack *rack) {
    if (rack == NULL || rack->boundGraph == NULL) return;
    (void)n60_graph_set_external_processor(rack->boundGraph, NULL, NULL, 0u);
    rack->boundGraph = NULL;
}

n60_graph *N60GraphAudioUnitRackBoundGraph(const N60GraphAudioUnitRack *rack) {
    return rack != NULL ? rack->boundGraph : NULL;
}

void N60GraphAudioUnitRackSetBlockSampleTime(N60GraphAudioUnitRack *rack, double sampleTime) {
    if (rack == NULL) return;
    atomic_store_explicit(&rack->blockSampleTime, sampleTime, memory_order_relaxed);
}

int N60GraphAudioUnitRackProcess(
    void *context,
    const float *const *in,
    float *const *out,
    uint32_t channels,
    uint32_t frames
) {
    N60GraphAudioUnitRack *rack = (N60GraphAudioUnitRack *)context;
    if (rack == NULL || in == NULL || out == NULL || channels != rack->processor.channelCount
        || !N60AudioUnitLiveRackProcessorIsValid(&rack->processor)) {
        return 0;
    }
    const uint32_t maxSlice = rack->processor.maximumFramesPerSlice;
    const double baseTime = atomic_load_explicit(&rack->blockSampleTime, memory_order_relaxed);
    float *const scratch = rack->scratch;
    for (uint32_t start = 0u; start < frames;) {
        uint32_t n = frames - start;
        if (n > maxSlice) n = maxSlice;
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            const float *lane = in[channel] + start;
            for (uint32_t i = 0u; i < n; ++i) scratch[(size_t)i * channels + channel] = lane[i];
        }
        if (!N60AudioUnitLiveRackProcess(&rack->processor, scratch, scratch, n, channels, baseTime + (double)start)) {
            return 0;
        }
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            float *lane = out[channel] + start;
            for (uint32_t i = 0u; i < n; ++i) lane[i] = scratch[(size_t)i * channels + channel];
        }
        start += n;
    }
    return 1;
}
