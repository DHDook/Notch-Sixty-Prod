/* E6 S6: deterministic tests for live (ramped) parameter edits and the faded topology rebuild,
 * through the C ABI at the eight standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
 *
 * Click-free checks bound the largest sample-to-sample step against the slope of the signal that
 * is playing; a click is a discontinuity many times that slope. The crossfade law, the failed
 * build, the NaN cancel, the CPU-budget refusal and the ANC mute rules are checked exactly. */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "n60/graph.h"

#define BLOCK 200u
#define MAXN 512u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static n60_stage_desc stg(uint32_t kind, uint32_t id, uint32_t laneA, const float *p, uint32_t np) {
    n60_stage_desc s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.params = p;
    s.paramCount = np;
    return s;
}
static n60_stage_desc stgMask(uint32_t kind, uint32_t id, uint64_t mask, const float *p, uint32_t np) {
    n60_stage_desc s = stg(kind, id, 0, p, np);
    s.laneMask = mask;
    return s;
}
static n60_stage_desc stgPair(uint32_t kind, uint32_t id, uint32_t a, uint32_t b, const float *p, uint32_t np) {
    n60_stage_desc s = stg(kind, id, a, p, np);
    s.laneB = b;
    return s;
}

static n60_graph_desc desc(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = MAXN;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    return d;
}

static n60_graph *build(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d = desc(rate, ch, st, n);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build status %d", s);
    return g;
}

static n60_rebuild_status status(n60_graph *g) {
    n60_rebuild_status s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    CHECK(n60_graph_get_rebuild_status(g, &s) == N60_STATUS_OK, "rebuild status");
    return s;
}

static void post(n60_graph *g, uint32_t stageId, uint32_t idx, float v) {
    n60_param_record r = {stageId, idx, v, 0};
    n60_status s = n60_graph_post_params(g, &r, 1);
    CHECK(s == N60_STATUS_OK, "post %u/%u = %g gave %d", stageId, idx, v, s);
}

/* Streaming source: one signal per channel, continuous across blocks. */
typedef struct {
    double rate;
    uint32_t ch;
    uint64_t pos;
    double freq[4], amp[4];
    int noise[4];
    uint32_t rng;
    float in[4][MAXN], out[4][MAXN];
    float nanAt;  /* >= 0: sample index (absolute) on channel 0 replaced by NaN */
} Src;

static float rnd(Src *s) {
    s->rng = s->rng * 1664525u + 1013904223u;
    return (float)((double)(s->rng >> 8) / 8388608.0 - 1.0);
}

static void srcInit(Src *s, double rate, uint32_t ch) {
    memset(s, 0, sizeof *s);
    s->rate = rate;
    s->ch = ch;
    s->rng = 12345u;
    s->nanAt = -1.0f;
}

static n60_status step(n60_graph *g, Src *s, uint32_t frames) {
    const float *ip[4];
    float *op[4];
    for (uint32_t c = 0; c < s->ch; c++) {
        for (uint32_t i = 0; i < frames; i++) {
            s->in[c][i] = s->noise[c] ? (float)(s->amp[c] * rnd(s))
                                      : (float)(s->amp[c] * sin(2.0 * kPi * s->freq[c] * (double)(s->pos + i) / s->rate));
        }
        ip[c] = s->in[c];
        op[c] = s->out[c];
    }
    if (s->nanAt >= 0.0f && (double)s->nanAt >= (double)s->pos && (double)s->nanAt < (double)(s->pos + frames)) {
        s->in[0][(uint32_t)((uint64_t)s->nanAt - s->pos)] = NAN;
    }
    n60_status st = n60_graph_process(g, ip, op, frames);
    s->pos += frames;
    return st;
}

/* Largest sample-to-sample step of channel c over `blocks` blocks; also the largest magnitude. */
static double runMaxStep(n60_graph *g, Src *s, uint32_t c, int blocks, double *prev, double *peak) {
    double worst = 0.0;
    for (int b = 0; b < blocks; b++) {
        step(g, s, BLOCK);
        for (uint32_t i = 0; i < BLOCK; i++) {
            double v = s->out[c][i];
            if (!isfinite(v)) return INFINITY;
            if (prev && s->pos > BLOCK) worst = fmax(worst, fabs(v - *prev));
            if (peak) *peak = fmax(*peak, fabs(v));
            if (prev) *prev = v;
        }
    }
    return worst;
}

static int blocksFor(double rate, double seconds) { return (int)ceil(seconds * rate / BLOCK); }

static double rmsOf(const float *p, uint32_t n) {
    double a = 0;
    for (uint32_t i = 0; i < n; i++) a += (double)p[i] * p[i];
    return sqrt(a / n);
}

static double peakOf(const float *p, uint32_t n) {
    double a = 0;
    for (uint32_t i = 0; i < n; i++) a = fmax(a, fabs((double)p[i]));
    return a;
}

/* Run until the rebuild is idle again; returns blocks taken (cap 100000). */
static int untilIdle(n60_graph *g, Src *s) {
    int n = 0;
    step(g, s, BLOCK);  /* the first block adopts the published snapshot */
    n++;
    while (status(g).state != 0 && n < 100000) {
        step(g, s, BLOCK);
        n++;
    }
    return n;
}

/* ---- live PEQ edits ------------------------------------------------------ */

