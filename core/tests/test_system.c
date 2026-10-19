/* E6 S5: deterministic tests for the ABI v4 system stages at the eight standard rates:
 * latency report against the measured impulse delay, the full stereo-plus-sub chain
 * against the same stages run one graph each, bass management, symmetry/crossfeed/
 * crosstalk/headphone/ambient/gate/mute behaviour, protection ceiling and unity,
 * howl-guard trip time, and the ANC authorisation rules. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define MAXN 8192
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

static n60_status build(double rate, uint32_t ch, n60_stage_desc *st, uint32_t n, n60_graph **g) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = MAXN;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    return n60_graph_build(&d, g);
}

static float bufIn[4][MAXN], bufOut[4][MAXN];
static void run(n60_graph *g, uint32_t ch, uint32_t frames) {
    const float *ip[4];
    float *op[4];
    for (uint32_t c = 0; c < ch; c++) { ip[c] = bufIn[c]; op[c] = bufOut[c]; }
    n60_status s = n60_graph_process(g, ip, op, frames);
    CHECK(s == N60_STATUS_OK, "process status %d", s);
}
static void feedOut(uint32_t ch) { memcpy(bufIn, bufOut, sizeof bufIn); (void)ch; }
static double peakOf(const float *x, uint32_t from, uint32_t to) {
    double p = 0;
    for (uint32_t i = from; i < to; i++) if (fabs(x[i]) > p) p = fabs(x[i]);
    return p;
}
static void tone(float *x, uint32_t n, double rate, double hz, double amp, uint64_t start) {
    for (uint32_t i = 0; i < n; i++) x[i] = (float)(amp * sin(2.0 * kPi * hz * (double)(start + i) / rate));
}
/* Runs a tone through the graph for `blocks` blocks of 1024 frames (at least enough to see 1.5 cycles) on the
 * lanes in inMask. gPeak[c] is the output peak of lane c over the final window; the return is gPeak[outLane]. */
static double gPeak[4];
#define SEC(rate, s) ((uint32_t)ceil((rate) * (s) / 1024.0))
static double toneMask(n60_graph *g, uint32_t ch, double rate, unsigned inMask, double hz, double amp, uint32_t blocks,
                       uint32_t outLane, uint64_t *pos) {
    uint32_t win = (uint32_t)ceil(1.5 * rate / hz / 1024.0) + 1;
    if (blocks < win) blocks = win;
    for (uint32_t c = 0; c < 4; c++) gPeak[c] = 0;
    for (uint32_t b = 0; b < blocks; b++) {
        for (uint32_t c = 0; c < ch; c++) {
            memset(bufIn[c], 0, sizeof bufIn[c]);
            if ((inMask >> c) & 1u) tone(bufIn[c], 1024, rate, hz, amp, *pos);
        }
        *pos += 1024;
        run(g, ch, 1024);
        if (b + win >= blocks) {
            for (uint32_t c = 0; c < ch; c++) {
                double p = peakOf(bufOut[c], 0, 1024);
                if (p > gPeak[c]) gPeak[c] = p;
            }
        }
    }
    return gPeak[outLane];
}
static double toneThrough(n60_graph *g, uint32_t ch, double rate, uint32_t lane, double hz, double amp, uint32_t blocks,
                          uint32_t outLane, uint64_t *pos) {
    return toneMask(g, ch, rate, 1u << lane, hz, amp, blocks, outLane, pos);
}

