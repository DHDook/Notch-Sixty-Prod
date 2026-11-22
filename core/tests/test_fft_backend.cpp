// E21 S3: the vDSP backend against the in-house backend, behind the one FFT contract (fft_backend.hpp). Apple only.
//   - every complex size 2..32768 and every real size 4..65536: each backend against a double-precision reference, the
//     round trip, and one against the other;
//   - known-tone spectra (a tone lands in its bin and nowhere else);
//   - the offline double transforms at every size 2..2^20 and at 2^24: backend against backend, round trip, direct DFT
//     at small sizes;
//   - forward, inverse, forwardReal and inverseReal of the vDSP backend never call malloc (malloc_logger counts every
//     allocation and free of the process while armed);
//   - ns per transform of both backends, printed for E20.
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "fft_backend.hpp"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

// libsystem_malloc calls this hook for every allocation and free when it is set (declared in the private stack_logging.h).
extern "C" void (*malloc_logger)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);

namespace {
constexpr uint32_t kLogAlloc = 2, kLogDealloc = 4;  // stack_logging_type_alloc, stack_logging_type_dealloc
using n60::fft::Complex;
constexpr double kPi = 3.14159265358979323846;

struct Rng {
    uint64_t s;
    float next() {
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<float>(static_cast<int32_t>(s >> 33)) / 1073741824.0f - 1.0f;
    }
};

struct Aligned {
    std::vector<uint8_t> raw;
    uint8_t *p = nullptr;
    explicit Aligned(size_t bytes) : raw(bytes + 16) {
        p = raw.data() + ((16 - reinterpret_cast<uintptr_t>(raw.data()) % 16) % 16);
    }
};

// Counts allocations made by anything in the process while armed.
std::atomic<long> gMallocs{0};
std::atomic<bool> gArmed{false};
void countingLogger(uint32_t type, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t) {
    if (gArmed.load(std::memory_order_relaxed) && (type & (kLogAlloc | kLogDealloc)) != 0) gMallocs.fetch_add(1);
}

struct Backend {
    const char *name;
    size_t (*planBytes)(uint32_t);
    bool (*planInit)(void *, uint32_t);
    void (*forward)(const void *, Complex *);
    void (*inverse)(const void *, Complex *);
    size_t (*realPlanBytes)(uint32_t);
    bool (*realPlanInit)(void *, uint32_t);
    void (*forwardReal)(const void *, float *);
    void (*inverseReal)(const void *, float *);
};

#define N60_BACKEND(NS)                                                                                                       \
    Backend {                                                                                                                 \
        #NS, [](uint32_t n) -> size_t { return n60::fft::NS::planBytes(n); },                                                \
            [](void *m, uint32_t n) { return n60::fft::NS::planInit(m, n); },                                                \
            [](const void *p, Complex *x) { n60::fft::NS::forward(p, x); },                                                  \
            [](const void *p, Complex *x) { n60::fft::NS::inverse(p, x); },                                                  \
            [](uint32_t n) -> size_t { return n60::fft::NS::realPlanBytes(n); },                                             \
            [](void *m, uint32_t n) { return n60::fft::NS::realPlanInit(m, n); },                                            \
            [](const void *p, float *x) { n60::fft::NS::forwardReal(p, x); },                                                \
            [](const void *p, float *x) { n60::fft::NS::inverseReal(p, x); }                                                 \
    }

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
        for (size_t i = 0; i < n; i += len)
            for (size_t k = 0; k < len / 2; ++k) {
                const double wr = std::cos(ang * k), wi = std::sin(ang * k);
                const size_t a = i + k, b = i + k + len / 2;
                const double tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr; im[a] += ti;
            }
    }
}

double relErr(const std::vector<double> &ar, const std::vector<double> &ai, const std::vector<double> &br, const std::vector<double> &bi) {
    double err = 0, ref = 0;
    for (size_t i = 0; i < ar.size(); ++i) {
        err += (ar[i] - br[i]) * (ar[i] - br[i]) + (ai[i] - bi[i]) * (ai[i] - bi[i]);
        ref += br[i] * br[i] + bi[i] * bi[i];
    }
    return std::sqrt(err / ref);
}

std::vector<std::vector<Complex>> gComplexOut[2];
std::vector<std::vector<float>> gRealOut[2];

