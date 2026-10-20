/* E6 S7: deterministic tests for N-channel layouts, the graph builder and the binaural matrix stage,
 * through the C ABI at the eight standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
 *
 *  - layout validation, pairing and the builder's argument checks;
 *  - stereo is the 2-channel layout: builder output equals a hand-built stage list bit for bit, and the
 *    left/right lanes of a 5.1 graph equal the stereo graph;
 *  - the binaural stage against a direct-form convolution (5.1, partitions, equal-ear LFE, declared
 *    latency, cleared non-ear lanes) and head-yaw interpolation (static positions, wrap, continuity,
 *    live-parameter rules);
 *  - mode switches (stereo -> 5.1 -> binaural -> stereo) through the rebuild fade do not click. */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#define BLOCK 200u
#define MAXN 512u
#define MAXC 8u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static uint32_t rngState = 1;
static float frand(void) {
    rngState = rngState * 1664525u + 1013904223u;
    return (float)((double)(rngState >> 8) / 8388608.0 - 1.0);
}

static n60_layout stdLayout(uint32_t id) {
    n60_layout l;
    CHECK(n60_layout_standard(id, &l) == N60_STATUS_OK, "standard layout %u", id);
    return l;
}

static n60_layout_options baseOptions(double rate, const n60_layout *l, uint32_t chans) {
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = MAXN;
    o.graphChannels = chans;
    o.layout = l;
    return o;
}

static n60_layout_graph *buildLG(const n60_layout_options *o) {
    n60_layout_graph *lg = NULL;
    n60_status s = n60_layout_graph_build(o, &lg);
    CHECK(s == N60_STATUS_OK && lg, "layout graph build status %d", s);
    return lg;
}

static n60_graph *graphOf(n60_layout_graph *lg) {
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(n60_layout_graph_desc(lg), &g);
    CHECK(s == N60_STATUS_OK && g, "graph build status %d", s);
    return g;
}

/* One processing block: in[c] -> out[c]. */
typedef struct {
    float in[MAXC][MAXN], out[MAXC][MAXN];
    uint32_t ch;
} IO;

static void run(n60_graph *g, IO *io, uint32_t frames) {
    const float *ip[MAXC];
    float *op[MAXC];
    for (uint32_t c = 0; c < io->ch; c++) { ip[c] = io->in[c]; op[c] = io->out[c]; }
    n60_status s = n60_graph_process(g, ip, op, frames);
    CHECK(s == N60_STATUS_OK, "process status %d", s);
}

static void post(n60_graph *g, uint32_t stageId, uint32_t idx, float v) {
    n60_param_record r = {stageId, idx, v, 0};
    n60_status s = n60_graph_post_params(g, &r, 1);
    CHECK(s == N60_STATUS_OK, "post %u/%u = %g gave %d", stageId, idx, v, s);
}

