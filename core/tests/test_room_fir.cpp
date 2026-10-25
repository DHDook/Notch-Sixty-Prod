// E10 S3: behavioural harness for the two-band ROOM_FIR stage (N60_STAGE_ROOM_FIR_TWO_BAND, ABI v15), through the
// C ABI. Reference values are closed forms written here: the direct DFT of the two tap sets plus the declared latency
// (no resampler code is shared with the engine). Every D at the eight standard device rates.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
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
static const uint32_t kDs[] = {1, 2, 4, 8, 16, 32};
static const double kPi = 3.14159265358979323846;

static uint32_t lowLatency(uint32_t D) { return 72u * (D - 1) + 256u * D; }

// Parameter block: D, N, M, full taps, low taps.
static std::vector<float> pack(uint32_t D, const std::vector<float> &full, const std::vector<float> &low) {
    std::vector<float> p = {static_cast<float>(D), static_cast<float>(full.size()), static_cast<float>(low.size())};
    p.insert(p.end(), full.begin(), full.end());
    p.insert(p.end(), low.begin(), low.end());
    return p;
}

static n60_stage_desc stageDesc(uint32_t kind, uint32_t id, const std::vector<float> &p, uint32_t cap, uint64_t mask,
                                uint32_t laneA = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = mask ? 0 : laneA;
    s.capacityFrames = cap;
    s.params = p.empty() ? nullptr : p.data();
    s.paramCount = static_cast<uint32_t>(p.size());
    s.laneMask = mask;
    return s;
}

static n60_graph_desc graphDesc(double rate, uint32_t channels, const n60_stage_desc *st, uint32_t n, uint32_t block = 512) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = block;
    d.inputChannels = d.outputChannels = channels;
    d.stages = st;
    d.stageCount = n;
    return d;
}

// Renders `in` (one channel) through a one-stage graph; returns the output.
static std::vector<float> render(double rate, const std::vector<float> &p, uint32_t cap, const std::vector<float> &in,
                                 uint32_t *latency = nullptr, uint32_t fixedBlock = 512) {
    n60_stage_desc st = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, p, cap, 0, N60_LANE_ALL);
    n60_graph_desc d = graphDesc(rate, 1, &st, 1);
    n60_graph *g = nullptr;
    const n60_status s = n60_graph_build(&d, &g);
    CHECK(s == N60_STATUS_OK, "build status %d", s);
    std::vector<float> out(in.size());
    if (s != N60_STATUS_OK) return out;
    if (latency) *latency = n60_graph_latency_frames(g);
    for (size_t pos = 0; pos < in.size();) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(fixedBlock, in.size() - pos));
        const float *ip = in.data() + pos;
        float *op = out.data() + pos;
        CHECK(n60_graph_process(g, &ip, &op, n) == N60_STATUS_OK, "process");
        pos += n;
    }
    n60_graph_retire(g);
    return out;
}

static std::vector<float> impulse(size_t n) {
    std::vector<float> v(n, 0.0f);
    v[0] = 1.0f;
    return v;
}

static double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 80; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
    }
    return sum;
}

// Low-pass with a Kaiser window: cutoff as a fraction of the sample rate, linear phase, unity DC gain.
static std::vector<float> lowpass(uint32_t m, double cutoff, double beta) {
    std::vector<double> h(m);
    double sum = 0.0;
    for (uint32_t i = 0; i < m; ++i) {
        const double t = i - 0.5 * (m - 1);
        const double sinc = t == 0.0 ? 2 * cutoff : std::sin(2 * kPi * cutoff * t) / (kPi * t);
        const double r = 2.0 * i / (m - 1) - 1.0;
        h[i] = sinc * besselI0(beta * std::sqrt(std::max(0.0, 1 - r * r))) / besselI0(beta);
        sum += h[i];
    }
    std::vector<float> o(m);
    for (uint32_t i = 0; i < m; ++i) o[i] = static_cast<float>(h[i] / sum);
    return o;
}

static std::complex<double> dft(const std::vector<float> &x, double freqPerSample, size_t from = 0) {
    std::complex<double> acc(0, 0);
    for (size_t n = from; n < x.size(); ++n) acc += static_cast<double>(x[n]) * std::polar(1.0, -2 * kPi * freqPerSample * static_cast<double>(n - from));
    return acc;
}

