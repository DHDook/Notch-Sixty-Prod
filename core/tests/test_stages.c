/*
 * E6 S3: behavioural harness for the libn60core snapshot swap, parameter mailbox
 * and the basic lane stages, through the C ABI at the eight standard rates.
 * Every stage is checked against an independent reference written here.
 */
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
#define NRATES (sizeof kRates / sizeof kRates[0])
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

/* ---- helpers --------------------------------------------------------------- */

static n60_graph_desc makeDesc(double rate, uint32_t maxBlock, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = maxBlock;
    d.inputChannels = ch;
    d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    return d;
}

static n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t lane, const float *params, uint32_t np) {
    n60_stage_desc s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = lane;
    s.params = params;
    s.paramCount = np;
    return s;
}

static n60_graph *buildOrDie(double rate, uint32_t maxBlock, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d = makeDesc(rate, maxBlock, ch, st, n);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build status %d", s);
    return g;
}

static uint32_t rampFrames(double rate) {
    long f = lround(0.005 * rate);
    return f < 32 ? 32 : (f > 4096 ? 4096 : (uint32_t)f);
}

/* Deterministic pseudo-noise in [-0.5, 0.5]. */
static uint32_t rngState = 12345;
static float noise(void) {
    rngState = rngState * 1664525u + 1013904223u;
    return (float)((rngState >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}

/* Render `total` frames of `ch` lanes from `src` in blocks of `block`. */
static void render(n60_graph *g, float **src, float **dst, uint32_t ch, uint32_t total, uint32_t block) {
    const float *in[N60_GRAPH_MAX_CHANNELS];
    float *out[N60_GRAPH_MAX_CHANNELS];
    for (uint32_t pos = 0; pos < total; pos += block) {
        uint32_t n = total - pos < block ? total - pos : block;
        for (uint32_t c = 0; c < ch; c++) { in[c] = src[c] + pos; out[c] = dst[c] + pos; }
        n60_status s = n60_graph_process(g, in, out, n);
        CHECK(s == N60_STATUS_OK, "process %d", s);
    }
}

static float **alloc2d(uint32_t ch, uint32_t n) {
    float **p = calloc(ch, sizeof *p);
    for (uint32_t c = 0; c < ch; c++) p[c] = calloc(n, sizeof(float));
    return p;
}
static void free2d(float **p, uint32_t ch) {
    for (uint32_t c = 0; c < ch; c++) free(p[c]);
    free(p);
}

/* ---- sanitise and meters --------------------------------------------------- */

static void testSanitiseAndMeters(double rate) {
    enum { N = 1000, CH = 2 };
    n60_stage_desc st[3] = {
        stage(N60_STAGE_SANITISE, 1, N60_LANE_ALL, NULL, 0),
        stage(N60_STAGE_METER_IN, 2, N60_LANE_ALL, NULL, 0),
        stage(N60_STAGE_METER_OUT, 3, 1, NULL, 0),
    };
    n60_graph *g = buildOrDie(rate, 512, CH, st, 3);
    float **in = alloc2d(CH, N), **out = alloc2d(CH, N);
    for (int c = 0; c < CH; c++)
        for (int i = 0; i < N; i++) in[c][i] = 0.25f * (float)sin(2 * M_PI * 1000 * i / rate) * (c + 1);
    in[0][7] = NAN;
    in[0][8] = INFINITY;
    in[1][9] = -INFINITY;
    render(g, in, out, CH, N, 512);
    n60_graph_stats stats;
    n60_graph_get_stats(g, &stats);
    CHECK(stats.sanitisedSamples == 3, "sanitised %llu", (unsigned long long)stats.sanitisedSamples);
    CHECK(out[0][7] == 0 && out[0][8] == 0 && out[1][9] == 0, "non-finite became zero");
    CHECK(out[0][6] == in[0][6] && out[1][10] == in[1][10], "finite samples untouched");
    /* The meter after sanitise sees only finite samples; compare with a reference
     * for the last block of 488 frames (512 + 488). */
    float peak, rms;
    CHECK(n60_graph_read_meter(g, 2, 1, &peak, &rms) == N60_STATUS_OK, "read meter");
    double rpeak = 0;
    for (int i = 0; i < N; i++) rpeak = fmax(rpeak, fabs(out[1][i]));
    CHECK(peak == (float)rpeak, "peak %g vs %g", peak, rpeak);
    double sum = 0;
    for (int i = 512; i < N; i++) sum += (double)out[1][i] * out[1][i];
    CHECK(fabs(rms - sqrt(sum / (N - 512))) < 1e-6, "rms %g vs %g", rms, sqrt(sum / (N - 512)));
    CHECK(n60_graph_read_meter(g, 2, 1, &peak, &rms) == N60_STATUS_OK && peak == 0.0f, "peak resets on read");
    CHECK(n60_graph_read_meter(g, 3, 0, &peak, &rms) == N60_STATUS_BAD_ARGUMENT, "lane not covered by the meter");
    CHECK(n60_graph_read_meter(g, 1, 0, &peak, &rms) == N60_STATUS_BAD_ARGUMENT, "not a meter stage");
    free2d(in, CH);
    free2d(out, CH);
    n60_graph_retire(g);
}

/* ---- gain ------------------------------------------------------------------ */

static void testGain(double rate) {
    enum { CH = 2, N = 20000 };
    float g0 = 0.5f;
    n60_stage_desc st[1] = {stage(N60_STAGE_GAIN, 10, N60_LANE_ALL, &g0, 1)};
    n60_graph *g = buildOrDie(rate, 4096, CH, st, 1);
    float **in = alloc2d(CH, N), **out = alloc2d(CH, N);
    for (int c = 0; c < CH; c++)
        for (int i = 0; i < N; i++) in[c][i] = 1.0f;
    render(g, in, out, CH, 100, 100);
    CHECK(out[0][0] == 0.5f && out[1][99] == 0.5f, "constant gain is exact");
    n60_param_record rec = {10, 0, 2.0f, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post gain");
    render(g, in, out, CH, N, 333);
    uint32_t ramp = rampFrames(rate);
    /* Linear ramp from 0.5 to 2.0 over `ramp` frames, then exactly 2.0. */
    CHECK(out[0][ramp + 5] == 2.0f && out[1][N - 1] == 2.0f, "ramp ends at the target");
    double maxStep = 0;
    for (int i = 1; i < N; i++) maxStep = fmax(maxStep, fabs(out[0][i] - out[0][i - 1]));
    double expected = 1.5 / ramp;
    CHECK(maxStep < expected * 1.01 + 1e-6, "step %g above ramp slope %g", maxStep, expected);
    int mono = 1;
    for (int i = 1; i < N; i++) if (out[0][i] < out[0][i - 1]) mono = 0;
    CHECK(mono, "ramp is monotone");
    CHECK(out[0][ramp / 2] > 0.5f && out[0][ramp / 2] < 2.0f, "mid-ramp value is between targets");
    CHECK(out[0][0] > 0.5f, "ramp starts at the first sample");
    free2d(in, CH);
    free2d(out, CH);
    n60_graph_retire(g);
}

static void refPeq(const float *params, int sections, double rate, const float *in, float *out, int n);

/* ---- mid/side -------------------------------------------------------------- */

static void testMidSide(double rate) {
    enum { N = 3001 };
    /* Encode, filter only lane 0 (the mid), decode; compare with M = (L+R)/2, S = (L-R)/2
     * computed in the reference. A filter on the mid alone moves L and R together. */
    float k = (float)(rate / 48000.0);
    float peq[4] = {0, 1000 * k, 9, 1.0f};
    n60_stage_desc ms[3] = {stage(N60_STAGE_MS_ENCODE, 1, 0, NULL, 0), stage(N60_STAGE_PEQ, 2, 0, peq, 4),
                            stage(N60_STAGE_MS_DECODE, 3, 0, NULL, 0)};
    ms[0].laneB = 1;
    ms[2].laneB = 1;
    n60_graph *g = buildOrDie(rate, 700, 2, ms, 3);
    float **in = alloc2d(2, N), **out = alloc2d(2, N);
    float *mid = calloc(N, sizeof(float)), *midOut = calloc(N, sizeof(float));
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < N; i++) in[c][i] = noise();
    render(g, in, out, 2, N, 700);
    for (int i = 0; i < N; i++) mid[i] = 0.5f * (in[0][i] + in[1][i]);
    refPeq(peq, 1, rate, mid, midOut, N);
    double conv = 0;
    for (int i = 0; i < N; i++) {
        float side = 0.5f * (in[0][i] - in[1][i]);
        conv = fmax(conv, fmax(fabs(out[0][i] - (midOut[i] + side)), fabs(out[1][i] - (midOut[i] - side))));
    }
    CHECK(conv < 1e-6, "M/S convention differs by %g", conv);
    free(mid);
    free(midOut);
    n60_graph_retire(g);

    n60_stage_desc both[2] = {stage(N60_STAGE_MS_ENCODE, 1, 0, NULL, 0), stage(N60_STAGE_MS_DECODE, 2, 0, NULL, 0)};
    both[0].laneB = 1;
    both[1].laneB = 1;
    g = buildOrDie(rate, 700, 2, both, 2);
    render(g, in, out, 2, N, 700);
    double worst = 0;
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < N; i++) worst = fmax(worst, fabs(out[c][i] - in[c][i]));
    CHECK(worst < 2e-7, "encode then decode returns the input (%g)", worst);
    n60_graph_retire(g);
    free2d(in, 2);
    free2d(out, 2);
}

/* ---- PEQ ------------------------------------------------------------------- */

static void refCoefs(int type, double rate, double f, double dB, double q, double c[5]) {
    double w = 2 * M_PI * f / rate, cw = cos(w), sw = sin(w), al = sw / (2 * q);
    double A = pow(10.0, dB / 40.0), beta = 2 * sqrt(A) * al;
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
    case 0: b0 = 1 + al * A; b1 = -2 * cw; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * cw; a2 = 1 - al / A; break;
    case 1: b0 = A * ((A + 1) - (A - 1) * cw + beta); b1 = 2 * A * ((A - 1) - (A + 1) * cw);
            b2 = A * ((A + 1) - (A - 1) * cw - beta); a0 = (A + 1) + (A - 1) * cw + beta;
            a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - beta; break;
    case 2: b0 = A * ((A + 1) + (A - 1) * cw + beta); b1 = -2 * A * ((A - 1) + (A + 1) * cw);
            b2 = A * ((A + 1) + (A - 1) * cw - beta); a0 = (A + 1) - (A - 1) * cw + beta;
            a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - beta; break;
    case 3: b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; break;
    case 4: b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; break;
    case 5: b0 = 1; b1 = -2 * cw; b2 = 1; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; break;
    case 6: b0 = 1 - al; b1 = -2 * cw; b2 = 1 + al; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; break;
    default: b0 = al; b1 = 0; b2 = -al; a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al; break;
    }
    c[0] = b0 / a0; c[1] = b1 / a0; c[2] = b2 / a0; c[3] = a1 / a0; c[4] = a2 / a0;
}

