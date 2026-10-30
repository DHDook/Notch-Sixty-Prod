// E4 S9a: broadband feed-forward canceller in shadow mode. See N60Fxlms.h for
// the contract and the update rules.
//
// Sources: multichannel FxLMS, S. M. Kuo and D. R. Morgan, Active Noise
// Control Systems (Wiley, 1996), ch. 5; band filters, RBJ Audio EQ Cookbook
// (R. Bristow-Johnson).

#include "n60_ff_shadow.hpp"

#include <algorithm>
#include <cmath>

#if !(__cplusplus >= 202002L || (defined(_MSVC_LANG) && _MSVC_LANG >= 202002L))
#error "n60_ff_shadow.cpp requires C++20"
#endif

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kErrorLimit = 8.0;     // virtual error clamp
constexpr float kInputLimit = 8.0f;     // microphone samples, +18 dBFS
constexpr double kMeterSeconds = 0.5;
constexpr double kFlush = 1e-30;
constexpr double kDefaultPeakGain = 0.06309573444801933;  // -24 dB

bool finite(double v) { return std::isfinite(v); }

N60BlockFxlmsConfig coreConfig(const N60FeedForwardShadowConfig &config, double decimatedRate) {
    N60BlockFxlmsConfig c = N60BlockFxlmsConfigDefault(decimatedRate);
    c.taps = config.taps;
    c.blockFrames = config.blockFrames;
    c.step = config.step;
    c.leakagePerSecond = config.leakagePerSecond;
    return c;
}

double decimatedRateFor(double sampleRate) {
    const auto factor = n60::anc::Decimator::factorFor(sampleRate);
    return factor == 0 ? 0.0 : sampleRate / factor;
}

}  // namespace

namespace n60::anc {

static_assert(FeedForwardShadow::kLineLength
                  >= N60_FF_SHADOW_MAX_BULK_DELAY + N60_FXLMS_MAX_BLOCK_TAPS
              && (FeedForwardShadow::kLineLength & (FeedForwardShadow::kLineLength - 1)) == 0,
              "the history lines must hold the longest delay plus the longest filter");

// Biquad -------------------------------------------------------------------

void Biquad::lowPass(double cyclesPerSample) noexcept {
    const double w = 2.0 * kPi * cyclesPerSample;
    const double c = std::cos(w), alpha = std::sin(w) / std::sqrt(2.0);
    const double a0 = 1.0 + alpha;
    b0 = b2 = 0.5 * (1.0 - c) / a0;
    b1 = (1.0 - c) / a0;
    a1 = -2.0 * c / a0;
    a2 = (1.0 - alpha) / a0;
}

void Biquad::highPass(double cyclesPerSample) noexcept {
    const double w = 2.0 * kPi * cyclesPerSample;
    const double c = std::cos(w), alpha = std::sin(w) / std::sqrt(2.0);
    const double a0 = 1.0 + alpha;
    b0 = b2 = 0.5 * (1.0 + c) / a0;
    b1 = -(1.0 + c) / a0;
    a1 = -2.0 * c / a0;
    a2 = (1.0 - alpha) / a0;
}

double Biquad::run(double x) noexcept {
    const double y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    if (std::fabs(z1) < kFlush) z1 = 0;
    if (std::fabs(z2) < kFlush) z2 = 0;
    return y;
}

// FeedForwardShadow ----------------------------------------------------------

FeedForwardShadow::FeedForwardShadow(const N60FeedForwardShadowConfig &config)
    : decimatedRate_(decimatedRateFor(config.sampleRate)),
      taps_(config.taps),
      blockFrames_(config.blockFrames),
      peakGainLimit_(config.peakGainLimit),
      meterAlpha_(1.0 - std::exp(-1.0 / (kMeterSeconds * decimatedRate_))),
      referenceDecimator_(config.sampleRate),
      errorDecimator_(config.sampleRate),
      cores_{BlockFxlms(coreConfig(config, decimatedRate_)),
             BlockFxlms(coreConfig(config, decimatedRate_))},
      referenceLine_(kLine),
      driveRate_(config.driveSampleRate) {
    const double low = config.bandLowHz / decimatedRate_;
    const double high = config.bandHighHz / decimatedRate_;
    referenceBand_[0].highPass(low);
    referenceBand_[1].highPass(low);
    referenceBand_[2].lowPass(high);
    referenceBand_[3].lowPass(high);
    errorBand_ = referenceBand_;
    if (driveRate_ > 0) {
        predictedBand_ = referenceBand_;
        beforeBand_ = referenceBand_;
        lead_ = static_cast<std::uint32_t>(std::ceil(0.010 * decimatedRate_));
        for (std::uint32_t c = 0; c < kChannels; ++c) {
            driveDecimator_.emplace_back(driveRate_);
            driveHistory_[c].assign(kDriveHistory, 0.0);
            driveLine_[c].assign(kDriveLine, 0.0);
            echo_[c].reserve(N60_FF_SHADOW_MAX_BULK_DELAY);
        }
        echoLine_.assign(kLine, 0.0);
        predictedBandLine_.assign(kLine, 0.0);
        correlation_.assign(2 * kMaxLag + 1, 0.0);
        if (lead_ > kMaxLag) lead_ = kMaxLag; // fd < 8 kHz keeps this at 80; never index past the buffer
    }
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        // Reserve the largest path so setPath never allocates.
        path_[c].reserve(N60_FXLMS_MAX_PATH_TAPS);
        path_[c].assign(1, 1.0);
        seed_[c].assign(taps_, 0.0f);
        outputLine_[c].assign(kLine, 0.0);
    }
}

