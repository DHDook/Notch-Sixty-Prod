/* E4 S30a: the AMBIENT stage trailer (ABI v32): up to 17 live cut-only peaking sections after the three bands.
 * Eight standard rates. Checks: the realised response against the analytic cascade of the designed biquads at the 17
 * third-octave centres, never above 0 dB, live edits post (no rebuild) and never step faster than the ramp window,
 * bit-identity of no trailer and n = 0, the refusals, and a finite output on full-scale noise. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define MAXN 4096
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static const float kCentres[17] = {200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000};
static const float kQ = 4.32f;

static float bufIn[1][MAXN], bufOut[1][MAXN];

static n60_status build(double rate, const float *p, uint32_t np, n60_graph **g) {
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_AMBIENT;
    st.stageId = 1;
    st.laneA = N60_LANE_ALL;
    st.params = p;
    st.paramCount = np;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = MAXN;
    d.inputChannels = d.outputChannels = 1;
    d.stages = &st;
    d.stageCount = 1;
    return n60_graph_build(&d, g);
}

static void fillParams(float *p, const float *gains, int n, uint32_t *count) {
    const float base[10] = {0, 120, 0, 0.7f, 2200, 0, 1.0f, 6500, 0, 0.7f};
    memcpy(p, base, sizeof base);
    if (n < 0) { *count = 10; return; }
    p[10] = (float)n;
    for (int k = 0; k < n; k++) {
        p[11 + 3 * k] = kCentres[k];
        p[12 + 3 * k] = gains ? gains[k] : 0.0f;
        p[13 + 3 * k] = kQ;
    }
    *count = 11 + 3 * (uint32_t)n;
}

/* RBJ peaking magnitude in dB at f. */
static double peakDb(double rate, double f0, double db, double q, double f) {
    const double A = pow(10.0, db / 40.0), w0 = 2 * kPi * f0 / rate, al = sin(w0) / (2 * q), cw = cos(w0);
    const double b0 = 1 + al * A, b1 = -2 * cw, b2 = 1 - al * A, a0 = 1 + al / A, a1 = -2 * cw, a2 = 1 - al / A;
    const double w = 2 * kPi * f / rate, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    const double nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2), dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

static void block(n60_graph *g, uint32_t frames) {
    const float *ip[1] = {bufIn[0]};
    float *op[1] = {bufOut[0]};
    CHECK(n60_graph_process(g, ip, op, frames) == N60_STATUS_OK, "process");
}

/* Steady-state gain in dB of a tone at hz: Hann-windowed lock-in over the last eight blocks. */
static double measure(n60_graph *g, double rate, double hz, uint64_t *pos) {
    static float hist[8 * 1024];
    const uint32_t blocks = (uint32_t)ceil(rate * 0.6 / 1024.0) + 8;
    for (uint32_t b = 0; b < blocks; b++) {
        for (uint32_t i = 0; i < 1024; i++) bufIn[0][i] = (float)(0.25 * sin(2 * kPi * hz * (double)(*pos + i) / rate));
        const uint64_t start = *pos;
        *pos += 1024;
        block(g, 1024);
        if (b + 8 >= blocks) memcpy(hist + (b + 8 - blocks) * 1024, bufOut[0], 1024 * sizeof(float));
        (void)start;
    }
    const uint64_t base = *pos - 8 * 1024;
    double sr = 0, si = 0, w = 0;
    for (uint32_t i = 0; i < 8 * 1024; i++) {
        const double h = 0.5 - 0.5 * cos(2 * kPi * (double)i / (8 * 1024 - 1));
        const double ph = 2 * kPi * hz * (double)(base + i) / rate;
        sr += h * hist[i] * sin(ph);
        si += h * hist[i] * cos(ph);
        w += h;
    }
    return 20 * log10(2.0 * sqrt(sr * sr + si * si) / w / 0.25);
}

