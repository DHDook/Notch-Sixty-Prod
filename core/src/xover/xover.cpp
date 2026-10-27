// E8 S1: crossover filter library (n60/xover.h). Offline, double precision, no Apple frameworks.
//
// Derivation. The analogue prototype is a cascade of first- and second-order low-pass sections
// with -3.01 dB at 1 rad/s (Butterworth: poles on the unit circle; Bessel: roots of the reverse
// Bessel polynomial, scaled so the magnitude is 1/sqrt(2) at 1 rad/s; Linkwitz-Riley order 2M: two
// Butterworth order-M cascades). A high-pass is the s -> 1/s image of the same poles. The
// bilinear transform s = (1/K)(1 - z^-1)/(1 + z^-1), K = tan(pi fc / fs), puts 1 rad/s exactly at
// the corner (prewarp). References: Bilinear transform, any DSP text; Bessel polynomials,
// Krall and Frink (1949); Linkwitz-Riley, Linkwitz (1976); Linkwitz transform, Linkwitz (2001).
#include "n60/correct.h"
#include "n60/xover.h"

#include <algorithm>
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

int n60_xover_prototype_design(uint32_t family, uint32_t order, n60_xover_prototype *out) {
    if (!out) return N60_XOVER_ERR_ARGUMENT;
    out->count = 0;
    out->copies = 0;
    n60_xover_spec probe{};
    probe.family = family;
    probe.order = order;
    probe.corner_hz = 1.0;
    const int status = validateSpec(&probe, 1000.0);
    if (status != N60_XOVER_OK) return status;
    ProtoList list;
    const bool lr = family == N60_XOVER_FAMILY_LINKWITZ_RILEY;
    const uint32_t base = lr ? order / 2 : order;
    if (family == N60_XOVER_FAMILY_BESSEL) bessel(base, list); else butterworth(base, list);
    out->count = list.count;
    out->copies = lr ? 2u : 1u;
    for (uint32_t i = 0; i < list.count; ++i) out->sections[i] = n60_xover_proto_section{list.s[i].second ? 1u : 0u, list.s[i].b, list.s[i].c};
    return N60_XOVER_OK;
}

