// E13 S11: generic HRTF generator (n60/hrtf.h). Design maths only; never on an audio callback.
#include "n60/hrtf.h"

#include <cmath>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kRadius = 0.0875;
constexpr double kSpeed = 343.0;
constexpr double kEarAzimuthDeg = 100.0;
constexpr int kKernelHalf = 8;      // 16-tap kernel: indices -7..8 around the integer delay
constexpr double kKaiserBeta = 8.0;

double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    const double q = x * x * 0.25;
    for (int k = 1; k < 60; ++k) {
        term *= q / (static_cast<double>(k) * static_cast<double>(k));
        sum += term;
        if (term < 1e-17 * sum) break;
    }
    return sum;
}

double sinc(double x) {
    if (std::fabs(x) < 1e-12) return 1.0;
    return std::sin(kPi * x) / (kPi * x);
}

bool validAngles(double az, double el) {
    return std::isfinite(az) && std::isfinite(el) && az >= -180.0 && az <= 180.0 && el >= -90.0 && el <= 90.0;
}

// Angle between the source direction and an ear (earSign -1 left, +1 right), radians.
double earAngle(double az, double el, int earSign) {
    const double d = kPi / 180.0;
    const double ca = std::cos(el * d), sa = std::sin(el * d);
    const double sx = ca * std::cos(az * d), sy = ca * std::sin(az * d), sz = sa;
    const double ex = std::cos(earSign * kEarAzimuthDeg * d), ey = std::sin(earSign * kEarAzimuthDeg * d);
    double c = sx * ex + sy * ey + sz * 0.0;
    if (c > 1.0) c = 1.0;
    if (c < -1.0) c = -1.0;
    return std::acos(c);
}

double arrivalDelay(double psi) {
    const double ac = kRadius / kSpeed;
    const double t = psi < 0.5 * kPi ? -ac * std::cos(psi) : ac * (psi - 0.5 * kPi);
    return t + ac;
}

double shadowAlpha(double psi) { return 1.05 + 0.95 * std::cos(psi * 180.0 / 150.0); }

}  // namespace

extern "C" uint32_t n60_hrtf_abi_version(void) { return N60_HRTF_ABI_VERSION; }

extern "C" uint32_t n60_hrtf_generic_taps(double sample_rate) {
    if (!std::isfinite(sample_rate) || sample_rate < N60_HRTF_MIN_RATE || sample_rate > N60_HRTF_MAX_RATE) return 0;
    const double n = std::ceil(0.003 * sample_rate);
    return n < 64.0 ? 64u : static_cast<uint32_t>(n);
}

extern "C" int n60_hrtf_generic_model_at(double az, double el, n60_hrtf_generic_model *out) {
    if (out == nullptr || !validAngles(az, el)) return N60_HRTF_ERR_ARGUMENT;
    for (int e = 0; e < 2; ++e) {
        const double psi = earAngle(az, el, e == 0 ? -1 : 1);
        out->delay_s[e] = arrivalDelay(psi);
        out->hf_gain[e] = shadowAlpha(psi);
    }
    out->shadow_s = kRadius / (2.0 * kSpeed);
    return N60_HRTF_OK;
}

extern "C" int n60_hrtf_generic_ir(double sample_rate, double az, double el, uint32_t taps, float *left, float *right) {
    const uint32_t need = n60_hrtf_generic_taps(sample_rate);
    if (need == 0 || taps < need || left == nullptr || right == nullptr || !validAngles(az, el)) return N60_HRTF_ERR_ARGUMENT;
    n60_hrtf_generic_model model;
    n60_hrtf_generic_model_at(az, el, &model);
    float *outs[2] = {left, right};
    const double k = 2.0 * sample_rate * model.shadow_s;  // T * K with K = 2 fs
    std::vector<double> shadow(taps);
    std::vector<double> acc(taps);
    for (int e = 0; e < 2; ++e) {
        const double alpha = model.hf_gain[e];
        const double b0 = (1.0 + alpha * k) / (1.0 + k), b1 = (1.0 - alpha * k) / (1.0 + k), a1 = (1.0 - k) / (1.0 + k);
        double yPrev = 0.0;
        for (uint32_t n = 0; n < taps; ++n) {
            const double x0 = n == 0 ? 1.0 : 0.0, x1 = n == 1 ? 1.0 : 0.0;
            const double y = b0 * x0 + b1 * x1 - a1 * yPrev;
            shadow[n] = y;
            yPrev = y;
        }
        const double d = model.delay_s[e] * sample_rate + static_cast<double>(N60_HRTF_GUARD_FRAMES);
        const double base = std::floor(d), frac = d - base;
        double kernel[2 * kKernelHalf];
        double ksum = 0.0;
        const double i0b = besselI0(kKaiserBeta);
        for (int m = -kKernelHalf + 1; m <= kKernelHalf; ++m) {
            const double u = static_cast<double>(m) - frac;
            const double r = u / static_cast<double>(kKernelHalf);
            const double w = std::fabs(r) >= 1.0 ? 0.0 : besselI0(kKaiserBeta * std::sqrt(1.0 - r * r)) / i0b;
            const double v = sinc(u) * w;
            kernel[m + kKernelHalf - 1] = v;
            ksum += v;
        }
        for (uint32_t n = 0; n < taps; ++n) acc[n] = 0.0;
        for (int m = -kKernelHalf + 1; m <= kKernelHalf; ++m) {
            const double kv = kernel[m + kKernelHalf - 1] / ksum;
            const int64_t shift = static_cast<int64_t>(base) + m;
            for (int64_t n = shift; n < static_cast<int64_t>(taps); ++n) {
                if (n < 0) continue;
                acc[static_cast<size_t>(n)] += kv * shadow[static_cast<size_t>(n - shift)];
            }
        }
        for (uint32_t n = 0; n < taps; ++n) outs[e][n] = static_cast<float>(acc[n]);
    }
    return N60_HRTF_OK;
}
