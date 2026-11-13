/* E28 S6b and S9: behavioural harness for the loudness capture ring and the paired stereo over-range counts.
 *  - ring: demand-gated; frames round-trip exactly; a full ring drops and counts new frames and never overwrites unread
 *    ones; Discard empties it; a producer thread and a consumer thread stay contiguous (SPSC);
 *  - N-channel bridge (stereo layout) at the eight standard rates: Input is the dequeued program, Output is the rendered
 *    signal (0.5 gain graph halves it), nothing is captured while demand is off, Reset clears demand;
 *  - subwoofer feeds (E9 S10): one legacy sub and five graph subs append Output channels after the program roles, carry
 *    the generated sub-lane signal (and only it), leave the program roles untouched; the program count plus the feeds
 *    caps at the ring's output ceiling;
 *  - routed N-channel bridge (S9): lanes that name a program role sum into that role's Output channel (two ways of one
 *    speaker add), and a routed map with no such lane has no Output ring;
 *  - stereo bridge: an over-range on L only counts on the left, R only on the right, and the total is their sum. */
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelBridge.h"
#include "N60RealtimeAudioBridge.h"

#define MAXB 256u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

/* ---- ring ---- */

static void ringBasics(double rate) {
    N60LoudnessCapture *c = N60LoudnessCaptureCreate(3u, 2u, rate);
    CHECK(c != NULL, "create at %.0f", rate);
    if (c == NULL) return;
    CHECK(c->capacityFrames >= (uint32_t)(rate * 0.25), "capacity %u too small for 250 ms at %.0f", c->capacityFrames, rate);
    CHECK(N60LoudnessCaptureCreate(2u, N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS, rate) != NULL, "program roles plus sub feeds refused");
    CHECK(N60LoudnessCaptureCreate(2u, N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS + 1u, rate) == NULL, "too many output channels accepted");
    CHECK(N60LoudnessCaptureCreate(0u, 0u, rate) == NULL && N60LoudnessCaptureCreate(N60_MAX_PROGRAM_CHANNELS + 1u, 0u, rate) == NULL,
          "bad channel counts accepted");

    /* demand off: nothing is captured and nothing counts as dropped */
    N60LoudnessCaptureBlock off = N60LoudnessCaptureBeginBlock(c, 64u);
    CHECK(off.frames == 0u, "block granted with demand off");
    CHECK(N60LoudnessCaptureGetSnapshot(c).droppedFrames == 0u, "drops counted with demand off");

    N60LoudnessCaptureSetDemand(c, true);
    N60LoudnessCaptureBlock block = N60LoudnessCaptureBeginBlock(c, 100u);
    CHECK(block.frames == 100u, "block frames");
    for (uint32_t n = 0; n < block.frames; ++n) {
        float in[3] = {(float)n, (float)n + 0.25f, -(float)n};
        float out[2] = {2.0f * (float)n, 0.5f};
        N60LoudnessCaptureWriteInput(c, block, n, in);
        N60LoudnessCaptureWriteOutput(c, block, n, out);
    }
    CHECK(N60LoudnessCaptureGetSnapshot(c).availableFrames == 0u, "frames visible before Commit");
    N60LoudnessCaptureCommit(c, block);
    float gotIn[3 * 128], gotOut[2 * 128];
    uint32_t got = N60LoudnessCaptureRead(c, gotIn, gotOut, 128u);
    CHECK(got == 100u, "read %u", got);
    for (uint32_t n = 0; n < got; ++n) {
        CHECK(gotIn[3u * n] == (float)n && gotIn[3u * n + 1u] == (float)n + 0.25f && gotIn[3u * n + 2u] == -(float)n
              && gotOut[2u * n] == 2.0f * (float)n && gotOut[2u * n + 1u] == 0.5f, "frame %u differs", n);
    }

    /* a frame whose output was never written reads as silence, not last lap's value */
    block = N60LoudnessCaptureBeginBlock(c, 1u);
    float in[3] = {1, 1, 1};
    N60LoudnessCaptureWriteInput(c, block, 0u, in);
    N60LoudnessCaptureCommit(c, block);
    N60LoudnessCaptureRead(c, gotIn, gotOut, 1u);
    CHECK(gotOut[0] == 0.0f && gotOut[1] == 0.0f, "unwritten output not silent");

    /* full ring: new frames are dropped and counted, unread frames survive */
    N60LoudnessCaptureDiscard(c);
    uint32_t written = 0;
    for (;;) {
        N60LoudnessCaptureBlock b = N60LoudnessCaptureBeginBlock(c, 4096u);
        if (b.frames == 0u) break;
        for (uint32_t n = 0; n < b.frames; ++n) {
            float v[3] = {(float)(written + n), 0, 0};
            N60LoudnessCaptureWriteInput(c, b, n, v);
        }
        N60LoudnessCaptureCommit(c, b);
        written += b.frames;
    }
    CHECK(written == c->capacityFrames, "filled %u of %u", written, c->capacityFrames);
    N60LoudnessCaptureSnapshot s = N60LoudnessCaptureGetSnapshot(c);
    CHECK(s.droppedFrames > 0u, "overflow not counted");
    CHECK(s.availableFrames == c->capacityFrames, "available %u", s.availableFrames);
    float *all = (float *)malloc((size_t)c->capacityFrames * 3u * sizeof(float));
    uint32_t read = all ? N60LoudnessCaptureRead(c, all, NULL, c->capacityFrames) : 0u;
    CHECK(read == c->capacityFrames, "drained %u", read);
    for (uint32_t n = 0; n < read && all; ++n) {
        if (all[3u * n] != (float)n) { CHECK(0, "unread frame %u overwritten", n); break; }
    }
    free(all);

    N60LoudnessCaptureBlock b = N60LoudnessCaptureBeginBlock(c, 10u);
    float v[3] = {0};
    N60LoudnessCaptureWriteInput(c, b, 0u, v);
    N60LoudnessCaptureCommit(c, b);
    N60LoudnessCaptureDiscard(c);
    CHECK(N60LoudnessCaptureGetSnapshot(c).availableFrames == 0u, "Discard left frames");
    N60LoudnessCaptureDestroy(c);
}