static void testLatency(double rate) {
    const float one[1] = {1.0f};
    const float delay[1] = {40};
    for (int os = 0; os < 3; os++) {
        const float factor = os == 0 ? 1.0f : (os == 1 ? 2.0f : 4.0f);
        const float prot[7] = {os == 0 ? 0.0f : 1.0f, 0.0f, 1.0f, 50.0f, 10.0f, 0.0f, factor};
        n60_stage_desc st[3] = {stg(N60_STAGE_ROOM_FIR, 1, N60_LANE_ALL, one, 1), stg(N60_STAGE_DELAY, 2, N60_LANE_ALL, delay, 1),
                                stg(N60_STAGE_PROTECTION, 3, N60_LANE_ALL, prot, 7)};
        st[1].capacityFrames = 256;
        n60_graph *g = NULL;
        CHECK(build(rate, 1, st, 3, &g) == N60_STATUS_OK, "latency build %.0f os %d", rate, os);
        if (!g) return;
        memset(bufIn, 0, sizeof bufIn);
        bufIn[0][0] = 0.25f;
        run(g, 1, 8192);
        uint32_t peakAt = 0;
        double pk = 0;
        for (uint32_t i = 0; i < 8192; i++) if (fabs(bufOut[0][i]) > pk) { pk = fabs(bufOut[0][i]); peakAt = i; }
        const uint32_t lat = n60_graph_latency_frames(g);
        CHECK(peakAt == lat, "rate %.0f os %d: measured impulse delay %u != reported latency %u", rate, os, peakAt, lat);
        CHECK(pk > 0.2 && pk < 0.3, "rate %.0f os %d: impulse peak %.4f", rate, os, pk);
        n60_graph_retire(g);
    }
}

static void testProtection(double rate) {
    const float prot[7] = {1.0f, -6.0f, 1.0f, 50.0f, 10.0f, 1.0f, 1.0f};
    n60_stage_desc st[1] = {stg(N60_STAGE_PROTECTION, 1, N60_LANE_ALL, prot, 7)};
    n60_graph *g = NULL;
    CHECK(build(rate, 2, st, 1, &g) == N60_STATUS_OK, "protection build");
    if (!g) return;
    uint64_t pos = 0;
    const double ceil = pow(10.0, -6.0 / 20.0);
    double pk = 0;
    for (int b = 0; b < 12; b++) {
        pk = toneThrough(g, 2, rate, 0, 1000, 1.0, 1, 0, &pos);
        if (b > 2) CHECK(pk <= ceil * 1.01, "rate %.0f: block %d peak %.4f over ceiling %.4f", rate, b, pk, ceil);
    }
    CHECK(pk > ceil * 0.85, "rate %.0f: limited peak %.4f far below ceiling %.4f", rate, pk, ceil);
    n60_graph_retire(g);
    /* below the ceiling the stage is transparent apart from its delay */
    n60_graph *g2 = NULL;
    CHECK(build(rate, 2, st, 1, &g2) == N60_STATUS_OK, "protection build 2");
    if (!g2) return;
    pos = 0;
    pk = 0;
    for (int b = 0; b < 6; b++) pk = toneThrough(g2, 2, rate, 0, 1000, 0.1, 1, 0, &pos);
    CHECK(fabs(pk - 0.1) < 0.002, "rate %.0f: below-ceiling peak %.4f", rate, pk);
    n60_graph_retire(g2);
}

static void testBass(double rate) {
    const float bm[9] = {80, 0, 2, 3, 120, 0, 0, 0, 0};
    n60_stage_desc st[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, bm, 9)};
    n60_graph *g = NULL;
    CHECK(build(rate, 4, st, 1, &g) == N60_STATUS_OK, "bass build");
    if (!g) return;
    uint64_t pos = 0;
    toneMask(g, 4, rate, 0x3, 25, 1.0, SEC(rate, 0.4), 2, &pos);
    double sub = gPeak[2], mainLow = gPeak[0];
    CHECK(sub > 1.7 && sub < 2.1, "rate %.0f: sub carries both mains (%.3f)", rate, sub);
    CHECK(mainLow < 0.1, "rate %.0f: mains high-passed (%.3f)", rate, mainLow);
    n60_graph_retire(g);

    n60_graph *g2 = NULL;
    build(rate, 4, st, 1, &g2);
    pos = 0;
    double mainHi = toneThrough(g2, 4, rate, 0, 2000, 0.5, SEC(rate, 0.1), 0, &pos);
    double subHi = gPeak[2];
    CHECK(fabs(mainHi - 0.5) < 0.02, "rate %.0f: mains pass band (%.3f)", rate, mainHi);
    CHECK(subHi < 0.01, "rate %.0f: sub rejects 2 kHz (%.4f)", rate, subHi);
    n60_graph_retire(g2);

    n60_graph *g3 = NULL;
    build(rate, 4, st, 1, &g3);
    pos = 0;
    toneThrough(g3, 4, rate, 3, 40, 0.5, SEC(rate, 0.4), 2, &pos);
    double lfe = gPeak[2], lfeLane = gPeak[3];
    CHECK(fabs(lfe - 0.5) < 0.03, "rate %.0f: LFE reaches sub (%.3f)", rate, lfe);
    CHECK(lfeLane == 0.0, "rate %.0f: LFE lane cleared (%g)", rate, lfeLane);
    n60_graph_retire(g3);
}

