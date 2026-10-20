/* E6 S8d: the spectral denoiser's noise profile across rebuilds, edits and hand-overs (ABI v9), through the C
 * ABI at the eight standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
 *
 * The legacy kernel's denoiser keeps one long-lived runtime: a captured profile and the adaptive estimate
 * survive a topology change, a parameter edit and the denoiser being switched off; a quality (FFT size)
 * change or a Reset command starts a fresh profile; a profile command runs once per revision. The graph
 * must match. The reference for the output checks is a graph that is never rebuilt. */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define BLOCK 256u
#define MAXN 512u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

enum { FLAG_READY = 1, FLAG_CAPTURED = 2, FLAG_CAPTURING = 4 };

typedef struct {
    uint32_t rng;
    uint64_t pos;
    double rate;
    float in[2][MAXN];
    float out[2][MAXN];
    int tone; /* 1: a 1 kHz tone on top of the noise */
} Feed;

static float rnd(Feed *f) {
    f->rng = f->rng * 1664525u + 1013904223u;
    return (float)((double)(f->rng >> 8) / 8388608.0 - 1.0);
}

static void feedBlock(Feed *f, uint32_t frames) {
    for (uint32_t i = 0; i < frames; i++) {
        double t = (double)(f->pos + i) / f->rate;
        float tone = f->tone ? (float)(0.2 * sin(2.0 * kPi * 1000.0 * t)) : 0.0f;
        f->in[0][i] = 0.05f * rnd(f) + tone;
        f->in[1][i] = 0.05f * rnd(f) + tone;
    }
    f->pos += frames;
}

typedef struct {
    float dn[9];
    float gain;
    int withGain;
    int withDenoiser;
    uint32_t parkFft, parkRev, parkCmd;
} Cfg;

static void cfgInit(Cfg *c, uint32_t quality, uint32_t cmd, uint32_t rev) {
    memset(c, 0, sizeof *c);
    c->dn[0] = 1; c->dn[1] = (float)quality; c->dn[2] = 0.9f; c->dn[3] = -60; c->dn[4] = 0;
    c->dn[5] = 0; c->dn[6] = 0; c->dn[7] = (float)cmd; c->dn[8] = (float)rev;
    c->gain = 1.0f;
    c->withDenoiser = 1;
}

static n60_graph_desc makeDesc(double rate, const Cfg *c, n60_stage_desc *st) {
    uint32_t n = 0;
    memset(st, 0, 2 * sizeof *st);
    if (c->withGain) {
        st[n].structSize = sizeof st[n];
        st[n].kind = N60_STAGE_GAIN;
        st[n].stageId = 1;
        st[n].laneA = N60_LANE_ALL;
        st[n].params = &c->gain;
        st[n].paramCount = 1;
        n++;
    }
    if (c->withDenoiser) {
        st[n].structSize = sizeof st[n];
        st[n].kind = N60_STAGE_DENOISER;
        st[n].stageId = 2;
        st[n].laneMask = 0x3;
        st[n].params = c->dn;
        st[n].paramCount = 9;
        n++;
    }
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = MAXN;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = n;
    d.parkFftSize = c->parkFft;
    d.parkRevision = c->parkRev;
    d.parkCommand = c->parkCmd;
    return d;
}

static n60_graph *build(double rate, const Cfg *c) {
    n60_stage_desc st[2];
    n60_graph_desc d = makeDesc(rate, c, st);
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build status %d", s);
    return g;
}

static void publish(n60_graph *g, double rate, const Cfg *c) {
    n60_stage_desc st[2];
    n60_graph_desc d = makeDesc(rate, c, st);
    n60_status s = n60_graph_publish(g, &d);
    CHECK(s == N60_STATUS_OK, "publish status %d", s);
}

static void run(n60_graph *g, Feed *f, double seconds) {
    const float *ip[2] = {f->in[0], f->in[1]};
    float *op[2] = {f->out[0], f->out[1]};
    uint32_t total = (uint32_t)ceil(seconds * f->rate / BLOCK);
    for (uint32_t b = 0; b < total; b++) {
        feedBlock(f, BLOCK);
        CHECK(n60_graph_process(g, ip, op, BLOCK) == N60_STATUS_OK, "process");
    }
}

