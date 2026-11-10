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

#endif

// Horizontal reductions, fixed order in both builds.
inline float hsum(f32x4 v) { return (lane(v, 0) + lane(v, 1)) + (lane(v, 2) + lane(v, 3)); }
inline float hmax(f32x4 v) {
    const float a = lane(v, 0) > lane(v, 1) ? lane(v, 0) : lane(v, 1);
    const float b = lane(v, 2) > lane(v, 3) ? lane(v, 2) : lane(v, 3);
    return a > b ? a : b;
}
inline double hsum(f64x2 v) { return lane(v, 0) + lane(v, 1); }

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

}  // namespace n60::simd

#endif
