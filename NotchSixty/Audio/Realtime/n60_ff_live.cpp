// E4 S25a: live broadband feed-forward filter. See N60FeedForwardLive.h for the design and the
// realtime contract.

#include "n60_ff_live.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

namespace {

constexpr double kTwoPi = 6.283185307179586476925286766559;
constexpr double kCutoffPerFd = 0.5;      // cycles per fd sample (stopband from 0.85 fd)
constexpr double kRampUpSeconds = 0.05;
constexpr double kRampDownSeconds = 0.01;
constexpr double kDefaultFadeSeconds = 0.01;
constexpr std::uint32_t kDefaultHalf = 4;

bool finiteIn(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }

// Blackman-windowed sinc low-pass of 2 half D + 1 taps, cutoff 0.5 fd, unity DC gain.
std::vector<double> kernel(std::uint32_t factor, std::uint32_t half) {
    const std::uint32_t length = 2 * half * factor + 1;
    const double fc = kCutoffPerFd / factor;
    const double centre = 0.5 * (length - 1);
    const double span = length - 1;
    std::vector<double> taps(length);
    double sum = 0;
    for (std::uint32_t i = 0; i < length; ++i) {
        const double t = i - centre;
        const double x = kTwoPi * fc * t;
        const double sinc = t == 0 ? 1.0 : std::sin(x) / x;
        const double window = 0.42 - 0.5 * std::cos(kTwoPi * i / span)
                              + 0.08 * std::cos(2.0 * kTwoPi * i / span);
        taps[i] = 2.0 * fc * sinc * window;
        sum += taps[i];
    }
    for (double &t : taps) t /= sum;
    return taps;
}

}  // namespace