/* Runs two graphs on identical input; returns the largest |a - b| over the last `tail` seconds. */
static double runPair(n60_graph *a, n60_graph *b, Feed *f, double seconds, double tail) {
    const float *ip[2] = {f->in[0], f->in[1]};
    float oa[2][MAXN], ob[2][MAXN];
    float *opa[2] = {oa[0], oa[1]}, *opb[2] = {ob[0], ob[1]};
    uint32_t total = (uint32_t)ceil(seconds * f->rate / BLOCK);
    uint32_t skip = total - (uint32_t)ceil(tail * f->rate / BLOCK);
    double worst = 0;
    for (uint32_t k = 0; k < total; k++) {
        feedBlock(f, BLOCK);
        CHECK(n60_graph_process(a, ip, opa, BLOCK) == N60_STATUS_OK, "process a");
        CHECK(n60_graph_process(b, ip, opb, BLOCK) == N60_STATUS_OK, "process b");
        if (k >= skip) {
            for (int c = 0; c < 2; c++) {
                for (uint32_t i = 0; i < BLOCK; i++) worst = fmax(worst, fabs((double)oa[c][i] - (double)ob[c][i]));
            }
        }
    }
    return worst;
}

static n60_denoiser_state *snap(void) {
    static n60_denoiser_state s;
    return &s;
}

static int exportTo(n60_graph *g, n60_denoiser_state *s) {
    memset(s, 0, sizeof *s);
    return n60_graph_denoiser_export(g, s);
}

static double noiseDiff(const n60_denoiser_state *a, const n60_denoiser_state *b) {
    double worst = 0;
    uint32_t bins = a->fftSize / 2 + 1;
    for (uint32_t i = 0; i < bins; i++) {
        double scale = fmax(1e-12, fabs((double)a->noise[i]));
        worst = fmax(worst, fabs((double)a->noise[i] - (double)b->noise[i]) / scale);
    }
    return worst;
}

static double noiseSum(const n60_denoiser_state *a) {
    double s = 0;
    for (uint32_t i = 0; i < a->fftSize / 2 + 1; i++) s += (double)a->noise[i];
    return s;
}

/* A rebuild is done when the next block is not mid-warm-up. */
static void settle(n60_graph *g, Feed *f) {
    run(g, f, 0.05);
    for (int i = 0; i < 100000; i++) {
        n60_rebuild_status rs;
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        n60_graph_get_rebuild_status(g, &rs);
        if (rs.state == 0) break;
        run(g, f, 0.005);
    }
}

static void testCapture(double rate) {
    n60_denoiser_state *s0 = snap();
    static n60_denoiser_state s1;
    Cfg c;
    cfgInit(&c, 0, 1, 1); /* capture, revision 1 */
    n60_graph *g = build(rate, &c);
    n60_graph *r = build(rate, &c);
    if (!g || !r) return;
    Feed f = {.rng = 77u, .rate = rate};
    runPair(g, r, &f, 1.6, 0.0);
    CHECK(exportTo(g, s0) == 1, "rate %.0f: capture state exported", rate);
    CHECK((s0->flags & FLAG_CAPTURED) && (s0->flags & FLAG_READY) && !(s0->flags & FLAG_CAPTURING),
          "rate %.0f: capture finished (flags %u)", rate, s0->flags);
    CHECK(s0->fftSize == 1024, "rate %.0f: fft %u", rate, s0->fftSize);

    /* Topology rebuild (a gain stage appears) with the same denoiser params and revision. */
    Cfg c2 = c;
    c2.withGain = 1;
    publish(g, rate, &c2);
    runPair(g, r, &f, 0.5, 0.0); /* adopt, warm up, crossfade */
    n60_rebuild_status rs;
    memset(&rs, 0, sizeof rs);
    rs.structSize = sizeof rs;
    n60_graph_get_rebuild_status(g, &rs);
    CHECK(rs.state == 0 && rs.completed >= 1, "rate %.0f: rebuild finished (state %u)", rate, rs.state);
    CHECK(exportTo(g, &s1) == 1 && (s1.flags & FLAG_READY) && (s1.flags & FLAG_CAPTURED),
          "rate %.0f: profile kept after the rebuild (flags %u)", rate, s1.flags);
    CHECK(noiseDiff(s0, &s1) < 1e-6, "rate %.0f: noise profile identical after the rebuild (%g)", rate, noiseDiff(s0, &s1));
    CHECK(!(s1.flags & FLAG_CAPTURING), "rate %.0f: a command already run is not run again on a rebuild", rate);

    /* Output matches the graph that never rebuilt. */
    f.tone = 1;
    double diff = runPair(g, r, &f, 0.6, 0.3);
    CHECK(diff < 1e-2, "rate %.0f: rebuilt output within %g of the never-rebuilt kernel-equivalent (limit 1e-2, 5 percent of the 0.2 tone, the kernel parity tolerance)", rate, diff);
    n60_graph_retire(g);
    n60_graph_retire(r);
}

