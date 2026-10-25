// E11 S7: behavioural harness for the libn60core generator stage (ABI v14), through the C ABI at the eight
// standard rates. Reference values are closed forms written here: octave and third-octave band powers of a pink
// spectrum, the sine definition, Butterworth edge levels, RMS from the dB parameters.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "measure/offline_fft.hpp"
#include "n60/graph.h"
#include "n60/measure.h"

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

enum { TYPE, LEVEL, CEIL, FREQ, LOW, HIGH, PERIOD, SEED, MUTE, ACTIVE, STOP, NP };

struct Gen {
    float p[NP];
    Gen() {
        const float d[NP] = {1, -20, -6, 1000, 1000, 4000, 4096, 1, 1, 1, 600};
        std::memcpy(p, d, sizeof p);
    }
};

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

static n60_graph *build(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    const n60_graph_desc d = descOf(rate, ch, st, n);
    n60_graph *g = nullptr;
    const n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK, "build status %d", int(s));
    return g;
}

// Renders `frames` frames; input is a constant per channel (program audio). Returns channel-major output.
static std::vector<std::vector<float>> render(n60_graph *g, uint32_t ch, uint32_t frames, const float *progDc = nullptr,
                                              bool count = false) {
    std::vector<std::vector<float>> out(ch, std::vector<float>(frames));
    std::vector<float> in(kBlock * ch);
    std::vector<float> ob(kBlock * ch);
    for (uint32_t c = 0; c < ch; ++c)
        for (uint32_t i = 0; i < kBlock; ++i) in[c * kBlock + i] = progDc ? progDc[c] : 0.0f;
    for (uint32_t pos = 0; pos < frames; pos += kBlock) {
        const uint32_t n = frames - pos < kBlock ? frames - pos : kBlock;
        const float *ip[64];
        float *op[64];
        for (uint32_t c = 0; c < ch; ++c) {
            ip[c] = &in[c * kBlock];
            op[c] = &ob[c * kBlock];
        }
        if (count) armed = true;
        n60_graph_process(g, ip, op, n);
        armed = false;
        for (uint32_t c = 0; c < ch; ++c) std::memcpy(&out[c][pos], op[c], n * sizeof(float));
    }
    return out;
}

static double rmsDb(const float *x, size_t n) {
    double e = 0;
    for (size_t i = 0; i < n; ++i) e += double(x[i]) * x[i];
    return 10.0 * std::log10(e / double(n) + 1e-300);
}

static uint32_t rampOf(double rate) { return uint32_t(std::lround(0.1 * rate)); }
static uint32_t tableLenOf(double rate) {
    uint32_t n = 1024;
    while (n < 2.0 * rate) n <<= 1;
    return n;
}

static std::vector<n60::fft::offline::Cplx> spectrumOf(const float *x, uint32_t n) {
    std::vector<double> d(x, x + n);
    std::vector<n60::fft::offline::Cplx> s;
    n60::fft::offline::realForward(d.data(), n, s);
    return s;
}

static double bandDb(const std::vector<n60::fft::offline::Cplx> &s, uint32_t n, double rate, double lo, double hi) {
    double e = 0;
    for (uint32_t k = 1; k < s.size(); ++k) {
        const double f = rate * k / n;
        if (f >= lo && f < hi) e += s[k].re * s[k].re + s[k].im * s[k].im;
    }
    return 10.0 * std::log10(e + 1e-300);
}