/* ---------- layouts ---------- */
static void testLayouts(void) {
    static const uint32_t counts[] = {0, 2, 6, 8, 8, 10, 12, 16};
    for (uint32_t id = 1; id <= 7; id++) {
        n60_layout l = stdLayout(id);
        CHECK(l.channelCount == counts[id], "layout %u has %u channels", id, l.channelCount);
        CHECK(n60_layout_validate(&l) == N60_STATUS_OK, "layout %u validates", id);
    }
    CHECK(n60_layout_standard(0, &(n60_layout){0}) == N60_STATUS_BAD_ARGUMENT, "custom is not standard");
    CHECK(n60_layout_standard(8, &(n60_layout){0}) == N60_STATUS_BAD_ARGUMENT, "unknown standard id");

    n60_layout_info info;
    memset(&info, 0, sizeof info);
    info.structSize = sizeof info;
    n60_layout st = stdLayout(N60_LAYOUT_STEREO);
    CHECK(n60_layout_describe(&st, &info) == N60_STATUS_OK, "describe stereo");
    CHECK(info.pairCount == 1 && info.pairLaneA[0] == 0 && info.pairLaneB[0] == 1 && info.centerLane == -1 &&
              info.lfeLane == -1 && info.frontLeftLane == 0 && info.frontRightLane == 1 && info.singleMask == 0,
          "stereo pairing");
    n60_layout l51 = stdLayout(N60_LAYOUT_5_1);
    CHECK(n60_layout_describe(&l51, &info) == N60_STATUS_OK, "describe 5.1");
    CHECK(info.pairCount == 2 && info.pairLaneA[1] == 4 && info.pairLaneB[1] == 5 && info.centerLane == 2 &&
              info.lfeLane == 3 && info.pairedMask == 0x33 && info.singleMask == 0x4,
          "5.1 pairing: pairs %u paired %llx single %llx", info.pairCount, (unsigned long long)info.pairedMask,
          (unsigned long long)info.singleMask);
    n60_layout l916 = stdLayout(N60_LAYOUT_9_1_6);
    CHECK(n60_layout_describe(&l916, &info) == N60_STATUS_OK && info.pairCount == 7, "9.1.6 has seven pairs");
    n60_layout cust;
    memset(&cust, 0, sizeof cust);
    cust.structSize = sizeof cust;
    cust.channelCount = 5;
    uint32_t roles[5] = {N60_ROLE_CUSTOM_1, N60_ROLE_CUSTOM_1 + 1, N60_ROLE_FRONT_CENTER, N60_ROLE_REAR_LEFT, N60_ROLE_LFE};
    memcpy(cust.roles, roles, sizeof roles);
    CHECK(n60_layout_describe(&cust, &info) == N60_STATUS_OK && info.pairCount == 1 && info.pairLaneA[0] == 0 &&
              info.singleMask == 0xC && info.lfeLane == 4,
          "custom layout pairs customs and leaves RL single");

    n60_layout bad = cust;
    bad.roles[1] = N60_ROLE_CUSTOM_1;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "duplicate role rejected");
    bad = cust;
    bad.roles[0] = 0;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "unused role rejected");
    bad = cust;
    bad.roles[0] = 33;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "role beyond custom 16 rejected");
    bad = cust;
    bad.channelCount = 0;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "empty layout rejected");
    bad = cust;
    bad.channelCount = N60_LAYOUT_MAX_CHANNELS + 1;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "oversize layout rejected");
    bad = cust;
    bad.structSize = 4;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "bad structSize rejected");
    bad = st;
    bad.roles[0] = N60_ROLE_FRONT_RIGHT;
    bad.roles[1] = N60_ROLE_FRONT_LEFT;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "swapped stereo is not canonical");
    bad = l51;
    bad.channelCount = 5;
    CHECK(n60_layout_validate(&bad) == N60_STATUS_BAD_ARGUMENT, "5.1 with five channels is not canonical");
    CHECK(n60_layout_validate(NULL) == N60_STATUS_BAD_ARGUMENT, "NULL layout");
}

static void testBuilderRejects(void) {
    n60_layout st = stdLayout(N60_LAYOUT_STEREO);
    n60_layout_graph *lg = NULL;
    n60_layout_options o = baseOptions(48000, &st, 0);
    CHECK(n60_layout_graph_build(NULL, &lg) == N60_STATUS_BAD_ARGUMENT && lg == NULL, "NULL options");
    CHECK(n60_layout_graph_build(&o, NULL) == N60_STATUS_BAD_ARGUMENT, "NULL out");
    o.mode = N60_MODE_BINAURAL;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT && lg == NULL, "binaural needs a profile");
    o = baseOptions(48000, &st, 1);
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "graph smaller than the layout");
    o = baseOptions(48000, &st, 65);
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "graph beyond the channel limit");
    o = baseOptions(48000, &st, 0);
    o.peqParamCount = 3;
    float peq[4] = {0, 1000, 1, 1};
    o.peq = peq;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "PEQ params not a multiple of four");
    o = baseOptions(48000, &st, 0);
    o.reserved = 1;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "reserved must be zero");
    o = baseOptions(10.0, &st, 0);
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT && lg == NULL, "bad rate caught by validation");
    o = baseOptions(48000, &st, 0);
    o.inputGain = -1.0f;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "negative input gain");

    float ir[2 * 2 * 4] = {0};
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = 4;
    p.orientations = 1;
    p.equalEarChannel = -1;
    p.responses = ir;
    o = baseOptions(48000, &st, 0);
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    lg = buildLG(&o);
    n60_layout_graph_free(lg);
    p.equalEarChannel = 2;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "equal-ear index beyond the layout");
    p.equalEarChannel = -1;
    p.taps = 0;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "zero taps");
    p.taps = 4;
    p.orientations = 65;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "too many orientation sets");
    p.orientations = 3;
    p.yawStepDeg = 0;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_BAD_ARGUMENT, "multi-set profile needs a yaw step");
    n60_layout one;
    memset(&one, 0, sizeof one);
    one.structSize = sizeof one;
    one.channelCount = 1;
    one.roles[0] = N60_ROLE_FRONT_CENTER;
    p.orientations = 1;
    o.layout = &one;
    lg = buildLG(&o);  /* mono binaural: the graph grows to two channels for the ears */
    if (lg) {
        CHECK(n60_layout_graph_desc(lg)->outputChannels == 2, "mono binaural graph has two channels");
        n60_layout_graph_free(lg);
    }
    n60_layout_graph_free(NULL);
}