typedef struct { N60LoudnessCapture *capture; uint32_t total; } ProducerArgs;

static void *producer(void *raw) {
    ProducerArgs *a = (ProducerArgs *)raw;
    uint32_t sent = 0;
    while (sent < a->total) {
        uint32_t want = a->total - sent > 61u ? 61u : a->total - sent;
        N60LoudnessCaptureBlock b = N60LoudnessCaptureBeginBlock(a->capture, want);
        for (uint32_t n = 0; n < b.frames; ++n) {
            float v[2] = {(float)(sent + n), 0};
            N60LoudnessCaptureWriteInput(a->capture, b, n, v);
        }
        N60LoudnessCaptureCommit(a->capture, b);
        sent += b.frames; /* frames refused are simply retried: this test wants a lossless stream */
    }
    return NULL;
}

static void spscStress(void) {
    N60LoudnessCapture *c = N60LoudnessCaptureCreate(2u, 0u, 48000.0);
    N60LoudnessCaptureSetDemand(c, true);
    ProducerArgs args = {c, 2000000u};
    pthread_t thread;
    pthread_create(&thread, NULL, producer, &args);
    uint32_t expected = 0;
    float buffer[2 * 1000];
    while (expected < args.total) {
        uint32_t n = N60LoudnessCaptureRead(c, buffer, NULL, 1000u);
        for (uint32_t i = 0; i < n; ++i) {
            if (buffer[2u * i] != (float)(expected + i)) {
                CHECK(0, "stream broke at %u", expected + i);
                expected = args.total;
                break;
            }
        }
        expected += n;
    }
    pthread_join(thread, NULL);
    N60LoudnessCaptureDestroy(c);
}

/* ---- N-channel bridge ---- */

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

