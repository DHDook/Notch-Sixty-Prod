/*
 * E6 S4: behavioural harness for the libn60core compressor, expander, dynamic EQ,
 * program FIR and spectral denoiser stages, through the C ABI at the eight standard
 * rates. Every stage is checked against an independent reference written here (closed
 * form gain laws, direct convolution, perfect reconstruction, noise statistics).
 */
#include <math.h>
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

static n60_stage_desc stageMask(uint32_t kind, uint32_t id, uint64_t mask, const float *params, uint32_t np) {
    n60_stage_desc s = stage(kind, id, 0, params, np);
    s.laneMask = mask;
    return s;
}

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

static n60_graph *buildOrDie(double rate, uint32_t maxBlock, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d = makeDesc(rate, maxBlock, ch, st, n);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build status %d (first stage kind %u, %u params, rate %.0f)", s, n, st[0].paramCount, rate);
    return g;
}

static n60_status tryBuild(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d = makeDesc(rate, 512, ch, st, n);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    if (s == N60_STATUS_OK) n60_graph_retire(g);
    return s;
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

/* Render frames [from, to) of `ch` lanes in blocks of at most `block`. */
static void renderRange(n60_graph *g, float **src, float **dst, uint32_t ch, uint32_t from, uint32_t to,
                        uint32_t block) {
    const float *in[N60_GRAPH_MAX_CHANNELS];
    float *out[N60_GRAPH_MAX_CHANNELS];
    for (uint32_t pos = from; pos < to; pos += block) {
        uint32_t n = to - pos < block ? to - pos : block;
        for (uint32_t c = 0; c < ch; c++) { in[c] = src[c] + pos; out[c] = dst[c] + pos; }
        n60_status s = n60_graph_process(g, in, out, n);
        CHECK(s == N60_STATUS_OK, "process %d", s);
    }
}
static void render(n60_graph *g, float **src, float **dst, uint32_t ch, uint32_t total, uint32_t block) {
    renderRange(g, src, dst, ch, 0, total, block);
}

static uint32_t rngState = 987654321;
static float noise(void) { /* in [-0.5, 0.5) */
    rngState = rngState * 1664525u + 1013904223u;
    return (float)((rngState >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}

static double tailAbsMax(const float *x, uint32_t total, uint32_t count) {
    double m = 0;
    for (uint32_t i = total - count; i < total; i++) m = fmax(m, fabs(x[i]));
    return m;
}
static double db(double x) { return 20.0 * log10(x); }

/* ---- compressor ------------------------------------------------------------ */

/* params: thr, ratio, knee, attack, release, makeup, feedback, pdr, hpHz, linked */
static void fillComp(float *p, float thr, float ratio, float knee, float mk) {
    p[0] = thr; p[1] = ratio; p[2] = knee; p[3] = 1.0f; p[4] = 100.0f; p[5] = mk;
    p[6] = 0; p[7] = 0; p[8] = 0; p[9] = 0;
}

static double dcGainDb(double rate, float *p, float level, uint32_t block) {
    uint32_t total = (uint32_t)(1.0 * rate);
    n60_stage_desc st = stage(N60_STAGE_COMPRESSOR, 1, N60_LANE_ALL, p, 10);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) in[0][i] = level;
    render(g, in, out, 1, total, block);
    double r = db(fabs(out[0][total - 1] / level));
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
    return r;
}

static void testCompressorCurve(double rate) {
    float p[10];
    /* Hard knee: 4:1, DC at -6.02 dBFS over a -20 dB threshold. */
    fillComp(p, -20, 4, 0, 0);
    double ref = (1.0 / 4.0 - 1.0) * (db(0.5) + 20.0);
    double got = dcGainDb(rate, p, 0.5f, 512);
    CHECK(fabs(got - ref) < 0.02, "rate %.0f hard knee %.4f vs %.4f", rate, got, ref);
    /* Block size must not matter. */
    double got1 = dcGainDb(rate, p, 0.5f, 1);
    CHECK(got1 == got, "rate %.0f block 1 differs: %.6f vs %.6f", rate, got1, got);
    /* Soft knee centre: gain = slope * (knee/2)^2 / (2 knee). */
    fillComp(p, -20, 4, 6, 0);
    ref = -0.75 * 9.0 / 12.0;
    got = dcGainDb(rate, p, 0.1f, 512);
    CHECK(fabs(got - ref) < 0.02, "rate %.0f knee centre %.4f vs %.4f", rate, got, ref);
    /* Below the knee only makeup remains. */
    fillComp(p, -20, 4, 6, 3);
    got = dcGainDb(rate, p, 0.01f, 512);
    CHECK(fabs(got - 3.0) < 0.02, "rate %.0f makeup %.4f", rate, got);
    /* Feedback topology equilibrium: g = slope / (1 - slope) * (in - thr). */
    fillComp(p, -20, 4, 0, 0);
    p[6] = 1;
    ref = (-0.75 / 1.75) * (db(0.5) + 20.0);
    got = dcGainDb(rate, p, 0.5f, 512);
    CHECK(fabs(got - ref) < 0.05, "rate %.0f feedback %.4f vs %.4f", rate, got, ref);
    /* Sidechain high-pass removes DC from the detector. */
    fillComp(p, -20, 4, 0, 0);
    p[8] = 100;
    got = dcGainDb(rate, p, 0.5f, 512);
    CHECK(fabs(got) < 0.01, "rate %.0f sidechain HP leaves gain %.4f", rate, got);
    /* Program-dependent release stays finite and reduces gain. */
    fillComp(p, -20, 4, 0, 0);
    p[7] = 1;
    got = dcGainDb(rate, p, 0.5f, 512);
    CHECK(fabs(got - (-0.75 * (db(0.5) + 20.0))) < 0.02, "rate %.0f pdr %.4f", rate, got);
}

static void testCompressorLinked(double rate) {
    enum { CH = 3 };
    uint32_t total = (uint32_t)(0.4 * rate);
    float p[10];
    fillComp(p, -20, 4, 0, 0);
    double gain = pow(10.0, (-0.75 * (db(0.5) + 20.0)) / 20.0);
    for (int linked = 0; linked < 2; linked++) {
        p[9] = (float)linked;
        n60_stage_desc st = stageMask(N60_STAGE_COMPRESSOR, 1, 0x3, p, 10);
        n60_graph *g = buildOrDie(rate, 512, CH, &st, 1);
        float **in = alloc2d(CH, total), **out = alloc2d(CH, total);
        for (uint32_t i = 0; i < total; i++) { in[0][i] = 0.5f; in[1][i] = 0.01f; in[2][i] = 0.5f; }
        render(g, in, out, CH, total, 256);
        double l0 = out[0][total - 1] / 0.5, l1 = out[1][total - 1] / 0.01, l2 = out[2][total - 1] / 0.5;
        CHECK(fabs(l0 - gain) < 0.002, "rate %.0f linked=%d lane0 gain %.4f vs %.4f", rate, linked, l0, gain);
        CHECK(fabs(l1 - (linked ? gain : 1.0)) < 0.002, "rate %.0f linked=%d quiet lane gain %.4f", rate, linked, l1);
        CHECK(l2 == 1.0, "rate %.0f lane outside the mask untouched (%g)", rate, l2);
        n60_graph_retire(g);
        free2d(in, CH);
        free2d(out, CH);
    }
}

static void testCompressorLive(double rate) {
    uint32_t total = (uint32_t)(0.5 * rate), half = (uint32_t)(0.2 * rate);
    float p[10];
    fillComp(p, -20, 4, 0, 0);
    n60_stage_desc st = stage(N60_STAGE_COMPRESSOR, 7, N60_LANE_ALL, p, 10);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) in[0][i] = 0.1f;
    renderRange(g, in, out, 1, 0, half, 512);
    CHECK(fabs(db(out[0][half - 1] / 0.1)) < 0.01, "rate %.0f no reduction at threshold", rate);
    n60_param_record rec = {7, 0, -40.0f, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post threshold");
    renderRange(g, in, out, 1, half, total, 512);
    double got = db(out[0][total - 1] / 0.1), ref = -0.75 * (db(0.1) + 40.0);
    CHECK(fabs(got - ref) < 0.03, "rate %.0f live threshold %.3f vs %.3f", rate, got, ref);
    rec.paramIndex = 9; rec.value = 1;
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_UNSUPPORTED, "linked is not live");
    rec.paramIndex = 1; rec.value = 0.5f;
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_BAD_ARGUMENT, "ratio below 1 rejected");
    rec.paramIndex = 10; rec.value = 0;
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_BAD_ARGUMENT, "index out of range rejected");
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
}