/* ---------- stereo parity ---------- */
static n60_stage_desc stg(uint32_t kind, uint32_t id, uint32_t laneA, uint32_t laneB, uint64_t mask, const float *p,
                          uint32_t n) {
    n60_stage_desc s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.laneB = laneB;
    s.laneMask = mask;
    s.params = p;
    s.paramCount = n;
    return s;
}

static void testStereoParity(void) {
    for (size_t r = 0; r < 8; r++) {
        const double rate = kRates[r];
        n60_layout st = stdLayout(N60_LAYOUT_STEREO);
        n60_layout l51 = stdLayout(N60_LAYOUT_5_1);
        const float peq[8] = {0, (float)(1000 * rate / 48000), 3, 1, 2, (float)(6000 * rate / 48000), -2, 0.7f};
        n60_layout_options o = baseOptions(rate, &st, 0);
        o.inputGain = 0.5f;
        o.midSide = 1;
        o.peq = peq;
        o.peqParamCount = 8;
        o.linkedDynamics = 1;
        o.headphoneCrossfeed = 0.3f;
        o.outputGain = 0.8f;
        o.protection = 1;
        n60_layout_graph *lgS = buildLG(&o);
        n60_layout_options o6 = o;
        o6.layout = &l51;
        n60_layout_graph *lg6 = buildLG(&o6);

        const float g0 = 0.5f, og = 0.8f;
        const float comp[10] = {-18, 2, 6, 10, 100, 0, 0, 0, 0, 1};
        const float hp[11] = {0, 0.3f, 30, 0.0875f, 700, 0, 0, 0, 0, 0, 0};
        const float prot[7] = {1, -1, 1, 100, 0, 0, 1};
        n60_stage_desc hand[] = {
            stg(N60_STAGE_SANITISE, 1, N60_LANE_ALL, 0, 0, NULL, 0),
            stg(N60_STAGE_METER_IN, 2, N60_LANE_ALL, 0, 0, NULL, 0),
            stg(N60_STAGE_GAIN, 3, N60_LANE_ALL, 0, 0, &g0, 1),
            stg(N60_STAGE_MS_ENCODE, 100, 0, 1, 0, NULL, 0),
            stg(N60_STAGE_PEQ, 5, N60_LANE_ALL, 0, 0, peq, 8),
            stg(N60_STAGE_MS_DECODE, 120, 0, 1, 0, NULL, 0),
            stg(N60_STAGE_COMPRESSOR, 140, 0, 0, 3, comp, 10),
            stg(N60_STAGE_METER_OUT, 7, N60_LANE_ALL, 0, 0, NULL, 0),
            stg(N60_STAGE_OUTPUT_GAIN, 65, 0, 0, 0, &og, 1),
            stg(N60_STAGE_OUTPUT_GAIN, 66, 1, 0, 0, &og, 1),
            stg(N60_STAGE_HEADPHONE, 61, 0, 1, 0, hp, 11),
            stg(N60_STAGE_PROTECTION, 62, 0, 0, 3, prot, 7),
            stg(N60_STAGE_FINAL_SANITISE, 63, N60_LANE_ALL, 0, 0, NULL, 0),
            stg(N60_STAGE_FINAL_METER, 64, N60_LANE_ALL, 0, 0, NULL, 0),
        };
        n60_graph_desc hd;
        memset(&hd, 0, sizeof hd);
        hd.structSize = sizeof hd;
        hd.abiVersion = N60_GRAPH_ABI_VERSION;
        hd.sampleRate = rate;
        hd.maxBlockFrames = MAXN;
        hd.inputChannels = hd.outputChannels = 2;
        hd.stages = hand;
        hd.stageCount = sizeof hand / sizeof hand[0];
        n60_graph *gHand = NULL;
        CHECK(n60_graph_build(&hd, &gHand) == N60_STATUS_OK, "hand-built stereo graph at %.0f", rate);
        n60_graph *gS = graphOf(lgS), *g6 = graphOf(lg6);
        if (!gHand || !gS || !g6) { failures++; continue; }

        IO a, b, c;
        a.ch = b.ch = 2;
        c.ch = 6;
        rngState = 7;
        double worst = 0, peak = 0;
        int identical = 1, lanes = 1;
        for (int blk = 0; blk < 24; blk++) {
            for (uint32_t i = 0; i < BLOCK; i++) {
                const float l = 0.6f * frand() * (blk > 12 ? 2.5f : 1.0f), rr = 0.4f * frand();
                a.in[0][i] = b.in[0][i] = c.in[0][i] = l;
                a.in[1][i] = b.in[1][i] = c.in[1][i] = rr;
                for (uint32_t k = 2; k < 6; k++) c.in[k][i] = 0.0f;
            }
            run(gHand, &a, BLOCK);
            run(gS, &b, BLOCK);
            run(g6, &c, BLOCK);
            for (uint32_t k = 0; k < 2; k++) {
                if (memcmp(a.out[k], b.out[k], sizeof(float) * BLOCK) != 0) identical = 0;
                if (memcmp(a.out[k], c.out[k], sizeof(float) * BLOCK) != 0) lanes = 0;
                for (uint32_t i = 0; i < BLOCK; i++) {
                    worst = fmax(worst, fabs((double)a.out[k][i] - c.out[k][i]));
                    peak = fmax(peak, fabs(a.out[k][i]));
                }
            }
            for (uint32_t k = 2; k < 6; k++) {
                for (uint32_t i = 0; i < BLOCK; i++) CHECK(c.out[k][i] == 0.0f, "5.1 silent lane %u not silent", k);
            }
        }
        CHECK(identical, "rate %.0f: builder stereo graph differs from the hand-built stage list", rate);
        CHECK(lanes || worst < 1e-6, "rate %.0f: 5.1 L/R lanes differ from stereo by %g (peak %g)", rate, worst, peak);
        CHECK(peak > 0.05, "rate %.0f: stereo test signal reached the output (%g)", rate, peak);
        n60_graph_retire(gHand);
        n60_graph_retire(gS);
        n60_graph_retire(g6);
        n60_layout_graph_free(lgS);
        n60_layout_graph_free(lg6);
    }
}

