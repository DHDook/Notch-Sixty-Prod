/*
 * E6 S8c: behavioural harness for the ABI v8 readbacks (n60_graph_read_dynamics and
 * n60_graph_read_over_range) through the C ABI at the eight standard rates:
 *  - compressor and expander gain reduction against the static gain law (closed form),
 *  - linked and unlinked lane groups,
 *  - protection true-peak on an inter-sample-peak tone (a sine at fs/4, phase 45 degrees: its samples
 *    reach 0.707 of the amplitude, its true peak is the full amplitude), limiter reduction and the
 *    guard flag,
 *  - over-range counts on a clipped burst,
 *  - limiter switched off and on again during playback,
 *  - reset-on-read, argument validation.
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
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

#define BLOCK 512u

static n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t lane, uint64_t mask, const float *params, uint32_t np) {
    n60_stage_desc s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = lane;
    s.laneMask = mask;
    s.params = params;
    s.paramCount = np;
    return s;
}

static n60_graph *build(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = BLOCK;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    n60_graph *g = NULL;
    n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK && g, "build %d at %.0f", s, rate);
    return g;
}

/* Renders `frames` frames of `ch` lanes whose samples come from fn(lane, absoluteIndex), in BLOCK chunks. */
typedef float (*SignalFn)(uint32_t lane, uint64_t i, double rate, const double *arg);
static void run(n60_graph *g, uint32_t ch, uint64_t from, uint64_t frames, SignalFn fn, double rate, const double *arg) {
    static float in[N60_GRAPH_MAX_CHANNELS][BLOCK], out[N60_GRAPH_MAX_CHANNELS][BLOCK];
    const float *ip[N60_GRAPH_MAX_CHANNELS];
    float *op[N60_GRAPH_MAX_CHANNELS];
    for (uint32_t c = 0; c < ch; c++) { ip[c] = in[c]; op[c] = out[c]; }
    for (uint64_t pos = 0; pos < frames; pos += BLOCK) {
        uint32_t n = frames - pos < BLOCK ? (uint32_t)(frames - pos) : BLOCK;
        for (uint32_t c = 0; c < ch; c++)
            for (uint32_t i = 0; i < n; i++) in[c][i] = fn(c, from + pos + i, rate, arg);
        CHECK(n60_graph_process(g, ip, op, n) == N60_STATUS_OK, "process");
    }
}

static float dcSignal(uint32_t lane, uint64_t i, double rate, const double *arg) {
    (void)i; (void)rate;
    return (float)arg[lane];
}
/* Sine at fs/4 with a 45 degree phase: every sample is +-0.7071 * amplitude, the true peak is the amplitude. */
static float isp(uint32_t lane, uint64_t i, double rate, const double *arg) {
    (void)rate;
    static const double s[4] = {0.70710678118654752, 0.70710678118654752, -0.70710678118654752, -0.70710678118654752};
    return (float)(arg[lane] * s[i & 3]);
}
/* Silence with a burst of 100 samples at 1.5 in frames [1000, 1100). */
static float burst(uint32_t lane, uint64_t i, double rate, const double *arg) {
    (void)lane; (void)rate; (void)arg;
    return (i >= 1000 && i < 1100) ? 1.5f : 0.0f;
}

static double db(double lin) { return 20.0 * log10(lin); }

static n60_dynamics_readback readDyn(n60_graph *g, uint32_t id, uint32_t lane, n60_status *st) {
    n60_dynamics_readback r;
    memset(&r, 0, sizeof r);
    r.structSize = sizeof r;
    n60_status s = n60_graph_read_dynamics(g, id, lane, &r);
    if (st) *st = s;
    return r;
}

