// E20 S4: the portable FFT (SIMD butterflies, real-input packing) and the SIMD convolution kernels.
//
//   test_fft_conv check   complex transforms at every size 2..32768 against a double-precision reference, known tones,
//                         round trips, real transforms against the complex ones (sizes 4..65536), non-finite input
//                         staying inside its own transform.
//   test_fft_conv dump    one hash per case: FFT outputs and a program FIR graph through every convolution segment at the
//                         eight standard rates. ci/run_harnesses.sh builds the core with N60_SIMD=1 and N60_SIMD=0 and
//                         requires the two dumps to be identical.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "fft.hpp"
#include "n60/graph.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

namespace {
using n60::fft::Complex;
constexpr double kPi = 3.14159265358979323846;

struct Rng {
    uint64_t s;
    float next() {
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<float>(static_cast<int32_t>(s >> 33)) / 1073741824.0f - 1.0f;
    }
};
struct Hash {
    uint64_t h = 1469598103934665603ull;
    void addf(float v) { const uint8_t *b = reinterpret_cast<const uint8_t *>(&v); for (int i = 0; i < 4; ++i) { h ^= b[i]; h *= 1099511628211ull; } }
};

// Aligned storage helpers (the plan must be 16-byte aligned).
struct Aligned {
    std::vector<uint8_t> raw;
    uint8_t *p = nullptr;
    explicit Aligned(size_t bytes) : raw(bytes + 16) {
        p = raw.data() + ((16 - reinterpret_cast<uintptr_t>(raw.data()) % 16) % 16);
    }
};

// Double-precision radix-2 reference (independent of the code under test).
void refFft(std::vector<double> &re, std::vector<double> &im, bool inverse) {
    const size_t n = re.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = 2.0 * kPi / static_cast<double>(len) * (inverse ? 1.0 : -1.0);
        for (size_t i = 0; i < n; i += len) {
            for (size_t k = 0; k < len / 2; ++k) {
                const double wr = std::cos(ang * k), wi = std::sin(ang * k);
                const size_t a = i + k, b = i + k + len / 2;
                const double tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr; im[a] += ti;
            }
        }
    }
}

void checkComplex() {
    for (uint32_t n = 2; n <= n60::fft::kMaxSize; n <<= 1) {
        Aligned plan(n60::fft::planBytes(n));
        CHECK(n60::fft::planInit(plan.p, n), "planInit %u", n);
        Rng rng{0x1234ull + n};
        std::vector<Complex> x(n);
        std::vector<double> re(n), im(n);
        for (uint32_t i = 0; i < n; ++i) { x[i] = {rng.next(), rng.next()}; re[i] = x[i].re; im[i] = x[i].im; }
        const std::vector<Complex> orig = x;
        n60::fft::forward(plan.p, x.data());
        refFft(re, im, false);
        double err = 0, ref = 0;
        for (uint32_t i = 0; i < n; ++i) {
            err += (x[i].re - re[i]) * (x[i].re - re[i]) + (x[i].im - im[i]) * (x[i].im - im[i]);
            ref += re[i] * re[i] + im[i] * im[i];
        }
        CHECK(std::sqrt(err / ref) < 3e-6, "forward n=%u rel err %g", n, std::sqrt(err / ref));
        n60::fft::inverse(plan.p, x.data());
        double rt = 0, nrm = 0;
        for (uint32_t i = 0; i < n; ++i) {
            rt += (x[i].re - orig[i].re) * (x[i].re - orig[i].re) + (x[i].im - orig[i].im) * (x[i].im - orig[i].im);
            nrm += orig[i].re * orig[i].re + orig[i].im * orig[i].im;
        }
        CHECK(std::sqrt(rt / nrm) < 3e-6, "round trip n=%u rel err %g", n, std::sqrt(rt / nrm));
    }
    // A complex tone lands in one bin.
    {
        const uint32_t n = 4096, bin = 357;
        Aligned plan(n60::fft::planBytes(n));
        n60::fft::planInit(plan.p, n);
        std::vector<Complex> x(n);
        for (uint32_t i = 0; i < n; ++i) {
            const double ph = 2.0 * kPi * bin * i / n;
            x[i] = {static_cast<float>(std::cos(ph)), static_cast<float>(std::sin(ph))};
        }
        n60::fft::forward(plan.p, x.data());
        for (uint32_t k = 0; k < n; ++k) {
            const double mag = std::hypot(x[k].re, x[k].im);
            if (k == bin) CHECK(std::fabs(mag - n) < 0.05, "tone bin magnitude %g", mag);
            else CHECK(mag < 0.05, "tone leakage bin %u: %g", k, mag);
        }
    }
}

