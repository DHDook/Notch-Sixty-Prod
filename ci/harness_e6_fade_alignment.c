/* E6 S8b2c: behavioural harness for latency alignment across the kernel/graph hand-over fade.
 * The graph is a DELAY stage of D frames (its latency readback is D) and the kernel is unity
 * (latency 0). A 1 kHz sine with D = half a period reaches the fade with the two paths in
 * antiphase, so an unaligned linear crossfade collapses toward silence mid-fade. With the graph
 * latency published, the bridge delays the kernel by D across the fade and the sliding
 * one-period peak stays near the signal level. Checked at the eight standard rates for attach
 * and detach, for the graph-leads case (kernel snapshot declares D, graph has none), and for
 * step-freedom of the output. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"
#include "n60/graph.h"

#define BUF 256u
#define CAP 262144u
#define MAXSAMPLES 200000u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static float inBuf[BUF * 2u], outBuf[BUF * 2u];
static AudioBufferList inList, outList;
static uint64_t pos;
static double rateNow;
static float captured[MAXSAMPLES];
static uint32_t capturedCount;
static float maxStep;
static float lastL;

static void block(N60RealtimeAudioBridge *b, int capture) {
    for (uint32_t i = 0; i < BUF; ++i) {
        float v = 0.4f * sinf((float)(2.0 * M_PI * 1000.0 * (double)(pos + i) / rateNow));
        inBuf[i * 2u] = v;
        inBuf[i * 2u + 1u] = v;
    }
    pos += BUF;
    AudioTimeStamp ts = {0};
    N60CaptureIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
    N60OutputIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
    for (uint32_t i = 0; i < BUF; ++i) {
        float l = outBuf[i * 2u];
        if (!isfinite(l)) { failures++; fprintf(stderr, "FAIL non-finite\n"); return; }
        if (capture) {
            float s = fabsf(l - lastL);
            if (s > maxStep) maxStep = s;
            if (capturedCount < MAXSAMPLES) captured[capturedCount++] = l;
        }
        lastL = l;
    }
}

/* Smallest one-period peak over the captured stream, skipping the first period. */
static float minWindowPeak(void) {
    const uint32_t w = (uint32_t)(rateNow / 1000.0);
    float minPeak = 10.0f;
    for (uint32_t start = w; start + w <= capturedCount; start += w) {
        float pk = 0.0f;
        for (uint32_t i = 0; i < w; ++i) {
            float a = fabsf(captured[start + i]);
            if (a > pk) pk = a;
        }
        if (pk < minPeak) minPeak = pk;
    }
    return minPeak;
}

static n60_graph *buildDelayGraph(uint32_t delay) {
    float p = (float)delay;
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_DELAY;
    st.stageId = 1;
    st.laneA = N60_LANE_ALL;
    st.params = &p;
    st.paramCount = 1;
    st.capacityFrames = delay + 16u;
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
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return NULL;
    return g;
}

/* mode 0: aligned attach+detach (graph latency published). mode 1: not published (control,
 * must collapse). mode 3: latency far beyond the fade (clamped), still step-free. mode 2: graph leads (kernel snapshot declares D, graph has no delay). */