// ---- 1. matches the direct sum of the two bands, 20 Hz to 0.45 fs --------------------------------------------------
static void testEquivalence(double rate, uint32_t D) {
    std::vector<float> full(300, 0.0f);
    full[10] = 0.5f;
    full[100] = -0.25f;
    full[250] = 0.1f;
    const std::vector<float> low = lowpass(200, 0.14, 10.0);
    const std::vector<float> p = pack(D, full, low);
    const uint32_t L = lowLatency(D);
    const size_t len = L + 200 * D + 4096;
    uint32_t reported = 0;
    const std::vector<float> h = render(rate, p, 0, impulse(len), &reported);
    CHECK(reported == L, "rate %.0f D %u: latency %u, expected %u", rate, D, reported, L);
    double maxMag = 0.0;
    std::vector<std::complex<double>> expect;
    std::vector<double> freqs;
    for (int i = 0; i < 80; ++i) {
        const double f = 20.0 * std::pow(0.45 * rate / 20.0, i / 79.0);
        freqs.push_back(f);
        const std::complex<double> hf = dft(full, f / rate);
        // The low band lives below the low rate's Nyquist; the interpolator removes its images above it.
        const std::complex<double> hl = f * D / rate < 0.5 ? dft(low, f * D / rate) : std::complex<double>(0, 0);
        const std::complex<double> e = std::polar(1.0, -2 * kPi * f / rate * L) * (hf + hl);
        expect.push_back(e);
        maxMag = std::max(maxMag, std::abs(e));
    }
    double worst = 0.0;
    for (size_t i = 0; i < freqs.size(); ++i) {
        const double err = std::abs(dft(h, freqs[i] / rate) - expect[i]) / maxMag;
        worst = std::max(worst, err);
    }
    CHECK(worst < 1e-4, "rate %.0f D %u: worst error %.1f dB (limit -80)", rate, D, 20 * std::log10(worst + 1e-30));
}

// ---- 2. exact latency, symmetric low-band kernel ---------------------------------------------------------------------
static void testLatency() {
    for (uint32_t D : kDs) {
        const uint32_t L = lowLatency(D);
        {
            std::vector<float> h = render(48000, pack(D, {1.0f}, {0.0f}), 0, impulse(L + 600));
            size_t peak = 0;
            for (size_t i = 0; i < h.size(); ++i) if (std::fabs(h[i]) > std::fabs(h[peak])) peak = i;
            CHECK(peak == L && std::fabs(h[L] - 1.0f) < 1e-6f, "D %u full path peak at %zu, expected %u", D, peak, L);
            for (size_t i = 0; i < L; ++i) CHECK(h[i] == 0.0f, "D %u pre-latency sample %zu is %g", D, i, h[i]);
        }
        {
            uint32_t reported = 0;
            // A band-limited pulse (below 0.4 of the low rate's Nyquist) through the low path alone comes out delayed by
            // exactly the reported latency minus the declared group delay, to the sample.
            const std::vector<float> pulse = lowpass(128 * D + 1, 0.1 / D, 10.0);
            std::vector<float> in(L + 37 + 1200 + pulse.size(), 0.0f);
            std::copy(pulse.begin(), pulse.end(), in.begin());
            std::vector<float> h = render(48000, pack(D, {0.0f}, {1.0f}), 37, in, &reported);
            CHECK(reported == L + 37, "D %u reported latency %u, expected %u", D, reported, L + 37);
            double worst = 0.0, peak = 0.0;
            for (size_t i = 0; i < pulse.size(); ++i) {
                worst = std::max<double>(worst, std::fabs(h[L + i] - pulse[i]));
                peak = std::max<double>(peak, std::fabs(pulse[i]));
            }
            CHECK(worst < 1e-4 * peak, "D %u low path is not the input delayed by %u frames (error %g of peak %g)", D, L, worst, peak);
        }
    }
}

