// E13 S11: behavioural tests for the generic HRTF generator (n60/hrtf.h) at the eight standard rates.
// Closed forms are those in the header (Woodworth delay, Brown-Duda head shadow); no measured data.
#include "n60/hrtf.h"

#include <cmath>
#include <cstdio>
#include <vector>

static int failures = 0;
#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); \
            ++failures;                                                        \
        }                                                                      \
    } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static double centroid(const std::vector<float> &h, double *sum) {
    double s = 0, m = 0;
    for (size_t n = 0; n < h.size(); ++n) { s += h[n]; m += static_cast<double>(n) * h[n]; }
    *sum = s;
    return m / s;
}

static double magnitude(const std::vector<float> &h, double rate, double f) {
    double re = 0, im = 0;
    for (size_t n = 0; n < h.size(); ++n) {
        const double w = 2.0 * kPi * f * static_cast<double>(n) / rate;
        re += h[n] * std::cos(w);
        im -= h[n] * std::sin(w);
    }
    return std::sqrt(re * re + im * im);
}

// |H(j w)| of (1 + alpha T s) / (1 + T s).
static double analyticMagnitude(double alpha, double T, double f) {
    const double wT = 2.0 * kPi * f * T;
    return std::sqrt((1 + alpha * alpha * wT * wT) / (1 + wT * wT));
}

int main() {
    const double dirs[][2] = {{0, 0}, {-30, 0}, {30, 0}, {-90, 0}, {90, 0}, {110, 0}, {-150, 0}, {180, 0}, {45, 45}, {-90, 60}, {0, -30}};
    for (double rate : kRates) {
        const uint32_t taps = n60_hrtf_generic_taps(rate);
        CHECK(taps >= 64 && taps <= 1200, "tap count range");
        std::vector<float> l(taps), r(taps), l2(taps), r2(taps);
        for (const auto &d : dirs) {
            n60_hrtf_generic_model m;
            CHECK(n60_hrtf_generic_model_at(d[0], d[1], &m) == N60_HRTF_OK, "model");
            CHECK(n60_hrtf_generic_ir(rate, d[0], d[1], taps, l.data(), r.data()) == N60_HRTF_OK, "ir");
            CHECK(n60_hrtf_generic_ir(rate, d[0], d[1], taps, l2.data(), r2.data()) == N60_HRTF_OK, "ir again");
            CHECK(l == l2 && r == r2, "deterministic: same input gives the same taps");
            const std::vector<float> *ears[2] = {&l, &r};
            for (int e = 0; e < 2; ++e) {
                double sum;
                const double c = centroid(*ears[e], &sum);
                CHECK(std::fabs(sum - 1.0) < 2e-3, "DC gain is 1");
                // Centroid = group delay at DC = arrival delay + guard + (1 - alpha) T.
                const double expect = (m.delay_s[e] + (1.0 - m.hf_gain[e]) * m.shadow_s) * rate + N60_HRTF_GUARD_FRAMES;
                if (std::fabs(c - expect) > 0.1) {
                    std::fprintf(stderr, "rate %.0f az %g el %g ear %d centroid %.4f expect %.4f\n", rate, d[0], d[1], e, c, expect);
                    ++failures;
                }
                // Level: magnitude at a band well below Nyquist follows the analytic shadow response.
                for (double f : {500.0, 2000.0}) {
                    if (f > 0.05 * rate) continue;
                    const double got = 20 * std::log10(magnitude(*ears[e], rate, f));
                    const double want = 20 * std::log10(analyticMagnitude(m.hf_gain[e], m.shadow_s, f));
                    if (std::fabs(got - want) > 0.4) {
                        std::fprintf(stderr, "rate %.0f az %g ear %d f %g got %.3f want %.3f dB\n", rate, d[0], e, f, got, want);
                        ++failures;
                    }
                }
            }
        }
        // Interaural time difference of a source at 90 degrees right matches the closed form, left ear later.
        n60_hrtf_generic_model m;
        n60_hrtf_generic_model_at(90, 0, &m);
        CHECK(m.delay_s[0] > m.delay_s[1], "far (left) ear is later for a right source");
        const double itd = m.delay_s[0] - m.delay_s[1];
        const double ac = 0.0875 / 343.0;
        const double psiNear = 10.0 * kPi / 180.0, psiFar = 190.0 * kPi / 180.0 > kPi ? kPi : 190.0 * kPi / 180.0;
        (void)psiFar;
        // Near ear (100 deg) is 10 degrees from the source; far ear (-100) is 170 degrees away.
        const double expectItd = ac * (170.0 * kPi / 180.0 - 0.5 * kPi) + ac * std::cos(psiNear);
        CHECK(std::fabs(itd - expectItd) < 1e-9, "ITD closed form");
        // Head shadow: near ear has more high-frequency level than the far ear.
        CHECK(m.hf_gain[1] > m.hf_gain[0], "near ear brighter");
        // Symmetry: mirrored azimuth swaps ears.
        n60_hrtf_generic_ir(rate, 40, 10, taps, l.data(), r.data());
        n60_hrtf_generic_ir(rate, -40, 10, taps, l2.data(), r2.data());
        CHECK(l == r2 && r == l2, "mirror symmetry");
    }
    // Argument checks.
    float a[512], b[512];
    CHECK(n60_hrtf_generic_taps(0) == 0, "bad rate");
    CHECK(n60_hrtf_generic_ir(48000, 0, 0, 10, a, b) == N60_HRTF_ERR_ARGUMENT, "too few taps");
    CHECK(n60_hrtf_generic_ir(48000, 200, 0, 512, a, b) == N60_HRTF_ERR_ARGUMENT, "bad azimuth");
    CHECK(n60_hrtf_generic_ir(48000, 0, 0, 512, nullptr, b) == N60_HRTF_ERR_ARGUMENT, "null");
    if (failures == 0) std::puts("hrtf ok");
    return failures == 0 ? 0 : 1;
}
