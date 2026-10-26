// E8 S1: crossover filter library (n60/xover.h). Offline, double precision, no Apple frameworks.
//
// Derivation. The analogue prototype is a cascade of first- and second-order low-pass sections
// with -3.01 dB at 1 rad/s (Butterworth: poles on the unit circle; Bessel: roots of the reverse
// Bessel polynomial, scaled so the magnitude is 1/sqrt(2) at 1 rad/s; Linkwitz-Riley order 2M: two
// Butterworth order-M cascades). A high-pass is the s -> 1/s image of the same poles. The
// bilinear transform s = (1/K)(1 - z^-1)/(1 + z^-1), K = tan(pi fc / fs), puts 1 rad/s exactly at
// the corner (prewarp). References: Bilinear transform, any DSP text; Bessel polynomials,
// Krall and Frink (1949); Linkwitz-Riley, Linkwitz (1976); Linkwitz transform, Linkwitz (2001).
#include "n60/xover.h"

#include <cmath>
#include <complex>

namespace {

constexpr double kPi = 3.14159265358979323846;
using Complex = std::complex<double>;

// One analogue section of the low-pass prototype: s^2 + b s + c (second order) or s + c (first).
struct Proto {
    bool second;
    double b, c;
};

struct ProtoList {
    uint32_t count = 0;
    Proto s[N60_XOVER_MAX_SECTIONS * 2];
};

void addPair(ProtoList &list, double re, double im) {
    list.s[list.count++] = Proto{true, -2.0 * re, re * re + im * im};
}

void butterworth(uint32_t order, ProtoList &list) {
    for (uint32_t k = 1; k <= order / 2; ++k) {
        const double phi = kPi * (2.0 * k - 1.0) / (2.0 * order);
        addPair(list, -std::sin(phi), std::cos(phi));
    }
    if (order % 2 == 1) list.s[list.count++] = Proto{false, 0.0, 1.0};
}

double besselMagnitudeSquared(const double *a, uint32_t n, double w) {
    // |theta(0) / theta(jw)|^2 with theta(s) = sum a_k s^k.
    Complex acc(0.0, 0.0);
    Complex jw(0.0, w);
    Complex p(1.0, 0.0);
    for (uint32_t k = 0; k <= n; ++k) {
        acc += a[k] * p;
        p *= jw;
    }
    return a[0] * a[0] / std::norm(acc);
}

void bessel(uint32_t n, ProtoList &list) {
    // Reverse Bessel polynomial coefficients a_k = (2n-k)! / (2^(n-k) k! (n-k)!).
    double a[N60_XOVER_MAX_ORDER + 1];
    auto fact = [](uint32_t m) {
        double f = 1.0;
        for (uint32_t i = 2; i <= m; ++i) f *= i;
        return f;
    };
    for (uint32_t k = 0; k <= n; ++k) a[k] = fact(2 * n - k) / (std::ldexp(1.0, static_cast<int>(n - k)) * fact(k) * fact(n - k));

    // Roots by Durand-Kerner on the monic polynomial, then Newton polish; fixed iteration counts.
    Complex r[N60_XOVER_MAX_ORDER];
    for (uint32_t i = 0; i < n; ++i) r[i] = std::pow(Complex(0.4, 0.9), static_cast<double>(i));
    auto eval = [&](Complex z) {  // monic Horner
        Complex v(1.0, 0.0);
        for (int k = static_cast<int>(n) - 1; k >= 0; --k) v = v * z + a[k] / a[n];
        return v;
    };
    for (int it = 0; it < 500; ++it) {
        for (uint32_t i = 0; i < n; ++i) {
            Complex den(1.0, 0.0);
            for (uint32_t j = 0; j < n; ++j)
                if (j != i) den *= (r[i] - r[j]);
            r[i] -= eval(r[i]) / den;
        }
    }
    // Normalise so |H(j1)|^2 = 1/2: bisection for the -3 dB radian frequency of the raw prototype.
    double lo = 0.01, hi = 4.0 * n;
    for (int it = 0; it < 200; ++it) {
        const double mid = 0.5 * (lo + hi);
        if (besselMagnitudeSquared(a, n, mid) > 0.5) lo = mid; else hi = mid;
    }
    const double w3 = 0.5 * (lo + hi);
    // Pair conjugates: take roots with positive imaginary part (scaled), then the real root, in a
    // fixed order (descending imaginary part) so the output is deterministic.
    bool used[N60_XOVER_MAX_ORDER] = {};
    for (;;) {
        int best = -1;
        for (uint32_t i = 0; i < n; ++i)
            if (!used[i] && r[i].imag() > 1e-9 && (best < 0 || r[i].imag() > r[static_cast<uint32_t>(best)].imag())) best = static_cast<int>(i);
        if (best < 0) break;
        used[best] = true;
        const Complex p = r[best] / w3;
        addPair(list, p.real(), p.imag());
    }
    if (n % 2 == 1) {
        int real = -1;
        for (uint32_t i = 0; i < n; ++i)
            if (std::fabs(r[i].imag()) <= 1e-9) real = static_cast<int>(i);
        list.s[list.count++] = Proto{false, 0.0, -r[real].real() / w3};
    }
}

// Maps (n2 s^2 + n1 s + n0)/(d2 s^2 + d1 s + d0), s = t (1 - z^-1)/(1 + z^-1), to a normalised biquad.
n60_xover_biquad bilinear(double n2, double n1, double n0, double d2, double d1, double d0, double t) {
    const double t2 = t * t;
    const double b0 = n2 * t2 + n1 * t + n0, b1 = -2.0 * n2 * t2 + 2.0 * n0, b2 = n2 * t2 - n1 * t + n0;
    const double a0 = d2 * t2 + d1 * t + d0, a1 = -2.0 * d2 * t2 + 2.0 * d0, a2 = d2 * t2 - d1 * t + d0;
    return n60_xover_biquad{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

// First-order: (n1 s + n0)/(d1 s + d0).
n60_xover_biquad bilinearFirst(double n1, double n0, double d1, double d0, double t) {
    const double b0 = n1 * t + n0, b1 = -n1 * t + n0, a0 = d1 * t + d0, a1 = -d1 * t + d0;
    return n60_xover_biquad{b0 / a0, b1 / a0, 0.0, a1 / a0, 0.0};
}

bool validFs(double fs) { return std::isfinite(fs) && fs > 0.0; }

int validateSpec(const n60_xover_spec *spec, double fs) {
    if (!spec || !validFs(fs)) return N60_XOVER_ERR_ARGUMENT;
    switch (spec->family) {
    case N60_XOVER_FAMILY_BUTTERWORTH:
    case N60_XOVER_FAMILY_BESSEL:
        if (spec->order < 1 || spec->order > N60_XOVER_MAX_ORDER) return N60_XOVER_ERR_ORDER;
        break;
    case N60_XOVER_FAMILY_LINKWITZ_RILEY:
        if (spec->order != 2 && spec->order != 4 && spec->order != 6 && spec->order != 8) return N60_XOVER_ERR_ORDER;
        break;
    default:
        return N60_XOVER_ERR_ARGUMENT;
    }
    if (!std::isfinite(spec->corner_hz) || !(spec->corner_hz > 0.0) || spec->corner_hz > 0.49 * fs) return N60_XOVER_ERR_CORNER;
    return N60_XOVER_OK;
}

}  // namespace

extern "C" {

uint32_t n60_xover_abi_version(void) { return N60_XOVER_ABI_VERSION; }

int n60_xover_design(const n60_xover_spec *spec, int highpass, double fs, n60_xover_cascade *out) {
    if (!out) return N60_XOVER_ERR_ARGUMENT;
    out->count = 0;
    const int status = validateSpec(spec, fs);
    if (status != N60_XOVER_OK) return status;

    ProtoList list;
    const bool lr = spec->family == N60_XOVER_FAMILY_LINKWITZ_RILEY;
    const uint32_t base = lr ? spec->order / 2 : spec->order;
    if (spec->family == N60_XOVER_FAMILY_BESSEL) bessel(base, list); else butterworth(base, list);
    const uint32_t copies = lr ? 2 : 1;

    const double k = std::tan(kPi * spec->corner_hz / fs);
    const double t = 1.0 / k;
    for (uint32_t copy = 0; copy < copies; ++copy) {
        for (uint32_t i = 0; i < list.count; ++i) {
            const Proto &p = list.s[i];
            n60_xover_biquad bq;
            if (p.second) {
                bq = highpass ? bilinear(1.0, 0.0, 0.0, 1.0, p.b / p.c, 1.0 / p.c, t)
                              : bilinear(0.0, 0.0, p.c, 1.0, p.b, p.c, t);
            } else {
                bq = highpass ? bilinearFirst(1.0, 0.0, 1.0, 1.0 / p.c, t) : bilinearFirst(0.0, p.c, 1.0, p.c, t);
            }
            out->sections[out->count++] = bq;
        }
    }
    return N60_XOVER_OK;
}

int n60_xover_linkwitz(double f0, double q0, double fp, double qp, double fs, n60_xover_cascade *out) {
    if (!out) return N60_XOVER_ERR_ARGUMENT;
    out->count = 0;
    if (!validFs(fs) || !(f0 > 0.0) || !(fp > 0.0) || !(q0 > 0.0) || !(qp > 0.0) || !std::isfinite(f0 + fp + q0 + qp)) return N60_XOVER_ERR_ARGUMENT;
    if (f0 > 0.49 * fs || fp > 0.49 * fs) return N60_XOVER_ERR_CORNER;
    // Prewarp both frequencies so the zero pair lands on f0 and the pole pair on fp exactly.
    const double t = 2.0 * fs;
    const double w0 = t * std::tan(kPi * f0 / fs), wp = t * std::tan(kPi * fp / fs);
    out->sections[0] = bilinear(1.0, w0 / q0, w0 * w0, 1.0, wp / qp, wp * wp, t);
    out->count = 1;
    return N60_XOVER_OK;
}

int n60_xover_response(const n60_xover_cascade *c, double fs, double hz, double *re, double *im) {
    if (!c || !re || !im || !validFs(fs) || !std::isfinite(hz) || c->count > N60_XOVER_MAX_SECTIONS) return N60_XOVER_ERR_ARGUMENT;
    const double w = 2.0 * kPi * hz / fs;
    const Complex z1(std::cos(w), -std::sin(w)), z2 = z1 * z1;
    Complex h(1.0, 0.0);
    for (uint32_t i = 0; i < c->count; ++i) {
        const n60_xover_biquad &s = c->sections[i];
        h *= (s.b0 + s.b1 * z1 + s.b2 * z2) / (1.0 + s.a1 * z1 + s.a2 * z2);
    }
    *re = h.real();
    *im = h.imag();
    return N60_XOVER_OK;
}

int n60_xover_magnitude_db(const n60_xover_cascade *c, double fs, double hz, double *db) {
    double re = 0, im = 0;
    if (!db) return N60_XOVER_ERR_ARGUMENT;
    const int status = n60_xover_response(c, fs, hz, &re, &im);
    if (status != N60_XOVER_OK) return status;
    *db = 10.0 * std::log10(re * re + im * im + 1e-300);
    return N60_XOVER_OK;
}

int n60_xover_lr_inverts_hp(uint32_t order) { return order % 4 == 2 ? 1 : 0; }

int n60_xover_sum_ripple_db(const n60_xover_spec *lp, const n60_xover_spec *hp, int invert_hp, double fs, double *ripple_db) {
    if (!lp || !hp || !ripple_db) return N60_XOVER_ERR_ARGUMENT;
    n60_xover_cascade a, b;
    int status = n60_xover_design(lp, 0, fs, &a);
    if (status != N60_XOVER_OK) return status;
    status = n60_xover_design(hp, 1, fs, &b);
    if (status != N60_XOVER_OK) return status;
    const double top = std::fmin(20000.0, 0.45 * fs);
    double lo = 1e300, hi = -1e300;
    for (uint32_t i = 0;; ++i) {
        const double hz = 20.0 * std::exp2(static_cast<double>(i) / 48.0);
        if (hz > top) break;
        double ar, ai, br, bi;
        n60_xover_response(&a, fs, hz, &ar, &ai);
        n60_xover_response(&b, fs, hz, &br, &bi);
        const double sign = invert_hp ? -1.0 : 1.0;
        const double re = ar + sign * br, im = ai + sign * bi;
        const double db = 10.0 * std::log10(re * re + im * im + 1e-300);
        if (db < lo) lo = db;
        if (db > hi) hi = db;
    }
    *ripple_db = hi - lo;
    return N60_XOVER_OK;
}

double n60_xover_max_pole_radius(const n60_xover_cascade *c) {
    if (!c) return 0.0;
    double worst = 0.0;
    for (uint32_t i = 0; i < c->count && i < N60_XOVER_MAX_SECTIONS; ++i) {
        const double a1 = c->sections[i].a1, a2 = c->sections[i].a2;
        const double disc = a1 * a1 - 4.0 * a2;
        double radius;
        if (disc < 0.0) {
            radius = std::sqrt(a2);
        } else {
            const double sq = std::sqrt(disc);
            radius = std::fmax(std::fabs(0.5 * (-a1 + sq)), std::fabs(0.5 * (-a1 - sq)));
        }
        if (radius > worst) worst = radius;
    }
    return worst;
}

}  // extern "C"
