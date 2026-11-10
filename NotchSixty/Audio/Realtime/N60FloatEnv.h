// E20 S2: flush-to-zero scope for the Core Audio callbacks (C side of core/src/platform/fpenv.hpp).
//
// N60FloatEnvEnterFlushToZero returns the caller's floating-point control word and sets subnormal flush-to-zero
// (AArch64 FPCR.FZ; x86 MXCSR FTZ and DAZ); N60FloatEnvRestore puts the word back. Pair them around a callback body.
// Allocation: none. Synchronisation: none (per-thread register). Latency: two register moves per callback.
// Rate and channel assumptions: none. Reset: Restore returns the thread to its previous mode. No -ffast-math.
#ifndef N60_FLOAT_ENV_H
#define N60_FLOAT_ENV_H

#include <stdint.h>

#if defined(__aarch64__)
static inline uint64_t N60FloatEnvEnterFlushToZero(void) {
    uint64_t saved;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(saved));
    if ((saved & (1ull << 24)) == 0) {
        const uint64_t want = saved | (1ull << 24);
        __asm__ __volatile__("msr fpcr, %0" : : "r"(want));
    }
    return saved;
}
static inline void N60FloatEnvRestore(uint64_t saved) {
    __asm__ __volatile__("msr fpcr, %0" : : "r"(saved));
}
#elif defined(__x86_64__)
#include <xmmintrin.h>
static inline uint64_t N60FloatEnvEnterFlushToZero(void) {
    const unsigned saved = _mm_getcsr();
    _mm_setcsr(saved | 0x8040u);
    return saved;
}
static inline void N60FloatEnvRestore(uint64_t saved) { _mm_setcsr((unsigned)saved); }
#else
static inline uint64_t N60FloatEnvEnterFlushToZero(void) { return 0; }
static inline void N60FloatEnvRestore(uint64_t saved) { (void)saved; }
#endif

#endif
