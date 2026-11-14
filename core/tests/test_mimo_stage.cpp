// E19 S4: behavioural harness for the MIMO treatment graph stage (libn60core ABI v33) through the C ABI at the eight
// standard rates. References are written here: a double-precision direct matrix convolution around the public
// decimate and interpolate calls; closed-form delays, ramps and monitor thresholds.
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
#include "n60/mimo.h"
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




struct Cfg {
    uint32_t S, T, tau;
    std::vector<float> gains, taps;
    float arm = 0.0f, trip = 0.0f;
    uint32_t D = 0;
    std::vector<float> params(double rate) {
        double lr;
        n60_mimo_low_rate(rate, &D, &lr);
        std::vector<float> p(8 + S + size_t(S) * S * T, 0.0f);
        p[0] = float(D); p[1] = float(T); p[2] = float(S); p[3] = float(tau); p[4] = arm; p[5] = trip;
        for (uint32_t s = 0; s < S; ++s) p[8 + s] = gains[s];
        std::memcpy(&p[8 + S], taps.data(), taps.size() * sizeof(float));
        return p;
    }
};

static uint32_t latencyOf(double rate, uint32_t tau) {
    uint32_t D; double lr;
    n60_mimo_low_rate(rate, &D, &lr);
    return 10 * D + tau;
}

// y_s = x_s z^-L + g(n) up(sum_t E_st down(x_t)); returns the delta (before g) per source, length = frames.
static Lanes referenceDelta(double rate, const Lanes &x, const Cfg &c) {
    const uint32_t S = c.S, N = uint32_t(x[0].size());
    uint32_t D; double lr;
    n60_mimo_low_rate(rate, &D, &lr);
    std::vector<std::vector<float>> low(S);
    uint64_t cnt = 0;
    const uint32_t M = (N + D - 1) / D;
    for (uint32_t t = 0; t < S; ++t) {
        low[t].assign(M, 0.0f);
        n60_mimo_decimate(rate, x[t].data(), N, low[t].data(), M, &cnt);
    }
    Lanes d(S, std::vector<float>(N, 0.0f));
    for (uint32_t s = 0; s < S; ++s) {
        std::vector<float> y(M, 0.0f), up(size_t(M) * D);
        for (uint32_t m = 0; m < M; ++m) {
            double a = 0;
            for (uint32_t t = 0; t < S; ++t)
                for (uint32_t j = 0; j < c.T && j <= m; ++j) a += double(c.taps[(size_t(s) * S + t) * c.T + j]) * low[t][m - j];
            y[m] = float(a);
        }
        n60_mimo_interpolate(rate, y.data(), M, up.data(), up.size(), &cnt);
        for (uint32_t i = 0; i < N; ++i) d[s][i] = up[i];
    }
    return d;
}

static n60_graph *buildMimo(double rate, Cfg &c, std::vector<float> &keep, uint32_t extraLanes = 0) {
    keep = c.params(rate);
    const uint32_t ch = c.S + extraLanes;
    uint64_t mask = 0;
    for (uint32_t s = 0; s < c.S; ++s) mask |= uint64_t(1) << s;
    n60_stage_desc st = stg(N60_STAGE_MIMO, 7, 0, keep.data(), uint32_t(keep.size()), mask);
    return build(rate, ch, &st, 1);
}

static double dbRel(const std::vector<float> &a, const std::vector<float> &ref, uint32_t skip) {
    double e = 0, r = 0;
    for (size_t i = skip; i < a.size(); ++i) { const double d = double(a[i]) - ref[i]; e += d * d; r += double(ref[i]) * ref[i]; }
    return 10.0 * std::log10((e + 1e-30) / (r + 1e-30));
}

