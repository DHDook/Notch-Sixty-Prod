// libn60core FFT abstraction (E6 S4, design note section 5; E21).
//
// The engine core never calls an Apple framework. Every spectral stage (program FIR,
// spectral denoiser, later convolution) goes through this interface. The portable
// implementation below is a radix-2 decimation-in-time transform in single precision.
// A vDSP-backed implementation can replace fft.cpp on Apple builds without touching
// any stage, as long as it keeps these contracts.
//
// Realtime documentation (docs/REALTIME_RULES.md):
//  - allocation: none. planInit writes into caller-provided memory on the control
//    thread; forward and inverse allocate nothing and touch only plan and data.
//  - synchronisation: none. A plan is immutable after planInit and may be read by one
//    or many threads; the data buffer belongs to the caller.
//  - latency: 0 (in-place, whole buffer).
//  - sample rate: not applicable.
//  - channels: not applicable; one transform per call.
//  - reset: stateless.
#ifndef N60_CORE_FFT_HPP
#define N60_CORE_FFT_HPP

#include <cstddef>
#include <cstdint>

namespace n60::fft {

struct Complex {
    float re;
    float im;
};

constexpr uint32_t kMaxSize = 32768;  // largest transform a plan supports

// Bytes a plan for an n-point transform occupies. n must be a power of two in [2, kMaxSize];
// returns 0 otherwise.
size_t planBytes(uint32_t n);

// Control thread. Builds a plan in `mem` (planBytes(n) bytes, 16-byte aligned).
bool planInit(void *mem, uint32_t n);

// In-place complex transforms of plan->n points. forward is unnormalised
// (X[k] = sum x[j] exp(-2 pi i jk/n)); inverse applies exp(+...) and scales by 1/n,
// so inverse(forward(x)) == x.
void forward(const void *plan, Complex *x);
void inverse(const void *plan, Complex *x);

}  // namespace n60::fft

#endif