static void testPeqSweep(double rate) {
    float peq[8] = {0, 440, 0, 1, 0, 3000, 0, 0.7f};
    n60_stage_desc st[1] = {stg(N60_STAGE_PEQ, 1, N60_LANE_ALL, peq, 8)};
    n60_graph *g = build(rate, 1, st, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 440;
    s.amp[0] = 0.5;
    double prev = 0, peak = 0, worst = 0;
    runMaxStep(g, &s, 0, blocksFor(rate, 0.05), &prev, &peak);
    /* A sweep of gain, centre-frequency and type edits, many while a previous crossfade is still running. */
    const float gains[] = {12, -12, 6, -18, 0, 9, -6, 12, 0};
    for (unsigned k = 0; k < sizeof gains / sizeof *gains; k++) {
        post(g, 1, 2, gains[k]);
        if (k % 3 == 1) post(g, 1, 1, 300.0f + 150.0f * (float)k);
        if (k % 4 == 3) post(g, 1, 4, (float)(k & 1 ? 1 : 7)); /* second section type: shelf / band pass */
        worst = fmax(worst, runMaxStep(g, &s, 0, 1 + (int)(k % 3), &prev, &peak));
        worst = fmax(worst, runMaxStep(g, &s, 0, blocksFor(rate, 0.004 * (k % 4)), &prev, &peak));
    }
    post(g, 1, 1, 440.0f);
    post(g, 1, 2, 12.0f);
    post(g, 1, 4, 0.0f);
    post(g, 1, 6, 0.0f);
    worst = fmax(worst, runMaxStep(g, &s, 0, blocksFor(rate, 0.3), &prev, &peak));
    const double slope = 0.5 * 4.0 * 2.0 * kPi * 1000.0 / rate;  /* gain <= 12 dB; allow content up to 1 kHz */
    CHECK(isfinite(worst) && worst < slope * 1.5, "rate %.0f PEQ edit sweep: largest step %g vs bound %g", rate, worst, slope * 1.5);
    /* Settled response: +12 dB peak at 440 Hz means amplitude ~ 0.5 * 3.98. */
    double a = 0;
    for (int b = 0; b < blocksFor(rate, 0.02); b++) {
        step(g, &s, BLOCK);
        a = fmax(a, peakOf(s.out[0], BLOCK));
    }
    CHECK(fabs(a - 0.5 * pow(10.0, 12.0 / 20.0)) < 0.5 * 0.05 * 4.0, "rate %.0f PEQ settled amplitude %g", rate, a);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(gs.paramsApplied >= 15 && gs.paramsDropped == 0, "PEQ edits applied %llu dropped %llu", (unsigned long long)gs.paramsApplied, (unsigned long long)gs.paramsDropped);
    n60_graph_retire(g);
}

static void testPeqValidation(double rate) {
    float peq[4] = {0, 1000, 0, 1};
    n60_stage_desc st[1] = {stg(N60_STAGE_PEQ, 1, N60_LANE_ALL, peq, 4)};
    n60_graph *g = build(rate, 1, st, 1);
    if (!g) return;
    n60_param_record bad[] = {{1, 0, 8.0f, 0}, {1, 0, 0.5f, 0}, {1, 1, 0.0f, 0}, {1, 1, (float)(rate * 0.5), 0},
                              {1, 2, 25.0f, 0}, {1, 3, 0.0f, 0}, {1, 4, 0.0f, 0}};
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) {
        CHECK(n60_graph_post_params(g, &bad[i], 1) == N60_STATUS_BAD_ARGUMENT, "PEQ record %u refused", i);
    }
    n60_param_record ok[] = {{1, 0, 7.0f, 0}, {1, 1, 20.0f, 0}, {1, 2, -24.0f, 0}, {1, 3, 1000.0f, 0}};
    CHECK(n60_graph_post_params(g, ok, 4) == N60_STATUS_OK, "PEQ extreme valid values accepted");
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 1000;
    s.amp[0] = 0.5;
    double peak = 0;
    runMaxStep(g, &s, 0, blocksFor(rate, 0.1), NULL, &peak);
    CHECK(isfinite(peak) && peak < 10.0, "extreme PEQ edit stays finite (%g)", peak);
    n60_graph_retire(g);
}

/* ---- live bass crossover and crosstalk ----------------------------------- */

static void testBassCrossover(double rate) {
    float bass[9] = {80, 0, 2, -1, 120, 0, 0, 0, 0};
    n60_stage_desc st[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, bass, 9)};
    n60_graph *g = build(rate, 3, st, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 3);
    s.freq[0] = s.freq[1] = 70;
    s.amp[0] = s.amp[1] = 0.5;
    double prev0 = 0, prev2 = 0, w0 = 0, w2 = 0, pk = 0;
    for (int i = 0; i < blocksFor(rate, 0.15) ; i++) {
        step(g, &s, BLOCK);
    }
    prev0 = s.out[0][BLOCK - 1];
    prev2 = s.out[2][BLOCK - 1];
    const float edits[] = {120, 60, 200, 80, 45, 80};
    for (unsigned k = 0; k < sizeof edits / sizeof *edits; k++) {
        post(g, 1, 0, edits[k]);
        for (int b = 0; b < blocksFor(rate, 0.04); b++) {
            step(g, &s, BLOCK);
            for (uint32_t i = 0; i < BLOCK; i++) {
                w0 = fmax(w0, fabs(s.out[0][i] - prev0));
                w2 = fmax(w2, fabs(s.out[2][i] - prev2));
                prev0 = s.out[0][i];
                prev2 = s.out[2][i];
                pk = fmax(pk, fmax(fabs(prev0), fabs(prev2)));
            }
        }
    }
    const double slope = 2.0 * 0.5 * 2.0 * kPi * 70.0 / rate;  /* the sub sums two 0.5 mains: bound 2x one path */
    CHECK(isfinite(pk) && w0 < slope * 2.5 && w2 < slope * 2.5, "rate %.0f crossover edit steps %g / %g vs %g", rate, w0, w2, slope * 2.5);
    n60_graph_retire(g);
}