/* ---- expander -------------------------------------------------------------- */

static void testExpander(double rate) {
    /* params: thr, ratio, range, attack, release, linked */
    uint32_t total = (uint32_t)(0.4 * rate);
    const float levels[2] = {0.01f, 1e-4f};
    const double refs[2] = {-10.0, -40.0};  /* (ratio-1)*(det-thr) = -10 ; -150 clamped to the range */
    for (int k = 0; k < 2; k++) {
        float p[6] = {-30, 2, -40, 1, 100, 0};
        if (k == 1) p[1] = 4;
        n60_stage_desc st = stage(N60_STAGE_EXPANDER, 1, N60_LANE_ALL, p, 6);
        n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
        float **in = alloc2d(1, total), **out = alloc2d(1, total);
        for (uint32_t i = 0; i < total; i++) in[0][i] = levels[k];
        render(g, in, out, 1, total, 512);
        double got = db(out[0][total - 1] / levels[k]);
        CHECK(fabs(got - refs[k]) < 0.02, "rate %.0f expander %.4f vs %.4f", rate, got, refs[k]);
        n60_graph_retire(g);
        free2d(in, 1);
        free2d(out, 1);
    }
    /* Above the threshold the signal passes. */
    float p[6] = {-30, 2, -40, 1, 100, 0};
    n60_stage_desc st = stage(N60_STAGE_EXPANDER, 1, N60_LANE_ALL, p, 6);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) in[0][i] = 0.2f;
    render(g, in, out, 1, total, 512);
    CHECK(out[0][total - 1] == 0.2f, "rate %.0f passes above threshold", rate);
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
}