static void testPinkSlope(double rate) {
    Gen G;
    G.p[TYPE] = 1;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 1, st, 1);
    const uint32_t n = tableLenOf(rate);
    auto o = render(g, 1, n + 2 * rampOf(rate));
    const float *x = o[0].data() + (o[0].size() - n);
    CHECK(std::fabs(rmsDb(x, n) - (-20.0)) < 0.05, "%.0f pink RMS %.3f dBFS", rate, rmsDb(x, n));
    const auto s = spectrumOf(x, n);
    double mn = 1e9, mx = -1e9;
    // Third-octave bands from 20 Hz while the upper edge is within 0.45 fs: equal power per band.
    for (double lo = 20.0; lo * std::pow(2.0, 1.0 / 3.0) <= 0.45 * rate; lo *= std::pow(2.0, 1.0 / 3.0)) {
        const double b = bandDb(s, n, rate, lo, lo * std::pow(2.0, 1.0 / 3.0));
        mn = std::fmin(mn, b);
        mx = std::fmax(mx, b);
    }
    CHECK(mx - mn < 1.0, "%.0f third-octave band spread %.3f dB (need within +-0.5)", rate, mx - mn);
    // Octave bands from 20 Hz.
    mn = 1e9, mx = -1e9;
    for (double lo = 20.0; lo * 2.0 <= 0.45 * rate; lo *= 2.0) {
        const double b = bandDb(s, n, rate, lo, lo * 2.0);
        mn = std::fmin(mn, b);
        mx = std::fmax(mx, b);
    }
    CHECK(mx - mn < 1.0, "%.0f octave band spread %.3f dB", rate, mx - mn);
    n60_graph_retire(g);
}

static void testBand(double rate) {
    Gen G;
    G.p[TYPE] = 2;
    G.p[LOW] = 1000;
    G.p[HIGH] = 4000;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 1, st, 1);
    const uint32_t n = tableLenOf(rate);
    auto o = render(g, 1, n + 2 * rampOf(rate));
    const float *x = o[0].data() + (o[0].size() - n);
    CHECK(std::fabs(rmsDb(x, n) - (-20.0)) < 0.05, "%.0f band RMS %.3f", rate, rmsDb(x, n));
    const auto s = spectrumOf(x, n);
    auto pinkDb = [&](double f) {  // |X|^2 * f at the bin nearest f: constant for a flat pink band
        const uint32_t k = uint32_t(std::lround(f * n / rate));
        const double fk = rate * k / n;
        return 10.0 * std::log10((s[k].re * s[k].re + s[k].im * s[k].im) * fk);
    };
    const double mid = pinkDb(2000.0);
    CHECK(std::fabs(pinkDb(1000.0) - mid + 3.01) < 0.5, "%.0f low edge %.2f dB (want -3)", rate, pinkDb(1000.0) - mid);
    CHECK(std::fabs(pinkDb(4000.0) - mid + 3.01) < 0.5, "%.0f high edge %.2f dB (want -3)", rate, pinkDb(4000.0) - mid);
    CHECK(std::fabs(pinkDb(1500.0) - mid) < 0.5 && std::fabs(pinkDb(2800.0) - mid) < 0.5, "%.0f passband flat", rate);
    CHECK(pinkDb(500.0) - mid < -23.0 && pinkDb(8000.0) - mid < -23.0, "%.0f one octave out: %.1f / %.1f dB", rate,
          pinkDb(500.0) - mid, pinkDb(8000.0) - mid);
    n60_graph_retire(g);
}

static void testTone(double rate) {
    for (double f : {1000.0, 0.4 * rate}) {
        Gen G;
        G.p[TYPE] = 3;
        G.p[FREQ] = float(f);
        G.p[LEVEL] = -12;
        n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
        n60_graph *g = build(rate, 1, st, 1);
        const uint32_t ramp = rampOf(rate);
        auto o = render(g, 1, ramp + 20000);
        const double fq = double(G.p[FREQ]);
        const double amp = std::pow(10.0, -12.0 / 20.0) * std::sqrt(2.0);
        double worst = 0;
        for (uint32_t i = ramp + 1; i < ramp + 20000; ++i) {
            worst = std::fmax(worst, std::fabs(o[0][i] - amp * std::sin(2.0 * kPi * fq * i / rate)));
        }
        CHECK(worst < 2e-6, "%.0f tone %.1f Hz max error %.3g", rate, fq, worst);
        CHECK(std::fabs(o[0][0]) < 1e-9, "tone starts at zero");
        n60_graph_retire(g);
    }
}

static void testCeiling(double rate) {
    Gen G;
    G.p[TYPE] = 0;
    G.p[LEVEL] = 0;  // asks for 0 dBFS RMS: clamps to the -6 ceiling
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 1, st, 1);
    auto o = render(g, 1, rampOf(rate) + 100000);
    const double db = rmsDb(o[0].data() + rampOf(rate) + 1000, 99000);
    CHECK(std::fabs(db + 6.0) < 0.1, "%.0f white clamped to %.3f dBFS (want -6)", rate, db);
    n60_graph_retire(g);

    G.p[CEIL] = -12;
    G.p[LEVEL] = -3;
    n60_stage_desc st2[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    g = build(rate, 1, st2, 1);
    o = render(g, 1, rampOf(rate) + 100000);
    const double db2 = rmsDb(o[0].data() + rampOf(rate) + 1000, 99000);
    CHECK(std::fabs(db2 + 12.0) < 0.1, "%.0f custom ceiling %.3f", rate, db2);
    n60_graph_retire(g);
}

