// vDSP backend of the FFT contract (E21 S3). Compiled only on Apple (Xcode, or CMake with N60_FFT_BACKEND=vdsp); the
// portable radix-2 transforms in core/src/fft.cpp and core/src/measure/offline_fft.cpp stay compiled and tested beside it.
//
// Realtime documentation (docs/REALTIME_RULES.md), realtime part (n60::fft::vdsp):
//  - allocation: none in forward, inverse, forwardReal, inverseReal. The one process-wide vDSP setup (twiddle tables for every
//    size up to 2^16 real points) is created by the first planInit on a control thread and never freed; plan memory is still
//    caller-provided and holds only a small header that points at that setup.
//  - synchronisation: none on the realtime path. A lock-free compare-exchange publishes the setup; losing the race frees the
//    loser's setup. vDSP setups are read-only after creation and safe to share between threads.
//  - latency 0, in place. Sample rate and channels: not applicable. Reset: stateless.
// The offline double transforms (n60::fft::offline::vdsp) allocate and run off the audio thread only.
#include <Accelerate/Accelerate.h>

#include <atomic>
#include <cstring>

#include "../../src/fft_backend.hpp"

static_assert(sizeof(n60::fft::Complex) == 2 * sizeof(float), "vDSP reads Complex as split complex with stride 2");
static_assert(sizeof(n60::fft::offline::Cplx) == 2 * sizeof(double), "vDSP reads Cplx as split complex with stride 2");

namespace n60::fft::vdsp {
namespace {

constexpr uint32_t kMaxLog2Real = 16;  // real transforms of up to 2 * kMaxSize = 65536 points

struct PlanHeader {
    uint32_t n;      // complex points, or n/2 for a real plan
    uint32_t log2n;  // log2 of the vDSP transform length (complex: n; real: 2 n)
    uint32_t real;
    uint32_t pad;
    FFTSetup setup;
};

std::atomic<FFTSetup> gSetup{nullptr};

FFTSetup sharedSetup() {
    FFTSetup s = gSetup.load(std::memory_order_acquire);
    if (s != nullptr) return s;
    FFTSetup mine = vDSP_create_fftsetup(kMaxLog2Real, kFFTRadix2);
    if (mine == nullptr) return nullptr;
    FFTSetup expected = nullptr;
    if (gSetup.compare_exchange_strong(expected, mine, std::memory_order_acq_rel)) return mine;
    vDSP_destroy_fftsetup(mine);
    return expected;
}

bool validComplex(uint32_t n) { return n >= 2 && n <= kMaxSize && (n & (n - 1)) == 0; }
bool validReal(uint32_t n) { return n >= 4 && n <= 2 * kMaxSize && (n & (n - 1)) == 0; }

uint32_t log2Of(uint32_t n) {
    uint32_t b = 0;
    while ((1u << b) < n) ++b;
    return b;
}

bool initHeader(void *mem, uint32_t points, uint32_t log2n, uint32_t real) {
    if (mem == nullptr) return false;
    FFTSetup s = sharedSetup();
    if (s == nullptr) return false;
    PlanHeader *p = static_cast<PlanHeader *>(mem);
    p->n = points;
    p->log2n = log2n;
    p->real = real;
    p->pad = 0;
    p->setup = s;
    return true;
}

}  // namespace

size_t planBytes(uint32_t n) N60_RT_NONBLOCKING { return validComplex(n) ? sizeof(PlanHeader) : 0; }

bool planInit(void *mem, uint32_t n) {
    if (!validComplex(n)) return false;
    return initHeader(mem, n, log2Of(n), 0);
}

size_t realPlanBytes(uint32_t n) N60_RT_NONBLOCKING { return validReal(n) ? sizeof(PlanHeader) : 0; }

bool realPlanInit(void *mem, uint32_t n) {
    if (!validReal(n)) return false;
    return initHeader(mem, n / 2, log2Of(n), 1);
}

// vDSP reads interleaved complex data as split complex with stride 2: realp at x[0].re, imagp at x[0].im.
void forward(const void *plan, Complex *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    DSPSplitComplex z{&x[0].re, &x[0].im};
    N60_RT_TRUST_BEGIN  // vDSP in-place complex FFT: no allocation, documented thread-safe on a shared setup
    vDSP_fft_zip(p->setup, &z, 2, p->log2n, kFFTDirection_Forward);
    N60_RT_TRUST_END
}

void inverse(const void *plan, Complex *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    DSPSplitComplex z{&x[0].re, &x[0].im};
    const float s = 1.0f / static_cast<float>(p->n);
    N60_RT_TRUST_BEGIN  // as forward
    vDSP_fft_zip(p->setup, &z, 2, p->log2n, kFFTDirection_Inverse);
    N60_RT_TRUST_END
    float *f = reinterpret_cast<float *>(x);
    for (uint32_t i = 0; i < 2 * p->n; ++i) f[i] *= s;
}

// Real transforms. vDSP's packed real format: m = n/2 complex slots z[j] = x[2j] + i x[2j+1] go in, and z[0] comes out as
// (2 X[0], 2 X[m]) with z[k] = 2 X[k] for 0 < k < m. The contract wants n/2 + 1 bins with Nyquist in z[m], unscaled.
void forwardReal(const void *plan, float *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    const uint32_t m = p->n;
    DSPSplitComplex z{x, x + 1};
    N60_RT_TRUST_BEGIN  // as forward
    vDSP_fft_zrip(p->setup, &z, 2, p->log2n, kFFTDirection_Forward);
    N60_RT_TRUST_END
    const float dc = 0.5f * x[0];
    const float nyq = 0.5f * x[1];
    for (uint32_t i = 2; i < 2 * m; ++i) x[i] *= 0.5f;
    x[0] = dc;
    x[1] = 0.0f;
    x[2 * m] = nyq;
    x[2 * m + 1] = 0.0f;
}

void inverseReal(const void *plan, float *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    const uint32_t m = p->n;
    x[1] = x[2 * m];  // pack Nyquist into the imaginary part of bin 0 (the contract ignores both imaginary parts)
    DSPSplitComplex z{x, x + 1};
    N60_RT_TRUST_BEGIN  // as forward
    vDSP_fft_zrip(p->setup, &z, 2, p->log2n, kFFTDirection_Inverse);
    N60_RT_TRUST_END
    const float s = 1.0f / static_cast<float>(2 * m);  // vDSP's real round trip scales by n
    for (uint32_t i = 0; i < 2 * m; ++i) x[i] *= s;
}

}  // namespace n60::fft::vdsp

