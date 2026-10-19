// libn60core portable FFT (E6 S4). See fft.hpp for the contracts and realtime notes.
#include "fft.hpp"

#include <cmath>
#include <cstring>

namespace n60::fft {
namespace {

struct PlanHeader {
    uint32_t n;
    uint32_t log2n;
    uint32_t pad[2];
};

constexpr double kPi = 3.14159265358979323846;

size_t alignUp16(size_t v) { return (v + 15) & ~size_t(15); }

bool validSize(uint32_t n) { return n >= 2 && n <= kMaxSize && (n & (n - 1)) == 0; }

const uint16_t *bitrevOf(const PlanHeader *p) {
    return reinterpret_cast<const uint16_t *>(reinterpret_cast<const uint8_t *>(p) + sizeof(PlanHeader));
}
const Complex *twiddlesOf(const PlanHeader *p) {
    return reinterpret_cast<const Complex *>(reinterpret_cast<const uint8_t *>(p) + sizeof(PlanHeader) +
                                             alignUp16(size_t(p->n) * sizeof(uint16_t)));
}

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
    for (uint32_t len = 2; len <= n; len <<= 1) {
        const uint32_t half = len >> 1;
        const uint32_t step = n / len;
        for (uint32_t base = 0; base < n; base += len) {
            for (uint32_t k = 0; k < half; ++k) {
                const Complex w = tw[k * step];
                const float wr = w.re;
                const float wi = Inverse ? -w.im : w.im;
                Complex &a = x[base + k];
                Complex &b = x[base + k + half];
                const float tr = b.re * wr - b.im * wi;
                const float ti = b.re * wi + b.im * wr;
                b.re = a.re - tr;
                b.im = a.im - ti;
                a.re += tr;
                a.im += ti;
            }
        }
    }
    if (Inverse) {
        const float scale = 1.0f / static_cast<float>(n);
        for (uint32_t i = 0; i < n; ++i) {
            x[i].re *= scale;
            x[i].im *= scale;
        }
    }
}

}  // namespace

size_t planBytes(uint32_t n) {
    if (!validSize(n)) return 0;
    return sizeof(PlanHeader) + alignUp16(size_t(n) * sizeof(uint16_t)) + size_t(n / 2) * sizeof(Complex);
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
    for (uint32_t k = 0; k < n / 2; ++k) {
        const double phase = -2.0 * kPi * static_cast<double>(k) / static_cast<double>(n);
        tw[k].re = static_cast<float>(std::cos(phase));
        tw[k].im = static_cast<float>(std::sin(phase));
    }
    return true;
}

void forward(const void *plan, Complex *x) { transform<false>(plan, x); }
void inverse(const void *plan, Complex *x) { transform<true>(plan, x); }

}  // namespace n60::fft