static void testUnarmedDelay() {
    for (double rate : kRates) {
        Cfg c{2, 8, uint32_t(0.020 * rate), {1.0f, 1.0f}, std::vector<float>(2 * 2 * 8, 0.0f)};
        c.taps[0] = 0.5f;
        std::vector<float> keep;
        n60_graph *g = buildMimo(rate, c, keep);
        const uint32_t L = latencyOf(rate, c.tau);
        CHECK(n60_graph_latency_frames(g) == L, "latency %u vs %u at %.0f", n60_graph_latency_frames(g), L, rate);
        CHECK(double(L) / rate <= 0.0251, "latency %.4f s at %.0f", L / rate, rate);
        const uint32_t N = L + 3000;
        Lanes in = noise(2, N, 11, 0.5f);
        Lanes out = run(g, in, 300);
        bool exact = true;
        for (uint32_t i = 0; i < N; ++i)
            for (uint32_t ch = 0; ch < 2; ++ch) exact &= (out[ch][i] == (i >= L ? in[ch][i - L] : 0.0f));
        CHECK(exact, "unarmed output is not the bit-exact delay by L at %.0f", rate);
        n60_mimo_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        CHECK(n60_graph_read_mimo(g, 7, &rb) == N60_STATUS_OK && rb.latencyFrames == L && rb.state == 0 && rb.sourceCount == 2, "readback");
        n60_graph_retire(g);
    }
}

static void testArmedMatchesReference() {
    const double rates[] = {48000, 96000, 192000, 384000, 44100};
    for (double rate : rates) {
        Cfg c;
        c.S = 3; c.T = 150; c.tau = uint32_t(0.015 * rate);
        c.gains = {20.0f, 20.0f, 20.0f};
        c.taps.assign(size_t(c.S) * c.S * c.T, 0.0f);
        uint32_t seed = 5;
        for (size_t i = 0; i < c.taps.size(); ++i) {
            seed = seed * 1664525u + 1013904223u;
            const uint32_t j = uint32_t(i % c.T);
            c.taps[i] = 0.03f * (float(seed >> 8) / 8388608.0f - 1.0f) * float(std::exp(-double(j) / 40.0));
        }
        c.arm = 1.0f;
        std::vector<float> keep;
        n60_graph *g = buildMimo(rate, c, keep);
        const uint32_t L = latencyOf(rate, c.tau);
        uint32_t Dq = 0;
        double lrq = 0;
        n60_mimo_low_rate(rate, &Dq, &lrq);
        const uint32_t N = uint32_t(5.0 * rate);
        // Low-passed, quiet source so the delta sits inside the decimator pass band.
        Lanes in = noise(3, N, 3, 0.2f);
        for (auto &ch : in) { float z = 0; for (auto &v : ch) { z += 0.05f * (v - z); v = z * 4.0f; } }
        // Disarmed first so the held flag is clear, then arm (the graph starts armed, with g ramping over 3 s).
        Lanes out = run(g, in, 417);
        const Lanes ref = referenceDelta(rate, in, c);
        const uint32_t from = uint32_t(3.2 * rate);  // g == 1 (3 s ramp)
        for (uint32_t s = 0; s < 3; ++s) {
            std::vector<float> got, want;
            for (uint32_t i = from; i < N; ++i) {
                got.push_back(out[s][i] - in[s][i - L]);
                want.push_back(ref[s][i - 10 * Dq]);  // the delta is 10 D late, the direct path L = 10 D + tau (E19 S5)
            }
            const double e = dbRel(got, want, 0);
            CHECK(e < -80.0, "armed delta vs reference %.1f dB (source %u, %.0f)", e, s, rate);
        }
        n60_graph_retire(g);
    }
}