static void testAdaptive(double rate) {
    static n60_denoiser_state a, b;
    Cfg c;
    cfgInit(&c, 0, 0, 0);
    n60_graph *g = build(rate, &c);
    n60_graph *r = build(rate, &c);
    if (!g || !r) return;
    Feed f = {.rng = 5u, .rate = rate};
    runPair(g, r, &f, 3.2, 0.0);
    CHECK(exportTo(g, &a) == 1 && (a.flags & FLAG_READY) && a.adaptiveBlocks >= 2,
          "rate %.0f: adaptive estimate learned (blocks %u)", rate, a.adaptiveBlocks);
    /* A parameter edit that needs a rebuild (the tuning). */
    Cfg c2 = c;
    c2.dn[0] = 2;
    n60_graph *r2 = build(rate, &c2);
    if (!r2) return;
    Feed fr2 = {.rng = 5u, .rate = rate};
    run(r2, &fr2, 3.2);
    publish(g, rate, &c2);
    runPair(g, r2, &f, 0.5, 0.0);
    CHECK(exportTo(g, &b) == 1, "rate %.0f: state after edit", rate);
    CHECK((b.flags & FLAG_READY) && b.adaptiveBlocks >= a.adaptiveBlocks,
          "rate %.0f: adaptive estimate carried, no relearn (blocks %u -> %u)", rate, a.adaptiveBlocks, b.adaptiveBlocks);
    CHECK(noiseSum(&b) > 0.0 && noiseDiff(&a, &b) < 0.5, "rate %.0f: adaptive profile carried (%g)", rate, noiseDiff(&a, &b));
    /* The tuning is not live, so the reference is a graph built with the new tuning that heard the same
     * history; the rebuilt graph must sound the same once its stream state has refilled. */
    f.tone = 1;
    double diff = runPair(g, r2, &f, 0.6, 0.3);
    CHECK(diff < 1e-2, "rate %.0f: output after an edit within %g of a continuously-run graph (limit 1e-2, 5 percent of the 0.2 tone, the kernel parity tolerance)", rate, diff);
    n60_graph_retire(r2);
    n60_graph_retire(g);
    n60_graph_retire(r);
}

static void testResets(double rate) {
    static n60_denoiser_state s;
    Cfg c;
    cfgInit(&c, 0, 1, 1);
    n60_graph *g = build(rate, &c);
    if (!g) return;
    Feed f = {.rng = 3u, .rate = rate};
    run(g, &f, 1.6);
    CHECK(exportTo(g, &s) == 1 && (s.flags & FLAG_CAPTURED), "rate %.0f: captured before resets", rate);

    /* A quality change starts a fresh profile at the new FFT size. */
    Cfg q = c;
    q.dn[1] = 1;
    publish(g, rate, &q);
    settle(g, &f);
    int have = exportTo(g, &s);
    CHECK(!have || (!(s.flags & FLAG_READY) && s.adaptiveBlocks == 0),
          "rate %.0f: a quality change drops the profile (flags %u)", rate, have ? s.flags : 0);
    CHECK(!have || s.fftSize == 0 || s.fftSize == 2048, "rate %.0f: new fft size (%u)", rate, s.fftSize);
    settle(g, &f);

    /* Capture again at the new quality with a new revision, then Reset. */
    Cfg cap = q;
    cap.dn[7] = 1;
    cap.dn[8] = 2;
    publish(g, rate, &cap);
    settle(g, &f);
    run(g, &f, 1.6);
    CHECK(exportTo(g, &s) == 1 && (s.flags & FLAG_CAPTURED), "rate %.0f: a new revision runs the capture (flags %u)", rate, s.flags);
    Cfg rs = cap;
    rs.dn[7] = 2;
    rs.dn[8] = 3;
    publish(g, rate, &rs);
    settle(g, &f);
    have = exportTo(g, &s);
    CHECK(!have || !(s.flags & (FLAG_READY | FLAG_CAPTURED)), "rate %.0f: a Reset command clears the profile (flags %u)", rate, s.flags);

    /* The Reset revision does not run twice: capture, rebuild with the same Reset revision, profile stays. */
    Cfg cap2 = rs;
    cap2.dn[7] = 1;
    cap2.dn[8] = 4;
    publish(g, rate, &cap2);
    settle(g, &f);
    run(g, &f, 1.6);
    CHECK(exportTo(g, &s) == 1 && (s.flags & FLAG_CAPTURED), "rate %.0f: recaptured", rate);
    Cfg again = cap2;
    again.withGain = 1;
    publish(g, rate, &again);
    settle(g, &f);
    CHECK(exportTo(g, &s) == 1 && (s.flags & FLAG_CAPTURED), "rate %.0f: the revision-4 capture does not rerun or clear on a rebuild", rate);
    n60_graph_retire(g);
}

