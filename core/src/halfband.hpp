// The half-band filter shared by the two-band ROOM_FIR stage (stages_dsp.cpp) and its designer (correct/synth.cpp), so
// the designer's model of the resampler is the stage's own coefficients (E10 S8).
//
// Kaiser-windowed half-band, 4K+1 = 73 taps, cutoff a quarter of the rate, beta 11 (about 110 dB stop band). The centre
// tap is 0.5 and the odd off-centre taps are normalised so the DC gain is exactly one. Offline helper, double precision.
#ifndef N60_HALFBAND_HPP
#define N60_HALFBAND_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace n60 {

constexpr uint32_t kHalfbandK = 18;

inline double halfbandBesselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 60; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < 1e-18 * sum) break;
    }
    return sum;
}

// h[2i+1] for i = 0 .. 2K-1 (the odd taps from offset 1), as the stage stores them (float).
inline void halfbandOddTaps(float *hodd) {
    constexpr double kBeta = 11.0;
    constexpr double kPi = 3.14159265358979323846;
    constexpr uint32_t kOdd = 2 * kHalfbandK;
    const int N = static_cast<int>(4 * kHalfbandK);
    double h[kOdd], sum = 0.0;
    for (uint32_t i = 0; i < kOdd; ++i) {
        const int n = static_cast<int>(2 * i + 1);
        const double m = n - static_cast<int>(2 * kHalfbandK);
        const double sinc = std::sin(0.5 * kPi * m) / (kPi * m);  // 2 fc sinc(2 fc m), fc = 1/4
        const double t = 2.0 * n / N - 1.0;
        h[i] = sinc * halfbandBesselI0(kBeta * std::sqrt(std::max(0.0, 1.0 - t * t))) / halfbandBesselI0(kBeta);
        sum += h[i];
    }
    const double norm = 0.5 / sum;
    for (uint32_t i = 0; i < kOdd; ++i) hodd[i] = static_cast<float>(h[i] * norm);
}

}  // namespace n60

#endif
