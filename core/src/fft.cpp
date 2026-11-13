// libn60core portable FFT (E6 S4). See fft.hpp for the contracts and realtime notes.
#include "fft.hpp"

#include <cmath>
#include <cstring>

#include "simd/simd.hpp"

namespace n60::fft {
namespace {

struct PlanHeader {
    uint32_t n;
    uint32_t log2n;
    uint32_t pad[2];
};

constexpr double kPi = 3.14159265358979323846;

size_t alignUp16(size_t v) { return (v + 15) & ~size_t(15); }

uint32_t bitsOf(uint32_t n) {
    uint32_t b = 0;
    while ((1u << b) < n) ++b;
    return b;
}

bool validSize(uint32_t n) { return n >= 2 && n <= kMaxSize && (n & (n - 1)) == 0; }

const uint16_t *bitrevOf(const PlanHeader *p) {
    return reinterpret_cast<const uint16_t *>(reinterpret_cast<const uint8_t *>(p) + sizeof(PlanHeader));
}
const Complex *twiddlesOf(const PlanHeader *p) {
    return reinterpret_cast<const Complex *>(reinterpret_cast<const uint8_t *>(p) + sizeof(PlanHeader) +
                                             alignUp16(size_t(p->n) * sizeof(uint16_t)));
}

// Twiddles are stored per stage so every butterfly pass reads them contiguously: the stage with `half` butterflies per
// group keeps w^(k n/len), k < half, at index half - 1 + k (n - 1 entries in all).
template <bool Inverse>
void transform(const void *plan, Complex *x) {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    const uint32_t n = p->n;
    const uint16_t *rev = bitrevOf(p);
    const Complex *tw = twiddlesOf(p);
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t j = rev[i];
        if (j > i) {
            const Complex t = x[i];
            x[i] = x[j];
            x[j] = t;
        }
    }
    float *f = reinterpret_cast<float *>(x);
    const float *wf = reinterpret_cast<const float *>(tw);
    using namespace simd;
    // len 2: twiddle 1, one butterfly per complex pair held in a vector.
    const f32x4 sgn2 = make4(1.0f, 1.0f, -1.0f, -1.0f);
    for (uint32_t i = 0; i < n; i += 2) {
        const f32x4 v = load4(f + 2 * size_t(i));
        store4(f + 2 * size_t(i), add(lowPairDup(v), mul(highPairDup(v), sgn2)));
    }
    const f32x4 conj = make4(1.0f, -1.0f, 1.0f, -1.0f);
    // Remaining stages (half = 2 .. n/2), two at a time: a fused four-point pass (radix-2^2) keeps both butterfly layers in
    // registers, halving the memory passes. The arithmetic of each butterfly is exactly the radix-2 stage's, so results are
    // bit-identical to running the stages one by one. An odd stage count runs its first stage alone.
    uint32_t half = 2;
    auto twid = [&](const float *w) {
        f32x4 wv = load4(w);
        if (Inverse) wv = mul(wv, conj);
        return wv;
    };
    if ((bitsOf(n) - 1) & 1u) {
        const float *w = wf + 2 * size_t(half - 1);
        for (uint32_t base = 0; base < n; base += 2 * half) {
            float *pa = f + 2 * size_t(base);
            float *pb = pa + 2 * size_t(half);
            for (uint32_t k = 0; k < half; k += 2) {
                const f32x4 wv = twid(w + 2 * size_t(k));
                const f32x4 a = load4(pa + 2 * size_t(k));
                const f32x4 t = cmul(wv, load4(pb + 2 * size_t(k)));
                store4(pb + 2 * size_t(k), sub(a, t));
                store4(pa + 2 * size_t(k), add(a, t));
            }
        }
        half <<= 1;
    }
    for (; half < n; half <<= 2) {
        const uint32_t h2 = half << 1;
        const float *w1 = wf + 2 * size_t(half - 1);   // first layer, k < half
        const float *w2 = wf + 2 * size_t(h2 - 1);     // second layer, k < 2 half
        for (uint32_t base = 0; base < n; base += 4 * half) {
            float *pA = f + 2 * size_t(base);
            float *pB = pA + 2 * size_t(half);
            float *pC = pB + 2 * size_t(half);
            float *pD = pC + 2 * size_t(half);
            for (uint32_t k = 0; k < half; k += 2) {
                const size_t o = 2 * size_t(k);
                const f32x4 wa = twid(w1 + o);
                const f32x4 wc = twid(w2 + o);
                const f32x4 wd = twid(w2 + o + 2 * size_t(half));
                const f32x4 a = load4(pA + o), c = load4(pC + o);
                const f32x4 tb = cmul(wa, load4(pB + o));
                const f32x4 td = cmul(wa, load4(pD + o));
                const f32x4 a1 = add(a, tb), b1 = sub(a, tb);
                const f32x4 c1 = add(c, td), d1 = sub(c, td);
                const f32x4 tc = cmul(wc, c1);
                const f32x4 tdd = cmul(wd, d1);
                store4(pC + o, sub(a1, tc));
                store4(pA + o, add(a1, tc));
                store4(pD + o, sub(b1, tdd));
                store4(pB + o, add(b1, tdd));
            }
        }
    }
    if (Inverse) scale(f, 2 * n, 1.0f / static_cast<float>(n));
}

// Real-input transforms of 2 m points through a complex plan of m: z[j] = x[2j] + i x[2j+1], one complex transform, then
// the even/odd split X[k] = E[k] + w^k O[k], X[m - k] = conj(E[k] - w^k O[k]), w = exp(-2 pi i / 2m).
const Complex *splitOf(const PlanHeader *p) {
    return reinterpret_cast<const Complex *>(reinterpret_cast<const uint8_t *>(twiddlesOf(p)) + size_t(p->n) * sizeof(Complex));
}

}  // namespace

