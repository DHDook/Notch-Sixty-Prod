// E8 S1: crossover filter library (n60/xover.h) at the eight standard rates.
#include <cmath>
#include <initializer_list>
#include <cstdio>
#include <cstring>

#include "n60/xover.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static n60_xover_spec spec(uint32_t family, uint32_t order, double hz) {
    n60_xover_spec s{};
    s.struct_size = sizeof(s);
    s.family = family;
    s.order = order;
    s.corner_hz = hz;
    return s;
}

static double magDb(const n60_xover_cascade &c, double fs, double hz) {
    double db = 0;
    n60_xover_magnitude_db(&c, fs, hz, &db);
    return db;
}

static const char *familyName(uint32_t f) { return f == 0 ? "BW" : f == 1 ? "Bessel" : "LR"; }

static void forEachSpec(void (*fn)(uint32_t family, uint32_t order)) {
    for (uint32_t order = 1; order <= 8; ++order) { fn(0, order); fn(1, order); }
    for (uint32_t order = 2; order <= 8; order += 2) fn(2, order);
}

static void testCorner(uint32_t family, uint32_t order) {
    const double expected = family == 2 ? -6.0206 : -3.0103;
    for (double fs : kRates) {
        for (double fc : {100.0, 1000.0, 3000.0}) {
            for (int hp = 0; hp < 2; ++hp) {
                n60_xover_cascade c;
                const n60_xover_spec s = spec(family, order, fc);
                CHECK(n60_xover_design(&s, hp, fs, &c) == N60_XOVER_OK, "design");
                const double db = magDb(c, fs, fc);
                CHECK(std::fabs(db - expected) < 0.01, "%s%u %s fc=%g fs=%g: %.4f dB (want %.4f)", familyName(family), order,
                      hp ? "HP" : "LP", fc, fs, db, expected);
            }
        }
    }
}

static void testSlope(uint32_t family, uint32_t order) {
    for (double fs : kRates) {
        for (int hp = 0; hp < 2; ++hp) {
            // Low-pass: a low corner so the measurement octave stays far below Nyquist.
            // High-pass: measure well below the corner.
            const double fc = hp ? 0.05 * fs : 0.0002 * fs;
            n60_xover_cascade c;
            const n60_xover_spec s = spec(family, order, fc);
            n60_xover_design(&s, hp, fs, &c);
            const double f1 = hp ? fc / 40.0 : fc * 20.0, f2 = hp ? fc / 20.0 : fc * 40.0;
            const double slope = (magDb(c, fs, f2) - magDb(c, fs, f1)) * (hp ? 1.0 : -1.0);
            const double want = 6.0206 * order;
            CHECK(std::fabs(slope - want) < 0.1, "%s%u %s fs=%g: slope %.3f dB/oct (want %.3f)", familyName(family), order,
                  hp ? "HP" : "LP", fs, slope, want);
        }
    }
}

static void testLrSum() {
    for (double fs : kRates) {
        for (uint32_t order = 2; order <= 8; order += 2) {
            for (double fc : {80.0, 250.0, 2500.0}) {
                const n60_xover_spec s = spec(N60_XOVER_FAMILY_LINKWITZ_RILEY, order, fc);
                double ripple = -1;
                CHECK(n60_xover_sum_ripple_db(&s, &s, n60_xover_lr_inverts_hp(order), fs, &ripple) == N60_XOVER_OK, "ripple");
                CHECK(ripple >= 0 && ripple < 0.001, "LR%u fc=%g fs=%g sum ripple %.6f dB", order, fc, fs, ripple);
                // Without the inversion the 2nd and 6th orders do not sum flat: the helper is load-bearing.
                if (n60_xover_lr_inverts_hp(order)) {
                    n60_xover_sum_ripple_db(&s, &s, 0, fs, &ripple);
                    CHECK(ripple > 20.0, "LR%u uninverted sum should notch (ripple %.3f)", order, ripple);
                }
            }
        }
        // Asymmetric slopes report a real ripple; a matched pair reports none.
        const n60_xover_spec lp = spec(N60_XOVER_FAMILY_LINKWITZ_RILEY, 4, 1000), hp = spec(N60_XOVER_FAMILY_LINKWITZ_RILEY, 8, 1000);
        double ripple = 0;
        n60_xover_sum_ripple_db(&lp, &hp, 0, fs, &ripple);
        CHECK(ripple > 0.5, "asymmetric LR4/LR8 ripple %.3f dB should be reported", ripple);
    }
}

