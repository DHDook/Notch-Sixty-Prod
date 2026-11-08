// E6 S12f2: state carry across a snapshot swap (G7, G11), non-finite reset in the image stages (G14), and the precision
// of the float cleanup high-pass against a double reference at the corner (G9, G13), at the eight standard rates.
//  - Carry: a graph with CLEANUP, IMAGE and DEESS running is swapped for an identical snapshot (fade 0). The output must
//    equal an unswapped reference graph's (the state carried), and differ from a cold-started graph's (the signal does
//    exercise the state).
//  - Non-finite: a NaN and an Inf sample into IMAGE and DEESS leave the following output finite.
//  - Precision: the infrasonic cascade at 10 Hz against a double-precision run of the same design.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f\n", what, rate); ++failures; }
}

struct Cfg {
    float clean[26];
    float img[8] = {0, 1, 0, 200, 4000, 1, 1.5f, 1.4f};
    float de[12] = {1, 3500, -3, 1, 6500, -40, 4, -24, 2, 1, 50, 1};
    bool cleanup = true, image = true, deess = true;
    Cfg() {
        std::memset(clean, 0, sizeof clean);
        clean[0] = 1; clean[1] = 1; clean[2] = 20; clean[3] = 1; clean[4] = 1; clean[5] = 50; clean[6] = 3; clean[7] = 20;
        clean[8] = 1; clean[9] = 50;
        for (int i = 10; i < 26; ++i) clean[i] = -30;
    }
};

n60_graph_desc makeDesc(double rate, const Cfg &c, n60_stage_desc *st) {
    uint32_t n = 0;
    std::memset(st, 0, 3 * sizeof *st);
    auto add = [&](uint32_t kind, uint32_t id, const float *p, uint32_t count) {
        st[n].structSize = sizeof st[n];
        st[n].kind = kind;
        st[n].stageId = id;
        st[n].laneA = 0;
        st[n].laneB = 1;
        st[n].params = p;
        st[n].paramCount = count;
        ++n;
    };
    if (c.cleanup) add(N60_STAGE_CLEANUP, 7, c.clean, 26);
    if (c.image) add(N60_STAGE_IMAGE, 8, c.img, 8);
    if (c.deess) add(N60_STAGE_DEESS, 9, c.de, 12);
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = n;
    return d;
}

n60_graph *build(double rate, const Cfg &c) {
    n60_stage_desc st[3];
    n60_graph_desc d = makeDesc(rate, c, st);
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return nullptr;
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
    unsigned seed = 99u + (unsigned)from;
    for (size_t i = 0; i < n; ++i) {
        const double t = double(from + i) / rate;
        seed = seed * 1664525u + 1013904223u;
        const double noise = 0.02 * (double((seed >> 8) & 0xFFFF) / 65536.0 - 0.5);
        const double base = 0.03 + 0.2 * std::sin(2 * M_PI * 50.0 * t) + 0.2 * std::sin(2 * M_PI * 440.0 * t) + noise;
        const double ess = (std::fmod(t, 0.2) < 0.1) ? 0.3 * std::sin(2 * M_PI * 6500.0 * t) : 0.0;
        l[i] = float(base + ess);
        r[i] = float(0.6 * base - 0.5 * ess + 0.1 * std::sin(2 * M_PI * 2200.0 * t));
    }
}

void process(n60_graph *g, const std::vector<float> &l, const std::vector<float> &r, std::vector<float> &ol,
             std::vector<float> &orr) {
    ol.resize(l.size());
    orr.resize(r.size());
    for (size_t off = 0; off < l.size(); off += 512) {
        const uint32_t n = (uint32_t)std::fmin(512.0, double(l.size() - off));
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
}

double maxDiff(const std::vector<float> &a, const std::vector<float> &b) {
    double m = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) m = std::fmax(m, std::fabs(double(a[i]) - double(b[i])));
    return m;
}

void carryTest(double rate) {
    const size_t pre = (size_t)(rate * 0.45) / 512 * 512;
    const size_t post = (size_t)(rate * 0.06) / 512 * 512 + 512;
    std::vector<float> l1, r1, l2, r2, a1, b1, a2, b2, ref1, refr1, ref2, refr2;
    signal(rate, 0, pre, l1, r1);
    signal(rate, pre, post, l2, r2);
    Cfg c;
    n60_graph *swap = build(rate, c), *ref = build(rate, c);
    check(swap && ref, "build", rate);
    if (!swap || !ref) return;
    process(swap, l1, r1, a1, b1);
    process(ref, l1, r1, ref1, refr1);
    n60_stage_desc st[3];
    n60_graph_desc d = makeDesc(rate, c, st);
    check(n60_graph_publish(swap, &d) == N60_STATUS_OK, "publish", rate);
    process(swap, l2, r2, a2, b2);
    process(ref, l2, r2, ref2, refr2);
    const double carried = std::fmax(maxDiff(a2, ref2), maxDiff(b2, refr2));
    n60_graph *cold = build(rate, c);
    std::vector<float> ca, cb;
    process(cold, l2, r2, ca, cb);
    const double coldDiff = std::fmax(maxDiff(ca, ref2), maxDiff(cb, refr2));
    std::printf("rate %.0f: carried deviation %.3g, cold deviation %.3g\n", rate, carried, coldDiff);
    check(carried < 1e-6, "swap with carried state matches the unswapped graph", rate);
    check(coldDiff > 1e-3, "the signal exercises the carried state", rate);
    n60_graph_retire(swap);
    n60_graph_retire(ref);
    n60_graph_retire(cold);
}

