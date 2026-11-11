/* E4 S30c (G9), tightened in S30d (G12): an AMBIENT stage with the section trailer (n = 17) across a topology rebuild
 * (an output-gain stage is appended). The rebuilt instance carries the filter state, the coefficient crossfades and the
 * gain ramp, so it matches a graph built with that topology from the start sample for sample (bit-identical with an instant swap; a linear fade of two equal
 * signals is within float rounding), in steady state and with a section edit 1 block before the rebuild (mid-crossfade at the
 * hand-over). A section-count change keeps the shared sections' state. Eight standard rates, noise input. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define BLOCK 256
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const float kCentres[17] = {200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000};

static void params(float *p, float sec7Db) {
    const float base[10] = {0, 120, 0, 0.7f, 2200, 0, 1.0f, 6500, 0, 0.7f};
    memcpy(p, base, sizeof base);
    p[10] = 17;
    for (int k = 0; k < 17; k++) {
        p[11 + 3 * k] = kCentres[k];
        p[12 + 3 * k] = (k == 7) ? sec7Db : -1.0f - 0.25f * (float)(k % 5);
        p[13 + 3 * k] = 4.32f;
    }
}

static n60_graph_desc desc(double rate, const float *p, uint32_t np, const float *gain, n60_stage_desc *st) {
    memset(st, 0, 2 * sizeof *st);
    uint32_t n = 0;
    st[n].structSize = sizeof st[n];
    st[n].kind = N60_STAGE_AMBIENT;
    st[n].stageId = 1;
    st[n].laneA = N60_LANE_ALL;
    st[n].params = p;
    st[n].paramCount = np;
    n++;
    if (gain) {
        st[n].structSize = sizeof st[n];
        st[n].kind = N60_STAGE_OUTPUT_GAIN;
        st[n].stageId = 2;
        st[n].laneA = N60_LANE_ALL;
        st[n].params = gain;
        st[n].paramCount = 1;
        n++;
    }
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = BLOCK;
    d.inputChannels = d.outputChannels = 1;
    d.stages = st;
    d.stageCount = n;
    return d;
}

static uint32_t seed = 4242;

/* Runs both graphs on the same noise block; returns the largest |a - b|. */
static double step(n60_graph *a, n60_graph *b) {
    static float in[BLOCK], oa[BLOCK], ob[BLOCK];
    for (uint32_t i = 0; i < BLOCK; i++) { seed = seed * 1664525u + 1013904223u; in[i] = 0.5f * (((float)(seed >> 8) / 8388608.0f) - 1.0f); }
    const float *ip[1] = {in};
    float *opa[1] = {oa}, *opb[1] = {ob};
    CHECK(n60_graph_process(a, ip, opa, BLOCK) == N60_STATUS_OK, "process a");
    CHECK(n60_graph_process(b, ip, opb, BLOCK) == N60_STATUS_OK, "process b");
    double worst = 0;
    for (uint32_t i = 0; i < BLOCK; i++) { const double d = fabs((double)oa[i] - (double)ob[i]); if (d > worst) worst = d; }
    return worst;
}

static void settle(n60_graph *a, n60_graph *b, double *worst) {
    for (int i = 0; i < 100000; i++) {
        n60_rebuild_status rs;
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        n60_graph_get_rebuild_status(a, &rs);
        double w = step(a, b);
        if (w > *worst) *worst = w;
        if (rs.state == 0 && i > 0) break;
    }
}

/* edit: 0 = steady state at the rebuild; 1 = a section edit posted 1 ms before the rebuild (xf != 0 at hand-over). */
static void testCarry(double rate, int edit, int linearFade) {
    float p0[62], p1[62];
    params(p0, -2.0f);
    params(p1, edit ? -6.0f : -2.0f);
    const float unity = 1.0f;
    n60_stage_desc sa[2], sb[2], sc[2];
    n60_graph_desc da = desc(rate, p0, 62, NULL, sa);     /* rebuilt graph: starts without the output-gain stage */
    n60_graph_desc db = desc(rate, p0, 62, (const float *)&unity, sb);   /* uninterrupted reference: has it from the start */
    n60_graph *a = NULL, *b = NULL;
    CHECK(n60_graph_build(&da, &a) == N60_STATUS_OK && a, "rate %.0f build a", rate);
    n60_status bst = n60_graph_build(&db, &b);
    CHECK(bst == N60_STATUS_OK && b, "rate %.0f build b status %d", rate, (int)bst);
    if (!a || !b) return;
    double worst = 0;
    const int warm = (int)(rate * 0.3 / BLOCK);
    for (int i = 0; i < warm; i++) { double w = step(a, b); if (w > worst) worst = w; }
    CHECK(worst < 1e-5, "rate %.0f edit %d: identical before the rebuild (%g)", rate, edit, worst);
    if (edit) {
        n60_param_record rec = {1, 12 + 3 * 7, -6.0f, 0};
        CHECK(n60_graph_post_params(a, &rec, 1) == N60_STATUS_OK, "post a");
        CHECK(n60_graph_post_params(b, &rec, 1) == N60_STATUS_OK, "post b");
        const int part = (int)(rate * 0.001 / BLOCK) + 1; /* 1 block: well inside the 5 ms crossfade at most rates */
        for (int i = 0; i < part; i++) { double w = step(a, b); if (w > worst) worst = w; }
    }
    n60_rebuild_options ro;
    memset(&ro, 0, sizeof ro);
    ro.structSize = sizeof ro;
    ro.fadeMs = linearFade ? 20.0f : 0.0f;  /* 0: instant swap (exactly equal); else a linear fade of two equal signals */
    ro.reserved = linearFade ? 1u : 0u;
    CHECK(n60_graph_set_rebuild_options(a, &ro) == N60_STATUS_OK, "options");
    n60_graph_desc dc = desc(rate, p1, 62, (const float *)&unity, sc);
    CHECK(n60_graph_publish(a, &dc) == N60_STATUS_OK, "rate %.0f edit %d publish", rate, edit);
    double during = 0, after = 0;
    settle(a, b, &during);
    if (getenv("N60_VERBOSE")) fprintf(stderr, "rate %.0f edit %d: during rebuild %g\n", rate, edit, during);
    for (int i = 0; i < (int)(rate * 0.1 / BLOCK); i++) { double w = step(a, b); if (w > after) after = w; }
    const double tol = linearFade ? 1e-6 : 0.0;  /* instant swap: bit-identical; linear fade: float rounding of old*(1-t)+new*t */
    CHECK(during <= tol, "rate %.0f edit %d fade %d: rebuilt graph differs from the uninterrupted one during the rebuild (%g)", rate, edit, linearFade, during);
    CHECK(after <= tol, "rate %.0f edit %d fade %d: rebuilt graph differs from the uninterrupted one afterwards (%g)", rate, edit, linearFade, after);
    n60_graph_retire(a);
    n60_graph_retire(b);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; r++) {
        for (int f = 0; f < 2; f++) {
            testCarry(kRates[r], 0, f);
            testCarry(kRates[r], 1, f);
        }
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("ambient carry OK\n");
    return 0;
}