static void testRampAndTrip() {
    const double rate = 48000;
    Cfg c{1, 4, uint32_t(0.015 * rate), {50.0f}, {0.5f, 0, 0, 0}};
    c.arm = 1.0f;
    std::vector<float> keep;
    n60_graph *g = buildMimo(rate, c, keep);
    const uint32_t L = latencyOf(rate, c.tau);
    const uint32_t N = uint32_t(4.0 * rate);
    Lanes in(1, std::vector<float>(N));
    for (uint32_t i = 0; i < N; ++i) in[0][i] = 0.1f * float(std::sin(2.0 * 3.14159265358979 * 200.0 * i / rate));
    // Trip at 3.5 s through a live param.
    uint32_t tripBlock = uint32_t(3.5 * rate) / 480;
    Lanes out = run(g, in, 480, [&](uint32_t b) { if (b == tripBlock) post(g, 7, 5, 1.0f); });
    std::vector<double> env;
    double prev = 0;
    bool monotone = true;
    const uint32_t win = 480;
    for (uint32_t i = L + 100; i + win < uint32_t(3.4 * rate); i += win) {
        double a = 0;
        for (uint32_t k = 0; k < win; ++k) a = std::max(a, std::fabs(double(out[0][i + k]) - in[0][i + k - L]));
        env.push_back(a);
        if (a + 1e-4 < prev) monotone = false;
        prev = a;
    }
    CHECK(monotone, "delta not monotone while arming");
    CHECK(env.front() < 0.3 * env.back(), "arm starts too loud: %g vs %g", env.front(), env.back());
    CHECK(env.back() > 0.02, "no delta at the end of the ramp: %g", env.back());
    // After the trip the delta is gone within the fall plus the stage latency of the tail already in flight.
    const uint32_t after = uint32_t(3.5 * rate) + 480 + uint32_t(0.012 * rate);
    double tail = 0;
    for (uint32_t i = after; i < N; ++i) tail = std::max(tail, std::fabs(double(out[0][i]) - in[0][i - L]));
    CHECK(tail == 0.0, "delta after trip: %g", tail);
    n60_mimo_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.tripCount == 1 && rb.held == 1 && rb.state == 0, "trip readback count %u held %u state %u", rb.tripCount, rb.held, rb.state);
    // Held until the host writes arm = 0 and trip = 0.
    post(g, 7, 5, 0.0f);
    run(g, zeros(1, 960), 480);
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.held == 1, "cleared without disarm");
    post(g, 7, 4, 0.0f);
    run(g, zeros(1, 960), 480);
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.held == 0, "not cleared after disarm");
    n60_graph_retire(g);
}

static void testMonitor() {
    const double rate = 48000;
    const double cases[] = {1.9953 * 1.001, 1.9724};  // amplitude ratio over bound: just over 6 dB, just under (5.9 dB)
    for (double ratio : cases) {
        const bool expectFault = ratio > 1.9953;
        // One source, one tap g: delta = g * x (inside the pass band), bound G = 1.
        Cfg c{1, 1, uint32_t(0.015 * rate), {1.0f}, {float(ratio)}};
        c.arm = 1.0f;
        std::vector<float> keep;
        n60_graph *g = buildMimo(rate, c, keep);
        const uint32_t N = uint32_t(6.0 * rate);
        Lanes in(1, std::vector<float>(N));
        for (uint32_t i = 0; i < N; ++i) in[0][i] = 0.1f * float(std::sin(2.0 * 3.14159265358979 * 100.0 * i / rate));
        run(g, in, 480);
        n60_mimo_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_mimo(g, 7, &rb);
        CHECK((rb.faultLatched == 1) == expectFault, "ratio %.4f: fault %u (expected %d), boundMax %g", ratio, rb.faultLatched, int(expectFault), rb.boundRatioMax[0]);
        if (expectFault) CHECK(rb.faultSource == 1 && rb.held == 1 && rb.faultReason == 1, "fault source/held/reason");
        n60_graph_retire(g);
    }
}

// E19 S5, design note 6 and decision D5: the thermal budget. One source, one tap c: the delta is c times the in-band feed, so the
// delta power over the program power is c^2 exactly. The monitor bound is set far above it, so only the 10 s thermal window can
// fault. -5.9 dB faults when the first 10 s window ends and not before; -6.1 dB never does.
static n60_mimo_readback readMimo(n60_graph *g, uint32_t id = 7) {
    n60_mimo_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_mimo(g, id, &rb);
    return rb;
}