static void runBlock(N60LiveNChannelBridge *b, uint32_t frames, uint32_t *position, double rate, float amplitude) {
    float in[MAXB * 2u], out[MAXB * 2u];
    for (uint32_t i = 0; i < frames; ++i) {
        float v = amplitude * sinf((float)(2.0 * M_PI * 1000.0 * (double)(*position + i) / rate));
        in[i * 2u] = v;
        in[i * 2u + 1u] = -v;
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
}

static float peak(const float *x, uint32_t count, uint32_t stride, uint32_t offset) {
    float p = 0.0f;
    for (uint32_t i = 0; i < count; ++i) if (fabsf(x[i * stride + offset]) > p) p = fabsf(x[i * stride + offset]);
    return p;
}

static void bridgeCase(double rate) {
    N60LiveNChannelRenderGraph g = makeGraph(rate);
    AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}}, {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
    N60ProgramInputMap map = {0};
    CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map");
    N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
    CHECK(b != NULL && b->loudnessCapture != NULL, "bridge with capture at %.0f", rate);
    if (b == NULL) return;
    CHECK(b->loudnessCapture->inputChannels == 2u && b->loudnessCapture->outputChannels == 2u, "ring channels");
    uint32_t pos = 0;
    for (int i = 0; i < 8; ++i) runBlock(b, MAXB, &pos, rate, 0.4f);
    CHECK(N60LoudnessCaptureGetSnapshot(b->loudnessCapture).capturedFrames == 0u, "captured with demand off at %.0f", rate);
    N60LoudnessCaptureSetDemand(b->loudnessCapture, true);
    for (int i = 0; i < 16; ++i) runBlock(b, MAXB, &pos, rate, 0.4f);
    float inBuf[2 * MAXB * 16], outBuf[2 * MAXB * 16];
    uint32_t got = N60LoudnessCaptureRead(b->loudnessCapture, inBuf, outBuf, MAXB * 16u);
    CHECK(got == MAXB * 16u, "read %u at %.0f", got, rate);
    float inL = peak(inBuf, got, 2u, 0u), inR = peak(inBuf, got, 2u, 1u), outL = peak(outBuf, got, 2u, 0u);
    CHECK(fabsf(inL - 0.4f) < 0.01f && fabsf(inR - 0.4f) < 0.01f, "input peaks %.3f %.3f at %.0f", inL, inR, rate);
    CHECK(outL > 0.3f && outL < 0.45f, "legacy output peak %.3f at %.0f", outL, rate);

    /* with a 0.5 gain graph the Output halves and the Input does not */
    const float half = 0.5f;
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st; st.kind = N60_STAGE_GAIN; st.stageId = 1; st.laneA = N60_LANE_ALL;
    st.params = &half; st.paramCount = 1;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d; d.abiVersion = N60_GRAPH_ABI_VERSION; d.sampleRate = rate; d.maxBlockFrames = MAXB;
    d.inputChannels = d.outputChannels = 2; d.stages = &st; d.stageCount = 1;
    n60_graph *graph = NULL;
    CHECK(n60_graph_build(&d, &graph) == N60_STATUS_OK && graph, "graph build");
    if (graph && N60LiveNChannelBridgeAttachGraph(b, graph, 2u, MAXB)) {
        for (int i = 0; i < 16; ++i) runBlock(b, MAXB, &pos, rate, 0.4f);
        got = N60LoudnessCaptureRead(b->loudnessCapture, inBuf, outBuf, MAXB * 16u);
        CHECK(got == MAXB * 16u, "graph read %u", got);
        /* the first block can still carry the legacy tail: look at the last 8 */
        const uint32_t skip = MAXB * 8u;
        float gIn = peak(inBuf + skip * 2u, got - skip, 2u, 0u), gOut = peak(outBuf + skip * 2u, got - skip, 2u, 0u);
        CHECK(fabsf(gIn - 0.4f) < 0.01f, "graph input peak %.3f", gIn);
        CHECK(gOut > 0.15f && gOut < 0.25f, "graph output peak %.3f at %.0f", gOut, rate);
        N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
    }

    /* Reset (a new generation) drops demand and pending frames */
    N60LoudnessCaptureSnapshot before = N60LoudnessCaptureGetSnapshot(b->loudnessCapture);
    CHECK(before.demand != 0u, "demand lost");
    N60LiveNChannelBridgeDestroy(b);
    if (graph) n60_graph_retire(graph);
}