namespace n60::fft::offline::vdsp {

bool realForward(const double *x, uint64_t n, std::vector<Cplx> &spectrum) {
    if (!validSize(n) || x == nullptr) return false;
    spectrum.clear();
    if (n == 2) {
        spectrum.resize(2);
        spectrum[0] = Cplx{x[0] + x[1], 0.0};
        spectrum[1] = Cplx{x[0] - x[1], 0.0};
        return true;
    }
    const uint64_t m = n / 2;
    uint32_t log2n = 0;
    while ((1ull << log2n) < n) ++log2n;
    FFTSetupD setup = vDSP_create_fftsetupD(log2n, kFFTRadix2);
    if (setup == nullptr) return false;
    spectrum.resize(m + 1);
    // Cplx is two doubles: the first m slots take z[j] = x[2j] + i x[2j+1] and become the packed result.
    for (uint64_t j = 0; j < m; ++j) spectrum[j] = Cplx{x[2 * j], x[2 * j + 1]};
    DSPDoubleSplitComplex z{&spectrum[0].re, &spectrum[0].im};
    vDSP_fft_zripD(setup, &z, 2, log2n, kFFTDirection_Forward);
    vDSP_destroy_fftsetupD(setup);
    const double dc = 0.5 * spectrum[0].re;
    const double nyq = 0.5 * spectrum[0].im;
    for (uint64_t k = 1; k < m; ++k) {
        spectrum[k].re *= 0.5;
        spectrum[k].im *= 0.5;
    }
    spectrum[0] = Cplx{dc, 0.0};
    spectrum[m] = Cplx{nyq, 0.0};
    return true;
}

bool realInverse(const std::vector<Cplx> &spectrum, uint64_t n, std::vector<double> &x) {
    if (!validSize(n) || spectrum.size() != n / 2 + 1) return false;
    x.assign(n, 0.0);
    if (n == 2) {
        x[0] = 0.5 * (spectrum[0].re + spectrum[1].re);
        x[1] = 0.5 * (spectrum[0].re - spectrum[1].re);
        return true;
    }
    const uint64_t m = n / 2;
    uint32_t log2n = 0;
    while ((1ull << log2n) < n) ++log2n;
    FFTSetupD setup = vDSP_create_fftsetupD(log2n, kFFTRadix2);
    if (setup == nullptr) return false;
    std::vector<Cplx> z(spectrum.begin(), spectrum.begin() + static_cast<std::ptrdiff_t>(m));
    z[0].im = spectrum[m].re;  // Nyquist rides in the imaginary part of bin 0
    DSPDoubleSplitComplex sp{&z[0].re, &z[0].im};
    vDSP_fft_zripD(setup, &sp, 2, log2n, kFFTDirection_Inverse);
    vDSP_destroy_fftsetupD(setup);
    const double s = 1.0 / static_cast<double>(n);
    for (uint64_t j = 0; j < m; ++j) {
        x[2 * j] = z[j].re * s;
        x[2 * j + 1] = z[j].im * s;
    }
    return true;
}

}  // namespace n60::fft::offline::vdsp