void checkComplex(const Backend &b, int slot) {
    gComplexOut[slot].clear();
    for (uint32_t n = 2; n <= n60::fft::kMaxSize; n <<= 1) {
        Aligned plan(b.planBytes(n));
        CHECK(b.planBytes(n) > 0 && b.planInit(plan.p, n), "%s planInit %u", b.name, n);
        Rng rng{0x1234ull + n};
        std::vector<Complex> x(n);
        std::vector<double> re(n), im(n);
        for (uint32_t i = 0; i < n; ++i) { x[i] = {rng.next(), rng.next()}; re[i] = x[i].re; im[i] = x[i].im; }
        const std::vector<Complex> orig = x;
        b.forward(plan.p, x.data());
        gComplexOut[slot].push_back(x);
        refFft(re, im, false);
        std::vector<double> xr(n), xi(n);
        for (uint32_t i = 0; i < n; ++i) { xr[i] = x[i].re; xi[i] = x[i].im; }
        CHECK(relErr(xr, xi, re, im) < 3e-6, "%s forward n=%u rel err %g", b.name, n, relErr(xr, xi, re, im));
        b.inverse(plan.p, x.data());
        double rt = 0, nrm = 0;
        for (uint32_t i = 0; i < n; ++i) {
            rt += (x[i].re - orig[i].re) * (x[i].re - orig[i].re) + (x[i].im - orig[i].im) * (x[i].im - orig[i].im);
            nrm += orig[i].re * orig[i].re + orig[i].im * orig[i].im;
        }
        CHECK(std::sqrt(rt / nrm) < 3e-6, "%s round trip n=%u rel err %g", b.name, n, std::sqrt(rt / nrm));
    }
    // A complex tone lands in one bin.
    const uint32_t n = 4096, bin = 357;
    Aligned plan(b.planBytes(n));
    b.planInit(plan.p, n);
    std::vector<Complex> x(n);
    for (uint32_t i = 0; i < n; ++i) {
        const double ph = 2.0 * kPi * bin * i / n;
        x[i] = {static_cast<float>(std::cos(ph)), static_cast<float>(std::sin(ph))};
    }
    b.forward(plan.p, x.data());
    for (uint32_t k = 0; k < n; ++k) {
        const double mag = std::hypot(x[k].re, x[k].im);
        if (k == bin) CHECK(std::fabs(mag - n) < 0.05, "%s tone bin magnitude %g", b.name, mag);
        else CHECK(mag < 0.05, "%s tone leakage bin %u: %g", b.name, k, mag);
    }
}

void checkReal(const Backend &b, int slot) {
    gRealOut[slot].clear();
    for (uint32_t n = 4; n <= 2 * n60::fft::kMaxSize; n <<= 1) {
        Aligned plan(b.realPlanBytes(n));
        CHECK(b.realPlanBytes(n) > 0 && b.realPlanInit(plan.p, n), "%s realPlanInit %u", b.name, n);
        Rng rng{0x9999ull + n};
        std::vector<float> buf(n + 2, 0.0f), orig(n);
        std::vector<double> re(n), im(n, 0.0);
        for (uint32_t i = 0; i < n; ++i) { buf[i] = rng.next(); orig[i] = buf[i]; re[i] = buf[i]; }
        b.forwardReal(plan.p, buf.data());
        gRealOut[slot].push_back(buf);
        refFft(re, im, false);
        double err = 0, ref = 0;
        for (uint32_t k = 0; k <= n / 2; ++k) {
            err += (buf[2 * k] - re[k]) * (buf[2 * k] - re[k]) + (buf[2 * k + 1] - im[k]) * (buf[2 * k + 1] - im[k]);
            ref += re[k] * re[k] + im[k] * im[k];
        }
        CHECK(std::sqrt(err / ref) < 3e-6, "%s real forward n=%u rel err %g", b.name, n, std::sqrt(err / ref));
        b.inverseReal(plan.p, buf.data());
        double rt = 0, nrm = 0;
        for (uint32_t i = 0; i < n; ++i) { rt += (buf[i] - orig[i]) * (buf[i] - orig[i]); nrm += orig[i] * orig[i]; }
        CHECK(std::sqrt(rt / nrm) < 3e-6, "%s real round trip n=%u rel err %g", b.name, n, std::sqrt(rt / nrm));
    }
    // A real tone: bin magnitude n/2 and no leakage.
    const uint32_t n = 8192, bin = 611;
    Aligned plan(b.realPlanBytes(n));
    b.realPlanInit(plan.p, n);
    std::vector<float> x(n + 2, 0.0f);
    for (uint32_t i = 0; i < n; ++i) x[i] = static_cast<float>(std::cos(2.0 * kPi * bin * i / n));
    b.forwardReal(plan.p, x.data());
    for (uint32_t k = 0; k <= n / 2; ++k) {
        const double mag = std::hypot(x[2 * k], x[2 * k + 1]);
        if (k == bin) CHECK(std::fabs(mag - n / 2) < 0.05, "%s real tone bin magnitude %g", b.name, mag);
        else CHECK(mag < 0.05, "%s real tone leakage bin %u: %g", b.name, k, mag);
    }
}