bool FeedForwardShadow::setPath(std::uint32_t channel, std::uint32_t bulkDelay,
                                const float *taps, std::uint32_t count) noexcept {
    if (channel >= kChannels || taps == nullptr || count == 0
        || count > N60_FXLMS_MAX_PATH_TAPS || bulkDelay > N60_FF_SHADOW_MAX_BULK_DELAY)
        return false;
    for (std::uint32_t k = 0; k < count; ++k) {
        if (!finite(taps[k])) return false;
    }
    if (!cores_[channel].setPath(taps, count)) return false;
    path_[channel].assign(taps, taps + count);
    delay_[channel] = bulkDelay;
    restartFilters();
    return true;
}

bool FeedForwardShadow::setSeed(const float *left, const float *right,
                                std::uint32_t count) noexcept {
    if (left == nullptr || right == nullptr) return false;
    const auto n = std::min(count, taps_);
    for (std::uint32_t k = 0; k < n; ++k) {
        if (!finite(left[k]) || !finite(right[k])) return false;
    }
    for (std::uint32_t k = 0; k < taps_; ++k) {
        seed_[0][k] = k < n ? left[k] : 0.0f;
        seed_[1][k] = k < n ? right[k] : 0.0f;
    }
    restoreSeed();
    restartFilters();
    return true;
}

void FeedForwardShadow::process(const float *reference, const float *error,
                                std::uint32_t frames) noexcept {
    for (std::uint32_t m = 0; m < frames; ++m) {
        // Clamped, so no finite input can overflow the filter states.
        const float x = std::isfinite(reference[m])
                            ? std::clamp(reference[m], -kInputLimit, kInputLimit) : 0.0f;
        const float e = std::isfinite(error[m])
                            ? std::clamp(error[m], -kInputLimit, kInputLimit) : 0.0f;
        double xd = 0, ed = 0;
        const bool emitted = referenceDecimator_.push(x, xd);
        errorDecimator_.push(e, ed);  // fed in step, so it emits with the reference
        if (emitted && referenceDecimator_.warm()) {
            referenceCentre_ = static_cast<std::int64_t>(referenceFrames_)
                               - static_cast<std::int64_t>(referenceDecimator_.delayFrames());
            adapt(xd, ed);
        }
        ++referenceFrames_;
    }
}

