// E4 S5: adaptive speaker-ANC core. See N60Fxlms.h for the contract and the
// update rules.
//
// Sources: narrowband and block FxLMS, S. M. Kuo and D. R. Morgan, Active
// Noise Control Systems (Wiley, 1996), ch. 3-4; auxiliary-noise secondary-path
// modelling, L. J. Eriksson and M. C. Allie, JASA 85(2), 1989; probe low-pass,
// RBJ Audio EQ Cookbook (R. Bristow-Johnson); window, R. B. Blackman and
// J. W. Tukey, The Measurement of Power Spectra (1958).

#include "n60_fxlms.hpp"

#include <algorithm>
#include <cmath>
#include <new>

#if !(__cplusplus >= 202002L || (defined(_MSVC_LANG) && _MSVC_LANG >= 202002L))
#error "n60_fxlms.cpp requires C++20"
#endif

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;
constexpr double kAdaptationRateHz = 4000.0;
constexpr double kMinimumRate = 8000.0;
constexpr double kMaximumRate = 768000.0;
constexpr std::uint32_t kTapsPerFactor = 16;
constexpr double kCutoffPerFactor = 0.3;
constexpr std::uint32_t kChunkDecimated = 16;
constexpr std::uint32_t kPathRefreshSamples = 16;
constexpr std::uint64_t kNotchSettleSamples = 256;
constexpr double kNotchBandwidthHz = 10.0;
constexpr double kProbeCutoffHz = 400.0;
constexpr std::uint64_t kDefaultProbeSeed = 0x9E3779B97F4A7C15ull;
constexpr double kPowerFloor = 1e-10;
constexpr double kReferencePowerFloor = 1e-8;  // -80 dBFS
constexpr double kErrorLimit = 8.0;            // decimated error clamp
constexpr double kPathSettleConstants = 3.0;
constexpr double kFlush = 1e-30;

double amplitudeFromDB(double db) { return std::pow(10.0, db / 20.0); }

double fraction(double x) { return x - std::floor(x); }

bool finite(double v) { return std::isfinite(v); }

}  // namespace

