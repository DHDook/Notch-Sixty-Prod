// E7 S1: capacities are times. A buffer that must hold a duration is `ceil(seconds * rate)` frames, derived at build
// time, so the duration holds at every device rate. Swift's twin is `RateCapacity.frames(seconds:sampleRate:)`.
// Control plane and build time only; not for the render path.
#pragma once

#include <cmath>
#include <cstdint>

namespace n60 {

// ceil(seconds * rate), saturating at UINT32_MAX; 0 for a non-finite or non-positive input.
inline uint32_t framesFor(double seconds, double rate) {
    const double v = std::ceil(seconds * rate);
    if (!std::isfinite(v) || v <= 0.0) return 0u;
    return v >= 4294967295.0 ? UINT32_MAX : static_cast<uint32_t>(v);
}

}  // namespace n60
