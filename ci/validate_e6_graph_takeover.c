/* E6 S8b: behavioural harness for the bridge hand-over between the stereo kernel and a
 * libn60core graph. Drives N60OutputIOProc with a continuous sine at the eight standard
 * rates, attaches a graph (gain 0.5), then detaches it, and checks that the output never
 * steps (largest sample-to-sample jump bounded by the signal slope), that the published
 * mix reaches 1 and returns to 0, and that the settled levels are the kernel's and the
 * graph's. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"
#include "n60/graph.h"

#define BUF 256u
#define CAP 262144u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static float inBuf[BUF * 2u], outBuf[BUF * 2u];
static AudioBufferList inList, outList;
static uint64_t pos;
static double rateNow;
static float lastL, lastR;
static float maxStep;
static float peakAfter;

static void block(N60RealtimeAudioBridge *b, int track) {
    for (uint32_t i = 0; i < BUF; ++i) {
        float v = 0.4f * sinf((float)(2.0 * M_PI * 1000.0 * (double)(pos + i) / rateNow));
        inBuf[i * 2u] = v;
        inBuf[i * 2u + 1u] = v;
    }
    pos += BUF;
    AudioTimeStamp ts = {0};
    N60CaptureIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
    N60OutputIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
    peakAfter = 0.0f;
    for (uint32_t i = 0; i < BUF; ++i) {
        float l = outBuf[i * 2u], r = outBuf[i * 2u + 1u];
        if (!isfinite(l) || !isfinite(r)) { failures++; fprintf(stderr, "FAIL non-finite\n"); return; }
        if (track) {
            float s = fabsf(l - lastL);
            if (s > maxStep) maxStep = s;
            s = fabsf(r - lastR);
            if (s > maxStep) maxStep = s;
        }
        lastL = l;
        lastR = r;
        if (fabsf(l) > peakAfter) peakAfter = fabsf(l);
    }
}

int main(void) {
    memset(&inList, 0, sizeof inList);
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mDataByteSize = sizeof inBuf;
    inList.mBuffers[0].mData = inBuf;
    outList = inList;
    outList.mBuffers[0].mData = outBuf;

    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        rateNow = kRates[r];
        pos = 0;
        N60RealtimeAudioBridge *b = N60RealtimeAudioBridgeCreate(CAP);
        CHECK(b != NULL, "bridge");
        if (!b) continue;
        N60DSPGraphSnapshot snap = N60DSPGraphSnapshotMakeUnity(rateNow);
        CHECK(N60RealtimeAudioBridgePublishDSPGraph(b, snap), "publish");
        N60RealtimeAudioBridgeConfigureOutputGate(b, 0u, 0u);

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
        d.sampleRate = rateNow;
        d.maxBlockFrames = BUF;
        d.inputChannels = d.outputChannels = 2;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *g = NULL;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK && g, "graph build");
        if (!g) { N60RealtimeAudioBridgeDestroy(b); continue; }

        uint32_t settle = (uint32_t)(rateNow * 0.2 / BUF) + 8u;
        for (uint32_t i = 0; i < settle; ++i) block(b, 0);
        CHECK(peakAfter > 0.35f && peakAfter < 0.45f, "kernel level %.3f at %.0f", peakAfter, rateNow);

        /* Largest legitimate step: 1 kHz at 0.4 peak. */
        float slope = 0.4f * (float)(2.0 * M_PI * 1000.0 / rateNow);
        maxStep = 0.0f;
        CHECK(N60RealtimeAudioBridgeSetUnifiedGraph(b, g, BUF, rateNow), "attach");
        for (uint32_t i = 0; i < settle; ++i) block(b, 1);
        CHECK(N60RealtimeAudioBridgeUnifiedGraphMix(b) > 0.999f, "mix did not reach 1: %.3f", N60RealtimeAudioBridgeUnifiedGraphMix(b));
        CHECK(peakAfter > 0.15f && peakAfter < 0.25f, "graph level %.3f at %.0f", peakAfter, rateNow);
        CHECK(maxStep < 4.0f * slope + 1.0e-4f, "attach step %.5f vs slope %.5f at %.0f", maxStep, slope, rateNow);

        maxStep = 0.0f;
        CHECK(N60RealtimeAudioBridgeSetUnifiedGraph(b, NULL, 0, 0.0), "detach");
        for (uint32_t i = 0; i < settle; ++i) block(b, 1);
        CHECK(N60RealtimeAudioBridgeUnifiedGraphMix(b) < 0.001f, "mix did not return to 0");
        CHECK(!N60RealtimeAudioBridgeUnifiedGraphActive(b), "still active");
        CHECK(peakAfter > 0.35f && peakAfter < 0.45f, "kernel level after detach %.3f", peakAfter);
        CHECK(maxStep < 4.0f * slope + 1.0e-4f, "detach step %.5f vs slope %.5f at %.0f", maxStep, slope, rateNow);

        N60RealtimeAudioBridgeReleaseUnifiedGraph(b);
        N60RealtimeAudioBridgeDestroy(b);
        n60_graph_retire(g);
    }
    if (failures) { fprintf(stderr, "E6 graph takeover: %d failures\n", failures); return EXIT_FAILURE; }
    puts("E6 graph takeover: PASS");
    return EXIT_SUCCESS;
}