namespace n60::anc {

// Decimator ----------------------------------------------------------------

std::uint32_t Decimator::factorFor(double sampleRate) noexcept {
    if (!finite(sampleRate) || sampleRate < kMinimumRate || sampleRate > kMaximumRate) return 0;
    return static_cast<std::uint32_t>(sampleRate / kAdaptationRateHz);
}

Decimator::Decimator(double sampleRate)
    : factor_(std::max<std::uint32_t>(1u, factorFor(sampleRate))),
      length_(kTapsPerFactor * factor_ + 1),
      taps_(length_),
      history_(2 * static_cast<std::size_t>(length_)) {
    const double fc = kCutoffPerFactor / factor_;
    const double centre = 0.5 * (length_ - 1);
    const double span = length_ - 1;
    double sum = 0;
    for (std::uint32_t i = 0; i < length_; ++i) {
        const double t = i - centre;
        const double x = kTwoPi * fc * t;
        const double sinc = t == 0 ? 1.0 : std::sin(x) / x;
        const double window = 0.42 - 0.5 * std::cos(kTwoPi * i / span)
                              + 0.08 * std::cos(2.0 * kTwoPi * i / span);
        taps_[i] = 2.0 * fc * sinc * window;
        sum += taps_[i];
    }
    for (auto &tap : taps_) tap /= sum;
}

bool Decimator::push(float x, double &out) noexcept {
    history_[position_] = x;
    history_[position_ + length_] = x;
    position_ = position_ + 1 == length_ ? 0 : position_ + 1;
    ++seen_;
    if (++phase_ < factor_) return false;
    phase_ = 0;
    // The taps are symmetric, so the history order does not matter.
    const double *h = history_.data() + position_;
    double acc = 0;
    for (std::uint32_t i = 0; i < length_; ++i) acc += taps_[i] * h[i];
    out = acc;
    return true;
}

void Decimator::reset() noexcept {
    std::fill(history_.begin(), history_.end(), 0.0);
    position_ = 0;
    phase_ = 0;
    seen_ = 0;
}

// Notch --------------------------------------------------------------------

void Notch::design(double cyclesPerSample, double radius) noexcept {
    const double c = std::cos(kTwoPi * cyclesPerSample);
    b1 = -2.0 * c;
    a1 = -2.0 * radius * c;
    a2 = radius * radius;
    z1 = z2 = 0;
}

double Notch::run(double x) noexcept {
    const double y = x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = x - a2 * y;
    if (z1 > -kFlush && z1 < kFlush) z1 = 0;
    if (z2 > -kFlush && z2 < kFlush) z2 = 0;
    return y;
}

// PathModel ----------------------------------------------------------------

PathModel::PathModel(std::uint32_t taps, double step)
    : taps_(taps), step_(step), weights_(taps), history_(2 * static_cast<std::size_t>(taps)) {}

void PathModel::update(double probe, double error) noexcept {
    position_ = position_ == 0 ? taps_ - 1 : position_ - 1;
    history_[position_] = probe;
    history_[position_ + taps_] = probe;
    power_ += (probe * probe - power_) / taps_;
    const double *r = history_.data() + position_;
    double predicted = 0;
    for (std::uint32_t k = 0; k < taps_; ++k) predicted += weights_[k] * r[k];
    const double gain = step_ * (error - predicted) / (taps_ * power_ + kPowerFloor);
    for (std::uint32_t k = 0; k < taps_; ++k) weights_[k] += gain * r[k];
}

Complex PathModel::responseAt(double cyclesPerSample) const noexcept {
    const double sr = std::cos(kTwoPi * cyclesPerSample);
    const double si = -std::sin(kTwoPi * cyclesPerSample);
    double pr = 1, pi = 0, re = 0, im = 0;
    for (std::uint32_t k = 0; k < taps_; ++k) {
        re += weights_[k] * pr;
        im += weights_[k] * pi;
        const double nr = pr * sr - pi * si;
        pi = pr * si + pi * sr;
        pr = nr;
    }
    return {re, im};
}

void PathModel::clearHistory() noexcept {
    std::fill(history_.begin(), history_.end(), 0.0);
    position_ = 0;
    power_ = 0;
}

void PathModel::reset() noexcept {
    clearHistory();
    std::fill(weights_.begin(), weights_.end(), 0.0);
}

// AdaptiveTonal ------------------------------------------------------------

AdaptiveTonal::AdaptiveTonal(const N60AdaptiveTonalConfig &config)
    : sampleRate_(config.sampleRate),
      decimatedRate_(config.sampleRate / Decimator::factorFor(config.sampleRate)),
      toneCount_(config.toneCount),
      updateGain_(2.0 / (config.convergenceSeconds * decimatedRate_)),
      leakage_(config.leakagePerSecond / decimatedRate_),
      toneCap_(amplitudeFromDB(config.toneCapDBFS)),
      aggregateCap_(amplitudeFromDB(config.aggregateCapDBFS)),
      pathFloor2_(static_cast<double>(config.pathFloor) * config.pathFloor),
      probeEnabled_(config.probeEnabled),
      probeSeed_(config.probeSeed != 0 ? config.probeSeed : kDefaultProbeSeed),
      chunkFrames_(kChunkDecimated * Decimator::factorFor(config.sampleRate)),
      chunkCount_(std::max<std::uint32_t>(
          2u, static_cast<std::uint32_t>(
                  std::ceil(config.ringSeconds * config.sampleRate / chunkFrames_)))),
      ringError_(static_cast<std::size_t>(chunkFrames_) * chunkCount_),
      ringProbe_(static_cast<std::size_t>(chunkFrames_) * chunkCount_),
      ringStart_(chunkCount_),
      probeState_(probeSeed_),
      errorDecimator_(config.sampleRate),
      probeDecimator_(config.sampleRate),
      path_(config.pathTaps, config.pathTaps / (config.pathConvergenceSeconds * decimatedRate_)),
      pathSettleSamples_(static_cast<std::uint64_t>(
          kPathSettleConstants * config.pathConvergenceSeconds * decimatedRate_)) {
    for (std::uint32_t k = 0; k < kTones; ++k) {
        toneHz_[k] = k < toneCount_ ? config.toneHz[k] : 0.0;
        toneSeed_[k] = k < toneCount_ ? Complex(config.toneSeed[k].re, config.toneSeed[k].im)
                                      : Complex();
        stepRe_[k] = std::cos(kTwoPi * toneHz_[k] / sampleRate_);
        stepIm_[k] = std::sin(kTwoPi * toneHz_[k] / sampleRate_);
    }
    // Probe: uniform white noise (RMS 1 / sqrt 3) through a second-order
    // Butterworth low-pass, scaled by its equivalent noise bandwidth
    // fc (pi / 4) / sin(pi / 4) so its RMS is probeLevelDBFS at every rate.
    const double w0 = kTwoPi * kProbeCutoffHz / sampleRate_;
    const double alpha = std::sin(w0) / (2.0 * std::sqrt(0.5));
    const double a0 = 1.0 + alpha;
    const double c = std::cos(w0);
    probeB0_ = 0.5 * (1.0 - c) / a0;
    probeB1_ = (1.0 - c) / a0;
    probeB2_ = probeB0_;
    probeA1_ = -2.0 * c / a0;
    probeA2_ = (1.0 - alpha) / a0;
    const double noiseBandwidth = kProbeCutoffHz * (kPi / 4.0) / std::sin(kPi / 4.0);
    probeScale_ = amplitudeFromDB(config.probeLevelDBFS) * std::sqrt(3.0)
                  / std::sqrt(2.0 * noiseBandwidth / sampleRate_);

    const double radius = std::exp(-kPi * kNotchBandwidthHz / decimatedRate_);
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        errorNotch_[k].design(toneHz_[k] / decimatedRate_, radius);
        probeNotch_[k].design(toneHz_[k] / decimatedRate_, radius);
    }
    resetModel();
    publish();
}

