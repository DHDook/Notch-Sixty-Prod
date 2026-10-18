#pragma once

// E4 S4: C++20 core of the speaker-ANC howl guard. The C interface and the
// realtime contract are documented in N60AncGuard.h.

#include "N60AncGuard.h"

#include <array>
#include <atomic>
#include <cstdint>

namespace n60::anc {

static_assert(std::atomic<std::uint64_t>::is_always_lock_free
              && std::atomic<std::uint32_t>::is_always_lock_free
              && std::atomic<bool>::is_always_lock_free,
              "the ANC guard's shared state must be lock-free");

class Guard {
public:
    static constexpr std::uint32_t kBands = N60_ANC_GUARD_BAND_COUNT;

    // Control plane: computes coefficients and thresholds. The config must
    // already be valid (N60AncGuardConfigIsValid).
    explicit Guard(const N60AncGuardConfig &config) noexcept;

    // Realtime.
    N60AncGuardTrip process(float *antiNoise, const float *reference,
                            const float *error, std::uint32_t frames) noexcept;

    // Any thread.
    void requestRearm() noexcept;
    N60AncGuardStatus status() const noexcept;

private:
    struct Biquad {
        double b0 = 0, b2 = 0, a1 = 0, a2 = 0;  // b1 is zero for a band-pass
        double z1 = 0, z2 = 0;

        double run(double x) noexcept {
            const double y = b0 * x + z1;
            z1 = -a1 * y + z2;
            z2 = b2 * x - a2 * y;
            // Flush decaying state before it turns subnormal on long silence.
            if (z1 > -1e-200 && z1 < 1e-200) z1 = 0;
            if (z2 > -1e-200 && z2 < 1e-200) z2 = 0;
            return y;
        }
    };

    void rearm() noexcept;
    void trip(N60AncGuardTrip reason) noexcept;
    void startRamp(float target) noexcept;
    void endBlock() noexcept;
    float applyGain(float sample) noexcept;

    // Fixed configuration.
    bool hasErrorBaseline_;
    std::uint32_t growthBlocks_;
    std::uint32_t errorRiseBlocks_;
    std::uint32_t blockFrames_;
    std::uint32_t decimation_;
    std::uint32_t rampFrames_;
    float ceiling_;
    double growthRatio_;
    double referenceAllowance_;
    double errorRatio_;
    double activityFloor_;
    std::array<double, kBands> baseline_{};
    std::array<Biquad, kBands> bands_{};

    // Realtime-thread state.
    std::uint32_t blockPosition_ = 0;
    std::uint32_t blocksSeen_ = 0;
    double outSum_ = 0, refSum_ = 0;
    std::array<double, 2> outHistory_{};  // [0] = previous, [1] = two back
    std::array<double, 2> refHistory_{};
    std::uint32_t decimatePosition_ = 0;
    double decimateSum_ = 0;
    std::array<double, kBands> bandSum_{};
    std::uint32_t bandCount_ = 0;
    std::uint32_t growthRun_ = 0;
    std::uint32_t errorRun_ = 0;
    std::uint64_t framesSinceArm_ = 0;
    // Ramps are computed from a frame counter, not accumulated, so they end
    // exactly on time at every rate.
    float gain_ = 1.0f;
    float rampStart_ = 1.0f;
    float gainTarget_ = 1.0f;
    std::uint32_t rampRemaining_ = 0;

    // Shared with other threads, on its own cache line so status polling does
    // not contend with the realtime state above.
    struct alignas(64) Shared {
        std::atomic<bool> rearmRequested{false};
        std::atomic<std::uint32_t> trip{N60AncGuardTripNone};
        std::atomic<bool> muted{false};
        std::atomic<std::uint64_t> tripFrame{0};
        std::atomic<std::uint64_t> processedFrames{0};
        std::atomic<std::uint64_t> tripCount{0};
    } shared_;
};

}  // namespace n60::anc