static void testPairs(double rate) {
    /* symmetry hard right, crossfeed, mute, ambient, headphone, crosstalk neutral */
    {
        const float sym[1] = {1.0f};
        n60_stage_desc st[1] = {stgPair(N60_STAGE_SYMMETRY, 1, 0, 1, sym, 1)};
        n60_graph *g = NULL;
        build(rate, 2, st, 1, &g);
        uint64_t pos = 0;
        for (int c = 0; c < 2; c++) for (int i = 0; i < 1024; i++) bufIn[c][i] = 0.5f;
        run(g, 2, 1024);
        CHECK(fabs(bufOut[0][1023]) < 1e-6 && fabs(bufOut[1][1023] - 0.5 * sqrt(2.0)) < 1e-4, "rate %.0f symmetry gains", rate);
        (void)pos;
        n60_graph_retire(g);
    }
    {
        const float cf[1] = {0.5f};
        n60_stage_desc st[1] = {stgPair(N60_STAGE_CROSSFEED, 1, 0, 1, cf, 1)};
        n60_graph *g = NULL;
        build(rate, 2, st, 1, &g);
        for (int i = 0; i < 64; i++) { bufIn[0][i] = 1.0f; bufIn[1][i] = 0.0f; }
        run(g, 2, 64);
        CHECK(fabs(bufOut[0][10] - 0.5) < 1e-6 && fabs(bufOut[1][10] - 0.5) < 1e-6, "rate %.0f crossfeed", rate);
        n60_graph_retire(g);
    }
    {
        const float ct[2] = {800, 0.0f};
        n60_stage_desc st[1] = {stgPair(N60_STAGE_CROSSTALK, 1, 0, 1, ct, 2)};
        n60_graph *g = NULL;
        build(rate, 2, st, 1, &g);
        uint64_t pos = 0;
        double pk = toneThrough(g, 2, rate, 0, 500, 0.5, 2, 0, &pos);
        CHECK(fabs(pk - 0.5) < 1e-3, "rate %.0f crosstalk amount 0 is neutral (%.4f)", rate, pk);
        n60_graph_retire(g);
    }
    {
        const float mute[1] = {0.0f}, og[1] = {0.5f};
        n60_stage_desc st[2] = {stg(N60_STAGE_OUTPUT_GAIN, 1, 1, og, 1), stg(N60_STAGE_MUTE, 2, N60_LANE_ALL, mute, 1)};
        n60_graph *g = NULL;
        build(rate, 2, st, 2, &g);
        for (int c = 0; c < 2; c++) for (int i = 0; i < 1024; i++) bufIn[c][i] = 0.8f;
        run(g, 2, 1024);
        CHECK(fabs(bufOut[0][100] - 0.8) < 1e-6 && fabs(bufOut[1][100] - 0.4) < 1e-6, "rate %.0f output gain/balance", rate);
        n60_param_record rec = {2, 0, 1.0f, 0};
        CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "mute post");
        for (uint32_t k = 0; k < SEC(rate, 0.05) + 1; k++) run(g, 2, 1024);
        CHECK(peakOf(bufOut[0], 0, 1024) == 0.0 && peakOf(bufOut[1], 0, 1024) == 0.0, "rate %.0f mute reaches silence", rate);
        n60_graph_retire(g);
    }
    {
        const float amb[10] = {6.0f, 100, 0, 1, 1000, 0, 1, 8000, 0, 1};
        n60_stage_desc st[1] = {stg(N60_STAGE_AMBIENT, 1, N60_LANE_ALL, amb, 10)};
        n60_graph *g = NULL;
        build(rate, 2, st, 1, &g);
        uint64_t pos = 0;
        double pk = toneThrough(g, 2, rate, 0, 700, 0.25, 4, 0, &pos);
        CHECK(fabs(pk - 0.25 * pow(10.0, 6.0 / 20.0)) < 0.004, "rate %.0f ambient level (%.4f)", rate, pk);
        n60_graph_retire(g);
    }
    {
        float hp[11] = {0, 0, 45, 0.09f, 700, 0, 0, 0, 0, 0, 0};
        n60_stage_desc st[1] = {stgPair(N60_STAGE_HEADPHONE, 1, 0, 1, hp, 11)};
        n60_graph *g = NULL;
        build(rate, 2, st, 1, &g);
        uint64_t pos = 0;
        double pk = toneThrough(g, 2, rate, 0, 300, 0.5, 4, 0, &pos);
        CHECK(fabs(pk - 0.5) < 1e-3 && peakOf(bufOut[1], 0, 1024) < 1e-6, "rate %.0f headphone neutral", rate);
        n60_graph_retire(g);
        hp[1] = 1.0f;
        build(rate, 2, st, 1, &g);
        pos = 0;
        for (int b = 0; b < 8; b++) toneThrough(g, 2, rate, 0, 100, 0.5, 1, 0, &pos);
        double r = peakOf(bufOut[1], 0, 1024);
        CHECK(r > 0.2 && r < 0.3, "rate %.0f headphone crossfeed level (%.3f)", rate, r);
        n60_graph_retire(g);
    }
}