static void testOffAndOn(double rate) {
    static n60_denoiser_state before, parked, after;
    Cfg c;
    cfgInit(&c, 0, 1, 1);
    n60_graph *g = build(rate, &c);
    if (!g) return;
    Feed f = {.rng = 9u, .rate = rate};
    run(g, &f, 1.6);
    CHECK(exportTo(g, &before) == 1 && (before.flags & FLAG_CAPTURED), "rate %.0f: captured before switching off", rate);

    /* Denoiser off: the kernel keeps its profile. The view carries the same quality and revision. */
    Cfg off = c;
    off.withDenoiser = 0;
    off.parkFft = 1024;
    off.parkRev = 1;
    publish(g, rate, &off);
    settle(g, &f);
    CHECK(exportTo(g, &parked) == 1 && (parked.flags & FLAG_CAPTURED), "rate %.0f: profile kept while the denoiser is off", rate);
    CHECK(noiseDiff(&before, &parked) < 1e-6, "rate %.0f: parked profile equals the captured one (%g)", rate, noiseDiff(&before, &parked));

    /* Back on: restored. */
    publish(g, rate, &c);
    settle(g, &f);
    CHECK(exportTo(g, &after) == 1 && (after.flags & FLAG_READY), "rate %.0f: profile restored when the denoiser returns", rate);
    CHECK(noiseDiff(&before, &after) < 1e-6, "rate %.0f: restored profile equals the captured one (%g)", rate, noiseDiff(&before, &after));

    /* Off with a Reset revision: cleared, as the kernel does. */
    Cfg offReset = off;
    offReset.parkRev = 2;
    offReset.parkCmd = 2;
    publish(g, rate, &offReset);
    settle(g, &f);
    int have = exportTo(g, &parked);
    CHECK(!have || !(parked.flags & (FLAG_READY | FLAG_CAPTURED)), "rate %.0f: Reset while off clears the profile", rate);
    n60_graph_retire(g);

    /* Off with a quality change: dropped. */
    g = build(rate, &c);
    if (!g) return;
    Feed f3 = {.rng = 9u, .rate = rate};
    run(g, &f3, 1.6);
    Cfg offQ = off;
    offQ.parkFft = 2048;
    publish(g, rate, &offQ);
    settle(g, &f3);
    have = exportTo(g, &parked);
    CHECK(!have || !(parked.flags & (FLAG_READY | FLAG_CAPTURED)), "rate %.0f: a quality change while off drops the profile", rate);
    n60_graph_retire(g);
}

static void testHandOver(double rate) {
    static n60_denoiser_state exported, seen;
    Cfg c;
    cfgInit(&c, 0, 1, 1);
    n60_graph *g = build(rate, &c);
    if (!g) return;
    Feed f = {.rng = 21u, .rate = rate};
    run(g, &f, 1.6);
    CHECK(exportTo(g, &exported) == 1 && (exported.flags & FLAG_CAPTURED), "rate %.0f: source profile", rate);
    /* The bridge hands a kernel profile to a freshly built graph. */
    n60_graph *h = build(rate, &c);
    if (!h) return;
    n60_graph_denoiser_import(h, &exported);
    CHECK(exportTo(h, &seen) == 1 && (seen.flags & FLAG_CAPTURED), "rate %.0f: imported profile visible", rate);
    CHECK(noiseDiff(&exported, &seen) < 1e-6, "rate %.0f: imported noise equal (%g)", rate, noiseDiff(&exported, &seen));
    /* The imported revision stops the capture command from running again. */
    Feed f2 = {.rng = 4u, .rate = rate};
    run(h, &f2, 0.05);
    CHECK(exportTo(h, &seen) == 1 && !(seen.flags & FLAG_CAPTURING) && (seen.flags & FLAG_CAPTURED),
          "rate %.0f: imported revision suppresses a repeat capture (flags %u)", rate, seen.flags);
    /* A state of another FFT size is dropped. */
    n60_denoiser_state *bad = &exported;
    bad->fftSize = 2048;
    n60_graph_denoiser_import(h, bad);
    int have = exportTo(h, &seen);
    CHECK(!have || !(seen.flags & FLAG_READY), "rate %.0f: a profile of another FFT size is dropped", rate);
    n60_graph_retire(h);
    n60_graph_retire(g);
}

int main(void) {
    for (unsigned i = 0; i < sizeof kRates / sizeof *kRates; i++) {
        double rate = kRates[i];
        testCapture(rate);
        testAdaptive(rate);
        testResets(rate);
        testOffAndOn(rate);
        testHandOver(rate);
    }
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("denoiser carry: all checks passed");
    return 0;
}
