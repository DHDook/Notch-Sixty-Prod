/* E6 S7b: deterministic tests for BASS_MGMT driving 1 to 8 sub lanes (ABI v7), through the C ABI at the
 * eight standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
 *
 * Covers: sum correctness for 1, 2, 4 and 8 subs, per-sub gain, polarity, EQ and (DELAY stage) delay,
 * single-sub bit-exactness (a one-sub parameter list is the ABI v6 list; sub 0 does not depend on the other
 * subs), LFE routing (including an LFE lane that is also a sub lane), parameter validation, click-free live
 * edits (gain, polarity, EQ Hz/dB) with untouched subs unchanged to the bit, and the faded rebuild when the
 * sub count changes. Zero allocation is covered in test_alloc.cpp. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define BLOCK 1024u
#define LANES 11u    /* 0, 1 mains; 2 LFE; 3..10 subs */
#define MAXSUB 8u
static int failures = 0;
/* Mode of the lists buildCfg emits: 1 = host-weighted (no 1/N), 0 = default (1/N). Most tests run host-weighted so
 * N identical subs compare bit for bit with one; testModes covers both. */
static int gWeighted = 1;
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

static n60_graph_desc desc(double rate, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = BLOCK;
    d.inputChannels = d.outputChannels = LANES;
    d.stages = st;
    d.stageCount = n;
    return d;
}

/* ---- parameter list builder ------------------------------------------------ */

typedef struct {
    uint32_t lane;
    float gainDb, pol;
    uint32_t nEq;
    float sec[4][4];  /* type, Hz, dB, Q */
} SubSpec;

typedef struct {
    float p[160];
    uint32_t n;
    uint32_t gainIdx[MAXSUB], polIdx[MAXSUB], eqIdx[MAXSUB];
    uint32_t ext;  /* index of the extension word, 0 when the list has none (a v6 one-sub list) */
} Cfg;

static SubSpec subDefault(uint32_t lane) {
    SubSpec s;
    memset(&s, 0, sizeof s);
    s.lane = lane;
    return s;
}

static void buildCfg(Cfg *c, float xover, float redirectDb, float lfeLane, const SubSpec *subs, uint32_t count) {
    memset(c, 0, sizeof *c);
    float *p = c->p;
    p[0] = xover;
    p[1] = redirectDb;
    p[2] = (float)subs[0].lane;
    p[3] = lfeLane;
    p[4] = 120;
    p[5] = 0;
    p[6] = subs[0].gainDb;
    p[7] = subs[0].pol;
    p[8] = (float)subs[0].nEq;
    c->gainIdx[0] = 6;
    c->polIdx[0] = 7;
    c->eqIdx[0] = 9;
    uint32_t n = 9;
    for (uint32_t k = 0; k < subs[0].nEq; k++) for (int j = 0; j < 4; j++) p[n++] = subs[0].sec[k][j];
    if (count > 1 || gWeighted) {
        c->ext = n;
        p[n++] = (float)(count - 1) + (gWeighted ? 8.0f : 0.0f);
        for (uint32_t q = 1; q < count; q++) {
            p[n++] = (float)subs[q].lane;
            c->gainIdx[q] = n;
            p[n++] = subs[q].gainDb;
            c->polIdx[q] = n;
            p[n++] = subs[q].pol;
            p[n++] = (float)subs[q].nEq;
            c->eqIdx[q] = n;
            for (uint32_t k = 0; k < subs[q].nEq; k++) for (int j = 0; j < 4; j++) p[n++] = subs[q].sec[k][j];
        }
    }
    c->n = n;
}

/* ---- streaming rig that records every output lane ---------------------------- */

typedef struct {
    double rate;
    n60_graph *g;
    uint64_t pos;
    uint32_t cap;
    float *rec;  /* LANES * cap */
    double freq[LANES], amp[LANES];
    int impulseAt;  /* >= 0: lane 0 carries a single 0.5 impulse at that frame instead of tones */
} Rig;

static void rigInit(Rig *r, double rate, n60_graph *g, double maxSeconds) {
    memset(r, 0, sizeof *r);
    r->rate = rate;
    r->g = g;
    r->cap = (uint32_t)(maxSeconds * rate) + BLOCK;
    r->rec = (float *)calloc((size_t)LANES * r->cap, sizeof(float));
    r->impulseAt = -1;
}
static void rigFree(Rig *r) {
    free(r->rec);
    n60_graph_retire(r->g);
}
static float *lane(Rig *r, uint32_t l) { return r->rec + (size_t)l * r->cap; }