/* ---------- binaural against direct convolution ---------- */
static void testBinauralConvolution(void) {
    for (size_t r = 0; r < 8; r++) {
        const double rate = kRates[r];
        n60_layout l51 = stdLayout(N60_LAYOUT_5_1);
        const uint32_t taps = 300, N = 6, latDecl = 17, CH = 8;
        float *ir = malloc(sizeof(float) * N * 2 * taps);
        rngState = 31;
        for (uint32_t k = 0; k < N; k++) {
            for (uint32_t e = 0; e < 2; e++) {
                for (uint32_t t = 0; t < taps; t++) ir[((size_t)k * 2 + e) * taps + t] = 0.4f * frand() * expf(-(float)t / 60.0f);
            }
        }
        n60_binaural_profile p;
        memset(&p, 0, sizeof p);
        p.structSize = sizeof p;
        p.taps = taps;
        p.orientations = 1;
        p.equalEarChannel = 3;
        p.declaredLatency = latDecl;
        p.responses = ir;
        n60_layout_options o = baseOptions(rate, &l51, CH);
        o.mode = N60_MODE_BINAURAL;
        o.binaural = &p;
        n60_layout_graph *lg = buildLG(&o);
        n60_graph *g = graphOf(lg);
        if (!g) { free(ir); failures++; continue; }
        CHECK(n60_graph_latency_frames(g) == 128 + latDecl, "rate %.0f: binaural latency %u", rate, n60_graph_latency_frames(g));

        enum { TOTAL = 2400 };
        static float x[6][TOTAL], y[2][TOTAL];
        IO io;
        io.ch = CH;
        rngState = 77;
        int pos = 0, cleared = 1;
        while (pos < TOTAL) {
            const uint32_t n = pos + BLOCK <= TOTAL ? BLOCK : TOTAL - pos;
            for (uint32_t c = 0; c < CH; c++) {
                for (uint32_t i = 0; i < n; i++) {
                    io.in[c][i] = c < N ? 0.3f * frand() : 0.0f;
                    if (c < N) x[c][pos + i] = io.in[c][i];
                }
            }
            run(g, &io, n);
            for (uint32_t i = 0; i < n; i++) {
                y[0][pos + i] = io.out[0][i];
                y[1][pos + i] = io.out[1][i];
                for (uint32_t c = 2; c < CH; c++) if (io.out[c][i] != 0.0f) cleared = 0;
            }
            pos += (int)n;
        }
        CHECK(cleared, "rate %.0f: lanes beyond the ears are silent", rate);
        double worst = 0, peak = 0;
        for (int n = 0; n < TOTAL; n++) {
            for (uint32_t e = 0; e < 2; e++) {
                double ref = 0;
                for (uint32_t k = 0; k < N; k++) {
                    for (uint32_t t = 0; t < taps; t++) {
                        const int idx = n - 128 - (int)t;
                        if (idx < 0) break;
                        double h = ir[((size_t)k * 2 + e) * taps + t];
                        if (k == 3) h = 0.5 * ((double)ir[((size_t)k * 2) * taps + t] + ir[((size_t)k * 2 + 1) * taps + t]);
                        ref += h * x[k][idx];
                    }
                }
                worst = fmax(worst, fabs(ref - y[e][n]));
                peak = fmax(peak, fabs(ref));
            }
        }
        CHECK(peak > 0.1 && worst < 2e-4, "rate %.0f: binaural vs direct convolution error %g (peak %g)", rate, worst, peak);
        n60_graph_retire(g);
        n60_layout_graph_free(lg);
        free(ir);
    }
}

