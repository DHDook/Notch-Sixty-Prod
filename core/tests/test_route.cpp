// E8 S2: behavioural harness for the ROUTE and XOVER graph stages and the BASS_MGMT filter-spec trailer
// (libn60core ABI v17), through the C ABI at the eight standard rates. Reference values are closed forms written
// here: the matrix product, the S1 crossover library's predicted response, linear ramps.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <new>
#include <vector>

#include "n60/graph.h"
#include "n60/xover.h"
#include "snapshot.hpp"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void *operator new(std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void *operator new[](std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
constexpr uint32_t kBlock = 512;
typedef std::vector<std::vector<float>> Lanes;

static n60_stage_desc stg(uint32_t kind, uint32_t id, uint32_t laneA, const float *p, uint32_t np, uint64_t mask = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.laneMask = mask;
    s.params = p;
    s.paramCount = np;
    return s;
}

static n60_graph_desc descOf(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    return d;
}

static n60_status tryBuild(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n, n60_graph **g) {
    const n60_graph_desc d = descOf(rate, ch, st, n);
    *g = nullptr;
    return n60_graph_build(&d, g);
}

static n60_graph *build(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph *g = nullptr;
    const n60_status s = tryBuild(rate, ch, st, n, &g);
    CHECK(s == N60_STATUS_OK, "build status %d", int(s));
    return g;
}

// Processes in[ch][frames] in blocks of `block`; `pre(blockIndex)` runs before each block (posts edits).
static Lanes run(n60_graph *g, const Lanes &in, uint32_t block, const std::function<void(uint32_t)> &pre = {},
                 bool countAllocs = false) {
    const uint32_t ch = static_cast<uint32_t>(in.size()), frames = static_cast<uint32_t>(in[0].size());
    Lanes out(ch, std::vector<float>(frames));
    std::vector<float> ib(size_t(block) * ch), ob(size_t(block) * ch);
    uint32_t bi = 0;
    for (uint32_t pos = 0; pos < frames; pos += block, ++bi) {
        const uint32_t n = std::min(block, frames - pos);
        if (pre) pre(bi);
        const float *ip[64];
        float *op[64];
        for (uint32_t c = 0; c < ch; ++c) {
            std::memcpy(&ib[size_t(c) * block], &in[c][pos], n * sizeof(float));
            ip[c] = &ib[size_t(c) * block];
            op[c] = &ob[size_t(c) * block];
        }
        if (countAllocs) armed = true;
        n60_graph_process(g, ip, op, n);
        armed = false;
        for (uint32_t c = 0; c < ch; ++c) std::memcpy(&out[c][pos], op[c], n * sizeof(float));
    }
    return out;
}

static n60_status post(n60_graph *g, uint32_t stage, uint32_t idx, float v) {
    const n60_param_record r = {stage, idx, v, 0};
    return n60_graph_post_params(g, &r, 1);
}

static Lanes zeros(uint32_t ch, uint32_t frames) { return Lanes(ch, std::vector<float>(frames, 0.0f)); }

static Lanes noise(uint32_t ch, uint32_t frames, uint32_t seed, float amp) {
    Lanes x = zeros(ch, frames);
    for (uint32_t c = 0; c < ch; ++c)
        for (uint32_t i = 0; i < frames; ++i) {
            seed = seed * 1664525u + 1013904223u;
            x[c][i] = amp * (float(seed >> 8) / 8388608.0f - 1.0f);
        }
    return x;
}

static uint32_t rampOf(double rate) { return uint32_t(std::min<long>(std::max<long>(std::lround(0.005 * rate), 32), 4096)); }

// ---- ROUTE ---------------------------------------------------------------------------------------------------

static void entries(float *p, std::initializer_list<std::pair<int, float>> e) {
    for (int i = 0; i < 16; ++i) p[i] = (i & 1) ? 0.0f : -1.0f;
    int k = 0;
    for (auto &x : e) {
        p[2 * k] = float(x.first);
        p[2 * k + 1] = x.second;
        ++k;
    }
}

