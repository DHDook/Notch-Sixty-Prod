// E21 S10a: helpers shared by the ANC design translation units (complex arithmetic matching the Swift
// ActiveQuietZoneComplex, the limits, the bass-plant assessment). Internal to core/src/anc_design.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "n60/anc_design.h"
#include "../nothrow_array.hpp"

namespace n60::anc_design {

struct C {
    double re{0}, im{0};
};

inline C make(const n60_anc_complex &z) { return C{z.re, z.im}; }
inline n60_anc_complex out(const C &z) { return n60_anc_complex{z.re, z.im}; }
inline C operator+(C a, C b) { return {a.re + b.re, a.im + b.im}; }
inline C operator-(C a, C b) { return {a.re - b.re, a.im - b.im}; }
inline C operator-(C a) { return {-a.re, -a.im}; }
inline C operator*(C a, C b) { return {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
inline C operator*(C a, double s) { return {a.re * s, a.im * s}; }
inline C operator/(C a, double s) { return {a.re / s, a.im / s}; }
inline C conj(C a) { return {a.re, -a.im}; }
inline double mag(C a) { return std::hypot(a.re, a.im); }
inline bool finite(C a) { return std::isfinite(a.re) && std::isfinite(a.im); }
inline C operator/(C a, C b) {
    const double d = b.re * b.re + b.im * b.im;
    if (!std::isfinite(d) || !(d > 1.0e-24)) return {NAN, NAN};
    return {(a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d};
}

inline constexpr double kMinimumCoherence = 0.85;
inline constexpr double kMaximumLeakage = 0.10;
inline constexpr double kMinimumReduction = 0.25;
inline constexpr double kMinimumAuthority = 1.0e-5;
inline constexpr double kMinimumReserve = 0.002;
inline constexpr double kPeakGainLimit = 0.06309573444801933;
inline constexpr double kMaxFitError = 0.18;
inline constexpr double kMinRate = 1000.0;
inline constexpr double kMaxRate = 768000.0;
inline constexpr double kTieWeight = 10.0;
inline constexpr double kTieTolerance = 0.05;
inline constexpr double kPi = 3.14159265358979323846;

struct Plant {
    int32_t mode;
    double scale;
};

inline Plant assess(const n60_anc_seat_band &b) {
    const double db = n60_anc_bass_condition_db(b.leftSecondaryAtListener, b.rightSecondaryAtListener,
                                                b.leftLeakageAtReference, b.rightLeakageAtReference);
    Plant p{};
    p.mode = n60_anc_bass_mode(db, &p.scale);
    return p;
}

inline double leakageLimit(const n60_anc_seat_band &b, bool bass, double toleranceDB) {
    if (!bass || assess(b).mode == N60_ANC_BASS_FREE) return kMaximumLeakage;
    return kMaximumLeakage / std::pow(10.0, toleranceDB / 20.0);
}

// Indices of `bands` in ascending frequency order (stable).
inline bool sortedOrder(const n60_anc_seat_band *bands, uint32_t n, n60::NothrowArray<uint32_t> &order) {
    if (!order.allocate(n)) return false;
    for (uint32_t i = 0; i < n; ++i) order[i] = i;
    std::stable_sort(&order[0], &order[0] + n,
                     [&](uint32_t x, uint32_t y) { return bands[x].frequencyHz < bands[y].frequencyHz; });
    return true;
}

}  // namespace n60::anc_design