/* ---- dynamic EQ ------------------------------------------------------------ */

/* One band: shape, Hz, Q, static dB, cutThr, cutRatio, cutRange, atk, rel, dir,
 * boostThr, boostRatio, boostMax, rms, rmsMs. */
static void fillBand(float *b, float stat, float thr, float ratio) {
    float v[15] = {0, 1000, 1, stat, thr, ratio, -24, 10, 10, 0, -60, 1, 0, 1, 20};
    memcpy(b, v, sizeof v);
}

static double sineAmp(double rate, uint32_t bands, const float *params, float amp) {
    uint32_t total = (uint32_t)(0.8 * rate);
    n60_stage_desc st = stage(N60_STAGE_DYN_EQ, 1, N60_LANE_ALL, params, 1 + 15 * bands);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) in[0][i] = amp * (float)sin(2 * M_PI * 1000.0 * i / rate);
    render(g, in, out, 1, total, 333);
    double r = tailAbsMax(out[0], total, (uint32_t)(0.1 * rate)) / amp;
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
    return r;
}

static void testDynEq(double rate) {
    float p[1 + 15 * 2];
    p[0] = 0;
    /* Static +6 dB, detector far below its threshold: output is 6 dB up at the centre. */
    fillBand(p + 1, 6, -10, 4);
    double got = sineAmp(rate, 1, p, 0.01f);
    CHECK(fabs(got - 1.9953) < 0.03, "rate %.0f static +6 dB gain %.4f", rate, got);
    /* Two cascaded bands. */
    fillBand(p + 1, 6, -10, 4);
    fillBand(p + 16, 6, -10, 4);
    got = sineAmp(rate, 2, p, 0.01f);
    CHECK(fabs(got - 3.981) < 0.08, "rate %.0f cascaded bands gain %.4f", rate, got);
    /* Dynamic cut: RMS detector, 4:1 above -30 dB. */
    fillBand(p + 1, 0, -30, 4);
    double rmsDb = db(0.5 / sqrt(2.0));
    double cut = -(rmsDb + 30.0) * 0.75;
    got = db(sineAmp(rate, 1, p, 0.5f));
    CHECK(fabs(got - cut) < 0.5, "rate %.0f dynamic cut %.3f dB vs %.3f", rate, got, cut);
    /* Dynamic boost below the boost threshold. */
    fillBand(p + 1, 0, 0, 1);
    p[1 + 9] = 1; p[1 + 10] = -20; p[1 + 11] = 2; p[1 + 12] = 12;
    double boost = (-20.0 - db(0.01 / sqrt(2.0))) * 0.5;
    got = db(sineAmp(rate, 1, p, 0.01f));
    CHECK(fabs(got - boost) < 0.5, "rate %.0f dynamic boost %.3f dB vs %.3f", rate, got, boost);
    /* Linked groups share one detector: a quiet lane follows a loud one. */
    {
        enum { CH = 2 };
        uint32_t total = (uint32_t)(0.8 * rate);
        for (int linked = 0; linked < 2; linked++) {
            fillBand(p + 1, 0, -30, 4);
            p[0] = (float)linked;
            n60_stage_desc st = stageMask(N60_STAGE_DYN_EQ, 1, 0x3, p, 16);
            n60_graph *g = buildOrDie(rate, 512, CH, &st, 1);
            float **in = alloc2d(CH, total), **out = alloc2d(CH, total);
            for (uint32_t i = 0; i < total; i++) {
                float s = (float)sin(2 * M_PI * 1000.0 * i / rate);
                in[0][i] = 0.5f * s;
                in[1][i] = 0.005f * s;
            }
            render(g, in, out, CH, total, 512);
            uint32_t t = (uint32_t)(0.1 * rate);
            double a0 = tailAbsMax(out[0], total, t) / 0.5, a1 = tailAbsMax(out[1], total, t) / 0.005;
            if (linked) {
                CHECK(fabs(db(a1) - db(a0)) < 0.2, "rate %.0f linked lanes share the cut (%.3f %.3f dB)", rate, db(a0), db(a1));
            } else {
                CHECK(fabs(db(a1)) < 0.2 && db(a0) < -5.0, "rate %.0f unlinked quiet lane stays (%.3f %.3f dB)", rate, db(a0), db(a1));
            }
            n60_graph_retire(g);
            free2d(in, CH);
            free2d(out, CH);
        }
    }
}

