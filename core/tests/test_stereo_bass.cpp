// E25 S2: behavioural harness for the STEREO_CROSSOVER filter-spec trailer (ABI v19), negative GAIN as lane polarity,
// and the crossover-then-ROOM_FIR coexistence, through the C ABI at the eight standard rates.
// References are closed forms or an independent re-statement of the v18 arithmetic written in this file.
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
static const uint32_t kBlock = 480;

static n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t laneA, uint32_t laneB, const float *p, uint32_t pc) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.laneB = laneB;
    s.params = p;
    s.paramCount = pc;
    return s;
}

static n60_status buildGraph(double rate, const std::vector<n60_stage_desc> &st, n60_graph **g) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st.data();
    d.stageCount = static_cast<uint32_t>(st.size());
    return n60_graph_build(&d, g);
}

static void run(n60_graph *g, const std::vector<float> &l, const std::vector<float> &r, std::vector<float> &ol,
                std::vector<float> &orr) {
    const size_t n = l.size();
    ol.assign(n, 0.0f);
    orr.assign(n, 0.0f);
    for (size_t at = 0; at < n; at += kBlock) {
        const uint32_t len = static_cast<uint32_t>(std::min<size_t>(kBlock, n - at));
        const float *in[2] = {l.data() + at, r.data() + at};
        float *out[2] = {ol.data() + at, orr.data() + at};
        n60_graph_process(g, in, out, len);
    }
}

// ---- the v18 arithmetic, restated -----------------------------------------------------------------------------------
struct RefBq { double z1 = 0, z2 = 0; };
static void refDesign(int type, double rate, double hz, double q, double *c) {
    const double omega = 2.0 * kPi * hz / rate;
    const double cosine = std::cos(omega);
    const double alpha = std::sin(omega) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    c[3] = (-2.0 * cosine) / a0;
    c[4] = (1.0 - alpha) / a0;
    if (type == 0) { c[0] = (1.0 - cosine) / (2.0 * a0); c[1] = 2.0 * c[0]; c[2] = c[0]; }
    else { c[0] = (1.0 + cosine) / (2.0 * a0); c[1] = -2.0 * c[0]; c[2] = c[0]; }
}
static float refRun(const double *c, RefBq &s, float in) {
    const double x = static_cast<double>(in);
    const double y = c[0] * x + s.z1;
    s.z1 = c[1] * x - c[3] * y + s.z2;
    s.z2 = c[2] * x - c[4] * y;
    return static_cast<float>(y);
}

static void signal(std::vector<float> &l, std::vector<float> &r, size_t n, double rate) {
    l.resize(n);
    r.resize(n);
    uint32_t seed = 99;
    for (size_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        const float noise = (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        l[i] = 0.4f * noise + 0.3f * static_cast<float>(std::sin(2.0 * kPi * 55.0 * i / rate));
        r[i] = 0.3f * noise * ((i / 997) % 2 ? 1.0f : -1.0f) + 0.2f * static_cast<float>(std::sin(2.0 * kPi * 1500.0 * i / rate));
    }
}

// Single-bin DFT amplitude of the last `span` frames, Hann windowed.
static double amplitude(const std::vector<float> &x, double rate, double hz, size_t span) {
    const size_t start = x.size() - span;
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < span; i++) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * (i + 0.5) / span);
        const double ph = 2.0 * kPi * hz * (start + i) / rate;
        re += w * x[start + i] * std::cos(ph);
        im += w * x[start + i] * std::sin(ph);
        wsum += w;
    }
    return 2.0 * std::sqrt(re * re + im * im) / wsum;
}

static std::vector<float> tone(size_t n, double rate, double hz, float level) {
    std::vector<float> t(n);
    for (size_t i = 0; i < n; i++) t[i] = level * static_cast<float>(std::sin(2.0 * kPi * hz * i / rate));
    return t;
}

static double db(double ratio) { return 20.0 * std::log10(ratio); }