float AdaptiveTonal::nextProbe() noexcept {
    // xorshift64* (S. Vigna, 2016).
    probeState_ ^= probeState_ >> 12;
    probeState_ ^= probeState_ << 25;
    probeState_ ^= probeState_ >> 27;
    const std::uint64_t r = probeState_ * 2685821657736338717ull;
    const double u = ((static_cast<double>(r >> 40) + 0.5) / 16777216.0) * 2.0 - 1.0;
    const double y = probeB0_ * u + probeZ1_;
    probeZ1_ = probeB1_ * u - probeA1_ * y + probeZ2_;
    probeZ2_ = probeB2_ * u - probeA2_ * y;
    return static_cast<float>(probeScale_ * y);
}

void AdaptiveTonal::process(const float *error, float *output, std::uint32_t frames) noexcept {
    if (frames == 0) return;
    if (discontinuity_.exchange(false, std::memory_order_acquire)) {
        // Abandon the partial chunk and skip a chunk of frames, so the worker
        // sees a gap and restarts its filters rather than adapting across it.
        chunkFill_ = 0;
        frame_ += chunkFrames_;
    }
    const auto start = applied_;
    auto target = applied_;
    if (exchange_.acquire()) target = exchange_.front().w;

    // Tone phase is exact at the start of every buffer, then rotated.
    std::array<double, kTones> pr{}, pi{};
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        const double phase = kTwoPi * fraction(toneHz_[k] * static_cast<double>(frame_) / sampleRate_);
        pr[k] = std::cos(phase);
        pi[k] = std::sin(phase);
    }
    const double inverse = 1.0 / frames;
    for (std::uint32_t n = 0; n < frames; ++n) {
        const double t = (n + 1) * inverse;
        double y = 0;
        for (std::uint32_t k = 0; k < toneCount_; ++k) {
            const double wr = start[k].real() + (target[k].real() - start[k].real()) * t;
            const double wi = start[k].imag() + (target[k].imag() - start[k].imag()) * t;
            y += wr * pr[k] - wi * pi[k];
            const double nr = pr[k] * stepRe_[k] - pi[k] * stepIm_[k];
            pi[k] = pr[k] * stepIm_[k] + pi[k] * stepRe_[k];
            pr[k] = nr;
        }
        const float probe = probeEnabled_ ? nextProbe() : 0.0f;
        output[n] = static_cast<float>(y) + probe;

        if (chunkFill_ == 0) {
            const auto head = head_.load(std::memory_order_relaxed);
            chunkDropping_ = head - tail_.load(std::memory_order_acquire) >= chunkCount_;
            chunkSlot_ = head % chunkCount_;
            if (!chunkDropping_) ringStart_[chunkSlot_] = frame_;
        }
        if (!chunkDropping_) {
            const std::size_t index = chunkSlot_ * chunkFrames_ + chunkFill_;
            ringError_[index] = std::isfinite(error[n]) ? error[n] : 0.0f;
            ringProbe_[index] = probe;
        }
        if (++chunkFill_ == chunkFrames_) {
            chunkFill_ = 0;
            if (chunkDropping_) {
                droppedFrames_.fetch_add(chunkFrames_, std::memory_order_relaxed);
            } else {
                head_.store(head_.load(std::memory_order_relaxed) + 1, std::memory_order_release);
            }
        }
        ++frame_;
    }
    applied_ = target;
}