/* ---- program FIR ----------------------------------------------------------- */

static void testFir(double rate, uint32_t taps, uint32_t total, uint32_t block, uint32_t declared) {
    float *h = malloc(sizeof(float) * taps);
    for (uint32_t i = 0; i < taps; i++) h[i] = noise() * 2.0f / (float)(taps < 64 ? 1 : sqrt((double)taps));
    n60_stage_desc st = stage(N60_STAGE_FIR, 1, N60_LANE_ALL, h, taps);
    st.capacityFrames = declared;
    n60_graph *g = buildOrDie(rate, 512, 2, &st, 1);
    float **in = alloc2d(2, total), **out = alloc2d(2, total);
    for (uint32_t i = 0; i < total; i++) { in[0][i] = noise(); in[1][i] = noise() * 0.5f; }
    render(g, in, out, 2, total, block);
    CHECK(n60_graph_latency_frames(g) == 256 + declared, "latency %u", n60_graph_latency_frames(g));
    double worst = 0, peak = 0;
    for (uint32_t c = 0; c < 2; c++) {
        for (uint32_t n = 0; n < total; n++) {
            double ref = 0;
            if (n >= 256) {
                uint32_t m = n - 256;
                uint32_t kmax = m < taps - 1 ? m : taps - 1;
                for (uint32_t k = 0; k <= kmax; k++) ref += (double)h[k] * in[c][m - k];
            }
            worst = fmax(worst, fabs(out[c][n] - ref));
            peak = fmax(peak, fabs(ref));
        }
    }
    CHECK(worst < 2e-5 * fmax(peak, 1.0) + 1e-6, "rate %.0f taps %u block %u: worst error %.3g (peak %.3g)", rate, taps,
          block, worst, peak);
    n60_graph_retire(g);
    free2d(in, 2);
    free2d(out, 2);
    free(h);
}