// ---- 3. aliasing and imaging ------------------------------------------------------------------------------------------
static void testAliasing(double rate, uint32_t D) {
    constexpr size_t W = 8192;
    const uint32_t L = lowLatency(D);
    const size_t skip = L + 2048;
    auto tone = [&](size_t k) {
        std::vector<float> x(skip + W);
        for (size_t n = 0; n < x.size(); ++n) x[n] = 0.5f * static_cast<float>(std::sin(2 * kPi * k * static_cast<double>(n) / W));
        return x;
    };
    // Above 0.6 of the low rate: must not alias back into the band.
    const size_t kAlias = static_cast<size_t>(std::lround(0.68 * W / D));
    if (kAlias > W / 2 - 1) return;
    std::vector<float> y = render(rate, pack(D, {0.0f}, {1.0f}), 0, tone(kAlias));
    double e = 0.0;
    for (size_t n = skip; n < y.size(); ++n) e += double(y[n]) * y[n];
    const double rel = std::sqrt(e / W) / (0.5 / std::sqrt(2.0));
    CHECK(rel < 3.2e-5, "rate %.0f D %u: out-of-band tone leaks at %.1f dB (limit -90)", rate, D, 20 * std::log10(rel + 1e-30));
    // Inside the band: unity gain, and no images (everything but the tone itself stays under -90 dB).
    const size_t kPass = std::max<size_t>(1, static_cast<size_t>(std::lround(0.1 * W / D)));
    y = render(rate, pack(D, {0.0f}, {1.0f}), 0, tone(kPass));
    double sc = 0.0, ss = 0.0, tot = 0.0;
    for (size_t n = 0; n < W; ++n) {
        const double ph = 2 * kPi * kPass * static_cast<double>(n + skip) / W;
        sc += y[skip + n] * std::cos(ph);
        ss += y[skip + n] * std::sin(ph);
        tot += double(y[skip + n]) * y[skip + n];
    }
    const double a = 2.0 * std::sqrt(sc * sc + ss * ss) / W;
    CHECK(std::fabs(a - 0.5) < 5e-4, "rate %.0f D %u: pass-band tone amplitude %.5f", rate, D, a);
    const double resid = std::sqrt(std::max(0.0, tot / W - a * a / 2.0)) / (0.5 / std::sqrt(2.0));
    CHECK(resid < 3.2e-5, "rate %.0f D %u: images at %.1f dB (limit -90)", rate, D, 20 * std::log10(resid + 1e-30));
}

// ---- 4. block-size independence ---------------------------------------------------------------------------------------
static void testBlockIndependence() {
    std::vector<float> full(400), low = lowpass(300, 0.12, 8.0);
    for (size_t i = 0; i < full.size(); ++i) full[i] = 0.01f * static_cast<float>(std::sin(0.3 * i));
    const std::vector<float> p = pack(8, full, low);
    std::vector<float> in(20000);
    uint32_t s = 12345;
    for (float &v : in) { s = s * 1664525u + 1013904223u; v = (static_cast<int>(s >> 9) - 4194304) / 8388608.0f; }
    const std::vector<float> a = render(96000, p, 0, in, nullptr, 512);
    for (uint32_t b : {1u, 7u, 37u, 255u, 256u, 257u}) {
        const std::vector<float> c = render(96000, p, 0, in, nullptr, b);
        CHECK(a == c, "output differs between block 512 and %u", b);
    }
}