/* ---------- head yaw ---------- */
/* Two-source (stereo layout) binaural graph with one-tap responses: set s has left/right gain gains[s]
 * from source 0 and zero from source 1. Source 0 carries a 1 kHz sine. */
static n60_graph *yawGraph(double rate, uint32_t sets, float start, float step, int wrap, const float *gains,
                           n60_layout_graph **lgOut) {
    static n60_layout st;
    st = stdLayout(N60_LAYOUT_STEREO);
    float ir[64 * 4];
    memset(ir, 0, sizeof ir);
    for (uint32_t s = 0; s < sets; s++) {
        ir[s * 4 + 0] = gains[s];
        ir[s * 4 + 1] = gains[s];
    }
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = 1;
    p.orientations = sets;
    p.yawStartDeg = start;
    p.yawStepDeg = step;
    p.wrap = (uint32_t)wrap;
    p.equalEarChannel = -1;
    p.responses = ir;
    p.headYawDeg = start;
    n60_layout_options o = baseOptions(rate, &st, 0);
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    *lgOut = buildLG(&o);
    return graphOf(*lgOut);
}

typedef struct {
    double phase, w;
} Sine;

/* Runs `blocks` blocks of the 1 kHz sine on source 0; returns the gain estimate of the last block
 * (output amplitude over input amplitude, delayed by 128) and the largest sample step. */
static double runSine(n60_graph *g, Sine *s, int blocks, double amp, double *maxStep, double *prevOut) {
    IO io;
    io.ch = 2;
    double gainEst = 0;
    static double hist[MAXN * 4];
    (void)hist;
    for (int b = 0; b < blocks; b++) {
        const double ph0 = s->phase;
        for (uint32_t i = 0; i < BLOCK; i++) {
            io.in[0][i] = (float)(amp * sin(s->phase));
            io.in[1][i] = 0.0f;
            s->phase += s->w;
        }
        run(g, &io, BLOCK);
        double num = 0, den = 0;
        for (uint32_t i = 0; i < BLOCK; i++) {
            const double v = io.out[0][i];
            const double ref = amp * sin(ph0 + s->w * ((double)i - 128.0));
            num += v * ref;
            den += ref * ref;
            if (maxStep && prevOut) {
                if (b > 0 || i > 0) *maxStep = fmax(*maxStep, fabs(v - *prevOut));
                *prevOut = v;
            }
        }
        gainEst = num / den;
    }
    return gainEst;
}