static void render(Rig *r, uint32_t frames) {
    static float in[LANES][BLOCK], out[LANES][BLOCK];
    while (frames > 0) {
        const uint32_t n = frames < BLOCK ? frames : BLOCK;
        const float *ip[LANES];
        float *op[LANES];
        for (uint32_t c = 0; c < LANES; c++) {
            for (uint32_t i = 0; i < n; i++) {
                in[c][i] = (float)(r->amp[c] * sin(2.0 * kPi * r->freq[c] * (double)(r->pos + i) / r->rate));
                if (r->impulseAt >= 0) in[c][i] = (c == 0 && (int64_t)(r->pos + i) == r->impulseAt) ? 0.5f : 0.0f;
            }
            ip[c] = in[c];
            op[c] = out[c];
        }
        n60_status s = n60_graph_process(r->g, ip, op, n);
        CHECK(s == N60_STATUS_OK, "process status %d", s);
        for (uint32_t c = 0; c < LANES; c++) {
            if (r->pos + n <= r->cap) memcpy(lane(r, c) + r->pos, out[c], n * sizeof(float));
        }
        r->pos += n;
        frames -= n;
    }
}

static uint32_t framesFor(double rate, double sec) { return (uint32_t)ceil(rate * sec); }

static double peakRange(const float *x, uint32_t from, uint32_t to) {
    double p = 0;
    for (uint32_t i = from; i < to; i++) p = fmax(p, fabs(x[i]));
    return p;
}
static double maxStep(const float *x, uint32_t from, uint32_t to) {
    double w = 0;
    for (uint32_t i = from + 1; i < to; i++) w = fmax(w, fabs((double)x[i] - (double)x[i - 1]));
    return w;
}
static int bitEqual(const float *a, const float *b, uint32_t from, uint32_t to) {
    for (uint32_t i = from; i < to; i++) if (memcmp(a + i, b + i, sizeof(float)) != 0) return 0;
    return 1;
}

static n60_graph *buildGraph(double rate, const Cfg *c, uint64_t mask, const n60_stage_desc *extra, uint32_t extraN) {
    n60_stage_desc st[1 + 8];
    st[0] = stgMask(N60_STAGE_BASS_MGMT, 1, mask, c->p, c->n);
    for (uint32_t i = 0; i < extraN; i++) st[1 + i] = extra[i];
    n60_graph_desc d = desc(rate, st, 1 + extraN);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build status %d", s);
    return s == N60_STATUS_OK ? g : NULL;
}

static void tones(Rig *r, double lowHz, double a0, double a1) {
    r->freq[0] = r->freq[1] = lowHz;
    r->amp[0] = a0;
    r->amp[1] = a1;
}

/* One tone source, N identical subs on lanes 3..3+N-1. */
static Rig uniformRig(double rate, uint32_t n, float redirectDb, double seconds) {
    SubSpec sp[MAXSUB];
    for (uint32_t q = 0; q < n; q++) sp[q] = subDefault(3 + q);
    Cfg c;
    buildCfg(&c, 200, redirectDb, -1, sp, n);
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), seconds);
    tones(&r, 50, 0.5, 0.3);
    render(&r, framesFor(rate, seconds));
    return r;
}

static void testSums(double rate) {
    const double sec = 0.3;
    Rig ref = uniformRig(rate, 1, 0, sec);
    const uint32_t len = framesFor(rate, sec), w0 = len - framesFor(rate, 0.05);
    const double refPk = peakRange(lane(&ref, 3), w0, len);
    CHECK(refPk > 0.7 && refPk < 0.82, "rate %.0f: one sub carries L+R lows (%.4f)", rate, refPk);
    CHECK(peakRange(lane(&ref, 0), w0, len) < 0.01, "rate %.0f: mains high-passed", rate);
    const uint32_t counts[] = {2, 4, 8};
    for (unsigned k = 0; k < 3; k++) {
        const uint32_t n = counts[k];
        Rig r = uniformRig(rate, n, 0, sec);
        int ok = bitEqual(lane(&r, 0), lane(&ref, 0), 0, len) && bitEqual(lane(&r, 1), lane(&ref, 1), 0, len);
        CHECK(ok, "rate %.0f: %u subs leave the mains unchanged", rate, n);
        for (uint32_t q = 0; q < n; q++) {
            CHECK(bitEqual(lane(&r, 3 + q), lane(&ref, 3), 0, len), "rate %.0f: %u subs, sub %u equals the one-sub output", rate, n, q);
        }
        rigFree(&r);
        /* host-side 1/N normalisation through the redirect gain */
        Rig norm = uniformRig(rate, n, (float)(-20.0 * log10((double)n)), sec);
        for (uint32_t q = 0; q < n; q++) {
            const double pk = peakRange(lane(&norm, 3 + q), w0, len);
            CHECK(fabs(pk - refPk / n) < 0.01 * refPk / n + 1e-6, "rate %.0f: %u subs at 1/N: %.5f vs %.5f", rate, n, pk, refPk / n);
        }
        rigFree(&norm);
    }
    rigFree(&ref);
}