/* ---- subwoofer feeds (E9 S10) ---- */

static void runSubBlock(N60LiveNChannelBridge *b, uint32_t frames, uint32_t phys, uint32_t *position, double rate) {
    static float in[MAXB * 2u], out[MAXB * 16u];
    for (uint32_t i = 0; i < frames; ++i) {
        float v = 0.25f * sinf((float)(2.0 * M_PI * 1000.0 * (double)(*position + i) / rate));
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
    outList.mBuffers[0].mNumberChannels = phys;
    outList.mBuffers[0].mDataByteSize = frames * phys * sizeof(float);
    outList.mBuffers[0].mData = out;
    AudioTimeStamp ts = {0};
    N60LiveNChannelCaptureIOProc(0, &ts, &inList, &ts, &unused, &ts, b);
    N60LiveNChannelOutputIOProc(0, &ts, &unused, &ts, &outList, &ts, b);
}

/* `subs` sub lanes after two program lanes; legacy path (1..4 subs, bass management) or graph subs (5..8). */
static void subFeedCase(double rate, uint32_t subs) {
    const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    N60ProgramLaneGraphFinalize(&lanes);
    const uint32_t phys = 2u + subs;
    uint32_t prog[N60_MAX_PROGRAM_CHANNELS], subPhys[N60_LIVE_MAX_GRAPH_SUBWOOFERS];
    for (uint32_t i = 0; i < N60_MAX_PROGRAM_CHANNELS; ++i) prog[i] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    prog[0] = 0u;
    prog[1] = 1u;
    /* the sub feeds sit on shuffled physical channels so the mapping, not the order, is what is checked */
    for (uint32_t i = 0; i < subs; ++i) subPhys[i] = 2u + (subs - 1u - i);
    N60LiveNChannelOutputMap map = {0};
    const bool legacy = subs <= N60_MAX_SUBWOOFER_OUTPUTS;
    bool compiled = legacy
        ? N60LiveNChannelOutputMapCompile(layout, phys, prog, true, subs, subPhys, &map)
        : N60LiveNChannelOutputMapCompileGraphSubs(layout, phys, prog, subs, subPhys, &map);
    CHECK(compiled, "sub map compile (%u subs)", subs);
    if (!compiled) return;
    N60MultichannelBassManagementSnapshot bass = {0};
    if (legacy) bass = N60MultichannelBassManagementSnapshotMake(rate, layout, subs);
    N60LiveNChannelRenderGraph g = {0};
    CHECK(N60LiveNChannelRenderGraphMake(rate, layout, lanes, legacy, bass, map, &g), "graph make (%u subs)", subs);
    AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}}, {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
    N60ProgramInputMap inMap = {0};
    CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &inMap), "input map");
    N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, inMap, g, 0u, 1u);
    CHECK(b != NULL && b->loudnessCapture != NULL, "bridge (%u subs) at %.0f", subs, rate);
    if (b == NULL) return;
    CHECK(b->loudnessSubFeedCount == subs && b->loudnessCapture->outputChannels == 2u + subs,
          "ring output channels %u for %u subs", b->loudnessCapture->outputChannels, subs);

    /* a sine generator on the sub lanes only (RMS -12 dBFS, peak 0.355) */
    float p[11] = {(float)N60_GENERATOR_SINE, -12.0f, -6.0f, 100.0f, 100.0f, 4000.0f, 4096.0f, 7.0f, 0.0f, 1.0f, 600.0f};
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st; st.kind = N60_STAGE_GENERATOR; st.stageId = 5; st.laneA = 0;
    for (uint32_t i = 0; i < subs; ++i) st.laneMask |= 1ull << (2u + i);
    st.params = p; st.paramCount = 11;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d; d.abiVersion = N60_GRAPH_ABI_VERSION; d.sampleRate = rate; d.maxBlockFrames = MAXB;
    d.inputChannels = d.outputChannels = phys; d.stages = &st; d.stageCount = 1;
    n60_graph *graph = NULL;
    CHECK(n60_graph_build(&d, &graph) == N60_STATUS_OK && graph, "sub graph build");
    if (graph && N60LiveNChannelBridgeAttachGraph(b, graph, phys, MAXB)) {
        N60LoudnessCaptureSetDemand(b->loudnessCapture, true);
        uint32_t pos = 0;
        /* the generator ramps over 100 ms: run past it, discard, then read a settled window */
        const uint32_t settle = (uint32_t)(rate * 0.15 / MAXB) + 1u;
        for (uint32_t i = 0; i < settle; ++i) runSubBlock(b, MAXB, phys, &pos, rate);
        N60LoudnessCaptureDiscard(b->loudnessCapture);
        for (int i = 0; i < 16; ++i) runSubBlock(b, MAXB, phys, &pos, rate);
        static float inBuf[2 * MAXB * 16], outBuf[N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS * MAXB * 16];
        const uint32_t got = N60LoudnessCaptureRead(b->loudnessCapture, inBuf, outBuf, MAXB * 16u);
        CHECK(got == MAXB * 16u, "sub read %u", got);
        const uint32_t stride = b->loudnessCapture->outputChannels;
        for (uint32_t ch = 0; ch < stride; ++ch) {
            const float pk = peak(outBuf, got, stride, ch);
            if (ch < 2u) {
                /* the program passes through at 0.25 and never picks up the 0.355 sub generator */
                CHECK(pk > 0.22f && pk < 0.28f, "program role %u peak %.3f (want 0.25) at %.0f", ch, pk, rate);
            } else {
                CHECK(pk > 0.30f && pk < 0.40f, "sub feed %u peak %.3f at %.0f (%u subs)", ch - 2u, pk, rate, subs);
            }
        }
        N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
    }
    N60LiveNChannelBridgeDestroy(b);
    if (graph) n60_graph_retire(graph);
}