int n60_xover_realise(const n60_xover_prototype *proto, int highpass, double corner_hz, double fs, n60_xover_cascade *out) {
    if (!out) return N60_XOVER_ERR_ARGUMENT;
    out->count = 0;
    if (!proto || !validFs(fs) || proto->count == 0 || proto->count > N60_XOVER_MAX_SECTIONS || proto->copies < 1 ||
        proto->copies > 2 || proto->count * proto->copies > N60_XOVER_MAX_SECTIONS) {
        return N60_XOVER_ERR_ARGUMENT;
    }
    if (!std::isfinite(corner_hz) || !(corner_hz > 0.0) || corner_hz > 0.49 * fs) return N60_XOVER_ERR_CORNER;
    const double k = std::tan(kPi * corner_hz / fs);
    const double t = 1.0 / k;
    for (uint32_t copy = 0; copy < proto->copies; ++copy) {
        for (uint32_t i = 0; i < proto->count; ++i) {
            const n60_xover_proto_section &p = proto->sections[i];
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

int n60_xover_design(const n60_xover_spec *spec, int highpass, double fs, n60_xover_cascade *out) {
    if (!out) return N60_XOVER_ERR_ARGUMENT;
    out->count = 0;
    const int status = validateSpec(spec, fs);
    if (status != N60_XOVER_OK) return status;
    n60_xover_prototype proto;
    const int ps = n60_xover_prototype_design(spec->family, spec->order, &proto);
    if (ps != N60_XOVER_OK) return ps;
    return n60_xover_realise(&proto, highpass, spec->corner_hz, fs, out);
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

namespace {

struct FirTarget {
    n60_xover_cascade hp, lp;
    bool hasHp = false, hasLp = false;
    double fs = 0.0;
};

double firAmplitude(double hz, void *user) {
    const FirTarget &t = *static_cast<const FirTarget *>(user);
    double a = 1.0, re = 0.0, im = 0.0;
    if (t.hasHp) { n60_xover_response(&t.hp, t.fs, hz, &re, &im); a *= std::hypot(re, im); }
    if (t.hasLp) { n60_xover_response(&t.lp, t.fs, hz, &re, &im); a *= std::hypot(re, im); }
    return a;
}

// Validates the params, builds the target and resolves the group delay.
int firPrepare(const n60_xover_fir_params *p, FirTarget &t, uint32_t &delay) {
    if (!p || p->struct_size != sizeof(n60_xover_fir_params) || !validFs(p->sample_rate) || p->sample_rate < 8000.0 ||
        p->sample_rate > 768000.0 || (!p->highpass && !p->lowpass)) {
        return N60_XOVER_ERR_ARGUMENT;
    }
    t.fs = p->sample_rate;
    double lowest = 1e300;
    if (p->highpass) {
        const int s = n60_xover_design(p->highpass, 1, t.fs, &t.hp);
        if (s != N60_XOVER_OK) return s;
        t.hasHp = true;
        lowest = std::fmin(lowest, p->highpass->corner_hz);
    }
    if (p->lowpass) {
        const int s = n60_xover_design(p->lowpass, 0, t.fs, &t.lp);
        if (s != N60_XOVER_OK) return s;
        t.hasLp = true;
        lowest = std::fmin(lowest, p->lowpass->corner_hz);
    }
    delay = p->group_delay_frames;
    if (delay == 0) {
        const double frames = std::round(5.0 * t.fs / lowest);
        delay = static_cast<uint32_t>(std::fmin(262144.0, std::fmax(32.0, frames)));
    }
    if (delay > 262144u) return N60_XOVER_ERR_ARGUMENT;
    return N60_XOVER_OK;
}

void firReport(uint32_t delay, double fs, n60_xover_fir_report *r) {
    const uint64_t span = 2ull * delay + 1;
    *r = n60_xover_fir_report{};
    r->group_delay_frames = delay;
    if (span <= 32768) {
        r->decimation = 1;
        r->full_tap_count = static_cast<uint32_t>(span);
        r->latency_frames = 256 + delay;
        return;
    }
    const uint32_t d = n60_correct_two_band_decimation(fs);
    const uint64_t keep = std::min<uint64_t>(delay, static_cast<uint64_t>(std::llround(0.01 * fs)));
    r->two_band = 1;
    r->decimation = d;
    r->extra_delay_frames = static_cast<uint32_t>(delay - keep);
    r->full_tap_count = static_cast<uint32_t>(std::min<uint64_t>(32768, 2 * keep + 1));
    r->low_tap_count = static_cast<uint32_t>(std::min<uint64_t>(32768, (span + d - 1) / d));
    r->latency_frames = 4 * 18 * (d - 1) + 256 * d + delay;
}

}  // namespace

extern "C" {

int n60_xover_fir_plan(const n60_xover_fir_params *params, n60_xover_fir_report *report) {
    if (!report) return N60_XOVER_ERR_ARGUMENT;
    FirTarget t;
    uint32_t delay = 0;
    const int s = firPrepare(params, t, delay);
    if (s != N60_XOVER_OK) return s;
    firReport(delay, t.fs, report);
    return N60_XOVER_OK;
}

int n60_xover_fir_synthesize(const n60_xover_fir_params *params, float *full, uint64_t fullCap, float *low, uint64_t lowCap,
                             n60_xover_fir_report *report) {
    FirTarget t;
    uint32_t delay = 0;
    int s = firPrepare(params, t, delay);
    if (s != N60_XOVER_OK) return s;
    n60_xover_fir_report plan;
    firReport(delay, t.fs, &plan);
    n60_correct_two_band_report r{};
    const int32_t status = n60_correct_synthesize_linear_phase(t.fs, delay, firAmplitude, &t, full, fullCap, low, lowCap, &r);
    if (status != N60_CORRECT_OK) return status == N60_CORRECT_ERR_ARGUMENT ? N60_XOVER_ERR_ARGUMENT : N60_XOVER_ERR_SYNTH;
    if (report) *report = plan;
    return N60_XOVER_OK;
}

}  // extern "C"

// E8 S8: near-field driver linearisation (ABI v4). Method: smooth the measured dB at a fractional-octave width (the mean of
// nine evenly spaced samples across the window), level-match and blend an optional far field above a merge frequency, take the
// mean level between the way's corners as the target, and correct towards it with the fixed safety limits of owner decision 6.
// Minimum phase uses the real-cepstrum synthesiser (n60_correct_minphase_synthesize); linear phase folds the correction into
// the crossover's zero-phase amplitude and calls n60_correct_synthesize_linear_phase.
#include <vector>

namespace {

uint64_t nextPow2Local(uint64_t n) {
    uint64_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

constexpr double kGridStartHz = 20.0;
constexpr double kPerOctave = 24.0;
constexpr double kMaxCutDb = -24.0;
constexpr double kBoostCapDb = 6.0;

// dB at hz, linear in log frequency, held at the ends.
double atHz(const double *f, const double *v, uint32_t n, double hz) {
    if (hz <= f[0]) return v[0];
    if (hz >= f[n - 1]) return v[n - 1];
    uint32_t lo = 0, hi = n - 1;
    while (hi - lo > 1) {
        const uint32_t mid = (lo + hi) / 2;
        (f[mid] <= hz ? lo : hi) = mid;
    }
    const double t = std::log(hz / f[lo]) / std::log(f[hi] / f[lo]);
    return v[lo] + t * (v[hi] - v[lo]);
}

bool ascending(const double *f, const double *v, uint32_t n) {
    if (!f || !v || n < 2) return false;
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(f[i]) || !std::isfinite(v[i]) || !(f[i] > 0.0) || (i > 0 && !(f[i] > f[i - 1]))) return false;
    }
    return true;
}

double smoothedAt(const double *f, const double *v, uint32_t n, double hz, double width) {
    double sum = 0.0;
    for (int k = -4; k <= 4; ++k) sum += atHz(f, v, n, hz * std::exp2(width * static_cast<double>(k) / 8.0));
    return sum / 9.0;
}

uint32_t gridCount(double fs) {
    const double top = std::fmin(20000.0, 0.45 * fs);
    return static_cast<uint32_t>(std::floor(std::log2(top / kGridStartHz) * kPerOctave)) + 1;
}

double gridHz(uint32_t i) { return kGridStartHz * std::exp2(static_cast<double>(i) / kPerOctave); }

bool linValid(const n60_xover_lin_params *p) {
    return p && p->struct_size == sizeof(n60_xover_lin_params) && std::isfinite(p->sample_rate) && p->sample_rate >= 8000.0 &&
           p->sample_rate <= 768000.0 && (p->highpass || p->lowpass) && std::isfinite(p->merge_hz) && p->merge_hz >= 0.0 &&
           std::isfinite(p->max_boost_db) && p->max_boost_db >= 0.0 && p->max_boost_db <= kBoostCapDb &&
           std::isfinite(p->smoothing_octaves) && p->smoothing_octaves >= 0.0 && p->smoothing_octaves <= 1.0 &&
           std::isfinite(p->band_octaves) && p->band_octaves >= 0.0 && p->band_octaves <= 2.0;
}

struct LinAmplitude {
    FirTarget target;
    const double *grid;
    const double *correction;
    uint32_t count;
};

double linAmplitude(double hz, void *user) {
    const LinAmplitude &a = *static_cast<const LinAmplitude *>(user);
    const double xo = firAmplitude(hz, const_cast<FirTarget *>(&a.target));
    const double c = (hz < a.grid[0] || hz > a.grid[a.count - 1]) ? 0.0 : atHz(a.grid, a.correction, a.count, hz);
    return xo * std::pow(10.0, c / 20.0);
}

}  // namespace

extern "C" {

int n60_xover_linearise_design(const n60_xover_lin_params *p, const double *nearHz, const double *nearDb, uint32_t nearN,
                               const double *farHz, const double *farDb, uint32_t farN, double *gridOut, double *corrOut,
                               double *predOut, uint32_t capacity, n60_xover_lin_report *report) {
    if (!linValid(p) || !ascending(nearHz, nearDb, nearN) || !gridOut || !corrOut || !predOut || !report) return N60_XOVER_ERR_ARGUMENT;
    const bool useFar = p->merge_hz > 0.0 && farN > 0;
    if (useFar && !ascending(farHz, farDb, farN)) return N60_XOVER_ERR_ARGUMENT;
    const uint32_t n = gridCount(p->sample_rate);
    if (capacity < n || n > N60_XOVER_LIN_MAX_POINTS) return N60_XOVER_ERR_ARGUMENT;
    const double width = p->smoothing_octaves > 0.0 ? p->smoothing_octaves : 1.0 / 6.0;
    const double band = p->band_octaves > 0.0 ? p->band_octaves : 1.0;
    const double cap = p->max_boost_db > 0.0 ? p->max_boost_db : kBoostCapDb;
    const double top = gridHz(n - 1);
    const double lo = p->highpass ? p->highpass->corner_hz : kGridStartHz;
    const double hi = p->lowpass ? p->lowpass->corner_hz : top;
    if (!(lo >= kGridStartHz) || !(hi > lo) || hi > 0.49 * p->sample_rate) return N60_XOVER_ERR_CORNER;

    std::vector<double> measured(n);
    double offset = 0.0;
    if (useFar) {
        double sum = 0.0;
        for (int k = 0; k < 16; ++k) {
            const double hz = p->merge_hz / std::exp2(0.585 * static_cast<double>(k) / 15.0);  // merge / 1.5 .. merge
            sum += smoothedAt(nearHz, nearDb, nearN, hz, width) - smoothedAt(farHz, farDb, farN, hz, width);
        }
        offset = sum / 16.0;
    }
    for (uint32_t i = 0; i < n; ++i) {
        const double hz = gridHz(i);
        double m = smoothedAt(nearHz, nearDb, nearN, hz, width);
        if (useFar) {
            const double w = std::fmin(1.0, std::fmax(0.0, std::log2(hz / p->merge_hz) * 3.0 + 0.5));
            const double s = w * w * (3.0 - 2.0 * w);
            m = (1.0 - s) * m + s * (smoothedAt(farHz, farDb, farN, hz, width) + offset);
        }
        measured[i] = m;
        gridOut[i] = hz;
    }

    double sum = 0.0, count = 0.0;
    for (uint32_t i = 0; i < n; ++i) {
        if (gridOut[i] >= lo && gridOut[i] <= hi) { sum += measured[i]; count += 1.0; }
    }
    if (count < 2.0) return N60_XOVER_ERR_CORNER;
    const double reference = sum / count;

    *report = n60_xover_lin_report{};
    report->point_count = n;
    report->passband_low_hz = lo;
    report->passband_high_hz = hi;
    report->reference_db = reference;
    double beforeMin = 1e300, beforeMax = -1e300, afterMin = 1e300, afterMax = -1e300;
    const double edgeLo = lo / std::exp2(band), edgeHi = hi * std::exp2(band);
    for (uint32_t i = 0; i < n; ++i) {
        const double hz = gridOut[i];
        double c = 0.0;
        if (hz >= edgeLo && hz <= edgeHi) {
            c = reference - measured[i];
            if (c > cap) { c = cap; report->boost_capped = 1; }
            if (hz < lo && c > 0.0) { c = 0.0; report->boost_capped = 1; }
            c = std::fmax(c, kMaxCutDb);
            const double fade = std::fmin(std::fmin(1.0, std::log2(hz / edgeLo) * 3.0), std::fmin(1.0, std::log2(edgeHi / hz) * 3.0));
            c *= fade;
        }
        corrOut[i] = c;
        predOut[i] = measured[i] + c;
        report->max_boost_db = std::fmax(report->max_boost_db, c);
        report->max_cut_db = std::fmin(report->max_cut_db, c);
        if (hz >= lo && hz <= hi) {
            beforeMin = std::fmin(beforeMin, measured[i]);
            beforeMax = std::fmax(beforeMax, measured[i]);
            afterMin = std::fmin(afterMin, predOut[i]);
            afterMax = std::fmax(afterMax, predOut[i]);
        }
    }
    report->ripple_before_db = beforeMax - beforeMin;
    report->ripple_after_db = afterMax - afterMin;
    return N60_XOVER_OK;
}

int n60_xover_linearise_synthesize(const n60_xover_lin_params *p, const double *grid, const double *corr, uint32_t points,
                                   uint32_t delayIn, float *full, uint64_t fullCap, float *low, uint64_t lowCap,
                                   n60_xover_fir_report *report) {
    if (!linValid(p) || !grid || !corr || points < 2 || !full || !report) return N60_XOVER_ERR_ARGUMENT;
    for (uint32_t i = 0; i < points; ++i) {
        if (!std::isfinite(grid[i]) || !std::isfinite(corr[i]) || !(grid[i] > 0.0) || (i > 0 && !(grid[i] > grid[i - 1]))) {
            return N60_XOVER_ERR_ARGUMENT;
        }
    }
    const double fs = p->sample_rate;
    if (p->linear_phase) {
        LinAmplitude a{};
        a.grid = grid;
        a.correction = corr;
        a.count = points;
        double lowest = 1e300;
        if (p->highpass) {
            const int s = n60_xover_design(p->highpass, 1, fs, &a.target.hp);
            if (s != N60_XOVER_OK) return s;
            a.target.hasHp = true;
            lowest = std::fmin(lowest, p->highpass->corner_hz);
        }
        if (p->lowpass) {
            const int s = n60_xover_design(p->lowpass, 0, fs, &a.target.lp);
            if (s != N60_XOVER_OK) return s;
            a.target.hasLp = true;
            lowest = std::fmin(lowest, p->lowpass->corner_hz);
        }
        a.target.fs = fs;
        uint32_t delay = delayIn;
        if (delay == 0) {
            const double band = p->band_octaves > 0.0 ? p->band_octaves : 1.0;
            delay = static_cast<uint32_t>(std::fmin(262144.0, std::fmax(32.0, std::round(5.0 * fs / (lowest / std::exp2(band))))));
        }
        if (delay > 262144u) return N60_XOVER_ERR_ARGUMENT;
        n60_xover_fir_report plan;
        firReport(delay, fs, &plan);
        n60_correct_two_band_report r{};
        const int32_t status = n60_correct_synthesize_linear_phase(fs, delay, linAmplitude, &a, full, fullCap, low, lowCap, &r);
        if (status != N60_CORRECT_OK) return status == N60_CORRECT_ERR_ARGUMENT ? N60_XOVER_ERR_ARGUMENT : N60_XOVER_ERR_SYNTH;
        *report = plan;
        return N60_XOVER_OK;
    }
    // Minimum phase: the correction alone. Tap count: about six periods of the lowest corrected frequency, 1024 .. 32768.
    const double lowest = std::fmax(grid[0], p->highpass ? p->highpass->corner_hz / 2.0 : grid[0]);
    const uint64_t wanted = nextPow2Local(static_cast<uint64_t>(std::ceil(6.0 * fs / lowest)));
    const uint32_t taps = static_cast<uint32_t>(std::min<uint64_t>(32768, std::max<uint64_t>(1024, wanted)));
    if (fullCap < taps) return N60_XOVER_ERR_SYNTH;
    n60_correct_minphase_params mp{};
    n60_correct_minphase_defaults(fs, taps, &mp);
    mp.low_hz = 0.0;
    mp.high_hz = 0.49 * fs;
    if (n60_correct_minphase_synthesize(&mp, grid, corr, points, full, fullCap) != N60_CORRECT_OK) return N60_XOVER_ERR_SYNTH;
    uint32_t peak = 0;
    for (uint32_t i = 1; i < taps; ++i) {
        if (std::fabs(full[i]) > std::fabs(full[peak])) peak = i;
    }
    *report = n60_xover_fir_report{};
    report->decimation = 1;
    report->full_tap_count = taps;
    report->group_delay_frames = peak;
    report->latency_frames = 256 + peak;
    return N60_XOVER_OK;
}

int n60_xover_fir_magnitude_db(double fs, const n60_xover_fir_report *r, const float *full, const float *low,
                               const double *freqs, uint32_t count, double *magDb) {
    if (!r || !full || !freqs || !magDb || r->full_tap_count == 0 || !(fs >= 8000.0)) return N60_XOVER_ERR_ARGUMENT;
    std::vector<double> phase(count);
    const int32_t s = n60_correct_two_band_response(fs, r->decimation, r->extra_delay_frames, r->group_delay_frames, full,
                                                    r->full_tap_count, low, r->low_tap_count, freqs, count, magDb, phase.data());
    return s == N60_CORRECT_OK ? N60_XOVER_OK : N60_XOVER_ERR_ARGUMENT;
}

}  // extern "C"
