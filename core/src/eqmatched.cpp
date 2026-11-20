// E33 S26 (G51): matched EQ biquads. See docs/MATCHED_EQ_FILTERS.md for the derivation, the sources and the tolerance
// per type. Double precision, deterministic on one platform (fixed operation order, no tables; libm last-bit results may differ between platforms, so tests compare with a tolerance), allocation-free, no exceptions, so it
// can run wherever the core designs a PEQ section, including the render thread's edit path.
#include <cmath>
#include <cstdint>

#include "snapshot.hpp"

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846;


struct Cx {
    double re, im;
};
inline Cx cx(double re, double im) { return {re, im}; }
inline Cx operator+(Cx a, Cx b) { return {a.re + b.re, a.im + b.im}; }
inline Cx operator*(Cx a, Cx b) { return {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
inline Cx scale(Cx a, double k) { return {a.re * k, a.im * k}; }
inline double norm2(Cx a) { return a.re * a.re + a.im * a.im; }
// |n| ^ 2 / |d| ^ 2 for a rational function of s = j x.
inline double ratio2(Cx n, Cx d) { return norm2(n) / norm2(d); }

// Pole pair of an analogue second-order section s^2 + 2 zeta s + 1 (frequency wp rad/sample), mapped by z = e^{sT}
// (Vicanek 2016, section 2). Returns a1, a2 of 1 + a1 z^-1 + a2 z^-2.
void mapPoles(double wp, double zeta, double &a1, double &a2) {
    const double decay = std::exp(-zeta * wp);
    if (zeta < 1.0) {
        a1 = -2.0 * decay * std::cos(std::sqrt(1.0 - zeta * zeta) * wp);
    } else {
        a1 = -2.0 * decay * std::cosh(std::sqrt(zeta * zeta - 1.0) * wp);
    }
    a2 = decay * decay;
}

// |den(e^jw)|^2 = A0 phi0 + A1 phi1 + A2 phi2 with phi0 = cos^2(w/2), phi1 = sin^2(w/2), phi2 = 4 phi0 phi1
// (Vicanek 2016, section 1). The same basis holds for the numerator with B0 = (b0+b1+b2)^2, B1 = (b0-b1+b2)^2,
// B2 = -4 b0 b2.
struct Basis {
    double p0, p1, p2;
};
inline Basis basisAt(double w) {
    const double s = std::sin(0.5 * w), c = std::cos(0.5 * w);
    return {c * c, s * s, 4.0 * c * c * s * s};
}

// Numerator from the three magnitude-squared targets (DC, w0, Nyquist) against poles a1, a2 (Orfanidis 1997 prescribes
// the Nyquist gain; Vicanek 2016 solves the numerator in the phi basis). m0, m1, mpi are the analogue magnitudes
// at DC, at w0 and at Nyquist (not squared).
bool threePoint(double w0, double a1, double a2, double m0, double m1, double mpi, double out[5]) {
    const double A0 = (1.0 + a1 + a2) * (1.0 + a1 + a2), A1 = (1.0 - a1 + a2) * (1.0 - a1 + a2), A2 = -4.0 * a2;
    const Basis f = basisAt(w0);
    if (!(f.p2 > 1e-9)) return false;
    const double B0 = m0 * m0 * A0, B1 = mpi * mpi * A1;
    const double B2 = (m1 * m1 * (A0 * f.p0 + A1 * f.p1 + A2 * f.p2) - B0 * f.p0 - B1 * f.p1) / f.p2;
    if (!(B0 >= 0.0) || !(B1 >= 0.0)) return false;
    const double W0 = std::sqrt(B0), W1 = std::sqrt(B1);
    const double S = 0.5 * (W0 + W1);
    const double disc = S * S + B2;
    if (!(disc >= 0.0) || !(S > 0.0)) return false;
    const double b0 = 0.5 * (S + std::sqrt(disc));
    const double b2 = S - b0;
    out[0] = b0; out[1] = 0.5 * (W0 - W1); out[2] = b2; out[3] = a1; out[4] = a2;
    return true;
}

// Analogue prototypes of the RBJ Audio EQ Cookbook (the curves the cookbook digital filters approximate), as a function
// of x = w / w0, evaluated at s = j x.
double peakMag(double A, double Q, double x) {
    const Cx s = cx(0.0, x), one = cx(1.0, 0.0);
    const Cx s2 = s * s;
    return std::sqrt(ratio2(s2 + scale(s, A / Q) + one, s2 + scale(s, 1.0 / (A * Q)) + one));
}
double lowShelfMag(double A, double Q, double x) {
    const Cx s = cx(0.0, x);
    const Cx s2 = s * s;
    const double r = std::sqrt(A) / Q;
    return A * std::sqrt(ratio2(s2 + scale(s, r) + cx(A, 0.0), scale(s2, A) + scale(s, r) + cx(1.0, 0.0)));
}
bool matchedPeakBoost(double w0, double A, double Q, double out[5]) {
    double a1, a2;
    mapPoles(w0, 1.0 / (2.0 * A * Q), a1, a2);
    return threePoint(w0, a1, a2, 1.0, A * A, peakMag(A, Q, kPi / w0), out);
}
bool matchedLowShelfBoost(double w0, double A, double Q, double out[5]) {
    double a1, a2;
    mapPoles(w0 / std::sqrt(A), 1.0 / (2.0 * Q), a1, a2);
    return threePoint(w0, a1, a2, A * A, lowShelfMag(A, Q, 1.0), lowShelfMag(A, Q, kPi / w0), out);
}
// The inverse of a biquad (zeros and poles swapped, scaled by k). Valid when the numerator is minimum phase (the
// designs above choose the larger of the two numerator roots as b0, which puts both zeros inside the unit circle).
bool invertScaled(const double in[5], double k, double out[5]) {
    if (!(std::fabs(in[0]) > 1e-12)) return false;
    out[0] = k / in[0]; out[1] = k * in[3] / in[0]; out[2] = k * in[4] / in[0]; out[3] = in[1] / in[0]; out[4] = in[2] / in[0];
    return true;
}

// A cut is the exact inverse of the boost of the same shape (the cookbook's cut is 1 / boost with A -> 1 / A), so it is
// designed as that boost and inverted.
bool matchedPeak(double w0, double A, double Q, double out[5]) {
    if (A >= 1.0) return matchedPeakBoost(w0, A, Q, out);
    double boost[5];
    return matchedPeakBoost(w0, 1.0 / A, Q, boost) && invertScaled(boost, 1.0, out);
}
bool matchedLowShelf(double w0, double A, double Q, double out[5]) {
    if (A >= 1.0) return matchedLowShelfBoost(w0, A, Q, out);
    double boost[5];
    return matchedLowShelfBoost(w0, 1.0 / A, Q, boost) && invertScaled(boost, 1.0, out);
}
// The analogue shelves satisfy LS(A) HS(A) = A^2 (the two numerators and the two denominators are the same pair of
// quadratics), so the high shelf is A^2 over the matched low shelf. A high shelf's own poles sit at sqrt(A) w0, often
// above Nyquist at the top of the band, where mapping poles by z = e^(sT) fails; the low shelf's sit at w0 / sqrt(A).
bool matchedHighShelf(double w0, double A, double Q, double out[5]) {
    double ls[5];
    return matchedLowShelf(w0, A, Q, ls) && invertScaled(ls, A * A, out);
}

// Low pass, high pass and band pass: Vicanek 2016 closed forms (gain Q at w0 for LP and HP, 1 for BP).
bool matchedLowPass(double w0, double Q, double out[5]) {
    double a1, a2;
    mapPoles(w0, 1.0 / (2.0 * Q), a1, a2);
    const double A0 = (1.0 + a1 + a2) * (1.0 + a1 + a2), A1 = (1.0 - a1 + a2) * (1.0 - a1 + a2), A2 = -4.0 * a2;
    const Basis f = basisAt(w0);
    if (!(f.p1 > 1e-12)) return false;
    const double R1 = (A0 * f.p0 + A1 * f.p1 + A2 * f.p2) * Q * Q;
    const double B1 = (R1 - A0 * f.p0) / f.p1;
    if (!(B1 >= 0.0)) return false;
    const double b0 = 0.5 * (std::sqrt(A0) + std::sqrt(B1));
    out[0] = b0; out[1] = std::sqrt(A0) - b0; out[2] = 0.0; out[3] = a1; out[4] = a2;
    return true;
}
bool matchedHighPass(double w0, double Q, double out[5]) {
    double a1, a2;
    mapPoles(w0, 1.0 / (2.0 * Q), a1, a2);
    const double A0 = (1.0 + a1 + a2) * (1.0 + a1 + a2), A1 = (1.0 - a1 + a2) * (1.0 - a1 + a2), A2 = -4.0 * a2;
    const Basis f = basisAt(w0);
    if (!(f.p1 > 1e-12)) return false;
    const double b0 = Q * std::sqrt(A0 * f.p0 + A1 * f.p1 + A2 * f.p2) / (4.0 * f.p1);
    out[0] = b0; out[1] = -2.0 * b0; out[2] = b0; out[3] = a1; out[4] = a2;
    return true;
}
bool matchedBandPass(double w0, double Q, double out[5]) {
    double a1, a2;
    mapPoles(w0, 1.0 / (2.0 * Q), a1, a2);
    const double A0 = (1.0 + a1 + a2) * (1.0 + a1 + a2), A1 = (1.0 - a1 + a2) * (1.0 - a1 + a2), A2 = -4.0 * a2;
    const Basis f = basisAt(w0);
    if (!(f.p1 > 1e-12)) return false;
    const double R1 = A0 * f.p0 + A1 * f.p1 + A2 * f.p2;
    const double R2 = -A0 + A1 + 4.0 * (f.p0 - f.p1) * A2;
    const double B2 = (R1 - R2 * f.p1) / (4.0 * f.p1 * f.p1);
    const double B1 = R2 + 4.0 * (f.p1 - f.p0) * B2;
    if (!(B1 >= 0.0)) return false;
    const double b1 = -0.5 * std::sqrt(B1);
    const double inner = B2 + b1 * b1;
    if (!(inner >= 0.0)) return false;
    const double b0 = 0.5 * (std::sqrt(inner) - b1);
    out[0] = b0; out[1] = b1; out[2] = -b0 - b1; out[3] = a1; out[4] = a2;
    return true;
}

bool finite5(const double *c) {
    for (int i = 0; i < 5; ++i) {
        if (!std::isfinite(c[i])) return false;
    }
    // Strictly stable poles.
    return std::fabs(c[4]) < 1.0 && std::fabs(c[3]) < 1.0 + c[4];
}

}  // namespace

bool designEqSection(uint32_t type, double rate, double f, double gainDb, double q, double out[5]) N60_RT_NONBLOCKING {
    if (type <= 7) return designBiquad(type, rate, f, gainDb, q, out);
    if (type == 8) {
        if (!std::isfinite(gainDb) || gainDb < -24.0 || gainDb > 24.0 || !(q > 0.0)) return false;
        return designBiquad(0, rate, f, gainDb, q / std::pow(10.0, gainDb / 40.0), out);
    }
    if (type < 16 || type > 24 || type == 21 || type == 22) return false;
    const uint32_t base = type == 24 ? 0u : type - 16u;
    const double qCookbook = type == 24 && std::isfinite(gainDb) ? q / std::pow(10.0, gainDb / 40.0) : q;
    // The cookbook is the reference and the fallback: same argument limits, and used whenever the matched design is
    // not defined for the argument (near Nyquist for the shelves and bells, or a numerator that has no real solution).
    double cookbook[5];
    if (!designBiquad(base, rate, f, gainDb, qCookbook, cookbook)) return false;
    const double w0 = 2.0 * kPi * f / rate;
    const double A = std::pow(10.0, gainDb / 40.0);
    double m[5];
    bool ok = false;
    switch (base) {
        case 0: ok = gainDb != 0.0 && matchedPeak(w0, A, qCookbook, m); break;
        case 1: ok = gainDb != 0.0 && matchedLowShelf(w0, A, qCookbook, m); break;
        case 2: ok = gainDb != 0.0 && matchedHighShelf(w0, A, qCookbook, m); break;
        case 3: ok = matchedLowPass(w0, qCookbook, m); break;
        case 4: ok = matchedHighPass(w0, qCookbook, m); break;
        case 7: ok = matchedBandPass(w0, qCookbook, m); break;
        default: return false;
    }
    const double *c = ok && finite5(m) ? m : cookbook;
    for (int i = 0; i < 5; ++i) out[i] = c[i];
    return true;
}

double eqSectionMagnitude(const double c[5], double rate, double f) N60_RT_NONBLOCKING {
    const double w = 2.0 * kPi * f / rate;
    const Cx z1 = cx(std::cos(w), -std::sin(w)), z2 = cx(std::cos(2.0 * w), -std::sin(2.0 * w));
    const Cx num = cx(c[0], 0.0) + scale(z1, c[1]) + scale(z2, c[2]);
    const Cx den = cx(1.0, 0.0) + scale(z1, c[3]) + scale(z2, c[4]);
    const double d = norm2(den);
    return d > 0.0 ? std::sqrt(norm2(num) / d) : 0.0;
}

}  // namespace n60

extern "C" {
int32_t n60_eq_design_section(uint32_t type, double rate, double hz, double gainDb, double q, double *out) {
    if (out == nullptr || !std::isfinite(rate) || rate <= 0.0) return 0;
    double c[5];
    if (!n60::designEqSection(type, rate, hz, gainDb, q, c)) return 0;
    for (int i = 0; i < 5; ++i) out[i] = c[i];
    return 1;
}
double n60_eq_section_magnitude(const double *coefficients, double rate, double hz) {
    if (coefficients == nullptr || !(rate > 0.0)) return 0.0;
    return n60::eqSectionMagnitude(coefficients, rate, hz);
}
}
