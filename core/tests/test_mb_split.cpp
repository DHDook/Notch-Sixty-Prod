// E28 G42: the multiband band-pass tree (parameter 43 = 1), at the eight standard rates. Bands sum flat (LR4 and LR8), each
// band holds only its own range (the old residual mid leaked a 0.1 tone at 50 Hz and 9 kHz at about 0.11 and 0.1), the
// split adds no latency, the extras-off block is unchanged, enable and disable do not step, the lookahead keeps the bands
// aligned, and the realtime call allocates nothing across live corner edits.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "n60/graph.h"

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

// on 0, lowMid 1, midHigh 2, slopes 3-4, thr 5, ratio 8, atk 11, rel 14, knee 17, hpf 20, makeup 23, auto 26, bypass 29,
// solo 32, listen 35, detector 38, window 41, lookahead 42, split 43.
struct Mb {
    float p[44] = {1, 120, 3500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                   1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 0, 1};
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

Vec run(n60_graph *g, const Vec &in, uint32_t block = 512) {
    Vec ol(in.size()), orr(in.size());
    for (size_t off = 0; off < in.size(); off += block) {
        const uint32_t n = (uint32_t)std::min<size_t>(block, in.size() - off);
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
    return ol;
}
Vec render(double rate, const Mb &m, const Vec &in, uint32_t count = 44) {
    n60_graph *g = build(rate, m.p, count);
    if (!g) return Vec(in.size());
    Vec out = run(g, in);
    n60_graph_retire(g);
    return out;
}
Vec sine(double rate, double hz, double amp, size_t n) {
    Vec v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}
Vec noise(size_t n, float amp) {
    static uint32_t rng = 777;
    Vec v(n);
    for (auto &x : v) {
        rng = rng * 1664525u + 1013904223u;
        x = amp * ((float)((rng >> 8) & 0xFFFF) / 32768.0f - 1.0f);
    }
    return v;
}
double rms(const Vec &v, size_t from) {
    double s = 0;
    for (size_t i = from; i < v.size(); ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(v.size() - from));
}
double db(double x) { return 20.0 * std::log10(x); }
// Peak amplitude of a tone, as sqrt(2) * rms.
double amp(const Vec &v, size_t from) { return rms(v, from) * std::sqrt(2.0); }

void testRate(double rate) {
    const size_t n = (size_t)(rate * 0.8), from = n / 2;
    const double tones[] = {50, 120, 300, 1000, 3500, 9000};
    // 1. Flat sum: every band bypassed (unity gain), a tone at each frequency keeps its level within 0.01 dB; LR4 and LR8.
    for (int lr8 = 0; lr8 < 2; ++lr8) {
        Mb m;
        m.p[3] = m.p[4] = (float)lr8;
        for (double hz : tones) {
            const Vec in = sine(rate, hz, 0.3, n);
            const Vec o = render(rate, m, in);
            const double d = db(rms(o, from) / rms(in, from));
            check(std::fabs(d) < 0.01, lr8 ? "LR8 tree sums flat" : "LR4 tree sums flat", rate, hz, d);
        }
        const Vec in = noise(n, 0.5f);
        const Vec o = render(rate, m, in);
        check(std::fabs(db(rms(o, from) / rms(in, from))) < 0.02, "tree sums flat on noise", rate, db(rms(o, from) / rms(in, from)));
    }
    // 2. Isolation: a 0.1 tone, one band soloed. The residual mid passed 50 Hz at 0.11 and 9 kHz at 0.10.
    for (int lr8 = 0; lr8 < 2; ++lr8) {
        for (int band = 0; band < 3; ++band) {
            Mb m;
            m.p[3] = m.p[4] = (float)lr8;
            m.p[32 + band] = 1;
            for (double hz : tones) {
                const Vec o = render(rate, m, sine(rate, hz, 0.1, n));
                const double a = amp(o, from);
                if (band == 1 && (hz == 50 || hz == 9000)) check(a < 0.005, "mid solo leak of the 0.1 tone is near zero", rate, hz, a);
                if (band == 0 && hz >= 1000) check(a < 0.005, "low solo holds no highs", rate, hz, a);
                if (band == 2 && hz <= 300) check(a < 0.005, "high solo holds no lows", rate, hz, a);
                if (band == 1 && hz == 1000) check(std::fabs(db(a / 0.1)) < 0.2, "mid passes its own range", rate, hz, a);
                if (band == 0 && hz == 50) check(std::fabs(db(a / 0.1)) < 0.3, "low passes its own range", rate, hz, a);
                if (band == 2 && hz == 9000) check(std::fabs(db(a / 0.1)) < 0.3, "high passes its own range", rate, hz, a);
            }
        }
    }
    // 3. Extras off: the 43-value block (no split) and a 44-value block with split 0 are bit-identical, and the residual
    // mid still leaks (the shipped sound).
    {
        Mb b;
        b.p[43] = 0;
        b.p[33] = 1;  // mid solo
        const Vec in = sine(rate, 50, 0.1, n);
        const Vec o43 = render(rate, b, in, 43), o44 = render(rate, b, in, 44);
        check(std::memcmp(o43.data(), o44.data(), n * 4) == 0, "split 0 is bit-identical to the 43-value block", rate);
        check(amp(o43, from) > 0.05, "residual mid still leaks 50 Hz when the split is off", rate, amp(o43, from));
    }
    // 4. Latency: the split adds none; the lookahead is the only latency.
    {
        Mb m;
        n60_graph *g = build(rate, m.p, 44);
        check(g && n60_graph_latency_frames(g) == 0, "split adds no latency", rate, g ? n60_graph_latency_frames(g) : -1);
        if (g) n60_graph_retire(g);
        const uint32_t look = (uint32_t)(rate * 0.003);
        m.p[42] = (float)look;
        g = build(rate, m.p, 44);
        check(g && n60_graph_latency_frames(g) == look, "latency is the lookahead alone", rate, g ? n60_graph_latency_frames(g) : -1, look);
        if (g) n60_graph_retire(g);
    }
    // 5. The lookahead keeps the three bands aligned: the delayed output is the undelayed tree output, shifted.
    {
        Mb m;
        const uint32_t look = (uint32_t)(rate * 0.003);
        const Vec in = noise(n, 0.4f);
        const Vec a = render(rate, m, in);
        m.p[42] = (float)look;
        const Vec b = render(rate, m, in);
        double worst = 0;
        for (size_t i = (size_t)(rate * 0.1); i + look < n; ++i) worst = std::max(worst, std::fabs((double)a[i] - (double)b[i + look]));
        check(worst < 2e-6, "lookahead output is the delayed tree output", rate, worst);
    }
    // 6. Enable and disable do not step: the stage fades against the dry signal, and after the fade the output is the dry
    // signal exactly (parked).
    {
        Mb m;
        const Vec in = sine(rate, 150, 0.5, n);
        n60_graph *g = build(rate, m.p, 44);
        Vec out = run(g, Vec(in.begin(), in.begin() + n / 2));
        n60_param_record off[1] = {{5, 0, 0.0f, 0}};
        n60_graph_post_params(g, off, 1);
        const Vec tail = run(g, Vec(in.begin() + n / 2, in.end()));
        n60_graph_retire(g);
        out.insert(out.end(), tail.begin(), tail.end());
        double inStep = 0, outStep = 0;
        for (size_t i = n / 2 - 64; i < n / 2 + (size_t)(rate * 0.05); ++i) {
            inStep = std::max(inStep, std::fabs((double)in[i] - in[i - 1]));
            outStep = std::max(outStep, std::fabs((double)out[i] - out[i - 1]));
        }
        check(outStep < 1.6 * inStep + 1e-4, "disable fades without a step", rate, outStep, inStep);
        double dryDiff = 0;
        for (size_t i = n / 2 + (size_t)(rate * 0.3); i < n; ++i) dryDiff = std::max(dryDiff, std::fabs((double)out[i] - in[i]));
        check(dryDiff == 0.0, "disabled stage passes the dry signal exactly", rate, dryDiff);
    }
    // 7. The realtime call allocates nothing across live corner, enable and sidechain edits.
    {
        constexpr uint32_t N = 512;
        Mb m;
        m.p[29] = m.p[30] = m.p[31] = 0;
        n60_graph *g = build(rate, m.p, 44);
        Vec l(N), r(N), ol(N), orr(N);
        for (uint32_t i = 0; i < N; ++i) { l[i] = 0.5f * std::sin(0.05f * i); r[i] = 0.5f * std::cos(0.07f * i); }
        const float *ip[2] = {l.data(), r.data()};
        float *op[2] = {ol.data(), orr.data()};
        long total = 0;
        for (int round = 0; round < 30; ++round) {
            n60_param_record rec[5] = {{5, 1, 60.0f + 5.0f * round, 0},
                                       {5, 2, 1500.0f + 100.0f * round, 0},
                                       {5, 20, (float)(10 * (round % 7)), 0},
                                       {5, 0, (float)((round / 3) % 2), 0},
                                       {5, 5, -40.0f + (float)round, 0}};
            check(n60_graph_post_params(g, rec, 5) == N60_STATUS_OK, "post split params", rate);
            allocs = 0;
            armed = true;
            n60_graph_process(g, ip, op, N);
            n60_graph_process(g, ip, op, 97);
            armed = false;
            total += allocs.load();
        }
        check(total == 0, "split allocates nothing in the callback", rate, (double)total);
        n60_graph_retire(g);
    }
    // 8. The split mode is topology: a bad value is rejected at build.
    {
        n60_status st;
        Mb m;
        m.p[43] = 2;
        check(build(rate, m.p, 44, &st) == nullptr && st != N60_STATUS_OK, "reject split 2", rate);
    }
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) testRate(rate);
    if (failures) {
        std::fprintf(stderr, "n60core multiband split: %d failures\n", failures);
        return 1;
    }
    std::puts("n60core multiband split: ok");
    return 0;
}