static void testFirImpulse(double rate, uint32_t taps) {
    float *h = malloc(sizeof(float) * taps);
    for (uint32_t i = 0; i < taps; i++) h[i] = noise();
    uint32_t total = 256 + taps + 600;
    n60_stage_desc st = stage(N60_STAGE_FIR, 1, N60_LANE_ALL, h, taps);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    in[0][0] = 1.0f;
    render(g, in, out, 1, total, 512);
    double worst = 0;
    for (uint32_t n = 0; n < total; n++) {
        double ref = (n >= 256 && n - 256 < taps) ? h[n - 256] : 0.0;
        worst = fmax(worst, fabs(out[0][n] - ref));
    }
    CHECK(worst < 2e-5, "rate %.0f impulse response of %u taps: worst error %.3g", rate, taps, worst);
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
    free(h);
}

/* ---- denoiser -------------------------------------------------------------- */

/* params: tuning, quality, reduction, thresholdDb, protect, protLo, protHi, command, revision */
static void testDenoiserReconstruction(double rate, uint32_t quality) {
    const uint32_t n = 1024u << quality;
    const uint32_t total = 8 * n;
    float p[9] = {1, (float)quality, 0, -60, 0, 0, 0, 0, 0};
    n60_stage_desc st = stage(N60_STAGE_DENOISER, 1, N60_LANE_ALL, p, 9);
    n60_graph *g = buildOrDie(rate, 512, 2, &st, 1);
    float **in = alloc2d(2, total), **out = alloc2d(2, total);
    for (uint32_t i = 0; i < total; i++) { in[0][i] = noise(); in[1][i] = 0.3f * (float)sin(0.01 * i); }
    render(g, in, out, 2, total, 300);
    CHECK(n60_graph_latency_frames(g) == n, "denoiser latency %u vs %u", n60_graph_latency_frames(g), n);
    double worst = 0, early = 0;
    for (uint32_t c = 0; c < 2; c++) {
        for (uint32_t i = 0; i < n; i++) early = fmax(early, fabs(out[c][i]));
        /* The first hop after the latency is a fade-in (half a window overlap). */
        for (uint32_t i = n + n / 2; i < total; i++) worst = fmax(worst, fabs(out[c][i] - in[c][i - n]));
    }
    CHECK(early == 0.0, "rate %.0f q%u output before the first frame is silent (%g)", rate, quality, early);
    CHECK(worst < 2e-5, "rate %.0f q%u pass-through reconstruction error %.3g", rate, quality, worst);
    n60_graph_retire(g);
    free2d(in, 2);
    free2d(out, 2);
}

static double rmsRange(const float *x, uint32_t a, uint32_t b) {
    double s = 0;
    for (uint32_t i = a; i < b; i++) s += (double)x[i] * x[i];
    return sqrt(s / (b - a));
}