static void testCrosstalkAndCrossfeed(double rate) {
    float xt[2] = {800, 0.0f};
    float cf[1] = {0.0f};
    n60_stage_desc st[2] = {stgPair(N60_STAGE_CROSSFEED, 1, 0, 1, cf, 1), stgPair(N60_STAGE_CROSSTALK, 2, 0, 1, xt, 2)};
    n60_graph *g = build(rate, 2, st, 2);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 2);
    s.freq[0] = 1000;
    s.freq[1] = 1500;
    s.amp[0] = s.amp[1] = 0.4;
    double worst = 0, prev0 = 0, prev1 = 0;
    for (int i = 0; i < blocksFor(rate, 0.05); i++) step(g, &s, BLOCK);
    prev0 = s.out[0][BLOCK - 1];
    prev1 = s.out[1][BLOCK - 1];
    const float amounts[] = {1.0f, 0.2f, 0.9f, 0.0f};
    for (unsigned k = 0; k < sizeof amounts / sizeof *amounts; k++) {
        post(g, 2, 1, amounts[k]);
        post(g, 1, 0, 0.5f * amounts[k]);
        for (int b = 0; b < blocksFor(rate, 0.03); b++) {
            step(g, &s, BLOCK);
            for (uint32_t i = 0; i < BLOCK; i++) {
                worst = fmax(worst, fmax(fabs(s.out[0][i] - prev0), fabs(s.out[1][i] - prev1)));
                prev0 = s.out[0][i];
                prev1 = s.out[1][i];
            }
        }
    }
    const double slope = 1.6 * 2.0 * kPi * 1500.0 / rate;
    CHECK(isfinite(worst) && worst < slope * 1.5, "rate %.0f crosstalk/crossfeed edit step %g vs %g", rate, worst, slope * 1.5);
    n60_graph_retire(g);
}

/* ---- faded rebuild -------------------------------------------------------- */