static void testRampsAndLanes(double rate) {
    Gen G;
    G.p[TYPE] = 3;
    G.p[FREQ] = 1000;
    G.p[LEVEL] = -10;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, 0, G.p, NP)};
    n60_graph *g = build(rate, 2, st, 1);
    const float prog[2] = {0.0f, 0.3f};
    const uint32_t ramp = rampOf(rate);
    auto o = render(g, 2, 3 * ramp, prog);
    const double amp = std::pow(10.0, -10.0 / 20.0) * std::sqrt(2.0);
    const double w = 2 * kPi * 1000.0 / rate;
    double maxStep = 0;
    for (uint32_t i = 1; i < 3 * ramp; ++i) maxStep = std::fmax(maxStep, std::fabs(o[0][i] - o[0][i - 1]));
    CHECK(maxStep <= amp * (w + 2.0 / ramp) * 1.01, "%.0f start step %.5f", rate, maxStep);
    CHECK(std::fabs(o[1][3 * ramp - 1]) < 1e-6, "mute-others silenced lane 1: %g", o[1][3 * ramp - 1]);
    CHECK(std::fabs(o[1][0] - 0.3f) < 1e-3, "program passes before the ramp");
    float p[2] = {0, 0};
    n60_param_record rec{1, ACTIVE, 0.0f, 0};
    CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post stop");
    o = render(g, 2, 3 * ramp, prog);
    maxStep = 0;
    for (uint32_t i = 1; i < 3 * ramp; ++i) maxStep = std::fmax(maxStep, std::fabs(o[0][i] - o[0][i - 1]));
    CHECK(maxStep <= amp * (w + 2.0 / ramp) * 1.01, "%.0f stop step %.5f", rate, maxStep);
    CHECK(std::fabs(o[1][3 * ramp - 1] - 0.3f) < 1e-6, "program restored on lane 1: %g", o[1][3 * ramp - 1]);
    CHECK(std::fabs(o[0][3 * ramp - 1]) < 1e-6, "silent lane 0 after stop (program was 0)");
    (void)p;
    n60_graph_retire(g);

    // Without mute-others, the other lane keeps its program.
    G.p[MUTE] = 0;
    n60_stage_desc st2[1] = {stg(N60_STAGE_GENERATOR, 1, 0, G.p, NP)};
    g = build(rate, 2, st2, 1);
    o = render(g, 2, 3 * ramp, prog);
    CHECK(std::fabs(o[1][3 * ramp - 1] - 0.3f) < 1e-6, "lane 1 untouched without mute");
    n60_graph_retire(g);
}