void compareBackends() {
    // The two backends agree to float rounding at every size.
    for (size_t i = 0; i < gComplexOut[0].size(); ++i) {
        const auto &a = gComplexOut[0][i];
        const auto &c = gComplexOut[1][i];
        std::vector<double> ar(a.size()), ai(a.size()), br(a.size()), bi(a.size());
        for (size_t k = 0; k < a.size(); ++k) { ar[k] = a[k].re; ai[k] = a[k].im; br[k] = c[k].re; bi[k] = c[k].im; }
        CHECK(relErr(ar, ai, br, bi) < 6e-6, "complex n=%zu vdsp vs portable %g", a.size(), relErr(ar, ai, br, bi));
    }
    for (size_t i = 0; i < gRealOut[0].size(); ++i) {
        const auto &a = gRealOut[0][i];
        const auto &c = gRealOut[1][i];
        double err = 0, ref = 0;
        for (size_t k = 0; k < a.size(); ++k) { err += (a[k] - c[k]) * (a[k] - c[k]); ref += c[k] * c[k]; }
        CHECK(std::sqrt(err / ref) < 6e-6, "real size index %zu vdsp vs portable %g", i, std::sqrt(err / ref));
    }
}

void checkNoAllocation() {
    {   // The hook sees allocations: a deliberate one must be counted, or a zero below would prove nothing.
        malloc_logger = countingLogger;
        gMallocs.store(0);
        gArmed.store(true);
        void *volatile probe = std::malloc(4096);
        probe = std::realloc(probe, 8192);
        std::free(probe);
        gArmed.store(false);
        malloc_logger = nullptr;
        CHECK(gMallocs.load() >= 1, "malloc_logger did not see a deliberate malloc");
    }
    const Backend b = N60_BACKEND(vdsp);
    const uint32_t sizes[] = {2, 4, 64, 1024, 32768};
    for (uint32_t n : sizes) {
        Aligned plan(b.planBytes(n));
        b.planInit(plan.p, n);
        std::vector<Complex> x(n, Complex{0.25f, -0.5f});
        const uint32_t rn = n < 2 ? 4 : 2 * n;
        Aligned rplan(b.realPlanBytes(rn));
        b.realPlanInit(rplan.p, rn);
        std::vector<float> r(rn + 2, 0.125f);
        malloc_logger = countingLogger;
        gMallocs.store(0);
        gArmed.store(true);
        b.forward(plan.p, x.data());
        b.inverse(plan.p, x.data());
        b.forwardReal(rplan.p, r.data());
        b.inverseReal(rplan.p, r.data());
        gArmed.store(false);
        malloc_logger = nullptr;
        CHECK(gMallocs.load() == 0, "vdsp transforms of size %u allocated %ld times", n, gMallocs.load());
    }
}

void logTiming(const Backend &b) {
    for (uint32_t n : {256u, 4096u, 32768u}) {
        Aligned plan(b.planBytes(n));
        b.planInit(plan.p, n);
        std::vector<Complex> x(n, Complex{0.1f, 0.2f});
        const int reps = n >= 32768 ? 200 : 2000;
        const auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < reps; ++i) { b.forward(plan.p, x.data()); b.inverse(plan.p, x.data()); }
        const auto t1 = std::chrono::steady_clock::now();
        const double ns = std::chrono::duration<double, std::nano>(t1 - t0).count() / (2.0 * reps);
        std::printf("fft_ns %-8s complex n=%-6u %10.0f ns per transform\n", b.name, n, ns);
    }
}