static void testRouteMatrix(double rate) {
    // Dests: 0 <- lane 1, 1 <- lane 0 (a swap), 4 <- (L+R)/2, 5 <- 2L - R + lane 6/8. Lane 6 is a source only.
    float p[64];
    entries(p, {{1, 1.0f}});
    entries(p + 16, {{0, 1.0f}});
    entries(p + 32, {{0, 0.5f}, {1, 0.5f}});
    entries(p + 48, {{0, 2.0f}, {1, -1.0f}, {6, 0.125f}});
    const uint64_t mask = (1u << 0) | (1u << 1) | (1u << 4) | (1u << 5);
    n60_stage_desc st[1] = {stg(N60_STAGE_ROUTE, 1, 0, p, 64, mask)};
    n60_graph *g = build(rate, 8, st, 1);
    CHECK(g != nullptr, "route build");
    if (g == nullptr) return;
    const uint32_t frames = 4096;
    const Lanes in = noise(8, frames, 7, 0.4f);
    const Lanes a = run(g, in, kBlock);
    n60_graph *g2 = build(rate, 8, st, 1);
    const Lanes b = run(g2, in, 77);
    CHECK(n60_graph_latency_frames(g) == 0, "route latency");
    double worst = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        const double ref[8] = {in[1][i], in[0][i], in[2][i], in[3][i], 0.5 * in[0][i] + 0.5 * in[1][i],
                               2.0 * in[0][i] - in[1][i] + 0.125 * in[6][i], 0.0, in[7][i]};
        for (int c = 0; c < 8; ++c) {
            if (c == 6) {
                CHECK(a[6][i] == 0.0f, "source-only lane not cleared at %u", i);
            } else if (c == 2 || c == 3 || c == 7) {
                CHECK(a[c][i] == in[c][i], "untouched lane %d changed at %u", c, i);
            } else {
                worst = std::max(worst, std::fabs(double(a[c][i]) - ref[c]));
            }
        }
    }
    CHECK(worst < 2e-6, "fs=%g matrix error %.3g", rate, worst);
    CHECK(a == b, "fs=%g route output depends on block size", rate);
    n60_graph_retire(g);
    n60_graph_retire(g2);
}

static void checkRamp(const std::vector<float> &o, double g0, double g1, uint32_t L, const char *what, double rate) {
    double worst = 0;
    for (uint32_t i = 0; i < L + 64 && i < o.size(); ++i) {
        const double ref = i < L ? g0 + (g1 - g0) * double(i + 1) / double(L) : g1;
        worst = std::max(worst, std::fabs(double(o[i]) - ref));
    }
    CHECK(worst < 3.2e-5, "fs=%g %s ramp error %.3g (ramp %u)", rate, what, worst, L);
    CHECK(o[L + 63] == float(g1), "fs=%g %s ramp does not end exactly on target", rate, what);
}

static void testRouteGainRamp(double rate) {
    float p[16];
    entries(p, {{0, 0.5f}});
    n60_stage_desc st[1] = {stg(N60_STAGE_ROUTE, 3, 0, p, 16, 1u << 1)};
    n60_graph *g = build(rate, 2, st, 1);
    if (g == nullptr) return;
    Lanes in = zeros(2, 8192);
    std::fill(in[0].begin(), in[0].end(), 1.0f);
    const uint32_t L = rampOf(rate);
    const Lanes o = run(g, in, kBlock, [&](uint32_t bi) {
        if (bi == 2) CHECK(post(g, 3, 1, -1.5f) == N60_STATUS_OK, "gain post");
    });
    CHECK(o[1][2 * kBlock - 1] == 0.5f, "gain before edit");
    const std::vector<float> tail(o[1].begin() + 2 * kBlock, o[1].end());
    checkRamp(tail, 0.5, -1.5, L, "route gain", rate);
    // Topology and out-of-range edits.
    CHECK(post(g, 3, 0, 1.0f) == N60_STATUS_UNSUPPORTED, "source lane edit must be a rebuild");
    CHECK(post(g, 3, 3, 1.0f) == N60_STATUS_UNSUPPORTED, "unused entry gain edit must be a rebuild");
    CHECK(post(g, 3, 1, 101.0f) == N60_STATUS_BAD_ARGUMENT, "gain above 100");
    CHECK(post(g, 3, 16, 1.0f) == N60_STATUS_BAD_ARGUMENT, "index past the end");
    n60_graph_retire(g);
}