static void testGainPolarity(double rate) {
    const double sec = 0.2;
    Rig ref = uniformRig(rate, 1, 0, sec);
    const uint32_t len = framesFor(rate, sec);
    const float gains[4] = {0, -6, 3, -12};
    const float pols[4] = {0, 1, 0, 1};
    SubSpec sp[4];
    for (uint32_t q = 0; q < 4; q++) {
        sp[q] = subDefault(3 + q);
        sp[q].gainDb = gains[q];
        sp[q].pol = pols[q];
    }
    Cfg c;
    buildCfg(&c, 200, 0, -1, sp, 4);
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), sec);
    tones(&r, 50, 0.5, 0.3);
    render(&r, len);
    for (uint32_t q = 0; q < 4; q++) {
        const double lin = pow(10.0, gains[q] / 20.0) * (pols[q] != 0 ? -1.0 : 1.0);
        double err = 0;
        for (uint32_t i = 0; i < len; i++) err = fmax(err, fabs((double)lane(&r, 3 + q)[i] - lin * (double)lane(&ref, 3)[i]));
        CHECK(err < 2e-6, "rate %.0f: sub %u gain %.0f dB pol %.0f error %g", rate, q, gains[q], pols[q], err);
    }
    rigFree(&r);
    rigFree(&ref);
}

static void testEq(double rate) {
    const double sec = 0.4;
    Rig ref = uniformRig(rate, 1, 0, sec);
    const uint32_t len = framesFor(rate, sec), w0 = len - framesFor(rate, 0.05);
    const double refPk = peakRange(lane(&ref, 3), w0, len);
    SubSpec sp[4];
    for (uint32_t q = 0; q < 4; q++) sp[q] = subDefault(3 + q);
    sp[1].nEq = 1;
    { float s[4] = {0, 50, 6, 1}; memcpy(sp[1].sec[0], s, sizeof s); }
    sp[2].nEq = 1;
    { float s[4] = {0, 50, -6, 1}; memcpy(sp[2].sec[0], s, sizeof s); }
    sp[3].nEq = 2;
    { float s[4] = {0, 50, 6, 1}; memcpy(sp[3].sec[0], s, sizeof s); }
    { float s[4] = {0, 50, -6, 1}; memcpy(sp[3].sec[1], s, sizeof s); }
    Cfg c;
    buildCfg(&c, 200, 0, -1, sp, 4);
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), sec);
    tones(&r, 50, 0.5, 0.3);
    render(&r, len);
    const double want[4] = {1.0, 2.0, 0.5, 1.0};
    for (uint32_t q = 0; q < 4; q++) {
        const double ratio = peakRange(lane(&r, 3 + q), w0, len) / refPk;
        CHECK(fabs(ratio - want[q]) < 0.03 * want[q], "rate %.0f: sub %u EQ ratio %.4f vs %.2f", rate, q, ratio, want[q]);
    }
    CHECK(bitEqual(lane(&r, 3), lane(&ref, 3), 0, len), "rate %.0f: the flat sub equals the one-sub output", rate);
    rigFree(&r);
    rigFree(&ref);
}

static void testDelay(double rate) {
    const uint32_t delays[4] = {0, 7, 20, 33};
    SubSpec sp[4];
    for (uint32_t q = 0; q < 4; q++) sp[q] = subDefault(3 + q);
    Cfg c;
    buildCfg(&c, 200, 0, -1, sp, 4);
    float dp[4];
    n60_stage_desc ex[4];
    for (uint32_t q = 0; q < 4; q++) {
        dp[q] = (float)delays[q];
        ex[q] = stg(N60_STAGE_DELAY, 10 + q, 3 + q, &dp[q], 1);
        ex[q].capacityFrames = 64;
    }
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, ex, 4), 0.1);
    r.impulseAt = 100;
    render(&r, framesFor(rate, 0.05));
    const uint32_t len = framesFor(rate, 0.05);
    CHECK(peakRange(lane(&r, 3), 0, len) > 1e-4, "rate %.0f: impulse reaches the subs", rate);
    for (uint32_t q = 1; q < 4; q++) {
        int ok = 1;
        for (uint32_t i = 0; i + delays[q] < len; i++) {
            if (memcmp(lane(&r, 3 + q) + i + delays[q], lane(&r, 3) + i, sizeof(float)) != 0) { ok = 0; break; }
        }
        CHECK(ok, "rate %.0f: sub %u delayed exactly %u frames", rate, q, delays[q]);
    }
    rigFree(&r);
}