static void testGate(double rate) {
    const float gate[5] = {-60, 6, 10, 5, 5};
    n60_stage_desc st[1] = {stgMask(N60_STAGE_PAUSE_GATE, 1, 0x3, gate, 5)};
    n60_graph *g = NULL;
    build(rate, 2, st, 1, &g);
    uint64_t pos = 0;
    double loud = toneThrough(g, 2, rate, 0, 500, 0.5, SEC(rate, 0.05), 0, &pos);
    CHECK(fabs(loud - 0.5) < 1e-3, "rate %.0f gate open passes (%.4f)", rate, loud);
    double quiet = toneThrough(g, 2, rate, 0, 500, 0.0003, SEC(rate, 0.4), 0, &pos);
    CHECK(quiet < 1e-6, "rate %.0f gate closes on quiet program (%.2g)", rate, quiet);
    double back = toneThrough(g, 2, rate, 0, 500, 0.5, SEC(rate, 0.2), 0, &pos);
    CHECK(fabs(back - 0.5) < 1e-3, "rate %.0f gate reopens (%.4f)", rate, back);
    n60_graph_retire(g);
}

static void testAnc(double rate) {
    /* injection and capture: authorisation only through the snapshot */
    for (int auth = 0; auth < 2; auth++) {
        const float inj[3] = {2, (float)auth, 0.0f};
        const float cap[1] = {(float)auth};
        n60_stage_desc st[2] = {stg(N60_STAGE_ANC_INJECT, 1, 0, inj, 3), stgMask(N60_STAGE_ANC_CAPTURE, 2, 0x7, cap, 1)};
        st[1].capacityFrames = 4096;
        n60_graph *g = NULL;
        CHECK(build(rate, 3, st, 2, &g) == N60_STATUS_OK, "anc build");
        if (!g) return;
        for (int i = 0; i < 3; i++) memset(bufIn[i], 0, sizeof bufIn[i]);
        for (int i = 0; i < 2048; i++) bufIn[2][i] = 0.1f;
        run(g, 3, 2048);
        for (int blk = 0; blk < 4; blk++) { for (int i = 0; i < 2048; i++) bufIn[2][i] = 0.1f; run(g, 3, 2048); }
        double dst = peakOf(bufOut[0], 0, 2048);
        double src = peakOf(bufOut[2], 0, 2048);
        CHECK(src == 0.0, "rate %.0f: source lane always cleared (%g)", rate, src);
        if (auth) CHECK(fabs(dst - 0.1) < 1e-5, "rate %.0f: authorised injection (%.5f)", rate, dst);
        else CHECK(dst == 0.0, "rate %.0f: unauthorised injection silent (%g)", rate, dst);
        uint64_t w = 99;
        float tmp[16];
        n60_status rs = n60_graph_read_capture(g, 2, 2, 0, tmp, 0, &w);
        CHECK(rs == N60_STATUS_OK, "capture read status");
        if (auth) {
            CHECK(w == 5 * 2048u, "rate %.0f: captured %llu", rate, (unsigned long long)w);
            rs = n60_graph_read_capture(g, 2, 0, w - 16, tmp, 16, &w);
            CHECK(rs == N60_STATUS_OK && fabs(tmp[0] - 0.1) < 1e-5, "capture contents (st %d, %g)", rs, tmp[0]);
        } else {
            CHECK(w == 0, "rate %.0f: nothing recorded when unauthorised (%llu)", rate, (unsigned long long)w);
        }
        n60_param_record rec = {1, 1, 1.0f, 0};
        CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_UNSUPPORTED, "authorisation is not live-postable");
        n60_param_record rec2 = {2, 0, 1.0f, 0};
        CHECK(n60_graph_post_params(g, &rec2, 1) == N60_STATUS_UNSUPPORTED, "capture authorisation is not live-postable");
        n60_graph_retire(g);
    }
}