static void run(int mode) {
    pos = 0;
    N60RealtimeAudioBridge *b = N60RealtimeAudioBridgeCreate(CAP);
    CHECK(b != NULL, "bridge");
    if (!b) return;
    const uint32_t D = mode == 3 ? (uint32_t)(rateNow * 0.04) : (uint32_t)(rateNow / 2000.0);
    const uint32_t fadeFrames = (uint32_t)(rateNow * 0.020);
    N60DSPGraphSnapshot snap = N60DSPGraphSnapshotMakeUnity(rateNow);
    if (mode == 2) snap.latencyFrames = D;
    CHECK(N60RealtimeAudioBridgePublishDSPGraph(b, snap), "publish");
    N60RealtimeAudioBridgeConfigureOutputGate(b, 0u, 0u);
    n60_graph *g = buildDelayGraph(mode == 2 ? 0u : D);
    CHECK(g != NULL, "graph build");
    if (!g) { N60RealtimeAudioBridgeDestroy(b); return; }
    const uint32_t settle = (uint32_t)(rateNow * 0.2 / BUF) + 8u;
    for (uint32_t i = 0; i < settle; ++i) block(b, 0);
    const float slope = 0.4f * (float)(2.0 * M_PI * 1000.0 / rateNow);

    CHECK(N60RealtimeAudioBridgeSetUnifiedGraph(b, g, BUF, rateNow), "attach");
    if (mode == 0 || mode == 3) N60RealtimeAudioBridgeSetUnifiedGraphLatency(b, D);
    if (mode == 2) N60RealtimeAudioBridgeSetUnifiedGraphLatency(b, 0u);
    capturedCount = 0;
    maxStep = 0.0f;
    for (uint32_t i = 0; i < settle; ++i) block(b, 1);
    CHECK(N60RealtimeAudioBridgeUnifiedGraphMix(b) > 0.999f, "mix did not reach 1");
    const float attachMin = minWindowPeak();
    const float attachStep = maxStep;
    /* Mode 3: a 40 ms graph latency is capped at a quarter of the 20 ms fade. */
    const int32_t expectAlign = mode == 3 ? (int32_t)(fadeFrames / 4u) : mode == 0 ? (int32_t)D : mode == 2 ? -(int32_t)D : 0;
    CHECK(N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(b) == expectAlign,
          "mode %d alignment %d expected %d at %.0f", mode,
          N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(b), expectAlign, rateNow);

    capturedCount = 0;
    maxStep = 0.0f;
    CHECK(N60RealtimeAudioBridgeSetUnifiedGraph(b, NULL, 0, 0.0), "detach");
    for (uint32_t i = 0; i < settle; ++i) block(b, 1);
    CHECK(N60RealtimeAudioBridgeUnifiedGraphMix(b) < 0.001f, "mix did not return to 0");
    const float detachMin = minWindowPeak();
    const float detachStep = maxStep;

    if (mode == 1) {
        /* Unaligned antiphase fade: the mid-fade window must collapse (sensitivity check). */
        CHECK(attachMin < 0.3f * 0.4f, "unaligned attach min peak %.3f did not collapse at %.0f", attachMin, rateNow);
    } else if (mode == 0) {
        /* Aligned: the kernel is delayed by D*mix, the graph by D, so the residual lag is
         * D*(1-mix) of a half period. The linear crossfade of two sines with that lag has
         * magnitude |(1-m) + m*exp(j*pi*(1-m))|, minimum ~0.57 near m = 0.3 (measured 0.58
         * of level at every rate). The bound is 0.5, against ~0.0 for the unaligned control. */
        CHECK(attachMin > 0.5f * 0.4f, "aligned attach min peak %.3f at %.0f", attachMin, rateNow);
        CHECK(detachMin > 0.5f * 0.4f, "aligned detach min peak %.3f at %.0f", detachMin, rateNow);
    }
    /* The graph path itself is a pure delay, so nothing may step beyond the signal slope. */
    const float stepBound = mode == 3 ? 8.0f * slope : 4.0f * slope;
    CHECK(attachStep < stepBound + 1.0e-4f, "mode %d attach step %.5f vs slope %.5f at %.0f", mode, attachStep, slope, rateNow);
    CHECK(detachStep < stepBound + 1.0e-4f, "mode %d detach step %.5f vs slope %.5f at %.0f", mode, detachStep, slope, rateNow);

    N60RealtimeAudioBridgeReleaseUnifiedGraph(b);
    N60RealtimeAudioBridgeDestroy(b);
    n60_graph_retire(g);
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
        for (int mode = 0; mode < 4; ++mode) run(mode);
    }
    if (failures) { fprintf(stderr, "E6 fade alignment: %d failures\n", failures); return EXIT_FAILURE; }
    puts("E6 fade alignment: PASS");
    return EXIT_SUCCESS;
}