static void testRouteRejects() {
    float p[32];
    entries(p, {{0, 1.0f}});
    entries(p + 16, {{1, 1.0f}});
    n60_graph *g = nullptr;
    n60_stage_desc ok = stg(N60_STAGE_ROUTE, 1, 0, p, 32, 0x6);
    CHECK(tryBuild(48000, 4, &ok, 1, &g) == N60_STATUS_OK, "valid route");
    n60_graph_retire(g);
    n60_stage_desc bad = stg(N60_STAGE_ROUTE, 1, 0, p, 16, 0x6);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "param count must be 16 per destination");
    bad = stg(N60_STAGE_ROUTE, 1, 0, p, 32, 0);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "mask required");
    bad = stg(N60_STAGE_ROUTE, 1, 0, p, 32, 0x16);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "destination past the lane count");
    float q[32];
    std::memcpy(q, p, sizeof q);
    q[0] = 4.0f;
    bad = stg(N60_STAGE_ROUTE, 1, 0, q, 32, 0x6);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "source past the lane count");
    std::memcpy(q, p, sizeof q);
    q[1] = 101.0f;
    bad = stg(N60_STAGE_ROUTE, 1, 0, q, 32, 0x6);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "gain above 100");
    std::memcpy(q, p, sizeof q);
    q[5] = 0.5f;  // unused entry with a gain
    bad = stg(N60_STAGE_ROUTE, 1, 0, q, 32, 0x6);
    CHECK(tryBuild(48000, 4, &bad, 1, &g) == N60_STATUS_BAD_ARGUMENT, "unused entry must hold gain 0");
    // Ordering: ROUTE precedes XOVER, which precedes DELAY.
    float xp[14] = {3, 0, 100, 3, 0, 1000, 0, 0, 0, 50, 0.707f, 25, 0.5f, 0};
    float dp[1] = {0};
    n60_stage_desc chain[3] = {stg(N60_STAGE_ROUTE, 1, 0, p, 32, 0x6), stg(N60_STAGE_XOVER, 2, N60_LANE_ALL, xp, 14),
                               stg(N60_STAGE_DELAY, 3, 0, dp, 1)};
    chain[2].capacityFrames = 64;
    CHECK(tryBuild(48000, 4, chain, 3, &g) == N60_STATUS_OK, "route, xover, delay order");
    n60_graph_retire(g);
    n60_stage_desc rev[2] = {chain[1], chain[0]};
    CHECK(tryBuild(48000, 4, rev, 2, &g) == N60_STATUS_BAD_ARGUMENT, "xover before route rejected");
}

// ---- XOVER ---------------------------------------------------------------------------------------------------

struct XCfg {
    float p[14 + 4 * 4];
    uint32_t np = 14;
    XCfg() {
        const float d[14] = {3, 0, 100, 3, 0, 1000, 0, 0, 0, 50, 0.707f, 25, 0.5f, 0};
        std::memcpy(p, d, sizeof d);
    }
    void eq(float type, float hz, float db, float q) {
        float *s = p + np;
        s[0] = type; s[1] = hz; s[2] = db; s[3] = q;
        np += 4;
        p[13] = float((np - 14) / 4);
    }
};

static std::complex<double> cascadeResp(const n60_xover_cascade &c, double fs, double hz) {
    double re = 0, im = 0;
    n60_xover_response(&c, fs, hz, &re, &im);
    return {re, im};
}

// The offline prediction of the whole XOVER chain at hz.
static std::complex<double> predictX(const float *p, double fs, double hz) {
    std::complex<double> h = 1.0;
    n60_xover_cascade c;
    for (int hp = 0; hp < 2; ++hp) {
        const float *f = p + 3 * hp;
        if (f[0] == 3.0f) continue;
        n60_xover_spec s{};
        s.struct_size = sizeof s;
        s.family = uint32_t(f[0]);
        s.order = uint32_t(f[1]);
        s.corner_hz = f[2];
        CHECK(n60_xover_design(&s, hp == 0 ? 1 : 0, fs, &c) == N60_XOVER_OK, "predict design");
        h *= cascadeResp(c, fs, hz);
    }
    if (p[8] != 0.0f) {
        n60_xover_linkwitz(p[9], p[10], p[11], p[12], fs, &c);
        h *= cascadeResp(c, fs, hz);
    }
    for (uint32_t k = 0; k < uint32_t(p[13]); ++k) {
        const float *e = p + 14 + 4 * k;
        double co[5];
        n60::designBiquad(uint32_t(e[0]), fs, e[1], e[2], e[3], co);
        c.count = 1;
        c.sections[0] = {co[0], co[1], co[2], co[3], co[4]};
        h *= cascadeResp(c, fs, hz);
    }
    return h * (std::pow(10.0, p[6] / 20.0) * (p[7] != 0.0f ? -1.0 : 1.0));
}

static std::complex<double> dftAt(const std::vector<float> &h, double fs, double hz) {
    const std::complex<double> w = std::polar(1.0, -2.0 * kPi * hz / fs);
    std::complex<double> ph = 1.0, acc = 0.0;
    for (size_t n = 0; n < h.size(); ++n) {
        acc += double(h[n]) * ph;
        ph *= w;
        if ((n & 1023) == 1023) ph /= std::abs(ph);
    }
    return acc;
}

// Compares a measured impulse response with the prediction at log-spaced frequencies up to 0.45 fs.
static void compareResponse(const std::vector<float> &ir, const float *p, double fs, const char *what) {
    double worstDb = 0, worstRel = 0;
    int used = 0;
    for (double hz = 20.0; hz < 0.45 * fs; hz *= 1.35) {
        const std::complex<double> want = predictX(p, fs, hz), got = dftAt(ir, fs, hz);
        if (std::abs(want) < 3e-3) continue;  // below -50 dB the float quantisation of the capture dominates
        ++used;
        worstDb = std::max(worstDb, std::fabs(20.0 * std::log10(std::abs(got) / std::abs(want))));
        worstRel = std::max(worstRel, std::abs(got - want) / std::abs(want));
    }
    CHECK(used > 8, "%s fs=%g only %d points compared", what, fs, used);
    CHECK(worstDb < 0.002 && worstRel < 5e-4, "%s fs=%g: magnitude %.5f dB, complex error %.2e", what, fs, worstDb, worstRel);
}

