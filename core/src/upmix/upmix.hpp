// E14 S1: stereo upmix engine (n60/upmix.h). STFT primary/ambience decomposition, role-based panning, seeded
// decorrelators. The realtime stage (E14 S2) wraps this class.
//
// Realtime documentation (docs/REALTIME_RULES.md):
//  - allocation: init allocates one arena (the only allocation); process, setStrength and reset allocate nothing.
//  - synchronisation: none. One audio thread calls process; setStrength stores a float the same thread reads (the stage
//    publishes it through the snapshot path).
//  - latency: one STFT frame (frameLength() samples), the same on every lane, at every strength.
//  - sample rate: 8 kHz..768 kHz, frame length 1024 * 2^round(log2(rate / 48 kHz)) (fixed in time, about 21 to 23 ms).
//  - channels: two input lanes; output lanes follow the configured roles. The LFE lane is never written (zero).
//  - denormals: the engine does not set FTZ/DAZ; the S2 stage runs under the core floating-point guard (platform/fpenv.hpp).
//  - cost: one whole frame (2 forward, 5 inverse transforms) runs in the callback that completes each hop; S2 measures the worst
//    callback and splits the work across the hop if it is over budget. setStrength takes effect at the next hop. init is called once.
//  - input: samples beyond +-1e6 or non-finite read as 0.
//  - reset: STFT history, smoothed statistics, decorrelator state and the strength ramp restart from silence.
#ifndef N60_CORE_UPMIX_HPP
#define N60_CORE_UPMIX_HPP

#include <cstdint>

#include "n60/upmix.h"
#include "../nothrow_array.hpp"
#include "../platform/rt.hpp"

namespace n60::upmix {

constexpr uint32_t kMaxAmbientPerSide = 8;
constexpr uint32_t kDecorStages = 4;

class Engine {
public:
    // Control thread. Builds the arena and plans; false for a bad configuration or out of memory.
    bool init(const n60_upmix_config &config);
    // Restarts from silence; the strength ramp snaps to the target.
    void reset() N60_RT_NONBLOCKING;
    // Live, ramped (about 50 ms) to the target; clamps to 0..1, non-finite reads as 0.
    void setStrength(float strength) N60_RT_NONBLOCKING;
    // `frames` samples of input to channelCount output lanes (out[c] has `frames` floats). Non-finite input reads as 0.
    void process(const float *left, const float *right, float *const *out, uint32_t frames) N60_RT_NONBLOCKING;

    uint32_t frameLength() const { return n_; }
    uint32_t latencyFrames() const { return n_; }
    uint32_t channelCount() const { return channels_; }

    static uint32_t frameLengthFor(double sampleRate);

private:
    struct Decor {
        uint32_t lane = 0;
        uint32_t delay[kDecorStages] = {};
        uint32_t pos[kDecorStages] = {};
        float g[kDecorStages] = {};
        float *buf[kDecorStages] = {};
    };

    void runFrame() N60_RT_NONBLOCKING;
    float decorrelate(Decor &d, float x) N60_RT_NONBLOCKING;

    NothrowArray<float> arena_;
    uint32_t n_ = 0, hop_ = 0, bins_ = 0, kMax_ = 0, channels_ = 0;
    double fs_ = 0;
    float smoothA_ = 0, strengthA_ = 0, target_ = 0, current_ = 0;
    uint32_t warmFrames_ = 0, warmNeeded_ = 0, hopCount_ = 0, inPos_ = 0, fifoW_ = 0, fifoR_ = 0;
    int32_t laneFl_ = -1, laneFr_ = -1, laneC_ = -1;
    uint32_t leftCount_ = 0, rightCount_ = 0;
    float leftGain_ = 0, rightGain_ = 0;
    Decor left_[kMaxAmbientPerSide], right_[kMaxAmbientPerSide];

    // Arena slices.
    float *inL_ = nullptr, *inR_ = nullptr;      // input rings, n floats each
    float *wnd_ = nullptr, *synth_ = nullptr;    // analysis and synthesis windows
    float *specL_ = nullptr, *specR_ = nullptr;  // n + 2 floats each (forwardReal output)
    float *out_[5] = {};                         // inverse buffers: L, C, R, ambience left, ambience right (n + 2)
    float *ola_[5] = {};                         // overlap-add accumulators, n each
    float *fifo_[5] = {};                        // finished samples, n each (ring, mask n - 1)
    float *pll_ = nullptr, *prr_ = nullptr, *plrRe_ = nullptr, *plrIm_ = nullptr;  // smoothed statistics, bins each
    void *plan_ = nullptr;
};

}  // namespace n60::upmix

#endif
