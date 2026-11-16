// E33 S5b: the multiband stage with 2 to 5 bands (ABI v42, 73-value block), at the eight standard rates. The bands of every
// count sum flat within 0.1 dB, three bands through the new block are bit-identical to the 44-value block, the older 29, 43 and
// 44-value blocks render bit-identically to the three-band code before this slice (golden hashes), the split ordering rules and
// the widened limits validate, each band reduces only its own range, a five-band reference-lab case (tones in every band,
// loudness and flatness), the lookahead latency, a band-count rebuild, and zero allocation across live corner edits.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "mb_golden.inc"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate, double a = 0, double b = 0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f (%g, %g)\n", what, rate, a, b); ++failures; }
}
using Vec = std::vector<float>;
constexpr double kTwoPi = 6.283185307179586;

// A 73-value block. Per band (0..4) kinds: thr 0, ratio 1, atk 2, rel 3, knee 4, sc 5, mk 6, auto 7, byp 8, solo 9, listen 10, det 11.
struct Nb {
    float p[73];
    Nb(uint32_t n = 3) {
        std::memset(p, 0, sizeof p);
        p[0] = 1;
        p[44] = (float)n;
        const float defaults[5][4] = {{200, 0, 0, 0}, {120, 3500, 0, 0}, {120, 1000, 5000, 0}, {80, 400, 2000, 8000}, {0, 0, 0, 0}};
        const float *c = defaults[n == 2 ? 0 : n == 3 ? 1 : n == 4 ? 2 : 3];
        p[1] = c[0];
        p[2] = n == 2 ? 3500 : c[1];
        p[45] = n >= 4 ? c[2] : 8000;
        p[46] = n >= 5 ? c[3] : 12000;
        p[41] = 50;
        for (uint32_t b = 0; b < 5; ++b) {
            set(0, b, -30); set(1, b, 4); set(2, b, 5); set(3, b, 100);
        }
        p[43] = 1;
    }
    static uint32_t at(uint32_t kind, uint32_t band) { return band < 3 ? 5 + 3 * kind + band : 49 + 2 * kind + (band - 3); }
    void set(uint32_t kind, uint32_t band, float v) { p[at(kind, band)] = v; }
    void unity() {  // every band passes at unity: ratio 1, no make-up
        for (uint32_t b = 0; b < 5; ++b) { set(1, b, 1); set(0, b, 0); }
    }
};

n60_graph *build(double rate, const float *params, uint32_t count, n60_status *st = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_MULTIBAND;
    s.stageId = 5;
    s.laneA = 0;
    s.laneB = 1;
    s.params = params;
    s.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    const n60_status r = n60_graph_build(&d, &g);
    if (st) *st = r;
    return r == N60_STATUS_OK ? g : nullptr;
}

void run(n60_graph *g, Vec &l, Vec &r, uint32_t block = 512) {
    for (size_t off = 0; off < l.size(); off += block) {
        const uint32_t n = (uint32_t)std::min<size_t>(block, l.size() - off);
        float *lanes[2] = {l.data() + off, r.data() + off};
        const float *ip[2] = {lanes[0], lanes[1]};
        std::vector<float> a(n), b(n);
        std::memcpy(a.data(), lanes[0], n * 4);
        std::memcpy(b.data(), lanes[1], n * 4);
        const float *in[2] = {a.data(), b.data()};
        (void)ip;
        n60_graph_process(g, in, lanes, n);
    }
}
Vec sine(double rate, double hz, double amp, size_t n) {
    Vec v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(kTwoPi * hz * (double)i / rate));
    return v;
}
double rmsTail(const Vec &v, size_t from) {
    double s = 0;
    for (size_t i = from; i < v.size(); ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(v.size() - from));
}
double db(double x) { return 20.0 * std::log10(x); }
n60_multiband_readback rb(n60_graph *g) {
    n60_multiband_readback r;
    std::memset(&r, 0, sizeof r);
    r.structSize = sizeof r;
    n60_graph_read_multiband(g, 5, &r);
    return r;
}

