/* E20 S2: behavioural harness for the bridge output path. The rendered stream must not depend on
 * how the host chops it into callbacks: the same input pushed through N60CaptureIOProc /
 * N60OutputIOProc in callbacks of 1, 31, 512 and 4096 frames, with a libn60core graph (gain 0.5)
 * attached, is bit-identical at the eight standard rates. The kernel path before the graph is
 * attached is covered too (the first frames of each run). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"
#include "n60/graph.h"

/* The graph attaches at a frame that every callback size lands on (lcm of 31 and 4096). */
#define ATTACH 126976u
#define TOTAL (ATTACH + 16384u)
#define MAXCB 4096u
#define CAP 262144u
#define GRAPH_BLOCK 256u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const uint32_t kSizes[] = {1u, 31u, 512u, 4096u};
static float inBuf[MAXCB * 2u], outBuf[MAXCB * 2u];
static float result[4][TOTAL * 2u];

/* E20 S10 part 7: the analysis, ambient-reference and speaker-drive rings and the output VU meter are on, and a
 * transition ramp runs across the first frames of the graph-only path, so the bulk output side (gain tiles, ring
 * writes) is compared across callback sizes too. */
static uint64_t fnv(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}
static N60AnalysisFrame anBuf[MAXCB];
static N60AmbientPlaybackReferenceFrame refBuf[MAXCB];
static uint64_t ringHash[4][3];

static void run(double rate, uint32_t cb, float *dst, uint64_t *rings) {
    rings[0] = rings[1] = rings[2] = 14695981039346656037ull;
    AudioBufferList inList, outList;
    memset(&inList, 0, sizeof inList);
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mData = inBuf;
    outList = inList;
    outList.mBuffers[0].mData = outBuf;

    N60RealtimeAudioBridge *b = N60RealtimeAudioBridgeCreate(CAP);
    CHECK(b != NULL, "bridge");
    if (!b) return;
    N60DSPGraphSnapshot snap = N60DSPGraphSnapshotMakeUnity(rate);
    CHECK(N60RealtimeAudioBridgePublishDSPGraph(b, snap), "publish");
    N60RealtimeAudioBridgeConfigureOutputGate(b, 0u, 0u);
    N60RealtimeAudioBridgeSetAnalysisDemand(b, N60_ANALYSIS_DEMAND_ALL);
    N60RealtimeAudioBridgeSetAmbientReferenceDemand(b, true);
    N60RealtimeAudioBridgeSetSpeakerDriveDemand(b, true);
    N60RealtimeAudioBridgeSetOutputVUMeterDemand(true);

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
    d.maxBlockFrames = GRAPH_BLOCK;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = NULL;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK && g, "graph build");
    if (!g) { N60RealtimeAudioBridgeDestroy(b); return; }

    uint32_t done = 0;
    while (done < TOTAL) {
        uint32_t n = TOTAL - done < cb ? TOTAL - done : cb;
        if (done == ATTACH)
            CHECK(N60RealtimeAudioBridgeSetUnifiedGraph(b, g, GRAPH_BLOCK, rate), "attach");
        if (done == ATTACH) N60RealtimeAudioBridgeRampTransitionGain(b, 0.5f, 6000u);
        for (uint32_t i = 0; i < n; ++i) {
            float v = 0.4f * sinf((float)(2.0 * M_PI * 997.0 * (double)(done + i) / rate));
            inBuf[i * 2u] = v;
            inBuf[i * 2u + 1u] = 0.5f * v;
        }
        inList.mBuffers[0].mDataByteSize = n * 2u * sizeof(float);
        outList.mBuffers[0].mDataByteSize = n * 2u * sizeof(float);
        AudioTimeStamp ts = {0};
        N60CaptureIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
        N60OutputIOProc(0, &ts, &inList, &ts, &outList, &ts, b);
        memcpy(dst + (size_t)done * 2u, outBuf, (size_t)n * 2u * sizeof(float));
        uint32_t got = N60RealtimeAudioBridgeReadAnalysisFrames(b, anBuf, MAXCB);
        rings[0] = fnv(rings[0], anBuf, (size_t)got * sizeof(N60AnalysisFrame));
        got = N60RealtimeAudioBridgeReadAmbientReferenceFrames(b, refBuf, MAXCB);
        rings[1] = fnv(rings[1], refBuf, (size_t)got * sizeof(N60AmbientPlaybackReferenceFrame));
        got = N60RealtimeAudioBridgeReadSpeakerDriveFrames(b, refBuf, MAXCB);
        rings[2] = fnv(rings[2], refBuf, (size_t)got * sizeof(N60AmbientPlaybackReferenceFrame));
        done += n;
    }
    N60RealtimeAudioBridgeReleaseUnifiedGraph(b);
    N60RealtimeAudioBridgeDestroy(b);
    n60_graph_retire(g);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        for (size_t s = 0; s < 4; ++s) run(kRates[r], kSizes[s], result[s], ringHash[s]);
        if (getenv("N60_HARNESS_DUMP"))   /* digest for comparing two builds of the bridge (old against new) */
            for (size_t s = 0; s < 4; ++s)
                printf("DIGEST %.0f %u out=%016llx an=%016llx amb=%016llx drv=%016llx\n", kRates[r], kSizes[s],
                       (unsigned long long)fnv(14695981039346656037ull, result[s], (size_t)TOTAL * 2u * sizeof(float)),
                       (unsigned long long)ringHash[s][0], (unsigned long long)ringHash[s][1],
                       (unsigned long long)ringHash[s][2]);
        for (size_t s = 1; s < 4; ++s) {
            size_t bad = 0, first = 0;
            for (size_t i = 0; i < (size_t)TOTAL * 2u; ++i)
                if (memcmp(&result[0][i], &result[s][i], sizeof(float)) != 0) { if (!bad) first = i; bad++; }
            CHECK(bad == 0, "rate %.0f: callback %u differs from %u in %zu samples (first at %zu)", kRates[r], kSizes[s], kSizes[0], bad, first);
        }
        for (size_t s = 1; s < 4; ++s)
            /* The speaker-drive ring records whole callbacks against a small anchor ring, so 1- and 31-frame callbacks
             * legitimately drop; it is compared from 512 frames up (reference: the first of those). */
            for (size_t k = 0; k < 3; ++k)
                if (k != 2 || kSizes[s] >= 512u)
                CHECK(ringHash[s][k] == ringHash[k == 2 ? 2 : 0][k], "rate %.0f: ring %zu differs between callback %u and %u",
                      kRates[r], k, kSizes[s], kSizes[0]);
        float peak = 0.0f;
        for (size_t i = (size_t)(TOTAL - 4096u) * 2u; i < (size_t)TOTAL * 2u; ++i) if (fabsf(result[0][i]) > peak) peak = fabsf(result[0][i]);
        CHECK(peak > 0.01f, "rate %.0f: silent output (%.4f)", kRates[r], peak);
    }
    if (failures) { fprintf(stderr, "E20 bridge fast path: %d failures\n", failures); return EXIT_FAILURE; }
    puts("E20 bridge fast path: PASS");
    return EXIT_SUCCESS;
}
