// E33 S10 (graph ABI v44): the inter-sample over detector at the chain input (METER_IN). Portable C++20, no platform
// dependence. The detector counts input frames whose reconstructed signal exceeds 0 dBTP (|y| > 1.0): 4x at 44.1 and
// 48 kHz, 2x at 88.2 and 96 kHz, 1x (sample overs) from 176.4 kHz up, the factor rule of the limiter's true-peak guard
// (tpFactorForRate in stages_system.cpp). The up-samplers are the 73-tap Kaiser half-band of halfband.hpp (about 110 dB
// stop band), cascaded for 4x. The audio is never touched.
//
// Realtime record. Allocation: none (all state is in the MeterLane the snapshot arena holds). Synchronisation: one relaxed
// atomic add per block per lane. Latency: 0 (an observer). Sample rate: any rate from 8 kHz to 768 kHz; the factor is
// chosen from the rate at run time. Channels: one detector per lane the METER_IN stage runs on. Reset: the generation
// parameter, a state clear when detection is switched on, and a new snapshot starts with zero history.
#ifndef N60_CORE_INPUT_OVERS_HPP
#define N60_CORE_INPUT_OVERS_HPP

#include <cstdint>

#include "halfband.hpp"

namespace n60 {

constexpr uint32_t kOversOdd = 2 * kHalfbandK;  // 36 odd taps

// One 2x half-band interpolator. The even output is the input delayed by 18 samples, the odd output the point half a sample
// later; both are returned as the values the oversampled signal takes between the two input samples.
struct OversHb {
    float buf[2 * kOversOdd];  // doubled ring: buf[j] == buf[j + 36]
    uint32_t wp;

    void clear() {
        for (float &v : buf) v = 0.0f;
        wp = 0;
    }
    void push(float x, const float *oddRev, float &even, float &odd) {
        buf[wp] = x;
        buf[wp + kOversOdd] = x;
        const float *w = buf + wp + 1;  // oldest first: x[n-35] .. x[n]
        float acc = 0.0f;
        for (uint32_t k = 0; k < kOversOdd; ++k) acc += oddRev[k] * w[k];
        odd = 2.0f * acc;
        even = buf[wp + kOversOdd / 2];  // x[n-18]
        if (++wp == kOversOdd) wp = 0;
    }
};

struct OversDetector {
    OversHb a, b;
    float oddRev[kOversOdd];  // the odd taps, newest last (pairs with the window order above)
    void init() {
        float hodd[kOversOdd];
        halfbandOddTaps(hodd);
        for (uint32_t k = 0; k < kOversOdd; ++k) oddRev[k] = hodd[kOversOdd - 1 - k];
        a.clear();
        b.clear();
    }
    void clear() {
        a.clear();
        b.clear();
    }
};

inline uint32_t oversFactorForRate(double rate) { return rate >= 176399.0 ? 1u : (rate * 2.0 >= 176399.0 ? 2u : 4u); }

// Number of frames of buf whose oversampled signal exceeds 1.0 in magnitude.
inline uint64_t oversCount(OversDetector &d, const float *buf, uint32_t frames, uint32_t factor) {
    uint64_t over = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        const float x = buf[i];
        bool hit = x > 1.0f || x < -1.0f;
        if (factor >= 2) {
            float e1, o1;
            d.a.push(x, d.oddRev, e1, o1);
            hit = hit || e1 > 1.0f || e1 < -1.0f || o1 > 1.0f || o1 < -1.0f;
            if (factor >= 4) {
                float e2, o2, e3, o3;
                d.b.push(e1, d.oddRev, e2, o2);
                // the second stage sees the two points of the first in order; its odd phase of the odd point sits last
                hit = hit || o2 > 1.0f || o2 < -1.0f;
                d.b.push(o1, d.oddRev, e3, o3);
                hit = hit || e2 > 1.0f || e2 < -1.0f || e3 > 1.0f || e3 < -1.0f || o3 > 1.0f || o3 < -1.0f;
            }
        }
        over += hit ? 1u : 0u;
    }
    return over;
}

}  // namespace n60

#endif