// 1. No trailer: bit-identical to the v18 arithmetic for LR24 and LR48.
static void testNoTrailerBitIdentical() {
    for (double rate : kRates) {
        for (int lr48 = 0; lr48 < 2; lr48++) {
            const float p[8] = {100.0f, static_cast<float>(lr48), 0, 1.0f, 0, 0, 80, 0.7f};
            n60_graph *g = nullptr;
            CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 8)}, &g) == N60_STATUS_OK, "build v18 form");
            if (!g) continue;
            std::vector<float> l, r, ol, orr;
            signal(l, r, 20000, rate);
            run(g, l, r, ol, orr);
            const double q24[2] = {0.7071067811865476, 0.7071067811865476};
            const double q48[4] = {0.5411961001461970, 1.3065629648763766, 0.5411961001461970, 1.3065629648763766};
            const uint32_t n = lr48 ? 4 : 2;
            double hp[4][5], lp[4][5];
            for (uint32_t k = 0; k < n; k++) {
                const double q = lr48 ? q48[k] : q24[k];
                refDesign(1, rate, 100.0, q, hp[k]);
                refDesign(0, rate, 100.0, q, lp[k]);
            }
            RefBq sh[2][4], sl[4];
            size_t bad = 0;
            for (size_t base = 0; base < l.size(); base += 256) {
                const size_t len = std::min<size_t>(256, l.size() - base);
                std::vector<float> ml(l.begin() + base, l.begin() + base + len), mr(r.begin() + base, r.begin() + base + len), sub(len);
                for (size_t i = 0; i < len; i++) sub[i] = (ml[i] + mr[i]) * 0.5f;
                for (uint32_t k = 0; k < n; k++) {
                    for (size_t i = 0; i < len; i++) ml[i] = refRun(hp[k], sh[0][k], ml[i]);
                    for (size_t i = 0; i < len; i++) mr[i] = refRun(hp[k], sh[1][k], mr[i]);
                    for (size_t i = 0; i < len; i++) sub[i] = refRun(lp[k], sl[k], sub[i]);
                }
                for (size_t i = 0; i < len; i++) {
                    const float sb = sub[i] * 1.0f;
                    if (ol[base + i] != ml[i] + sb || orr[base + i] != mr[i] + sb) bad++;
                }
            }
            CHECK(bad == 0, "no trailer must match v18 bit for bit (rate %.0f lr48 %d): %zu frames differ", rate, lr48, bad);
            n60_graph_retire(g);
        }
    }
}

// 2. Each family and slope: level at fc (HP and LP), within 0.1 dB of the closed form.
static void testLevelAtCorner() {
    const uint32_t families[3] = {N60_GRAPH_FILTER_BUTTERWORTH, N60_GRAPH_FILTER_BESSEL, N60_GRAPH_FILTER_LINKWITZ_RILEY};
    const uint32_t orders[4] = {2, 4, 6, 8};
    for (double rate : kRates) {
        for (uint32_t family : families) {
            for (uint32_t order : orders) {
                const float fc = 100.0f;
                const double expected = family == N60_GRAPH_FILTER_LINKWITZ_RILEY ? -6.0206 : -3.0103;
                for (int sub = 0; sub < 2; sub++) {
                    const float p[12] = {fc, 0, sub ? 2.0f : 1.0f, 1.0f, 0, 0, 80, 0.7f,
                                         static_cast<float>(family), static_cast<float>(order),
                                         static_cast<float>(family), static_cast<float>(order)};
                    n60_graph *g = nullptr;
                    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK,
                          "build trailer family %u order %u", family, order);
                    if (!g) continue;
                    const size_t n = static_cast<size_t>(rate * 2.0);
                    // sub-only: L = R = tone gives the mono sum through the low-pass; mains-only: L = tone, R silent.
                    const std::vector<float> t = tone(n, rate, fc, 0.5f), zero(n, 0.0f);
                    std::vector<float> ol, orr;
                    run(g, t, sub ? t : zero, ol, orr);
                    const double got = db(amplitude(ol, rate, fc, static_cast<size_t>(rate * 0.5)) / 0.5);
                    CHECK(std::fabs(got - expected) < 0.1, "family %u order %u %s at fc: %.3f dB, expected %.3f (rate %.0f)",
                          family, order, sub ? "low-pass" : "high-pass", got, expected, rate);
                    n60_graph_retire(g);
                }
            }
        }
    }
}