void FeedForwardShadow::adapt(double reference, double error) noexcept {
    const bool echo = driveRate_ > 0 && echoSet_;
    double xRaw = reference, e = error;
    bool hold = false;
    if (echo) {
        echoPosition_ = (echoPosition_ + 1) & (kDriveLine - 1);
        const bool ok = prepareDrive();
        double predicted = 0;
        if (ok) {
            for (std::uint32_t c = 0; c < kChannels; ++c) {
                const auto &l = echo_[c];
                for (std::uint32_t j = 0; j < l.size(); ++j) {
                    predicted += l[j] * driveLine_[c][(echoPosition_ - echoDelay_[c] - j)
                                                      & (kDriveLine - 1)];
                }
            }
        }
        echoLine_[echoPosition_ & kMask] = predicted;
        const double a = driveLine_[0][echoPosition_], b = driveLine_[1][echoPosition_];
        drivePower_ += meterAlpha_ * (std::max(a * a, b * b) - drivePower_);
        if (drivePrepared_ < kDriveLine) ++drivePrepared_;
        double xb = xRaw, pb = predicted;
        for (auto &f : beforeBand_) xb = f.run(xb);
        for (auto &f : predictedBand_) pb = f.run(pb);
        predictedBandLine_[echoPosition_ & kMask] = pb;
        referenceBefore_ += meterAlpha_ * (xb * xb - referenceBefore_);
        const bool present = drivePower_ > kActivePower;
        if (!locked_) {
            if (ok && present && timingValid_) search(xb);
            hold = present && timingValid_;
        } else {
            const std::uint32_t back = static_cast<std::uint32_t>(
                static_cast<std::int32_t>(lead_) + offset_);
            xRaw -= echoLine_[(echoPosition_ - back) & kMask];
            double removed = 0;
            for (std::uint32_t c = 0; c < kChannels; ++c) {
                const auto &s = path_[c];
                for (std::uint32_t j = 0; j < s.size(); ++j) {
                    removed += s[j] * driveLine_[c][(echoPosition_ - back - delay_[c] - j)
                                                    & (kDriveLine - 1)];
                }
            }
            e -= removed;
        }
    }

    double x = xRaw;
    for (auto &f : referenceBand_) x = f.run(x);
    for (auto &f : errorBand_) e = f.run(e);
    if (!finite(x) || !finite(e)) {  // unreachable with clamped input; never adapt on it
        restartFilters();
        ++gaps_;
        return;
    }
    if (echo) referenceAfter_ += meterAlpha_ * (x * x - referenceAfter_);

    position_ = (position_ + 1) & kMask;
    referenceLine_[position_] = x;

    double virtualError = e;
    std::array<double, kChannels> y{};
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        const double *w = cores_[c].weights();
        double acc = 0;
        for (std::uint32_t k = 0; k < taps_; ++k) {
            acc += w[k] * referenceLine_[(position_ - k) & kMask];
        }
        y[c] = acc;
        outputLine_[c][position_] = acc;
        const auto &s = path_[c];
        const std::uint32_t start = position_ - delay_[c];
        for (std::uint32_t j = 0; j < s.size(); ++j) {
            virtualError += s[j] * outputLine_[c][(start - j) & kMask];
        }
    }
    virtualError = std::clamp(virtualError, -kErrorLimit, kErrorLimit);

    if (!hold) {
        const float ev = static_cast<float>(virtualError);
        for (std::uint32_t c = 0; c < kChannels; ++c) {
            const float xr = static_cast<float>(referenceLine_[(position_ - delay_[c]) & kMask]);
            cores_[c].update(&xr, &ev, 1);
        }
        if (++blockFill_ == blockFrames_) {
            blockFill_ = 0;
            limitWeights();
        }
    }

    measured_ += meterAlpha_ * (e * e - measured_);
    predicted_ += meterAlpha_ * (virtualError * virtualError - predicted_);
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        output_[c] += meterAlpha_ * (y[c] * y[c] - output_[c]);
    }
    ++decimatedSamples_;
    ++sinceRestart_;
}