static void testGuard(double rate) {
    float gp[28] = {-1, -1, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0};
    for (int i = 12; i < 28; i++) gp[i] = -100;
    n60_stage_desc st[1] = {stg(N60_STAGE_ANC_GUARD, 1, 0, gp, 28)};
    /* stationary sine: never trips */
    {
        n60_graph *g = NULL;
        CHECK(build(rate, 1, st, 1, &g) == N60_STATUS_OK, "guard build");
        if (!g) return;
        uint64_t pos = 0;
        for (int b = 0; b < 40; b++) toneThrough(g, 1, rate, 0, 200, 0.1, 1, 0, &pos);
        n60_guard_status s = {0}; s.structSize = sizeof s;
        CHECK(n60_graph_read_guard(g, 1, &s) == N60_STATUS_OK && s.trip == 0 && s.muted == 0, "rate %.0f guard quiet on steady tone", rate);
        CHECK(fabs(peakOf(bufOut[0], 0, 1024) - 0.1) < 1e-5, "guard passes a steady tone");
        n60_graph_retire(g);
    }
    /* growing howl: trips within 50 ms of the growth start, output ends silent */
    {
        n60_graph *g = NULL;
        build(rate, 1, st, 1, &g);
        const uint32_t block = (uint32_t)(rate * 0.001);
        double t = 0;
        uint64_t frame = 0;
        int64_t tripAt = -1;
        for (int ms = 0; ms < 200; ms++) {
            for (uint32_t i = 0; i < block; i++) {
                double amp = 0.01 * pow(2.0, t / 0.005);
                if (amp > 8.0) amp = 8.0;
                bufIn[0][i] = (float)(amp * sin(2 * kPi * 200.0 * t));
                t += 1.0 / rate;
            }
            run(g, 1, block);
            frame += block;
            n60_guard_status s = {0}; s.structSize = sizeof s;
            n60_graph_read_guard(g, 1, &s);
            if (tripAt < 0 && s.trip != 0) tripAt = (int64_t)frame;
        }
        CHECK(tripAt >= 0 && tripAt <= (int64_t)(rate * 0.050), "rate %.0f: guard tripped at %.1f ms", rate, tripAt < 0 ? -1.0 : 1000.0 * tripAt / rate);
        n60_guard_status s = {0}; s.structSize = sizeof s;
        n60_graph_read_guard(g, 1, &s);
        CHECK(s.muted == 1 && s.tripCount >= 1, "rate %.0f: guard muted", rate);
        CHECK(peakOf(bufOut[0], 0, block) == 0.0, "rate %.0f: muted output is silent", rate);
        n60_graph_retire(g);
    }
}