void nonFiniteTest(double rate) {
    Cfg c;
    n60_graph *g = build(rate, c);
    check(g != nullptr, "build image", rate);
    if (!g) return;
    std::vector<float> l, r, ol, orr;
    signal(rate, 0, 4096, l, r);
    l[1000] = NAN;
    r[1500] = INFINITY;
    process(g, l, r, ol, orr);
    bool finite = true;
    for (size_t i = 2048; i < ol.size(); ++i) finite = finite && std::isfinite(ol[i]) && std::isfinite(orr[i]);
    check(finite, "cleanup, image and de-ess recover from non-finite input", rate);
    n60_graph_retire(g);
}

// Double-precision reference of the infrasonic cascade (Butterworth sections, RBJ high-pass, DF2T) against the stage.
void precisionTest(double rate, uint32_t slope) {
    const double hz = 10.0;
    const uint32_t sections = slope == 0 ? 2 : (slope == 1 ? 4 : 8);
    Cfg c;
    c.image = c.deess = false;
    std::memset(c.clean, 0, sizeof c.clean);
    c.clean[1] = 1; c.clean[2] = (float)hz; c.clean[3] = (float)slope; c.clean[5] = 50; c.clean[6] = 3; c.clean[7] = 20; c.clean[9] = 50;
    for (int i = 10; i < 26; ++i) c.clean[i] = -30;
    n60_graph *g = build(rate, c);
    check(g != nullptr, "build precision", rate);
    if (!g) return;
    const size_t n = (size_t)(rate * 3.0) / 512 * 512;
    std::vector<float> l(n), r(n), ol, orr;
    for (size_t i = 0; i < n; ++i) l[i] = r[i] = (float)(0.5 * std::sin(2 * M_PI * hz * double(i) / rate));
    process(g, l, r, ol, orr);
    double z1[8] = {0}, z2[8] = {0}, b0[8], b1[8], b2[8], a1[8], a2[8];
    for (uint32_t s = 0; s < sections; ++s) {
        const double order = sections * 2.0;
        const double angle = ((2.0 * s + 1.0) * M_PI) / (2.0 * order);
        const double q = 1.0 / (2.0 * std::cos(angle));
        const double w = 2.0 * M_PI * hz / rate, cw = std::cos(w), alpha = std::sin(w) / (2.0 * q), a0 = 1.0 + alpha;
        b0[s] = (1 + cw) * 0.5 / a0; b1[s] = -(1 + cw) / a0; b2[s] = b0[s]; a1[s] = -2 * cw / a0; a2[s] = (1 - alpha) / a0;
    }
    double worst = 0, peak = 0;
    for (size_t i = 0; i < n; ++i) {
        double v = double(l[i]);
        for (uint32_t s = 0; s < sections; ++s) {
            const double out = b0[s] * v + z1[s];
            z1[s] = b1[s] * v - a1[s] * out + z2[s];
            z2[s] = b2[s] * v - a2[s] * out;
            v = out;
        }
        if (i > n / 2) {
            worst = std::fmax(worst, std::fabs(v - double(ol[i])));
            peak = std::fmax(peak, std::fabs(v));
        }
    }
    const double relDb = 20.0 * std::log10(std::fmax(worst, 1e-30) / std::fmax(peak, 1e-30));
    std::printf("rate %.0f slope %u: float cascade vs double reference at 10 Hz: worst %.3g of peak %.3g (%.1f dB)\n", rate, slope,
                worst, peak, relDb);
    check(relDb < -40.0, "infrasonic corner within 40 dB-down of a double reference", rate);
    n60_graph_retire(g);
}

void above384(double rate) {
    Cfg c;
    n60_graph *g = build(rate, c);
    check(g != nullptr, "build above 384 kHz", rate);
    if (!g) return;
    std::vector<float> l, r, ol, orr;
    signal(rate, 0, 8192, l, r);
    process(g, l, r, ol, orr);
    bool finite = true;
    for (size_t i = 0; i < ol.size(); ++i) finite = finite && std::isfinite(ol[i]) && std::isfinite(orr[i]);
    check(finite, "finite output at 768 kHz", rate);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        carryTest(rate);
        nonFiniteTest(rate);
        for (uint32_t slope = 0; slope < 3; ++slope) precisionTest(rate, slope);
    }
    above384(768000.0);
    if (failures) return 1;
    std::puts("n60core state carry: OK");
    return 0;
}