static void testThermalBudget() {
    struct Case { double db; bool trips; };
    const Case cases[] = {{-5.9, true}, {-6.1, false}};
    for (const Case &cs : cases) {
        for (double rate : kRates) {
            if (!cs.trips && rate != 48000 && rate != 384000) continue;
            Cfg c{1, 1, uint32_t(0.015 * rate), {10.0f}, {float(std::pow(10.0, cs.db / 20.0))}};
            c.arm = 1.0f;
            std::vector<float> keep;
            n60_graph *g = buildMimo(rate, c, keep);
            auto chunk = [&](double seconds, uint64_t &pos) {
                const uint32_t N = uint32_t(seconds * rate);
                Lanes in(1, std::vector<float>(N));
                for (uint32_t i = 0; i < N; ++i) in[0][i] = 0.1f * float(std::sin(2.0 * 3.14159265358979 * 100.0 * double(pos + i) / rate));
                pos += N;
                run(g, in, 480);
            };
            uint64_t pos = 0;
            chunk(9.8, pos);
            n60_mimo_readback rb = readMimo(g);
            CHECK(rb.faultLatched == 0, "fs %.0f %.1f dB: fault before the window ends (reason %u)", rate, cs.db, rb.faultReason);
            chunk(cs.trips ? 0.6 : 15.0, pos);
            rb = readMimo(g);
            if (cs.trips) {
                CHECK(rb.faultLatched == 1 && rb.faultReason == 2 && rb.faultSource == 1 && rb.held == 1,
                      "fs %.0f %.1f dB: expected a thermal fault, got latched %u reason %u source %u", rate, cs.db, rb.faultLatched, rb.faultReason, rb.faultSource);
            } else {
                CHECK(rb.faultLatched == 0 && rb.state == 2, "fs %.0f %.1f dB: unexpected fault %u reason %u state %u", rate, cs.db, rb.faultLatched, rb.faultReason, rb.state);
            }
            n60_graph_retire(g);
        }
    }
}

// E19 S6, G18 and S7, G26/G29: the thermal window slides. Taps {c, -c} make the delta gain frequency dependent
// (2 c |sin(pi f / fsLow)|): about 0.19 c at 100 Hz, 1.6 to 1.7 c at 800 Hz. With c set so 800 Hz sits at `db`, a 100 Hz program for
// 5 s then 800 Hz overloads only a window that starts at 5 s: tumbling 10 s windows [0, 10) and [10, 20) each see half of it and
// never trip, the sliding window must. Every standard rate, so both low rates (3 kHz and 2756.25 Hz; at 44.1 and 88.2 kHz the
// 0.1 s bin is 275.6 low-rate samples, rounded to 276).
static double lowRateOf(double rate) {
    const double d = rate < 60000 ? 16 : rate < 120000 ? 32 : rate < 250000 ? 64 : 128;
    return rate / d;
}

static n60_graph *buildSliding(double rate, double db, std::vector<float> &keep) {
    const double fsLow = lowRateOf(rate);
    const float c = float(std::pow(10.0, db / 20.0) / (2.0 * std::sin(3.14159265358979 * 800.0 / fsLow)));
    Cfg cfg{1, 2, uint32_t(0.015 * rate), {10.0f}, {c, -c}};
    cfg.arm = 1.0f;
    return buildMimo(rate, cfg, keep);
}

static void tone(n60_graph *g, double rate, uint64_t &pos, double seconds, double hz) {
    const uint32_t N = uint32_t(seconds * rate);
    Lanes in(1, std::vector<float>(N));
    for (uint32_t i = 0; i < N; ++i) in[0][i] = 0.1f * float(std::sin(2.0 * 3.14159265358979 * hz * double(pos + i) / rate));
    pos += N;
    run(g, in, 480);
}

static void testThermalSlidingWindow() {
    for (double rate : kRates) {
        std::vector<float> keep;
        n60_graph *g = buildSliding(rate, -5.9, keep);
        uint64_t pos = 0;
        tone(g, rate, pos, 5.0, 100.0);
        tone(g, rate, pos, 9.0, 800.0);
        n60_mimo_readback rb = readMimo(g);
        CHECK(rb.faultLatched == 0, "fs %.0f: sliding window faulted before the overload filled a window (reason %u)", rate, rb.faultReason);
        tone(g, rate, pos, 1.5, 800.0);
        rb = readMimo(g);
        CHECK(rb.faultLatched == 1 && rb.faultReason == 2 && rb.faultSource == 1 && rb.held == 1,
              "fs %.0f: a 10 s overload straddling a window boundary must trip: latched %u reason %u", rate, rb.faultLatched, rb.faultReason);
        n60_graph_retire(g);
    }
}

// G29: the same straddling pattern at -6.1 dB never trips, across several window boundaries.
static void testThermalSlidingWindowPasses() {
    for (double rate : kRates) {
        std::vector<float> keep;
        n60_graph *g = buildSliding(rate, -6.1, keep);
        uint64_t pos = 0;
        tone(g, rate, pos, 5.0, 100.0);
        tone(g, rate, pos, 25.0, 800.0);
        const n60_mimo_readback rb = readMimo(g);
        CHECK(rb.faultLatched == 0 && rb.state == 2, "fs %.0f: -6.1 dB across window boundaries must pass: latched %u reason %u state %u",
              rate, rb.faultLatched, rb.faultReason, rb.state);
        n60_graph_retire(g);
    }
}