static void testDeterminismAndRestart(double rate) {
    for (uint32_t type : {0u, 1u, 2u, 4u}) {
        Gen G;
        G.p[TYPE] = float(type);
        n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
        n60_graph *a = build(rate, 2, st, 1);
        n60_graph *b = build(rate, 2, st, 1);
        auto oa = render(a, 2, 5000);
        auto ob = render(b, 2, 5000);
        CHECK(std::memcmp(oa[0].data(), ob[0].data(), 5000 * sizeof(float)) == 0, "%.0f type %u bit-identical", rate, type);
        CHECK(std::memcmp(oa[1].data(), ob[1].data(), 5000 * sizeof(float)) == 0, "lane 1 identical");
        CHECK(std::memcmp(oa[0].data(), oa[1].data(), 5000 * sizeof(float)) != 0, "%.0f type %u lanes differ", rate, type);
        n60_graph_retire(b);
        G.p[SEED] = 2;
        n60_stage_desc st2[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
        n60_graph *c = build(rate, 2, st2, 1);
        auto oc = render(c, 2, 5000);
        CHECK(std::memcmp(oa[0].data(), oc[0].data(), 5000 * sizeof(float)) != 0, "%.0f type %u seed changes output", rate, type);
        n60_graph_retire(c);
        // Stop, wait for silence, start: the stream restarts from its seed.
        n60_param_record off{1, ACTIVE, 0.0f, 0}, on{1, ACTIVE, 1.0f, 0};
        n60_graph_post_params(a, &off, 1);
        render(a, 2, rampOf(rate) + 2 * kBlock);
        n60_graph_post_params(a, &on, 1);
        auto od = render(a, 2, 5000);
        // Mix ramps again from zero, so compare after the ramp is applied: regenerate the reference ramp-free by
        // comparing against a fresh graph rendered the same way.
        G.p[SEED] = 1;
        n60_graph *f = build(rate, 2, st, 1);
        auto of = render(f, 2, 5000);
        CHECK(std::memcmp(od[0].data(), of[0].data(), 5000 * sizeof(float)) == 0, "%.0f type %u restart reproduces start", rate, type);
        n60_graph_retire(f);
        n60_graph_retire(a);
    }
}

static void testPeriodic(double rate) {
    Gen G;
    G.p[TYPE] = 4;
    G.p[PERIOD] = 4096;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 1, st, 1);
    auto o = render(g, 1, rampOf(rate) + 3 * 4096);
    const float *x = o[0].data() + rampOf(rate) + 16;
    uint32_t diff = 0;
    for (uint32_t i = 0; i < 4096; ++i) diff += (x[i] != x[i + 4096]);
    CHECK(diff == 0, "%.0f periodic: %u samples differ after one period", rate, diff);
    const auto s = spectrumOf(x, 4096);
    auto lvl = [&](uint32_t k) { return 10.0 * std::log10((s[k].re * s[k].re + s[k].im * s[k].im) * k); };
    const double ref = lvl(100);
    double worst = 0;
    for (uint32_t k = 8; k < uint32_t(0.45 * 4096); ++k) worst = std::fmax(worst, std::fabs(lvl(k) - ref));
    CHECK(worst < 0.05, "%.0f periodic bins follow 1/f within %.4f dB", rate, worst);
    CHECK(std::fabs(rmsDb(x, 4096) + 20.0) < 0.05, "periodic RMS %.3f", rmsDb(x, 4096));
    n60_graph_retire(g);
}

// E10 S8: the sweep kind equals the E11 synchronised ESS bit for bit (times the RMS-referenced gain), plays once, then
// stays silent, and restarts on a rising edge.
static void testSweep(double rate) {
    Gen G;
    G.p[TYPE] = 5;
    G.p[LOW] = 20;
    G.p[HIGH] = 18000;
    G.p[PERIOD] = float(uint32_t(rate)); // 1 s
    G.p[LEVEL] = -20;
    G.p[MUTE] = 0;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 2, st, 1);
    n60_measure_ess_params e{};
    e.sample_rate = rate; e.start_hz = 20; e.end_hz = 18000; e.duration_seconds = 1.0; e.level_dbfs = 0;
    e.fade_seconds = 0.05; e.synchronised = 1;
    n60_measure_ess_info info{};
    CHECK(n60_measure_ess_describe(&e, &info) == N60_MEASURE_OK, "describe");
    std::vector<float> ref(info.frame_count);
    CHECK(n60_measure_ess_generate(&e, ref.data(), ref.size(), &info) == N60_MEASURE_OK, "generate");
    const uint32_t total = uint32_t(info.frame_count) + uint32_t(rate * 0.3);
    auto o = render(g, 2, total);
    const float gain = float(std::pow(10.0, -20.0 / 20.0) * std::sqrt(2.0));
    // Past the 100 ms mix ramp the output is exactly the scaled ESS.
    uint32_t diff = 0, lanesDiffer = 0;
    for (uint32_t i = rampOf(rate); i < info.frame_count; ++i) {
        const float want = std::clamp(ref[i] * gain, -1.0f, 1.0f);
        diff += (o[0][i] != want) ? 1u : 0u;
        lanesDiffer += (o[0][i] != o[1][i]);
    }
    CHECK(diff == 0, "%.0f sweep differs from the E11 ESS in %u samples", rate, diff);
    CHECK(lanesDiffer == 0, "%.0f sweep lanes identical", rate);
    double tail = 0;
    for (uint32_t i = uint32_t(info.frame_count) + 16; i < total; ++i) tail = std::fmax(tail, std::fabs(o[0][i]));
    CHECK(tail == 0.0, "%.0f silent after the sweep (peak %g)", rate, tail);
    n60_graph_retire(g);

    // Invalid sweeps are refused: end above 0.45 fs, end below start, too short, too long.
    auto bad = [&](int idx, float v) {
        Gen H = G;
        H.p[idx] = v;
        n60_stage_desc s2[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, H.p, NP)};
        n60_graph_desc d = descOf(rate, 2, s2, 1);
        n60_graph *x = nullptr;
        const n60_status r = n60_graph_build(&d, &x);
        if (x) n60_graph_retire(x);
        return r != N60_STATUS_OK;
    };
    CHECK(bad(HIGH, float(0.46 * rate)), "%.0f sweep end above 0.45 fs", rate);
    CHECK(bad(HIGH, 10.0f), "%.0f sweep end below start", rate);
    CHECK(bad(PERIOD, float(uint32_t(rate * 0.1))), "%.0f sweep shorter than 0.5 s", rate);
    CHECK(bad(PERIOD, 20000000.0f), "%.0f sweep above 16777216 frames", rate);
}

