// Portable SIMD layer for the engine core (E20 S3, design note 5).
//
// In-house, header-only, no Apple framework and no third-party code. Two builds of one API:
//   N60_SIMD=1 (default)  clang/GCC vector extensions: f32x4 and f64x2 map to NEON on arm64 and SSE2 on x86-64.
//   N60_SIMD=0            a scalar build of the same types (plain arrays and loops, same operation order), used
//                         as the reference by the tests and on a compiler without vector extensions.
// Selection is at compile time; there is no runtime dispatch in v1.
//
// Determinism rules the stages rely on (the SIMD and scalar builds are bit-identical):
//   - Every operation is element-wise and IEEE: add, sub, mul, fma (one rounding), min, max, abs, select.
//   - Horizontal reductions (hsum, hmax) have a fixed tree order: (e0 + e1) + (e2 + e3).
//   - Nothing here reads the rounding mode or relies on -ffast-math; the vector code never lets the compiler
//     contract a * b + c on its own (use fma explicitly).
//
// Realtime: pure functions on registers and caller-owned memory. No allocation, no locks, no exceptions, so every
// function is safe in an audio callback. fma maps to one instruction on arm64 (NEON) and on x86-64 with an FMA target;
// without one the compiler calls libm fma per element (correctly rounded, so results stay bit-identical, but slower: the
// x86 baseline is an open item, see E20 G15). Stage rules: latency 0, no state of its own, rate and channel-count
// independent; stages that pair lanes process an odd last lane with a duplicate and store only the real lane's state,
// so a lane's result equals its single-lane result. Sample rate and channel count assumptions
// belong to the callers; loads and stores are unaligned (memcpy) and have no alignment requirement.
#ifndef N60_SIMD_HPP
#define N60_SIMD_HPP

#include <cmath>
#include <cstdint>
#include <cstring>

#ifndef N60_SIMD
#if defined(__clang__) && defined(__has_builtin)
#if __has_builtin(__builtin_elementwise_fma) && __has_builtin(__builtin_elementwise_abs)
#define N60_SIMD 1
#else
#define N60_SIMD 0
#endif
#else
#define N60_SIMD 0
#endif
#endif