static void testLinkwitz() {
    for (double fs : kRates) {
        const double f0 = 50.0, q0 = 0.707, fp = 25.0, qp = 0.5;
        n60_xover_cascade c;
        CHECK(n60_xover_linkwitz(f0, q0, fp, qp, fs, &c) == N60_XOVER_OK, "linkwitz");
        double worst = 0;
        for (double hz = 10.0; hz <= 1000.0; hz *= std::pow(2.0, 1.0 / 12.0)) {
            const double w0 = 2 * kPi * f0, wp = 2 * kPi * fp, w = 2 * kPi * hz;
            // Analytic |H(jw)| = |(w0^2 - w^2) + j w w0/q0| / |(wp^2 - w^2) + j w wp/qp|.
            const double num = std::hypot(w0 * w0 - w * w, w * w0 / q0), den = std::hypot(wp * wp - w * w, w * wp / qp);
            const double want = 20.0 * std::log10(num / den);
            worst = std::fmax(worst, std::fabs(magDb(c, fs, hz) - want));
        }
        CHECK(worst < 0.01, "Linkwitz transform fs=%g: worst error %.5f dB", fs, worst);
    }
}

static void testStabilityAndDeterminism(uint32_t family, uint32_t order) {
    for (double fs : kRates) {
        for (double frac : {0.0001, 0.01, 0.1, 0.25, 0.45}) {
            for (int hp = 0; hp < 2; ++hp) {
                const n60_xover_spec s = spec(family, order, frac * fs);
                n60_xover_cascade a, b;
                std::memset(&a, 0xAA, sizeof a);
                std::memset(&b, 0x55, sizeof b);
                CHECK(n60_xover_design(&s, hp, fs, &a) == N60_XOVER_OK, "design");
                CHECK(n60_xover_design(&s, hp, fs, &b) == N60_XOVER_OK, "design");
                const double r = n60_xover_max_pole_radius(&a);
                CHECK(r < 1.0, "%s%u %s fc=%.4g*fs: pole radius %.9f", familyName(family), order, hp ? "HP" : "LP", frac, r);
                CHECK(a.count == b.count && std::memcmp(a.sections, b.sections, a.count * sizeof(n60_xover_biquad)) == 0,
                      "design not bit-identical");
            }
        }
    }
}

static void testRejections() {
    n60_xover_cascade c;
    n60_xover_spec s = spec(N60_XOVER_FAMILY_LINKWITZ_RILEY, 3, 1000);
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_ORDER, "LR3 rejected");
    s = spec(N60_XOVER_FAMILY_BUTTERWORTH, 9, 1000);
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_ORDER, "order 9 rejected");
    s = spec(N60_XOVER_FAMILY_BESSEL, 0, 1000);
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_ORDER, "order 0 rejected");
    s = spec(N60_XOVER_FAMILY_BUTTERWORTH, 2, 30000);
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_CORNER, "corner above Nyquist rejected");
    s = spec(N60_XOVER_FAMILY_BUTTERWORTH, 2, std::nan(""));
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_CORNER, "NaN corner rejected");
    s = spec(7, 2, 1000);
    CHECK(n60_xover_design(&s, 0, 48000, &c) == N60_XOVER_ERR_ARGUMENT, "unknown family rejected");
    CHECK(n60_xover_design(nullptr, 0, 48000, &c) == N60_XOVER_ERR_ARGUMENT, "null spec rejected");
    CHECK(n60_xover_linkwitz(50, 0.7, 25, 0, 48000, &c) == N60_XOVER_ERR_ARGUMENT, "zero Q rejected");
    CHECK(n60_xover_abi_version() == N60_XOVER_ABI_VERSION, "abi version");
}

int main() {
    forEachSpec(testCorner);
    forEachSpec(testSlope);
    forEachSpec(testStabilityAndDeterminism);
    testLrSum();
    testLinkwitz();
    testRejections();
    if (failures) { std::fprintf(stderr, "%d failures\n", failures); return 1; }
    std::puts("xover: all checks passed");
    return 0;
}
