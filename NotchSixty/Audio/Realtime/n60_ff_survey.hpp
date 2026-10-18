#pragma once

// E4 S9b1: feed-forward survey (reference -> error transfer and coherence by
// Welch averaging at chosen band frequencies). The C interface, the estimator
// and the threading contract are documented in N60Fxlms.h.

#include "n60_fxlms.hpp"

#include <array>
#include <cstdint>
#include <vector>

namespace n60::anc {

class FeedForwardSurvey {
public:
    // Control plane. The config must already be valid.
    explicit FeedForwardSurvey(const N60FeedForwardSurveyConfig &config);

    void process(const float *reference, const float *error, std::uint32_t frames) noexcept;
    void markDiscontinuity() noexcept;
    void reset() noexcept;
    N60FeedForwardSurveyResult result() const noexcept;

private:
    static constexpr std::uint32_t kBands = N60_FF_SURVEY_MAX_BANDS;

    void push(double reference, double error) noexcept;
    void analyseSegment() noexcept;
    void restart() noexcept;

    double decimatedRate_;
    std::uint32_t bandCount_;
    std::uint32_t length_;  // segment, decimated samples
    std::uint32_t hop_;
    std::array<double, kBands> stepRe_{};  // exp(-j 2 pi f / fd)
    std::array<double, kBands> stepIm_{};
    std::vector<double> window_;

    Decimator referenceDecimator_;
    Decimator errorDecimator_;
    std::vector<double> reference_;  // ring of the last length_ samples
    std::vector<double> error_;
    std::uint32_t position_ = 0;     // next write
    std::uint64_t filled_ = 0;       // since the last restart
    std::uint32_t sinceSegment_ = 0;
    bool faulted_ = false;

    std::array<double, kBands> sxx_{};
    std::array<double, kBands> see_{};
    std::array<double, kBands> sxeRe_{};
    std::array<double, kBands> sxeIm_{};
    std::uint64_t segments_ = 0;
    std::uint64_t gaps_ = 0;
};

}  // namespace n60::anc