static void testFadeLaw(double rate) {
    float ga = 1.0f, gb = 0.25f;
    n60_stage_desc a[1] = {stg(N60_STAGE_GAIN, 1, N60_LANE_ALL, &ga, 1)};
    n60_stage_desc b[1] = {stg(N60_STAGE_GAIN, 1, N60_LANE_ALL, &gb, 1)};
    n60_graph *g = build(rate, 1, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 300;
    s.amp[0] = 0.5;
    for (int i = 0; i < 5; i++) step(g, &s, BLOCK);
    n60_graph_desc db = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    const uint32_t F = (uint32_t)lround(0.020 * rate);
    long fadeStart = -1;
    double prev = s.out[0][BLOCK - 1], worst = 0, maxErr = 0;
    int guard = 0;
    long fadeFrames = 0;
    while (guard++ < 100000) {
        n60_rebuild_status rs = status(g);
        if (rs.state == 0 && s.pos > 5 * BLOCK && rs.completed == 1) break;
        const uint64_t start = s.pos;
        const int inFade = rs.state == 2;
        if (inFade && fadeStart < 0) fadeStart = (long)start;
        step(g, &s, BLOCK);
        for (uint32_t i = 0; i < BLOCK; i++) {
            const double x = s.in[0][i];
            double expect;
            if (fadeStart < 0 || !inFade) {
                expect = x * 1.0;  /* warm-up: the old graph alone */
            } else {
                double k = (double)((long)(start + i) - fadeStart);
                double th = 0.5 * kPi * fmin(k, (double)F) / (double)F;
                expect = x * (cos(th) + 0.25 * sin(th));
            }
            if (inFade) fadeFrames++;
            maxErr = fmax(maxErr, fabs(s.out[0][i] - expect));
            worst = fmax(worst, fabs(s.out[0][i] - prev));
            prev = s.out[0][i];
        }
    }
    CHECK(maxErr < 3e-5, "rate %.0f equal-power law error %g", rate, maxErr);
    CHECK(fadeStart > 0 && fadeFrames >= (long)F && fadeFrames <= (long)F + BLOCK, "rate %.0f fade length %ld vs %u", rate, fadeFrames, F);
    const double slope = 0.5 * 2.0 * kPi * 300.0 / rate * 1.3;
    CHECK(worst < slope, "rate %.0f rebuild step %g vs %g", rate, worst, slope);
    step(g, &s, BLOCK);
    CHECK(fabs(s.out[0][BLOCK - 1] - 0.25 * s.in[0][BLOCK - 1]) < 1e-6, "new graph live after the fade");
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(gs.liveEpoch == 2, "epoch 2 live");
    CHECK(n60_graph_collect(g) == 1, "old snapshot retired once");
    n60_rebuild_status rs = status(g);
    CHECK(rs.completed == 1 && rs.lastResult == 1 && rs.refused == 0 && rs.cancelled == 0, "status after completion");
    n60_graph_retire(g);
}

static void testEnergyConstancy(double rate) {
    /* The new graph delays white noise by 1000 frames, so old and new outputs are uncorrelated and an
     * equal-power fade keeps the power constant. The delay line must be warm before the fade starts. */
    float delay0 = 0, delay1 = 1000;
    n60_stage_desc a[1] = {stg(N60_STAGE_DELAY, 1, N60_LANE_ALL, &delay0, 1)};
    n60_stage_desc b[1] = {stg(N60_STAGE_DELAY, 1, N60_LANE_ALL, &delay1, 1)};
    a[0].capacityFrames = b[0].capacityFrames = 2000;
    n60_graph *g = build(rate, 1, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.noise[0] = 1;
    s.amp[0] = 0.3;
    for (int i = 0; i < 5; i++) step(g, &s, BLOCK);
    n60_graph_desc db = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    double lo = 1e9, hi = 0;
    const double ref = 0.3 / sqrt(3.0);
    int n = 0;
    step(g, &s, BLOCK);  /* adopts the snapshot */
    while (status(g).state != 0 && n++ < 100000) {
        const int fading = status(g).state == 2;
        step(g, &s, BLOCK);
        const double r = rmsOf(s.out[0], BLOCK) / ref;
        if (n > 1 && fading) {
            lo = fmin(lo, r);
            hi = fmax(hi, r);
        }
    }
    CHECK(lo > 0.8 && hi < 1.2, "rate %.0f energy over the fade %g..%g of nominal", rate, lo, hi);
    CHECK(status(g).completed == 1, "completed");
    n60_graph_retire(g);
}

static void testFailedBuildKeepsOld(double rate) {
    float ga = 0.5f;
    n60_stage_desc a[1] = {stg(N60_STAGE_GAIN, 1, N60_LANE_ALL, &ga, 1)};
    n60_graph *g = build(rate, 1, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 300;
    s.amp[0] = 0.5;
    for (int i = 0; i < 3; i++) step(g, &s, BLOCK);
    float bad[1] = {0};
    n60_stage_desc order[2] = {stg(N60_STAGE_DELAY, 1, N60_LANE_ALL, bad, 1), stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)};
    order[0].capacityFrames = 10;
    n60_graph_desc d1 = desc(rate, 1, order, 2);
    CHECK(n60_graph_publish(g, &d1) == N60_STATUS_BAD_ARGUMENT, "out of order stages refused");
    n60_graph_desc d2 = desc(rate + 1000, 1, a, 1);
    CHECK(n60_graph_publish(g, &d2) == N60_STATUS_BAD_ARGUMENT, "different rate refused");
    n60_graph_desc d3 = desc(rate, 1, a, 1);
    d3.abiVersion = 4;
    CHECK(n60_graph_publish(g, &d3) == N60_STATUS_ABI_MISMATCH, "old ABI refused");
    double prev = s.out[0][BLOCK - 1], pk = 0;
    double w = runMaxStep(g, &s, 0, blocksFor(rate, 0.1), &prev, &pk);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    n60_rebuild_status rs = status(g);
    CHECK(gs.liveEpoch == 1 && gs.publishedEpoch == 1 && rs.state == 0 && rs.completed == 0, "state unchanged");
    CHECK(fabs(s.out[0][BLOCK - 1] - 0.5 * s.in[0][BLOCK - 1]) < 1e-6 && w < 0.5 * 2 * kPi * 300 / rate * 1.1, "old graph keeps rendering");
    n60_graph_retire(g);
}

static void testNanCancel(double rate) {
    float ga = 0.5f;
    n60_stage_desc a[2] = {stg(N60_STAGE_SANITISE, 1, N60_LANE_ALL, NULL, 0), stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)};
    n60_stage_desc b[1] = {stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)}; /* no sanitiser: NaN propagates */
    n60_graph *g = build(rate, 1, a, 2);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 300;
    s.amp[0] = 0.5;
    for (int i = 0; i < 3; i++) step(g, &s, BLOCK);
    n60_graph_desc db = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    s.nanAt = (float)(s.pos + BLOCK + 17);  /* inside the warm-up */
    int finite = 1;
    for (int i = 0; i < blocksFor(rate, 0.1); i++) {
        step(g, &s, BLOCK);
        for (uint32_t k = 0; k < BLOCK; k++) finite &= isfinite(s.out[0][k]);
    }
    n60_rebuild_status rs = status(g);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(finite, "output stays finite");
    CHECK(rs.state == 0 && rs.lastResult == 3 && rs.cancelled == 1 && rs.completed == 0, "cancelled (state %u last %u)", rs.state, rs.lastResult);
    CHECK(gs.liveEpoch == 1, "old graph kept");
    CHECK(n60_graph_collect(g) == 1, "cancelled snapshot retired");
    /* A later clean publish still works. */
    float gc = 0.25f;
    n60_stage_desc c[1] = {stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &gc, 1)};
    n60_graph_desc dc = desc(rate, 1, c, 1);
    s.nanAt = -1.0f;
    CHECK(n60_graph_publish(g, &dc) == N60_STATUS_OK, "publish again");
    untilIdle(g, &s);
    CHECK(status(g).completed == 1, "later rebuild completes");
    n60_graph_retire(g);
}