std::uint32_t AdaptiveTonal::service() noexcept {
    bool changed = false;
    if (resetRequested_.exchange(false, std::memory_order_acq_rel)) {
        resetModel();
        changed = true;
    }
    auto tail = tail_.load(std::memory_order_relaxed);
    const auto head = head_.load(std::memory_order_acquire);
    std::uint32_t used = 0;
    while (tail != head) {
        const auto slot = tail % chunkCount_;
        const auto start = ringStart_[slot];
        if (!started_ || start != expectedFrame_) {
            if (started_) ++gaps_;
            restartFilters();
            started_ = true;
        }
        const float *error = ringError_.data() + slot * chunkFrames_;
        const float *probe = ringProbe_.data() + slot * chunkFrames_;
        for (std::uint32_t i = 0; i < chunkFrames_; ++i) {
            double e = 0, v = 0;
            const bool ready = errorDecimator_.push(error[i], e);
            probeDecimator_.push(probe[i], v);
            if (ready && errorDecimator_.warm()) {
                adapt(start + i, e, v);
                ++used;
            }
        }
        expectedFrame_ = start + chunkFrames_;
        ++tail;
        tail_.store(tail, std::memory_order_release);
    }
    if (used > 0 || changed) publish();
    return used;
}

void AdaptiveTonal::markDiscontinuity() noexcept {
    discontinuity_.store(true, std::memory_order_release);
}

void AdaptiveTonal::adapt(std::uint64_t frame, double error, double probe) noexcept {
    error = std::clamp(error, -kErrorLimit, kErrorLimit);
    ++decimatedSamples_;
    ++sinceRestart_;
    if (probeEnabled_) {
        double e = error, v = probe;
        for (std::uint32_t k = 0; k < toneCount_; ++k) {
            e = errorNotch_[k].run(e);
            v = probeNotch_[k].run(v);
        }
        if (sinceRestart_ > kNotchSettleSamples) {
            path_.update(v, e);
            ++pathUpdates_;
        }
        if (++pathRefresh_ >= kPathRefreshSamples) {
            pathRefresh_ = 0;
            refreshPath();
        }
    }
    // The decimated sample describes native frame (frame - G).
    const double aligned = static_cast<double>(frame - errorDecimator_.delayFrames());
    double total = 0;
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        double wr = weights_[k].real() * (1.0 - leakage_);
        double wi = weights_[k].imag() * (1.0 - leakage_);
        const double sRe = pathAtTone_[k].real(), sIm = pathAtTone_[k].imag();
        const double magnitude2 = sRe * sRe + sIm * sIm;
        // With the probe on, a tone waits for the path model to settle: an
        // estimate far below the true path would multiply the loop gain.
        adapting_[k] = magnitude2 >= pathFloor2_
                       && (!probeEnabled_ || pathUpdates_ >= pathSettleSamples_);
        if (adapting_[k]) {
            const double phase = kTwoPi * fraction(toneHz_[k] * aligned / sampleRate_);
            const double c = std::cos(phase), s = std::sin(phase);
            // W -= g e conj(S exp(j phase)).
            const double qr = sRe * c - sIm * s;
            const double qi = sRe * s + sIm * c;
            const double g = updateGain_ * error / magnitude2;
            wr -= g * qr;
            wi += g * qi;
        }
        const double magnitude = std::sqrt(wr * wr + wi * wi);
        if (magnitude > toneCap_) {
            wr *= toneCap_ / magnitude;
            wi *= toneCap_ / magnitude;
            total += toneCap_;
        } else {
            total += magnitude;
        }
        weights_[k] = {wr, wi};
    }
    if (total > aggregateCap_) {
        const double scale = aggregateCap_ / total;
        for (std::uint32_t k = 0; k < toneCount_; ++k) weights_[k] *= scale;
    }
    if (!std::isfinite(total)) {
        ++modelResets_;
        resetModel();
    }
}

