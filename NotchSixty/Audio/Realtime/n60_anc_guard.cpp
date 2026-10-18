// E4 S4: speaker-ANC howl guard. See N60AncGuard.h for the contract.
//
// Band-pass sections: RBJ Audio EQ Cookbook band-pass (constant 0 dB peak
// gain), R. Bristow-Johnson. Detection rules: docs/ANC_QUALIFICATION.md s3.

#include "n60_anc_guard.hpp"

#include <algorithm>
#include <cmath>
#include <new>

#if __cplusplus < 202002L
#error "n60_anc_guard.cpp requires C++20"
#endif

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kLowestBandHz = 20.0;
constexpr double kHighestBandHz = 500.0;
constexpr double kBandQ = 4.3;
constexpr double kDecimatedRateHz = 4000.0;
constexpr double kMinimumRate = 8000.0;
constexpr double kMaximumRate = 768000.0;

double fromDB(double db) { return std::pow(10.0, db / 10.0); }

}  // namespace

namespace n60::anc {

Guard::Guard(const N60AncGuardConfig &config) noexcept
    : hasErrorBaseline_(config.hasErrorBaseline),
      growthBlocks_(config.growthBlocks),
      errorRiseBlocks_(config.errorRiseBlocks),
      blockFrames_(static_cast<std::uint32_t>(
          std::lround(config.sampleRate * N60_ANC_GUARD_BLOCK_SECONDS))),
      decimation_(std::max<std::uint32_t>(
          1u, static_cast<std::uint32_t>(config.sampleRate / kDecimatedRateHz))),
      rampFrames_(std::max<std::uint32_t>(
          1u, static_cast<std::uint32_t>(
                  std::lround(config.sampleRate * config.muteRampSeconds)))),
      ceiling_(config.outputCeiling),
      growthRatio_(fromDB(config.growthDBPer20ms)),
      referenceAllowance_(fromDB(config.referenceAllowanceDB)),
      errorRatio_(fromDB(config.errorRiseDB)),
      activityFloor_(fromDB(config.activityFloorDB)) {
    const double decimatedRate = config.sampleRate / decimation_;
    for (std::uint32_t k = 0; k < kBands; ++k) {
        baseline_[k] = fromDB(config.errorBaselineDB[k]);
        const double w0 = 2.0 * kPi * N60AncGuardBandCentreHz(k) / decimatedRate;
        const double alpha = std::sin(w0) / (2.0 * kBandQ);
        const double a0 = 1.0 + alpha;
        bands_[k].b0 = alpha / a0;
        bands_[k].b2 = -alpha / a0;
        bands_[k].a1 = -2.0 * std::cos(w0) / a0;
        bands_[k].a2 = (1.0 - alpha) / a0;
    }
}

void Guard::requestRearm() noexcept {
    shared_.rearmRequested.store(true, std::memory_order_release);
}

N60AncGuardStatus Guard::status() const noexcept {
    const auto reason = static_cast<N60AncGuardTrip>(
        shared_.trip.load(std::memory_order_acquire));
    return N60AncGuardStatus{
        .trip = reason,
        .tripped = reason != N60AncGuardTripNone,
        .muted = shared_.muted.load(std::memory_order_acquire),
        .tripFrame = shared_.tripFrame.load(std::memory_order_relaxed),
        .processedFrames = shared_.processedFrames.load(std::memory_order_relaxed),
        .tripCount = shared_.tripCount.load(std::memory_order_relaxed),
    };
}

void Guard::rearm() noexcept {
    blockPosition_ = 0;
    blocksSeen_ = 0;
    outSum_ = refSum_ = 0;
    outHistory_ = {};
    refHistory_ = {};
    decimatePosition_ = 0;
    decimateSum_ = 0;
    bandSum_ = {};
    bandCount_ = 0;
    for (auto &band : bands_) band.z1 = band.z2 = 0;
    growthRun_ = errorRun_ = 0;
    framesSinceArm_ = 0;
    startRamp(1.0f);
    shared_.muted.store(false, std::memory_order_release);
    shared_.trip.store(N60AncGuardTripNone, std::memory_order_release);
}

void Guard::trip(N60AncGuardTrip reason) noexcept {
    if (shared_.trip.load(std::memory_order_relaxed) != N60AncGuardTripNone) return;
    startRamp(0.0f);
    if (gain_ == 0.0f) shared_.muted.store(true, std::memory_order_release);
    shared_.tripFrame.store(framesSinceArm_, std::memory_order_relaxed);
    shared_.tripCount.fetch_add(1, std::memory_order_relaxed);
    shared_.trip.store(reason, std::memory_order_release);
}

void Guard::startRamp(float target) noexcept {
    rampStart_ = gain_;
    gainTarget_ = target;
    rampRemaining_ = gain_ == target ? 0 : rampFrames_;
}

float Guard::applyGain(float sample) noexcept {
    if (rampRemaining_ > 0) {
        --rampRemaining_;
        const float left = static_cast<float>(rampRemaining_)
            / static_cast<float>(rampFrames_);
        gain_ = gainTarget_ + (rampStart_ - gainTarget_) * left;
        if (rampRemaining_ == 0 && gain_ == 0.0f) {
            shared_.muted.store(true, std::memory_order_release);
        }
    }
    return sample * gain_;
}

void Guard::endBlock() noexcept {
    const double out = outSum_ / blockFrames_;
    const double ref = refSum_ / blockFrames_;
    const bool active = out > activityFloor_;

    if (blocksSeen_ >= 2) {
        const double outGrowth = out / std::max(outHistory_[1], activityFloor_);
        const double refGrowth = std::clamp(
            ref / std::max(refHistory_[1], activityFloor_),
            1.0, referenceAllowance_);
        growthRun_ = (active && outGrowth > growthRatio_ * refGrowth)
            ? growthRun_ + 1 : 0;
        if (growthRun_ >= growthBlocks_) trip(N60AncGuardTripGrowth);
    }

    if (hasErrorBaseline_ && bandCount_ > 0) {
        bool risen = false;
        for (std::uint32_t k = 0; k < kBands; ++k) {
            risen |= bandSum_[k] / bandCount_ > baseline_[k] * errorRatio_;
        }
        errorRun_ = (active && risen) ? errorRun_ + 1 : 0;
        if (errorRun_ >= errorRiseBlocks_) trip(N60AncGuardTripErrorRise);
    }

    outHistory_[1] = outHistory_[0];
    outHistory_[0] = out;
    refHistory_[1] = refHistory_[0];
    refHistory_[0] = ref;
    blocksSeen_ = std::min<std::uint32_t>(blocksSeen_ + 1, 2);
    outSum_ = refSum_ = 0;
    bandSum_ = {};
    bandCount_ = 0;
    blockPosition_ = 0;
}

N60AncGuardTrip Guard::process(float *antiNoise, const float *reference,
                               const float *error,
                               std::uint32_t frames) noexcept {
    if (shared_.rearmRequested.exchange(false, std::memory_order_acq_rel)) rearm();
    const bool useError = hasErrorBaseline_ && error != nullptr;

    for (std::uint32_t i = 0; i < frames; ++i) {
        float x = antiNoise[i];
        if (!std::isfinite(x)) {
            trip(N60AncGuardTripNonFinite);
            x = 0.0f;
        } else if (std::fabs(x) > ceiling_) {
            trip(N60AncGuardTripOverCeiling);
            x = std::copysign(ceiling_, x);
        }
        outSum_ += static_cast<double>(x) * x;
        if (reference != nullptr) {
            const float r = reference[i];
            if (std::isfinite(r)) {
                refSum_ += static_cast<double>(r) * r;
            } else {
                trip(N60AncGuardTripNonFinite);
            }
        }
        if (useError) {
            float e = error[i];
            if (!std::isfinite(e)) {
                trip(N60AncGuardTripNonFinite);
                e = 0.0f;
            }
            decimateSum_ += e;
            if (++decimatePosition_ == decimation_) {
                const double sample = decimateSum_ / decimation_;
                for (std::uint32_t k = 0; k < kBands; ++k) {
                    const double y = bands_[k].run(sample);
                    bandSum_[k] += y * y;
                }
                ++bandCount_;
                decimatePosition_ = 0;
                decimateSum_ = 0;
            }
        }
        antiNoise[i] = applyGain(x);
        ++framesSinceArm_;
        if (++blockPosition_ == blockFrames_) endBlock();
    }
    shared_.processedFrames.fetch_add(frames, std::memory_order_relaxed);
    return static_cast<N60AncGuardTrip>(shared_.trip.load(std::memory_order_relaxed));
}

}  // namespace n60::anc