static std::vector<float> impulseResponse(n60_graph *g, uint32_t ch, uint32_t lane, double fs, uint32_t lead) {
    const uint32_t frames = lead + uint32_t(0.3 * fs);
    Lanes in = zeros(ch, frames);
    in[lane][lead] = 1.0f;
    const Lanes o = run(g, in, kBlock);
    return std::vector<float>(o[lane].begin() + lead, o[lane].end());
}

static void testXoverResponse(double rate) {
    XCfg a;
    a.p[0] = 2; a.p[1] = 4; a.p[2] = 100; a.p[3] = 0; a.p[4] = 3; a.p[5] = 2000;
    XCfg b;
    b.p[0] = 1; b.p[1] = 4; b.p[2] = 60; b.p[3] = 2; b.p[4] = 8; b.p[5] = 5000; b.p[6] = -6;
    XCfg c;
    c.p[0] = 0; c.p[1] = 2; c.p[2] = 20; c.p[8] = 1;
    XCfg d;
    d.p[7] = 1;
    d.eq(0, 1000, 6, 2);
    d.eq(1, 100, -4, 0.7f);
    XCfg* cfgs[4] = {&a, &b, &c, &d};
    for (int k = 0; k < 4; ++k) {
        n60_stage_desc st[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, cfgs[k]->p, cfgs[k]->np)};
        n60_graph *g = build(rate, 2, st, 1);
        if (g == nullptr) continue;
        CHECK(n60_graph_latency_frames(g) == 0, "xover latency");
        const std::vector<float> ir = impulseResponse(g, 2, 1, rate, 64);
        compareResponse(ir, cfgs[k]->p, rate, k == 0 ? "LR4 HP + BW3 LP" : k == 1 ? "Bessel4 HP + LR8 LP + trim" : k == 2 ? "Linkwitz" : "EQ + polarity");
        n60_graph_retire(g);
    }
}

// A corner edit lands exactly where the offline library puts it once the crossfade is over.
static void testXoverLiveCorner(double rate) {
    XCfg a;
    a.p[0] = 1; a.p[1] = 3; a.p[2] = 100; a.p[3] = 2; a.p[4] = 4; a.p[5] = 3000;
    n60_stage_desc st[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, a.p, a.np)};
    n60_graph *g = build(rate, 2, st, 1);
    if (g == nullptr) return;
    CHECK(post(g, 5, 2, 300.0f) == N60_STATUS_OK, "HP corner edit");
    CHECK(post(g, 5, 5, 4500.0f) == N60_STATUS_OK, "LP corner edit");
    CHECK(post(g, 5, 1, 4.0f) == N60_STATUS_UNSUPPORTED, "order is a rebuild");
    CHECK(post(g, 5, 0, 0.0f) == N60_STATUS_UNSUPPORTED, "family is a rebuild");
    CHECK(post(g, 5, 2, 0.0f) == N60_STATUS_BAD_ARGUMENT, "corner below 1 Hz");
    CHECK(post(g, 5, 5, float(0.5 * rate)) == N60_STATUS_BAD_ARGUMENT, "corner above 0.49 fs");
    const uint32_t lead = 4 * rampOf(rate) + kBlock;
    const uint32_t frames = lead + uint32_t(0.3 * rate);
    Lanes in = zeros(2, frames);
    in[0][lead] = 1.0f;
    const Lanes o = run(g, in, kBlock);
    XCfg want = a;
    want.p[2] = 300;
    want.p[5] = 4500;
    compareResponse(std::vector<float>(o[0].begin() + lead, o[0].end()), want.p, rate, "live corner");
    n60_graph_retire(g);

    // During the edit the output stays continuous: a 1 kHz sine, the corner moving, no sample-to-sample step larger
    // than the steepest slope of either end state.
    XCfg h;
    h.p[0] = 2; h.p[1] = 4; h.p[2] = 100; h.p[3] = 3;
    n60_stage_desc st2[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, h.p, h.np)};
    g = build(rate, 2, st2, 1);
    if (g == nullptr) return;
    Lanes sine = zeros(2, 40 * kBlock);
    for (size_t i = 0; i < sine[0].size(); ++i) sine[0][i] = float(0.5 * std::sin(2.0 * kPi * 1000.0 * double(i) / rate));
    const Lanes so = run(g, sine, kBlock, [&](uint32_t bi) { if (bi == 20) post(g, 5, 2, 1500.0f); });
    double maxStep = 0, ref = 0;
    for (size_t i = 10 * kBlock + 1; i < sine[0].size(); ++i) {
        const double s = std::fabs(double(so[0][i]) - double(so[0][i - 1]));
        maxStep = std::max(maxStep, s);
        if (i < 18 * kBlock) ref = std::max(ref, s);
    }
    const double bound = 0.5 * 2.0 * kPi * 1000.0 / rate * 1.6;
    CHECK(maxStep < bound && ref < bound, "fs=%g corner edit discontinuity: max step %.5f, bound %.5f", rate, maxStep, bound);
    n60_graph_retire(g);
}