/* ---- routed N-channel bridge (E28 S9) ---- */

#define ROUTED_LANES 3u
#define ROUTED_PHYS 6u

static N60LiveNChannelRenderGraph makeRoutedGraph(double rate, const uint32_t *laneProgram, bool *ok) {
    const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    N60ProgramLaneGraphFinalize(&lanes);
    const uint32_t physical[ROUTED_LANES] = {5u, 4u, 3u};
    N60LiveNChannelOutputMap map = {0};
    *ok = N60LiveNChannelOutputMapCompileRouted(layout, ROUTED_PHYS, ROUTED_LANES, physical, &map);
    if (laneProgram != NULL) *ok = *ok && N60LiveNChannelOutputMapSetRoutedLaneProgram(&map, ROUTED_LANES, laneProgram);
    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    *ok = *ok && N60LiveNChannelRenderGraphMake(rate, layout, lanes, false, bass, map, &graph);
    return graph;
}

/* Lane 0 and lane 1 are two ways of the left speaker (0.3 and 0.2 of the source), lane 2 is the right speaker (0.5). */
static n60_graph *makeRoutedRouteGraph(double rate) {
    const float gains[ROUTED_LANES] = {0.3f, 0.2f, 0.5f};
    const float source[ROUTED_LANES] = {0.0f, 0.0f, 1.0f};
    float params[ROUTED_LANES * N60_ROUTE_PARAMS_PER_DEST];
    uint64_t mask = 0;
    for (uint32_t k = 0; k < ROUTED_LANES; ++k) {
        float *p = params + k * N60_ROUTE_PARAMS_PER_DEST;
        for (uint32_t e = 0; e < N60_ROUTE_MAX_ENTRIES; ++e) { p[e * 2u] = -1.0f; p[e * 2u + 1u] = 0.0f; }
        p[0] = source[k];
        p[1] = gains[k];
        mask |= (uint64_t)1 << (2u + k);
    }
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st; st.kind = N60_STAGE_ROUTE; st.stageId = 1; st.laneMask = mask;
    st.params = params; st.paramCount = ROUTED_LANES * N60_ROUTE_PARAMS_PER_DEST;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d; d.abiVersion = N60_GRAPH_ABI_VERSION; d.sampleRate = rate; d.maxBlockFrames = MAXB;
    d.inputChannels = d.outputChannels = 2u + ROUTED_LANES; d.stages = &st; d.stageCount = 1;
    n60_graph *graph = NULL;
    if (n60_graph_build(&d, &graph) != N60_STATUS_OK) return NULL;
    return graph;
}