void FeedForwardShadow::limitWeights() noexcept {
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        const double *w = cores_[c].weights();
        double gain = 0;
        for (std::uint32_t k = 0; k < taps_; ++k) gain += std::fabs(w[k]);
        if (!finite(gain)) {
            restoreSeed();
            restartFilters();
            ++modelResets_;
            return;
        }
        if (gain > peakGainLimit_) {
            cores_[c].scaleWeights(peakGainLimit_ / gain);
            ++gainLimited_;
        }
    }
}

void FeedForwardShadow::restartFilters() noexcept {
    referenceDecimator_.reset();
    errorDecimator_.reset();
    for (auto &f : referenceBand_) f.reset();
    for (auto &f : errorBand_) f.reset();
    for (auto &core : cores_) core.clearHistory();
    std::fill(referenceLine_.begin(), referenceLine_.end(), 0.0);
    for (auto &line : outputLine_) std::fill(line.begin(), line.end(), 0.0);
    position_ = 0;
    blockFill_ = 0;
    sinceRestart_ = 0;
    if (driveRate_ > 0) restartEcho();
}

void FeedForwardShadow::restoreSeed() noexcept {
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        cores_[c].setWeights(seed_[c].data(), taps_);
    }
    // The meters described the previous weights.
    measured_ = predicted_ = 0;
    output_.fill(0);
}

// Echo stage -----------------------------------------------------------------

bool FeedForwardShadow::setEcho(std::uint32_t channel, std::uint32_t bulkDelay, const float *taps,
                                std::uint32_t count) noexcept {
    if (driveRate_ <= 0 || channel >= kChannels || taps == nullptr || count == 0
        || count > N60_FF_SHADOW_MAX_BULK_DELAY || bulkDelay > N60_FF_SHADOW_MAX_BULK_DELAY)
        return false;
    for (std::uint32_t k = 0; k < count; ++k) {
        if (!finite(taps[k])) return false;
    }
    echo_[channel].assign(taps, taps + count);  // within the reserved capacity
    echoDelay_[channel] = bulkDelay;
    echoSet_ = true;
    restartFilters();
    return true;
}

void FeedForwardShadow::pushDrive(const float *left, const float *right,
                                  std::uint32_t frames) noexcept {
    if (driveRate_ <= 0) return;
    for (std::uint32_t m = 0; m < frames; ++m) {
        const float in[kChannels] = {
            std::isfinite(left[m]) ? std::clamp(left[m], -kInputLimit, kInputLimit) : 0.0f,
            std::isfinite(right[m]) ? std::clamp(right[m], -kInputLimit, kInputLimit) : 0.0f};
        double out[kChannels] = {0, 0};
        bool emitted = false;
        for (std::uint32_t c = 0; c < kChannels; ++c) {
            emitted = driveDecimator_[c].push(in[c], out[c]);
        }
        if (emitted) {
            const auto slot = static_cast<std::uint32_t>(driveDecimated_ & (kDriveHistory - 1));
            for (std::uint32_t c = 0; c < kChannels; ++c) driveHistory_[c][slot] = out[c];
            ++driveDecimated_;
        }
        ++driveFrames_;
    }
}

bool FeedForwardShadow::setDriveTiming(std::uint64_t micFrame, double driveFrame,
                                       double ratio) noexcept {
    if (driveRate_ <= 0 || !finite(driveFrame) || !finite(ratio) || ratio < 0.05 || ratio > 20.0)
        return false;
    timingMicFrame_ = micFrame;
    timingDriveFrame_ = driveFrame;
    timingRatio_ = ratio;
    timingValid_ = true;
    return true;
}