// ---- 5. rebuild: crossfade is click-free, an unrelated change carries the state ---------------------------------------------
static void testRebuild() {
    const double rate = 96000;
    const std::vector<float> lowA = lowpass(64, 0.14, 8.0);
    std::vector<float> fullA(64, 0.0f), fullB(64, 0.0f);
    fullA[0] = 0.6f;
    fullB[0] = 0.3f;
    const std::vector<float> pa = pack(8, fullA, lowA), pb = pack(8, fullB, lowA);
    n60_stage_desc sa = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, pa, 0, 0, N60_LANE_ALL);
    n60_stage_desc sb = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, pb, 0, 0, N60_LANE_ALL);
    n60_graph_desc da = graphDesc(rate, 1, &sa, 1), db = graphDesc(rate, 1, &sb, 1);
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build");
    std::vector<float> out;
    auto run = [&](size_t frames) {
        static size_t pos = 0;
        std::vector<float> in(512), o(512);
        for (size_t done = 0; done < frames; done += 512) {
            for (size_t i = 0; i < 512; ++i) in[i] = 0.5f * static_cast<float>(std::sin(2 * kPi * 1000.0 * static_cast<double>(pos++) / rate));
            const float *ip = in.data();
            float *op = o.data();
            n60_graph_process(g, &ip, &op, 512);
            out.insert(out.end(), o.begin(), o.end());
        }
    };
    run(60000);
    const size_t swapAt = out.size();
    CHECK(n60_graph_publish(g, &db) == N60_STATUS_OK, "publish");
    run(60000);
    double steady = 0.0, worst = 0.0;
    for (size_t i = 20000; i < swapAt; ++i) steady = std::max<double>(steady, std::fabs(out[i] - out[i - 1]));
    for (size_t i = swapAt; i < out.size(); ++i) worst = std::max<double>(worst, std::fabs(out[i] - out[i - 1]));
    CHECK(steady > 0.0 && worst < 1.5 * steady, "crossfade step %.5f vs steady %.5f", worst, steady);
    n60_graph_retire(g);

    // An unrelated topology change (a meter appended) with an instant swap: the convolver keeps running, bit for bit.
    n60_stage_desc two[2] = {sa, stageDesc(N60_STAGE_FINAL_METER, 2, {}, 0, 0, N60_LANE_ALL)};
    n60_graph_desc dm = graphDesc(rate, 1, two, 2);
    n60_graph *r = nullptr, *t = nullptr;
    CHECK(n60_graph_build(&da, &r) == N60_STATUS_OK && n60_graph_build(&da, &t) == N60_STATUS_OK, "build pair");
    n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0};
    n60_graph_set_rebuild_options(t, &instant);
    std::vector<float> ref, tst;
    size_t pos = 0;
    for (int blk = 0; blk < 200; ++blk) {
        std::vector<float> in(512), o1(512), o2(512);
        for (size_t i = 0; i < 512; ++i) {
            const double t = static_cast<double>(pos++);
            in[i] = 0.5f * static_cast<float>(std::sin(0.01 * t)) + 0.1f * static_cast<float>(std::sin(0.77 * t));
        }
        const float *ip = in.data();
        float *p1 = o1.data(), *p2 = o2.data();
        if (blk == 100) CHECK(n60_graph_publish(t, &dm) == N60_STATUS_OK, "publish meter");
        n60_graph_process(r, &ip, &p1, 512);
        n60_graph_process(t, &ip, &p2, 512);
        ref.insert(ref.end(), o1.begin(), o1.end());
        tst.insert(tst.end(), o2.begin(), o2.end());
    }
    CHECK(ref == tst, "an unrelated rebuild disturbed the running convolver");
    n60_graph_retire(r);
    n60_graph_retire(t);
}

// ---- 6. reset clears every ring ---------------------------------------------------------------------------------------------
static void testReset() {
    const std::vector<float> p = pack(16, std::vector<float>(300, 0.01f), lowpass(120, 0.14, 8.0));
    n60_stage_desc st = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, p, 0, 0, N60_LANE_ALL);
    n60_graph_desc d = graphDesc(192000, 1, &st, 1);
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build");
    std::vector<float> in(512), o(512);
    uint32_t s = 99;
    double energy = 0.0;
    for (int blk = 0; blk < 60; ++blk) {
        for (float &v : in) { s = s * 1664525u + 1013904223u; v = (static_cast<int>(s >> 9) - 4194304) / 8388608.0f; }
        const float *ip = in.data();
        float *op = o.data();
        n60_graph_process(g, &ip, &op, 512);
        for (float v : o) energy += double(v) * v;
    }
    CHECK(energy > 1.0, "filter produced output before reset (%g)", energy);
    n60_graph_invalidate_history(g);
    std::fill(in.begin(), in.end(), 0.0f);
    bool silent = true;
    for (int blk = 0; blk < 40; ++blk) {
        const float *ip = in.data();
        float *op = o.data();
        n60_graph_process(g, &ip, &op, 512);
        for (float v : o) silent = silent && v == 0.0f;
    }
    CHECK(silent, "output is not silent after n60_graph_invalidate_history");
    n60_graph_retire(g);
}