static void testHeadYaw(void) {
    for (size_t r = 0; r < 8; r++) {
        const double rate = kRates[r];
        const double w = 2 * kPi * 1000.0 / rate;
        const int settle = (int)ceil(0.5 * rate / BLOCK);
        {
            const float gains[3] = {1.0f, 0.5f, 0.0f};
            n60_layout_graph *lg;
            n60_graph *g = yawGraph(rate, 3, -90, 90, 0, gains, &lg);
            if (!g) { failures++; continue; }
            Sine s = {0, w};
            double e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e - 1.0) < 0.02, "rate %.0f: yaw -90 gain %g", rate, e);
            post(g, N60_LSTAGE_BINAURAL, 0, 0.0f);
            e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e - 0.5) < 0.02, "rate %.0f: yaw 0 gain %g", rate, e);
            post(g, N60_LSTAGE_BINAURAL, 0, -45.0f);
            e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e - 0.75) < 0.02, "rate %.0f: yaw -45 interpolates (%g)", rate, e);
            post(g, N60_LSTAGE_BINAURAL, 1, 25.0f);  /* pitch and roll are stored, not rendered */
            post(g, N60_LSTAGE_BINAURAL, 2, -10.0f);
            e = runSine(g, &s, 20, 0.5, NULL, NULL);
            CHECK(fabs(e - 0.75) < 0.02, "rate %.0f: pitch/roll leave the output alone (%g)", rate, e);
            post(g, N60_LSTAGE_BINAURAL, 0, 500.0f);  /* beyond the last set, no wrap: clamps to it */
            e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e) < 0.02, "rate %.0f: yaw beyond the sets clamps (%g)", rate, e);
            /* Rules for live parameters. */
            n60_param_record bad = {N60_LSTAGE_BINAURAL, 0, 721.0f, 0};
            CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_BAD_ARGUMENT, "yaw out of range");
            bad.paramIndex = 1;
            bad.value = 181.0f;
            CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_BAD_ARGUMENT, "pitch out of range");
            bad.paramIndex = 3;
            bad.value = 10.0f;
            CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_UNSUPPORTED, "taps are not live");
            bad.paramIndex = 12;
            CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_UNSUPPORTED, "responses are not live");
            bad.paramIndex = 99999;
            CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_BAD_ARGUMENT, "index beyond the params");
            n60_graph_retire(g);
            n60_layout_graph_free(lg);
        }
        {
            /* Continuity: an abrupt head turn from the first set to the last never steps. */
            const float gains[3] = {1.0f, 0.5f, 0.0f};
            n60_layout_graph *lg;
            n60_graph *g = yawGraph(rate, 3, -90, 90, 0, gains, &lg);
            if (!g) { failures++; continue; }
            Sine s = {0, w};
            double maxStep = 0, prev = 0;
            runSine(g, &s, 12, 0.5, &maxStep, &prev);
            const double quiet = maxStep;
            post(g, N60_LSTAGE_BINAURAL, 0, 90.0f);
            runSine(g, &s, settle, 0.5, &maxStep, &prev);
            const double slope = 0.5 * 2 * kPi * 1000.0 / rate;
            CHECK(maxStep < 1.5 * slope + 1e-4, "rate %.0f: head turn click: step %g vs slope %g (static %g)", rate, maxStep,
                  slope, quiet);
            n60_graph_retire(g);
            n60_layout_graph_free(lg);
        }
        {
            /* Wrap: four sets around the circle, the last neighbours the first. */
            const float gains[4] = {1.0f, 0.75f, 0.5f, 0.25f};
            n60_layout_graph *lg;
            n60_graph *g = yawGraph(rate, 4, 0, 90, 1, gains, &lg);
            if (!g) { failures++; continue; }
            Sine s = {0, w};
            runSine(g, &s, 4, 0.5, NULL, NULL);
            post(g, N60_LSTAGE_BINAURAL, 0, -45.0f);  /* between set 3 (270) and set 0 */
            double e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e - 0.625) < 0.02, "rate %.0f: wrapped yaw -45 (%g)", rate, e);
            post(g, N60_LSTAGE_BINAURAL, 0, 360.0f + 90.0f);
            e = runSine(g, &s, settle, 0.5, NULL, NULL);
            CHECK(fabs(e - 0.75) < 0.02, "rate %.0f: yaw 450 is set 1 (%g)", rate, e);
            /* The long way round never happens: 350 -> 10 degrees passes through 0, not through 180. */
            post(g, N60_LSTAGE_BINAURAL, 0, 350.0f);
            runSine(g, &s, settle, 0.5, NULL, NULL);
            double lo = 10;
            post(g, N60_LSTAGE_BINAURAL, 0, 370.0f);
            IO io;
            io.ch = 2;
            for (int b = 0; b < settle; b++) {
                const double ph0 = s.phase;
                for (uint32_t i = 0; i < BLOCK; i++) {
                    io.in[0][i] = (float)(0.5 * sin(s.phase));
                    io.in[1][i] = 0.0f;
                    s.phase += s.w;
                }
                run(g, &io, BLOCK);
                double nn = 0, dd = 0;
                for (uint32_t i = 0; i < BLOCK; i++) {
                    const double ref = 0.5 * sin(ph0 + s.w * ((double)i - 128.0));
                    nn += io.out[0][i] * ref;
                    dd += ref * ref;
                }
                lo = fmin(lo, nn / dd);
            }
            CHECK(lo > 0.55, "rate %.0f: wrap takes the short path (min gain %g)", rate, lo);
            n60_graph_retire(g);
            n60_layout_graph_free(lg);
        }
    }
}