namespace n60::simd {

#if N60_SIMD

typedef float f32x4 __attribute__((vector_size(16)));
typedef double f64x2 __attribute__((vector_size(16)));

constexpr const char *kBackend = "vector-extensions";

inline f32x4 splat4(float x) { return f32x4{x, x, x, x}; }
inline f64x2 splat2(double x) { return f64x2{x, x}; }

inline f32x4 load4(const float *p) { f32x4 v; std::memcpy(&v, p, sizeof v); return v; }
inline void store4(float *p, f32x4 v) { std::memcpy(p, &v, sizeof v); }

inline f32x4 add(f32x4 a, f32x4 b) { return a + b; }
inline f32x4 sub(f32x4 a, f32x4 b) { return a - b; }
inline f32x4 mul(f32x4 a, f32x4 b) { return a * b; }
inline f64x2 add(f64x2 a, f64x2 b) { return a + b; }
inline f64x2 sub(f64x2 a, f64x2 b) { return a - b; }
inline f64x2 mul(f64x2 a, f64x2 b) { return a * b; }

// a * b + c with a single rounding.
inline f32x4 fma(f32x4 a, f32x4 b, f32x4 c) { return __builtin_elementwise_fma(a, b, c); }
inline f64x2 fma(f64x2 a, f64x2 b, f64x2 c) { return __builtin_elementwise_fma(a, b, c); }

inline f32x4 abs(f32x4 a) { return __builtin_elementwise_abs(a); }

// a > b ? x : y per element (false for NaN, as the scalar comparison).
inline f32x4 selectGt(f32x4 a, f32x4 b, f32x4 x, f32x4 y) { return (a > b) ? x : y; }
// max(a, b): a > b ? a : b, so a NaN in a is dropped and a NaN in b propagates (the scalar peak-hold idiom).
inline f32x4 maxGt(f32x4 a, f32x4 b) { return (a > b) ? a : b; }

inline f64x2 toDouble(float lo, float hi) { return f64x2{static_cast<double>(lo), static_cast<double>(hi)}; }
inline f64x2 pair(double lo, double hi) { return f64x2{lo, hi}; }
inline double lane(f64x2 v, int i) { return v[i]; }
inline float lane(f32x4 v, int i) { return v[i]; }

// Interleaved complex helpers (E20 S4): a f32x4 holds two complex values {re0, im0, re1, im1}.
inline f32x4 swapRI(f32x4 a) { return __builtin_shufflevector(a, a, 1, 0, 3, 2); }
inline f32x4 dupRe(f32x4 a) { return __builtin_shufflevector(a, a, 0, 0, 2, 2); }
inline f32x4 dupIm(f32x4 a) { return __builtin_shufflevector(a, a, 1, 1, 3, 3); }
inline f32x4 lowPairDup(f32x4 a) { return __builtin_shufflevector(a, a, 0, 1, 0, 1); }
inline f32x4 highPairDup(f32x4 a) { return __builtin_shufflevector(a, a, 2, 3, 2, 3); }
inline f32x4 make4(float a, float b, float c, float d) { return f32x4{a, b, c, d}; }

#else  // scalar build

struct f32x4 { float e[4]; };
struct f64x2 { double e[2]; };

constexpr const char *kBackend = "scalar";

inline f32x4 splat4(float x) { return f32x4{{x, x, x, x}}; }
inline f64x2 splat2(double x) { return f64x2{{x, x}}; }

inline f32x4 load4(const float *p) { f32x4 v; std::memcpy(&v, p, sizeof v); return v; }
inline void store4(float *p, f32x4 v) { std::memcpy(p, &v, sizeof v); }

#define N60_SIMD_BIN(T, N, NAME, OP) \
    inline T NAME(T a, T b) { T r; for (int i = 0; i < N; ++i) r.e[i] = a.e[i] OP b.e[i]; return r; }
N60_SIMD_BIN(f32x4, 4, add, +)
N60_SIMD_BIN(f32x4, 4, sub, -)
N60_SIMD_BIN(f32x4, 4, mul, *)
N60_SIMD_BIN(f64x2, 2, add, +)
N60_SIMD_BIN(f64x2, 2, sub, -)
N60_SIMD_BIN(f64x2, 2, mul, *)
#undef N60_SIMD_BIN

inline f32x4 fma(f32x4 a, f32x4 b, f32x4 c) { f32x4 r; for (int i = 0; i < 4; ++i) r.e[i] = std::fma(a.e[i], b.e[i], c.e[i]); return r; }
inline f64x2 fma(f64x2 a, f64x2 b, f64x2 c) { f64x2 r; for (int i = 0; i < 2; ++i) r.e[i] = std::fma(a.e[i], b.e[i], c.e[i]); return r; }

inline f32x4 abs(f32x4 a) { f32x4 r; for (int i = 0; i < 4; ++i) r.e[i] = std::fabs(a.e[i]); return r; }

inline f32x4 selectGt(f32x4 a, f32x4 b, f32x4 x, f32x4 y) { f32x4 r; for (int i = 0; i < 4; ++i) r.e[i] = a.e[i] > b.e[i] ? x.e[i] : y.e[i]; return r; }
inline f32x4 maxGt(f32x4 a, f32x4 b) { f32x4 r; for (int i = 0; i < 4; ++i) r.e[i] = a.e[i] > b.e[i] ? a.e[i] : b.e[i]; return r; }

inline f64x2 toDouble(float lo, float hi) { return f64x2{{static_cast<double>(lo), static_cast<double>(hi)}}; }
inline f64x2 pair(double lo, double hi) { return f64x2{{lo, hi}}; }
inline double lane(f64x2 v, int i) { return v.e[i]; }
inline float lane(f32x4 v, int i) { return v.e[i]; }

inline f32x4 swapRI(f32x4 a) { return f32x4{{a.e[1], a.e[0], a.e[3], a.e[2]}}; }
inline f32x4 dupRe(f32x4 a) { return f32x4{{a.e[0], a.e[0], a.e[2], a.e[2]}}; }
inline f32x4 dupIm(f32x4 a) { return f32x4{{a.e[1], a.e[1], a.e[3], a.e[3]}}; }
inline f32x4 lowPairDup(f32x4 a) { return f32x4{{a.e[0], a.e[1], a.e[0], a.e[1]}}; }
inline f32x4 highPairDup(f32x4 a) { return f32x4{{a.e[2], a.e[3], a.e[2], a.e[3]}}; }
inline f32x4 make4(float a, float b, float c, float d) { return f32x4{{a, b, c, d}}; }

#endif

// Horizontal reductions, fixed order in both builds.
inline float hsum(f32x4 v) { return (lane(v, 0) + lane(v, 1)) + (lane(v, 2) + lane(v, 3)); }
inline float hmax(f32x4 v) {
    const float a = lane(v, 0) > lane(v, 1) ? lane(v, 0) : lane(v, 1);
    const float b = lane(v, 2) > lane(v, 3) ? lane(v, 2) : lane(v, 3);
    return a > b ? a : b;
}
inline double hsum(f64x2 v) { return lane(v, 0) + lane(v, 1); }

// Complex product of two interleaved pairs: h * x per complex lane (re = hr xr - hi xi, im = hr xi + hi xr), the real part
// a single fused rounding of xr hr and the exactly negated product xi hi. Identical in both builds.
inline f32x4 cmul(f32x4 h, f32x4 x) {
    const f32x4 t = mul(mul(swapRI(x), dupIm(h)), make4(-1.0f, 1.0f, -1.0f, 1.0f));
    return fma(x, dupRe(h), t);
}
// acc + h * x per complex lane.
inline f32x4 cmac(f32x4 acc, f32x4 h, f32x4 x) { return add(acc, cmul(h, x)); }

// dst = acc + h * x over `bins` interleaved complex bins (float pairs), two bins per step; an odd last bin runs through a
// zero-padded pair. dst may equal acc or x. Every bin gets the same arithmetic as cmac, so the result does not depend on `bins`.
inline void cmacSpan(float *dst, const float *acc, const float *h, const float *x, uint32_t bins) {
    uint32_t k = 0;
    for (; k + 2 <= bins; k += 2) {
        const size_t i = 2 * size_t(k);
        store4(dst + i, cmac(load4(acc + i), load4(h + i), load4(x + i)));
    }
    if (k < bins) {
        const size_t i = 2 * size_t(k);
        const float pa[4] = {acc[i], acc[i + 1], 0.0f, 0.0f}, ph[4] = {h[i], h[i + 1], 0.0f, 0.0f}, px[4] = {x[i], x[i + 1], 0.0f, 0.0f};
        float o[4];
        store4(o, cmac(load4(pa), load4(ph), load4(px)));
        dst[i] = o[0];
        dst[i + 1] = o[1];
    }
}

// Dot product of n floats, n a multiple of 16: four independent f32x4 accumulators (element j goes to accumulator
// (j / 4) % 4), combined as (a0 + a1) + (a2 + a3), then hsum. The same order in both builds.
inline float dot16(const float *a, const float *b, unsigned n) {
    f32x4 a0 = splat4(0.0f), a1 = a0, a2 = a0, a3 = a0;
    for (unsigned i = 0; i < n; i += 16) {
        a0 = fma(load4(a + i), load4(b + i), a0);
        a1 = fma(load4(a + i + 4), load4(b + i + 4), a1);
        a2 = fma(load4(a + i + 8), load4(b + i + 8), a2);
        a3 = fma(load4(a + i + 12), load4(b + i + 12), a3);
    }
    return hsum(add(add(a0, a1), add(a2, a3)));
}

// out[i] *= g for n floats (any n).
inline void scale(float *buf, uint32_t n, float g) {
    const f32x4 gv = splat4(g);
    uint32_t i = 0;
    for (; i + 4 <= n; i += 4) store4(buf + i, mul(load4(buf + i), gv));
    for (; i < n; ++i) buf[i] *= g;
}


// Mix and ramp primitives (E20 S10, G14). Each element gets the same arithmetic in the vector body and the scalar tail
// (std::fma is correctly rounded, as the vector fma), so the result does not depend on n or on the build.
// dst[i] = g * x[i]
inline void mulConst(float *dst, const float *x, float g, uint32_t n) {
    const f32x4 gv = splat4(g);
    uint32_t i = 0;
    for (; i + 4 <= n; i += 4) store4(dst + i, mul(load4(x + i), gv));
    for (; i < n; ++i) dst[i] = g * x[i];
}
// dst[i] = fma(g, x[i], dst[i])
inline void macConst(float *dst, const float *x, float g, uint32_t n) {
    const f32x4 gv = splat4(g);
    uint32_t i = 0;
    for (; i + 4 <= n; i += 4) store4(dst + i, fma(gv, load4(x + i), load4(dst + i)));
    for (; i < n; ++i) dst[i] = std::fma(g, x[i], dst[i]);
}
// dst[i] = g[i] * x[i]; dst may equal x.
inline void mulVec(float *dst, const float *x, const float *g, uint32_t n) {
    uint32_t i = 0;
    for (; i + 4 <= n; i += 4) store4(dst + i, mul(load4(g + i), load4(x + i)));
    for (; i < n; ++i) dst[i] = g[i] * x[i];
}
// dst[i] = fma(g[i], x[i], dst[i])
inline void macVec(float *dst, const float *x, const float *g, uint32_t n) {
    uint32_t i = 0;
    for (; i + 4 <= n; i += 4) store4(dst + i, fma(load4(g + i), load4(x + i), load4(dst + i)));
    for (; i < n; ++i) dst[i] = std::fma(g[i], x[i], dst[i]);
}
// Linear gain ramp as the stages' rampNext, n samples at once: while `remaining` > 0 each sample is
// target - step * (remaining after the decrement), one fused rounding, so the last ramp sample is exactly target;
// afterwards the value holds. Updates cur and remaining as n calls of rampNext would.
inline void rampFill(float *g, float &cur, float target, float step, uint32_t &remaining, uint32_t n) {
    const uint32_t active = remaining < n ? remaining : n;
    const f32x4 ns = splat4(-step), tv = splat4(target);
    uint32_t i = 0;
    for (; i + 4 <= active; i += 4) {
        const float r0 = static_cast<float>(remaining - 1 - i);
        store4(g + i, fma(ns, make4(r0, r0 - 1.0f, r0 - 2.0f, r0 - 3.0f), tv));
    }
    for (; i < active; ++i) g[i] = std::fma(-step, static_cast<float>(remaining - 1 - i), target);
    if (active != 0) {
        cur = g[active - 1];
        remaining -= active;
    }
    for (i = active; i < n; ++i) g[i] = cur;
}

// One transposed direct form II biquad over n samples for a pair of channels at once (E20 S10, G14; the PEQ, XOVER, BASS_MGMT
// and LOUDNESS lane pairs). x[i] holds channel A in element 0 and channel B in element 1. c = {b0, b1, b2, a1, a2}. State is
// (a1z, a2z) for channel A and (*b1z, *b2z) for channel B; b1z null means an odd last channel, whose spare element is a
// throwaway copy of A. Each channel's arithmetic is exactly a single-channel run (fused multiply-adds in both builds), so the
// result does not depend on how channels are paired, on n, or on the build. x is overwritten with the output.
inline void biquadPair(const double *c, double &a1z, double &a2z, double *b1z, double *b2z, f64x2 *x, uint32_t n) {
    const f64x2 b0 = splat2(c[0]), b1 = splat2(c[1]), b2 = splat2(c[2]), na1 = splat2(-c[3]), na2 = splat2(-c[4]);
    f64x2 z1 = pair(a1z, b1z != nullptr ? *b1z : a1z);
    f64x2 z2 = pair(a2z, b2z != nullptr ? *b2z : a2z);
    for (uint32_t i = 0; i < n; ++i) {
        const f64x2 xi = x[i];
        const f64x2 y = fma(b0, xi, z1);
        z1 = fma(na1, y, fma(b1, xi, z2));
        z2 = fma(na2, y, mul(b2, xi));
        x[i] = y;
    }
    a1z = lane(z1, 0);
    a2z = lane(z2, 0);
    if (b1z != nullptr) {
        *b1z = lane(z1, 1);
        *b2z = lane(z2, 1);
    }
}

// Two independent biquads with their own coefficients, one per f64x2 element (E20 S10 part 5: the image widener's low-pass and
// high-pass side chains). ca and cb are {b0, b1, b2, a1, a2}; x[i] holds the input of A in element 0 and of B in element 1;
// state (a1z, a2z) is A's, (b1z, b2z) is B's. Each element's arithmetic is the fused form of biquadPair, so a run does not
// depend on n or on the build. x is overwritten with the output.
inline void biquadDual(const double *ca, const double *cb, double &a1z, double &a2z, double &b1z, double &b2z, f64x2 *x, uint32_t n) {
    const f64x2 b0 = pair(ca[0], cb[0]), b1 = pair(ca[1], cb[1]), b2 = pair(ca[2], cb[2]);
    const f64x2 na1 = pair(-ca[3], -cb[3]), na2 = pair(-ca[4], -cb[4]);
    f64x2 z1 = pair(a1z, b1z), z2 = pair(a2z, b2z);
    for (uint32_t i = 0; i < n; ++i) {
        const f64x2 xi = x[i];
        const f64x2 y = fma(b0, xi, z1);
        z1 = fma(na1, y, fma(b1, xi, z2));
        z2 = fma(na2, y, mul(b2, xi));
        x[i] = y;
    }
    a1z = lane(z1, 0);
    a2z = lane(z2, 0);
    b1z = lane(z1, 1);
    b2z = lane(z2, 1);
}

// One float transposed direct form II biquad for a channel pair (elements 0 and 1 of an f32x4; elements 2 and 3 are unused
// and stay zero), the float-state stages (image harsh, de-esser). c = {b0, b1, b2, a1, a2}; each channel's arithmetic is the
// fused single-channel form, independent of n and the build. x is overwritten with the output.
inline void biquadPairF(const float *c, float &a1z, float &a2z, float &b1z, float &b2z, f32x4 *x, uint32_t n) {
    const f32x4 b0 = splat4(c[0]), b1 = splat4(c[1]), b2 = splat4(c[2]), na1 = splat4(-c[3]), na2 = splat4(-c[4]);
    f32x4 z1 = make4(a1z, b1z, 0.0f, 0.0f), z2 = make4(a2z, b2z, 0.0f, 0.0f);
    for (uint32_t i = 0; i < n; ++i) {
        const f32x4 xi = x[i];
        const f32x4 y = fma(b0, xi, z1);
        z1 = fma(na1, y, fma(b1, xi, z2));
        z2 = fma(na2, y, mul(b2, xi));
        x[i] = y;
    }
    a1z = lane(z1, 0);
    a2z = lane(z2, 0);
    b1z = lane(z1, 1);
    b2z = lane(z2, 1);
}

}  // namespace n60::simd

#endif