static void testResponse(double rate) {
    float gains[17], p[11 + 51];
    uint32_t np;
    for (int k = 0; k < 17; k++) gains[k] = -(float)((k * 5) % 7) * 1.0f;  /* a bumpy 0..-6 dB plan */
    fillParams(p, gains, 17, &np);
    n60_graph *g = NULL;
    CHECK(build(rate, p, np, &g) == N60_STATUS_OK, "rate %.0f build", rate);
    if (!g) return;
    uint64_t pos = 0;
    for (int k = 0; k < 17; k++) {
        double want = 0;
        for (int j = 0; j < 17; j++) want += peakDb(rate, kCentres[j], gains[j], kQ, kCentres[k]);
        const double got = measure(g, rate, kCentres[k], &pos);
        CHECK(fabs(got - want) < 0.1, "rate %.0f %g Hz: realised %.3f dB, analytic %.3f dB", rate, (double)kCentres[k], got, want);
        CHECK(got < 0.05, "rate %.0f %g Hz above 0 dB (%.3f)", rate, (double)kCentres[k], got);
    }
    for (int i = 0; i < 24; i++) {
        const double f = 30.0 * pow(0.45 * rate / 30.0, i / 23.0);
        if (f < 6.0 * rate / (8 * 1024)) continue;  /* the lock-in window holds under six cycles */
        const double got = measure(g, rate, f, &pos);
        double want = 0;
        for (int j = 0; j < 17; j++) want += peakDb(rate, kCentres[j], gains[j], kQ, f);
        CHECK(got < 0.05, "rate %.0f %.0f Hz above 0 dB (%.3f)", rate, f, got);
        CHECK(fabs(got - want) < 0.1, "rate %.0f %.0f Hz: realised %.3f dB, analytic %.3f dB", rate, f, got, want);
    }
    n60_graph_retire(g);
}

static void testLiveEdit(double rate) {
    float p[11 + 51];
    uint32_t np;
    fillParams(p, NULL, 17, &np);
    n60_graph *g = NULL;
    CHECK(build(rate, p, np, &g) == N60_STATUS_OK, "rate %.0f build live", rate);
    if (!g) return;
    const double f = 1000.0;
    uint64_t pos = 0;
    CHECK(fabs(measure(g, rate, f, &pos)) < 0.01, "rate %.0f flat before the edit", rate);
    /* 1000 Hz is section 8 (index 7): its dB is parameter 12 + 3 * 7. */
    n60_param_record rec = {1, 12 + 3 * 7, -6.0f, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "rate %.0f live dB post", rate);
    /* One block per cycle of the tone: the cycle peaks must fall no faster than the 5 ms crossfade allows. */
    const uint32_t cyc = (uint32_t)(rate / f + 0.5), ramp = (uint32_t)(rate * 0.005 + 0.5);
    double prev = 0.25, worst = 0;
    for (uint32_t b = 0; b < (uint32_t)(rate * 0.2 / cyc); b++) {
        for (uint32_t i = 0; i < cyc; i++) bufIn[0][i] = (float)(0.25 * sin(2 * kPi * f * (double)(pos + i) / rate));
        pos += cyc;
        block(g, cyc);
        double pk = 0;
        for (uint32_t i = 0; i < cyc; i++) if (fabs(bufOut[0][i]) > pk) pk = fabs(bufOut[0][i]);
        CHECK(pk <= 0.25 * 1.0005, "rate %.0f output above input during a cut (%.4f)", rate, pk);
        if (prev - pk > worst) worst = prev - pk;
        prev = pk;
    }
    CHECK(fabs(measure(g, rate, f, &pos) + 6.0) < 0.1, "rate %.0f settles at -6 dB", rate);
    CHECK(worst < 0.125 * ((double)cyc / ramp) * 1.5 + 0.01, "rate %.0f cycle-peak step %.4f exceeds the ramp slope", rate, worst);
    /* Frequency and Q posts are live too; the count is topology. */
    n60_param_record hz = {1, 11 + 3 * 7, 1100.0f, 0}, q = {1, 13 + 3 * 7, 3.0f, 0}, cnt = {1, 10, 5.0f, 0};
    CHECK(n60_graph_post_params(g, &hz, 1) == N60_STATUS_OK, "rate %.0f live Hz post", rate);
    CHECK(n60_graph_post_params(g, &q, 1) == N60_STATUS_OK, "rate %.0f live Q post", rate);
    CHECK(n60_graph_post_params(g, &cnt, 1) != N60_STATUS_OK, "rate %.0f count post refused", rate);
    n60_param_record boost = {1, 12 + 3 * 7, 1.0f, 0}, hi = {1, 11 + 3 * 7, (float)(rate * 0.46), 0};
    CHECK(n60_graph_post_params(g, &boost, 1) != N60_STATUS_OK, "rate %.0f boost refused", rate);
    CHECK(n60_graph_post_params(g, &hi, 1) != N60_STATUS_OK, "rate %.0f Hz above 0.45 fs refused", rate);
    /* The three bands are live as well. */
    n60_param_record band = {1, 5, 3.0f, 0};
    CHECK(n60_graph_post_params(g, &band, 1) == N60_STATUS_OK, "rate %.0f live band post", rate);
    n60_graph_retire(g);
}