/* The whole speaker chain with every stage on, against the same stages one graph each. */
static void testChain(double rate) {
    const float gain[1] = {0.9f}, peq[4] = {0, 1000, 3, 1.0f}, bm[9] = {80, 0, 2, -1, 120, 0, 0, 0, 0};
    float taps[300];
    for (int i = 0; i < 300; i++) taps[i] = 0.002f * (float)sin(0.2 * i);
    taps[0] = 0.8f;
    const float amb[10] = {2.0f, 100, 0, 1, 1000, 1, 1, 8000, 0, 1};
    const float comp[10] = {-24, 3, 6, 5, 100, 0, 0, 0, 0, 1};
    const float sym[1] = {0.1f}, cf[1] = {0.1f}, ct[2] = {900, 0.2f};
    const float og[1] = {0.95f};
    float hp[11] = {-1, 0.3f, 45, 0.09f, 700, 0, 0, 0, 0, 0, 0};
    const float gate[5] = {-90, 6, 10, 5, 5};
    const float delay[1] = {17};
    float gp[28] = {-1, -1, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0};
    for (int i = 12; i < 28; i++) gp[i] = -100;
    const float inj[3] = {2, 0, 0};
    const float prot[7] = {1, -1, 1, 50, 5, 1, 2};
    const float mute[1] = {0};
    const float cap[1] = {1};
    n60_stage_desc st[] = {
        stg(N60_STAGE_SANITISE, 1, N60_LANE_ALL, NULL, 0),
        stg(N60_STAGE_METER_IN, 2, N60_LANE_ALL, NULL, 0),
        stg(N60_STAGE_GAIN, 3, N60_LANE_ALL, gain, 1),
        stg(N60_STAGE_PEQ, 4, N60_LANE_ALL, peq, 4),
        stg(N60_STAGE_METER_OUT, 5, N60_LANE_ALL, NULL, 0),
        stgMask(N60_STAGE_BASS_MGMT, 6, 0x3, bm, 9),
        stgMask(N60_STAGE_ROOM_FIR, 7, 0x3, taps, 300),
        stgMask(N60_STAGE_SPEAKER_IR, 8, 0x3, taps, 150),
        stg(N60_STAGE_AMBIENT, 9, N60_LANE_ALL, amb, 10),
        stgMask(N60_STAGE_CORE_DYNAMICS, 10, 0x3, comp, 10),
        stgPair(N60_STAGE_SYMMETRY, 11, 0, 1, sym, 1),
        stgPair(N60_STAGE_CROSSFEED, 12, 0, 1, cf, 1),
        stgPair(N60_STAGE_CROSSTALK, 13, 0, 1, ct, 2),
        stg(N60_STAGE_OUTPUT_GAIN, 14, 0, og, 1),
        stgPair(N60_STAGE_HEADPHONE, 15, 0, 1, hp, 11),
        stgMask(N60_STAGE_PAUSE_GATE, 16, 0x7, gate, 5),
        stg(N60_STAGE_DELAY, 17, N60_LANE_ALL, delay, 1),
        stg(N60_STAGE_ANC_GUARD, 18, 2, gp, 28),
        stg(N60_STAGE_ANC_INJECT, 19, 0, inj, 3),
        stg(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, prot, 7),
        stg(N60_STAGE_MUTE, 21, N60_LANE_ALL, mute, 1),
        stgMask(N60_STAGE_ANC_CAPTURE, 22, 0x7, cap, 1),
        stg(N60_STAGE_FINAL_SANITISE, 23, N60_LANE_ALL, NULL, 0),
        stg(N60_STAGE_FINAL_METER, 24, N60_LANE_ALL, NULL, 0),
    };
    const uint32_t n = sizeof st / sizeof st[0];
    st[16].capacityFrames = 64;
    st[21].capacityFrames = 8192;
    st[6].capacityFrames = 0;

    n60_graph *chain = NULL;
    CHECK(build(rate, 3, st, n, &chain) == N60_STATUS_OK, "chain build at %.0f", rate);
    n60_graph *each[40] = {0};
    for (uint32_t k = 0; k < n; k++) CHECK(build(rate, 3, &st[k], 1, &each[k]) == N60_STATUS_OK, "stage %u build at %.0f", k, rate);
    if (!chain) return;

    static float sig[3][MAXN];
    unsigned seed = 99;
    double worst = 0;
    const uint32_t sizes[] = {480, 256, 1000, 64, 777, 1024};
    for (int b = 0; b < 6; b++) {
        const uint32_t frames = sizes[b];
        for (int c = 0; c < 3; c++) {
            for (uint32_t i = 0; i < frames; i++) {
                seed = seed * 1664525u + 1013904223u;
                sig[c][i] = 0.4f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f) + 0.2f * (float)sin(0.03 * (i + 977.0 * b));
            }
        }
        for (int c = 0; c < 3; c++) memcpy(bufIn[c], sig[c], sizeof(float) * frames);
        run(chain, 3, frames);
        static float ref[3][MAXN];
        for (int c = 0; c < 3; c++) memcpy(ref[c], bufOut[c], sizeof(float) * frames);
        for (int c = 0; c < 3; c++) memcpy(bufIn[c], sig[c], sizeof(float) * frames);
        for (uint32_t k = 0; k < n; k++) {
            run(each[k], 3, frames);
            feedOut(3);
        }
        for (int c = 0; c < 3; c++) {
            for (uint32_t i = 0; i < frames; i++) {
                double e = fabs((double)bufIn[c][i] - (double)ref[c][i]);
                if (e > worst) worst = e;
            }
        }
    }
    CHECK(worst == 0.0, "rate %.0f: chain deviates from per-stage composition by %g", rate, worst);
    n60_graph_retire(chain);
    for (uint32_t k = 0; k < n; k++) n60_graph_retire(each[k]);
}

