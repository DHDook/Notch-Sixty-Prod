// E4 S22b3: echo stage of the live feed-forward filter. See n60_ff_echo.hpp for the method and the
// realtime contract.

#include "n60_ff_echo.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace n60::anc {

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr std::uint32_t kSearchRetrySeconds = 20;

std::uint32_t nextPowerOfTwo(std::uint32_t v) {
    std::uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

std::int64_t floorDiv(std::int64_t a, std::int64_t b) {
    std::int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
    return q;
}
}  // namespace

void LiveEcho::Biquad::design(bool highPass, double fc, double fs) noexcept {
    const double w0 = 2.0 * kPi * fc / fs;
    const double c = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * 0.70710678118654752);
    const double a0 = 1.0 + alpha;
    if (highPass) {
        b0 = (1.0 + c) / 2.0 / a0;
        b1 = -(1.0 + c) / a0;
        b2 = b0;
    } else {
        b0 = (1.0 - c) / 2.0 / a0;
        b1 = (1.0 - c) / a0;
        b2 = b0;
    }
    a1 = -2.0 * c / a0;
    a2 = (1.0 - alpha) / a0;
    clear();
}

LiveEcho::LiveEcho(double sampleRate, std::uint32_t factor, std::uint32_t half, std::uint32_t maxBlock,
                   const std::vector<float> &decimatorReversed, const std::vector<float> &polyphase)
    : sampleRate_(sampleRate),
      factor_(factor),
      half_(half),
      chain_(2 * half * factor),
      kernelLength_(2 * half * factor + 1),
      maxBlock_(maxBlock),
      searchHalf_(static_cast<std::uint32_t>(std::ceil(kSearchHalfWidthMs * 0.001 * sampleRate / factor))),
      maxFd_(maxBlock / factor + 3),
      decimatorReversed_(decimatorReversed),
      polyphase_(polyphase) {
    const std::uint32_t keep = kernelLength_ - 1;
    for (Lane &lane : driveLanes_) lane.buffer.assign(static_cast<std::size_t>(keep) + maxBlock_, 0.0f);
    rawLane_.buffer.assign(static_cast<std::size_t>(keep) + maxBlock_, 0.0f);
    cleanLane_.buffer.assign(static_cast<std::size_t>(keep) + maxBlock_, 0.0f);
    for (auto &ring : ddRing_) ring.assign(2u * kRing, 0.0f);
    pmRing_.assign(kRing, 0.0f);
    rawFd_.assign(maxFd_, 0.0f);
    cleanFd_.assign(maxFd_, 0.0f);
    fdIndex_.assign(maxFd_, 0);
    corr_.assign(2u * searchHalf_ + 1u, 0.0);
    delayLine_.assign(nextPowerOfTwo(factor_ + 2), 0.0f);
    for (auto &t : model_.taps) t.assign(kMaxTaps, 0.0f);
    const double fd = sampleRate_ / factor_;
    for (Band &band : bands_) {
        band.high.design(true, 31.5, fd);
        band.low.design(false, 125.0, fd);
    }
}

// Control thread ---------------------------------------------------------------------------------

bool LiveEcho::setModel(const N60FeedForwardLiveEcho *echo) noexcept {
    Model &back = modelBox_.back();
    if (echo == nullptr) {
        back.valid = false;
        back.count = {0, 0};
        back.bulk = {0, 0};
    } else {
        for (int c = 0; c < 2; ++c) {
            if (echo->tapCount[c] > kMaxTaps || echo->bulkDelay[c] > N60FeedForwardLiveEchoMaxBulk) return false;
            if (echo->tapCount[c] > 0) {
                if (echo->taps[c] == nullptr) return false;
                for (std::uint32_t i = 0; i < echo->tapCount[c]; ++i)
                    if (!std::isfinite(echo->taps[c][i])) return false;
            }
        }
        if (echo->tapCount[0] == 0 && echo->tapCount[1] == 0) return false;
        for (int c = 0; c < 2; ++c) {
            back.count[c] = echo->tapCount[c];
            back.bulk[c] = echo->bulkDelay[c];
            if (back.taps[c].size() != kMaxTaps) back.taps[c].assign(kMaxTaps, 0.0f);
            for (std::uint32_t i = 0; i < echo->tapCount[c]; ++i)
                back.taps[c][i] = echo->taps[c][echo->tapCount[c] - 1 - i];   // reversed for the dot
        }
        back.valid = true;
    }
    modelBox_.publish();
    modelGeneration_.fetch_add(1, std::memory_order_release);
    return true;
}