static void testSingleSubExact(double rate) {
    const double sec = 0.2;
    const uint32_t len = framesFor(rate, sec);
    SubSpec sp[4];
    for (uint32_t q = 0; q < 4; q++) sp[q] = subDefault(3 + q);
    sp[0].gainDb = -4.5f;
    sp[0].pol = 1;
    sp[0].nEq = 2;
    { float s[4] = {0, 45, 5, 1.2f}; memcpy(sp[0].sec[0], s, sizeof s); }
    { float s[4] = {1, 80, -3, 0.9f}; memcpy(sp[0].sec[1], s, sizeof s); }
    sp[1].gainDb = -2;
    sp[2].nEq = 1;
    { float s[4] = {0, 60, 3, 1}; memcpy(sp[2].sec[0], s, sizeof s); }
    Cfg one, four;
    gWeighted = 0;  /* a pure v6 list */
    buildCfg(&one, 200, 0, 2, sp, 1);
    gWeighted = 1;
    buildCfg(&four, 200, 0, 2, sp, 4);
    CHECK(one.n == 9 + 8, "rate %.0f: a one-sub list is the v6 length (%u)", rate, one.n);
    Rig a, b;
    rigInit(&a, rate, buildGraph(rate, &one, 0x3, NULL, 0), sec);
    rigInit(&b, rate, buildGraph(rate, &four, 0x3, NULL, 0), sec);
    for (Rig *r = &a; r != NULL; r = (r == &a ? &b : NULL)) {
        tones(r, 50, 0.5, 0.3);
        r->freq[2] = 40;
        r->amp[2] = 0.4;
        render(r, len);
    }
    CHECK(bitEqual(lane(&a, 3), lane(&b, 3), 0, len), "rate %.0f: sub 0 does not depend on the other subs", rate);
    CHECK(peakRange(lane(&a, 3), len / 2, len) > 0.3, "rate %.0f: sub 0 carries signal", rate);
    CHECK(peakRange(lane(&a, 2), 0, len) == 0.0 && peakRange(lane(&b, 2), 0, len) == 0.0, "rate %.0f: LFE lane cleared", rate);
    CHECK(bitEqual(lane(&a, 0), lane(&b, 0), 0, len), "rate %.0f: mains equal", rate);
    rigFree(&a);
    rigFree(&b);
}

static void testLfe(double rate) {
    const double sec = 0.3;
    const uint32_t len = framesFor(rate, sec), w0 = len - framesFor(rate, 0.05);
    SubSpec sp[2];
    sp[0] = subDefault(3);
    sp[1] = subDefault(4);
    Cfg c;
    buildCfg(&c, 200, 0, 2, sp, 2);
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), sec);
    r.freq[2] = 40;
    r.amp[2] = 0.5;
    render(&r, len);
    const double pk = peakRange(lane(&r, 3), w0, len);
    CHECK(pk > 0.45 && pk < 0.52, "rate %.0f: LFE reaches the subs (%.4f)", rate, pk);
    CHECK(bitEqual(lane(&r, 3), lane(&r, 4), 0, len), "rate %.0f: both subs get the LFE", rate);
    CHECK(peakRange(lane(&r, 2), 0, len) == 0.0, "rate %.0f: LFE lane cleared", rate);
    rigFree(&r);

    /* the LFE lane is also sub 0's lane: it is read before it is replaced */
    buildCfg(&c, 200, 0, 3, sp, 2);
    rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), sec);
    r.freq[3] = 40;
    r.amp[3] = 0.5;
    render(&r, len);
    const double pk2 = peakRange(lane(&r, 3), w0, len);
    CHECK(fabs(pk2 - pk) < 0.01 && bitEqual(lane(&r, 3), lane(&r, 4), 0, len), "rate %.0f: LFE on a sub lane (%.4f)", rate, pk2);
    rigFree(&r);
}

/* ---- validation ---------------------------------------------------------------- */

static n60_status tryBuild(double rate, const float *p, uint32_t n, uint64_t mask) {
    n60_stage_desc st[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, mask, p, n)};
    n60_graph_desc d = desc(rate, st, 1);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    if (g) n60_graph_retire(g);
    return s;
}