void checkReal() {
    for (uint32_t n = 4; n <= 2 * n60::fft::kMaxSize; n <<= 1) {
        Aligned plan(n60::fft::realPlanBytes(n));
        CHECK(n60::fft::realPlanInit(plan.p, n), "realPlanInit %u", n);
        Rng rng{0x777ull + n};
        std::vector<float> buf(n + 2, 0.0f), orig(n);
        std::vector<double> re(n), im(n, 0.0);
        for (uint32_t i = 0; i < n; ++i) { orig[i] = buf[i] = rng.next(); re[i] = orig[i]; }
        n60::fft::forwardReal(plan.p, buf.data());
        refFft(re, im, false);
        double err = 0, ref = 0;
        for (uint32_t k = 0; k <= n / 2; ++k) {
            const double dr = buf[2 * k] - re[k], di = buf[2 * k + 1] - im[k];
            err += dr * dr + di * di;
            ref += re[k] * re[k] + im[k] * im[k];
        }
        CHECK(std::sqrt(err / ref) < 3e-6, "forwardReal n=%u rel err %g", n, std::sqrt(err / ref));
        CHECK(buf[1] == 0.0f && buf[n + 1] == 0.0f, "DC and Nyquist bins are real (n=%u)", n);
        n60::fft::inverseReal(plan.p, buf.data());
        double rt = 0, nrm = 0;
        for (uint32_t i = 0; i < n; ++i) { rt += (buf[i] - orig[i]) * (buf[i] - orig[i]); nrm += orig[i] * orig[i]; }
        CHECK(std::sqrt(rt / nrm) < 3e-6, "real round trip n=%u rel err %g", n, std::sqrt(rt / nrm));
    }
    // Real tone: bin n/4 + 3 of 1024, amplitude 1 -> magnitude n/2 at the bin, nothing elsewhere.
    {
        const uint32_t n = 1024, bin = 259;
        Aligned plan(n60::fft::realPlanBytes(n));
        n60::fft::realPlanInit(plan.p, n);
        std::vector<float> b(n + 2, 0.0f);
        for (uint32_t i = 0; i < n; ++i) b[i] = static_cast<float>(std::cos(2.0 * kPi * bin * i / n));
        n60::fft::forwardReal(plan.p, b.data());
        for (uint32_t k = 0; k <= n / 2; ++k) {
            const double mag = std::hypot(b[2 * k], b[2 * k + 1]);
            if (k == bin) CHECK(std::fabs(mag - n / 2.0) < 0.05, "real tone magnitude %g", mag);
            else CHECK(mag < 0.05, "real tone leakage bin %u: %g", k, mag);
        }
    }
}

// A non-finite input stays inside its own transform: the next transform with a clean plan and buffer is exact.
void checkNonFinite() {
    const uint32_t n = 512;
    Aligned plan(n60::fft::planBytes(n));
    n60::fft::planInit(plan.p, n);
    std::vector<Complex> bad(n, Complex{0.0f, 0.0f});
    bad[3] = {NAN, INFINITY};
    n60::fft::forward(plan.p, bad.data());
    Rng rng{99};
    std::vector<Complex> x(n);
    for (auto &c : x) c = {rng.next(), rng.next()};
    const std::vector<Complex> o = x;
    n60::fft::forward(plan.p, x.data());
    n60::fft::inverse(plan.p, x.data());
    for (uint32_t i = 0; i < n; ++i) CHECK(std::fabs(x[i].re - o[i].re) < 1e-5f, "plan intact after non-finite input");
}