// 3. Linkwitz-Riley recombination is flat (orders 4 and 8 as is; orders 2 and 6 with the sub inverted).
static void testLinkwitzRileySumsFlat() {
    const uint32_t orders[4] = {2, 4, 6, 8};
    const double probes[5] = {40.0, 80.0, 100.0, 125.0, 400.0};
    for (double rate : kRates) {
        for (uint32_t order : orders) {
            const float invert = (order == 2 || order == 6) ? 1.0f : 0.0f;
            const float p[12] = {100.0f, 0, 0, 1.0f, invert, 0, 80, 0.7f, 2, static_cast<float>(order), 2, static_cast<float>(order)};
            for (double hz : probes) {
                n60_graph *g = nullptr;
                CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "build LR sum");
                if (!g) continue;
                const size_t n = static_cast<size_t>(rate * 2.0);
                const std::vector<float> t = tone(n, rate, hz, 0.5f);
                std::vector<float> ol, orr;
                run(g, t, t, ol, orr);
                const double got = db(amplitude(ol, rate, hz, static_cast<size_t>(rate * 0.5)) / 0.5);
                CHECK(std::fabs(got) < 0.1, "LR%u recombined at %.0f Hz: %.3f dB (rate %.0f)", order * 6, hz, got, rate);
                n60_graph_retire(g);
            }
        }
    }
}

// 4. Below fc both lanes carry the same mono sum; above fc the pair stays independent.
static void testMonoBelowStereoAbove() {
    for (double rate : kRates) {
        const float p[12] = {200.0f, 0, 0, 1.0f, 0, 0, 80, 0.7f, 2, 8, 2, 8};
        n60_graph *g = nullptr;
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "build mono/stereo");
        if (!g) continue;
        const size_t n = static_cast<size_t>(rate * 2.0), span = static_cast<size_t>(rate * 0.5);
        // 30 Hz: L = 0.6, R = 0.2 in antiphase-free mix; the mono sum is 0.4 on both lanes.
        std::vector<float> l = tone(n, rate, 30.0, 0.6f), r = tone(n, rate, 30.0, 0.2f), ol, orr;
        run(g, l, r, ol, orr);
        CHECK(std::fabs(amplitude(ol, rate, 30.0, span) - 0.4) < 0.004 && std::fabs(amplitude(orr, rate, 30.0, span) - 0.4) < 0.004,
              "below fc both lanes carry (L+R)/2: %.4f %.4f (rate %.0f)", amplitude(ol, rate, 30.0, span), amplitude(orr, rate, 30.0, span), rate);
        n60_graph_retire(g);
        // 2 kHz in L only: R must stay silent, L untouched in level.
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "rebuild");
        if (!g) continue;
        l = tone(n, rate, 2000.0, 0.5f);
        r.assign(n, 0.0f);
        run(g, l, r, ol, orr);
        CHECK(std::fabs(db(amplitude(ol, rate, 2000.0, span) / 0.5)) < 0.01, "above fc left level (rate %.0f)", rate);
        CHECK(amplitude(orr, rate, 2000.0, span) < 1e-4, "above fc right stays silent (rate %.0f)", rate);
        n60_graph_retire(g);
    }
}