static void testValidation(double rate) {
    SubSpec sp[MAXSUB + 1];
    for (uint32_t q = 0; q < MAXSUB + 1; q++) sp[q] = subDefault(q < MAXSUB ? 3 + q : 2);
    Cfg c;
    buildCfg(&c, 200, 0, -1, sp, 8);
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_OK, "rate %.0f: eight subs accepted", rate);
    buildCfg(&c, 200, 0, -1, sp, 1);
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_OK, "one sub accepted");
    /* nine subs: extension count 8 */
    buildCfg(&c, 200, 0, -1, sp, 8);
    c.p[9] = 16;
    float nine[160];
    memcpy(nine, c.p, sizeof nine);
    uint32_t n = c.n;
    nine[n++] = 2; nine[n++] = 0; nine[n++] = 0; nine[n++] = 0;
    CHECK(tryBuild(rate, nine, n, 0x3) == N60_STATUS_BAD_ARGUMENT, "rate %.0f: extension word 16 refused", rate);
    buildCfg(&c, 200, 0, -1, sp, 2);
    c.p[9] = 0;
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "zero extra subs with data refused");
    buildCfg(&c, 200, 0, -1, sp, 2);
    c.p[9] = -1;
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "negative extension word refused");
    buildCfg(&c, 200, 0, -1, sp, 2);
    c.p[9] = 1.5f;
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "fractional extension word refused");
    buildCfg(&c, 200, 0, -1, sp, 1);
    CHECK(c.ext != 0 && c.p[c.ext] == 8 && tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_OK, "one host-weighted sub accepted");
    buildCfg(&c, 200, 0, -1, sp, 3);
    CHECK(tryBuild(rate, c.p, c.n - 1, 0x3) == N60_STATUS_BAD_ARGUMENT, "truncated list refused");
    c.p[c.n] = 0;
    CHECK(tryBuild(rate, c.p, c.n + 1, 0x3) == N60_STATUS_BAD_ARGUMENT, "trailing value refused");
    buildCfg(&c, 200, 0, -1, sp, 3);
    c.p[c.gainIdx[2] - 1] = 3;  /* duplicate lane with sub 0 */
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "duplicate sub lane refused");
    buildCfg(&c, 200, 0, -1, sp, 3);
    c.p[c.gainIdx[1] - 1] = 1;  /* a main lane */
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "sub lane inside the mask refused");
    buildCfg(&c, 200, 0, -1, sp, 3);
    c.p[c.gainIdx[1] - 1] = 11;  /* out of range */
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "sub lane out of range refused");
    buildCfg(&c, 200, 0, -1, sp, 3);
    c.p[c.gainIdx[1]] = 30;
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "sub gain out of range refused");
    buildCfg(&c, 200, 0, -1, sp, 3);
    c.p[c.polIdx[2]] = 2;
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "polarity 2 refused");
    buildCfg(&c, 200, 0, 1, sp, 3);
    CHECK(tryBuild(rate, c.p, c.n, 0x3) == N60_STATUS_BAD_ARGUMENT, "LFE lane inside the mask refused");

    /* live posts */
    SubSpec s2[3];
    for (uint32_t q = 0; q < 3; q++) s2[q] = subDefault(3 + q);
    s2[2].nEq = 1;
    { float s[4] = {0, 50, 6, 1}; memcpy(s2[2].sec[0], s, sizeof s); }
    buildCfg(&c, 200, 0, -1, s2, 3);
    n60_graph *g = buildGraph(rate, &c, 0x3, NULL, 0);
    if (!g) return;
    n60_param_record r;
    memset(&r, 0, sizeof r);
    r.stageId = 1;
    r.paramIndex = c.gainIdx[2]; r.value = -9;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "extra sub gain is live");
    r.paramIndex = c.polIdx[1]; r.value = 1;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "extra sub polarity is live");
    r.paramIndex = 7; r.value = 1;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "sub 0 polarity is live");
    r.paramIndex = c.eqIdx[2] + 2; r.value = -4;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "section dB is live");
    r.paramIndex = c.eqIdx[2] + 1; r.value = 70;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "section Hz is live");
    r.paramIndex = c.eqIdx[2]; r.value = 1;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_UNSUPPORTED, "section type is not live");
    r.paramIndex = c.ext; r.value = 2;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_UNSUPPORTED, "sub count / mode is not live");
    r.paramIndex = c.gainIdx[2] - 1; r.value = 9;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_UNSUPPORTED, "sub lane is not live");
    r.paramIndex = c.gainIdx[2]; r.value = 99;
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_BAD_ARGUMENT, "gain out of range refused");
    r.paramIndex = c.eqIdx[2] + 1; r.value = (float)(rate);
    CHECK(n60_graph_post_params(g, &r, 1) == N60_STATUS_BAD_ARGUMENT, "section Hz above Nyquist refused");
    n60_graph_retire(g);
}

