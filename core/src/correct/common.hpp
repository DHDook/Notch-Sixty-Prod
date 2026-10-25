// Shared helpers for the room-correction design core (E10 S1).
//
// Offline only: control or worker thread, allocates freely, never called from an audio
// callback. Double precision throughout, fixed summation order, no threads.
#ifndef N60_CORRECT_COMMON_HPP
#define N60_CORRECT_COMMON_HPP

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "n60/correct.h"

namespace n60::correct {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kLn10 = 2.30258509299404568401799145468436421;

inline uint64_t nextPow2(uint64_t n) {
    uint64_t p = 2;
    while (p < n) p <<= 1;
    return p;
}

inline double dbToNeper(double db) { return db * kLn10 / 20.0; }

// Frequency of grid point i.
inline double gridFrequency(uint32_t i) {
    return N60_CORRECT_GRID_START_HZ * std::exp2(static_cast<double>(i) / N60_CORRECT_GRID_PER_OCTAVE);
}

// Position of a frequency on the grid, in (fractional) grid points; negative below 20 Hz.
inline double gridPosition(double hz) {
    return N60_CORRECT_GRID_PER_OCTAVE * std::log2(hz / N60_CORRECT_GRID_START_HZ);
}

// Linear interpolation of a value given on an ascending frequency list, linear in log
// frequency. Returns `outside` beyond the first and last points.
double interpolateLogFrequency(const double *frequencies, const double *values, size_t count, double hz,
                               double outside);

// Linear interpolation of a value given on the correction grid; `outside` beyond it.
double interpolateGrid(const double *values, double hz, double outside);

// Minimum phase of a magnitude. `log_magnitude` holds n/2+1 natural-log magnitudes of an
// n-point real spectrum; writes the n/2+1 phases (radians, H = |H| e^{j phase}).
bool minimumPhase(const std::vector<double> &log_magnitude, uint64_t n, std::vector<double> &phase);

// Power-domain box smoothing of grid values of power (not dB), half width in grid points.
void smoothPower(std::vector<double> &power, int half_width);

// Raised-cosine window over [low, high] (1 inside, a third-octave transition at each edge).
double edgeWindow(double hz, double low_hz, double high_hz);

}  // namespace n60::correct

#endif