// 5. Negative GAIN inverts polarity exactly; lane polarity composes with OUTPUT_GAIN trim.
static void testPolarity() {
    for (double rate : kRates) {
        const float inv = -1.0f, trim = -0.5f;
        n60_graph *g = nullptr;
        CHECK(buildGraph(rate, {stage(N60_STAGE_GAIN, 1, 0, 0, &inv, 1), stage(N60_STAGE_OUTPUT_GAIN, 2, 1, 0, &trim, 1)}, &g) == N60_STATUS_OK,
              "negative gain builds (rate %.0f)", rate);
        if (!g) continue;
        std::vector<float> l, r, ol, orr;
        signal(l, r, 6000, rate);
        run(g, l, r, ol, orr);
        size_t bad = 0;
        for (size_t i = 3000; i < l.size(); i++) {
            if (ol[i] != -l[i]) bad++;
            if (orr[i] != -0.5f * r[i]) bad++;
        }
        CHECK(bad == 0, "polarity exact after the ramp (rate %.0f): %zu", rate, bad);
        n60_graph_retire(g);
        const float bad1 = -10001.0f;
        CHECK(buildGraph(rate, {stage(N60_STAGE_GAIN, 1, 0, 0, &bad1, 1)}, &g) == N60_STATUS_BAD_ARGUMENT, "gain below -10000 rejected");
    }
}

// 6. Validation: bad trailers, odd lengths and live changes.
static void testValidation() {
    const double rate = 48000;
    n60_graph *g = nullptr;
    const float badFamily[12] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 3, 4, 3, 4};
    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, badFamily, 12)}, &g) == N60_STATUS_BAD_ARGUMENT, "family OFF rejected");
    const float badOrder[12] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 2, 3, 2, 3};
    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, badOrder, 12)}, &g) == N60_STATUS_BAD_ARGUMENT, "odd Linkwitz-Riley order rejected");
    const float zeroOrder[12] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 0, 0, 0, 0};
    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, zeroOrder, 12)}, &g) == N60_STATUS_BAD_ARGUMENT, "order 0 rejected");
    const float ten[10] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 2, 4};
    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, ten, 10)}, &g) == N60_STATUS_BAD_ARGUMENT, "10 params rejected");
    const float good[12] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 1, 3, 1, 3};
    CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, good, 12)}, &g) == N60_STATUS_OK, "Bessel 3 accepted");
    if (g) n60_graph_retire(g);
}

// 7. Crossover then ROOM_FIR equals the offline cascade (crossover output convolved with the taps in double).
static void testRoomFirCoexistence() {
    for (double rate : kRates) {
        const float p[12] = {90.0f, 0, 0, 1.0f, 0, 0, 80, 0.7f, 2, 4, 2, 4};
        std::vector<float> tapsL(48), tapsR(48);
        uint32_t seed = 5;
        for (size_t i = 0; i < 48; i++) {
            seed = seed * 1664525u + 1013904223u;
            tapsL[i] = (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f) * 0.1f * std::exp(-static_cast<float>(i) / 12.0f);
            seed = seed * 1664525u + 1013904223u;
            tapsR[i] = (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f) * 0.1f * std::exp(-static_cast<float>(i) / 12.0f);
        }
        tapsL[0] = tapsR[0] = 1.0f;
        std::vector<float> l, r, xl, xr, ol, orr;
        signal(l, r, 12000, rate);
        n60_graph *g = nullptr;
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "build crossover only");
        if (!g) continue;
        run(g, l, r, xl, xr);
        n60_graph_retire(g);
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12),
                                stage(N60_STAGE_ROOM_FIR, 2, 0, 0, tapsL.data(), 48), stage(N60_STAGE_ROOM_FIR, 3, 1, 0, tapsR.data(), 48)},
                         &g) == N60_STATUS_OK, "build crossover + ROOM_FIR");
        if (!g) continue;
        run(g, l, r, ol, orr);
        double worst = 0;
        for (size_t i = 0; i + 256 < l.size(); i++) {  // the partitioned convolver adds 256 frames of latency
            double aL = 0, aR = 0;
            for (size_t k = 0; k < 48 && k <= i; k++) {
                aL += static_cast<double>(tapsL[k]) * xl[i - k];
                aR += static_cast<double>(tapsR[k]) * xr[i - k];
            }
            worst = std::fmax(worst, std::fmax(std::fabs(aL - ol[i + 256]), std::fabs(aR - orr[i + 256])));
        }
        CHECK(worst < 2e-5, "crossover + ROOM_FIR deviates %.3g from the offline cascade (rate %.0f)", worst, rate);
        n60_graph_retire(g);
    }
}