static void testDenoiserReduction(double rate) {
    const uint32_t total = (uint32_t)(3.2 * rate);
    float p[9] = {2, 0, 1, -30, 0, 0, 0, 0, 0};
    n60_stage_desc st = stage(N60_STAGE_DENOISER, 1, N60_LANE_ALL, p, 9);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    float **in = alloc2d(1, total), **out = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) {
        in[0][i] = 0.1f * noise();
        if (i >= (uint32_t)(2.4 * rate)) in[0][i] += 0.3f * (float)sin(2 * M_PI * 1000.0 * i / rate);
    }
    n60_param_record recs[2] = {{1, 7, 1.0f, 0}, {1, 8, 1.0f, 0}};  /* capture a profile, revision 1 */
    CHECK(n60_graph_post_params(g, recs, 2) == N60_STATUS_OK, "post profile command");
    renderRange(g, in, out, 1, 0, total, 512);
    uint32_t a = (uint32_t)(1.9 * rate), b = (uint32_t)(2.3 * rate);
    double rin = rmsRange(in[0], a, b), rout = rmsRange(out[0], a, b);
    CHECK(rout < 0.5 * rin, "rate %.0f noise only: %.3g -> %.3g (%.1f dB)", rate, rin, rout, db(rout / rin));
    /* The sine survives: project the tail on a 1 kHz quadrature pair. */
    uint32_t t0 = (uint32_t)(2.9 * rate);
    uint32_t lat = n60_graph_latency_frames(g);
    double sa = 0, sb = 0;
    for (uint32_t i = t0; i < total; i++) {
        double ph = 2 * M_PI * 1000.0 * ((double)i - lat) / rate;
        sa += out[0][i] * sin(ph);
        sb += out[0][i] * cos(ph);
    }
    double amp = 2.0 * sqrt(sa * sa + sb * sb) / (total - t0);
    CHECK(fabs(db(amp / 0.3)) < 1.5, "rate %.0f sine amplitude %.3f (%.2f dB)", rate, amp, db(amp / 0.3));
    n60_graph_retire(g);
    free2d(in, 1);
    free2d(out, 1);
}