/* ---------- mode switches ---------- */
typedef struct {
    double rate, phase[3];
    double freq[3], amp;
} Tone;

static void fillTone(Tone *t, IO *io, uint32_t frames) {
    for (uint32_t i = 0; i < frames; i++) {
        for (uint32_t c = 0; c < MAXC; c++) io->in[c][i] = 0.0f;
        for (uint32_t k = 0; k < 3; k++) {
            io->in[k][i] = (float)(t->amp * sin(t->phase[k]));
            t->phase[k] += 2 * kPi * t->freq[k] / t->rate;
        }
    }
}

static double stepsThrough(n60_graph *g, Tone *t, IO *io, int blocks, double *prev) {
    double worst = 0;
    for (int b = 0; b < blocks; b++) {
        fillTone(t, io, BLOCK);
        run(g, io, BLOCK);
        for (uint32_t i = 0; i < BLOCK; i++) {
            worst = fmax(worst, fabs((double)io->out[0][i] - *prev));
            *prev = io->out[0][i];
        }
    }
    return worst;
}

static void publishAndWait(n60_graph *g, n60_layout_graph *lg, Tone *t, IO *io, double *prev, double *worst) {
    n60_status s = n60_graph_publish(g, n60_layout_graph_desc(lg));
    CHECK(s == N60_STATUS_OK, "publish status %d", s);
    for (int b = 0; b < 400; b++) {
        *worst = fmax(*worst, stepsThrough(g, t, io, 1, prev));
        n60_rebuild_status rs;
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        n60_graph_get_rebuild_status(g, &rs);
        if (b > 2 && rs.state == 0) {
            CHECK(rs.lastResult == 1, "rebuild result %u", rs.lastResult);
            break;
        }
    }
    n60_graph_collect(g);
}

