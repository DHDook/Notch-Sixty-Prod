/* E8 S4: behavioural harness for the routed N-channel output map. At the eight standard rates it drives a stereo
 * program through a graph with a ROUTE stage onto 8 output lanes (2 program + 8 output = 10 graph channels) and a
 * 12-channel physical output where output lane k lands on physical channel 11 - k. Each physical channel must carry
 * its lane's source scaled by its gain, the program lanes must not leak to the device, an invalid routed map must be
 * refused, a routed map with no graph attached must render silence, and the map accepts 64 physical channels. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelBridge.h"

#define MAXB 256u
#define OUTS 8u
#define PHYS 12u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static N60LiveNChannelRenderGraph makeGraph(double rate, bool *ok) {
    const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    N60ProgramLaneGraphFinalize(&lanes);
    uint32_t routed[OUTS];
    for (uint32_t k = 0; k < OUTS; ++k) routed[k] = PHYS - 1u - k;
    N60LiveNChannelOutputMap map = {0};
    *ok = N60LiveNChannelOutputMapCompileRouted(layout, PHYS, OUTS, routed, &map);
    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    *ok = *ok && N60LiveNChannelRenderGraphMake(rate, layout, lanes, false, bass, map, &graph);
    return graph;
}

static n60_graph *makeRouteGraph(double rate) {
    float params[OUTS * N60_ROUTE_PARAMS_PER_DEST];
    uint64_t mask = 0;
    for (uint32_t k = 0; k < OUTS; ++k) {
        float *p = params + k * N60_ROUTE_PARAMS_PER_DEST;
        for (uint32_t e = 0; e < N60_ROUTE_MAX_ENTRIES; ++e) { p[e * 2u] = -1.0f; p[e * 2u + 1u] = 0.0f; }
        p[0] = (float)(k % 2u);
        p[1] = 0.1f * (float)(k + 1u);
        mask |= (uint64_t)1 << (2u + k);
    }
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_ROUTE;
    st.stageId = 1;
    st.laneMask = mask;
    st.params = params;
    st.paramCount = OUTS * N60_ROUTE_PARAMS_PER_DEST;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = MAXB;
    d.inputChannels = d.outputChannels = 2u + OUTS;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *graph = NULL;
    if (n60_graph_build(&d, &graph) != N60_STATUS_OK) return NULL;
    return graph;
}

static void block(N60LiveNChannelBridge *b, uint32_t frames, uint32_t *position, double rate, float peaks[PHYS]) {
    float in[MAXB * 2u], out[MAXB * PHYS];
    for (uint32_t i = 0; i < frames; ++i) {
        const float v = sinf((float)(2.0 * M_PI * 1000.0 * (double)(*position + i) / rate));
        in[i * 2u] = 0.4f * v;
        in[i * 2u + 1u] = 0.2f * v;
    }
    *position += frames;
    memset(out, 0, sizeof out);
    AudioBufferList inList = {0}, outList = {0}, unused = {0};
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mDataByteSize = frames * 2u * sizeof(float);
    inList.mBuffers[0].mData = in;
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = PHYS;
    outList.mBuffers[0].mDataByteSize = frames * PHYS * sizeof(float);
    outList.mBuffers[0].mData = out;
    AudioTimeStamp ts = {0};
    N60LiveNChannelCaptureIOProc(0, &ts, &inList, &ts, &unused, &ts, b);
    N60LiveNChannelOutputIOProc(0, &ts, &unused, &ts, &outList, &ts, b);
    for (uint32_t c = 0; c < PHYS; ++c) peaks[c] = 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t c = 0; c < PHYS; ++c) {
            const float v = out[i * PHYS + c];
            if (!isfinite(v)) { failures++; fprintf(stderr, "FAIL non-finite\n"); return; }
            if (fabsf(v) > peaks[c]) peaks[c] = fabsf(v);
        }
    }
}

int main(void) {
    /* Map validation, rate independent. */
    {
        const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
        uint32_t good[64], dup[2] = {3u, 3u}, high[2] = {0u, 12u};
        for (uint32_t i = 0; i < 64u; ++i) good[i] = 63u - i;
        N60LiveNChannelOutputMap m = {0};
        CHECK(N60LiveNChannelOutputMapCompileRouted(layout, 64u, 64u, good, &m), "64 physical channels refused");
        CHECK(N60LiveNChannelOutputMapIsValid(&m), "64-channel routed map not valid");
        CHECK(!N60LiveNChannelOutputMapCompileRouted(layout, 65u, 2u, dup, &m), "65 channels accepted");
        CHECK(!N60LiveNChannelOutputMapCompileRouted(layout, 12u, 2u, dup, &m), "duplicate channel accepted");
        CHECK(!N60LiveNChannelOutputMapCompileRouted(layout, 12u, 2u, high, &m), "out of range channel accepted");
        CHECK(!N60LiveNChannelOutputMapCompileRouted(layout, 12u, 0u, good, &m), "zero lanes accepted");
        /* The legacy compile keeps its 40 channel ceiling. */
        uint32_t phys[N60_MAX_PROGRAM_CHANNELS];
        for (uint32_t i = 0; i < N60_MAX_PROGRAM_CHANNELS; ++i) phys[i] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
        phys[0] = 0u;
        phys[1] = 41u;
        CHECK(!N60LiveNChannelOutputMapCompile(layout, 42u, phys, false, 0u, NULL, &m), "legacy map accepted 42");
    }
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        bool ok = false;
        N60LiveNChannelRenderGraph g = makeGraph(rate, &ok);
        CHECK(ok, "routed render graph at %.0f", rate);
        if (!ok) continue;
        AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}},
                                            {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
        N60ProgramInputMap map = {0};
        CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map at %.0f", rate);
        N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
        CHECK(b != NULL, "bridge at %.0f", rate);
        if (!b) continue;
        n60_graph *graph = makeRouteGraph(rate);
        CHECK(graph != NULL, "graph build at %.0f", rate);
        if (!graph) { N60LiveNChannelBridgeDestroy(b); continue; }

        uint32_t pos = 0;
        float peaks[PHYS];
        /* No graph: silence on every channel (never an unmapped legacy render). */
        for (int i = 0; i < 4; ++i) block(b, MAXB, &pos, rate, peaks);
        for (uint32_t c = 0; c < PHYS; ++c) CHECK(peaks[c] == 0.0f, "no-graph output on channel %u", c);

        /* Too few graph channels for the routed lanes is refused. */
        CHECK(!N60LiveNChannelBridgeAttachGraph(b, graph, 2u + OUTS - 1u, MAXB), "short routed attach accepted");
        CHECK(N60LiveNChannelBridgeAttachGraph(b, graph, 2u + OUTS, MAXB), "attach");
        for (int i = 0; i < 12; ++i) block(b, MAXB, &pos, rate, peaks);
        for (uint32_t k = 0; k < OUTS; ++k) {
            const float src = (k % 2u) == 0u ? 0.4f : 0.2f;
            const float expected = src * 0.1f * (float)(k + 1u);
            const float got = peaks[PHYS - 1u - k];
            CHECK(fabsf(got - expected) < 0.02f * expected + 1e-4f,
                  "lane %u on channel %u: %.4f expected %.4f at %.0f", k, PHYS - 1u - k, got, expected, rate);
        }
        for (uint32_t c = 0; c < PHYS - OUTS; ++c) CHECK(peaks[c] == 0.0f, "leak on unrouted channel %u", c);
        N60LiveNChannelBridgeSnapshot s = N60LiveNChannelBridgeGetSnapshot(b);
        CHECK(s.renderFailures > 0u, "no-graph blocks not counted as failures");

        N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
        N60LiveNChannelBridgeDestroy(b);
        n60_graph_retire(graph);
        printf("rate %.0f ok\n", rate);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("harness_e8_routed_output OK");
    return 0;
}