static void runRoutedBlock(N60LiveNChannelBridge *b, uint32_t frames, uint32_t *position, double rate) {
    float in[MAXB * 2u], out[MAXB * ROUTED_PHYS];
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
    outList.mBuffers[0].mNumberChannels = ROUTED_PHYS;
    outList.mBuffers[0].mDataByteSize = frames * ROUTED_PHYS * sizeof(float);
    outList.mBuffers[0].mData = out;
    AudioTimeStamp ts = {0};
    N60LiveNChannelCaptureIOProc(0, &ts, &inList, &ts, &unused, &ts, b);
    N60LiveNChannelOutputIOProc(0, &ts, &unused, &ts, &outList, &ts, b);
}

static void routedCase(double rate) {
    const uint32_t none = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    const uint32_t laneProgram[ROUTED_LANES] = {0u, 0u, 1u};
    const uint32_t noProgram[ROUTED_LANES] = {none, none, none};
    const uint32_t badProgram[ROUTED_LANES] = {0u, 2u, 1u};
    bool ok = false;
    N60LiveNChannelOutputMap probe = {0};
    const uint32_t physical[ROUTED_LANES] = {5u, 4u, 3u};
    CHECK(N60LiveNChannelOutputMapCompileRouted(N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo),
                                                ROUTED_PHYS, ROUTED_LANES, physical, &probe), "routed compile");
    CHECK(!N60LiveNChannelOutputMapRoutedHasProgramLane(&probe), "fresh routed map claims a program lane");
    CHECK(!N60LiveNChannelOutputMapSetRoutedLaneProgram(&probe, ROUTED_LANES, badProgram), "role out of range accepted");
    CHECK(!N60LiveNChannelOutputMapSetRoutedLaneProgram(&probe, ROUTED_LANES - 1u, laneProgram), "short lane list accepted");
    CHECK(!N60LiveNChannelOutputMapRoutedHasProgramLane(&probe), "refused set changed the map");
    CHECK(N60LiveNChannelOutputMapSetRoutedLaneProgram(&probe, ROUTED_LANES, laneProgram)
              && N60LiveNChannelOutputMapRoutedHasProgramLane(&probe) && N60LiveNChannelOutputMapIsValid(&probe),
          "set lane programs");

    AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}}, {kAudioChannelLabel_Right, 0, {0, 0, 0}}};

    /* lanes that carry roles: the ring has Output, each role is the sum of its lanes */
    N60LiveNChannelRenderGraph g = makeRoutedGraph(rate, laneProgram, &ok);
    CHECK(ok, "routed graph at %.0f", rate);
    if (!ok) return;
    N60ProgramInputMap map = {0};
    CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map");
    N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
    CHECK(b != NULL && b->loudnessCapture != NULL && b->loudnessCapture->outputChannels == 2u,
          "routed bridge keeps an Output ring at %.0f", rate);
    n60_graph *graph = makeRoutedRouteGraph(rate);
    if (b != NULL && graph != NULL && b->loudnessCapture != NULL && b->loudnessCapture->outputChannels == 2u
        && N60LiveNChannelBridgeAttachGraph(b, graph, 2u + ROUTED_LANES, MAXB)) {
        uint32_t pos = 0;
        N60LoudnessCaptureSetDemand(b->loudnessCapture, true);
        for (int i = 0; i < 16; ++i) runRoutedBlock(b, MAXB, &pos, rate);
        float inBuf[2 * MAXB * 16], outBuf[2 * MAXB * 16];
        const uint32_t got = N60LoudnessCaptureRead(b->loudnessCapture, inBuf, outBuf, MAXB * 16u);
        CHECK(got == MAXB * 16u, "routed read %u at %.0f", got, rate);
        const uint32_t skip = MAXB * 8u; /* the first blocks can carry the pre-graph tail */
        const float left = peak(outBuf + skip * 2u, got - skip, 2u, 0u), right = peak(outBuf + skip * 2u, got - skip, 2u, 1u);
        /* left role = 0.4 x (0.3 + 0.2); right role = 0.2 x 0.5 (route entry 1 reads the right program lane) */
        CHECK(fabsf(left - 0.2f) < 0.01f, "left role peak %.4f expected 0.2 at %.0f", left, rate);
        CHECK(fabsf(right - 0.1f) < 0.005f, "right role peak %.4f expected 0.1 at %.0f", right, rate);
    } else {
        CHECK(0, "routed attach at %.0f", rate);
    }
    N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
    N60LiveNChannelBridgeDestroy(b);
    if (graph) n60_graph_retire(graph);

    /* no lane carries a role (sub or matrix-only routing): no Output ring, Input only */
    g = makeRoutedGraph(rate, noProgram, &ok);
    CHECK(ok, "unmapped routed graph");
    if (!ok) return;
    b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
    CHECK(b != NULL && b->loudnessCapture != NULL && b->loudnessCapture->outputChannels == 0u
              && b->loudnessCapture->inputChannels == 2u, "routed bridge with no program lane has no Output ring");
    N60LiveNChannelBridgeDestroy(b);
}