void FeedForwardShadow::restartDrive(std::uint64_t nextDriveFrame) noexcept {
    if (driveRate_ <= 0) return;
    for (auto &d : driveDecimator_) d.reset();
    for (auto &h : driveHistory_) std::fill(h.begin(), h.end(), 0.0);
    driveDecimated_ = 0;
    driveFrames_ = nextDriveFrame;
    driveBaseFrame_ = nextDriveFrame;
    timingValid_ = false;
    restartEcho();
    if (echoSet_) ++searchRestarts_;
}

void FeedForwardShadow::restartEcho() noexcept {
    locked_ = false;
    offset_ = 0;
    searchXX_ = searchPP_ = 0;
    searchSamples_ = 0;
    std::fill(correlation_.begin(), correlation_.end(), 0.0);
    for (auto &l : driveLine_) std::fill(l.begin(), l.end(), 0.0);
    std::fill(echoLine_.begin(), echoLine_.end(), 0.0);
    std::fill(predictedBandLine_.begin(), predictedBandLine_.end(), 0.0);
    for (auto &f : predictedBand_) f.reset();
    for (auto &f : beforeBand_) f.reset();
    echoPosition_ = 0;
    drivePrepared_ = 0;
    referenceBefore_ = referenceAfter_ = 0;
}

double FeedForwardShadow::driveAt(std::uint32_t channel, std::int64_t sample) const noexcept {
    return driveHistory_[channel][static_cast<std::uint32_t>(sample) & (kDriveHistory - 1)];
}

// Interpolates the drive, read ahead by lead_ fd samples, at this reference sample (4-point
// Lagrange, nodes -1..2). False when the drive does not cover the point.
bool FeedForwardShadow::prepareDrive() noexcept {
    for (std::uint32_t c = 0; c < kChannels; ++c) driveLine_[c][echoPosition_] = 0.0;
    if (!timingValid_ || driveDecimated_ < 4) return false;
    const double factor = driveDecimator_[0].factor();
    const double centre = static_cast<double>(referenceCentre_)
                          + static_cast<double>(lead_) * referenceDecimator_.factor();
    const double frame = timingDriveFrame_
                         + (centre - static_cast<double>(timingMicFrame_)) * timingRatio_;
    const double index = (frame - static_cast<double>(driveBaseFrame_) - (factor - 1.0)
                          + static_cast<double>(driveDecimator_[0].delayFrames())) / factor;
    const double base = std::floor(index);
    if (!finite(index) || base < 1.0) { ++driveStarved_; return false; }
    const auto i0 = static_cast<std::int64_t>(base);
    const auto produced = static_cast<std::int64_t>(driveDecimated_);
    if (i0 + 2 >= produced || i0 - 1 < produced - static_cast<std::int64_t>(kDriveHistory)) {
        ++driveStarved_;
        return false;
    }
    const double t = index - base;
    const double w[4] = {-t * (t - 1.0) * (t - 2.0) / 6.0, (t + 1.0) * (t - 1.0) * (t - 2.0) / 2.0,
                         -(t + 1.0) * t * (t - 2.0) / 2.0, (t + 1.0) * t * (t - 1.0) / 6.0};
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        double acc = 0;
        for (int k = 0; k < 4; ++k) acc += w[k] * driveAt(c, i0 - 1 + k);
        driveLine_[c][echoPosition_] = acc;
    }
    return true;
}

// Correlates the band-limited reference with the predicted leakage at lags -lead_..lead_.
void FeedForwardShadow::search(double referenceBand) noexcept {
    searchXX_ += referenceBand * referenceBand;
    const double nominal = predictedBandLine_[(echoPosition_ - lead_) & kMask];
    searchPP_ += nominal * nominal;
    for (std::uint32_t l = 0; l <= 2 * lead_; ++l) {
        const std::int32_t lag = static_cast<std::int32_t>(l) - static_cast<std::int32_t>(lead_);
        const double p = predictedBandLine_[static_cast<std::uint32_t>(
            static_cast<std::int32_t>(echoPosition_) - static_cast<std::int32_t>(lead_) - lag) & kMask];
        correlation_[l] += referenceBand * p;
    }
    if (++searchSamples_ >= static_cast<std::uint64_t>(kSearchSeconds * decimatedRate_)) finishSearch();
}