// G29: the window restarts when g returns to 0. 6 s of overload, a disarm (the 10 ms fade ends at g = 0), a re-arm, then 9.5 s of
// overload: the window never holds 10 s of armed time, so no fault; 1.2 s more completes it and the monitor must trip.
static void testThermalWindowResetsAtZeroGain() {
    for (double rate : kRates) {
        std::vector<float> keep;
        n60_graph *g = buildSliding(rate, -5.9, keep);
        uint64_t pos = 0;
        tone(g, rate, pos, 6.0, 800.0);
        CHECK(post(g, 7, 4, 0.0f) == N60_STATUS_OK, "disarm post");
        tone(g, rate, pos, 0.5, 800.0);
        n60_mimo_readback rb = readMimo(g);
        CHECK(rb.faultLatched == 0 && rb.state == 0, "fs %.0f: disarmed: latched %u state %u", rate, rb.faultLatched, rb.state);
        CHECK(post(g, 7, 4, 1.0f) == N60_STATUS_OK, "re-arm post");
        tone(g, rate, pos, 9.5, 800.0);
        rb = readMimo(g);
        CHECK(rb.faultLatched == 0, "fs %.0f: the window must restart at g = 0 (reason %u)", rate, rb.faultReason);
        tone(g, rate, pos, 1.2, 800.0);
        rb = readMimo(g);
        CHECK(rb.faultLatched == 1 && rb.faultReason == 2, "fs %.0f: a full 10 s of armed overload must trip: latched %u reason %u", rate,
              rb.faultLatched, rb.faultReason);
        n60_graph_retire(g);
    }
}

static void testRebuildMute() {
    const double rate = 48000;
    Cfg c{1, 4, uint32_t(0.015 * rate), {50.0f}, {0.5f, 0, 0, 0}};
    c.arm = 1.0f;
    std::vector<float> keep;
    n60_graph *g = buildMimo(rate, c, keep);
    const uint32_t N = uint32_t(4.0 * rate);
    Lanes in(1, std::vector<float>(N));
    for (uint32_t i = 0; i < N; ++i) in[0][i] = 0.1f * float(std::sin(2.0 * 3.14159265358979 * 200.0 * i / rate));
    run(g, in, 480);
    n60_mimo_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.state == 2 && rb.armGain > 0.99f, "armed before rebuild: state %u g %g", rb.state, rb.armGain);
    // A topology change (a trailing gain) rebuilds: the treatment goes silent and stays so until the host re-arms.
    float gain = 1.0f;
    std::vector<float> keep2 = c.params(rate);
    n60_stage_desc st[2];
    st[0] = stg(N60_STAGE_GAIN, 8, 0, &gain, 1);
    st[1] = stg(N60_STAGE_MIMO, 7, 0, keep2.data(), uint32_t(keep2.size()), 1);
    const n60_graph_desc d = descOf(rate, 1, st, 2);
    const n60_status ps = n60_graph_publish(g, &d);
    CHECK(ps == N60_STATUS_OK, "publish %d", int(ps));
    const uint32_t L = latencyOf(rate, c.tau);
    Lanes out = run(g, in, 480);
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.held == 1 && rb.state == 0, "after rebuild: held %u state %u", rb.held, rb.state);
    double tail = 0;
    for (uint32_t i = uint32_t(1.0 * rate); i < N; ++i) tail = std::max(tail, std::fabs(double(out[0][i]) - in[0][i - L]));
    CHECK(tail == 0.0, "delta after rebuild: %g", tail);
    // Disarm then re-arm: the delta returns.
    post(g, 7, 4, 0.0f);
    run(g, zeros(1, 960), 480);
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.held == 0, "held after disarm");
    post(g, 7, 4, 1.0f);
    run(g, in, 480);
    n60_graph_read_mimo(g, 7, &rb);
    CHECK(rb.state != 0 && rb.armGain > 0.0f, "no re-arm: state %u g %g", rb.state, rb.armGain);
    n60_graph_retire(g);
}

