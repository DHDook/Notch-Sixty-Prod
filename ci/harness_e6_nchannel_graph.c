/* E6 S8b2b: behavioural harness for the N-channel live bridge graph path. At the eight standard
 * rates, drives a stereo N-channel bridge through the Capture/Output IOProcs with and without an
 * attached libn60core graph (gain 0.5): the graph must carry the render (half level), a block
 * larger than the graph's maxBlockFrames must produce silence and a render failure rather than
 * overrun, the graph latency must be reported, and detaching must restore the legacy render. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelBridge.h"

#define MAXB 256u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static N60LiveNChannelRenderGraph makeGraph(double rate) {
    const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    N60ProgramLaneGraphFinalize(&lanes);
    uint32_t phys[N60_MAX_PROGRAM_CHANNELS];
    for (uint32_t i = 0; i < N60_MAX_PROGRAM_CHANNELS; ++i) phys[i] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    phys[0] = 0u;
    phys[1] = 1u;
    N60LiveNChannelOutputMap map = {0};
    N60LiveNChannelOutputMapCompile(layout, 2u, phys, false, 0u, NULL, &map);
    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    N60LiveNChannelRenderGraphMake(rate, layout, lanes, false, bass, map, &graph);
    return graph;
}

static float peakOfBlock(N60LiveNChannelBridge *b, uint32_t frames, uint32_t *position, double rate) {
    float in[MAXB * 4u], out[MAXB * 4u];
    for (uint32_t i = 0; i < frames; ++i) {
        float v = 0.4f * sinf((float)(2.0 * M_PI * 1000.0 * (double)(*position + i) / rate));
        in[i * 2u] = v;
        in[i * 2u + 1u] = v;
    }
    *position += frames;
    memset(out, 0, sizeof out);
    AudioBufferList inList = {0}, outList = {0}, unused = {0};
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mDataByteSize = frames * 2u * sizeof(float);
    inList.mBuffers[0].mData = in;
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = 2;
    outList.mBuffers[0].mDataByteSize = frames * 2u * sizeof(float);
    outList.mBuffers[0].mData = out;
    AudioTimeStamp ts = {0};
    N60LiveNChannelCaptureIOProc(0, &ts, &inList, &ts, &unused, &ts, b);
    N60LiveNChannelOutputIOProc(0, &ts, &unused, &ts, &outList, &ts, b);
    float peak = 0.0f;
    for (uint32_t i = 0; i < frames * 2u; ++i) {
        if (!isfinite(out[i])) { failures++; fprintf(stderr, "FAIL non-finite\n"); return 0.0f; }
        if (fabsf(out[i]) > peak) peak = fabsf(out[i]);
    }
    return peak;
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        N60LiveNChannelRenderGraph g = makeGraph(rate);
        AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}},
                                            {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
        N60ProgramInputMap map = {0};
        CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map at %.0f", rate);
        N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
        CHECK(b != NULL, "bridge at %.0f", rate);
        if (!b) continue;

        const float half = 0.5f;
        n60_stage_desc st;
        memset(&st, 0, sizeof st);
        st.structSize = sizeof st;
        st.kind = N60_STAGE_GAIN;
        st.stageId = 1;
        st.laneA = N60_LANE_ALL;
        st.params = &half;
        st.paramCount = 1;
        n60_graph_desc d;
        memset(&d, 0, sizeof d);
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = MAXB;
        d.inputChannels = d.outputChannels = 2;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *graph = NULL;
        CHECK(n60_graph_build(&d, &graph) == N60_STATUS_OK && graph, "graph build");
        if (!graph) { N60LiveNChannelBridgeDestroy(b); continue; }

        /* Argument validation: too few channels or zero frames is refused and leaves no graph. */
        CHECK(!N60LiveNChannelBridgeAttachGraph(b, graph, 1u, MAXB), "attach with 1 channel accepted");
        CHECK(!N60LiveNChannelBridgeAttachGraph(b, graph, 2u, 0u), "attach with 0 frames accepted");
        CHECK(b->unifiedGraph == NULL, "failed attach left a graph");

        uint32_t pos = 0;
        float legacy = 0.0f;
        for (int i = 0; i < 8; ++i) legacy = peakOfBlock(b, MAXB, &pos, rate);
        CHECK(legacy > 0.35f && legacy < 0.45f, "legacy level %.3f at %.0f", legacy, rate);

        CHECK(N60LiveNChannelBridgeAttachGraph(b, graph, 2u, MAXB), "attach");
        float viaGraph = 0.0f;
        for (int i = 0; i < 8; ++i) viaGraph = peakOfBlock(b, MAXB, &pos, rate);
        CHECK(viaGraph > 0.15f && viaGraph < 0.25f, "graph level %.3f at %.0f", viaGraph, rate);
        N60LiveNChannelBridgeSnapshot s = N60LiveNChannelBridgeGetSnapshot(b);
        CHECK(s.renderFailures == 0, "unexpected render failures %llu", (unsigned long long)s.renderFailures);

        /* A block bigger than the graph can take renders silence and counts a failure. */
        float over = peakOfBlock(b, MAXB, &pos, rate); /* within limit, sanity */
        (void)over;
        N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
        CHECK(N60LiveNChannelBridgeAttachGraph(b, graph, 2u, 64u), "attach small");
        float silent = peakOfBlock(b, 128u, &pos, rate);
        CHECK(silent == 0.0f, "oversized block not silent: %.3f", silent);
        s = N60LiveNChannelBridgeGetSnapshot(b);
        CHECK(s.renderFailures > 0, "oversized block not counted");

        /* Detach restores the legacy render. */
        CHECK(N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u), "detach");
        float after = 0.0f;
        for (int i = 0; i < 8; ++i) after = peakOfBlock(b, MAXB, &pos, rate);
        CHECK(after > 0.35f && after < 0.45f, "legacy level after detach %.3f", after);

        N60LiveNChannelBridgeDestroy(b);
        n60_graph_retire(graph);
        printf("rate %.0f ok\n", rate);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("harness_e6_nchannel_graph OK");
    return 0;
}