/* E9 S10b: a routed 2.1 plan. Lanes 0 and 1 are two ways of the left speaker, lane 2 is a sub-sourced lane: the Output
 * plane carries the program roles plus one sub feed (the lane's physical channel, after the limiter and master gain). */
static void routedSubFeedCase(double rate) {
    const uint32_t none = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    const uint32_t laneProgram[ROUTED_LANES] = {0u, 0u, none};
    const uint8_t laneSub[ROUTED_LANES] = {0u, 0u, 1u};
    bool ok = false;
    N60LiveNChannelRenderGraph g = makeRoutedGraph(rate, laneProgram, &ok);
    N60LiveNChannelOutputMap probe = g.outputMap;
    CHECK(ok, "routed sub graph at %.0f", rate);
    if (!ok) return;
    CHECK(!N60LiveNChannelOutputMapSetRoutedLaneSub(&probe, ROUTED_LANES - 1u, laneSub), "short sub list accepted");
    CHECK(N60LiveNChannelOutputMapSetRoutedLaneSub(&g.outputMap, ROUTED_LANES, laneSub)
              && N60LiveNChannelOutputMapIsValid(&g.outputMap), "set sub lanes");
    AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}}, {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
    N60ProgramInputMap map = {0};
    CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map");
    N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
    n60_graph *graph = makeRoutedRouteGraph(rate);
    const bool ring = b != NULL && b->loudnessCapture != NULL && b->loudnessCapture->outputChannels == 3u
        && b->loudnessSubFeedCount == 1u;
    CHECK(ring, "routed 2.1 bridge has 2 roles plus 1 sub feed at %.0f", rate);
    if (ring && graph != NULL && N60LiveNChannelBridgeAttachGraph(b, graph, 2u + ROUTED_LANES, MAXB)) {
        uint32_t pos = 0;
        N60LoudnessCaptureSetDemand(b->loudnessCapture, true);
        for (int i = 0; i < 16; ++i) runRoutedBlock(b, MAXB, &pos, rate);
        float inBuf[2 * MAXB * 16], outBuf[3 * MAXB * 16];
        const uint32_t got = N60LoudnessCaptureRead(b->loudnessCapture, inBuf, outBuf, MAXB * 16u);
        CHECK(got == MAXB * 16u, "routed sub read %u at %.0f", got, rate);
        const uint32_t skip = MAXB * 8u;
        const float left = peak(outBuf + skip * 3u, got - skip, 3u, 0u);
        const float right = peak(outBuf + skip * 3u, got - skip, 3u, 1u);
        const float sub = peak(outBuf + skip * 3u, got - skip, 3u, 2u);
        CHECK(fabsf(left - 0.2f) < 0.01f, "left role peak %.4f expected 0.2 at %.0f", left, rate);
        CHECK(right < 0.001f, "right role peak %.4f expected 0 (no lane) at %.0f", right, rate);
        CHECK(fabsf(sub - 0.1f) < 0.005f, "routed sub feed peak %.4f expected 0.1 at %.0f", sub, rate);
    } else {
        CHECK(0, "routed sub attach at %.0f", rate);
    }
    if (b != NULL) N60LiveNChannelBridgeAttachGraph(b, NULL, 0u, 0u);
    N60LiveNChannelBridgeDestroy(b);
    if (graph) n60_graph_retire(graph);
}