static void testBlockSizeIndependence() {
    const double rate = 48000;
    Cfg c;
    c.S = 2; c.T = 200; c.tau = 700;
    c.gains = {20.0f, 20.0f};
    c.taps.assign(size_t(2) * 2 * c.T, 0.0f);
    for (size_t i = 0; i < c.taps.size(); ++i) c.taps[i] = (float(int((i * 7919) % 13) - 6)) * 0.002f * float(std::exp(-double(i % c.T) / 50.0));
    c.arm = 1.0f;
    Lanes in = noise(2, 60000, 21, 0.1f);
    Lanes ref;
    for (uint32_t block : {512u, 1u, 7u, 64u, 480u}) {
        std::vector<float> keep;
        n60_graph *g = buildMimo(rate, c, keep);
        Lanes o = run(g, in, block);
        if (ref.empty()) ref = o;
        else CHECK(o == ref, "block size %u differs from 512", block);
        n60_graph_retire(g);
    }
}

static void testNoAllocations() {
    const double rate = 96000;
    Cfg c;
    c.S = 8; c.T = 200; c.tau = uint32_t(0.015 * rate);
    c.gains.assign(8, 10.0f);
    c.taps.assign(size_t(8) * 8 * c.T, 0.001f);
    c.arm = 1.0f;
    std::vector<float> keep;
    n60_graph *g = buildMimo(rate, c, keep);
    Lanes in = noise(8, 20000, 9, 0.1f);
    run(g, in, 256, {}, true);
    CHECK(allocs.load() == 0, "allocations in the callback: %ld", allocs.load());
    n60_graph_retire(g);
}

static void testBadDescs() {
    Cfg c{2, 4, 100, {1.0f, 1.0f}, std::vector<float>(16, 0.0f)};
    std::vector<float> p = c.params(48000);
    uint64_t mask = 3;
    n60_graph *g = nullptr;
    n60_stage_desc st = stg(N60_STAGE_MIMO, 7, 0, p.data(), uint32_t(p.size()), mask);
    CHECK(tryBuild(48000, 2, &st, 1, &g) == N60_STATUS_OK, "valid build");
    n60_graph_retire(g);
    std::vector<float> bad = p;
    bad[0] = 32.0f;  // wrong D for the rate
    st = stg(N60_STAGE_MIMO, 7, 0, bad.data(), uint32_t(bad.size()), mask);
    CHECK(tryBuild(48000, 2, &st, 1, &g) != N60_STATUS_OK, "wrong D accepted");
    st = stg(N60_STAGE_MIMO, 7, 0, p.data(), uint32_t(p.size()) - 1, mask);
    CHECK(tryBuild(48000, 2, &st, 1, &g) != N60_STATUS_OK, "short params accepted");
    bad = p;
    bad[8 + 2 + 3] = std::nanf("");
    st = stg(N60_STAGE_MIMO, 7, 0, bad.data(), uint32_t(bad.size()), mask);
    CHECK(tryBuild(48000, 2, &st, 1, &g) != N60_STATUS_OK, "NaN tap accepted");
    st = stg(N60_STAGE_MIMO, 7, 0, p.data(), uint32_t(p.size()), 0);
    CHECK(tryBuild(48000, 2, &st, 1, &g) != N60_STATUS_OK, "empty mask accepted");
}

// ---- N60_STAGE_MIMO_ROUTED (ABI v40, E19 S10) -------------------------------------------------------------------------

struct Routed {
    Cfg c;
    uint32_t W = 0;
    std::vector<uint32_t> in;                  // per source: input position
    std::vector<std::vector<int>> inj;         // per source: injection positions (up to 4)
    float beat = 0.0f, leaseMs = 0.0f;
    std::vector<float> params(double rate) {
        std::vector<float> p = c.params(rate);
        p[6] = beat;
        p[7] = leaseMs;
        for (uint32_t s = 0; s < c.S; ++s) {
            p.push_back(float(in[s]));
            for (uint32_t k = 0; k < 4; ++k) p.push_back(k < inj[s].size() ? float(inj[s][k]) : -1.0f);
        }
        return p;
    }
};