void AdaptiveTonal::refreshPath() noexcept {
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        pathAtTone_[k] = path_.responseAt(toneHz_[k] / decimatedRate_);
        if (!std::isfinite(pathAtTone_[k].real()) || !std::isfinite(pathAtTone_[k].imag())) {
            ++modelResets_;
            resetModel();
            return;
        }
    }
}

void AdaptiveTonal::restartFilters() noexcept {
    errorDecimator_.reset();
    probeDecimator_.reset();
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        errorNotch_[k].z1 = errorNotch_[k].z2 = 0;
        probeNotch_[k].z1 = probeNotch_[k].z2 = 0;
    }
    path_.clearHistory();
    sinceRestart_ = 0;
    pathRefresh_ = 0;
}

void AdaptiveTonal::resetModel() noexcept {
    weights_ = {};
    adapting_ = {};
    path_.reset();
    pathUpdates_ = 0;
    pathAtTone_ = probeEnabled_ ? std::array<Complex, kTones>{} : toneSeed_;
    restartFilters();
}

void AdaptiveTonal::requestReset() noexcept {
    resetRequested_.store(true, std::memory_order_release);
}

void AdaptiveTonal::publish() noexcept {
    exchange_.back().w = weights_;
    exchange_.publish();
    auto &s = statusExchange_.back();
    s = N60AdaptiveTonalStatus{};
    s.sequence = ++sequence_;
    s.decimatedSamples = decimatedSamples_;
    s.gaps = gaps_;
    s.modelResets = modelResets_;
    for (std::uint32_t k = 0; k < toneCount_; ++k) {
        s.weight[k] = {static_cast<float>(weights_[k].real()), static_cast<float>(weights_[k].imag())};
        s.path[k] = {static_cast<float>(pathAtTone_[k].real()), static_cast<float>(pathAtTone_[k].imag())};
        s.adapting[k] = adapting_[k];
    }
    statusExchange_.publish();
}

N60AdaptiveTonalStatus AdaptiveTonal::status() noexcept {
    if (statusExchange_.acquire()) lastStatus_ = statusExchange_.front();
    auto s = lastStatus_;
    s.droppedFrames = droppedFrames_.load(std::memory_order_relaxed);
    return s;
}

// BlockFxlms ---------------------------------------------------------------

BlockFxlms::BlockFxlms(const N60BlockFxlmsConfig &config)
    : taps_(config.taps),
      blockFrames_(config.blockFrames),
      step_(config.step),
      leakage_(config.leakagePerSecond * config.blockFrames / config.sampleRate),
      filteredHistory_(2 * static_cast<std::size_t>(config.taps)),
      weights_(config.taps),
      gradient_(config.taps) {
    // Reserve the largest path so setPath never allocates.
    path_.reserve(N60_FXLMS_MAX_PATH_TAPS);
    referenceHistory_.reserve(2 * N60_FXLMS_MAX_PATH_TAPS);
    path_.assign(1, 1.0);
    referenceHistory_.assign(2, 0.0);
}

bool BlockFxlms::setPath(const float *taps, std::uint32_t count) noexcept {
    if (taps == nullptr || count == 0 || count > N60_FXLMS_MAX_PATH_TAPS) return false;
    path_.assign(taps, taps + count);
    referenceHistory_.assign(2 * static_cast<std::size_t>(count), 0.0);
    referencePosition_ = 0;
    return true;
}

