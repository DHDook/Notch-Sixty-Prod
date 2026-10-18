// E4 S9b1: feed-forward survey. See N60Fxlms.h for the contract and the
// estimator.
//
// Sources: Welch averaging, P. D. Welch, IEEE Trans. Audio Electroacoust.
// 15(2), 1967; H1 transfer and coherence, J. S. Bendat and A. G. Piersol,
// Random Data (Wiley, 2010), ch. 9.

#include "n60_ff_survey.hpp"

#include <algorithm>
#include <cmath>

#if !(__cplusplus >= 202002L || (defined(_MSVC_LANG) && _MSVC_LANG >= 202002L))
#error "n60_ff_survey.cpp requires C++20"
#endif

namespace {

constexpr double kPi = 3.14159265358979323846;

bool finite(double v) { return std::isfinite(v); }

double decimatedRateFor(double sampleRate) {
    const auto factor = n60::anc::Decimator::factorFor(sampleRate);
    return factor == 0 ? 0.0 : sampleRate / factor;
}

std::uint32_t segmentLength(const N60FeedForwardSurveyConfig &config) {
    return static_cast<std::uint32_t>(
        std::lround(config.segmentSeconds * decimatedRateFor(config.sampleRate)));
}

}  // namespace

namespace n60::anc {

FeedForwardSurvey::FeedForwardSurvey(const N60FeedForwardSurveyConfig &config)
    : decimatedRate_(decimatedRateFor(config.sampleRate)),
      bandCount_(config.bandCount),
      length_(segmentLength(config)),
      hop_(segmentLength(config) / 2),
      window_(segmentLength(config)),
      referenceDecimator_(config.sampleRate),
      errorDecimator_(config.sampleRate),
      reference_(segmentLength(config)),
      error_(segmentLength(config)) {
    for (std::uint32_t k = 0; k < bandCount_; ++k) {
        const double w = 2.0 * kPi * config.bandHz[k] / decimatedRate_;
        stepRe_[k] = std::cos(w);
        stepIm_[k] = -std::sin(w);
    }
    for (std::uint32_t n = 0; n < length_; ++n) {
        window_[n] = 0.5 - 0.5 * std::cos(2.0 * kPi * n / length_);
    }
}

void FeedForwardSurvey::process(const float *reference, const float *error,
                                std::uint32_t frames) noexcept {
    for (std::uint32_t m = 0; m < frames; ++m) {
        if (!std::isfinite(reference[m]) || !std::isfinite(error[m])) {
            if (!faulted_) {  // one gap per run of bad samples
                markDiscontinuity();
                faulted_ = true;
            }
            continue;
        }
        faulted_ = false;
        double x = 0, e = 0;
        const bool emitted = referenceDecimator_.push(reference[m], x);
        errorDecimator_.push(error[m], e);  // fed in step, so it emits with the reference
        if (emitted && referenceDecimator_.warm()) push(x, e);
    }
}

void FeedForwardSurvey::push(double reference, double error) noexcept {
    reference_[position_] = reference;
    error_[position_] = error;
    position_ = position_ + 1 == length_ ? 0 : position_ + 1;
    ++filled_;
    if (filled_ < length_) return;
    if (filled_ == length_ || ++sinceSegment_ == hop_) {
        sinceSegment_ = 0;
        analyseSegment();
    }
}

void FeedForwardSurvey::analyseSegment() noexcept {
    // position_ is the oldest sample of the segment.
    for (std::uint32_t k = 0; k < bandCount_; ++k) {
        double pr = 1, pi = 0;  // exp(-j w n), n from the oldest sample
        double xr = 0, xi = 0, er = 0, ei = 0;
        std::uint32_t index = position_;
        for (std::uint32_t n = 0; n < length_; ++n) {
            const double wx = window_[n] * reference_[index];
            const double we = window_[n] * error_[index];
            xr += wx * pr;
            xi += wx * pi;
            er += we * pr;
            ei += we * pi;
            const double nr = pr * stepRe_[k] - pi * stepIm_[k];
            pi = pr * stepIm_[k] + pi * stepRe_[k];
            pr = nr;
            index = index + 1 == length_ ? 0 : index + 1;
        }
        sxx_[k] += xr * xr + xi * xi;
        see_[k] += er * er + ei * ei;
        // conj(X) E
        sxeRe_[k] += xr * er + xi * ei;
        sxeIm_[k] += xr * ei - xi * er;
    }
    ++segments_;
}

void FeedForwardSurvey::restart() noexcept {
    faulted_ = false;
    referenceDecimator_.reset();
    errorDecimator_.reset();
    std::fill(reference_.begin(), reference_.end(), 0.0);
    std::fill(error_.begin(), error_.end(), 0.0);
    position_ = 0;
    filled_ = 0;
    sinceSegment_ = 0;
}

void FeedForwardSurvey::markDiscontinuity() noexcept {
    restart();
    ++gaps_;
}

void FeedForwardSurvey::reset() noexcept {
    restart();
    sxx_.fill(0);
    see_.fill(0);
    sxeRe_.fill(0);
    sxeIm_.fill(0);
    segments_ = 0;
    gaps_ = 0;
}

N60FeedForwardSurveyResult FeedForwardSurvey::result() const noexcept {
    N60FeedForwardSurveyResult r{};
    r.decimatedRate = decimatedRate_;
    r.segments = segments_;
    r.gaps = gaps_;
    if (segments_ == 0) return r;
    const double count = static_cast<double>(segments_);
    for (std::uint32_t k = 0; k < bandCount_; ++k) {
        const double sxx = sxx_[k], see = see_[k];
        const double cross2 = sxeRe_[k] * sxeRe_[k] + sxeIm_[k] * sxeIm_[k];
        if (sxx > 0) {
            r.transfer[k].re = static_cast<float>(sxeRe_[k] / sxx);
            r.transfer[k].im = static_cast<float>(sxeIm_[k] / sxx);
        }
        if (sxx > 0 && see > 0) {
            r.coherence[k] = static_cast<float>(std::clamp(cross2 / (sxx * see), 0.0, 1.0));
        }
        r.referencePower[k] = static_cast<float>(sxx / count);
        r.errorPower[k] = static_cast<float>(see / count);
    }
    return r;
}

}  // namespace n60::anc