// ---- 7. allocation-free render, eight lanes, 384 kHz, with a snapshot swap ----------------------------------------------------
static void testAllocationFree() {
    const double rate = 384000;
    const std::vector<float> pa = pack(32, std::vector<float>(8192, 0.0001f), lowpass(900, 0.14, 8.0));
    const std::vector<float> pb = pack(32, std::vector<float>(4000, 0.0002f), lowpass(700, 0.14, 8.0));
    n60_stage_desc sa = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, pa, 100, 0xFF);
    n60_stage_desc sb = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, pb, 100, 0xFF);
    n60_graph_desc da = graphDesc(rate, 8, &sa, 1), db = graphDesc(rate, 8, &sb, 1);
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build");
    std::vector<std::vector<float>> in(8, std::vector<float>(512)), out(8, std::vector<float>(512));
    const float *ip[8];
    float *op[8];
    for (int c = 0; c < 8; ++c) {
        for (size_t i = 0; i < 512; ++i) in[c][i] = 0.2f * static_cast<float>(std::sin(0.03 * i + 0.3 * c));
        ip[c] = in[c].data();
        op[c] = out[c].data();
    }
    for (int round = 0; round < 6; ++round) {
        CHECK(n60_graph_publish(g, (round & 1) ? &da : &db) == N60_STATUS_OK, "publish");
        allocs = 0;
        armed = true;
        for (int k = 0; k < 40; ++k) n60_graph_process(g, ip, op, k == 0 ? 512 : 1 + 13 * k);
        armed = false;
        CHECK(allocs == 0, "round %d: realtime call allocated %ld times", round, allocs.load());
        n60_graph_collect(g);
    }
    n60_graph_invalidate_history(g);
    allocs = 0;
    armed = true;
    n60_graph_process(g, ip, op, 512);
    armed = false;
    CHECK(allocs == 0, "reset path allocated %ld times", allocs.load());
    n60_graph_retire(g);
}

// ---- 8. validation ------------------------------------------------------------------------------------------------------------
static void testValidation() {
    auto status = [](std::vector<float> p, uint32_t cap = 0) {
        n60_stage_desc st = stageDesc(N60_STAGE_ROOM_FIR_TWO_BAND, 1, p, cap, 0, N60_LANE_ALL);
        n60_graph_desc d = graphDesc(48000, 1, &st, 1);
        n60_graph *g = nullptr;
        const n60_status s = n60_graph_build(&d, &g);
        if (s == N60_STATUS_OK) n60_graph_retire(g);
        return s;
    };
    CHECK(status(pack(4, {1.0f}, {1.0f})) == N60_STATUS_OK, "valid block accepted");
    CHECK(status(pack(3, {1.0f}, {1.0f})) == N60_STATUS_BAD_ARGUMENT, "D = 3 refused");
    CHECK(status(pack(64, {1.0f}, {1.0f})) == N60_STATUS_BAD_ARGUMENT, "D = 64 refused");
    CHECK(status(pack(4, {1.0f}, {})) == N60_STATUS_BAD_ARGUMENT, "no low taps refused");
    std::vector<float> bad = pack(4, {1.0f, 2.0f}, {1.0f});
    bad.pop_back();
    CHECK(status(bad) == N60_STATUS_BAD_ARGUMENT, "tap count mismatch refused");
    bad = pack(4, {1.0f}, {1.0f});
    bad[1] = 1.5f;
    CHECK(status(bad) == N60_STATUS_BAD_ARGUMENT, "fractional tap count refused");
    CHECK(status(pack(4, {1.0f}, {1.0f}), N60_GRAPH_MAX_DELAY_FRAMES + 1) == N60_STATUS_BAD_ARGUMENT, "declared delay too large");
}

int main() {
    CHECK(n60_graph_abi_version() == 15u, "ABI v15");
    for (double rate : kRates) {
        for (uint32_t D : kDs) {
            testEquivalence(rate, D);
            if (D > 1) testAliasing(rate, D);
        }
    }
    testEquivalence(12000, 1);
    testLatency();
    testBlockIndependence();
    testRebuild();
    testReset();
    testAllocationFree();
    testValidation();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("room fir: ok");
    return 0;
}