/* Direct form I in double: a different structure from the core's transposed form II. */
static void refPeq(const float *params, int sections, double rate, const float *in, float *out, int n) {
    double x1[16] = {0}, x2[16] = {0}, y1[16] = {0}, y2[16] = {0}, c[16][5];
    for (int s = 0; s < sections; s++) refCoefs((int)params[4 * s], rate, params[4 * s + 1], params[4 * s + 2], params[4 * s + 3], c[s]);
    for (int i = 0; i < n; i++) {
        double x = in[i];
        for (int s = 0; s < sections; s++) {
            double y = c[s][0] * x + c[s][1] * x1[s] + c[s][2] * x2[s] - c[s][3] * y1[s] - c[s][4] * y2[s];
            x2[s] = x1[s]; x1[s] = x; y2[s] = y1[s]; y1[s] = y;
            x = y;
        }
        out[i] = (float)x;
    }
}

static void testPeq(double rate) {
    enum { N = 6000 };
    /* One section of every type, cascaded, scaled with the rate so the poles sit at
     * the same normalised place at every rate (as the parity harness does). */
    float k = (float)(rate / 48000.0);
    float params[8 * 4] = {
        0, 1000 * k, 6, 1.2f,   1, 200 * k, -5, 0.8f,  2, 6000 * k, 4, 0.9f, 3, 9000 * k, 0, 0.707f,
        4, 80 * k, 0, 0.707f,   5, 3000 * k, 0, 4,      6, 500 * k, 0, 1,     7, 2000 * k, 0, 2,
    };
    for (int sections = 1; sections <= 8; sections += 7) {
        n60_stage_desc st[1] = {stage(N60_STAGE_PEQ, 5, N60_LANE_ALL, params, 4 * sections)};
        n60_graph *g = buildOrDie(rate, 1024, 2, st, 1);
        float **in = alloc2d(2, N), **out = alloc2d(2, N), *ref = calloc(N, sizeof(float));
        for (int c = 0; c < 2; c++)
            for (int i = 0; i < N; i++) in[c][i] = noise();
        render(g, in, out, 2, N, 977);
        double worst = 0;
        for (int c = 0; c < 2; c++) {
            refPeq(params, sections, rate, in[c], ref, N);
            for (int i = 0; i < N; i++) worst = fmax(worst, fabs(out[c][i] - ref[i]));
        }
        CHECK(worst < 1e-6, "PEQ %d sections at %.0f differs by %g", sections, rate, worst);
        n60_graph_retire(g);

        /* Block-size invariance: the same input in blocks of 1 and 1024 is bit identical. */
        float **out2 = alloc2d(2, N);
        g = buildOrDie(rate, 1024, 2, st, 1);
        render(g, in, out2, 2, N, 1);
        int same = 1;
        for (int c = 0; c < 2; c++)
            for (int i = 0; i < N; i++) if (out[c][i] != out2[c][i]) same = 0;
        CHECK(same, "PEQ output depends on block size");
        n60_graph_retire(g);
        free2d(in, 2); free2d(out, 2); free2d(out2, 2); free(ref);
    }
}

