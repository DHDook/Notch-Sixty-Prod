// E20 S2: scoped flush-to-zero guard for the realtime render path.
//
// Sets subnormal flush-to-zero (and denormals-are-zero on x86) for the lifetime of the guard and restores the
// caller's state on destruction. Replaces the per-sample denormal flushes in the stages.
//   AArch64: FPCR.FZ (bit 24). x86-64: MXCSR FTZ (bit 15) and DAZ (bit 6). Elsewhere: no-op.
// Allocation: none. Synchronisation: none (per-thread register state). Latency: two register moves.
// Rate and channel assumptions: none. Reset: the destructor restores the saved value; nothing persists.
// No -ffast-math: only the hardware mode changes, NaN and Inf handling is untouched.
#pragma once

#include <cstdint>

#if defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
#define N60_FPENV_AARCH64 1
#elif (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#define N60_FPENV_X86 1
#include <xmmintrin.h>
#endif

namespace n60 {

// Raw access, exposed so tests can inspect and perturb the mode. Values are opaque register images.
inline uint64_t fpenvRead() noexcept {
#if defined(N60_FPENV_AARCH64)
    uint64_t v;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(v));
    return v;
#elif defined(N60_FPENV_X86)
    return _mm_getcsr();
#else
    return 0;
#endif
}

inline void fpenvWrite(uint64_t v) noexcept {
#if defined(N60_FPENV_AARCH64)
    __asm__ __volatile__("msr fpcr, %0" : : "r"(v));
#elif defined(N60_FPENV_X86)
    _mm_setcsr(static_cast<unsigned>(v));
#else
    (void)v;
#endif
}

// True when this build can set a flush mode (tests skip the subnormal checks otherwise).
constexpr bool fpenvSupported() noexcept {
#if defined(N60_FPENV_AARCH64) || defined(N60_FPENV_X86)
    return true;
#else
    return false;
#endif
}

// The register bits the guard sets. Tests use this to pre-set the flush mode; writing any other bit is unsafe
// (MXCSR bit 24 is reserved on x86, and a write that sets it faults with #GP, seen as SIGSEGV on Linux).
constexpr uint64_t fpenvFlushMask() noexcept {
#if defined(N60_FPENV_AARCH64)
    return 1ull << 24;
#elif defined(N60_FPENV_X86)
    return (1ull << 15) | (1ull << 6);
#else
    return 0;
#endif
}

class ScopedFlushToZero {
public:
    ScopedFlushToZero() noexcept : saved_(fpenvRead()) {
#if defined(N60_FPENV_AARCH64)
        if ((saved_ & (1ull << 24)) == 0) fpenvWrite(saved_ | (1ull << 24));
#elif defined(N60_FPENV_X86)
        const uint64_t want = saved_ | (1ull << 15) | (1ull << 6);
        if (want != saved_) fpenvWrite(want);
#endif
    }
    ~ScopedFlushToZero() noexcept { fpenvWrite(saved_); }
    ScopedFlushToZero(const ScopedFlushToZero &) = delete;
    ScopedFlushToZero &operator=(const ScopedFlushToZero &) = delete;

private:
    uint64_t saved_;
};

}  // namespace n60