namespace n60::anc {

FeedForwardLive::FeedForwardLive(const N60FeedForwardLiveConfig &config)
    : factor_(Decimator::factorFor(config.sampleRate)),
      half_(config.kernelHalf == 0 ? kDefaultHalf : config.kernelHalf),
      offset_(2 * half_),
      kernelLength_(2 * half_ * factor_ + 1),
      headLength_((2 * offset_ - 1) * factor_ + 1),
      headCapacity_((headLength_ + 7) & ~7u),
      maxBlock_(config.maxBlockFrames),
      fadeFrames_(std::max<std::uint32_t>(
          1, static_cast<std::uint32_t>((config.swapFadeSeconds > 0 ? config.swapFadeSeconds
                                                                    : kDefaultFadeSeconds)
                                        * config.sampleRate))),
      rampUp_(std::max<std::uint32_t>(1, static_cast<std::uint32_t>(kRampUpSeconds * config.sampleRate))),
      rampDown_(std::max<std::uint32_t>(1, static_cast<std::uint32_t>(kRampDownSeconds * config.sampleRate))),
      peakLimit_(static_cast<float>(config.peakLimit)),
      decimator_(kernel(factor_, half_)),
      interpolator_(kernel(factor_, half_)),
      historyKept_(headCapacity_ - 1) {
    for (double &g : interpolator_) g *= factor_;
    // Chain kernel c = decimator * interpolator, centred at index offset_ * D.
    chain_.assign(decimator_.size() + interpolator_.size() - 1, 0.0);
    for (std::size_t i = 0; i < decimator_.size(); ++i)
        for (std::size_t j = 0; j < interpolator_.size(); ++j)
            chain_[i + j] += decimator_[i] * interpolator_[j];
    // The decimated chain has unity in-band gain, so a weight at fd spreads as c / D natively.
    for (double &c : chain_) c /= factor_;
    decimatorReversed_.resize(kernelLength_);
    for (std::uint32_t i = 0; i < kernelLength_; ++i)
        decimatorReversed_[kernelLength_ - 1 - i] = static_cast<float>(decimator_[i]);
    polyphase_.assign(static_cast<std::size_t>(factor_) * kHistory, 0.0f);
    for (std::uint32_t r = 0; r < factor_; ++r)
        for (std::uint32_t k = 0; k < kHistory; ++k) {
            const std::size_t index = static_cast<std::size_t>(r) + static_cast<std::size_t>(k) * factor_;
            if (index < interpolator_.size())
                polyphase_[static_cast<std::size_t>(r) * kHistory + k] = static_cast<float>(interpolator_[index]);
        }
    // The k = 8 phase only exists at r = 0 (index 8 D, the last tap).
    history_.assign(static_cast<std::size_t>(historyKept_) + maxBlock_, 0.0f);
    decimated_.assign(2 * kMaxTaps, 0.0f);
    auto prepare = [this](Set &set) {
        for (auto &h : set.head) h.assign(headCapacity_, 0.0f);
        for (auto &t : set.tail) t.assign(kMaxTaps, 0.0f);
    };
    prepare(active_);
    prepare(previous_);
}

void FeedForwardLive::makeSet(Set &set, const float *left, const float *right,
                              std::uint32_t count) const {
    const float *weights[kChannels] = {left, right};
    for (auto &h : set.head) if (h.size() != headCapacity_) h.assign(headCapacity_, 0.0f);
    for (auto &t : set.tail) if (t.size() != kMaxTaps) t.assign(kMaxTaps, 0.0f);
    const std::uint32_t headTaps = std::min(count, offset_);
    for (std::uint32_t ch = 0; ch < kChannels; ++ch) {
        std::vector<double> head(headLength_, 0.0);
        const std::ptrdiff_t centre = static_cast<std::ptrdiff_t>(offset_) * factor_;
        for (std::uint32_t i = 0; i < headTaps; ++i) {
            const double w = weights[ch][i];
            if (w == 0) continue;
            for (std::uint32_t n = 0; n < headLength_; ++n) {
                const std::ptrdiff_t index = static_cast<std::ptrdiff_t>(n)
                    - static_cast<std::ptrdiff_t>(i) * factor_ + centre;
                if (index >= 0 && index < static_cast<std::ptrdiff_t>(chain_.size()))
                    head[n] += w * chain_[static_cast<std::size_t>(index)];
            }
        }
        std::fill(set.head[ch].begin(), set.head[ch].end(), 0.0f);
        for (std::uint32_t j = 0; j < headLength_; ++j)
            set.head[ch][headCapacity_ - 1 - j] = static_cast<float>(head[j]);
        std::fill(set.tail[ch].begin(), set.tail[ch].end(), 0.0f);
        // Tail tap j is weight offset_ + j; reversed so index kMaxTaps - 1 - j.
        for (std::uint32_t j = 0; offset_ + j < count; ++j)
            set.tail[ch][kMaxTaps - 1 - j] = weights[ch][offset_ + j];
    }
    set.tailTaps = count > offset_ ? count - offset_ : 0;
    set.valid = true;
}

bool FeedForwardLive::setWeights(const float *left, const float *right,
                                 std::uint32_t count) noexcept {
    if (!left || !right || count == 0 || count > kMaxTaps) return false;
    for (std::uint32_t i = 0; i < count; ++i)
        if (!std::isfinite(left[i]) || !std::isfinite(right[i])) return false;
    try {
        makeSet(mailbox_.back(), left, right, count);
    } catch (...) {
        return false;
    }
    publishedTail_.store(mailbox_.back().tailTaps, std::memory_order_relaxed);
    mailbox_.publish();
    hasWeights_.store(true, std::memory_order_release);
    return true;
}

std::uint32_t FeedForwardLive::arm(double leadSeconds, double requiredSeconds) noexcept {
    if (state_.load(std::memory_order_acquire) == N60FeedForwardLiveTripped)
        return N60FeedForwardLiveArmTripped;
    if (!hasWeights_.load(std::memory_order_acquire)) return N60FeedForwardLiveArmNoWeights;
    if (!std::isfinite(leadSeconds) || !std::isfinite(requiredSeconds) || leadSeconds < requiredSeconds)
        return N60FeedForwardLiveArmShortLead;
    armRequested_.store(true, std::memory_order_release);
    return N60FeedForwardLiveArmOK;
}

void FeedForwardLive::copySet(Set &to, const Set &from) const noexcept {
    for (std::uint32_t ch = 0; ch < kChannels; ++ch) {
        std::copy(from.head[ch].begin(), from.head[ch].end(), to.head[ch].begin());
        std::copy(from.tail[ch].begin(), from.tail[ch].end(), to.tail[ch].begin());
    }
    to.tailTaps = from.tailTaps;
    to.valid = from.valid;
}

float FeedForwardLive::dot(const float *a, const float *b, std::uint32_t count) noexcept {
    float lanes[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    std::uint32_t i = 0;
    for (; i + 8 <= count; i += 8)
        for (std::uint32_t k = 0; k < 8; ++k) lanes[k] += a[i + k] * b[i + k];
    float sum = ((lanes[0] + lanes[4]) + (lanes[1] + lanes[5])) + ((lanes[2] + lanes[6]) + (lanes[3] + lanes[7]));
    for (; i < count; ++i) sum += a[i] * b[i];
    return sum;
}

void FeedForwardLive::restartState() noexcept {
    std::fill(history_.begin(), history_.end(), 0.0f);
    std::fill(decimated_.begin(), decimated_.end(), 0.0f);
    decimatedPosition_ = 0;
    phase_ = 0;
    sinceOutput_ = 0;
    for (auto &o : outputs_) o.fill(0.0f);
    fadeLeft_ = 0;
    lastFrames_ = 0;
    gain_ = 0;
}

void FeedForwardLive::reset() noexcept {
    restartState();
    state_.store(N60FeedForwardLiveIdle, std::memory_order_release);
    tripReason_.store(N60FeedForwardLiveTripNone, std::memory_order_release);
    referenceLost_.store(false, std::memory_order_release);
    armRequested_.store(false, std::memory_order_release);
    peak_.store(0, std::memory_order_relaxed);
}

void FeedForwardLive::process(const float *reference, float *left, float *right,
                              std::uint32_t frames) noexcept {
    while (frames > 0) {
        const std::uint32_t chunk = std::min(frames, maxBlock_);
        processChunk(reference, left, right, chunk);
        reference += chunk;
        left += chunk;
        right += chunk;
        frames -= chunk;
    }
}

void FeedForwardLive::processChunk(const float *reference, float *left, float *right,
                                   std::uint32_t frames) noexcept {
    // Control requests, once per chunk.
    if (referenceLost_.exchange(false, std::memory_order_acq_rel)
        && state_.load(std::memory_order_relaxed) != N60FeedForwardLiveTripped) {
        state_.store(N60FeedForwardLiveTripped, std::memory_order_release);
        tripReason_.store(N60FeedForwardLiveTripReferenceLost, std::memory_order_release);
    }
    std::uint32_t state = state_.load(std::memory_order_relaxed);
    const bool wanted = armRequested_.load(std::memory_order_acquire);
    if (state == N60FeedForwardLiveIdle && wanted && haveActive_) state = N60FeedForwardLiveArmed;
    if (state == N60FeedForwardLiveArmed && !wanted) state = N60FeedForwardLiveIdle;
    if (mailbox_.acquire()) {
        const Set &fresh = mailbox_.front();
        if (haveActive_) {
            copySet(previous_, active_);
            fadeLeft_ = fadeFrames_;
        }
        copySet(active_, fresh);
        haveActive_ = true;
        setsApplied_.fetch_add(1, std::memory_order_relaxed);
        if (wanted && state == N60FeedForwardLiveIdle) state = N60FeedForwardLiveArmed;
    }

    // history_ is [kept samples][new samples]: slide the last kept samples of the previous chunk
    // down, then append this chunk.
    {
        float *base = history_.data();
        std::memmove(base, base + lastFrames_, historyKept_ * sizeof(float));
        std::memcpy(base + historyKept_, reference, frames * sizeof(float));
        lastFrames_ = frames;
    }
    const float *history = history_.data();

    const float target = state == N60FeedForwardLiveArmed ? 1.0f : 0.0f;
    const float upStep = 1.0f / static_cast<float>(rampUp_);
    const float downStep = 1.0f / static_cast<float>(rampDown_);
    float *out[kChannels] = {left, right};
    float peak = peak_.load(std::memory_order_relaxed);
    std::uint64_t clamped = 0;
    bool nonFinite = false;

    for (std::uint32_t n = 0; n < frames; ++n) {
        const bool fading = fadeLeft_ > 0 && previous_.valid;
        const float fade = fading
            ? 1.0f - static_cast<float>(fadeLeft_) / static_cast<float>(fadeFrames_) : 1.0f;
        if (fadeLeft_ > 0) --fadeLeft_;

        float headSum[kChannels] = {0, 0};
        const float *window = history + n;
        for (std::uint32_t ch = 0; ch < kChannels; ++ch) {
            const float fresh = haveActive_ ? dot(active_.head[ch].data(), window, headCapacity_) : 0.0f;
            if (fading) {
                const float old = dot(previous_.head[ch].data(), window, headCapacity_);
                headSum[ch] = old + fade * (fresh - old);
            } else {
                headSum[ch] = fresh;
            }
        }

        if (phase_ == 0) {
            // Decimate: window of kernelLength_ samples ending at this sample.
            const float d = dot(decimatorReversed_.data(), history + (headCapacity_ - kernelLength_) + n,
                                kernelLength_);
            decimated_[decimatedPosition_] = d;
            decimated_[decimatedPosition_ + kMaxTaps] = d;
            decimatedPosition_ = (decimatedPosition_ + 1) & (kMaxTaps - 1);
            const float *line = decimated_.data() + decimatedPosition_;
            for (std::uint32_t ch = 0; ch < kChannels; ++ch) {
                float u = haveActive_ ? dot(active_.tail[ch].data(), line, kMaxTaps) : 0.0f;
                if (fading) {
                    const float old = dot(previous_.tail[ch].data(), line, kMaxTaps);
                    u = old + fade * (u - old);
                }
                std::memmove(outputs_[ch].data() + 1, outputs_[ch].data(), (kHistory - 1) * sizeof(float));
                outputs_[ch][0] = u;
            }
            sinceOutput_ = 0;
        }
        if (gain_ < target) gain_ = std::min(target, gain_ + upStep);
        else if (gain_ > target) gain_ = std::max(target, gain_ - downStep);
        const float *poly = polyphase_.data() + static_cast<std::size_t>(sinceOutput_) * kHistory;
        for (std::uint32_t ch = 0; ch < kChannels; ++ch) {
            float tail = 0;
            for (std::uint32_t k = 0; k < kHistory; ++k) tail += poly[k] * outputs_[ch][k];
            float y = headSum[ch] + tail;
            if (!std::isfinite(y)) {
                nonFinite = true;
                y = 0;
            }
            y *= gain_;
            if (y > peakLimit_) { y = peakLimit_; ++clamped; }
            else if (y < -peakLimit_) { y = -peakLimit_; ++clamped; }
            peak = std::max(peak, std::fabs(y));
            out[ch][n] = y;
        }
        ++sinceOutput_;
        if (++phase_ == factor_) phase_ = 0;
    }
    if (nonFinite) {
        tripReason_.store(N60FeedForwardLiveTripNonFinite, std::memory_order_release);
        state = N60FeedForwardLiveTripped;
        restartState();
    }
    state_.store(state, std::memory_order_release);
    if (clamped) clamped_.fetch_add(clamped, std::memory_order_relaxed);
    peak_.store(peak, std::memory_order_relaxed);
    gainPublished_.store(gain_, std::memory_order_relaxed);
}

N60FeedForwardLiveStatus FeedForwardLive::status() const noexcept {
    N60FeedForwardLiveStatus s{};
    s.state = state_.load(std::memory_order_acquire);
    s.tripReason = tripReason_.load(std::memory_order_acquire);
    s.decimation = factor_;
    s.headTaps = headLength_;
    s.tailTaps = publishedTail_.load(std::memory_order_relaxed);
    s.chainDelayFrames = offset_ * factor_;
    s.addedDelayFrames = 0;
    s.setsApplied = setsApplied_.load(std::memory_order_relaxed);
    s.clampedSamples = clamped_.load(std::memory_order_relaxed);
    s.outputPeak = peak_.load(std::memory_order_relaxed);
    s.gain = gainPublished_.load(std::memory_order_relaxed);
    return s;
}

}  // namespace n60::anc

// C interface -----------------------------------------------------------------------------------

struct N60FeedForwardLive {
    n60::anc::FeedForwardLive core;
};

extern "C" {

bool N60FeedForwardLiveConfigIsValid(const N60FeedForwardLiveConfig *config) {
    if (!config) return false;
    if (!finiteIn(config->sampleRate, 8000, 768000)) return false;
    if (n60::anc::Decimator::factorFor(config->sampleRate) == 0) return false;
    if (config->maxBlockFrames < 16 || config->maxBlockFrames > 16384) return false;
    if (config->kernelHalf != 0 && (config->kernelHalf < 3 || config->kernelHalf > 4)) return false;
    if (config->swapFadeSeconds != 0 && !finiteIn(config->swapFadeSeconds, 0.001, 0.5)) return false;
    return finiteIn(config->peakLimit, 1e-6, 1.0);
}

N60FeedForwardLive *N60FeedForwardLiveCreate(const N60FeedForwardLiveConfig *config) {
    if (!N60FeedForwardLiveConfigIsValid(config)) return nullptr;
    try {
        return new N60FeedForwardLive{n60::anc::FeedForwardLive(*config)};
    } catch (...) {
        return nullptr;
    }
}

void N60FeedForwardLiveDestroy(N60FeedForwardLive *live) { delete live; }

bool N60FeedForwardLiveSetWeights(N60FeedForwardLive *live, const float *left, const float *right,
                                  uint32_t count) {
    return live->core.setWeights(left, right, count);
}

uint32_t N60FeedForwardLiveArm(N60FeedForwardLive *live, double leadSeconds, double requiredSeconds) {
    return live->core.arm(leadSeconds, requiredSeconds);
}

void N60FeedForwardLiveDisarm(N60FeedForwardLive *live) { live->core.disarm(); }
void N60FeedForwardLiveMarkReferenceLost(N60FeedForwardLive *live) { live->core.markReferenceLost(); }

void N60FeedForwardLiveProcess(N60FeedForwardLive *live, const float *reference, float *left,
                               float *right, uint32_t frames) {
    live->core.process(reference, left, right, frames);
}

void N60FeedForwardLiveReset(N60FeedForwardLive *live) { live->core.reset(); }

N60FeedForwardLiveStatus N60FeedForwardLiveGetStatus(const N60FeedForwardLive *live) {
    return live->core.status();
}

}  // extern "C"