/* After a cancel or refusal the control side must fall back to the live snapshot (no freed pointer) and the
 * mailbox must keep flowing. Run under ASan this also catches a use-after-free. */
static void testAfterFailure(double rate) {
    float ga = 0.5f;
    n60_stage_desc a[2] = {stg(N60_STAGE_METER_IN, 8, N60_LANE_ALL, NULL, 0), stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)};
    n60_stage_desc b[2] = {stg(N60_STAGE_METER_IN, 7, N60_LANE_ALL, NULL, 0), stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)};
    for (int mode = 0; mode < 2; mode++) { /* 0 cancel on NaN, 1 refuse on CPU budget */
        n60_graph *g = build(rate, 1, a, 2);
        if (!g) return;
        Src s;
        srcInit(&s, rate, 1);
        s.freq[0] = 300;
        s.amp[0] = 0.5;
        for (int i = 0; i < 3; i++) step(g, &s, BLOCK);
        if (mode == 1) {
            n60_rebuild_options o = {sizeof o, 20.0f, 1e-9f, 0};
            CHECK(n60_graph_set_rebuild_options(g, &o) == N60_STATUS_OK, "budget");
        }
        n60_graph_desc db = desc(rate, 1, b, 2);
        CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
        /* Posted while the doomed snapshot is the newest: tagged with its epoch. */
        post(g, 2, 0, 0.25f);
        if (mode == 0) s.nanAt = (float)(s.pos + BLOCK + 17);
        for (int i = 0; i < blocksFor(rate, 0.1); i++) step(g, &s, BLOCK);
        s.nanAt = -1.0f;
        n60_rebuild_status rs = status(g);
        CHECK(rs.state == 0 && (mode == 0 ? rs.cancelled : rs.refused) == 1, "mode %d failed rebuild", mode);
        CHECK(n60_graph_collect(g) == 1, "failed snapshot freed");
        float peak, rms;
        CHECK(n60_graph_read_meter(g, 7, 0, &peak, &rms) == N60_STATUS_BAD_ARGUMENT, "doomed stage unknown after fallback");
        CHECK(n60_graph_read_meter(g, 8, 0, &peak, &rms) == N60_STATUS_OK, "meter read on live snapshot is safe");
        /* Edits to the live graph flow again and are not stuck behind the dead record. */
        n60_param_record r = {2, 0, 0.125f, 0};
        for (int i = 0; i < 2000; i++) {
            CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "post after failure #%d", i);
            step(g, &s, BLOCK);
        }
        for (int i = 0; i < 4; i++) step(g, &s, BLOCK);
        CHECK(fabs(s.out[0][BLOCK - 1] - 0.125 * s.in[0][BLOCK - 1]) < 1e-5, "mode %d edit applied after failure", mode);
        n60_graph_retire(g);
    }
}

/* The incoming graph alone has the ANC stage: it must still start held and not re-arm mid-rebuild. */
static void testAncIncomingOnly(double rate) {
    float inj[4] = {1, 1, 0, 7};
    float ga = 1.0f;
    n60_stage_desc a[1] = {stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1)};
    n60_stage_desc b[2] = {stg(N60_STAGE_GAIN, 2, N60_LANE_ALL, &ga, 1), stg(N60_STAGE_ANC_INJECT, 1, 0, inj, 4)};
    n60_graph *g = build(rate, 2, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 2);
    n60_graph_desc db = desc(rate, 2, b, 2);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    step(g, &s, BLOCK);
    CHECK(status(g).ancStagesHeld == 1, "incoming ANC stage counted");
    post(g, 1, 3, 8.0f); /* a revision during the rebuild */
    double mx = 0;
    for (int i = 0; i < blocksFor(rate, 0.2); i++) {
        for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
        const float *ip[2] = {s.in[0], s.in[1]};
        float *op[2] = {s.out[0], s.out[1]};
        n60_graph_process(g, ip, op, BLOCK);
        for (uint32_t k = 0; k < BLOCK; k++) mx = fmax(mx, fabs(s.out[0][k]));
    }
    CHECK(status(g).completed == 1 && mx < 1e-6, "rate %.0f injection stays muted (%g)", rate, mx);
    n60_graph_retire(g);
}

