// E9 S1: the non-uniform partitioned FIR engine (core/src/conv/nufir.hpp), tested on its own.
// The engine works in frames only, so these checks do not depend on a sample rate; the graph-level tests in
// test_dsp.c run the same engine at the eight standard rates. Reference: a double-precision FFT convolution
// written here (an independent implementation).
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "conv/nufir.hpp"

using namespace n60::conv;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static double rnd() {  // uniform in [-1, 1)
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (double(rng >> 11) / double(1ull << 52)) * 2.0 - 1.0;
}

struct Engine {
    std::vector<uint8_t> shRaw, laneRaw;
    uint8_t *sh = nullptr, *lane = nullptr;
    Counter ctr;
    Engine(const std::vector<float> &taps) {
        const uint32_t n = static_cast<uint32_t>(taps.size());
        shRaw.assign(sharedBytes(taps.data(), n) + 64, 0);
        laneRaw.assign(laneBytes(taps.data(), n) + 64, 0);
        sh = shRaw.data() + ((64 - (reinterpret_cast<uintptr_t>(shRaw.data()) & 63)) & 63);
        lane = laneRaw.data() + ((64 - (reinterpret_cast<uintptr_t>(laneRaw.data()) & 63)) & 63);
        init(sh, taps.data(), n);
        resetLane(sh, lane, 1);
    }
    void run(float *buf, size_t frames, size_t block) {
        for (size_t i = 0; i < frames; i += block) process(sh, lane, buf + i, uint32_t(std::min(block, frames - i)), &ctr);
    }
};

// ---- double reference ---------------------------------------------------------------------
using cd = std::complex<double>;
static void fftd(std::vector<cd> &a, bool inv) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = 2.0 * M_PI / double(len) * (inv ? 1 : -1);
        const cd wl(std::cos(ang), std::sin(ang));
        for (size_t i = 0; i < n; i += len) {
            cd w(1);
            for (size_t k = 0; k < len / 2; ++k) {
                const cd u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
                w *= wl;
            }
        }
    }
    if (inv) for (auto &x : a) x /= double(n);
}
static std::vector<double> convRef(const std::vector<float> &x, const std::vector<float> &h) {
    size_t n = 1;
    while (n < x.size() + h.size()) n <<= 1;
    std::vector<cd> a(n), b(n);
    for (size_t i = 0; i < x.size(); ++i) a[i] = x[i];
    for (size_t i = 0; i < h.size(); ++i) b[i] = h[i];
    fftd(a, false); fftd(b, false);
    for (size_t i = 0; i < n; ++i) a[i] *= b[i];
    fftd(a, true);
    std::vector<double> y(x.size() + h.size() - 1);
    for (size_t i = 0; i < y.size(); ++i) y[i] = a[i].real();
    return y;
}

static std::vector<float> makeTaps(uint32_t n, int kind) {
    std::vector<float> h(n);
    for (uint32_t i = 0; i < n; ++i) {
        double v = rnd();
        if (kind == 1) v *= std::exp(-6.0 * double(i) / double(n));  // exponentially decaying random filter
        h[i] = float(v * (kind == 0 ? 1.0 / std::sqrt(double(n)) : 0.2));
    }
    if (n > 1 && h[0] == 0.0f) h[0] = 0.01f;
    return h;
}

static void testAccuracyAndLatency() {
    const uint32_t sizes[] = {1, 255, 256, 257, 1024, 1025, 5120, 5121, 32768, 32769, 262144};
    for (uint32_t n : sizes) {
        for (int kind = 0; kind < 2; ++kind) {
            const std::vector<float> h = makeTaps(n, kind);
            const size_t lx = size_t(n) + 2048;
            std::vector<float> x(lx);
            for (auto &v : x) v = float(rnd() * 0.5);
            const std::vector<double> ref = convRef(x, h);
            const size_t total = ref.size() + 512;
            std::vector<float> y(total, 0.0f);
            std::copy(x.begin(), x.end(), y.begin());
            Engine e(h);
            e.run(y.data(), total, 256);
            double es = 0.0, ys = 0.0;
            bool silent = true;
            for (size_t i = 0; i < 256; ++i) silent = silent && y[i] == 0.0f;
            for (size_t i = 0; i < ref.size(); ++i) {
                const double d = double(y[i + 256]) - ref[i];
                es += d * d;
                ys += ref[i] * ref[i];
            }
            const double db = 10.0 * std::log10(es / std::max(ys, 1e-300) + 1e-300);
            CHECK(silent, "taps %u kind %d: output before frame 256 is not silent", n, kind);
            CHECK(db < -110.0, "taps %u kind %d: error %.1f dB re output RMS (limit -110)", n, kind, db);
            std::printf("taps %6u kind %d  error %.1f dB\n", n, kind, db);
        }
    }
    // Latency: an impulse into taps with h[0] != 0 appears at exactly frame 256.
    const std::vector<float> h = makeTaps(5121, 0);
    std::vector<float> y(2048, 0.0f);
    y[0] = 1.0f;
    Engine e(h);
    e.run(y.data(), y.size(), 256);
    size_t first = 0;
    while (first < y.size() && y[first] == 0.0f) ++first;
    CHECK(first == 256, "impulse first nonzero output at %zu, want 256", first);
}