/* ---- delay and latency ------------------------------------------------------ */

static void testDelay(double rate) {
    enum { N = 4000 };
    float d0 = 25;
    n60_stage_desc st[1] = {stage(N60_STAGE_DELAY, 20, N60_LANE_ALL, &d0, 1)};
    st[0].capacityFrames = 1000;
    n60_graph *g = buildOrDie(rate, 512, 2, st, 1);
    CHECK(n60_graph_latency_frames(g) == 25, "latency %u", n60_graph_latency_frames(g));
    float **in = alloc2d(2, N), **out = alloc2d(2, N);
    in[0][0] = 1.0f;
    in[1][3] = -0.5f;
    render(g, in, out, 2, N, 512);
    int ok = 1;
    for (int i = 0; i < N; i++) {
        if (out[0][i] != (i == 25 ? 1.0f : 0.0f)) ok = 0;
        if (out[1][i] != (i == 28 ? -0.5f : 0.0f)) ok = 0;
    }
    CHECK(ok, "impulse emerges exactly 25 frames late");
    n60_graph_retire(g);

    /* A live change crossfades two taps: ramp input, every output is a blend of the
     * two delayed ramps, so it never steps by more than the ramp slope allows. */
    g = buildOrDie(rate, 512, 1, st, 1);
    for (int i = 0; i < N; i++) in[0][i] = (float)i;
    render(g, in, out, 1, 1000, 512);
    n60_param_record rec = {20, 0, 400, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post delay");
    float **in1 = in;
    float *shifted[1] = {in[0] + 1000};
    float *o1[1] = {out[0] + 1000};
    render(g, shifted, o1, 1, N - 1000, 300);
    (void)in1;
    CHECK(n60_graph_latency_frames(g) == 400, "latency follows the target (%u)", n60_graph_latency_frames(g));
    uint32_t ramp = rampFrames(rate);
    double maxStep = 0;
    for (int i = 1000; i < N; i++) maxStep = fmax(maxStep, fabs(out[0][i] - out[0][i - 1]));
    double bound = 1.0 + (400.0 - 25.0) / ramp + 1e-3;
    CHECK(maxStep <= bound, "delay change stepped %g, bound %g", maxStep, bound);
    CHECK(out[0][N - 1] == (float)(N - 1 - 400), "settles on the new delay");
    rec.value = 2000; /* above capacity */
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_BAD_ARGUMENT, "delay above capacity rejected");

    /* Two stages on one lane add up. */
    n60_graph_retire(g);
    float da = 10, db = 30;
    n60_stage_desc two[2] = {stage(N60_STAGE_DELAY, 1, 0, &da, 1), stage(N60_STAGE_DELAY, 2, 0, &db, 1)};
    two[0].capacityFrames = 64;
    two[1].capacityFrames = 64;
    g = buildOrDie(rate, 512, 2, two, 2);
    CHECK(n60_graph_latency_frames(g) == 40, "latency adds along a lane (%u)", n60_graph_latency_frames(g));
    n60_graph_retire(g);
    free2d(in, 2);
    free2d(out, 2);
}