static void testCompressor(double rate) {
    /* threshold -20 dB, ratio 4, hard knee, attack 1 ms, release 50 ms, no make-up, feed-forward, linked */
    const float linked[10] = {-20, 4, 0, 1, 50, 0, 0, 0, 0, 1};
    const float unlinked[10] = {-20, 4, 0, 1, 50, 0, 0, 0, 0, 0};
    const uint64_t settle = (uint64_t)(rate * 0.4);
    /* DC 0.5 is -6.0206 dBFS: 13.979 dB over, so the static reduction is 13.979 * (1 - 1/4) = 10.484 dB. */
    const double expected = (db(0.5) + 20.0) * 0.75;
    {
        n60_stage_desc st = stage(N60_STAGE_COMPRESSOR, 10, 0, 3, linked, 10);
        n60_graph *g = build(rate, 2, &st, 1);
        double sig[2] = {0.5, 0.1};
        run(g, 2, 0, settle, dcSignal, rate, sig);
        for (uint32_t lane = 0; lane < 2; lane++) {
            n60_status s;
            n60_dynamics_readback r = readDyn(g, 10, lane, &s);
            CHECK(s == N60_STATUS_OK && r.kind == N60_STAGE_COMPRESSOR, "linked read lane %u status %d", lane, s);
            CHECK(fabs(r.grNowDb - expected) < 0.05, "%.0f linked lane %u grNow %.4f expected %.4f", rate, lane, r.grNowDb, expected);
            CHECK(r.grMaxDb >= r.grNowDb - 1e-4 && r.grMaxDb < expected + 0.05, "%.0f linked grMax %.4f", rate, r.grMaxDb);
            CHECK(r.inTruePeak == 0 && r.outTruePeak == 0 && r.guardActive == 0, "dynamics stage has no true peak");
        }
        /* The read reset grMax; with no further rendering it reads 0 while grNow stays. */
        n60_dynamics_readback r = readDyn(g, 10, 0, NULL);
        CHECK(r.grMaxDb == 0.0f && fabs(r.grNowDb - expected) < 0.05, "%.0f reset on read: grMax %.4f grNow %.4f", rate, r.grMaxDb, r.grNowDb);
        /* Render one block more: grMax is back (the reduction is held). */
        run(g, 2, settle, BLOCK, dcSignal, rate, sig);
        r = readDyn(g, 10, 1, NULL);
        CHECK(fabs(r.grMaxDb - expected) < 0.05, "%.0f grMax after another block %.4f", rate, r.grMaxDb);
        n60_graph_retire(g);
    }
    {
        n60_stage_desc st = stage(N60_STAGE_COMPRESSOR, 10, 0, 3, unlinked, 10);
        n60_graph *g = build(rate, 2, &st, 1);
        double sig[2] = {0.5, 0.05}; /* lane 1 is -26 dBFS: under the threshold */
        run(g, 2, 0, settle, dcSignal, rate, sig);
        n60_dynamics_readback r0 = readDyn(g, 10, 0, NULL), r1 = readDyn(g, 10, 1, NULL);
        CHECK(fabs(r0.grNowDb - expected) < 0.05, "%.0f unlinked lane 0 %.4f", rate, r0.grNowDb);
        CHECK(r1.grNowDb == 0.0f && r1.grMaxDb == 0.0f, "%.0f unlinked lane 1 under threshold %.4f", rate, r1.grNowDb);
        n60_graph_retire(g);
    }
    {
        /* CORE_DYNAMICS runs the compressor rules and reads like a compressor. */
        n60_stage_desc st = stage(N60_STAGE_CORE_DYNAMICS, 11, 0, 1, linked, 10);
        n60_graph *g = build(rate, 1, &st, 1);
        double sig[1] = {0.5};
        run(g, 1, 0, settle, dcSignal, rate, sig);
        n60_status s;
        n60_dynamics_readback r = readDyn(g, 11, 0, &s);
        CHECK(s == N60_STATUS_OK && fabs(r.grNowDb - expected) < 0.05, "%.0f core dynamics status %d grNow %.4f", rate, s, r.grNowDb);
        n60_graph_retire(g);
    }
}