static void testBlockSizes() {
    const uint32_t sizes[] = {5121, 32769, 262144};
    for (uint32_t n : sizes) {
        const std::vector<float> h = makeTaps(n, 1);
        const size_t frames = n == 262144 ? 40000 : 70000;
        std::vector<float> in(frames);
        for (auto &v : in) v = float(rnd());
        std::vector<float> base = in;
        Engine e0(h);
        e0.run(base.data(), frames, 256);
        const size_t blocks[] = {1, 13, 256, 511, 4096};
        for (size_t b : blocks) {
            std::vector<float> out = in;
            Engine e(h);
            e.run(out.data(), frames, b);
            CHECK(std::memcmp(out.data(), base.data(), frames * sizeof(float)) == 0, "taps %u: block %zu differs from block 256", n,
                  b);
        }
    }
}

static void testOperationCounter() {
    const uint32_t n = 262144;
    const std::vector<float> h = makeTaps(n, 1);
    Engine e(h);
    std::vector<float> buf(256);
    // Fill every partition's history (63 spectra, one per 16 ticks), then measure over 10 whole cycles.
    for (int t = 0; t < 1100; ++t) {
        for (auto &v : buf) v = float(rnd());
        e.run(buf.data(), 256, 256);
    }
    e.ctr = Counter();
    for (int t = 0; t < 160; ++t) {
        for (auto &v : buf) v = float(rnd());
        e.run(buf.data(), 256, 256);
    }
    const double mean = double(e.ctr.totalOps) / double(e.ctr.ticks);
    const double ratio = double(e.ctr.worstTick) / mean;
    std::printf("262144 taps: mean %.0f ops/tick, worst %llu, ratio %.2f\n", mean, (unsigned long long)e.ctr.worstTick, ratio);
    CHECK(ratio <= 2.5, "worst tick %.2f x mean at 262144 taps (limit 2.5)", ratio);
}

static void testDelayMode() {
    const uint32_t delays[] = {0, 1, 255, 256, 5119, 262143};
    for (uint32_t d : delays) {
        std::vector<float> h(d + 1, 0.0f);
        h[d] = 1.0f;
        const size_t frames = size_t(d) + 256 + 5000;
        std::vector<float> in(frames), out;
        for (auto &v : in) v = float(rnd());
        out = in;
        Engine e(h);
        e.run(out.data(), frames, 211);
        bool exact = true;
        for (size_t i = 0; i < frames; ++i) {
            const float want = i >= size_t(d) + 256 ? in[i - d - 256] : 0.0f;
            exact = exact && out[i] == want;
        }
        CHECK(exact, "unit impulse at %u is not a bit-exact delay of %u frames", d, d + 256);
        // A reset clears the delay line.
        resetLane(e.sh, e.lane, 2);
        std::vector<float> z(2000, 0.0f);
        e.run(z.data(), z.size(), 256);
        bool zero = true;
        for (float v : z) zero = zero && v == 0.0f;
        CHECK(zero, "delay %u: reset left history behind", d);
    }
    // A scaled impulse is a convolution, not a delay, and is still accurate.
    std::vector<float> h(100, 0.0f);
    h[40] = 0.5f;
    std::vector<float> in(3000), out;
    for (auto &v : in) v = float(rnd());
    out = in;
    Engine e(h);
    e.run(out.data(), out.size(), 256);
    double err = 0.0;
    for (size_t i = 296; i < out.size(); ++i) err = std::max(err, std::fabs(double(out[i]) - 0.5 * in[i - 296]));
    CHECK(err < 1e-6, "scaled impulse error %g", err);
}

static void testReset() {
    const std::vector<float> h = makeTaps(32769, 1);
    Engine e(h);
    std::vector<float> noise(50000);
    for (auto &v : noise) v = float(rnd());
    e.run(noise.data(), noise.size(), 256);
    resetLane(e.sh, e.lane, 2);
    std::vector<float> z(40000, 0.0f);
    e.run(z.data(), z.size(), 300);
    bool zero = true;
    for (float v : z) zero = zero && v == 0.0f;
    CHECK(zero, "reset: output after reset not silent");
    // After a reset the engine matches a fresh one.
    std::vector<float> a(30000), b;
    for (auto &v : a) v = float(rnd());
    b = a;
    resetLane(e.sh, e.lane, 3);  // back to tick 0, as a fresh engine
    Engine fresh(h);
    fresh.run(b.data(), b.size(), 256);
    e.run(a.data(), a.size(), 256);
    CHECK(std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0, "reset: differs from a fresh engine");
}

int main() {
    testAccuracyAndLatency();
    testBlockSizes();
    testOperationCounter();
    testDelayMode();
    testReset();
    if (failures != 0) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("test_conv ok");
    return 0;
}
