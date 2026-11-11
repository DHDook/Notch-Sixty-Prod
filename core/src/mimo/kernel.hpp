// The MIMO resampling kernel (E19 S2 design, S4 stage). One definition for the offline designer and the realtime stage, so
// the stage runs the exact filter the design assumed.
//
// Kaiser-windowed sinc (beta 8), cutoff 0.4 of the low rate fs/D, half width 5 low-rate samples (5 D input samples), DC
// gain 1, 10 D + 1 taps, symmetric. Decimation keeps every D-th output; interpolation zero-stuffs by D and filters with the
// same kernel scaled by D. Offline helper, double precision.
#ifndef N60_MIMO_KERNEL_HPP
#define N60_MIMO_KERNEL_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace n60::mimo {

constexpr uint32_t kKernelHalfWidthFactor = 5;
constexpr uint32_t kMaxDecimation = 128;

inline uint32_t kernelHalf(uint32_t d) { return kKernelHalfWidthFactor * d; }
inline uint32_t kernelTaps(uint32_t d) { return 2 * kernelHalf(d) + 1; }

inline double kernelBesselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 60; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < 1e-18 * sum) break;
    }
    return sum;
}

// Writes kernelTaps(d) values.
inline void designKernel(uint32_t d, double *h) {
    constexpr double kPi = 3.14159265358979323846;
    const int half = static_cast<int>(kernelHalf(d));
    const double beta = 8.0, denom = kernelBesselI0(beta);
    const double cutoff = 0.8 / d;   // 0.4 of the low rate, in cycles per input sample times 2
    double sum = 0;
    for (int i = -half; i <= half; ++i) {
        const double x = cutoff * i;
        const double sinc = (i == 0) ? cutoff : std::sin(kPi * x) / (kPi * i);
        const double r = static_cast<double>(i) / half;
        const double w = kernelBesselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / denom;
        h[i + half] = sinc * w;
        sum += h[i + half];
    }
    for (int i = 0; i < 2 * half + 1; ++i) h[i] /= sum;
}

}  // namespace n60::mimo

#endif