// 8. Rendering with the trailer allocates nothing.
static void testNoRenderAllocation() {
    for (double rate : kRates) {
        const float p[12] = {100.0f, 0, 0, 1.0f, 0, 0, 80, 0.7f, 0, 8, 1, 8};
        n60_graph *g = nullptr;
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "build alloc graph");
        if (!g) continue;
        std::vector<float> l, r, ol, orr;
        signal(l, r, 4800, rate);
        ol.assign(l.size(), 0.0f);
        orr.assign(l.size(), 0.0f);
        armed.store(true);
        allocs.store(0);
        for (size_t at = 0; at < l.size(); at += kBlock) {
            const float *in[2] = {l.data() + at, r.data() + at};
            float *out[2] = {ol.data() + at, orr.data() + at};
            n60_graph_process(g, in, out, kBlock);
        }
        armed.store(false);
        CHECK(allocs.load() == 0, "render allocated %ld times (rate %.0f)", allocs.load(), rate);
        n60_graph_retire(g);
    }
}

// 7. A live polarity flip ramps monotonically through zero (no overshoot, no step), and the trailer is topology.
static void testLiveFlipAndTrailerTopology() {
    for (double rate : kRates) {
        const float one = 1.0f;
        n60_graph *g = nullptr;
        CHECK(buildGraph(rate, {stage(N60_STAGE_GAIN, 1, 0, 0, &one, 1)}, &g) == N60_STATUS_OK, "flip graph builds");
        if (!g) continue;
        std::vector<float> l(kBlock * 40, 0.5f), r(l.size(), 0.5f), ol, orr;
        const size_t half = kBlock * 4;
        std::vector<float> l1(l.begin(), l.begin() + half), r1(l1.size(), 0.5f), o1, o2;
        run(g, l1, r1, o1, o2);
        const n60_param_record flip = {1, 0, -1.0f, 0};
        CHECK(n60_graph_post_params(g, &flip, 1) == N60_STATUS_OK, "live negative gain accepted");
        run(g, l, r, ol, orr);
        float prev = ol[0];
        bool monotone = true, inRange = true;
        for (size_t i = 0; i < ol.size(); i++) {
            if (ol[i] > prev + 1e-6f) monotone = false;
            if (ol[i] > 0.5f + 1e-6f || ol[i] < -0.5f - 1e-6f) inRange = false;
            prev = ol[i];
        }
        CHECK(monotone && inRange, "flip is monotone and bounded (rate %.0f)", rate);
        CHECK(ol.back() == -0.5f, "flip settles exactly (rate %.0f)", rate);
        n60_graph_retire(g);

        const float p[12] = {100, 0, 0, 1, 0, 0, 80, 0.7f, 2, 4, 2, 4};
        CHECK(buildGraph(rate, {stage(N60_STAGE_STEREO_CROSSOVER, 1, 0, 1, p, 12)}, &g) == N60_STATUS_OK, "trailer graph builds");
        if (!g) continue;
        for (uint32_t k = 8; k < 12; k++) {
            const n60_param_record rec = {1, k, 1.0f, 0};
            CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_UNSUPPORTED, "trailer index %u is topology (rate %.0f)", k, rate);
        }
        n60_graph_retire(g);
    }
}

int main() {
    testNoTrailerBitIdentical();
    testLevelAtCorner();
    testLinkwitzRileySumsFlat();
    testMonoBelowStereoAbove();
    testPolarity();
    testValidation();
    testLiveFlipAndTrailerTopology();
    testRoomFirCoexistence();
    testNoRenderAllocation();
    if (failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::puts("stereo bass: all checks passed");
    return 0;
}
