/* E24 S1: behavioural harness for the Level step's render path (N60LevelSessionProcess) with a real generator-only
 * libn60core graph, at every standard rate. Checks: the mic channel reaches the monitor ring; the generator plays
 * only on the chosen output channels and respects the -6 dBFS RMS ceiling; stop (active = 0, then request-stop)
 * ramps to exact silence in about 100 ms and raises rampDone only after that; a bad layout is counted, not crashed. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60LevelSessionProc.h"
#include "n60/graph.h"
#include "n60/measure.h"

#define BLOCK 256u
#define PHYS 6u /* physical output channels (interleaved) */

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static n60_graph *buildGraph(double rate, uint32_t lanes, float levelDb, float ceilDb) {
    float p[11] = {1 /*pink*/, levelDb, ceilDb, 1000, 1000, 4000, 4096, 7, 0, 1 /*active*/, 600};
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_GENERATOR;
    st.stageId = 618;
    st.laneA = 0;
    st.laneMask = (1ull << lanes) - 1ull;
    st.params = p;
    st.paramCount = 11;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = BLOCK;
    d.inputChannels = d.outputChannels = lanes;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = NULL;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return NULL;
    return g;
}

static void run(double rate) {
    const uint32_t lanes = 2u;
    const uint32_t outCh[2] = {1u, 4u};
    n60_graph *g = buildGraph(rate, lanes, -20.0f, -6.0f);
    n60_monitor_ring *ring = NULL;
    CHECK(g != NULL, "graph build %.0f", rate);
    CHECK(n60_monitor_ring_create(1u << 20, &ring) == 0, "ring");
    if (g == NULL || ring == NULL) return;
    N60LevelSessionContext *ctx = N60LevelSessionContextCreate(g, ring, 0u, outCh, lanes, BLOCK);
    CHECK(ctx != NULL, "context");
    if (ctx == NULL) return;

    float *io = calloc((size_t)BLOCK * PHYS, sizeof(float));
    float *mic = malloc(sizeof(float) * BLOCK);
    for (uint32_t i = 0; i < BLOCK; ++i) mic[i] = 0.25f;
    float *laneP[2];
    uint32_t strides[2] = {PHYS, PHYS};
    laneP[0] = io + outCh[0];
    laneP[1] = io + outCh[1];

    /* 0.5 s of playing: measure per-channel energy and peak. */
    const uint32_t playBlocks = (uint32_t)(rate * 0.5 / BLOCK) + 1u;
    double e[PHYS] = {0};
    float peak = 0.0f;
    uint64_t n = 0;
    for (uint32_t b = 0; b < playBlocks; ++b) {
        memset(io, 0, sizeof(float) * BLOCK * PHYS);
        CHECK(N60LevelSessionProcess(ctx, mic, 1u, laneP, strides, BLOCK) == BLOCK, "frames");
        if (b * BLOCK > rate * 0.2) { /* past the 100 ms ramp */
            for (uint32_t i = 0; i < BLOCK; ++i) {
                for (uint32_t c = 0; c < PHYS; ++c) { const double v = io[i * PHYS + c]; e[c] += v * v; if (fabsf((float)v) > peak) peak = fabsf((float)v); }
                ++n;
            }
        }
    }
    for (uint32_t c = 0; c < PHYS; ++c) {
        const double rmsDb = 10.0 * log10(e[c] / (double)n + 1e-30);
        if (c == outCh[0] || c == outCh[1]) CHECK(rmsDb > -23.0 && rmsDb < -17.0, "rate %.0f ch %u rms %.2f dB (want ~-20)", rate, c, rmsDb);
        else CHECK(e[c] == 0.0, "rate %.0f unselected ch %u not silent", rate, c);
    }
    CHECK(peak <= 1.0f, "peak %f", peak);
    const uint32_t popped = n60_monitor_ring_available(ring);
    CHECK(popped >= playBlocks * BLOCK - BLOCK, "ring got %u frames", popped);
    float tmp[8];
    CHECK(n60_monitor_ring_pop(ring, tmp, 8) == 8 && tmp[0] == 0.25f, "mic value in ring");

    /* Ceiling: level 0 dBFS posts are clamped to -6 dBFS RMS in the core. */
    n60_param_record up = {618, 1, 0.0f, 0};
    CHECK(n60_graph_post_params(g, &up, 1) == N60_STATUS_OK, "post level");
    double e2 = 0.0; uint64_t n2 = 0;
    for (uint32_t b = 0; b < playBlocks; ++b) {
        memset(io, 0, sizeof(float) * BLOCK * PHYS);
        N60LevelSessionProcess(ctx, mic, 1u, laneP, strides, BLOCK);
        if (b * BLOCK > rate * 0.2) for (uint32_t i = 0; i < BLOCK; ++i) { const double v = io[i * PHYS + outCh[0]]; e2 += v * v; ++n2; }
    }
    const double clampDb = 10.0 * log10(e2 / (double)n2);
    CHECK(clampDb < -4.5, "rate %.0f ceiling breached: %.2f dBFS RMS", rate, clampDb);

    /* Stop: post active = 0, then request stop; rampDone only after silence, within ~100 ms + 2 blocks. */
    n60_param_record off = {618, 9, 0.0f, 0};
    CHECK(n60_graph_post_params(g, &off, 1) == N60_STATUS_OK, "post stop");
    N60LevelSessionContextRequestStop(ctx);
    uint32_t blocksToDone = 0;
    N60LevelSessionSnapshot s = N60LevelSessionContextSnapshot(ctx);
    CHECK(!s.rampDone, "rampDone before processing");
    while (!s.rampDone && blocksToDone < 4000u) {
        memset(io, 0, sizeof(float) * BLOCK * PHYS);
        N60LevelSessionProcess(ctx, mic, 1u, laneP, strides, BLOCK);
        ++blocksToDone;
        s = N60LevelSessionContextSnapshot(ctx);
    }
    const double ms = 1000.0 * (double)blocksToDone * BLOCK / rate;
    CHECK(s.rampDone, "rate %.0f stop never completed", rate);
    CHECK(ms >= 90.0 && ms <= 100.0 + 2000.0 * BLOCK / rate + 20.0, "rate %.0f ramp took %.1f ms", rate, ms);
    CHECK(s.processFailures == 0, "process failures %llu", (unsigned long long)s.processFailures);

    /* Bad layout (NULL lane) is skipped, not fatal. */
    float *badLanes[2] = {NULL, laneP[1]};
    CHECK(N60LevelSessionProcess(ctx, NULL, 0u, badLanes, strides, BLOCK) == BLOCK, "null lane");

    free(io); free(mic);
    N60LevelSessionContextDestroy(ctx);
    n60_monitor_ring_destroy(ring);
    n60_graph_retire(g);
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (size_t i = 0; i < sizeof rates / sizeof rates[0]; ++i) run(rates[i]);
    if (failures) { printf("e24_level_session: %d failure(s)\n", failures); return 1; }
    printf("e24_level_session: ok\n");
    return 0;
}