/* Energy of x[a,b) in 41 narrow slots from 1 kHz to 2 kHz (Goertzel). */
static double bandEnergy(const float *x, uint32_t a, uint32_t b, double rate) {
    double sum = 0;
    for (int k = 0; k < 41; k++) {
        double w = 2 * M_PI * (1000.0 + 25.0 * k) / rate, c = 2 * cos(w), s1 = 0, s2 = 0;
        for (uint32_t i = a; i < b; i++) {
            double s0 = x[i] + c * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        sum += s1 * s1 + s2 * s2 - c * s1 * s2;
    }
    return sum;
}

static void runNoise(double rate, const float *p, float **in, float **out, uint32_t total, uint32_t block) {
    n60_stage_desc st = stage(N60_STAGE_DENOISER, 1, N60_LANE_ALL, p, 9);
    n60_graph *g = buildOrDie(rate, 512, 1, &st, 1);
    n60_param_record recs[2] = {{1, 7, 1.0f, 0}, {1, 8, 1.0f, 0}};
    CHECK(n60_graph_post_params(g, recs, 2) == N60_STATUS_OK, "post profile command");
    render(g, in, out, 1, total, block);
    n60_graph_retire(g);
}

static void testDenoiserProtectAndBlocks(double rate) {
    const uint32_t total = (uint32_t)(2.6 * rate);
    float **in = alloc2d(1, total), **o1 = alloc2d(1, total), **o2 = alloc2d(1, total);
    for (uint32_t i = 0; i < total; i++) in[0][i] = 0.1f * noise();
    /* A protected 1..2 kHz band keeps its energy; the same run unprotected loses most of it. */
    float prot[9] = {2, 0, 1, -30, 1, 900, 2100, 0, 0};
    float open[9] = {2, 0, 1, -30, 0, 0, 0, 0, 0};
    uint32_t a = (uint32_t)(2.0 * rate);
    runNoise(rate, prot, in, o1, total, 512);
    runNoise(rate, open, in, o2, total, 512);
    double ein = bandEnergy(in[0], a, total, rate);
    double rp = bandEnergy(o1[0], a, total, rate) / ein, ru = bandEnergy(o2[0], a, total, rate) / ein;
    CHECK(rp > 0.7 && rp < 1.4, "rate %.0f protected band energy ratio %.3f", rate, rp);
    CHECK(ru < 0.5 * rp, "rate %.0f unprotected band energy ratio %.3f vs protected %.3f", rate, ru, rp);
    /* Active reduction gives the same samples for any block size. */
    runNoise(rate, open, in, o1, total, 77);
    CHECK(memcmp(o1[0], o2[0], sizeof(float) * total) == 0, "rate %.0f denoiser output depends on block size", rate);
    free2d(in, 1);
    free2d(o1, 1);
    free2d(o2, 1);
}

/* ---- validation, ordering, latency ----------------------------------------- */

static void testValidation(void) {
    float comp[10] = {-20, 4, 0, 1, 100, 0, 0, 0, 0, 0};
    float gain = 1.0f;
    float peq[4] = {0, 1000, 3, 1};
    float band[16] = {0, 0, 1000, 1, 0, -30, 4, -24, 10, 10, 0, -60, 1, 0, 1, 20};
    n60_stage_desc st[3];

    st[0] = stage(N60_STAGE_COMPRESSOR, 1, N60_LANE_ALL, comp, 10);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_OK, "compressor builds");
    float bad[10];
    memcpy(bad, comp, sizeof bad); bad[1] = 0.5f;
    st[0] = stage(N60_STAGE_COMPRESSOR, 1, N60_LANE_ALL, bad, 10);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "ratio below 1 rejected");
    st[0] = stage(N60_STAGE_COMPRESSOR, 1, N60_LANE_ALL, comp, 9);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "wrong parameter count rejected");
    st[0] = stageMask(N60_STAGE_COMPRESSOR, 1, 0x8, comp, 10);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "lane mask beyond the channels rejected");
    st[0] = stageMask(N60_STAGE_COMPRESSOR, 1, 0x3, comp, 10);
    st[0].laneA = 1;
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "mask and laneA together rejected");
    st[0] = stageMask(N60_STAGE_GAIN, 1, 0x3, &gain, 1);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "lane mask on a basic stage rejected");
    st[0] = stage(N60_STAGE_COMPRESSOR, 1, N60_LANE_ALL, comp, 10);
    st[0].reserved = 1;
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "reserved field rejected");
    /* Order: PEQ, dynamic EQ, compressor, expander is fine; compressor before PEQ is not. */
    float exp6[6] = {-50, 2, -20, 1, 100, 0};
    st[0] = stage(N60_STAGE_PEQ, 1, N60_LANE_ALL, peq, 4);
    st[1] = stage(N60_STAGE_DYN_EQ, 2, N60_LANE_ALL, band, 16);
    st[2] = stage(N60_STAGE_COMPRESSOR, 3, N60_LANE_ALL, comp, 10);
    CHECK(tryBuild(48000, 2, st, 3) == N60_STATUS_OK, "PEQ, dynamic EQ, compressor in order");
    st[0] = stage(N60_STAGE_COMPRESSOR, 3, N60_LANE_ALL, comp, 10);
    st[1] = stage(N60_STAGE_EXPANDER, 4, N60_LANE_ALL, exp6, 6);
    CHECK(tryBuild(48000, 2, st, 2) == N60_STATUS_OK, "compressor then expander");
    st[0] = stage(N60_STAGE_EXPANDER, 4, N60_LANE_ALL, exp6, 6);
    st[1] = stage(N60_STAGE_COMPRESSOR, 3, N60_LANE_ALL, comp, 10);
    CHECK(tryBuild(48000, 2, st, 2) == N60_STATUS_BAD_ARGUMENT, "expander before compressor rejected");
    st[0] = stage(N60_STAGE_COMPRESSOR, 3, N60_LANE_ALL, comp, 10);
    st[1] = stage(N60_STAGE_PEQ, 1, N60_LANE_ALL, peq, 4);
    CHECK(tryBuild(48000, 2, st, 2) == N60_STATUS_BAD_ARGUMENT, "compressor before PEQ rejected");
    /* Dynamic EQ band limits. */
    float badBand[16];
    memcpy(badBand, band, sizeof badBand); badBand[2] = 30000.0f;
    st[0] = stage(N60_STAGE_DYN_EQ, 2, N60_LANE_ALL, badBand, 16);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "band above Nyquist rejected");
    st[0] = stage(N60_STAGE_DYN_EQ, 2, N60_LANE_ALL, band, 15);
    CHECK(tryBuild(48000, 2, st, 1) == N60_STATUS_BAD_ARGUMENT, "partial band rejected");
    /* FIR size limits. */
    float *taps = calloc(N60_FIR_MAX_TAPS + 1, sizeof(float));
    st[0] = stage(N60_STAGE_FIR, 1, N60_LANE_ALL, taps, N60_FIR_MAX_TAPS);
    CHECK(tryBuild(48000, 1, st, 1) == N60_STATUS_OK, "32768 taps build");
    st[0] = stage(N60_STAGE_FIR, 1, N60_LANE_ALL, taps, N60_FIR_MAX_TAPS + 1);
    CHECK(tryBuild(48000, 1, st, 1) == N60_STATUS_BAD_ARGUMENT, "too many taps rejected");
    st[0] = stage(N60_STAGE_FIR, 1, N60_LANE_ALL, taps, 0);
    CHECK(tryBuild(48000, 1, st, 1) == N60_STATUS_BAD_ARGUMENT, "no taps rejected");
    free(taps);
    float dn[9] = {1, 3, 0.5f, -60, 0, 0, 0, 0, 0};
    st[0] = stage(N60_STAGE_DENOISER, 1, N60_LANE_ALL, dn, 9);
    CHECK(tryBuild(48000, 1, st, 1) == N60_STATUS_BAD_ARGUMENT, "denoiser quality 3 rejected");
    /* Old ABI numbers are gone. */
    n60_graph_desc d = makeDesc(48000, 512, 1, st, 0);
    d.abiVersion = 2;
    n60_graph *g = NULL;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH, "ABI 2 refused");
}