static n60_status tryBuildRouted(double rate, Routed &r, std::vector<float> &keep, n60_graph **g) {
    keep = r.params(rate);
    uint64_t mask = 0;
    for (uint32_t w = 0; w < r.W; ++w) mask |= uint64_t(1) << (w + 2);  // lanes 2.. so the mask is not the first lanes
    n60_stage_desc st = stg(N60_STAGE_MIMO_ROUTED, 9, 0, keep.data(), uint32_t(keep.size()), mask);
    return tryBuild(rate, r.W + 2, &st, 1, g);
}

// Two speakers: A = woofer (0) + tweeter (1); B = two woofers (2, 3) + tweeter (4); position 5 is a matrix-only output.
static Routed twoSpeakers(double rate, float arm) {
    Routed r;
    r.c.S = 2; r.c.T = 120; r.c.tau = uint32_t(0.015 * rate);
    r.c.gains = {20.0f, 20.0f};
    r.c.taps.assign(size_t(2) * 2 * r.c.T, 0.0f);
    uint32_t seed = 17;
    for (size_t i = 0; i < r.c.taps.size(); ++i) {
        seed = seed * 1664525u + 1013904223u;
        r.c.taps[i] = 0.03f * (float(seed >> 8) / 8388608.0f - 1.0f) * float(std::exp(-double(i % r.c.T) / 30.0));
    }
    r.c.arm = arm;
    r.W = 6;
    r.in = {0, 2};
    r.inj = {{0}, {2, 3}};
    return r;
}

static void testRoutedUnarmedAndArmed() {
    for (double rate : kRates) {
        for (int armedRun = 0; armedRun < 2; ++armedRun) {
            if (armedRun == 1 && (rate == 88200 || rate == 176400 || rate == 352800)) continue;  // same four families as the unrouted test
            Routed r = twoSpeakers(rate, armedRun ? 1.0f : 0.0f);
            std::vector<float> keep;
            n60_graph *g = nullptr;
            CHECK(tryBuildRouted(rate, r, keep, &g) == N60_STATUS_OK, "routed build at %.0f", rate);
            if (g == nullptr) continue;
            const uint32_t L = latencyOf(rate, r.c.tau);
            CHECK(n60_graph_latency_frames(g) == L, "routed latency");
            const uint32_t N = armedRun ? uint32_t(4.0 * rate) : L + 3000;
            Lanes x = noise(r.W, N, 5, 0.2f);
            for (auto &ch : x) { float z = 0; for (auto &v : ch) { z += 0.05f * (v - z); v = z * 4.0f; } }
            Lanes in = zeros(r.W + 2, N);
            for (uint32_t w = 0; w < r.W; ++w) in[w + 2] = x[w];
            Lanes out = run(g, in, 417);
            // Reference: each source's delta from its own input lane.
            Cfg c = r.c;
            Lanes src(2);
            src[0] = x[r.in[0]];
            src[1] = x[r.in[1]];
            const Lanes ref = armedRun ? referenceDelta(rate, src, c) : zeros(2, N);
            uint32_t Dq = 0;
            double lr = 0;
            n60_mimo_low_rate(rate, &Dq, &lr);
            const uint32_t from = uint32_t(3.2 * rate);
            for (uint32_t w = 0; w < r.W; ++w) {
                int owner = -1;
                for (uint32_t s = 0; s < 2; ++s)
                    for (int v : r.inj[s]) owner = (uint32_t(v) == w) ? int(s) : owner;
                if (!armedRun || owner < 0) {
                    bool exact = true;
                    for (uint32_t i = 0; i < N; ++i) exact &= (out[w + 2][i] == (i >= L ? x[w][i - L] : 0.0f));
                    CHECK(exact, "routed lane %u is not the bit-exact delay by L (armed %d, %.0f)", w, armedRun, rate);
                } else {
                    std::vector<float> got, want;
                    for (uint32_t i = from; i < N; ++i) {
                        got.push_back(out[w + 2][i] - x[w][i - L]);
                        want.push_back(ref[owner][i - 10 * Dq]);
                    }
                    const double e = dbRel(got, want, 0);
                    CHECK(e < -80.0, "routed delta vs reference %.1f dB (lane %u, %.0f)", e, w, rate);
                }
            }
            // The program lanes of the speakers' injected ways carry the same delta: ways 2 and 3 of speaker B are identical.
            if (armedRun) {
                bool same = true;
                for (uint32_t i = from; i < N; ++i)
                    same &= ((out[4][i] - x[2][i - L]) == (out[5][i] - x[3][i - L])) || std::fabs((out[4][i] - x[2][i - L]) - (out[5][i] - x[3][i - L])) < 1e-5f;
                CHECK(same, "in-band ways of one speaker carry different deltas at %.0f", rate);
            }
            n60_graph_retire(g);
        }
    }
}