static void testModeSwitch(void) {
    for (size_t r = 0; r < 8; r++) {
        const double rate = kRates[r];
        n60_layout stereo = stdLayout(N60_LAYOUT_STEREO), l51 = stdLayout(N60_LAYOUT_5_1);
        float ir[6 * 2 * 16];
        memset(ir, 0, sizeof ir);
        for (uint32_t k = 0; k < 6; k++) {
            ir[(k * 2 + 0) * 16 + 5] = 0.7f;
            ir[(k * 2 + 1) * 16 + 9] = 0.4f;
        }
        n60_binaural_profile p;
        memset(&p, 0, sizeof p);
        p.structSize = sizeof p;
        p.taps = 16;
        p.orientations = 1;
        p.equalEarChannel = 3;
        p.responses = ir;
        n60_layout_options o = baseOptions(rate, &stereo, 6);
        n60_layout_graph *lgStereo = buildLG(&o);
        o.layout = &l51;
        n60_layout_graph *lg51 = buildLG(&o);
        o.mode = N60_MODE_BINAURAL;
        o.binaural = &p;
        n60_layout_graph *lgBin = buildLG(&o);
        n60_graph *g = graphOf(lgStereo);
        if (!g) { failures++; continue; }
        IO io;
        io.ch = 6;
        Tone t = {rate, {0, 0, 0}, {500, 700, 300}, 0.3};
        double prev = 0, worst = 0;
        stepsThrough(g, &t, &io, 4, &prev);
        const double slopeMax = 2 * kPi * 700.0 / rate;
        publishAndWait(g, lg51, &t, &io, &prev, &worst);   /* stereo -> 5.1: lanes 0 and 1 unchanged */
        CHECK(worst < 1.5 * slopeMax * 0.3 + 1e-4, "rate %.0f: stereo -> 5.1 step %g", rate, worst);
        double w2 = 0;
        publishAndWait(g, lgBin, &t, &io, &prev, &w2);     /* 5.1 -> binaural */
        const double bound = 1.5 * slopeMax * (0.3 + 0.63) + 1e-3;
        CHECK(w2 < bound, "rate %.0f: 5.1 -> binaural step %g (bound %g)", rate, w2, bound);
        double w3 = 0;
        publishAndWait(g, lgStereo, &t, &io, &prev, &w3);  /* binaural -> stereo */
        CHECK(w3 < bound, "rate %.0f: binaural -> stereo step %g (bound %g)", rate, w3, bound);
        CHECK(n60_graph_latency_frames(g) == 0, "rate %.0f: latency back to zero", rate);
        n60_graph_retire(g);
        n60_layout_graph_free(lgStereo);
        n60_layout_graph_free(lg51);
        n60_layout_graph_free(lgBin);
    }
    /* Control: an instant (unfaded) mode switch does click, so the bounds above can fail. */
    {
        const double rate = 48000;
        n60_layout stereo = stdLayout(N60_LAYOUT_STEREO), l51 = stdLayout(N60_LAYOUT_5_1);
        float ir[6 * 2 * 16];
        memset(ir, 0, sizeof ir);
        for (uint32_t k = 0; k < 6; k++) { ir[(k * 2 + 0) * 16 + 5] = 0.7f; ir[(k * 2 + 1) * 16 + 9] = 0.4f; }
        n60_binaural_profile p;
        memset(&p, 0, sizeof p);
        p.structSize = sizeof p;
        p.taps = 16;
        p.orientations = 1;
        p.equalEarChannel = -1;
        p.responses = ir;
        n60_layout_options o = baseOptions(rate, &l51, 6);
        n60_layout_graph *lg51 = buildLG(&o);
        o.mode = N60_MODE_BINAURAL;
        o.binaural = &p;
        n60_layout_graph *lgBin = buildLG(&o);
        (void)stereo;
        n60_graph *g = graphOf(lg51);
        n60_rebuild_options hard = {sizeof hard, 0.0f, 0.0f, 0};
        CHECK(n60_graph_set_rebuild_options(g, &hard) == N60_STATUS_OK, "instant swaps");
        IO io;
        io.ch = 6;
        Tone t = {rate, {0, 0, 0}, {500, 700, 300}, 0.3};
        double prev = 0, worst = 0;
        stepsThrough(g, &t, &io, 4, &prev);
        n60_graph_publish(g, n60_layout_graph_desc(lgBin));
        for (int b = 0; b < 8; b++) worst = fmax(worst, stepsThrough(g, &t, &io, 1, &prev));
        CHECK(worst > 0.1, "control: instant switch steps by %g", worst);
        n60_graph_retire(g);
        n60_layout_graph_free(lg51);
        n60_layout_graph_free(lgBin);
    }
}

int main(void) {
    CHECK(n60_graph_abi_version() == N60_GRAPH_ABI_VERSION && N60_GRAPH_ABI_VERSION == 8u, "ABI v8");
    testLayouts();
    testBuilderRejects();
    testStereoParity();
    testBinauralConvolution();
    testHeadYaw();
    testModeSwitch();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("n60core layouts and binaural stage: all checks passed");
    return 0;
}