// ---- offline double transforms ----
double offlineErr(const std::vector<n60::fft::offline::Cplx> &a, const std::vector<n60::fft::offline::Cplx> &b) {
    double err = 0, ref = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        err += (a[i].re - b[i].re) * (a[i].re - b[i].re) + (a[i].im - b[i].im) * (a[i].im - b[i].im);
        ref += b[i].re * b[i].re + b[i].im * b[i].im;
    }
    return std::sqrt(err / ref);
}

void checkOffline() {
    using namespace n60::fft::offline;
    uint64_t state = 4242;
    auto rnd = [&]() {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27;
        return static_cast<double>((state * 0x2545F4914F6CDD1Dull) >> 11) / 9007199254740992.0 * 2.0 - 1.0;
    };
    std::vector<uint64_t> sizes;
    for (uint64_t n = 2; n <= (1ull << 20); n <<= 1) sizes.push_back(n);
    sizes.push_back(1ull << 24);
    for (uint64_t n : sizes) {
        std::vector<double> x(n);
        for (double &v : x) v = rnd();
        std::vector<Cplx> sv, sp;
        CHECK(vdsp::realForward(x.data(), n, sv) && portable::realForward(x.data(), n, sp), "offline forward %llu", (unsigned long long)n);
        if (sv.size() != n / 2 + 1 || sp.size() != n / 2 + 1) { CHECK(false, "offline spectrum size %llu", (unsigned long long)n); continue; }
        CHECK(offlineErr(sv, sp) < 1e-12, "offline n=%llu vdsp vs portable %g", (unsigned long long)n, offlineErr(sv, sp));
        CHECK(sv[0].im == 0.0 && sv[n / 2].im == 0.0, "offline n=%llu edge bins must be real", (unsigned long long)n);
        if (n <= 256) {  // direct DFT
            for (uint64_t k = 0; k <= n / 2; ++k) {
                double re = 0, im = 0;
                for (uint64_t j = 0; j < n; ++j) {
                    const double ang = -2.0 * kPi * static_cast<double>(j * k % n) / static_cast<double>(n);
                    re += x[j] * std::cos(ang);
                    im += x[j] * std::sin(ang);
                }
                CHECK(std::fabs(re - sv[k].re) < 1e-10 && std::fabs(im - sv[k].im) < 1e-10, "offline n=%llu bin %llu direct DFT", (unsigned long long)n, (unsigned long long)k);
            }
        }
        std::vector<double> back;
        CHECK(vdsp::realInverse(sv, n, back), "offline inverse %llu", (unsigned long long)n);
        double worst = 0;
        for (uint64_t i = 0; i < n && i < back.size(); ++i) worst = std::fmax(worst, std::fabs(back[i] - x[i]));
        CHECK(back.size() == n && worst < 1e-12, "offline n=%llu round trip %g", (unsigned long long)n, worst);
    }
    // A tone lands in one bin.
    {
        const uint64_t n = 65536, bin = 1234;
        std::vector<double> x(n);
        for (uint64_t i = 0; i < n; ++i) x[i] = std::cos(2.0 * kPi * static_cast<double>(bin * i % n) / static_cast<double>(n));
        std::vector<Cplx> s;
        vdsp::realForward(x.data(), n, s);
        for (uint64_t k = 0; k <= n / 2; ++k) {
            const double mag = std::hypot(s[k].re, s[k].im);
            if (k == bin) CHECK(std::fabs(mag - n / 2.0) < 1e-6, "offline tone bin %g", mag);
            else CHECK(mag < 1e-6, "offline tone leakage bin %llu: %g", (unsigned long long)k, mag);
        }
    }
    // The public contract forwards to vDSP in this build.
    {
        std::vector<double> x(1024);
        for (double &v : x) v = rnd();
        std::vector<Cplx> pub, v;
        realForward(x.data(), x.size(), pub);
        vdsp::realForward(x.data(), x.size(), v);
        CHECK(offlineErr(pub, v) == 0.0, "public offline realForward is not the vdsp backend");
    }
}
}  // namespace

int main() {
    const Backend vd = N60_BACKEND(vdsp);
    const Backend po = N60_BACKEND(portable);
    checkComplex(vd, 0);
    checkComplex(po, 1);
    checkReal(vd, 0);
    checkReal(po, 1);
    compareBackends();
    checkNoAllocation();
    logTiming(vd);
    logTiming(po);
    checkOffline();
    if (failures == 0) std::printf("fft_backend ok\n");
    return failures == 0 ? 0 : 1;
}