int dump() {
    for (uint32_t n = 2; n <= n60::fft::kMaxSize; n <<= 2) {
        Aligned plan(n60::fft::planBytes(n));
        n60::fft::planInit(plan.p, n);
        Rng rng{n};
        std::vector<Complex> x(n);
        for (auto &c : x) c = {rng.next(), rng.next()};
        Hash h;
        n60::fft::forward(plan.p, x.data());
        for (auto &c : x) { h.addf(c.re); h.addf(c.im); }
        n60::fft::inverse(plan.p, x.data());
        for (auto &c : x) { h.addf(c.re); h.addf(c.im); }
        std::printf("fft %u %016llx\n", n, static_cast<unsigned long long>(h.h));
    }
    for (uint32_t n = 4; n <= 4096; n <<= 2) {
        Aligned plan(n60::fft::realPlanBytes(n));
        n60::fft::realPlanInit(plan.p, n);
        Rng rng{n + 5};
        std::vector<float> b(n + 2, 0.0f);
        for (uint32_t i = 0; i < n; ++i) b[i] = rng.next();
        Hash h;
        n60::fft::forwardReal(plan.p, b.data());
        for (uint32_t i = 0; i < n + 2; ++i) h.addf(b[i]);
        n60::fft::inverseReal(plan.p, b.data());
        for (uint32_t i = 0; i < n; ++i) h.addf(b[i]);
        std::printf("real %u %016llx\n", n, static_cast<unsigned long long>(h.h));
    }
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const uint32_t tapCounts[] = {200, 3000, 20000};
    for (double rate : rates) {
        for (uint32_t taps : tapCounts) {
            for (uint32_t block : {1u, 64u, 512u}) {
                std::vector<float> t(taps);
                Rng rng{taps};
                for (uint32_t i = 0; i < taps; ++i) t[i] = rng.next() * std::exp(-4.0f * static_cast<float>(i) / static_cast<float>(taps));
                n60_stage_desc s;
                std::memset(&s, 0, sizeof s);
                s.structSize = sizeof s;
                s.kind = N60_STAGE_FIR;
                s.stageId = 1;
                s.laneA = N60_LANE_ALL;
                s.params = t.data();
                s.paramCount = taps;
                n60_graph_desc d{};
                d.structSize = sizeof d;
                d.abiVersion = N60_GRAPH_ABI_VERSION;
                d.sampleRate = rate;
                d.maxBlockFrames = block;
                d.inputChannels = d.outputChannels = 2;
                d.stages = &s;
                d.stageCount = 1;
                n60_graph *g = nullptr;
                if (n60_graph_build(&d, &g) != N60_STATUS_OK) { std::fprintf(stderr, "build\n"); return 1; }
                std::vector<float> in0(block), in1(block), o0(block), o1(block);
                const float *in[2] = {in0.data(), in1.data()};
                float *out[2] = {o0.data(), o1.data()};
                Rng sig{7};
                Hash h;
                const uint32_t total = block == 1 ? 6000 : 30000;
                for (uint32_t pos = 0; pos < total; pos += block) {
                    for (uint32_t i = 0; i < block; ++i) { in0[i] = 0.5f * sig.next(); in1[i] = 0.5f * sig.next(); }
                    if (n60_graph_process(g, in, out, block) != N60_STATUS_OK) { n60_graph_retire(g); return 1; }
                    for (uint32_t i = 0; i < block; ++i) { h.addf(o0[i]); h.addf(o1[i]); }
                }
                n60_graph_retire(g);
                std::printf("fir %g %u %u %016llx\n", rate, taps, block, static_cast<unsigned long long>(h.h));
            }
        }
    }
    return 0;
}
}  // namespace

// E20 G20: complex plan twiddles are stored per stage (n - 1 entries), so a plan is about 10 bytes per point
// (8 for twiddles, 2 for the bit-reversal table). At the largest sizes that stays under 330 KiB per complex plan
// and 500 KiB per real plan (a 65,536-point real transform), small beside the 262,144-tap FIR spectra a snapshot holds.
static void checkPlanMemory() {
    const size_t big = n60::fft::planBytes(n60::fft::kMaxSize);
    const size_t real = n60::fft::realPlanBytes(2 * n60::fft::kMaxSize);
    std::printf("plan bytes: complex %u points %zu, real %u points %zu\n", n60::fft::kMaxSize, big, 2 * n60::fft::kMaxSize, real);
    CHECK(big <= size_t(n60::fft::kMaxSize) * 10 + 256, "complex plan bytes %zu", big);
    CHECK(real <= 500u * 1024u, "real plan bytes %zu", real);
}

int main(int argc, char **argv) {
    const std::string mode = argc > 1 ? argv[1] : "check";
    if (mode == "dump") return dump();
    checkComplex();
    checkReal();
    checkNonFinite();
    checkPlanMemory();
    if (failures == 0) std::printf("fft_conv ok\n");
    return failures == 0 ? 0 : 1;
}
