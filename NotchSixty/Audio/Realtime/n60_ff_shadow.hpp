#pragma once

// E4 S9a: broadband feed-forward canceller in shadow mode (1 reference x 2
// outputs x 1 error, block FxLMS at the decimated rate). The C interface, the
// update rules and the threading contract are documented in N60Fxlms.h.

#include "n60_fxlms.hpp"

#include <array>
#include <cstdint>
#include <vector>

namespace n60::anc {

// Second-order section, transposed direct form II.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    // RBJ Audio EQ Cookbook second-order Butterworth (Q = 1 / sqrt 2); two in
    // cascade make the fourth-order Linkwitz-Riley band edge. Corner in
    // cycles per sample.
    void lowPass(double cyclesPerSample) noexcept;
    void highPass(double cyclesPerSample) noexcept;
    double run(double x) noexcept;  // flushes decaying state to zero
    void reset() noexcept { z1 = z2 = 0; }
};

class FeedForwardShadow {
public:
    static constexpr std::uint32_t kChannels = 2;
    static constexpr std::uint32_t kLineLength = 1024;  // >= max bulk delay + max taps

    // Control plane. The config must already be valid.
    explicit FeedForwardShadow(const N60FeedForwardShadowConfig &config);

    bool setPath(std::uint32_t channel, std::uint32_t bulkDelay, const float *taps,
                 std::uint32_t count) noexcept;
    bool setSeed(const float *left, const float *right, std::uint32_t count) noexcept;
    void process(const float *reference, const float *error, std::uint32_t frames) noexcept;
    void markDiscontinuity() noexcept;
    void reset() noexcept;
    N60FeedForwardShadowStatus status() const noexcept;
    void copyWeights(std::uint32_t channel, float *out, std::uint32_t count) const noexcept;

private:
    static constexpr std::uint32_t kLine = kLineLength;
    static constexpr std::uint32_t kMask = kLine - 1;

    void adapt(double reference, double error) noexcept;
    void limitWeights() noexcept;
    void restartFilters() noexcept;
    void restoreSeed() noexcept;

    // Fixed configuration.
    double decimatedRate_;
    std::uint32_t taps_;
    std::uint32_t blockFrames_;
    double peakGainLimit_;
    double meterAlpha_;

    Decimator referenceDecimator_;
    Decimator errorDecimator_;
    std::array<Biquad, 4> referenceBand_{};  // high-pass x2, low-pass x2
    std::array<Biquad, 4> errorBand_{};
    std::array<BlockFxlms, kChannels> cores_;
    std::array<std::vector<double>, kChannels> path_;
    std::array<std::uint32_t, kChannels> delay_{};
    std::array<std::vector<float>, kChannels> seed_;

    std::vector<double> referenceLine_;
    std::array<std::vector<double>, kChannels> outputLine_;
    std::uint32_t position_ = 0;
    std::uint32_t blockFill_ = 0;

    double measured_ = 0;
    double predicted_ = 0;
    std::array<double, kChannels> output_{};
    std::uint64_t decimatedSamples_ = 0;
    std::uint64_t sinceRestart_ = 0;
    std::uint64_t gaps_ = 0;
    std::uint64_t modelResets_ = 0;
    std::uint64_t gainLimited_ = 0;
};

}  // namespace n60::anc