/* ---- live edits ---------------------------------------------------------------- */

static void fourSubsWithEq(SubSpec *sp) {
    for (uint32_t q = 0; q < 4; q++) {
        sp[q] = subDefault(3 + q);
        sp[q].nEq = 1;
        float s[4] = {0, 50, 3, 1};
        memcpy(sp[q].sec[0], s, sizeof s);
    }
}

static void testLiveEdits(double rate) {
    const double pre = 0.15, post = 0.15;
    const uint32_t a = framesFor(rate, pre), b = framesFor(rate, post);
    SubSpec sp[4];
    fourSubsWithEq(sp);
    Cfg c;
    buildCfg(&c, 200, 0, -1, sp, 4);
    Rig ed, un;
    rigInit(&ed, rate, buildGraph(rate, &c, 0x3, NULL, 0), 0.4);
    rigInit(&un, rate, buildGraph(rate, &c, 0x3, NULL, 0), 0.4);
    tones(&ed, 50, 0.4, 0.4);
    tones(&un, 50, 0.4, 0.4);
    render(&ed, a);
    render(&un, a);
    n60_param_record rec[5];
    memset(rec, 0, sizeof rec);
    rec[0] = (n60_param_record){1, c.gainIdx[2], -20, 0};
    rec[1] = (n60_param_record){1, c.polIdx[1], 1, 0};
    rec[2] = (n60_param_record){1, c.eqIdx[3] + 2, -6, 0};
    rec[3] = (n60_param_record){1, c.eqIdx[3] + 1, 70, 0};
    CHECK(n60_graph_post_params(ed.g, rec, 4) == N60_STATUS_OK, "post live edits");
    render(&ed, b);
    render(&un, b);
    const uint32_t total = a + b;
    CHECK(bitEqual(lane(&ed, 3), lane(&un, 3), 0, total), "rate %.0f: untouched sub 0 unchanged to the bit", rate);
    CHECK(bitEqual(lane(&ed, 0), lane(&un, 0), 0, total), "rate %.0f: mains unchanged", rate);
    const uint32_t settle = framesFor(rate, 0.04);
    for (uint32_t q = 1; q < 4; q++) {
        const float *x = lane(&ed, 3 + q);
        const double steady = fmax(maxStep(x, a - settle, a), maxStep(x, total - settle, total));
        const double worst = maxStep(x, a - settle, total);
        CHECK(worst < 3.0 * steady, "rate %.0f: sub %u live edit step %g vs steady %g", rate, q, worst, steady);
    }
    const double g2 = peakRange(lane(&ed, 5), total - framesFor(rate, 0.05), total) /
                      peakRange(lane(&un, 5), total - framesFor(rate, 0.05), total);
    CHECK(fabs(g2 - 0.1) < 0.005, "rate %.0f: sub 2 settled at -20 dB (%.4f)", rate, g2);
    const float *p1 = lane(&ed, 4), *u1 = lane(&un, 4);
    CHECK(fabs((double)p1[total - 1] + (double)u1[total - 1]) < 1e-6, "rate %.0f: sub 1 polarity inverted", rate);
    rigFree(&ed);
    rigFree(&un);
}