static void testExpander(double rate) {
    /* threshold -40 dB, ratio 2, range -60 dB, attack 1 ms, release 50 ms, linked */
    const float p[6] = {-40, 2, -60, 1, 50, 1};
    n60_stage_desc st = stage(N60_STAGE_EXPANDER, 12, 0, 3, p, 6);
    n60_graph *g = build(rate, 2, &st, 1);
    /* DC 0.001 is -60 dBFS: (ratio - 1) * (-60 + 40) = -20 dB of gain, above the -60 dB range floor. */
    double sig[2] = {0.001, 0.0005};
    run(g, 2, 0, (uint64_t)(rate * 0.4), dcSignal, rate, sig);
    for (uint32_t lane = 0; lane < 2; lane++) {
        n60_status s;
        n60_dynamics_readback r = readDyn(g, 12, lane, &s);
        CHECK(s == N60_STATUS_OK && r.kind == N60_STAGE_EXPANDER, "expander status %d", s);
        CHECK(fabs(r.grNowDb - 20.0) < 0.1, "%.0f expander lane %u attenuation %.4f expected 20", rate, lane, r.grNowDb);
    }
    n60_graph_retire(g);
}

static void testProtection(double rate) {
    /* limiter on, ceiling -6 dB, attack 1 ms, release 50 ms, look-ahead 10 ms, true-peak guard, factor 4 */
    const float guard[7] = {1, -6, 1, 50, 10, 1, 4};
    const float plain[7] = {1, -6, 1, 50, 10, 0, 1};
    const double ceilLin = pow(10.0, -6.0 / 20.0);
    const uint64_t settle = (uint64_t)(rate * 0.3);
    {
        n60_stage_desc st = stage(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, 0, guard, 7);
        n60_graph *g = build(rate, 2, &st, 1);
        double sig[2] = {0.9, 0.45};
        run(g, 2, 0, settle, isp, rate, sig);
        (void)readDyn(g, 20, 0, NULL); /* discard the attack transient */
        (void)readDyn(g, 20, 1, NULL);
        run(g, 2, settle, (uint64_t)(rate * 0.05), isp, rate, sig);
        n60_status s;
        n60_dynamics_readback r0 = readDyn(g, 20, 0, &s), r1 = readDyn(g, 20, 1, NULL);
        CHECK(s == N60_STATUS_OK && r0.kind == N60_STAGE_PROTECTION, "protection read status %d", s);
        CHECK(r0.guardActive == 1, "%.0f guard active", rate);
        /* The inter-sample peak: 0.9 true against 0.636 at the samples. */
        CHECK(fabs(r0.inTruePeak - 0.9) < 0.02, "%.0f lane 0 input true peak %.4f expected 0.9", rate, r0.inTruePeak);
        CHECK(r0.inTruePeak > 0.636 + 0.1, "%.0f true peak above the sample peak: %.4f", rate, r0.inTruePeak);
        CHECK(fabs(r1.inTruePeak - 0.45) < 0.012, "%.0f lane 1 input true peak %.4f expected 0.45", rate, r1.inTruePeak);
        CHECK(r0.outTruePeak <= ceilLin * 1.001, "%.0f output true peak %.4f over the ceiling %.4f", rate, r0.outTruePeak, ceilLin);
        CHECK(r0.outTruePeak > ceilLin * 0.9, "%.0f output true peak %.4f unexpectedly low", rate, r0.outTruePeak);
        const double expectedGr = db(0.9 / ceilLin);
        CHECK(fabs(r0.grNowDb - expectedGr) < 0.3, "%.0f limiter reduction %.4f expected %.4f", rate, r0.grNowDb, expectedGr);
        CHECK(r0.grMaxDb >= r0.grNowDb - 1e-3 && fabs(r1.grMaxDb - r0.grMaxDb) < 1e-6 && fabs(r1.grNowDb - r0.grNowDb) < 1e-6,
              "%.0f reduction is linked across lanes: %.4f/%.4f vs %.4f/%.4f", rate, r0.grMaxDb, r0.grNowDb, r1.grMaxDb, r1.grNowDb);
        r0 = readDyn(g, 20, 0, NULL);
        CHECK(r0.grMaxDb == 0.0f && r0.inTruePeak == 0.0f && r0.outTruePeak == 0.0f, "%.0f protection reset on read", rate);
        n60_graph_retire(g);
    }
    {
        n60_stage_desc st = stage(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, 0, plain, 7);
        n60_graph *g = build(rate, 2, &st, 1);
        double sig[2] = {0.9, 0.9};
        run(g, 2, 0, (uint64_t)(rate * 0.1), isp, rate, sig);
        n60_dynamics_readback r = readDyn(g, 20, 0, NULL);
        CHECK(r.guardActive == 0, "%.0f no guard without oversampling", rate);
        CHECK(fabs(r.inTruePeak - 0.9 * 0.70710678) < 1e-3, "%.0f sample peak %.4f expected 0.636", rate, r.inTruePeak);
        n60_graph_retire(g);
    }
    {
        /* Limiter off: protection is a bypass; nothing is measured and nothing is reduced. */
        const float off[7] = {0, -6, 1, 50, 10, 0, 1};
        n60_stage_desc st = stage(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, 0, off, 7);
        n60_graph *g = build(rate, 2, &st, 1);
        double sig[2] = {0.9, 0.9};
        run(g, 2, 0, (uint64_t)(rate * 0.05), isp, rate, sig);
        n60_dynamics_readback r = readDyn(g, 20, 0, NULL);
        CHECK(r.grMaxDb == 0.0f && r.grNowDb == 0.0f && r.guardActive == 0, "%.0f bypassed protection reads zero", rate);
        n60_graph_retire(g);
    }
}