static void testRoutedLease() {
    const double rate = 48000;
    for (int beating = 0; beating < 2; ++beating) {
        Routed r = twoSpeakers(rate, 1.0f);
        r.leaseMs = 200.0f;
        std::vector<float> keep;
        n60_graph *g = nullptr;
        CHECK(tryBuildRouted(rate, r, keep, &g) == N60_STATUS_OK, "lease build");
        if (g == nullptr) continue;
        Lanes in = noise(r.W + 2, uint32_t(1.0 * rate), 3, 0.1f);
        run(g, in, 256, [&](uint32_t bi) {
            if (beating) post(g, 9, 6, float(bi % 1000));
        });
        const n60_mimo_readback rb = readMimo(g, 9);
        if (beating) {
            CHECK(rb.faultLatched == 0 && rb.state != 0, "a live heartbeat kept the stage armed (state %u fault %u)", rb.state, rb.faultLatched);
        } else {
            CHECK(rb.faultLatched == 1 && rb.faultReason == 3 && rb.held == 1, "a silent host must latch the lease fault (fault %u reason %u)",
                  rb.faultLatched, rb.faultReason);
        }
        n60_graph_retire(g);
    }
}

static void testRoutedBadDescs() {
    const double rate = 48000;
    auto bad = [&](const char *what, const std::function<void(Routed &)> &edit) {
        Routed r = twoSpeakers(rate, 0.0f);
        edit(r);
        std::vector<float> keep;
        n60_graph *g = nullptr;
        CHECK(tryBuildRouted(rate, r, keep, &g) != N60_STATUS_OK, "routed desc accepted: %s", what);
        if (g != nullptr) n60_graph_retire(g);
    };
    bad("two sources inject one lane", [](Routed &r) { r.inj[1] = {0, 3}; });
    bad("injection beyond the mask", [](Routed &r) { r.inj[0] = {6}; });
    bad("input beyond the mask", [](Routed &r) { r.in[1] = 9; });
    bad("no injection lane", [](Routed &r) { r.inj[0] = {}; });
}

static void testRoutedNoAllocations() {
    const double rate = 384000;
    Routed r;
    r.c.S = 8; r.c.T = 200; r.c.tau = uint32_t(0.015 * rate);
    r.c.gains.assign(8, 10.0f);
    r.c.taps.assign(size_t(8) * 8 * r.c.T, 0.001f);
    r.c.arm = 1.0f;
    r.W = 24;
    for (uint32_t s = 0; s < 8; ++s) {
        r.in.push_back(s * 3);
        r.inj.push_back({int(s * 3), int(s * 3 + 1)});
    }
    std::vector<float> keep;
    n60_graph *g = nullptr;
    CHECK(tryBuildRouted(rate, r, keep, &g) == N60_STATUS_OK, "24 way lane build");
    if (g == nullptr) return;
    Lanes in = noise(26, 40000, 9, 0.1f);
    run(g, in, 256, {}, true);
    CHECK(allocs.load() == 0, "routed allocations in the callback: %ld", allocs.load());
    n60_graph_retire(g);
}

int main() {
    testBadDescs();
    testUnarmedDelay();
    testArmedMatchesReference();
    testRampAndTrip();
    testMonitor();
    testThermalBudget();
    testThermalSlidingWindow();
    testThermalSlidingWindowPasses();
    testThermalWindowResetsAtZeroGain();
    testRebuildMute();
    testBlockSizeIndependence();
    testNoAllocations();
    testRoutedUnarmedAndArmed();
    testRoutedLease();
    testRoutedBadDescs();
    testRoutedNoAllocations();
    if (failures == 0) std::printf("test_mimo_stage: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