/* ---- stereo bridge: per-side over-range ---- */

static void stereoOverRange(double rate) {
    static float in[512u * 2u], out[512u * 2u];
    const float levels[3][2] = {{1.5f, 0.2f}, {0.2f, 1.5f}, {1.5f, 1.5f}};
    const int expectLeft[3] = {1, 0, 1};
    const int expectRight[3] = {0, 1, 1};
    for (int c = 0; c < 3; ++c) {
        N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(2048u);
        CHECK(bridge != NULL, "stereo bridge");
        if (bridge == NULL) return;
        CHECK(N60RealtimeAudioBridgePublishDSPGraph(bridge, N60DSPGraphSnapshotMakeUnity(rate)), "publish");
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0u, 0u);
        N60RealtimeAudioBridgeSetOutputVUMeterDemand(true);
        for (uint32_t n = 0; n < 512u; ++n) { in[2u * n] = levels[c][0]; in[2u * n + 1u] = levels[c][1]; }
        AudioBufferList inList = {0}, outList = {0};
        inList.mNumberBuffers = 1;
        inList.mBuffers[0].mNumberChannels = 2;
        inList.mBuffers[0].mDataByteSize = sizeof in;
        inList.mBuffers[0].mData = in;
        outList.mNumberBuffers = 1;
        outList.mBuffers[0].mNumberChannels = 2;
        outList.mBuffers[0].mDataByteSize = sizeof out;
        outList.mBuffers[0].mData = out;
        AudioTimeStamp ts = {0};
        N60CaptureIOProc(0, &ts, &inList, &ts, &inList, &ts, bridge);
        N60OutputIOProc(0, &ts, &inList, &ts, &outList, &ts, bridge);
        N60OutputVUMeterSnapshot vu = N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(bridge);
        /* the meter reads post-render output; require the pairing, not the exact count */
        CHECK(vu.overRangeLeft + vu.overRangeRight == vu.overRangeSamples, "sum differs at case %d", c);
        CHECK(expectLeft[c] == (vu.overRangeLeft > 0u), "left over-range %llu case %d at %.0f",
              (unsigned long long)vu.overRangeLeft, c, rate);
        CHECK(expectRight[c] == (vu.overRangeRight > 0u), "right over-range %llu case %d at %.0f",
              (unsigned long long)vu.overRangeRight, c, rate);
        N60RealtimeAudioBridgeSetOutputVUMeterDemand(false);
        N60RealtimeAudioBridgeDestroy(bridge);
    }
}

int main(void) {
    spscStress();
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        ringBasics(kRates[r]);
        bridgeCase(kRates[r]);
        subFeedCase(kRates[r], 1u);
        subFeedCase(kRates[r], 2u);
        subFeedCase(kRates[r], 5u);
        routedCase(kRates[r]);
        routedSubFeedCase(kRates[r]);
        stereoOverRange(kRates[r]);
        printf("rate %.0f ok\n", kRates[r]);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("harness_e28_loudness_capture OK");
    return 0;
}