/* Publishes `st` as the graph's new topology (same rate and channels as `build`). */
static void republish(n60_graph *g, double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = BLOCK;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish at %.0f", rate);
}

/* S8c follow-up: the limiter is switched off, then on again, while the graph is rendering. The limiter
 * flag is not a live parameter (only 1..3 are), so the switch is a topology publish; the readbacks must
 * follow it: a bypassed limiter reads zero reduction and no guard, passes the signal through unchanged,
 * and reading again after the switch back shows the limiter working. */
static void testLimiterBypassedDuringPlayback(double rate) {
    const float on[7] = {1, -6, 1, 50, 10, 1, 4};
    const float off[7] = {0, -6, 1, 50, 10, 1, 4};
    const double ceilLin = pow(10.0, -6.0 / 20.0);
    n60_stage_desc stOn = stage(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, 0, on, 7);
    n60_stage_desc stOff = stage(N60_STAGE_PROTECTION, 20, N60_LANE_ALL, 0, off, 7);
    n60_graph *g = build(rate, 2, &stOn, 1);
    double sig[2] = {0.9, 0.9};
    uint64_t pos = 0;
    const uint64_t settle = (uint64_t)(rate * 0.3);
    run(g, 2, pos, settle, isp, rate, sig);
    pos += settle;
    n60_dynamics_readback r = readDyn(g, 20, 0, NULL);
    CHECK(r.guardActive == 1 && r.grNowDb > 1.0 && r.grMaxDb > 1.0, "%.0f limiter working before bypass: gr %.3f guard %u", rate, r.grNowDb, r.guardActive);

    /* A live parameter post cannot flip the limiter flag. */
    n60_param_record rec = {20, 0, 0.0f, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_UNSUPPORTED, "limiter flag is not a live parameter");

    /* Bypass during playback. Drain the switch (new snapshot adopted by the next block), then measure. */
    republish(g, rate, 2, &stOff, 1);
    run(g, 2, pos, BLOCK * 4, isp, rate, sig);
    pos += BLOCK * 4;
    (void)readDyn(g, 20, 0, NULL);
    (void)readDyn(g, 20, 1, NULL);
    (void)n60_graph_collect(g);
    run(g, 2, pos, (uint64_t)(rate * 0.1), isp, rate, sig);
    pos += (uint64_t)(rate * 0.1);
    for (uint32_t lane = 0; lane < 2; lane++) {
        n60_status s;
        r = readDyn(g, 20, lane, &s);
        CHECK(s == N60_STATUS_OK && r.kind == N60_STAGE_PROTECTION, "bypassed read status %d", s);
        CHECK(r.grNowDb == 0.0f && r.grMaxDb == 0.0f && r.guardActive == 0 && r.inTruePeak == 0.0f && r.outTruePeak == 0.0f,
              "%.0f bypassed lane %u reads zero: gr %.3f/%.3f guard %u in %.3f out %.3f", rate, lane,
              r.grNowDb, r.grMaxDb, r.guardActive, r.inTruePeak, r.outTruePeak);
    }
    /* The bypassed stage passes the signal through unchanged and adds no latency. */
    {
        static float in[2][BLOCK], out[2][BLOCK];
        const float *ip[2] = {in[0], in[1]};
        float *op[2] = {out[0], out[1]};
        for (uint32_t i = 0; i < BLOCK; i++) in[0][i] = in[1][i] = isp(0, pos + i, rate, sig);
        CHECK(n60_graph_process(g, ip, op, BLOCK) == N60_STATUS_OK, "process bypassed");
        int same = 1;
        for (uint32_t i = 0; i < BLOCK; i++) same &= out[0][i] == in[0][i] && out[1][i] == in[1][i];
        CHECK(same, "%.0f bypassed limiter is bit-exact", rate);
        pos += BLOCK;
    }

    /* Back on during playback: the limiter and the guard report again, within the ceiling. */
    republish(g, rate, 2, &stOn, 1);
    run(g, 2, pos, settle, isp, rate, sig);
    pos += settle;
    (void)readDyn(g, 20, 0, NULL);
    run(g, 2, pos, (uint64_t)(rate * 0.05), isp, rate, sig);
    r = readDyn(g, 20, 0, NULL);
    CHECK(r.guardActive == 1 && r.grNowDb > 1.0 && r.outTruePeak <= ceilLin * 1.001,
          "%.0f limiter back on: gr %.3f guard %u out %.4f", rate, r.grNowDb, r.guardActive, r.outTruePeak);
    n60_graph_retire(g);
}

