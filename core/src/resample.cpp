// E7 S2: control-plane Kaiser sinc resampler (see core/include/n60/resample.h for the derivation and rules).
#include "n60/resample.h"

#include <cmath>
#include <cstring>
#include <new>

namespace {

constexpr double kPi = 3.14159265358979323846;
// Two Kaiser kernels share the formula: crossings = window half length in zero crossings of the cut-off sinc.
// Standard (0): 32 crossings, beta 8.6; bit-compatible with the E6 S9c Swift resampler (binaural HRIRs, kept).
// Precise (1): 66 crossings, beta 10.2: flat to 0.01 dB at 0.9 x the lower Nyquist and at least 100 dB down from 1.0 x.
struct Kernel { double crossings, beta; };
Kernel kernelFor(int quality) { return quality == N60_RESAMPLE_PRECISE ? Kernel{66.0, 10.2} : Kernel{32.0, 8.6}; }

double besselI0(double x) {
    double sum = 1.0, term = 1.0, k = 1.0;
    while (term > 1.0e-12 * sum) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        k += 1.0;
    }
    return sum;
}

bool goodRate(double r) { return std::isfinite(r) && r > 0.0; }

}  // namespace

extern "C" {

uint32_t n60_resample_output_count(uint32_t in_count, double src_rate, double dst_rate) {
    if (in_count == 0u || !goodRate(src_rate) || !goodRate(dst_rate)) return in_count;
    const double v = std::ceil(static_cast<double>(in_count) * dst_rate / src_rate);
    if (!(v < 4294967295.0)) return UINT32_MAX;
    return v < 1.0 ? 1u : static_cast<uint32_t>(v);
}

int n60_resample_batch(const float *in, uint32_t in_count, uint32_t signal_count, double src_rate, double dst_rate,
                       int quality, float *out, uint64_t out_capacity) {
    if (quality != N60_RESAMPLE_STANDARD && quality != N60_RESAMPLE_PRECISE) return 0;
    const Kernel k = kernelFor(quality);
    const double kBeta = k.beta;
    if (in == nullptr || out == nullptr || in_count == 0u || signal_count == 0u || !goodRate(src_rate) ||
        !goodRate(dst_rate))
        return 0;
    const uint32_t outCount = n60_resample_output_count(in_count, src_rate, dst_rate);
    if (outCount == UINT32_MAX) return 0;
    if (out_capacity < static_cast<uint64_t>(outCount) * signal_count) return 0;

    if (std::fabs(dst_rate - src_rate) < 0.5) {
        std::memcpy(out, in, sizeof(float) * static_cast<size_t>(in_count) * signal_count);
        return 1;
    }

    const double step = src_rate / dst_rate;
    const double cutoff = 0.95 * (dst_rate < src_rate ? dst_rate / src_rate : 1.0);
    const double halfWidth = k.crossings / cutoff;
    const double i0Beta = besselI0(kBeta);
    const size_t scratchCount = static_cast<size_t>(std::ceil(2.0 * halfWidth)) + 2u;
    double *kernel = new (std::nothrow) double[scratchCount];
    if (kernel == nullptr) return 0;

    for (uint32_t j = 0; j < outCount; ++j) {
        const double position = static_cast<double>(j) * step;
        const double firstD = std::ceil(position - halfWidth);
        const double lastD = std::floor(position + halfWidth);
        const int64_t first = firstD < 0.0 ? 0 : static_cast<int64_t>(firstD);
        const int64_t last = lastD > static_cast<double>(in_count - 1u) ? static_cast<int64_t>(in_count) - 1
                                                                          : static_cast<int64_t>(lastD);
        if (first > last) {
            for (uint32_t s = 0; s < signal_count; ++s) out[static_cast<size_t>(s) * outCount + j] = 0.0f;
            continue;
        }
        const size_t n = static_cast<size_t>(last - first + 1);
        for (size_t o = 0; o < n; ++o) {
            const double distance = position - static_cast<double>(first + static_cast<int64_t>(o));
            const double x = cutoff * distance;
            const double sinc = std::fabs(x) < 1.0e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
            const double ratio = distance / halfWidth;
            const double arg = 1.0 - ratio * ratio;
            const double window = besselI0(kBeta * std::sqrt(arg > 0.0 ? arg : 0.0)) / i0Beta;
            kernel[o] = cutoff * sinc * window * step;
        }
        for (uint32_t s = 0; s < signal_count; ++s) {
            const float *src = in + static_cast<size_t>(s) * in_count + first;
            double acc = 0.0;
            for (size_t o = 0; o < n; ++o) acc += static_cast<double>(src[o]) * kernel[o];
            out[static_cast<size_t>(s) * outCount + j] = static_cast<float>(acc);
        }
    }
    delete[] kernel;
    return 1;
}

}  // extern "C"