/* ---- snapshot swap and mailbox --------------------------------------------- */

static void testSwapAndRetire(double rate) {
    enum { N = 256 };
    float g1 = 0.5f, g2 = 2.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &g1, 1)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &g2, 1), stage(N60_STAGE_METER_OUT, 9, 0, NULL, 0)};
    n60_graph *g = buildOrDie(rate, N, 2, a, 1);
    n60_graph_desc db = makeDesc(rate, N, 2, b, 2);
    float **in = alloc2d(2, N), **out = alloc2d(2, N);
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < N; i++) in[c][i] = 1.0f;
    render(g, in, out, 2, N, N);
    CHECK(out[0][N - 1] == 0.5f, "first snapshot renders");
    n60_graph_stats s;
    n60_graph_get_stats(g, &s);
    CHECK(s.liveEpoch == 1 && s.publishedEpoch == 1, "epochs start at 1");

    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    n60_graph_get_stats(g, &s);
    CHECK(s.liveEpoch == 1 && s.publishedEpoch == 2, "published but not yet adopted");
    CHECK(n60_graph_collect(g) == 0, "nothing retired before the realtime thread swaps");
    render(g, in, out, 2, N, N);
    n60_graph_get_stats(g, &s);
    CHECK(s.liveEpoch == 2, "adopted on the next block");
    CHECK(out[0][N - 1] == 2.0f, "new topology renders (fresh state, no ramp)");
    CHECK(n60_graph_collect(g) == 1, "old snapshot handed back and freed on the control thread");
    CHECK(n60_graph_collect(g) == 0, "collect is idempotent");

    /* Two publishes before one block: the first never renders and is freed at once. */
    n60_graph_desc da = makeDesc(rate, N, 2, a, 1);
    CHECK(n60_graph_publish(g, &da) == N60_STATUS_OK && n60_graph_publish(g, &db) == N60_STATUS_OK, "double publish");
    render(g, in, out, 2, N, N);
    n60_graph_get_stats(g, &s);
    CHECK(s.liveEpoch == 4, "only the newest snapshot renders (epoch %u)", s.liveEpoch);
    CHECK(n60_graph_collect(g) == 1, "one retired");

    /* Fixed fields cannot change through publish; a bad description leaves the graph alone. */
    n60_graph_desc other = makeDesc(rate * 2, N, 2, a, 1);
    CHECK(n60_graph_publish(g, &other) == N60_STATUS_BAD_ARGUMENT, "rate change needs a new graph");
    other = makeDesc(rate, N, 3, a, 1);
    CHECK(n60_graph_publish(g, &other) == N60_STATUS_BAD_ARGUMENT, "channel change needs a new graph");
    n60_stage_desc bad[1] = {stage(N60_STAGE_GAIN, 1, 7, &g1, 1)};
    other = makeDesc(rate, N, 2, bad, 1);
    CHECK(n60_graph_publish(g, &other) == N60_STATUS_BAD_ARGUMENT, "bad lane rejected");
    render(g, in, out, 2, N, N);
    CHECK(out[0][N - 1] == 2.0f, "failed publishes changed nothing");

    /* The retire queue refuses publishes instead of overflowing when nobody collects. */
    int refused = 0;
    for (int i = 0; i < 40; i++) {
        n60_status st = n60_graph_publish(g, &da);
        if (st == N60_STATUS_QUEUE_FULL) { refused = 1; break; }
        render(g, in, out, 2, N, N);
    }
    CHECK(refused, "publish refused while the retire queue is full");
    CHECK(n60_graph_collect(g) > 0, "collect drains the queue");
    CHECK(n60_graph_publish(g, &da) == N60_STATUS_OK, "publish works again after collect");
    free2d(in, 2);
    free2d(out, 2);
    n60_graph_retire(g);
}