// Golden hashes of the legacy blocks, captured from the three-band code before this slice: {scenario, rate, hash}.
struct Gold { int which; double rate; unsigned long long hash; };
const Gold kGold[] = {
    {0, 48000, 0x56c8aa0a47ca94f5ull}, {1, 48000, 0xe0c644aed6e498c9ull}, {2, 48000, 0x57721e6ddb419ba8ull},
    {3, 48000, 0xf7ea5fea898a1fd7ull}, {4, 48000, 0x222245a7cea40099ull}, {0, 384000, 0xb6e98ce43fb16dbcull},
    {1, 384000, 0x4111d8b5027f2ce5ull}, {2, 384000, 0x5ed99b58c1736c00ull}, {3, 384000, 0xa3417c32aee5680bull},
    {4, 384000, 0x8d3231cbb8b57aa1ull},
};

void testRate(double rate) {
    const size_t n = (size_t)(rate * 1.0), tail = n / 2;
    // Flat sum for every band count and both slopes: tones across the spectrum come out within 0.1 dB.
    for (uint32_t count = 2; count <= 5; ++count) {
        for (int lr8 = 0; lr8 < 2; ++lr8) {
            Nb m(count);
            m.unity();
            m.p[3] = m.p[4] = m.p[47] = m.p[48] = (float)lr8;
            n60_graph *g = build(rate, m.p, 73);
            check(g != nullptr, "build N bands", rate, count);
            if (!g) continue;
            double worst = 0;
            for (double hz : {30.0, 60.0, 100.0, 250.0, 700.0, 1500.0, 3000.0, 6000.0, 12000.0}) {
                if (hz > rate * 0.4) continue;
                Vec l = sine(rate, hz, 0.4, n), r = l;
                run(g, l, r);
                worst = std::max(worst, std::fabs(db(rmsTail(l, tail) / (0.4 * 0.7071067811865476))));
            }
            check(worst < 0.1, "bands sum flat within 0.1 dB", rate, count, worst);
            n60_graph_retire(g);
        }
    }
    // Three bands through the new block equal the 44-value block exactly (tree and residual), with a lookahead and a live corner edit.
    for (int tree = 0; tree < 2; ++tree) {
        Nb m(3);
        m.set(0, 1, -40); m.set(4, 0, 6); m.set(11, 2, 1); m.p[42] = 32; m.p[43] = (float)tree;
        float old44[44];
        std::memcpy(old44, m.p, sizeof old44);
        Vec lo[2], ro[2];
        for (int which = 0; which < 2; ++which) {
            n60_graph *g = which == 0 ? build(rate, old44, 44) : build(rate, m.p, 73);
            check(g != nullptr, "build legacy and wide", rate);
            Vec l, r;
            golden::signal(rate, (size_t)(rate * 0.3), l, r);
            n60_param_record rec[1] = {{5, 1, 150.0f, 0}};
            run(g, l, r, 512);
            n60_graph_post_params(g, rec, 1);
            Vec l2, r2;
            golden::signal(rate, (size_t)(rate * 0.1), l2, r2);
            run(g, l2, r2, 512);
            l.insert(l.end(), l2.begin(), l2.end());
            r.insert(r.end(), r2.begin(), r2.end());
            lo[which] = l; ro[which] = r;
            n60_graph_retire(g);
        }
        check(lo[0].size() == lo[1].size() && std::memcmp(lo[0].data(), lo[1].data(), lo[0].size() * 4) == 0
                  && std::memcmp(ro[0].data(), ro[1].data(), ro[0].size() * 4) == 0, "three bands through the 73-value block are bit-identical", rate, tree);
    }
    // Each band reduces its own tone only (five bands, corners 80, 400, 2000, 8000).
    {
        const double hz[5] = {40, 180, 900, 4000, 12000};
        for (int band = 0; band < 5; ++band) {
            if (hz[band] > rate * 0.4) continue;
            Nb m(5);
            for (uint32_t b = 0; b < 5; ++b) { m.set(0, b, -30); m.set(1, b, 8); m.set(2, b, 2); m.set(3, b, 60); }
            n60_graph *g = build(rate, m.p, 73);
            Vec l = sine(rate, hz[band], 0.5, n), r = l;
            run(g, l, r);
            const n60_multiband_readback x = rb(g);
            check(x.bandCount == 5, "readback band count", rate, x.bandCount);
            check(x.grNowDb[band] > 8.0f, "tone band reduced", rate, band, x.grNowDb[band]);
            for (int o = 0; o < 5; ++o) {
                // A tone near a corner leaks into its neighbour by the crossover slope; far bands see nothing.
                if (o != band) check(x.grNowDb[o] < 0.6f * x.grNowDb[band] && (std::abs(o - band) < 2 || x.grNowDb[o] < 0.5f), "other bands reduce far less", rate, band * 10 + o, x.grNowDb[o]);
            }
            n60_graph_retire(g);
        }
    }
    // Latency: the lookahead frames, with five bands.
    {
        Nb m(5);
        m.p[42] = 96;
        n60_graph *g = build(rate, m.p, 73);
        check(g != nullptr && n60_graph_latency_frames(g) == 96, "lookahead latency with five bands", rate);
        if (g) n60_graph_retire(g);
    }
    // A five-band lookahead stage at unity stays flat (the delayed bands stay aligned).
    {
        Nb m(5);
        m.unity();
        m.p[42] = 64;
        n60_graph *g = build(rate, m.p, 73);
        double worst = 0;
        for (double hz : {50.0, 300.0, 1000.0, 5000.0}) {
            Vec l = sine(rate, hz, 0.4, n), r = l;
            run(g, l, r);
            worst = std::max(worst, std::fabs(db(rmsTail(l, tail) / (0.4 * 0.7071067811865476))));
        }
        check(worst < 0.1, "five bands with lookahead sum flat", rate, worst);
        n60_graph_retire(g);
    }
    // Zero allocation: five bands, lookahead, listen, solo and live corner edits.
    {
        Nb m(5);
        m.p[42] = 48;
        m.set(10, 3, 1);
        n60_graph *g = build(rate, m.p, 73);
        Vec l = sine(rate, 500, 0.3, 4096), r = l;
        run(g, l, r);
        Vec a = sine(rate, 1000, 0.3, 512), b = a, oa(512), ob(512);
        armed = true;
        allocs = 0;
        for (int i = 0; i < 8; ++i) {
            // Corners stay ascending: 100, 800 + 50 i, 4000 + 100 i, 12000 (corner 3 untouched).
            n60_param_record rec[4] = {{5, 1, 100.0f, 0}, {5, 2, 800.0f + 50 * i, 0}, {5, 45, 4000.0f + 100 * i, 0}, {5, 67, (float)(i & 1), 0}};
            n60_graph_post_params(g, rec, 4);
            const float *in[2] = {a.data(), b.data()};
            float *out[2] = {oa.data(), ob.data()};
            n60_graph_process(g, in, out, 512);
        }
        armed = false;
        check(allocs.load() == 0, "zero allocation across live corner edits", rate, (double)allocs.load());
        n60_graph_retire(g);
    }
}

