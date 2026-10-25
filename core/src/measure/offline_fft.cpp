#include "offline_fft.hpp"

#include <cmath>
#include <new>

namespace n60::fft::offline {

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;

// In-place radix-2 DIT complex transform of m points; twiddle exp(-2 pi i j / m) is w[j * stride]. sign < 0 forward, > 0 inverse (unscaled).
void complexTransform(Cplx *a, uint64_t m, const Cplx *w, uint64_t stride, int sign) {
    // Bit reversal.
    for (uint64_t i = 1, j = 0; i < m; ++i) {
        uint64_t bit = m >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            const Cplx t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
    }
    for (uint64_t len = 2; len <= m; len <<= 1) {
        const uint64_t half = len >> 1;
        const uint64_t step = (m / len) * stride;
        for (uint64_t base = 0; base < m; base += len) {
            for (uint64_t k = 0; k < half; ++k) {
                const Cplx t = w[k * step];
                const double wr = t.re;
                const double wi = sign < 0 ? t.im : -t.im;
                Cplx &u = a[base + k];
                Cplx &v = a[base + k + half];
                const double vr = v.re * wr - v.im * wi;
                const double vi = v.re * wi + v.im * wr;
                v.re = u.re - vr;
                v.im = u.im - vi;
                u.re += vr;
                u.im += vi;
            }
        }
    }
}

// Twiddles exp(-2 pi i j / n), j < n/2. The n/2-point complex stage reads them with stride 2;
// the real post-processing reads them directly.
bool makeTwiddles(uint64_t n, std::vector<Cplx> &tw) {
    tw.assign(n / 2, Cplx{1.0, 0.0});
    if (tw.size() != n / 2) return false;
    for (uint64_t j = 0; j < n / 2; ++j) {
        const double angle = -2.0 * kPi * static_cast<double>(j) / static_cast<double>(n);
        tw[j] = Cplx{std::cos(angle), std::sin(angle)};
    }
    return true;
}

}  // namespace

bool validSize(uint64_t n) { return n >= 2 && n <= kMaxSize && (n & (n - 1)) == 0; }

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
    std::vector<Cplx> tw;
    std::vector<Cplx> z;
    {
        // Allocation failure must not throw across the C boundary: callers build with
        // -fno-exceptions, so a failed allocation terminates; sizes are bounded by kMaxSize.
        if (!makeTwiddles(n, tw)) return false;
        z.resize(m);
    }
    for (uint64_t j = 0; j < m; ++j) z[j] = Cplx{x[2 * j], x[2 * j + 1]};
    // The m-point stage needs exp(-2 pi i j / m) = tw[2 j].
    if (m >= 2) complexTransform(z.data(), m, tw.data(), 2, -1);
    spectrum.resize(m + 1);
    for (uint64_t k = 0; k <= m; ++k) {
        const Cplx a = z[k % m];
        const Cplx b = z[(m - k) % m];
        // E[k] = (Z[k] + conj Z[m-k]) / 2, O[k] = (Z[k] - conj Z[m-k]) / (2i)
        const double er = 0.5 * (a.re + b.re);
        const double ei = 0.5 * (a.im - b.im);
        const double orr = 0.5 * (a.im + b.im);
        const double oi = -0.5 * (a.re - b.re);
        double wr = 1.0, wi = 0.0;
        if (k < m) {
            wr = tw[k].re;
            wi = tw[k].im;
        } else {
            wr = -1.0;
            wi = 0.0;
        }
        spectrum[k] = Cplx{er + orr * wr - oi * wi, ei + orr * wi + oi * wr};
    }
    spectrum[0].im = 0.0;
    spectrum[m].im = 0.0;
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
    std::vector<Cplx> tw;
    if (!makeTwiddles(n, tw)) return false;
    std::vector<Cplx> z(m);
    for (uint64_t k = 0; k < m; ++k) {
        const Cplx a = spectrum[k];
        const Cplx b = spectrum[m - k];
        // E[k] = (X[k] + conj X[m-k]) / 2 ; O[k] = (X[k] - conj X[m-k]) / 2 * exp(+2 pi i k / n)
        const double er = 0.5 * (a.re + b.re);
        const double ei = 0.5 * (a.im - b.im);
        const double dr = 0.5 * (a.re - b.re);
        const double di = 0.5 * (a.im + b.im);
        const double wr = tw[k].re;
        const double wi = -tw[k].im;
        const double orr = dr * wr - di * wi;
        const double oi = dr * wi + di * wr;
        // Z[k] = E[k] + i O[k]
        z[k] = Cplx{er - oi, ei + orr};
    }
    complexTransform(z.data(), m, tw.data(), 2, +1);
    const double scale = 1.0 / static_cast<double>(m);
    for (uint64_t j = 0; j < m; ++j) {
        x[2 * j] = z[j].re * scale;
        x[2 * j + 1] = z[j].im * scale;
    }
    return true;
}

}  // namespace n60::fft::offline