static void testMailbox(double rate) {
    enum { N = 4096 };
    float g0 = 0.5f, d0 = 0;
    n60_stage_desc st[3] = {
        stage(N60_STAGE_GAIN, 1, 0, &g0, 1),
        stage(N60_STAGE_PEQ, 2, 0, (const float[]){0, 1000, 3, 1}, 4),
        stage(N60_STAGE_DELAY, 3, 0, &d0, 1),
    };
    st[2].capacityFrames = 100;
    n60_graph *g = buildOrDie(rate, N, 1, st, 3);
    float **in = alloc2d(1, N), **out = alloc2d(1, N);
    for (int i = 0; i < N; i++) in[0][i] = 1.0f;

    /* Coalescing: three targets before one block, only the last is ramped to. */
    n60_param_record recs[3] = {{1, 0, 0.1f, 0}, {1, 0, 0.9f, 0}, {1, 0, 1.5f, 0}};
    CHECK(n60_graph_post_params(g, recs, 3) == N60_STATUS_OK, "post three");
    render(g, in, out, 1, N, N);
    /* Only the PEQ-free comparison: the PEQ at unity gain is not in the chain here, so
     * compare against gain only by removing it from the expectation: skip. */
    n60_graph_stats s;
    n60_graph_get_stats(g, &s);
    CHECK(s.paramsApplied == 3, "applied %llu", (unsigned long long)s.paramsApplied);
    free2d(in, 1);
    free2d(out, 1);
    n60_graph_retire(g);

    /* Same, without the filter: output must rise monotonically to exactly 1.5. */
    n60_stage_desc only[1] = {stage(N60_STAGE_GAIN, 1, 0, &g0, 1)};
    g = buildOrDie(rate, N, 1, only, 1);
    in = alloc2d(1, N); out = alloc2d(1, N);
    for (int i = 0; i < N; i++) in[0][i] = 1.0f;
    CHECK(n60_graph_post_params(g, recs, 3) == N60_STATUS_OK, "post three");
    render(g, in, out, 1, N, N);
    int mono = 1;
    float prev = 0.5f;
    for (int i = 0; i < N; i++) { if (out[0][i] < prev) mono = 0; prev = out[0][i]; }
    CHECK(mono, "coalesced: no excursion toward the intermediate targets");
    CHECK(out[0][N - 1] == 1.5f, "coalesced: ends exactly on the last value");

    /* Rejections. */
    n60_param_record pe = {2, 0, 1.0f, 0};
    CHECK(n60_graph_post_params(g, &pe, 1) == N60_STATUS_BAD_ARGUMENT, "unknown stage");
    n60_param_record badv = {1, 0, NAN, 0};
    CHECK(n60_graph_post_params(g, &badv, 1) == N60_STATUS_BAD_ARGUMENT, "NaN value");
    n60_param_record neg = {1, 0, -1.0f, 0};
    CHECK(n60_graph_post_params(g, &neg, 1) == N60_STATUS_BAD_ARGUMENT, "negative gain");
    n60_param_record idx = {1, 1, 1.0f, 0};
    CHECK(n60_graph_post_params(g, &idx, 1) == N60_STATUS_BAD_ARGUMENT, "parameter index out of range");
    n60_param_record rsv = {1, 0, 1.0f, 1};
    CHECK(n60_graph_post_params(g, &rsv, 1) == N60_STATUS_BAD_ARGUMENT, "reserved must be zero");
    n60_param_record mixed[2] = {{1, 0, 0.25f, 0}, {99, 0, 1.0f, 0}};
    CHECK(n60_graph_post_params(g, mixed, 2) == N60_STATUS_BAD_ARGUMENT, "batch with one bad record");
    render(g, in, out, 1, 64, 64);
    CHECK(out[0][63] == 1.5f, "rejected batch applied nothing");
    n60_graph_stats st2;
    n60_graph_get_stats(g, &st2);
    CHECK(st2.paramsApplied == 3, "applied count %llu", (unsigned long long)st2.paramsApplied);

    /* A full mailbox refuses the whole batch. */
    n60_param_record *many = calloc(2000, sizeof *many);
    for (int i = 0; i < 2000; i++) { many[i].stageId = 1; many[i].value = 1.0f; }
    CHECK(n60_graph_post_params(g, many, 1024) == N60_STATUS_OK, "1024 records fit");
    CHECK(n60_graph_post_params(g, many, 1) == N60_STATUS_QUEUE_FULL, "mailbox full");
    render(g, in, out, 1, 64, 64);
    CHECK(n60_graph_post_params(g, many, 1000) == N60_STATUS_OK, "room again after the callback drained it");
    free(many);

    /* A publish discards edits posted for the superseded snapshot. */
    float g9 = 0.75f;
    n60_stage_desc re[1] = {stage(N60_STAGE_GAIN, 1, 0, &g9, 1)};
    n60_graph_desc rd = makeDesc(rate, N, 1, re, 1);
    render(g, in, out, 1, 64, 64); /* drain whatever is left */
    n60_param_record stale = {1, 0, 0.1f, 0};
    CHECK(n60_graph_post_params(g, &stale, 1) == N60_STATUS_OK, "post before publish");
    CHECK(n60_graph_publish(g, &rd) == N60_STATUS_OK, "publish");
    n60_param_record fresh = {1, 0, 0.3f, 0};
    n60_graph_get_stats(g, &st2);
    uint64_t droppedBefore = st2.paramsDropped;
    render(g, in, out, 1, 64, 64);
    n60_graph_get_stats(g, &st2);
    CHECK(st2.paramsDropped == droppedBefore + 1, "stale record dropped");
    CHECK(out[0][63] == 0.75f, "new snapshot keeps its own initial value (%g)", out[0][63]);
    CHECK(n60_graph_post_params(g, &fresh, 1) == N60_STATUS_OK, "post after publish");
    render(g, in, out, 1, N, N);
    CHECK(out[0][N - 1] == 0.3f, "record posted after the publish applies");
    free2d(in, 1);
    free2d(out, 1);
    n60_graph_retire(g);

    /* Parameters that need a new topology are refused, not half applied. */
    g = buildOrDie(rate, N, 1, st, 3);
    n60_param_record peq = {2, 0, 1.0f, 0};
    CHECK(n60_graph_post_params(g, &peq, 1) == N60_STATUS_UNSUPPORTED, "PEQ edit needs a topology publish");
    n60_graph_retire(g);
}