static void testAutoStop(double rate) {
    Gen G;
    G.p[TYPE] = 0;
    G.p[STOP] = 0.5f;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 1, st, 1);
    const uint32_t total = uint32_t(0.8 * rate);
    auto o = render(g, 1, total);
    const uint32_t mid = uint32_t(0.3 * rate), late = uint32_t(0.5 * rate) + rampOf(rate) + 2 * kBlock;
    CHECK(rmsDb(&o[0][mid], 2000) > -40.0, "%.0f still playing at 0.3 s", rate);
    double peak = 0;
    for (uint32_t i = late; i < total; ++i) peak = std::fmax(peak, std::fabs(o[0][i]));
    CHECK(peak == 0.0, "%.0f silent after auto-stop (peak %g)", rate, peak);
    n60_graph_retire(g);

    // Toggling off then on inside the fade-out re-arms the source.
    n60_graph *h = build(rate, 1, st, 1);
    render(h, 1, uint32_t(0.5 * rate) + rampOf(rate) / 4);
    n60_param_record off{1, ACTIVE, 0.0f, 0}, on{1, ACTIVE, 1.0f, 0};
    n60_graph_post_params(h, &off, 1);
    render(h, 1, kBlock);
    n60_graph_post_params(h, &on, 1);
    auto r = render(h, 1, 3 * rampOf(rate));
    CHECK(rmsDb(&r[0][2 * rampOf(rate)], rampOf(rate)) > -40.0, "%.0f re-armed after toggle in fade", rate);
    n60_graph_retire(h);
}

static void testProtectionDownstream(double rate) {
    Gen G;
    G.p[TYPE] = 1;
    G.p[LEVEL] = -6;
    const float prot[7] = {1.0f, -20.0f, 1.0f, 50.0f, 10.0f, 0.0f, 1.0f};
    n60_stage_desc st[2] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP), stg(N60_STAGE_PROTECTION, 2, N60_LANE_ALL, prot, 7)};
    n60_graph *g = build(rate, 2, st, 2);
    auto o = render(g, 2, uint32_t(rate * 0.6));
    double peak = 0;
    for (uint32_t i = uint32_t(rate * 0.3); i < o[0].size(); ++i) peak = std::fmax(peak, std::fabs(o[0][i]));
    CHECK(peak > 0.02, "%.0f limiter passes signal (peak %.4f)", rate, peak);
    CHECK(peak <= 0.1 * 1.01, "%.0f protection holds the -20 dBFS ceiling downstream of the generator: %.4f", rate, peak);
    n60_graph_retire(g);

    // PROTECTION before the generator is not a valid order.
    n60_stage_desc bad[2] = {stg(N60_STAGE_PROTECTION, 2, N60_LANE_ALL, prot, 7), stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph_desc d = descOf(rate, 2, bad, 2);
    n60_graph *none = nullptr;
    CHECK(n60_graph_build(&d, &none) == N60_STATUS_BAD_ARGUMENT, "generator after protection is rejected");
}