void FeedForwardShadow::finishSearch() noexcept {
    std::uint32_t best = 0;
    for (std::uint32_t l = 1; l <= 2 * lead_; ++l) {
        if (correlation_[l] > correlation_[best]) best = l;
    }
    const double energy = searchXX_ * searchPP_;
    const double peak = energy > 0 ? correlation_[best] / std::sqrt(energy) : 0.0;
    searchPeak_ = static_cast<float>(std::clamp(peak, 0.0, 1.0));
    if (peak >= kLockThreshold) {
        locked_ = true;
        offset_ = static_cast<std::int32_t>(best) - static_cast<std::int32_t>(lead_);
    } else {
        ++searchRestarts_;
    }
    searchXX_ = searchPP_ = 0;
    searchSamples_ = 0;
    std::fill(correlation_.begin(), correlation_.end(), 0.0);
}

void FeedForwardShadow::markDiscontinuity() noexcept {
    restartFilters();
    ++gaps_;
}

void FeedForwardShadow::reset() noexcept {
    restoreSeed();
    restartFilters();
}

N60FeedForwardShadowStatus FeedForwardShadow::status() const noexcept {
    N60FeedForwardShadowStatus s{};
    s.decimatedRate = decimatedRate_;
    s.decimatedSamples = decimatedSamples_;
    s.samplesSinceRestart = sinceRestart_;
    s.gaps = gaps_;
    s.modelResets = modelResets_;
    s.gainLimited = gainLimited_;
    if (driveRate_ > 0) {
        s.echoState = !echoSet_ ? N60_FF_ECHO_OFF
                      : locked_ ? N60_FF_ECHO_LOCKED
                      : (drivePower_ > kActivePower && timingValid_) ? N60_FF_ECHO_SEARCHING
                                                                     : N60_FF_ECHO_WAITING;
        s.echoOffset = offset_;
        s.searchPeak = searchPeak_;
        s.searchRestarts = searchRestarts_;
        s.driveFrames = driveFrames_;
        s.referenceFrames = referenceFrames_;
        s.driveStarved = driveStarved_;
        s.drivePower = static_cast<float>(drivePower_);
        s.referencePowerBefore = static_cast<float>(referenceBefore_);
        s.referencePowerAfter = static_cast<float>(referenceAfter_);
    }
    s.measuredPower = static_cast<float>(measured_);
    s.predictedPower = static_cast<float>(predicted_);
    for (std::uint32_t c = 0; c < kChannels; ++c) {
        s.outputPower[c] = static_cast<float>(output_[c]);
        const double *w = cores_[c].weights();
        double gain = 0;
        for (std::uint32_t k = 0; k < taps_; ++k) gain += std::fabs(w[k]);
        s.weightGain[c] = static_cast<float>(gain);
    }
    return s;
}

void FeedForwardShadow::copyWeights(std::uint32_t channel, float *out,
                                    std::uint32_t count) const noexcept {
    if (channel < kChannels) cores_[channel].copyWeights(out, count);
}

}  // namespace n60::anc

// C interface --------------------------------------------------------------

struct N60FeedForwardShadow {
    n60::anc::FeedForwardShadow core;
};