/* ---- validation ------------------------------------------------------------ */

static void testValidation(double rate) {
    float one = 1.0f, f4[4] = {0, 1000, 0, 1};
    n60_graph *g = NULL;
    n60_stage_desc s2[2];
    n60_graph_desc d;

    s2[0] = stage(N60_STAGE_PEQ, 1, 0, f4, 4);
    s2[1] = stage(N60_STAGE_GAIN, 2, 0, &one, 1);
    d = makeDesc(rate, 64, 2, s2, 2);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT && g == NULL, "stages out of the fixed order");

    s2[0] = stage(N60_STAGE_GAIN, 1, 0, &one, 1);
    s2[1] = stage(N60_STAGE_GAIN, 1, 1, &one, 1);
    d = makeDesc(rate, 64, 2, s2, 2);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "duplicate stage id");

    s2[0] = stage(N60_STAGE_MS_ENCODE, 1, 0, NULL, 0);
    s2[0].laneB = 1;
    d = makeDesc(rate, 64, 2, s2, 1);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "encode without decode");
    s2[0] = stage(N60_STAGE_MS_DECODE, 1, 0, NULL, 0);
    s2[0].laneB = 1;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "decode without encode");
    s2[0] = stage(N60_STAGE_MS_ENCODE, 1, 0, NULL, 0);
    s2[0].laneB = 0;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "M/S on one lane");

    float badq[4] = {0, 1000, 0, 0};
    s2[0] = stage(N60_STAGE_PEQ, 1, 0, badq, 4);
    d = makeDesc(rate, 64, 2, s2, 1);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "PEQ with Q = 0");
    float nyq[4] = {0, (float)(rate * 0.5), 0, 1};
    s2[0] = stage(N60_STAGE_PEQ, 1, 0, nyq, 4);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "PEQ at Nyquist");
    float hot[4] = {0, 1000, 30, 1};
    s2[0] = stage(N60_STAGE_PEQ, 1, 0, hot, 4);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "PEQ gain out of range");
    float ty[4] = {9, 1000, 0, 1};
    s2[0] = stage(N60_STAGE_PEQ, 1, 0, ty, 4);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "unknown PEQ type");
    float five[5] = {0, 1000, 0, 1, 0};
    s2[0] = stage(N60_STAGE_PEQ, 1, 0, five, 5);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "PEQ parameter count not a multiple of 4");
    s2[0] = stage(N60_STAGE_GAIN, 1, 0, &one, 1);
    s2[0].structSize = 4;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH, "stage struct size");
    float nan = NAN;
    s2[0] = stage(N60_STAGE_GAIN, 1, 0, &nan, 1);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "NaN parameter");
    float big = 5000;
    s2[0] = stage(N60_STAGE_DELAY, 1, 0, &big, 1);
    s2[0].capacityFrames = 100;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "delay above capacity");
    CHECK(g == NULL, "no graph after a failed build");
}