static void testOverRange(double rate) {
    n60_stage_desc st[3];
    st[0] = stage(N60_STAGE_METER_IN, 2, N60_LANE_ALL, 0, NULL, 0);
    st[1] = stage(N60_STAGE_METER_OUT, 7, N60_LANE_ALL, 0, NULL, 0);
    st[2] = stage(N60_STAGE_GAIN, 3, N60_LANE_ALL, 0, (const float[]){0.5f}, 1);
    /* Order is fixed by the kind positions: METER_IN, GAIN, METER_OUT. */
    n60_stage_desc ordered[3] = {st[0], st[2], st[1]};
    n60_graph *g = build(rate, 2, ordered, 3);
    double sig[2] = {0, 0};
    run(g, 2, 0, 4096, burst, rate, sig);
    uint64_t in0 = 0, in1 = 0, out0 = 7;
    CHECK(n60_graph_read_over_range(g, 2, 0, &in0) == N60_STATUS_OK && in0 == 100, "%.0f input over-range lane 0: %llu", rate, (unsigned long long)in0);
    CHECK(n60_graph_read_over_range(g, 2, 1, &in1) == N60_STATUS_OK && in1 == 100, "%.0f input over-range lane 1: %llu", rate, (unsigned long long)in1);
    /* Halved by the gain stage: 0.75 does not exceed full scale downstream. */
    CHECK(n60_graph_read_over_range(g, 7, 0, &out0) == N60_STATUS_OK && out0 == 0, "%.0f output over-range after -6 dB: %llu", rate, (unsigned long long)out0);
    CHECK(n60_graph_read_over_range(g, 2, 0, &in0) == N60_STATUS_OK && in0 == 0, "%.0f over-range reset on read: %llu", rate, (unsigned long long)in0);
    run(g, 2, 0, 2048, burst, rate, sig);
    CHECK(n60_graph_read_over_range(g, 2, 0, &in0) == N60_STATUS_OK && in0 == 100, "%.0f accumulates across blocks: %llu", rate, (unsigned long long)in0);
    n60_graph_retire(g);

    /* Without the gain stage the output meter sees the burst too, and the count survives block splits. */
    n60_stage_desc two[2] = {st[0], st[1]};
    g = build(rate, 2, two, 2);
    run(g, 2, 0, 4096, burst, rate, sig);
    uint64_t o = 0;
    CHECK(n60_graph_read_over_range(g, 7, 1, &o) == N60_STATUS_OK && o == 100, "%.0f output over-range %llu", rate, (unsigned long long)o);
    n60_graph_retire(g);
}