struct N60AncGuard {
    n60::anc::Guard guard;
};

extern "C" {

N60AncGuardConfig N60AncGuardConfigDefault(double sampleRate) {
    N60AncGuardConfig config{};
    config.sampleRate = sampleRate;
    config.growthDBPer20ms = 6.0f;
    config.growthBlocks = 3;
    config.referenceAllowanceDB = 3.0f;
    config.errorRiseDB = 6.0f;
    config.errorRiseBlocks = 3;
    config.outputCeiling = 0.5f;
    config.activityFloorDB = -60.0f;
    config.muteRampSeconds = 0.010;
    config.hasErrorBaseline = false;
    for (auto &db : config.errorBaselineDB) db = -120.0f;
    return config;
}

bool N60AncGuardConfigIsValid(const N60AncGuardConfig *config) {
    if (config == nullptr) return false;
    const auto finite = [](double v) { return std::isfinite(v); };
    if (!finite(config->sampleRate) || config->sampleRate < kMinimumRate
        || config->sampleRate > kMaximumRate) return false;
    const auto inDB = [&](double v, double lo, double hi) {
        return finite(v) && v >= lo && v <= hi;
    };
    if (!inDB(config->growthDBPer20ms, 0.5, 40)
        || config->growthBlocks < 1 || config->growthBlocks > 10) return false;
    if (!inDB(config->referenceAllowanceDB, 0, 20)) return false;
    if (!inDB(config->errorRiseDB, 0.5, 40)
        || config->errorRiseBlocks < 1 || config->errorRiseBlocks > 10) return false;
    if (!finite(config->outputCeiling) || config->outputCeiling <= 0
        || config->outputCeiling > 1) return false;
    if (!finite(config->activityFloorDB) || config->activityFloorDB > 0
        || config->activityFloorDB < -160) return false;
    if (!finite(config->muteRampSeconds) || config->muteRampSeconds < 0.001
        || config->muteRampSeconds > 0.1) return false;
    if (config->hasErrorBaseline) {
        for (const float db : config->errorBaselineDB) {
            if (!finite(db) || db > 0 || db < -200) return false;
        }
    }
    return true;
}

double N60AncGuardBandCentreHz(uint32_t band) {
    const uint32_t k = std::min(band, N60_ANC_GUARD_BAND_COUNT - 1u);
    return kLowestBandHz * std::pow(kHighestBandHz / kLowestBandHz,
                                    k / double(N60_ANC_GUARD_BAND_COUNT - 1u));
}

N60AncGuard *N60AncGuardCreate(const N60AncGuardConfig *config) {
    if (!N60AncGuardConfigIsValid(config)) return nullptr;
    return new (std::nothrow) N60AncGuard{n60::anc::Guard(*config)};
}

void N60AncGuardDestroy(N60AncGuard *guard) { delete guard; }

N60AncGuardTrip N60AncGuardProcess(N60AncGuard *guard, float *antiNoise,
                                   const float *reference, const float *error,
                                   uint32_t frames) {
    return guard->guard.process(antiNoise, reference, error, frames);
}

void N60AncGuardRequestRearm(N60AncGuard *guard) { guard->guard.requestRearm(); }

N60AncGuardStatus N60AncGuardReadStatus(const N60AncGuard *guard) {
    return guard->guard.status();
}

}  // extern "C"