extern "C" {

N60FeedForwardShadowConfig N60FeedForwardShadowConfigDefault(double sampleRate) {
    N60FeedForwardShadowConfig config{};
    config.sampleRate = sampleRate;
    config.taps = 128;
    config.blockFrames = 8;
    config.step = 0.05f;
    config.leakagePerSecond = 0.01;
    config.bandLowHz = 20.0f;
    config.bandHighHz = 200.0f;
    config.peakGainLimit = static_cast<float>(kDefaultPeakGain);
    config.driveSampleRate = 0;
    return config;
}

bool N60FeedForwardShadowConfigIsValid(const N60FeedForwardShadowConfig *config) {
    if (config == nullptr) return false;
    const double fd = decimatedRateFor(config->sampleRate);
    if (fd == 0) return false;
    const auto in = [](double v, double lo, double hi) { return finite(v) && v >= lo && v <= hi; };
    if (config->taps < 1 || config->taps > N60_FXLMS_MAX_BLOCK_TAPS) return false;
    if (config->blockFrames < 1 || config->blockFrames > 1024) return false;
    if (!finite(config->step) || config->step <= 0 || config->step > N60_FF_SHADOW_MAX_STEP)
        return false;
    if (!in(config->leakagePerSecond, 0, 10)) return false;
    if (!in(config->bandLowHz, 10, 100)) return false;
    if (!in(config->bandHighHz, 2.0 * config->bandLowHz, 0.25 * fd)) return false;
    if (config->driveSampleRate != 0
        && !(in(config->driveSampleRate, 8000, 768000)
             && decimatedRateFor(config->driveSampleRate) != 0))
        return false;
    return finite(config->peakGainLimit) && config->peakGainLimit > 0
           && config->peakGainLimit <= 16;
}

N60FeedForwardShadow *N60FeedForwardShadowCreate(const N60FeedForwardShadowConfig *config) {
    if (!N60FeedForwardShadowConfigIsValid(config)) return nullptr;
    try {
        return new N60FeedForwardShadow{n60::anc::FeedForwardShadow(*config)};
    } catch (...) {
        return nullptr;
    }
}

void N60FeedForwardShadowDestroy(N60FeedForwardShadow *shadow) { delete shadow; }

bool N60FeedForwardShadowSetPath(N60FeedForwardShadow *shadow, uint32_t channel,
                                 uint32_t bulkDelay, const float *taps, uint32_t count) {
    return shadow->core.setPath(channel, bulkDelay, taps, count);
}

bool N60FeedForwardShadowSetSeed(N60FeedForwardShadow *shadow, const float *left,
                                 const float *right, uint32_t count) {
    return shadow->core.setSeed(left, right, count);
}

void N60FeedForwardShadowProcess(N60FeedForwardShadow *shadow, const float *reference,
                                 const float *error, uint32_t frames) {
    shadow->core.process(reference, error, frames);
}

bool N60FeedForwardShadowSetEcho(N60FeedForwardShadow *shadow, uint32_t channel,
                                 uint32_t bulkDelay, const float *taps, uint32_t count) {
    return shadow->core.setEcho(channel, bulkDelay, taps, count);
}

void N60FeedForwardShadowPushDrive(N60FeedForwardShadow *shadow, const float *left,
                                   const float *right, uint32_t frames) {
    shadow->core.pushDrive(left, right, frames);
}

bool N60FeedForwardShadowSetDriveTiming(N60FeedForwardShadow *shadow, uint64_t micFrame,
                                        double driveFrame, double driveFramesPerMicFrame) {
    return shadow->core.setDriveTiming(micFrame, driveFrame, driveFramesPerMicFrame);
}

void N60FeedForwardShadowRestartDrive(N60FeedForwardShadow *shadow, uint64_t nextDriveFrame) {
    shadow->core.restartDrive(nextDriveFrame);
}

void N60FeedForwardShadowMarkDiscontinuity(N60FeedForwardShadow *shadow) {
    shadow->core.markDiscontinuity();
}

void N60FeedForwardShadowReset(N60FeedForwardShadow *shadow) { shadow->core.reset(); }

N60FeedForwardShadowStatus N60FeedForwardShadowReadStatus(const N60FeedForwardShadow *shadow) {
    return shadow->core.status();
}

void N60FeedForwardShadowCopyWeights(const N60FeedForwardShadow *shadow, uint32_t channel,
                                     float *weights, uint32_t count) {
    shadow->core.copyWeights(channel, weights, count);
}

}  // extern "C"