// C interface --------------------------------------------------------------

struct N60FeedForwardSurvey {
    n60::anc::FeedForwardSurvey core;
};

extern "C" {

N60FeedForwardSurveyConfig N60FeedForwardSurveyConfigDefault(double sampleRate) {
    N60FeedForwardSurveyConfig config{};
    config.sampleRate = sampleRate;
    config.bandCount = 0;
    config.segmentSeconds = 1.0;
    return config;
}

bool N60FeedForwardSurveyConfigIsValid(const N60FeedForwardSurveyConfig *config) {
    if (config == nullptr) return false;
    const double fd = decimatedRateFor(config->sampleRate);
    if (fd == 0) return false;
    if (config->bandCount < 1 || config->bandCount > N60_FF_SURVEY_MAX_BANDS) return false;
    for (uint32_t k = 0; k < config->bandCount; ++k) {
        const double hz = config->bandHz[k];
        if (!finite(hz) || hz < 10 || hz > 0.15 * fd) return false;
    }
    return finite(config->segmentSeconds) && config->segmentSeconds >= 0.25
           && config->segmentSeconds <= 4;
}

N60FeedForwardSurvey *N60FeedForwardSurveyCreate(const N60FeedForwardSurveyConfig *config) {
    if (!N60FeedForwardSurveyConfigIsValid(config)) return nullptr;
    try {
        return new N60FeedForwardSurvey{n60::anc::FeedForwardSurvey(*config)};
    } catch (...) {
        return nullptr;
    }
}

void N60FeedForwardSurveyDestroy(N60FeedForwardSurvey *survey) { delete survey; }

void N60FeedForwardSurveyProcess(N60FeedForwardSurvey *survey, const float *reference,
                                 const float *error, uint32_t frames) {
    survey->core.process(reference, error, frames);
}

void N60FeedForwardSurveyMarkDiscontinuity(N60FeedForwardSurvey *survey) {
    survey->core.markDiscontinuity();
}

void N60FeedForwardSurveyReset(N60FeedForwardSurvey *survey) { survey->core.reset(); }

N60FeedForwardSurveyResult N60FeedForwardSurveyRead(const N60FeedForwardSurvey *survey) {
    return survey->core.result();
}

}  // extern "C"