static void testXoverTrimPolarity(double rate) {
    XCfg a;  // no filters: trim and polarity only
    a.p[6] = -6.0f;
    n60_stage_desc st[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, a.p, a.np)};
    n60_graph *g = build(rate, 2, st, 1);
    if (g == nullptr) return;
    Lanes in = zeros(2, 8192);
    std::fill(in[0].begin(), in[0].end(), 1.0f);
    std::fill(in[1].begin(), in[1].end(), 1.0f);
    const uint32_t L = rampOf(rate);
    const double g0 = std::pow(10.0, -6.0 / 20.0);
    const Lanes o = run(g, in, kBlock, [&](uint32_t bi) {
        if (bi == 2) CHECK(post(g, 5, 6, 0.0f) == N60_STATUS_OK, "trim post");
        if (bi == 8) CHECK(post(g, 5, 7, 1.0f) == N60_STATUS_OK, "polarity post");
    });
    checkRamp(std::vector<float>(o[0].begin() + 2 * kBlock, o[0].begin() + 8 * kBlock), g0, 1.0, L, "trim", rate);
    // A polarity flip passes through zero.
    const std::vector<float> pol(o[1].begin() + 8 * kBlock, o[1].end());
    checkRamp(pol, 1.0, -1.0, L, "polarity", rate);
    float closest = 1.0f;
    for (uint32_t i = 0; i < L; ++i) closest = std::min(closest, std::fabs(pol[i]));
    CHECK(closest < 2.5f / float(L), "fs=%g polarity flip does not pass near zero (%.4f)", rate, closest);
    n60_graph_retire(g);
}

static void testXoverRejects() {
    n60_graph *g = nullptr;
    XCfg a;
    n60_stage_desc st = stg(N60_STAGE_XOVER, 1, N60_LANE_ALL, a.p, a.np);
    CHECK(tryBuild(48000, 2, &st, 1, &g) == N60_STATUS_OK, "default xover");
    n60_graph_retire(g);
    struct Case { const char *what; int idx; float v; };
    const Case cases[] = {
        {"family 4", 0, 4}, {"LR order 3", 0, 2}, {"order 9", 1, 9}, {"corner 0", 2, 0},
        {"corner above 0.49 fs", 2, 24000}, {"trim -61", 6, -61}, {"trim 25", 6, 25}, {"polarity 2", 7, 2}, {"enable 2", 8, 2},
        {"EQ count 17", 13, 17}, {"EQ count mismatch", 13, 1}, {"off with an order", 4, 2},
    };
    for (const Case &c : cases) {
        XCfg b;
        if (std::strcmp(c.what, "LR order 3") == 0) { b.p[0] = 2; b.p[1] = 3; }
        else if (std::strcmp(c.what, "off with an order") == 0) { b.p[3] = 3; b.p[4] = 2; }
        else if (c.idx == 0 || c.idx == 2) { b.p[c.idx] = c.v; if (c.idx == 2) { b.p[0] = 0; b.p[1] = 2; } else { b.p[1] = 2; } }
        else b.p[c.idx] = c.v;
        n60_stage_desc s = stg(N60_STAGE_XOVER, 1, N60_LANE_ALL, b.p, b.np);
        CHECK(tryBuild(48000, 2, &s, 1, &g) == N60_STATUS_BAD_ARGUMENT, "%s must be rejected", c.what);
    }
    XCfg e;
    e.eq(9, 1000, 0, 1);
    n60_stage_desc s = stg(N60_STAGE_XOVER, 1, N60_LANE_ALL, e.p, e.np);
    CHECK(tryBuild(48000, 2, &s, 1, &g) == N60_STATUS_BAD_ARGUMENT, "EQ type 9");
    XCfg l;
    l.p[8] = 1;
    l.p[11] = 30000;
    s = stg(N60_STAGE_XOVER, 1, N60_LANE_ALL, l.p, l.np);
    CHECK(tryBuild(48000, 2, &s, 1, &g) == N60_STATUS_BAD_ARGUMENT, "Linkwitz pole above 0.49 fs");
    XCfg m;
    s = stg(N60_STAGE_XOVER, 1, 5, m.p, m.np);
    CHECK(tryBuild(48000, 2, &s, 1, &g) == N60_STATUS_BAD_ARGUMENT, "lane past the lane count");
}