/* ---- concurrent publish, post and process ---------------------------------- */

typedef struct { n60_graph *g; atomic_int stop; int bad; } Shared;

static void *rtThread(void *arg) {
    Shared *sh = arg;
    enum { N = 128 };
    float in0[N], in1[N], out0[N], out1[N];
    for (int i = 0; i < N; i++) { in0[i] = 0.5f; in1[i] = -0.5f; }
    const float *in[2] = {in0, in1};
    float *out[2] = {out0, out1};
    while (!atomic_load(&sh->stop)) {
        if (n60_graph_process(sh->g, in, out, N) != N60_STATUS_OK) sh->bad = 1;
        for (int i = 0; i < N; i++)
            if (!isfinite(out0[i]) || !isfinite(out1[i]) || fabsf(out0[i]) > 100.0f) sh->bad = 1;
    }
    return NULL;
}

static void testConcurrency(void) {
    float one = 1.0f, two = 2.0f, d = 16;
    n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &one, 1), stage(N60_STAGE_METER_OUT, 5, 0, NULL, 0)};
    n60_stage_desc b[3] = {stage(N60_STAGE_SANITISE, 7, N60_LANE_ALL, NULL, 0), stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &two, 1),
                           stage(N60_STAGE_DELAY, 3, 1, &d, 1)};
    b[2].capacityFrames = 64;
    n60_graph *g = buildOrDie(48000, 128, 2, a, 2);
    n60_graph_desc da = makeDesc(48000, 128, 2, a, 2), db = makeDesc(48000, 128, 2, b, 3);
    Shared sh = {g, 0, 0};
    pthread_t t;
    pthread_create(&t, NULL, rtThread, &sh);
    int published = 0;
    for (int i = 0; i < 3000; i++) {
        n60_status st = n60_graph_publish(g, (i & 1) ? &db : &da);
        if (st == N60_STATUS_OK) published++;
        else CHECK(st == N60_STATUS_QUEUE_FULL, "publish status %d", st);
        n60_param_record r = {1, 0, (i % 7) * 0.25f, 0};
        n60_graph_post_params(g, &r, 1);
        float pk, rms;
        n60_graph_read_meter(g, 5, 0, &pk, &rms);
        n60_graph_collect(g);
    }
    atomic_store(&sh.stop, 1);
    pthread_join(t, NULL);
    CHECK(!sh.bad, "realtime thread saw a bad status or a non-finite sample");
    CHECK(published > 100, "only %d publishes succeeded", published);
    n60_graph_retire(g);
}

int main(void) {
    for (size_t r = 0; r < NRATES; r++) {
        double rate = kRates[r];
        testSanitiseAndMeters(rate);
        testGain(rate);
        testMidSide(rate);
        testPeq(rate);
        testDelay(rate);
        testSwapAndRetire(rate);
        testMailbox(rate);
        testValidation(rate);
    }
    testConcurrency();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("n60core stages, swap and mailbox: all checks passed");
    return 0;
}