static void testSubCountRebuild(double rate) {
    SubSpec sp[4];
    fourSubsWithEq(sp);
    Cfg two, four;
    buildCfg(&two, 200, -6, -1, sp, 2);
    buildCfg(&four, 200, -6, -1, sp, 4);
    Rig r;
    rigInit(&r, rate, buildGraph(rate, &two, 0x3, NULL, 0), 1.0);
    tones(&r, 50, 0.4, 0.4);
    render(&r, framesFor(rate, 0.15));
    const uint32_t before = (uint32_t)r.pos;
    CHECK(peakRange(lane(&r, 5), 0, before) == 0.0, "rate %.0f: lane 5 silent with two subs", rate);
    n60_stage_desc st[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, four.p, four.n)};
    n60_graph_desc d = desc(rate, st, 1);
    CHECK(n60_graph_publish(r.g, &d) == N60_STATUS_OK, "publish four subs");
    n60_rebuild_status rs;
    int guard = 0;
    do {
        render(&r, BLOCK);
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        n60_graph_get_rebuild_status(r.g, &rs);
    } while ((rs.state != 0 || rs.completed == 0) && ++guard < 4000);
    render(&r, framesFor(rate, 0.1));
    uint32_t mid = (uint32_t)r.pos;
    CHECK(rs.completed == 1, "rate %.0f: rebuild completed", rate);
    const double steady0 = maxStep(lane(&r, 3), before - framesFor(rate, 0.04), before);
    for (uint32_t q = 0; q < 4; q++) {
        const double w = maxStep(lane(&r, 3 + q), before, mid);
        CHECK(w < 3.0 * steady0, "rate %.0f: sub %u step across 2 to 4 subs %g vs %g", rate, q, w, steady0);
    }
    const double pk3 = peakRange(lane(&r, 6), mid - framesFor(rate, 0.05), mid);
    const double pk0 = peakRange(lane(&r, 3), mid - framesFor(rate, 0.05), mid);
    CHECK(pk3 > 0.5 * pk0 && fabs(pk3 - pk0) < 0.01 * pk0, "rate %.0f: new sub matches sub 0 (%.4f vs %.4f)", rate, pk3, pk0);
    /* back to two subs: the dropped lanes fall silent without a click */
    n60_stage_desc st2[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, two.p, two.n)};
    d = desc(rate, st2, 1);
    CHECK(n60_graph_publish(r.g, &d) == N60_STATUS_OK, "publish two subs");
    guard = 0;
    uint64_t done = rs.completed;
    do {
        render(&r, BLOCK);
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        n60_graph_get_rebuild_status(r.g, &rs);
    } while ((rs.state != 0 || rs.completed == done) && ++guard < 4000);
    const uint32_t m2 = (uint32_t)r.pos;
    render(&r, framesFor(rate, 0.1));
    const uint32_t end = (uint32_t)r.pos;
    CHECK(peakRange(lane(&r, 6), m2 + framesFor(rate, 0.02), end) == 0.0, "rate %.0f: dropped sub lane silent", rate);
    for (uint32_t q = 0; q < 4; q++) {
        const double w = maxStep(lane(&r, 3 + q), mid, end);
        CHECK(w < 3.0 * steady0, "rate %.0f: sub %u step across 4 to 2 subs %g vs %g", rate, q, w, steady0);
    }
    rigFree(&r);
}

/* ---- default (1/N) and host-weighted modes -------------------------------------- */