// A family change is a rebuild: publish a new description and the new filter takes over after the snapshot fade.
static void testXoverRebuild(double rate) {
    XCfg a;
    a.p[0] = 0; a.p[1] = 2; a.p[2] = 200;
    n60_stage_desc st[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, a.p, a.np)};
    n60_graph *g = build(rate, 2, st, 1);
    if (g == nullptr) return;
    const Lanes warm = noise(2, 2 * kBlock, 3, 0.3f);
    run(g, warm, kBlock);
    XCfg b = a;
    b.p[0] = 2;
    b.p[1] = 4;
    n60_stage_desc st2[1] = {stg(N60_STAGE_XOVER, 5, N60_LANE_ALL, b.p, b.np)};
    const n60_graph_desc d = descOf(rate, 2, st2, 1);
    CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish family change");
    const uint32_t lead = uint32_t(0.5 * rate);
    Lanes in = zeros(2, lead + uint32_t(0.3 * rate));
    in[0][lead] = 1.0f;
    const Lanes o = run(g, in, kBlock);
    compareResponse(std::vector<float>(o[0].begin() + lead, o[0].end()), b.p, rate, "rebuilt family");
    n60_graph_retire(g);
}

// ---- BASS_MGMT filter spec ----------------------------------------------------------------------------------------

static uint64_t bassHash(double rate, int variant) {
    const uint32_t CH = 6, N = 512;
    float one[9] = {80, 2, 2, 4, 120, 1, -1, 0, 0};
    float multi[18] = {80, 2, 2, 4, 120, 1, -1, 0, 1, 0, 50, 3, 1.0f, 1, 3, -2, 1, 0};
    const float *p = variant == 0 ? one : multi;
    n60_stage_desc st = stg(N60_STAGE_BASS_MGMT, 1, 0, p, variant == 0 ? 9 : 18, 0x3);
    n60_graph *g = build(rate, CH, &st, 1);
    if (g == nullptr) return 0;
    static float in[6][512], out[6][512];
    uint32_t seed = 12345u;
    uint64_t h = 1469598103934665603ull, pos = 0;
    for (int b = 0; b < 16; ++b) {
        if (b == 6) { n60_param_record r[2] = {{1, 0, 110.0f, 0}, {1, 1, 0.0f, 0}}; n60_graph_post_params(g, r, 2); }
        if (b == 10) { n60_param_record r[2] = {{1, 6, -6.0f, 0}, {1, 4, 90.0f, 0}}; n60_graph_post_params(g, r, 2); }
        for (uint32_t c = 0; c < CH; ++c) {
            for (uint32_t i = 0; i < N; ++i) {
                seed = seed * 1664525u + 1013904223u;
                const double n = (double(seed >> 8) / 8388608.0 - 1.0) * 0.2;
                const double t = double(pos + i) / rate;
                double v = 0;
                if (c < 2) v = n + 0.3 * std::sin(6.283185307179586 * (40.0 + 30.0 * c) * t) + 0.1 * std::sin(6.283185307179586 * 1500.0 * t);
                if (c == 4) v = 0.5 * n + 0.2 * std::sin(6.283185307179586 * 35.0 * t);
                in[c][i] = float(v);
            }
        }
        pos += N;
        const float *ip[6];
        float *op[6];
        for (uint32_t c = 0; c < CH; ++c) { ip[c] = in[c]; op[c] = out[c]; }
        n60_graph_process(g, ip, op, N);
        for (uint32_t c = 0; c < CH; ++c)
            for (uint32_t i = 0; i < N; ++i) {
                uint32_t u;
                std::memcpy(&u, &out[c][i], 4);
                for (int k = 0; k < 4; ++k) { h ^= (u >> (8 * k)) & 0xff; h *= 1099511628211ull; }
            }
    }
    n60_graph_retire(g);
    return h;
}

// Captured from the ABI v16 build before the filter-spec change: the default (no trailer) arithmetic is unchanged.
static const uint64_t kGolden[2][8] = {
    {0xc4a925243020e7c8ull, 0xb30e078a0e7171b6ull, 0x15734a5bbca86e5eull, 0x60eb22616da797ddull,
     0x51d43ea7a05f505dull, 0xf0e291f851957e38ull, 0x935b0b879aba3f7eull, 0xdad13e2d922410e5ull},
    {0x3395c9007bfa755aull, 0x98aed1fb12857ce0ull, 0x0b486e3c2c8b29bcull, 0x333fec4051695c9cull,
     0xda2b1872918fb701ull, 0xc466961f3523f718ull, 0x0a205a547c2cfb67ull, 0x9a5daf8102331b90ull},
};