size_t planBytes(uint32_t n) N60_RT_NONBLOCKING {
    if (!validSize(n)) return 0;
    return sizeof(PlanHeader) + alignUp16(size_t(n) * sizeof(uint16_t)) + size_t(n) * sizeof(Complex);
}

bool planInit(void *mem, uint32_t n) {
    if (mem == nullptr || !validSize(n)) return false;
    PlanHeader *p = static_cast<PlanHeader *>(mem);
    p->n = n;
    uint32_t bits = 0;
    while ((1u << bits) < n) ++bits;
    p->log2n = bits;
    uint16_t *rev = const_cast<uint16_t *>(bitrevOf(p));
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t r = 0, s = i;
        for (uint32_t b = 0; b < bits; ++b) {
            r = (r << 1) | (s & 1u);
            s >>= 1;
        }
        rev[i] = static_cast<uint16_t>(r);
    }
    Complex *tw = const_cast<Complex *>(twiddlesOf(p));
    for (uint32_t half = 1; half < n; half <<= 1) {
        const uint32_t len = half << 1;
        for (uint32_t k = 0; k < half; ++k) {
            const double phase = -2.0 * kPi * static_cast<double>(k) / static_cast<double>(len);
            tw[half - 1 + k].re = static_cast<float>(std::cos(phase));
            tw[half - 1 + k].im = static_cast<float>(std::sin(phase));
        }
    }
    return true;
}

size_t realPlanBytes(uint32_t n) N60_RT_NONBLOCKING {
    if (n < 4 || n > 2 * kMaxSize || (n & (n - 1)) != 0) return 0;
    const uint32_t m = n / 2;
    return planBytes(m) + size_t(m / 2 + 1) * sizeof(Complex);
}

bool realPlanInit(void *mem, uint32_t n) {
    if (mem == nullptr || realPlanBytes(n) == 0 || !planInit(mem, n / 2)) return false;
    const uint32_t m = n / 2;
    Complex *sp = const_cast<Complex *>(splitOf(static_cast<const PlanHeader *>(mem)));
    for (uint32_t k = 0; k <= m / 2; ++k) {
        const double phase = -2.0 * kPi * static_cast<double>(k) / static_cast<double>(n);
        sp[k].re = static_cast<float>(std::cos(phase));
        sp[k].im = static_cast<float>(std::sin(phase));
    }
    return true;
}

void forwardReal(const void *plan, float *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    const uint32_t m = p->n;
    Complex *z = reinterpret_cast<Complex *>(x);
    transform<false>(plan, z);
    const Complex *w = splitOf(p);
    const Complex z0 = z[0];
    z[m] = {z0.re - z0.im, 0.0f};  // X[m]; z has m + 1 slots
    z[0] = {z0.re + z0.im, 0.0f};
    for (uint32_t k = 1; k < m - k; ++k) {
        const Complex a = z[k], c = z[m - k];
        const float er = 0.5f * (a.re + c.re), ei = 0.5f * (a.im - c.im);  // E = (a + conj c) / 2
        const float dr = 0.5f * (a.re - c.re), di = 0.5f * (a.im + c.im);  // (a - conj c) / 2
        const float orr = di, oi = -dr;                                      // O = that / i
        const float tr = w[k].re * orr - w[k].im * oi, ti = w[k].re * oi + w[k].im * orr;
        z[k] = {er + tr, ei + ti};
        z[m - k] = {er - tr, -(ei - ti)};
    }
    if ((m & 1u) == 0) z[m / 2].im = -z[m / 2].im;  // w^(m/2) = -i: X = conj(Z)
}

void inverseReal(const void *plan, float *x) N60_RT_NONBLOCKING {
    const PlanHeader *p = static_cast<const PlanHeader *>(plan);
    const uint32_t m = p->n;
    Complex *z = reinterpret_cast<Complex *>(x);
    const Complex *w = splitOf(p);
    const float x0 = z[0].re, xm = z[m].re;  // a real signal has real DC and Nyquist bins
    z[0] = {0.5f * (x0 + xm), 0.5f * (x0 - xm)};
    for (uint32_t k = 1; k < m - k; ++k) {
        const Complex a = z[k], b = z[m - k];  // X[k], X[m - k]
        const float er = 0.5f * (a.re + b.re), ei = 0.5f * (a.im - b.im);  // E = (X[k] + conj X[m-k]) / 2
        const float tr = 0.5f * (a.re - b.re), ti = 0.5f * (a.im + b.im);  // T = (X[k] - conj X[m-k]) / 2
        const float orr = w[k].re * tr + w[k].im * ti, oi = w[k].re * ti - w[k].im * tr;  // O = conj(w^k) T
        z[k] = {er - oi, ei + orr};                                         // Z[k] = E + i O
        z[m - k] = {er + oi, -ei + orr};                                    // Z[m-k] = conj(E) + i conj(O)
    }
    if ((m & 1u) == 0) z[m / 2].im = -z[m / 2].im;
    transform<true>(plan, z);
}

void forward(const void *plan, Complex *x) N60_RT_NONBLOCKING { transform<false>(plan, x); }
void inverse(const void *plan, Complex *x) N60_RT_NONBLOCKING { transform<true>(plan, x); }

}  // namespace n60::fft