static void testRejects(void) {
    float prot[7] = {1, -1, 1, 50, 5, 1, 3};
    n60_stage_desc st[1] = {stg(N60_STAGE_PROTECTION, 1, N60_LANE_ALL, prot, 7)};
    n60_graph *g = NULL;
    CHECK(build(48000, 2, st, 1, &g) == N60_STATUS_BAD_ARGUMENT, "oversampling 3 rejected");
    const float bm[9] = {80, 0, 0, -1, 120, 0, 0, 0, 0};
    n60_stage_desc st2[1] = {stgMask(N60_STAGE_BASS_MGMT, 1, 0x3, bm, 9)};
    CHECK(build(48000, 3, st2, 1, &g) == N60_STATUS_BAD_ARGUMENT, "sub lane inside the main mask rejected");
    const float mute[1] = {0}, delay[1] = {0};
    n60_stage_desc st3[2] = {stg(N60_STAGE_MUTE, 1, N60_LANE_ALL, mute, 1), stg(N60_STAGE_DELAY, 2, N60_LANE_ALL, delay, 1)};
    CHECK(build(48000, 2, st3, 2, &g) == N60_STATUS_BAD_ARGUMENT, "delay after mute violates the chain order");
}

/* NaN/Inf input must not poison the protection state: output stays finite and recovers. */
static void testProtectionNonFinite(double rate) {
    const float prot[7] = {1.0f, -6.0f, 1.0f, 50.0f, 10.0f, 1.0f, 1.0f};
    n60_stage_desc st[1] = {stg(N60_STAGE_PROTECTION, 1, N60_LANE_ALL, prot, 7)};
    n60_graph *g = NULL;
    CHECK(build(rate, 2, st, 1, &g) == N60_STATUS_OK, "nonfinite build");
    if (!g) return;
    uint64_t pos = 0;
    for (int b = 0; b < 8; b++) {
        tone(bufIn[0], 512, rate, 1000, 0.5, pos);
        tone(bufIn[1], 512, rate, 1000, 0.5, pos);
        pos += 512;
        if (b == 2) { bufIn[0][10] = NAN; bufIn[1][20] = INFINITY; bufIn[0][30] = -INFINITY; }
        run(g, 2, 512);
        for (int c = 0; c < 2; c++)
            for (int i = 0; i < 512; i++)
                CHECK(isfinite(bufOut[c][i]), "rate %.0f: non-finite output block %d", rate, b);
    }
    CHECK(peakOf(bufOut[0], 0, 512) > 0.3, "rate %.0f: protection did not recover after non-finite input", rate);
    n60_graph_retire(g);
}

int main(void) {
    testRejects();
    for (unsigned r = 0; r < 8; r++) {
        const double rate = kRates[r];
        testLatency(rate);
        testProtection(rate);
        testProtectionNonFinite(rate);
        testBass(rate);
        testPairs(rate);
        testGate(rate);
        testAnc(rate);
        testGuard(rate);
        testChain(rate);
        printf("rate %.0f done\n", rate);
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    puts("n60core system stages: all checks passed");
    return 0;
}