void BlockFxlms::update(const float *reference, const float *error, std::uint32_t frames) noexcept {
    const auto pathTaps = static_cast<std::uint32_t>(path_.size());
    for (std::uint32_t m = 0; m < frames; ++m) {
        const double x = std::isfinite(reference[m]) ? reference[m] : 0.0;
        const double e = std::isfinite(error[m]) ? error[m] : 0.0;
        referencePosition_ = referencePosition_ == 0 ? pathTaps - 1 : referencePosition_ - 1;
        referenceHistory_[referencePosition_] = x;
        referenceHistory_[referencePosition_ + pathTaps] = x;
        const double *rx = referenceHistory_.data() + referencePosition_;
        double filtered = 0;
        for (std::uint32_t k = 0; k < pathTaps; ++k) filtered += path_[k] * rx[k];

        filteredPosition_ = filteredPosition_ == 0 ? taps_ - 1 : filteredPosition_ - 1;
        filteredHistory_[filteredPosition_] = filtered;
        filteredHistory_[filteredPosition_ + taps_] = filtered;
        power_ += (filtered * filtered - power_) / taps_;
        const double *r = filteredHistory_.data() + filteredPosition_;
        for (std::uint32_t k = 0; k < taps_; ++k) gradient_[k] += e * r[k];

        if (++blockPosition_ == blockFrames_) {
            blockPosition_ = 0;
            const double norm = step_ / (blockFrames_ * taps_ * (power_ + kReferencePowerFloor));
            const double keep = 1.0 - leakage_;
            for (std::uint32_t k = 0; k < taps_; ++k) {
                weights_[k] = keep * weights_[k] - norm * gradient_[k];
                gradient_[k] = 0;
            }
        }
    }
}

void BlockFxlms::copyWeights(float *out, std::uint32_t count) const noexcept {
    const auto n = std::min(count, taps_);
    for (std::uint32_t k = 0; k < n; ++k) out[k] = static_cast<float>(weights_[k]);
}

void BlockFxlms::setWeights(const float *in, std::uint32_t count) noexcept {
    for (std::uint32_t k = 0; k < taps_; ++k) weights_[k] = k < count ? in[k] : 0.0;
}

}  // namespace n60::anc

// C interface --------------------------------------------------------------

struct N60AncDecimator {
    n60::anc::Decimator core;
};

struct N60AdaptiveTonal {
    n60::anc::AdaptiveTonal core;
};

struct N60BlockFxlms {
    n60::anc::BlockFxlms core;
};

extern "C" {

uint32_t N60AncDecimationFactor(double sampleRate) {
    return n60::anc::Decimator::factorFor(sampleRate);
}

uint32_t N60AncDecimatorDelayFrames(double sampleRate) {
    return kTapsPerFactor / 2 * n60::anc::Decimator::factorFor(sampleRate);
}

N60AncDecimator *N60AncDecimatorCreate(double sampleRate) {
    if (n60::anc::Decimator::factorFor(sampleRate) == 0) return nullptr;
    try {
        return new N60AncDecimator{n60::anc::Decimator(sampleRate)};
    } catch (...) {
        return nullptr;
    }
}

void N60AncDecimatorDestroy(N60AncDecimator *decimator) { delete decimator; }

uint32_t N60AncDecimatorProcess(N60AncDecimator *decimator, const float *input, uint32_t frames,
                                float *output, uint32_t capacity) {
    uint32_t written = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        double out = 0;
        if (decimator->core.push(input[i], out) && written < capacity) {
            output[written++] = static_cast<float>(out);
        }
    }
    return written;
}

N60AdaptiveTonalConfig N60AdaptiveTonalConfigDefault(double sampleRate) {
    N60AdaptiveTonalConfig config{};
    config.sampleRate = sampleRate;
    config.toneCount = 0;
    config.convergenceSeconds = 0.25;
    config.leakagePerSecond = 0.01;
    config.toneCapDBFS = -24.0f;
    config.aggregateCapDBFS = -18.0f;
    config.pathFloor = 1e-3f;
    config.probeEnabled = false;
    config.probeLevelDBFS = -50.0f;
    config.probeSeed = kDefaultProbeSeed;
    config.pathTaps = 64;
    config.pathConvergenceSeconds = 0.5;
    config.ringSeconds = 0.25;
    return config;
}