static void testLatencyAccounting(double rate) {
    float dn[9] = {1, 0, 0.5f, -60, 0, 0, 0, 0, 0};
    float fir[10];
    for (int i = 0; i < 10; i++) fir[i] = i == 0 ? 1.0f : 0.0f;
    float delay = 5.0f;
    n60_stage_desc st[3] = {
        stage(N60_STAGE_DENOISER, 1, 0, dn, 9),
        stage(N60_STAGE_FIR, 2, N60_LANE_ALL, fir, 10),
        stage(N60_STAGE_DELAY, 3, 1, &delay, 1),
    };
    st[1].capacityFrames = 7;
    st[2].capacityFrames = 100;
    n60_graph *g = buildOrDie(rate, 512, 2, st, 3);
    float **in = alloc2d(2, 16), **out = alloc2d(2, 16);
    render(g, in, out, 2, 16, 16);
    /* Lane 0: 1024 + 263; lane 1: 263 + 5. */
    CHECK(n60_graph_latency_frames(g) == 1024 + 263, "latency %u", n60_graph_latency_frames(g));
    n60_graph_retire(g);
    free2d(in, 2);
    free2d(out, 2);
}

int main(void) {
    testValidation();
    for (size_t r = 0; r < NRATES; r++) {
        double rate = kRates[r];
        testCompressorCurve(rate);
        testCompressorLinked(rate);
        testCompressorLive(rate);
        testExpander(rate);
        testDynEq(rate);
        testFir(rate, 1, 3000, 97, 0);
        testFir(rate, 255, 3000, 512, 0);
        testFir(rate, 256, 3000, 1, 3);
        testFir(rate, 257, 3000, 333, 0);
        testFir(rate, 1000, 4000, 512, 0);
        testFirImpulse(rate, N60_FIR_MAX_TAPS);
        testDenoiserReconstruction(rate, 0);
        testDenoiserReconstruction(rate, 1);
        testDenoiserReconstruction(rate, 2);
        testDenoiserReduction(rate);
        testDenoiserProtectAndBlocks(rate);
        testLatencyAccounting(rate);
    }
    testFir(48000, N60_FIR_MAX_TAPS, 40000, 512, 0);  /* wraps all 128 partitions */
    testFir(48000, 4097, 12000, 512, 0);
    if (failures) {
        fprintf(stderr, "n60core DSP stages: %d check(s) failed\n", failures);
        return 1;
    }
    printf("n60core DSP stages: all checks passed\n");
    return 0;
}