static void testCpuBudget(double rate) {
    float delay0 = 0, delay1 = 100;
    n60_stage_desc a[1] = {stg(N60_STAGE_DELAY, 1, N60_LANE_ALL, &delay0, 1)};
    n60_stage_desc b[1] = {stg(N60_STAGE_DELAY, 1, N60_LANE_ALL, &delay1, 1)};
    a[0].capacityFrames = b[0].capacityFrames = 200;
    n60_graph *g = build(rate, 1, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 300;
    s.amp[0] = 0.5;
    for (int i = 0; i < 3; i++) step(g, &s, BLOCK);
    n60_rebuild_options o = {sizeof o, 20.0f, 1e-7f, 0};
    CHECK(n60_graph_set_rebuild_options(g, &o) == N60_STATUS_OK, "tiny budget set");
    n60_graph_desc db = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    untilIdle(g, &s);
    n60_rebuild_status rs = status(g);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(rs.lastResult == 2 && rs.refused == 1 && rs.completed == 0 && gs.liveEpoch == 1, "refused over budget (last %u)", rs.lastResult);
    CHECK(rs.lastWarmupCpuPercent > 0.0f, "measured load reported");
    CHECK(fabs(s.out[0][BLOCK - 1] - s.in[0][BLOCK - 1]) < 1e-6, "live graph still renders");
    o.cpuBudgetPercent = 1000.0f;
    CHECK(n60_graph_set_rebuild_options(g, &o) == N60_STATUS_OK, "generous budget set");
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish again");
    untilIdle(g, &s);
    rs = status(g);
    CHECK(rs.lastResult == 1 && rs.completed == 1 && rs.refused == 1, "completes within budget");
    n60_rebuild_options bad = {sizeof bad, -1.0f, 0.0f, 0};
    CHECK(n60_graph_set_rebuild_options(g, &bad) == N60_STATUS_BAD_ARGUMENT, "negative fade refused");
    bad.structSize = 3;
    CHECK(n60_graph_set_rebuild_options(g, &bad) == N60_STATUS_ABI_MISMATCH, "option struct size checked");
    n60_graph_retire(g);
}

/* ---- ANC mute and re-arm ---------------------------------------------------- */

static void testAncRebuild(double rate) {
    /* lane 0: speaker, lane 1: anti-noise source (0.5 DC). */
    float inj[4] = {1, 1, 0, 7};
    n60_stage_desc st[1] = {stg(N60_STAGE_ANC_INJECT, 1, 0, inj, 4)};
    n60_graph *g = build(rate, 2, st, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 2);
    s.freq[1] = 0.0;  /* sin(0) = 0: replaced below with DC */
    for (int i = 0; i < blocksFor(rate, 0.1); i++) {
        for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
        const float *ip[2] = {s.in[0], s.in[1]};
        float *op[2] = {s.out[0], s.out[1]};
        n60_graph_process(g, ip, op, BLOCK);
    }
    CHECK(fabs(s.out[0][BLOCK - 1] - 0.5) < 1e-4, "rate %.0f injects when authorised (%g)", rate, s.out[0][BLOCK - 1]);

    const uint32_t cap = 1;
    (void)cap;
    n60_graph_desc d = desc(rate, 2, st, 1);
    CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish identical topology");
    /* Revision posted during the rebuild must not re-arm. */
    n60_param_record early = {1, 3, 8.0f, 0};
    CHECK(n60_graph_post_params(g, &early, 1) == N60_STATUS_OK, "early revision accepted by the mailbox");
    double prevOut = 0.5, worst = 0, last = 1;
    int blocks = 0;
    int phaseMax = 0;
    do {
        for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
        const float *ip[2] = {s.in[0], s.in[1]};
        float *op[2] = {s.out[0], s.out[1]};
        n60_graph_process(g, ip, op, BLOCK);
        for (uint32_t k = 0; k < BLOCK; k++) {
            worst = fmax(worst, fabs(s.out[0][k] - prevOut));
            prevOut = s.out[0][k];
        }
        last = s.out[0][BLOCK - 1];
        blocks++;
        phaseMax = (int)status(g).state > phaseMax ? (int)status(g).state : phaseMax;
    } while (status(g).state != 0 && blocks < 100000);
    CHECK(phaseMax == 2, "rebuild passed through the fade");
    CHECK(worst < 2.0 * 0.5 / (0.010 * rate), "rate %.0f ANC mute ramp step %g", rate, worst);
    for (int i = 0; i < blocksFor(rate, 0.05); i++) {
        for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
        const float *ip[2] = {s.in[0], s.in[1]};
        float *op[2] = {s.out[0], s.out[1]};
        n60_graph_process(g, ip, op, BLOCK);
    }
    CHECK(fabs(s.out[0][BLOCK - 1]) < 1e-6 && fabs(last) < 0.5, "rate %.0f injection stays muted after the rebuild (%g)", rate, s.out[0][BLOCK - 1]);
    n60_rebuild_status rs = status(g);
    CHECK(rs.ancStagesHeld == 1, "ANC stage reported held");
    n60_param_record rearm = {1, 3, 9.0f, 0};
    CHECK(n60_graph_post_params(g, &rearm, 1) == N60_STATUS_OK, "re-arm revision posted");
    prevOut = 0;
    worst = 0;
    for (int i = 0; i < blocksFor(rate, 0.05); i++) {
        for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
        const float *ip[2] = {s.in[0], s.in[1]};
        float *op[2] = {s.out[0], s.out[1]};
        n60_graph_process(g, ip, op, BLOCK);
        for (uint32_t k = 0; k < BLOCK; k++) {
            worst = fmax(worst, fabs(s.out[0][k] - prevOut));
            prevOut = s.out[0][k];
        }
    }
    CHECK(fabs(s.out[0][BLOCK - 1] - 0.5) < 1e-4, "re-arm resumes injection (%g)", s.out[0][BLOCK - 1]);
    CHECK(worst < 2.0 * 0.5 / (0.010 * rate), "re-arm ramp step %g", worst);

    /* An unauthorised stage never injects, rebuild or not. */
    float inj0[4] = {1, 0, 0, 0};
    n60_stage_desc st0[1] = {stg(N60_STAGE_ANC_INJECT, 1, 0, inj0, 4)};
    n60_graph *g0 = build(rate, 2, st0, 1);
    if (g0) {
        n60_graph_desc d0 = desc(rate, 2, st0, 1);
        n60_graph_publish(g0, &d0);
        double pk = 0;
        for (int i = 0; i < blocksFor(rate, 0.1); i++) {
            for (uint32_t k = 0; k < BLOCK; k++) { s.in[0][k] = 0; s.in[1][k] = 0.5f; }
            const float *ip[2] = {s.in[0], s.in[1]};
            float *op[2] = {s.out[0], s.out[1]};
            n60_graph_process(g0, ip, op, BLOCK);
            pk = fmax(pk, peakOf(s.out[0], BLOCK));
        }
        CHECK(pk == 0.0, "unauthorised injection stays silent");
        n60_graph_retire(g0);
    }
    n60_graph_retire(g);
}

/* ---- many edits, bounded time ------------------------------------------------ */

static double nowSeconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

static void testRandomEdits(double rate) {
    float peq[16] = {0, 200, 0, 1, 0, 800, 0, 1, 0, 3000, 0, 1, 0, 9000, 0, 1};
    float g1 = 1.0f, delay = 0;
    n60_stage_desc st[3] = {stg(N60_STAGE_GAIN, 1, N60_LANE_ALL, &g1, 1), stg(N60_STAGE_PEQ, 2, N60_LANE_ALL, peq, 16),
                            stg(N60_STAGE_DELAY, 3, N60_LANE_ALL, &delay, 1)};
    st[2].capacityFrames = 500;
    n60_graph *g = build(rate, 2, st, 3);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 2);
    s.noise[0] = s.noise[1] = 1;
    s.amp[0] = s.amp[1] = 0.2;
    uint32_t r = 99;
    #define RND (r = r * 1664525u + 1013904223u, (double)(r >> 8) / 16777216.0)
    double t0 = nowSeconds(), pk = 0;
    unsigned posted = 0;
    for (int b = 0; b < 1000; b++) {
        n60_param_record rec[4];
        unsigned n = 0;
        const unsigned which = (unsigned)(RND * 4);
        for (unsigned k = 0; k <= which; k++) {
            const unsigned sec = (unsigned)(RND * 4);
            switch ((unsigned)(RND * 4)) {
                case 0: rec[n++] = (n60_param_record){2, sec * 4 + 2, (float)(RND * 36.0 - 18.0), 0}; break;
                case 1: rec[n++] = (n60_param_record){2, sec * 4 + 1, (float)(100.0 + RND * 10000.0), 0}; break;
                case 2: rec[n++] = (n60_param_record){1, 0, (float)(0.2 + RND * 2.0), 0}; break;
                default: rec[n++] = (n60_param_record){3, 0, (float)(int)(RND * 500.0), 0}; break;
            }
        }
        if (n60_graph_post_params(g, rec, n) == N60_STATUS_OK) posted += n;
        step(g, &s, 256);
        pk = fmax(pk, fmax(peakOf(s.out[0], 256), peakOf(s.out[1], 256)));
    }
    double elapsed = nowSeconds() - t0;
    for (int b = 0; b < 8; b++) step(g, &s, 256);
    const double audio = 1000.0 * 256.0 / rate;
    CHECK(elapsed < audio, "rate %.0f 1000 random edit blocks took %.3f s for %.3f s of audio", rate, elapsed, audio);
    CHECK(isfinite(pk) && pk < 50.0, "output bounded under random edits (%g)", pk);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(gs.paramsApplied + gs.paramsDropped == posted, "every posted record was taken (%llu + %llu vs %u)",
          (unsigned long long)gs.paramsApplied, (unsigned long long)gs.paramsDropped, posted);
    n60_graph_retire(g);
}