bool N60AdaptiveTonalConfigIsValid(const N60AdaptiveTonalConfig *config) {
    if (config == nullptr) return false;
    const uint32_t factor = n60::anc::Decimator::factorFor(config->sampleRate);
    if (factor == 0) return false;
    const double decimatedRate = config->sampleRate / factor;
    const auto in = [](double v, double lo, double hi) { return finite(v) && v >= lo && v <= hi; };
    if (config->toneCount > N60_FXLMS_MAX_TONES) return false;
    for (uint32_t k = 0; k < config->toneCount; ++k) {
        if (!in(config->toneHz[k], 20, 150)) return false;
        if (!finite(config->toneSeed[k].re) || !finite(config->toneSeed[k].im)) return false;
    }
    if (!in(config->convergenceSeconds, N60_FXLMS_MIN_CONVERGENCE_SECONDS, 60)) return false;
    if (!in(config->leakagePerSecond, 0, 10)) return false;
    if (!in(config->toneCapDBFS, -120, -6) || !in(config->aggregateCapDBFS, -120, -6)) return false;
    if (!(config->pathFloor > 0 && config->pathFloor <= 1)) return false;
    if (!in(config->probeLevelDBFS, -90, -40)) return false;
    if (config->pathTaps < 8 || config->pathTaps > N60_FXLMS_MAX_PATH_TAPS) return false;
    if (!in(config->pathConvergenceSeconds, 0.01, 600)) return false;
    if (config->pathTaps / (config->pathConvergenceSeconds * decimatedRate) > 0.5) return false;
    return in(config->ringSeconds, 0.05, 2);
}

N60AdaptiveTonal *N60AdaptiveTonalCreate(const N60AdaptiveTonalConfig *config) {
    if (!N60AdaptiveTonalConfigIsValid(config)) return nullptr;
    try {
        return new N60AdaptiveTonal{n60::anc::AdaptiveTonal(*config)};
    } catch (...) {
        return nullptr;
    }
}

void N60AdaptiveTonalDestroy(N60AdaptiveTonal *core) { delete core; }

void N60AdaptiveTonalProcess(N60AdaptiveTonal *core, const float *error, float *output,
                             uint32_t frames) {
    core->core.process(error, output, frames);
}

uint32_t N60AdaptiveTonalService(N60AdaptiveTonal *core) { return core->core.service(); }

void N60AdaptiveTonalRequestReset(N60AdaptiveTonal *core) { core->core.requestReset(); }

void N60AdaptiveTonalMarkDiscontinuity(N60AdaptiveTonal *core) {
    core->core.markDiscontinuity();
}

N60AdaptiveTonalStatus N60AdaptiveTonalReadStatus(N60AdaptiveTonal *core) {
    return core->core.status();
}

N60BlockFxlmsConfig N60BlockFxlmsConfigDefault(double sampleRate) {
    N60BlockFxlmsConfig config{};
    config.sampleRate = sampleRate;
    config.taps = 64;
    config.blockFrames = 32;
    config.step = 0.1f;
    config.leakagePerSecond = 0.01;
    return config;
}

bool N60BlockFxlmsConfigIsValid(const N60BlockFxlmsConfig *config) {
    if (config == nullptr) return false;
    if (!finite(config->sampleRate) || config->sampleRate < 1000
        || config->sampleRate > kMaximumRate) return false;
    if (config->taps < 1 || config->taps > N60_FXLMS_MAX_BLOCK_TAPS) return false;
    if (config->blockFrames < 1 || config->blockFrames > 1024) return false;
    if (!finite(config->step) || config->step <= 0 || config->step > N60_FXLMS_MAX_BLOCK_STEP)
        return false;
    return finite(config->leakagePerSecond) && config->leakagePerSecond >= 0
           && config->leakagePerSecond <= 10;
}

N60BlockFxlms *N60BlockFxlmsCreate(const N60BlockFxlmsConfig *config) {
    if (!N60BlockFxlmsConfigIsValid(config)) return nullptr;
    try {
        return new N60BlockFxlms{n60::anc::BlockFxlms(*config)};
    } catch (...) {
        return nullptr;
    }
}

void N60BlockFxlmsDestroy(N60BlockFxlms *fxlms) { delete fxlms; }

bool N60BlockFxlmsSetPath(N60BlockFxlms *fxlms, const float *taps, uint32_t count) {
    return fxlms->core.setPath(taps, count);
}

void N60BlockFxlmsUpdate(N60BlockFxlms *fxlms, const float *reference, const float *error,
                         uint32_t frames) {
    fxlms->core.update(reference, error, frames);
}

void N60BlockFxlmsCopyWeights(const N60BlockFxlms *fxlms, float *weights, uint32_t count) {
    fxlms->core.copyWeights(weights, count);
}

void N60BlockFxlmsSetWeights(N60BlockFxlms *fxlms, const float *weights, uint32_t count) {
    fxlms->core.setWeights(weights, count);
}

}  // extern "C"