static void testIdentityAndRefusals(double rate) {
    float p10[10], pn0[11], pn[11 + 51];
    uint32_t np;
    fillParams(p10, NULL, -1, &np);
    memcpy(pn0, p10, sizeof p10);
    pn0[10] = 0;
    float gains[17];
    for (int k = 0; k < 17; k++) gains[k] = 0.0f;
    fillParams(pn, gains, 17, &np);
    p10[1] = pn0[1] = pn[1] = 120; p10[2] = pn0[2] = pn[2] = 4; p10[5] = pn0[5] = pn[5] = -3; p10[8] = pn0[8] = pn[8] = 2;
    n60_graph *a = NULL, *b = NULL, *c = NULL;
    CHECK(build(rate, p10, 10, &a) == N60_STATUS_OK, "rate %.0f build v31 form", rate);
    CHECK(build(rate, pn0, 11, &b) == N60_STATUS_OK, "rate %.0f build n=0", rate);
    CHECK(build(rate, pn, 11 + 51, &c) == N60_STATUS_OK, "rate %.0f build 17 at 0 dB", rate);
    if (a && b && c) {
        static float oa[MAXN], ob[MAXN], oc[MAXN];
        uint32_t seed = 12345;
        for (int blk = 0; blk < 12; blk++) {
            for (uint32_t i = 0; i < 1024; i++) { seed = seed * 1664525u + 1013904223u; bufIn[0][i] = ((float)(seed >> 8) / 8388608.0f) - 1.0f; }
            block(a, 1024); memcpy(oa, bufOut[0], 1024 * sizeof(float));
            block(b, 1024); memcpy(ob, bufOut[0], 1024 * sizeof(float));
            block(c, 1024); memcpy(oc, bufOut[0], 1024 * sizeof(float));
            CHECK(memcmp(oa, ob, 1024 * sizeof(float)) == 0, "rate %.0f n=0 is not bit-identical to no trailer", rate);
            CHECK(memcmp(oa, oc, 1024 * sizeof(float)) == 0, "rate %.0f 17 sections at 0 dB is not bit-identical", rate);
        }
    }
    if (a) n60_graph_retire(a);
    if (b) n60_graph_retire(b);
    if (c) n60_graph_retire(c);
    /* Refusals at build: a boost, an out-of-range Hz, a bad count, a short list. */
    float bad[11 + 51];
    n60_graph *z = NULL;
    memcpy(bad, pn, sizeof pn);
    bad[12] = 1.0f;
    CHECK(build(rate, bad, 11 + 51, &z) != N60_STATUS_OK, "rate %.0f boost at build accepted", rate);
    memcpy(bad, pn, sizeof pn);
    bad[11 + 3 * 16] = (float)(rate * 0.46);
    CHECK(build(rate, bad, 11 + 51, &z) != N60_STATUS_OK, "rate %.0f Hz above 0.45 fs at build accepted", rate);
    memcpy(bad, pn, sizeof pn);
    bad[10] = 18.0f;
    CHECK(build(rate, bad, 11 + 51, &z) != N60_STATUS_OK, "rate %.0f count 18 accepted", rate);
    memcpy(bad, pn, sizeof pn);
    CHECK(build(rate, bad, 11 + 48, &z) != N60_STATUS_OK, "rate %.0f short list accepted", rate);
}

static void testNoise(double rate) {
    float gains[17], p[11 + 51];
    uint32_t np;
    for (int k = 0; k < 17; k++) gains[k] = -8.0f;
    fillParams(p, gains, 17, &np);
    n60_graph *g = NULL;
    CHECK(build(rate, p, np, &g) == N60_STATUS_OK, "rate %.0f noise build", rate);
    if (!g) return;
    uint32_t seed = 99;
    int finite = 1;
    double peak = 0;
    for (int blk = 0; blk < 40; blk++) {
        for (uint32_t i = 0; i < 1024; i++) { seed = seed * 1664525u + 1013904223u; bufIn[0][i] = (seed & 0x10000u) ? 1.0f : -1.0f; }
        if (blk == 10) { n60_param_record r = {1, 12, 0.0f, 0}; n60_graph_post_params(g, &r, 1); }
        block(g, 1024);
        for (uint32_t i = 0; i < 1024; i++) { if (!isfinite(bufOut[0][i])) finite = 0; if (fabs(bufOut[0][i]) > peak) peak = fabs(bufOut[0][i]); }
    }
    CHECK(finite, "rate %.0f full-scale noise not finite", rate);
    CHECK(peak < 4.0, "rate %.0f noise peak %.3f", rate, peak);
    n60_graph_retire(g);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; r++) {
        testResponse(kRates[r]);
        testLiveEdit(kRates[r]);
        testIdentityAndRefusals(kRates[r]);
        testNoise(kRates[r]);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("ambient sections OK\n");
    return 0;
}