static void testNoAllocation(double rate) {
    Gen G;
    G.p[TYPE] = 1;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
    n60_graph *g = build(rate, 2, st, 1);
    allocs = 0;
    render(g, 2, 8 * kBlock, nullptr, true);
    n60_param_record rec{1, LEVEL, -30.0f, 0};
    n60_graph_post_params(g, &rec, 1);
    render(g, 2, 8 * kBlock, nullptr, true);
    CHECK(allocs.load() == 0, "%.0f render allocated %ld times", rate, allocs.load());
    for (uint32_t type : {0u, 3u, 2u, 5u}) {
        Gen H;
        H.p[TYPE] = float(type);
        if (type == 5u) {  // the sweep: 10 Hz to 0.4 fs over about one second
            H.p[LOW] = 10.0f;
            H.p[HIGH] = float(0.4 * rate);
            H.p[PERIOD] = float(std::lround(rate));
        }
        n60_stage_desc s2[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, H.p, NP)};
        n60_graph *h = build(rate, 2, s2, 1);
        allocs = 0;
        render(h, 2, 4 * kBlock, nullptr, true);
        CHECK(allocs.load() == 0, "type %u allocated", type);
        n60_graph_retire(h);
    }
    n60_graph_retire(g);
}

static void testRejects() {
    auto rejects = [](Gen G, int idx, float v, uint32_t ch = 2) {
        G.p[idx] = v;
        n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, G.p, NP)};
        n60_graph_desc d = descOf(48000.0, ch, st, 1);
        n60_graph *g = nullptr;
        const n60_status s = n60_graph_build(&d, &g);
        if (g) n60_graph_retire(g);
        return s != N60_STATUS_OK;
    };
    Gen G;
    CHECK(!rejects(G, LEVEL, -20), "default accepted");
    CHECK(rejects(G, LEVEL, 1.0f), "level above 0");
    CHECK(rejects(G, CEIL, -5.0f), "ceiling above -6");
    CHECK(rejects(G, STOP, 0.0f), "auto-stop 0");
    CHECK(rejects(G, STOP, 601.0f), "auto-stop above 600 s");
    CHECK(rejects(G, TYPE, 9.0f), "unknown type");
    CHECK(rejects(G, ACTIVE, 2.0f), "active not 0/1");
    G.p[TYPE] = 4;
    CHECK(rejects(G, PERIOD, 5000.0f), "non power of two period");
    G.p[TYPE] = 3;
    CHECK(rejects(G, FREQ, 30000.0f), "tone above 0.45 fs");
    G.p[TYPE] = 2;
    CHECK(rejects(G, HIGH, 1010.0f), "band narrower than 5 percent");
    Gen H;
    n60_stage_desc st[1] = {stg(N60_STAGE_GENERATOR, 1, 5, H.p, NP)};
    n60_graph_desc d = descOf(48000.0, 2, st, 1);
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "lane out of range");
    // Live edits: level and active only.
    n60_stage_desc ok[1] = {stg(N60_STAGE_GENERATOR, 1, N60_LANE_ALL, H.p, NP)};
    d = descOf(48000.0, 2, ok, 1);
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build");
    n60_param_record bad{1, SEED, 5.0f, 0};
    CHECK(n60_graph_post_params(g, &bad, 1) == N60_STATUS_UNSUPPORTED, "seed is not live");
    n60_param_record lvl{1, LEVEL, 3.0f, 0};
    CHECK(n60_graph_post_params(g, &lvl, 1) == N60_STATUS_BAD_ARGUMENT, "live level range");
    n60_graph_retire(g);
}

int main() {
    CHECK(n60_graph_abi_version() == N60_GRAPH_ABI_VERSION && N60_GRAPH_ABI_VERSION == 16u, "ABI v16");
    testRejects();
    for (double rate : kRates) {
        testPinkSlope(rate);
        testBand(rate);
        testTone(rate);
        testCeiling(rate);
        testRampsAndLanes(rate);
        testDeterminismAndRestart(rate);
        testPeriodic(rate);
        testSweep(rate);
        testAutoStop(rate);
        testProtectionDownstream(rate);
        testNoAllocation(rate);
    }
    if (failures == 0) std::printf("generator harness: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