/* A burst larger than the per-block drain cap is taken over later blocks, in order, none lost. */
static void testDrainCap(double rate) {
    float g1 = 1.0f;
    n60_stage_desc st[1] = {stg(N60_STAGE_GAIN, 1, N60_LANE_ALL, &g1, 1)};
    n60_graph *g = build(rate, 1, st, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 100;
    s.amp[0] = 0.5;
    n60_param_record burst[1000];
    for (int i = 0; i < 1000; i++) burst[i] = (n60_param_record){1, 0, 1.0f + (float)i * 0.001f, 0};
    CHECK(n60_graph_post_params(g, burst, 1000) == N60_STATUS_OK, "burst posted");
    step(g, &s, 64);
    n60_graph_stats gs;
    n60_graph_get_stats(g, &gs);
    CHECK(gs.paramsApplied < 1000 && gs.paramsApplied > 0, "first block takes a capped share (%llu)", (unsigned long long)gs.paramsApplied);
    for (int i = 0; i < 6; i++) step(g, &s, 64);
    n60_graph_get_stats(g, &gs);
    CHECK(gs.paramsApplied == 1000, "the rest follow (%llu)", (unsigned long long)gs.paramsApplied);
    for (int i = 0; i < blocksFor(rate, 0.05); i++) step(g, &s, 64);
    CHECK(fabs(s.out[0][63] - s.in[0][63] * 1.999f) < 1e-3 * fabs(s.in[0][63]) + 1e-5 || fabs(s.in[0][63]) < 1e-3, "latest value wins (%g)", s.out[0][63] / (s.in[0][63] + 1e-30));
    n60_graph_retire(g);
}

/* ---- FIR / IR change continuity ------------------------------------------------ */

static void testIrChange(double rate) {
    float h0[64] = {0}, h1[64] = {0};
    h0[0] = 1.0f;
    h1[10] = 0.5f;
    n60_stage_desc a[1] = {stg(N60_STAGE_FIR, 1, N60_LANE_ALL, h0, 64)};
    n60_stage_desc b[1] = {stg(N60_STAGE_FIR, 1, N60_LANE_ALL, h1, 64)};
    n60_graph *g = build(rate, 1, a, 1);
    if (!g) return;
    Src s;
    srcInit(&s, rate, 1);
    s.freq[0] = 300;
    s.amp[0] = 0.5;
    double prev = 0, pk = 0;
    runMaxStep(g, &s, 0, blocksFor(rate, 0.05), &prev, &pk);
    n60_graph_desc db = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish new IR");
    double worst = 0;
    int n = 0;
    worst = fmax(worst, runMaxStep(g, &s, 0, 1, &prev, &pk));  /* adopts the snapshot */
    while (status(g).state != 0 && n++ < 100000) worst = fmax(worst, runMaxStep(g, &s, 0, 1, &prev, &pk));
    worst = fmax(worst, runMaxStep(g, &s, 0, blocksFor(rate, 0.02), &prev, &pk));
    const double slope = 0.5 * 2.0 * kPi * 300.0 / rate;
    CHECK(isfinite(worst) && worst < slope * 1.3, "rate %.0f IR change step %g vs %g", rate, worst, slope * 1.3);
    CHECK(status(g).completed == 1, "IR rebuild completed");
    /* Settled: y[n] = 0.5 x[n - 256 - 10]. */
    step(g, &s, BLOCK);
    const uint64_t base = s.pos - BLOCK;
    double err = 0;
    for (uint32_t i = 0; i < BLOCK; i++) {
        double want = 0.5 * 0.5 * sin(2.0 * kPi * 300.0 * (double)((long)(base + i) - 256 - 10) / rate);
        err = fmax(err, fabs(s.out[0][i] - want));
    }
    CHECK(err < 1e-4, "rate %.0f new IR settled (err %g)", rate, err);
    n60_graph_retire(g);
}

/* ---- deferred fixes from S4/S5 ------------------------------------------------------ */

static void testDeferred(double rate) {
    /* Gate: a NaN sample is zeroed, never passed on. */
    float gate[5] = {-60, 6, 100, 10, 10};
    n60_stage_desc st[1] = {stgMask(N60_STAGE_PAUSE_GATE, 1, 0x1, gate, 5)};
    n60_graph *g = build(rate, 1, st, 1);
    if (g) {
        Src s;
        srcInit(&s, rate, 1);
        s.freq[0] = 440;
        s.amp[0] = 0.5;
        s.nanAt = 300.0f;
        int finite = 1;
        for (int i = 0; i < 6; i++) {
            step(g, &s, BLOCK);
            for (uint32_t k = 0; k < BLOCK; k++) finite &= isfinite(s.out[0][k]);
        }
        CHECK(finite, "rate %.0f gate never passes NaN", rate);
        n60_graph_retire(g);
    }
    /* Guard status is size-checked. */
    float guard[28] = {-1, -1, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0};
    for (int i = 12; i < 28; i++) guard[i] = -100;
    n60_stage_desc gs[1] = {stg(N60_STAGE_ANC_GUARD, 1, 0, guard, 28)};
    n60_graph *g2 = build(rate, 1, gs, 1);
    if (g2) {
        n60_guard_status out;
        memset(&out, 0, sizeof out);
        CHECK(n60_graph_read_guard(g2, 1, &out) == N60_STATUS_ABI_MISMATCH, "guard status without structSize refused");
        out.structSize = sizeof out;
        CHECK(n60_graph_read_guard(g2, 1, &out) == N60_STATUS_OK, "guard status with structSize");
        n60_graph_retire(g2);
    }
}

int main(void) {
    CHECK(n60_graph_abi_version() == N60_GRAPH_ABI_VERSION && N60_GRAPH_ABI_VERSION >= 5u, "ABI v5 or later");
    for (unsigned i = 0; i < sizeof kRates / sizeof *kRates; i++) {
        const double rate = kRates[i];
        testPeqSweep(rate);
        testPeqValidation(rate);
        testBassCrossover(rate);
        testCrosstalkAndCrossfeed(rate);
        testFadeLaw(rate);
        testEnergyConstancy(rate);
        testFailedBuildKeepsOld(rate);
        testNanCancel(rate);
        testCpuBudget(rate);
        testAncRebuild(rate);
        testAfterFailure(rate);
        testAncIncomingOnly(rate);
        testRandomEdits(rate);
        testDrainCap(rate);
        testIrChange(rate);
        testDeferred(rate);
        printf("rate %.0f done\n", rate);
    }
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("n60core rebuild and live edits: all checks passed\n");
    return 0;
}