bool LiveEcho::setTiming(std::uint32_t baseLagFrames) noexcept {
    if (static_cast<double>(baseLagFrames) > 0.1 * sampleRate_) return false;
    timingFrames_.store(baseLagFrames, std::memory_order_relaxed);
    timingValid_.store(1, std::memory_order_relaxed);
    timingGeneration_.fetch_add(1, std::memory_order_release);
    return true;
}

// Audio thread -----------------------------------------------------------------------------------

float LiveEcho::dot(const float *a, const float *b, std::uint32_t count) noexcept {
    float lanes[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    std::uint32_t i = 0;
    for (; i + 8 <= count; i += 8)
        for (std::uint32_t k = 0; k < 8; ++k) lanes[k] += a[i + k] * b[i + k];
    float sum = ((lanes[0] + lanes[4]) + (lanes[1] + lanes[5])) + ((lanes[2] + lanes[6]) + (lanes[3] + lanes[7]));
    for (; i < count; ++i) sum += a[i] * b[i];
    return sum;
}

float LiveEcho::windowDot(const std::vector<float> &taps, const float *ring, std::int64_t end,
                          std::uint32_t count) const noexcept {
    if (count == 0) return 0.0f;
    const std::int64_t start = end - static_cast<std::int64_t>(count) + 1;
    const std::size_t slot = static_cast<std::size_t>(start & static_cast<std::int64_t>(kRing - 1));
    return dot(taps.data(), ring + slot, count);
}

template <class Sink>
void LiveEcho::decimate(Lane &lane, const float *in, std::uint32_t frames, std::uint64_t first,
                        Sink &&sink) noexcept {
    const std::uint32_t keep = kernelLength_ - 1;
    float *base = lane.buffer.data();
    std::memmove(base, base + lane.last, keep * sizeof(float));
    std::memcpy(base + keep, in, static_cast<std::size_t>(frames) * sizeof(float));
    lane.last = frames;
    std::uint32_t n = static_cast<std::uint32_t>((factor_ - first % factor_) % factor_);
    for (; n < frames; n += factor_)
        sink(first + n, dot(decimatorReversed_.data(), base + n, kernelLength_));
}

void LiveEcho::storeDrive(std::uint32_t channel, std::int64_t m, float value) noexcept {
    const std::size_t slot = static_cast<std::size_t>(m & static_cast<std::int64_t>(kRing - 1));
    ddRing_[channel][slot] = value;
    ddRing_[channel][slot + kRing] = value;
}

void LiveEcho::resetDriveLine(std::uint64_t driveStart) noexcept {
    for (Lane &lane : driveLanes_) {
        std::fill(lane.buffer.begin(), lane.buffer.end(), 0.0f);
        lane.last = 0;
    }
    for (auto &ring : ddRing_) std::fill(ring.begin(), ring.end(), 0.0f);
    std::fill(pmRing_.begin(), pmRing_.end(), 0.0f);
    ddNext_ = (driveStart + factor_ - 1) / factor_;
    pmNext_ = ddNext_;
    loud_ = false;
}

void LiveEcho::clearMeters() noexcept {
    meterBefore_ = meterAfter_ = meterSeconds_ = meterCount_ = 0;
    partBefore_.fill(0.0);
    partAfter_.fill(0.0);
    partIndex_ = partsFilled_ = 0;
    partSeconds_ = 0;
    for (Band &band : bands_) band.clear();
    before_.store(0, std::memory_order_relaxed);
    after_.store(0, std::memory_order_relaxed);
    seconds_.store(0, std::memory_order_relaxed);
}

void LiveEcho::restartSearch() noexcept {
    state_.store(active_ ? N60FeedForwardLiveEchoSearching : N60FeedForwardLiveEchoOff, std::memory_order_release);
    std::fill(corr_.begin(), corr_.end(), 0.0);
    energyRef_ = energyPm_ = searchSeconds_ = 0;
    nextCheck_ = kSearchSeconds;
    edgeTruncated_ = false;
    width_ = 0;
    if (!active_) return;
    restarts_.fetch_add(1, std::memory_order_relaxed);
    searchBlock_ = std::max<std::uint32_t>(callbackFrames_, 1);
    const std::uint32_t centre = (baseLag_ + factor_ / 2) / factor_;
    const std::uint32_t nominalLo = centre > searchHalf_ ? centre - searchHalf_ : 1;
    const std::uint32_t hi = centre + searchHalf_;
    const std::uint32_t bulkMin = std::min(model_.bulk[0], model_.bulk[1]);
    const std::uint32_t need1 = (searchBlock_ + factor_ - 1) / factor_ + 2;
    const std::int64_t need2 =
        static_cast<std::int64_t>((searchBlock_ + 2u * factor_ + chain_ + factor_ - 1) / factor_) + 1
        - static_cast<std::int64_t>(bulkMin);
    const std::uint32_t required = std::max<std::uint32_t>(need1, need2 > 0 ? static_cast<std::uint32_t>(need2) : 0u);
    lo_ = std::max(nominalLo, required);
    edgeTruncated_ = nominalLo < required;
    if (hi < lo_ || hi + 8 >= kRing) {
        state_.store(N60FeedForwardLiveEchoRefused, std::memory_order_release);
        return;
    }
    width_ = hi - lo_ + 1;
    peak_.store(0, std::memory_order_relaxed);
}

void LiveEcho::dropLock() noexcept {
    if (!active_) return;
    clearMeters();
    std::fill(pmRing_.begin(), pmRing_.end(), 0.0f);   // nothing predicted while locked: no stale values
    restartSearch();
}

void LiveEcho::reset() noexcept {
    refFrame_ = 0;
    callbackFrames_ = 0;
    gapPending_ = zeroSkip_ = false;
    for (Lane &lane : driveLanes_) {
        std::fill(lane.buffer.begin(), lane.buffer.end(), 0.0f);
        lane.last = 0;
    }
    for (Lane *lane : {&rawLane_, &cleanLane_}) {
        std::fill(lane->buffer.begin(), lane->buffer.end(), 0.0f);
        lane->last = 0;
    }
    resetDriveLine(0);
    predicted_.fill(0.0f);
    std::fill(delayLine_.begin(), delayLine_.end(), 0.0f);
    clearMeters();
    restartSearch();
}

void LiveEcho::applyPending(bool idle) noexcept {
    if (!idle) return;
    bool changed = false;
    const std::uint32_t modelGeneration = modelGeneration_.load(std::memory_order_acquire);
    if (modelGeneration != appliedModel_) {
        appliedModel_ = modelGeneration;
        if (modelBox_.acquire()) {
            const Model &fresh = modelBox_.front();
            for (int c = 0; c < 2; ++c) {
                model_.count[c] = fresh.count[c];
                model_.bulk[c] = fresh.bulk[c];
                std::copy(fresh.taps[c].begin(), fresh.taps[c].begin() + fresh.count[c], model_.taps[c].begin());
            }
            model_.valid = fresh.valid;
        }
        changed = true;
    }
    const std::uint32_t timingGeneration = timingGeneration_.load(std::memory_order_acquire);
    if (timingGeneration != appliedTiming_) {
        appliedTiming_ = timingGeneration;
        baseLag_ = timingFrames_.load(std::memory_order_relaxed);
        changed = true;
    }
    if (!changed) return;
    active_ = model_.valid && timingValid_.load(std::memory_order_relaxed) != 0;
    publishedBase_.store(baseLag_, std::memory_order_relaxed);
    if (active_) {
        // The drive line starts here: frames before this chunk were never pushed.
        resetDriveLine(refFrame_);
        predicted_.fill(0.0f);
        std::fill(delayLine_.begin(), delayLine_.end(), 0.0f);
    }
    clearMeters();
    restartSearch();
}

void LiveEcho::noteGaps(std::uint32_t zeroFrames, std::uint32_t skippedFrames) noexcept {
    if (zeroFrames > 0) zeroSkip_ = true;
    if (skippedFrames > 0) gapPending_ = true;
}

LiveEcho::Fault LiveEcho::pushDrive(const float *left, const float *right, std::uint32_t frames) noexcept {
    if (!active_) return Fault::None;
    Fault fault = Fault::None;
    if (frames == 0 && callbackFrames_ == 0 && !gapPending_) return fault;
    const std::uint64_t start = refFrame_ >= frames ? refFrame_ - frames : 0;
    if (frames != callbackFrames_ || gapPending_) {
        fault = Fault::AlignmentLost;
        discontinuities_.fetch_add(1, std::memory_order_relaxed);
        gapPending_ = false;
        resetDriveLine(start);
    }
    double power = 0;
    const float *channels[2] = {left, right};
    std::uint32_t done = 0;
    while (done < frames) {
        const std::uint32_t chunk = std::min(frames - done, maxBlock_);
        for (std::uint32_t c = 0; c < 2; ++c) {
            const float *in = channels[c] + done;
            for (std::uint32_t i = 0; i < chunk; ++i) power += static_cast<double>(in[i]) * in[i];
            decimate(driveLanes_[c], in, chunk, start + done, [this, c](std::uint64_t g, float d) {
                const std::int64_t m = static_cast<std::int64_t>(g / factor_);
                storeDrive(c, m, d);
                ddNext_ = std::max<std::uint64_t>(ddNext_, static_cast<std::uint64_t>(m) + 1);
            });
        }
        done += chunk;
    }
    const double mean = frames ? power / (2.0 * frames) : 0.0;
    drivePower_.store(static_cast<float>(mean), std::memory_order_relaxed);
    loud_ = mean > kProgrammeFloor;
    if (state_.load(std::memory_order_relaxed) == N60FeedForwardLiveEchoSearching) {
        for (; pmNext_ < ddNext_; ++pmNext_) {
            const std::int64_t m = static_cast<std::int64_t>(pmNext_);
            float p = 0;
            for (std::uint32_t c = 0; c < 2; ++c)
                p += windowDot(model_.taps[c], ddRing_[c].data(), m - model_.bulk[c], model_.count[c]);
            pmRing_[pmNext_ & (kRing - 1)] = p;
        }
    }
    pmNext_ = ddNext_;
    return fault;
}

float LiveEcho::refinedLag(const std::vector<double> &corr, std::uint32_t peak) const noexcept {
    // The cross-correlation is band-limited to fd / 2, so a windowed sinc interpolates it between the
    // fd samples; a parabola through the three best grid points then removes the grid step.
    constexpr int kReach = 8;
    constexpr int kGrid = 8;
    const int width = static_cast<int>(corr.size());
    const int first = std::max(0, static_cast<int>(peak) - kReach);
    const int last = std::min(width - 1, static_cast<int>(peak) + kReach);
    auto value = [&](double tau) {
        double sum = 0;
        for (int j = first; j <= last; ++j) {
            const double x = tau - j;
            if (std::fabs(x) >= kReach + 1) continue;
            const double sinc = std::fabs(x) < 1e-9 ? 1.0 : std::sin(kPi * x) / (kPi * x);
            const double window = 0.5 * (1.0 + std::cos(kPi * x / (kReach + 1)));
            sum += corr[static_cast<std::size_t>(j)] * sinc * window;
        }
        return sum;
    };
    double best = -1e300;
    int bestIndex = 0;
    std::array<double, 2 * kGrid + 1> grid{};
    for (int i = -kGrid; i <= kGrid; ++i) {
        grid[static_cast<std::size_t>(i + kGrid)] = value(peak + static_cast<double>(i) / kGrid);
        if (grid[static_cast<std::size_t>(i + kGrid)] > best) {
            best = grid[static_cast<std::size_t>(i + kGrid)];
            bestIndex = i;
        }
    }
    double offset = static_cast<double>(bestIndex) / kGrid;
    if (bestIndex > -kGrid && bestIndex < kGrid) {
        const double a = grid[static_cast<std::size_t>(bestIndex + kGrid - 1)];
        const double b = grid[static_cast<std::size_t>(bestIndex + kGrid)];
        const double c = grid[static_cast<std::size_t>(bestIndex + kGrid + 1)];
        const double denominator = a - 2.0 * b + c;
        if (denominator < 0) offset += 0.5 * (a - c) / denominator / kGrid;
    }
    return static_cast<float>(static_cast<double>(peak) + offset);
}

void LiveEcho::configureLock(std::uint32_t lagNative) noexcept {
    const std::int64_t base = static_cast<std::int64_t>(lagNative) - static_cast<std::int64_t>(chain_);
    const std::int64_t quotient = floorDiv(base, factor_);
    const std::int64_t remainder = base - quotient * factor_;
    const std::int64_t minimum = static_cast<std::int64_t>(searchBlock_ / factor_) + 2;
    for (std::uint32_t c = 0; c < 2; ++c) {
        q_[c] = quotient + model_.bulk[c];
        if (q_[c] < minimum
            || q_[c] + static_cast<std::int64_t>(model_.count[c]) + maxFd_ + 4 > static_cast<std::int64_t>(kRing)) {
            state_.store(N60FeedForwardLiveEchoRefused, std::memory_order_release);
            return;
        }
    }
    lagNative_ = lagNative;
    remainder_ = static_cast<std::uint32_t>(remainder);
    predicted_.fill(0.0f);
    std::fill(delayLine_.begin(), delayLine_.end(), 0.0f);
    clearMeters();
    publishedLag_.store(lagNative, std::memory_order_relaxed);
    state_.store(N60FeedForwardLiveEchoLocked, std::memory_order_release);
}

void LiveEcho::evaluateSearch() noexcept {
    nextCheck_ += 1.0;
    if (!std::isfinite(energyRef_) || !std::isfinite(energyPm_)) {
        // A non-finite sample reached the accumulators: start the search over.
        restartSearch();
        return;
    }
    if (width_ == 0 || energyRef_ <= 0 || energyPm_ <= 0) {
        if (searchSeconds_ > kSearchRetrySeconds) restartSearch();
        return;
    }
    std::uint32_t best = 0;
    for (std::uint32_t k = 1; k < width_; ++k)
        if (corr_[k] > corr_[best]) best = k;
    const double norm = corr_[best] / std::sqrt(energyRef_ * energyPm_);
    if (!std::isfinite(norm)) {
        restartSearch();
        return;
    }
    peak_.store(static_cast<float>(std::max(0.0, std::min(1.0, norm))), std::memory_order_relaxed);
    if (norm >= kLockPeak) {
        if (best == 0 && edgeTruncated_) {
            state_.store(N60FeedForwardLiveEchoRefused, std::memory_order_release);
            return;
        }
        if (best > 0 && best + 1 < width_) {
            const float s = lo_ + refinedLag(corr_, best);
            configureLock(static_cast<std::uint32_t>(std::lround(static_cast<double>(s) * factor_)));
            return;
        }
    }
    if (searchSeconds_ > kSearchRetrySeconds) {
        const float keep = peak_.load(std::memory_order_relaxed);
        restartSearch();
        peak_.store(keep, std::memory_order_relaxed);
    }
}

LiveEcho::Fault LiveEcho::clean(const float *reference, float *cleaned, std::uint32_t frames) noexcept {
    const bool skip = zeroSkip_;
    zeroSkip_ = false;
    Fault fault = Fault::None;
    const std::uint64_t first = refFrame_;

    fdCount_ = 0;
    decimate(rawLane_, reference, frames, first, [this](std::uint64_t g, float d) {
        if (fdCount_ < maxFd_) {
            fdIndex_[fdCount_] = g / factor_;
            rawFd_[fdCount_] = d;
            ++fdCount_;
        }
    });
    const bool qualified = !skip && loud_;
    const double blockSeconds = frames / sampleRate_;
    const std::uint32_t state = state_.load(std::memory_order_relaxed);

    if (state == N60FeedForwardLiveEchoSearching) {
        std::memcpy(cleaned, reference, static_cast<std::size_t>(frames) * sizeof(float));
        if (qualified) {
            if (callbackFrames_ > searchBlock_) {
                restartSearch();   // a larger block needs a later first lag
            }
            if (state_.load(std::memory_order_relaxed) == N60FeedForwardLiveEchoSearching && width_ > 0) {
                const std::int64_t reach = static_cast<std::int64_t>(pmNext_);
                for (std::uint32_t i = 0; i < fdCount_; ++i) {
                    const std::int64_t m = static_cast<std::int64_t>(fdIndex_[i]);
                    if (m - static_cast<std::int64_t>(lo_) >= reach) continue;
                    const double rd = rawFd_[i];
                    energyRef_ += rd * rd;
                    const double p0 = pmRing_[static_cast<std::size_t>((m - lo_) & (kRing - 1))];
                    energyPm_ += p0 * p0;
                    for (std::uint32_t k = 0; k < width_; ++k)
                        corr_[k] += rd * pmRing_[static_cast<std::size_t>((m - static_cast<std::int64_t>(lo_ + k)) & (kRing - 1))];
                }
                searchSeconds_ += blockSeconds;
                if (searchSeconds_ >= nextCheck_) evaluateSearch();
            }
        }
        seconds_.store(searchSeconds_, std::memory_order_relaxed);
    } else if (state == N60FeedForwardLiveEchoLocked) {
        const std::int64_t lastM = static_cast<std::int64_t>((first + frames - 1) / factor_);
        const std::int64_t available = static_cast<std::int64_t>(ddNext_) - 1;
        if (lastM - q_[0] > available || lastM - q_[1] > available) {
            fault = Fault::AlignmentLost;
            discontinuities_.fetch_add(1, std::memory_order_relaxed);
            std::memcpy(cleaned, reference, static_cast<std::size_t>(frames) * sizeof(float));
        } else {
            const std::size_t mask = delayLine_.size() - 1;
            for (std::uint32_t n = 0; n < frames; ++n) {
                const std::uint64_t g = first + n;
                const std::uint32_t phase = static_cast<std::uint32_t>(g % factor_);
                if (phase == 0) {
                    const std::int64_t m = static_cast<std::int64_t>(g / factor_);
                    float p = 0;
                    for (std::uint32_t c = 0; c < 2; ++c)
                        p += windowDot(model_.taps[c], ddRing_[c].data(), m - q_[c], model_.count[c]);
                    for (std::uint32_t k = kHistory - 1; k > 0; --k) predicted_[k] = predicted_[k - 1];
                    predicted_[0] = p;
                }
                const float *poly = polyphase_.data() + static_cast<std::size_t>(phase) * kHistory;
                float e = 0;
                for (std::uint32_t k = 0; k < kHistory; ++k) e += poly[k] * predicted_[k];
                delayLine_[g & mask] = e;
                const float delayed = delayLine_[(g - remainder_) & mask];
                cleaned[n] = skip ? reference[n] : reference[n] - delayed;
            }
        }
        std::uint32_t cleanCount = 0;
        decimate(cleanLane_, cleaned, frames, first, [this, &cleanCount](std::uint64_t, float d) {
            if (cleanCount < maxFd_) cleanFd_[cleanCount++] = d;
        });
        for (std::uint32_t i = 0; i < fdCount_ && i < cleanCount; ++i) {
            if (!std::isfinite(rawFd_[i]) || !std::isfinite(cleanFd_[i])) {
                // One bad sample must not poison the meters for the whole lock.
                for (Band &band : bands_) band.clear();
                if (!std::isfinite(cleanFd_[i]) && fault == Fault::None) fault = Fault::Diverged;
                continue;
            }
            const double before = bands_[0].run(rawFd_[i]);
            const double after = bands_[1].run(cleanFd_[i]);
            if (qualified && fault == Fault::None) {
                meterBefore_ += before * before;
                meterAfter_ += after * after;
                partBefore_[partIndex_] += before * before;
                partAfter_[partIndex_] += after * after;
                meterCount_ += 1;
            }
        }
        if (qualified && fault == Fault::None) {
            meterSeconds_ += blockSeconds;
            partSeconds_ += blockSeconds;
            if (partSeconds_ >= kDivergeWindowSeconds / kDivergeParts) {
                partSeconds_ = 0;
                if (partsFilled_ < kDivergeParts) ++partsFilled_;
                if (partsFilled_ == kDivergeParts) {
                    // Subtraction that adds more than 3 dB in band over the last 250 ms is harming the reference.
                    double sumBefore = 0, sumAfter = 0;
                    for (std::uint32_t i = 0; i < kDivergeParts; ++i) {
                        sumBefore += partBefore_[i];
                        sumAfter += partAfter_[i];
                    }
                    if (sumBefore > 0 && sumAfter > 2.0 * sumBefore) fault = Fault::Diverged;
                }
                partIndex_ = (partIndex_ + 1) % kDivergeParts;
                partBefore_[partIndex_] = partAfter_[partIndex_] = 0;
            }
        }
        seconds_.store(meterSeconds_, std::memory_order_relaxed);
        if (meterCount_ > 0) {
            before_.store(meterBefore_ / meterCount_, std::memory_order_relaxed);
            after_.store(meterAfter_ / meterCount_, std::memory_order_relaxed);
        }
    } else {
        std::memcpy(cleaned, reference, static_cast<std::size_t>(frames) * sizeof(float));
    }
    refFrame_ += frames;
    return fault;
}

N60FeedForwardLiveEchoStatus LiveEcho::status() const noexcept {
    N60FeedForwardLiveEchoStatus s{};
    s.state = state_.load(std::memory_order_acquire);
    s.lagFrames = publishedLag_.load(std::memory_order_relaxed);
    s.baseLagFrames = publishedBase_.load(std::memory_order_relaxed);
    s.driveDiscontinuities = discontinuities_.load(std::memory_order_relaxed);
    s.peak = peak_.load(std::memory_order_relaxed);
    s.drivePower = drivePower_.load(std::memory_order_relaxed);
    s.programmeSeconds = seconds_.load(std::memory_order_relaxed);
    s.bandBeforePower = before_.load(std::memory_order_relaxed);
    s.bandAfterPower = after_.load(std::memory_order_relaxed);
    s.searchRestarts = restarts_.load(std::memory_order_relaxed);
    return s;
}

}  // namespace n60::anc