static void testBassDefaultUnchanged() {
#if defined(__APPLE__) && defined(__aarch64__)
    for (int v = 0; v < 2; ++v)
        for (int r = 0; r < 8; ++r) {
            const uint64_t h = bassHash(kRates[r], v);
            CHECK(h == kGolden[v][r], "BASS default variant %d fs=%g: hash %016llx (golden %016llx)", v, kRates[r],
                  (unsigned long long)h, (unsigned long long)kGolden[v][r]);
        }
#else
    std::puts("route: BASS golden hashes are libm specific; skipped off Apple arm64");
#endif
}

// BASS_MGMT with a filter spec: mains lane 0 is the high-pass, the sub lane the low-pass of the lane sum.
static void testBassFilterSpec(double rate) {
    const float base[14] = {80, 0, 2, -1, 120, 0, 0, 0, 0, /*w*/ 0, /*spec*/ 0, 3, 0, 3};
    n60_stage_desc st = stg(N60_STAGE_BASS_MGMT, 1, 0, base, 14, 0x3);
    n60_graph *g = build(rate, 3, &st, 1);
    if (g == nullptr) return;
    n60_xover_cascade lp, hp;
    n60_xover_spec s{};
    s.struct_size = sizeof s;
    s.family = 0;
    s.order = 3;
    s.corner_hz = 80;
    n60_xover_design(&s, 0, rate, &lp);
    n60_xover_design(&s, 1, rate, &hp);
    const uint32_t lead = 64, frames = lead + uint32_t(0.3 * rate);
    Lanes in = zeros(3, frames);
    in[0][lead] = 1.0f;
    const Lanes o = run(g, in, kBlock);
    double worstHp = 0, worstLp = 0;
    for (double hz = 20.0; hz < 0.45 * rate; hz *= 1.35) {
        const std::vector<float> m(o[0].begin() + lead, o[0].end()), sub(o[2].begin() + lead, o[2].end());
        const std::complex<double> wh = cascadeResp(hp, rate, hz), wl = cascadeResp(lp, rate, hz);
        if (std::abs(wh) > 3e-3) worstHp = std::max(worstHp, std::abs(dftAt(m, rate, hz) - wh) / std::abs(wh));
        if (std::abs(wl) > 3e-3) worstLp = std::max(worstLp, std::abs(dftAt(sub, rate, hz) - wl) / std::abs(wl));
    }
    CHECK(worstHp < 5e-4 && worstLp < 5e-4, "fs=%g BASS Butterworth-3 split: HP %.2e, LP %.2e", rate, worstHp, worstLp);
    CHECK(post(g, 1, 10, 1.0f) == N60_STATUS_UNSUPPORTED, "trailer family is a rebuild");
    CHECK(post(g, 1, 13, 4.0f) == N60_STATUS_UNSUPPORTED, "trailer order is a rebuild");
    CHECK(post(g, 1, 0, 120.0f) == N60_STATUS_OK, "crossover corner stays live");
    n60_graph_retire(g);

    // After a live corner edit the split sits exactly at the new corner.
    g = build(rate, 3, &st, 1);
    CHECK(post(g, 1, 0, 120.0f) == N60_STATUS_OK, "corner post");
    const uint32_t lead2 = 4 * rampOf(rate) + kBlock, frames2 = lead2 + uint32_t(0.3 * rate);
    Lanes in2 = zeros(3, frames2);
    in2[0][lead2] = 1.0f;
    const Lanes o2 = run(g, in2, kBlock);
    s.corner_hz = 120;
    n60_xover_design(&s, 1, rate, &hp);
    double worst = 0;
    const std::vector<float> m2(o2[0].begin() + lead2, o2[0].end());
    for (double hz = 40.0; hz < 0.45 * rate; hz *= 1.35) {
        const std::complex<double> wh = cascadeResp(hp, rate, hz);
        if (std::abs(wh) > 3e-3) worst = std::max(worst, std::abs(dftAt(m2, rate, hz) - wh) / std::abs(wh));
    }
    CHECK(worst < 5e-4, "fs=%g BASS live corner: HP error %.2e", rate, worst);
    n60_graph_retire(g);

    // Linkwitz-Riley 4 through the library matches the default split to filter precision.
    const float lr[14] = {80, 0, 2, -1, 120, 0, 0, 0, 0, 0, 2, 4, 2, 4};
    const float def[9] = {80, 0, 2, -1, 120, 0, 0, 0, 0};
    n60_stage_desc a = stg(N60_STAGE_BASS_MGMT, 1, 0, lr, 14, 0x3), b = stg(N60_STAGE_BASS_MGMT, 1, 0, def, 9, 0x3);
    n60_graph *ga = build(rate, 3, &a, 1), *gb = build(rate, 3, &b, 1);
    const Lanes x = noise(3, 4096, 11, 0.3f);
    const Lanes oa = run(ga, x, kBlock), ob = run(gb, x, kBlock);
    double diff = 0;
    for (int c = 0; c < 3; ++c)
        for (size_t i = 0; i < x[0].size(); ++i) diff = std::max(diff, std::fabs(double(oa[c][i]) - ob[c][i]));
    CHECK(diff < 2e-5, "fs=%g BASS LR4 spec differs from the default split by %.2e", rate, diff);
    n60_graph_retire(ga);
    n60_graph_retire(gb);
}