void testGolden() {
    for (const Gold &g : kGold) {
        check(golden::scenario(g.which, g.rate) == g.hash, "legacy block hash", g.rate, g.which);
    }
}

void testValidation() {
    const double rate = 48000;
    n60_status st;
    auto ok = [&](const Nb &m, uint32_t count = 73) { n60_graph *g = build(rate, m.p, count, &st); if (g) n60_graph_retire(g); return st; };
    { Nb m(5); check(ok(m) == N60_STATUS_OK, "five bands build", rate); }
    { Nb m(2); check(ok(m) == N60_STATUS_OK, "two bands build", rate); }
    { Nb m(3); m.p[44] = 6; check(ok(m) != N60_STATUS_OK, "six bands rejected", rate); }
    { Nb m(3); m.p[44] = 1; check(ok(m) != N60_STATUS_OK, "one band rejected", rate); }
    { Nb m(3); m.p[1] = 1000; m.p[2] = 1200; check(ok(m) != N60_STATUS_OK, "corners under half an octave apart rejected", rate); }
    { Nb m(3); m.p[1] = 1000; m.p[2] = 900; check(ok(m) != N60_STATUS_OK, "descending corners rejected", rate); }
    { Nb m(3); m.p[1] = 1000; m.p[2] = 1415; check(ok(m) == N60_STATUS_OK, "corners half an octave apart accepted", rate); }
    { Nb m(5); m.p[45] = m.p[2]; check(ok(m) != N60_STATUS_OK, "equal corners rejected", rate); }
    { Nb m(2); m.p[2] = 50; check(ok(m) == N60_STATUS_OK, "unused corners are not ordered", rate); }
    { Nb m(5); m.p[46] = 16001; check(ok(m) != N60_STATUS_OK, "corner above 16 kHz rejected", rate); }
    { Nb m(5); m.p[1] = 39; check(ok(m) != N60_STATUS_OK, "corner below 40 Hz rejected", rate); }
    // Widened limits (the wideband compressor's), in the 73 and the 44-value blocks.
    {
        Nb m(5);
        for (uint32_t b = 0; b < 5; ++b) { m.set(0, b, -96); m.set(1, b, 100); m.set(2, b, 0.05f); m.set(3, b, 5000); m.set(4, b, 24); m.set(6, b, 24); m.set(5, b, 300); }
        check(ok(m) == N60_STATUS_OK, "widened limits accepted (73)", rate);
        Nb o(3);
        for (uint32_t b = 0; b < 3; ++b) { o.set(0, b, -96); o.set(1, b, 100); o.set(2, b, 0.05f); o.set(3, b, 5000); o.set(4, b, 24); o.set(6, b, -24); }
        check(ok(o, 44) == N60_STATUS_OK, "widened limits accepted (44)", rate);
        o.set(1, 0, 101);
        check(ok(o, 44) != N60_STATUS_OK, "ratio above 100 rejected", rate);
    }
    // Block sizes: 29, 43, 44 and 73 build; others do not.
    { Nb m(3); check(ok(m, 29) == N60_STATUS_OK && ok(m, 43) == N60_STATUS_OK && ok(m, 44) == N60_STATUS_OK, "legacy sizes build", rate); }
    { Nb m(3); check(ok(m, 45) != N60_STATUS_OK && ok(m, 72) != N60_STATUS_OK, "other sizes rejected", rate); }
    // Live edits: corners range-checked live, the band count and slopes are topology.
    {
        Nb m(5);
        n60_graph *g = build(rate, m.p, 73);
        n60_param_record rec = {5, 44, 4.0f, 0};
        check(n60_graph_post_params(g, &rec, 1) != N60_STATUS_OK, "band count is not live", rate);
        rec = {5, 47, 1.0f, 0};
        check(n60_graph_post_params(g, &rec, 1) != N60_STATUS_OK, "slope 2 is not live", rate);
        rec = {5, 46, 9000.0f, 0};
        check(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "corner 3 is live", rate);
        rec = {5, 46, 20000.0f, 0};
        check(n60_graph_post_params(g, &rec, 1) != N60_STATUS_OK, "corner out of range rejected live", rate);
        n60_graph_retire(g);
    }
}

// A band-count change is a rebuild: publish a four-band description over a running five-band graph; no crash, finite output,
// and the stage keeps running (it is the normal fade, nothing is carried between different counts).
void testCountChange(double rate) {
    Nb a(5), b(4);
    n60_graph *g = build(rate, a.p, 73);
    Vec l = sine(rate, 300, 0.4, 4096), r = l;
    run(g, l, r);
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_MULTIBAND;
    s.stageId = 5;
    s.laneA = 0;
    s.laneB = 1;
    s.params = b.p;
    s.paramCount = 73;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    check(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish a different band count", rate);
    Vec l2 = sine(rate, 300, 0.4, (size_t)(rate * 0.5)), r2 = l2;
    run(g, l2, r2);
    bool finite = true;
    for (float v : l2) finite = finite && std::isfinite(v);
    check(finite, "output stays finite across a band-count change", rate);
    check(rb(g).bandCount == 4, "new band count after the rebuild", rate, rb(g).bandCount);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    testGolden();
    testValidation();
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        testRate(rate);
        testCountChange(rate);
    }
    if (failures == 0) std::printf("test_mb_nband: ok\n");
    return failures == 0 ? 0 : 1;
}