static void testArguments(void) {
    const float p[10] = {-20, 4, 0, 1, 50, 0, 0, 0, 0, 1};
    n60_stage_desc st[2] = {stage(N60_STAGE_METER_IN, 2, N60_LANE_ALL, 0, NULL, 0), stage(N60_STAGE_COMPRESSOR, 10, 0, 1, p, 10)};
    n60_graph *g = build(48000, 2, st, 2);
    n60_status s;
    n60_dynamics_readback r;
    memset(&r, 0, sizeof r);
    r.structSize = sizeof r;
    CHECK(n60_graph_read_dynamics(NULL, 10, 0, &r) == N60_STATUS_BAD_ARGUMENT, "null graph");
    CHECK(n60_graph_read_dynamics(g, 10, 0, NULL) == N60_STATUS_BAD_ARGUMENT, "null out");
    r.structSize = 4;
    CHECK(n60_graph_read_dynamics(g, 10, 0, &r) == N60_STATUS_ABI_MISMATCH, "struct size");
    r.structSize = sizeof r;
    s = n60_graph_read_dynamics(g, 2, 0, &r);
    CHECK(s == N60_STATUS_BAD_ARGUMENT, "meter stage is not a dynamics stage: %d", s);
    s = n60_graph_read_dynamics(g, 99, 0, &r);
    CHECK(s == N60_STATUS_BAD_ARGUMENT, "unknown stage: %d", s);
    s = n60_graph_read_dynamics(g, 10, 1, &r);
    CHECK(s == N60_STATUS_BAD_ARGUMENT, "lane outside the stage mask: %d", s);
    s = n60_graph_read_dynamics(g, 10, 0, &r);
    CHECK(s == N60_STATUS_OK && r.grMaxDb == 0.0f && r.grNowDb == 0.0f, "reads zero before rendering: %d", s);
    uint64_t c;
    CHECK(n60_graph_read_over_range(g, 10, 0, &c) == N60_STATUS_BAD_ARGUMENT, "over-range of a compressor");
    CHECK(n60_graph_read_over_range(g, 2, 5, &c) == N60_STATUS_BAD_ARGUMENT, "over-range lane out of range");
    CHECK(n60_graph_read_over_range(g, 2, 0, NULL) == N60_STATUS_BAD_ARGUMENT, "over-range null count");
    CHECK(n60_graph_abi_version() == 10u && N60_GRAPH_ABI_VERSION == 10u, "ABI v10");
    n60_graph_retire(g);
}

int main(void) {
    for (unsigned i = 0; i < sizeof kRates / sizeof kRates[0]; i++) {
        testCompressor(kRates[i]);
        testExpander(kRates[i]);
        testProtection(kRates[i]);
        testOverRange(kRates[i]);
        testLimiterBypassedDuringPlayback(kRates[i]);
    }
    testArguments();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("n60core readbacks: dynamics, true-peak and over-range readbacks OK at 8 rates");
    return 0;
}
