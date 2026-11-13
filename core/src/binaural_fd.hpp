// The binaural stage's fractional-delay kernel (E13 S5, ABI v39), shared by the stage's delay line (stages_matrix.cpp)
// and the host-side response aligner (layout.cpp), so the stage's delay and the aligner's advance are the same
// filter and cancel at the grid sets.
//
// Kaiser-windowed sinc, 16 taps (m = -7 .. 8), beta 6.5. coefficient(m, a) = s(m - a) for a fractional delay a in
// [0, 1): y[n] = sum_m s(m - a) x[u - m], with u the integer position. At a = 0 it is exactly a unit tap at m = 0.
// The table holds kFdPhases + 1 phases; a stage interpolates linearly between neighbours (error below -80 dB).
#ifndef N60_BINAURAL_FD_HPP
#define N60_BINAURAL_FD_HPP

#include <cmath>
#include <cstdint>

#include "halfband.hpp"

namespace n60 {

constexpr uint32_t kFdTaps = 16;
constexpr uint32_t kFdFirst = 7;     // m runs from -kFdFirst to kFdTaps - 1 - kFdFirst
constexpr uint32_t kFdHalf = 8;      // window half-width; the line's latency
constexpr uint32_t kFdPhases = 64;

// The windowed sinc at x (|x| < kFdHalf, else 0). Exactly 1 at 0 and exactly 0 at every other integer.
inline double fdKernel(double x) {
    constexpr double kPi = 3.14159265358979323846;
    constexpr double kBeta = 6.5;
    if (std::fabs(x) >= static_cast<double>(kFdHalf)) return 0.0;
    if (x == std::round(x)) return x == 0.0 ? 1.0 : 0.0;
    const double t = x / static_cast<double>(kFdHalf);
    return std::sin(kPi * x) / (kPi * x) * halfbandBesselI0(kBeta * std::sqrt(1.0 - t * t)) / halfbandBesselI0(kBeta);
}

// Tap m (index m + kFdFirst) at fractional delay a. Double precision, offline.
inline double fdCoefficient(int m, double a) { return fdKernel(static_cast<double>(m) - a); }

// table[phase * kFdTaps + tap], phase 0..kFdPhases.
inline void fdTable(float *table) {
    for (uint32_t p = 0; p <= kFdPhases; ++p) {
        const double a = static_cast<double>(p) / static_cast<double>(kFdPhases);
        for (uint32_t t = 0; t < kFdTaps; ++t) {
            table[p * kFdTaps + t] = static_cast<float>(fdCoefficient(static_cast<int>(t) - static_cast<int>(kFdFirst), a));
        }
    }
}

}  // namespace n60

#endif
