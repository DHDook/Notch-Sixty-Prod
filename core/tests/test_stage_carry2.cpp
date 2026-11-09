// E6 S12h part 1: loudness and multiband running state carried across a snapshot swap (G16, G21), the carry copies
// charged to the callback's bulk-copy budget (G38), and the deferred-swap path (a large program FIR whose lazy carry
// makes the swap wait, G38 staleness), at the eight standard rates.
//  - A graph with LOUDNESS (match, per-band contour, leveler) and MULTIBAND running is swapped for an identical snapshot
//    (fade 0). The output must equal an unswapped reference graph's, and differ from a cold-started graph's.
//  - The swap callback's bulk bytes include the carry copies and stay within the allowance.
//  - With a 65536-tap program FIR in the graph the swap is deferred (the FIR copies over several callbacks); CLEANUP, IMAGE,
//    DEESS, LOUDNESS and MULTIBAND still match the unswapped reference through and after the deferred swap.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "graph_debug.hpp"
#include "n60/graph.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f\n", what, rate); ++failures; }
}

constexpr uint32_t kBlock = 512;

struct Params {
    float clean[26];
    float img[8] = {0, 1, 0, 200, 4000, 1, 1.5f, 1.4f};
    float de[12] = {1, 3500, -3, 1, 6500, -40, 4, -24, 2, 1, 50, 1};
    // match on, contour on per band (integrated source off), leveler on
    float loud[32] = {1, 0, -16, 10, 0.5f, 2, 1, 0.6f, 1, 0, 80, 12, 3, 1,
                      1, 0, 300, 3500, 6, 3, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f};
    float mb[29] = {1, 120, 2500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    std::vector<float> fir;
    Params() {
        std::memset(clean, 0, sizeof clean);
        clean[0] = 1; clean[1] = 1; clean[2] = 20; clean[3] = 1; clean[4] = 1; clean[5] = 50; clean[6] = 3; clean[7] = 20;
        clean[8] = 1; clean[9] = 50;
        for (int i = 10; i < 26; ++i) clean[i] = -30;
    }
};

struct Built {
    n60_stage_desc st[8];
    n60_graph_desc d;
};

void describe(double rate, const Params &c, bool withFir, Built &b) {
    std::memset(&b, 0, sizeof b);
    uint32_t n = 0;
    auto add = [&](uint32_t kind, uint32_t id, const float *p, uint32_t count, uint32_t laneA) {
        b.st[n].structSize = sizeof b.st[n];
        b.st[n].kind = kind;
        b.st[n].stageId = id;
        b.st[n].laneA = laneA;
        b.st[n].laneB = laneA == N60_LANE_ALL ? 0 : 1;
        b.st[n].params = p;
        b.st[n].paramCount = count;
        ++n;
    };
    add(N60_STAGE_CLEANUP, 7, c.clean, 26, 0);
    if (withFir) add(N60_STAGE_FIR, 12, c.fir.data(), (uint32_t)c.fir.size(), N60_LANE_ALL);
    add(N60_STAGE_IMAGE, 8, c.img, 8, 0);
    add(N60_STAGE_LOUDNESS, 10, c.loud, 32, 0);
    add(N60_STAGE_DEESS, 9, c.de, 12, 0);
    add(N60_STAGE_MULTIBAND, 11, c.mb, 29, 0);
    b.d.structSize = sizeof b.d;
    b.d.abiVersion = N60_GRAPH_ABI_VERSION;
    b.d.sampleRate = rate;
    b.d.maxBlockFrames = kBlock;
    b.d.inputChannels = b.d.outputChannels = 2;
    b.d.stages = b.st;
    b.d.stageCount = n;
    b.d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
}

n60_graph *build(double rate, const Params &c, bool withFir) {
    Built b;
    describe(rate, c, withFir, b);
    n60_graph *g = nullptr;
    const n60_status s = n60_graph_build(&b.d, &g);
    if (s != N60_STATUS_OK) { std::fprintf(stderr, "build status %d\n", (int)s); return nullptr; }
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    n60_graph_set_rebuild_options(g, &o);
    return g;
}

void signal(double rate, size_t from, size_t n, std::vector<float> &l, std::vector<float> &r) {
    l.resize(n);
    r.resize(n);
    unsigned seed = 7u + (unsigned)from;
    for (size_t i = 0; i < n; ++i) {
        const double t = double(from + i) / rate;
        seed = seed * 1664525u + 1013904223u;
        const double noise = 0.03 * (double((seed >> 8) & 0xFFFF) / 65536.0 - 0.5);
        const double env = 0.5 + 0.5 * std::sin(2 * M_PI * 1.3 * t);
        const double base = 0.1 * env * (std::sin(2 * M_PI * 80.0 * t) + std::sin(2 * M_PI * 440.0 * t) +
                                         0.7 * std::sin(2 * M_PI * 3100.0 * t)) + noise + 0.02;
        const double ess = (std::fmod(t, 0.2) < 0.1) ? 0.2 * std::sin(2 * M_PI * 6500.0 * t) : 0.0;
        l[i] = float(base + ess);
        r[i] = float(0.7 * base - 0.4 * ess + 0.05 * std::sin(2 * M_PI * 2200.0 * t));
    }
}

void process(n60_graph *g, const std::vector<float> &l, const std::vector<float> &r, std::vector<float> &ol,
             std::vector<float> &orr) {
    ol.resize(l.size());
    orr.resize(r.size());
    for (size_t off = 0; off < l.size(); off += kBlock) {
        const uint32_t n = (uint32_t)std::fmin(double(kBlock), double(l.size() - off));
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
}

double maxDiff(const std::vector<float> &a, const std::vector<float> &b, size_t from = 0) {
    double m = 0;
    for (size_t i = from; i < a.size() && i < b.size(); ++i) m = std::fmax(m, std::fabs(double(a[i]) - double(b[i])));
    return m;
}

void carryTest(double rate, bool withFir) {
    Params c;
    if (withFir) {
        c.fir.assign(65536, 0.0f);
        c.fir[0] = 0.8f;
        c.fir[200] = 0.1f;
        c.fir[40000] = 0.05f;
    }
    const size_t pre = (size_t)(rate * 0.8) / kBlock * kBlock;
    const size_t post = (size_t)(rate * 0.4) / kBlock * kBlock + kBlock;
    std::vector<float> l1, r1, l2, r2, a1, b1, a2, b2, ref1, refr1, ref2, refr2;
    signal(rate, 0, pre, l1, r1);
    signal(rate, pre, post, l2, r2);
    n60_graph *swap = build(rate, c, withFir), *ref = build(rate, c, withFir);
    check(swap && ref, "build", rate);
    if (!swap || !ref) return;
    process(swap, l1, r1, a1, b1);
    process(ref, l1, r1, ref1, refr1);
    const uint64_t peakBefore = n60_graph_debug_peak_rt_bytes(swap);
    Built b;
    describe(rate, c, withFir, b);
    check(n60_graph_publish(swap, &b.d) == N60_STATUS_OK, "publish", rate);
    process(swap, l2, r2, a2, b2);
    process(ref, l2, r2, ref2, refr2);
    const double carried = std::fmax(maxDiff(a2, ref2), maxDiff(b2, refr2));
    const uint64_t peakAfter = n60_graph_debug_peak_rt_bytes(swap);
    const uint64_t allowance = n60_graph_debug_rt_budget(kBlock);
    std::printf("rate %.0f fir %d: carried deviation %.3g, peak bytes %llu -> %llu of %llu\n", rate, withFir ? 1 : 0, carried,
                (unsigned long long)peakBefore, (unsigned long long)peakAfter, (unsigned long long)allowance);
    check(carried < 1e-6, "swap with carried state matches the unswapped graph", rate);
    // G38: the small carries are charged to the allowance, so the swap callback shows their bytes and never exceeds it.
    check(peakAfter > peakBefore, "the swap callback charges the carry copies to the budget", rate);
    check(peakAfter <= allowance, "the swap callback stays within the allowance", rate);
    if (!withFir) {
        n60_graph *cold = build(rate, c, false);
        std::vector<float> ca, cb;
        process(cold, l2, r2, ca, cb);
        const double coldDiff = std::fmax(maxDiff(ca, ref2), maxDiff(cb, refr2));
        check(coldDiff > 1e-4, "the signal exercises the carried state", rate);
        n60_graph_retire(cold);
    }
    n60_graph_retire(swap);
    n60_graph_retire(ref);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        carryTest(rate, false);
        carryTest(rate, true);
    }
    if (failures) return 1;
    std::puts("n60core stage carry (S12h): OK");
    return 0;
}