static void testBassSpecRejects() {
    n60_graph *g = nullptr;
    auto tryParams = [&](const float *p, uint32_t n) {
        n60_stage_desc st = stg(N60_STAGE_BASS_MGMT, 1, 0, p, n, 0x3);
        const n60_status s = tryBuild(48000, 3, &st, 1, &g);
        if (s == N60_STATUS_OK) n60_graph_retire(g);
        return s;
    };
    const float ok[14] = {80, 0, 2, -1, 120, 0, 0, 0, 0, 0, 1, 4, 2, 6};
    CHECK(tryParams(ok, 14) == N60_STATUS_OK, "Bessel 4 / LR6 spec");
    float bad[14];
    std::memcpy(bad, ok, sizeof bad);
    bad[10] = 3;  // OFF is not allowed
    CHECK(tryParams(bad, 14) == N60_STATUS_BAD_ARGUMENT, "OFF family");
    std::memcpy(bad, ok, sizeof bad);
    bad[13] = 3;  // LR3
    CHECK(tryParams(bad, 14) == N60_STATUS_BAD_ARGUMENT, "LR order 3");
    std::memcpy(bad, ok, sizeof bad);
    bad[11] = 0;
    CHECK(tryParams(bad, 14) == N60_STATUS_BAD_ARGUMENT, "order 0");
    CHECK(tryParams(ok, 13) == N60_STATUS_BAD_ARGUMENT, "a short trailer");
    const float noExt[13] = {80, 0, 2, -1, 120, 0, 0, 0, 0, 1, 4, 1, 4};
    CHECK(tryParams(noExt, 13) == N60_STATUS_BAD_ARGUMENT, "a trailer needs the extension word");
}

// ---- allocation-free render ------------------------------------------------------------------------------------

static void testNoAllocation(double rate) {
    float rp[32];
    entries(rp, {{0, 0.7f}, {1, 0.3f}});
    entries(rp + 16, {{1, 1.0f}});
    XCfg x;
    x.p[0] = 1; x.p[1] = 4; x.p[2] = 90; x.p[3] = 2; x.p[4] = 4; x.p[5] = 2500; x.p[8] = 1;
    x.eq(0, 800, 3, 1.5f);
    const float bp[14] = {80, 0, 2, -1, 120, 0, 0, 0, 0, 0, 1, 4, 2, 4};
    n60_stage_desc st[3] = {stg(N60_STAGE_BASS_MGMT, 1, 0, bp, 14, 0x3), stg(N60_STAGE_ROUTE, 2, 0, rp, 32, 0x6),
                            stg(N60_STAGE_XOVER, 3, N60_LANE_ALL, x.p, x.np)};
    n60_graph *g = build(rate, 4, st, 3);
    if (g == nullptr) return;
    const Lanes in = noise(4, 40 * kBlock, 5, 0.3f);
    allocs = 0;
    run(g, in, kBlock, [&](uint32_t bi) {
        if (bi % 7 == 1) post(g, 3, 2, 90.0f + float(bi));
        if (bi % 7 == 3) post(g, 3, 5, 2500.0f + float(10 * bi));
        if (bi % 11 == 2) post(g, 3, 14 + 2, float(bi % 5) - 2.0f);
        if (bi % 9 == 4) post(g, 2, 1, 0.1f * float(bi % 4));
        if (bi % 13 == 5) post(g, 1, 0, 70.0f + float(bi));
    }, true);
    CHECK(allocs.load() == 0, "fs=%g: %ld heap allocations while rendering", rate, allocs.load());
    n60_graph_retire(g);
}

int main() {
    CHECK(N60_GRAPH_ABI_VERSION == 17u && n60_graph_abi_version() == 17u, "ABI version");
    testRouteRejects();
    testXoverRejects();
    testBassSpecRejects();
    testBassDefaultUnchanged();
    for (double fs : kRates) {
        testRouteMatrix(fs);
        testRouteGainRamp(fs);
        testXoverResponse(fs);
        testXoverLiveCorner(fs);
        testXoverTrimPolarity(fs);
        testXoverRebuild(fs);
        testBassFilterSpec(fs);
        testNoAllocation(fs);
    }
    if (failures) { std::fprintf(stderr, "%d failures\n", failures); return 1; }
    std::puts("route: all checks passed");
    return 0;
}