static void testModes(double rate) {
    const double sec = 0.3;
    const uint32_t len = framesFor(rate, sec), w0 = len - framesFor(rate, 0.05);
    const uint32_t counts[] = {1, 2, 4, 8};
    gWeighted = 1;
    Rig ref = uniformRig(rate, 1, 0, sec);  /* one sub: both modes give this */
    const double refPk = peakRange(lane(&ref, 3), w0, len);
    gWeighted = 0;
    Rig v6 = uniformRig(rate, 1, 0, sec);   /* a pure v6 list (no extension word) */
    CHECK(bitEqual(lane(&v6, 3), lane(&ref, 3), 0, len), "rate %.0f: v6 one-sub list equals the host-weighted one-sub output", rate);
    rigFree(&v6);
    for (unsigned k = 0; k < 4; k++) {
        const uint32_t n = counts[k];
        gWeighted = 0;
        Rig d = uniformRig(rate, n, 0, sec);
        gWeighted = 1;
        Rig w = uniformRig(rate, n, 0, sec);
        for (uint32_t q = 0; q < n; q++) {
            CHECK(bitEqual(lane(&w, 3 + q), lane(&ref, 3), 0, len), "rate %.0f: host-weighted %u subs, sub %u passes the sum through", rate, n, q);
            const double pk = peakRange(lane(&d, 3 + q), w0, len);
            CHECK(fabs(pk - refPk / n) < 0.005 * refPk / n + 1e-6, "rate %.0f: default %u subs, sub %u at 1/N (%.5f vs %.5f)", rate, n, q, pk, refPk / n);
            double err = 0;
            for (uint32_t i = 0; i < len; i++) err = fmax(err, fabs((double)lane(&d, 3 + q)[i] - (double)lane(&ref, 3)[i] / n));
            CHECK(err < 1e-6, "rate %.0f: default %u subs, sub %u equals the sum / N (err %g)", rate, n, q, err);
        }
        if (n == 1) CHECK(bitEqual(lane(&d, 3), lane(&w, 3), 0, len), "rate %.0f: one sub is identical in both modes", rate);
        /* the coherent acoustic sum of the default mode is the level of one sub */
        double acc = 0;
        for (uint32_t i = w0; i < len; i++) {
            double t = 0;
            for (uint32_t q = 0; q < n; q++) t += lane(&d, 3 + q)[i];
            acc = fmax(acc, fabs(t));
        }
        CHECK(fabs(acc - refPk) < 0.005 * refPk, "rate %.0f: default %u subs sum acoustically to one sub (%.5f vs %.5f)", rate, n, acc, refPk);
        rigFree(&d);
        rigFree(&w);
    }
    /* per-sub gains are applied on top of 1/N in the default mode and as given when host-weighted */
    {
        SubSpec sp[2] = {subDefault(3), subDefault(4)};
        sp[0].gainDb = -6;
        sp[1].gainDb = 3;
        for (int mode = 0; mode < 2; mode++) {
            gWeighted = mode;
            Cfg c;
            buildCfg(&c, 200, 0, -1, sp, 2);
            Rig r;
            rigInit(&r, rate, buildGraph(rate, &c, 0x3, NULL, 0), sec);
            tones(&r, 50, 0.5, 0.3);
            render(&r, len);
            const double norm = mode ? 1.0 : 0.5;
            double e0 = 0, e1 = 0;
            for (uint32_t i = 0; i < len; i++) {
                e0 = fmax(e0, fabs((double)lane(&r, 3)[i] - norm * pow(10.0, -6.0 / 20.0) * (double)lane(&ref, 3)[i]));
                e1 = fmax(e1, fabs((double)lane(&r, 4)[i] - norm * pow(10.0, 3.0 / 20.0) * (double)lane(&ref, 3)[i]));
            }
            CHECK(e0 < 2e-6 && e1 < 2e-6, "rate %.0f: %s mode gains (err %g, %g)", rate, mode ? "host-weighted" : "default", e0, e1);
            rigFree(&r);
        }
    }
    gWeighted = 1;
    rigFree(&ref);

    /* switching the mode is a topology change: the rebuild fade, no click */
    for (int dir = 0; dir < 2; dir++) {
        SubSpec sp[4];
        for (uint32_t q = 0; q < 4; q++) sp[q] = subDefault(3 + q);
        Cfg from, to;
        gWeighted = dir;
        buildCfg(&from, 200, 0, -1, sp, 4);
        gWeighted = !dir;
        buildCfg(&to, 200, 0, -1, sp, 4);
        gWeighted = 1;
        Rig r;
        rigInit(&r, rate, buildGraph(rate, &from, 0x3, NULL, 0), 1.0);
        tones(&r, 50, 0.4, 0.4);
        render(&r, framesFor(rate, 0.15));
        const uint32_t before = (uint32_t)r.pos;
        n60_stage_desc st[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, to.p, to.n)};
        n60_graph_desc d = desc(rate, st, 1);
        CHECK(n60_graph_publish(r.g, &d) == N60_STATUS_OK, "publish mode switch");
        n60_rebuild_status rs;
        int guard = 0;
        do {
            render(&r, BLOCK);
            memset(&rs, 0, sizeof rs);
            rs.structSize = sizeof rs;
            n60_graph_get_rebuild_status(r.g, &rs);
        } while ((rs.state != 0 || rs.completed == 0) && ++guard < 4000);
        render(&r, framesFor(rate, 0.1));
        const uint32_t end = (uint32_t)r.pos;
        CHECK(rs.completed == 1, "rate %.0f: mode-switch rebuild completed", rate);
        const double hi = maxStep(lane(&r, 3), dir ? before - framesFor(rate, 0.04) : end - framesFor(rate, 0.04), dir ? before : end);
        for (uint32_t q = 0; q < 4; q++) {
            const double st2 = maxStep(lane(&r, 3 + q), before, end);
            CHECK(st2 < 3.0 * hi, "rate %.0f: sub %u step across the mode switch %g vs %g", rate, q, st2, hi);
        }
        const double a = peakRange(lane(&r, 3), before - framesFor(rate, 0.05), before);
        const double b = peakRange(lane(&r, 3), end - framesFor(rate, 0.05), end);
        const double ratio = dir ? a / b : b / a;  /* weighted / default = N */
        CHECK(fabs(ratio - 4.0) < 0.04, "rate %.0f: weighted level is N times the default (%.3f)", rate, ratio);
        rigFree(&r);
    }
}

int main(void) {
    for (unsigned i = 0; i < sizeof kRates / sizeof *kRates; i++) {
        const double rate = kRates[i];
        testSums(rate);
        testGainPolarity(rate);
        testEq(rate);
        testDelay(rate);
        testSingleSubExact(rate);
        testLfe(rate);
        testValidation(rate);
        testLiveEdits(rate);
        testSubCountRebuild(rate);
        testModes(rate);
        printf("rate %.0f done\n", rate);
    }
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("n60core multi-sub bass management: all checks passed\n");
    return 0;
}
