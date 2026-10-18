#pragma once

// E4 S5: C++20 core of the adaptive speaker-ANC (FxLMS). The C interface, the
// update rules and the realtime contract are documented in N60Fxlms.h.

#include "N60Fxlms.h"

#include <array>
#include <atomic>
#include <complex>
#include <cstdint>
#include <vector>

namespace n60::anc {

using Complex = std::complex<double>;

static_assert(std::atomic<std::uint32_t>::is_always_lock_free
              && std::atomic<std::uint64_t>::is_always_lock_free
              && std::atomic<bool>::is_always_lock_free,
              "the adaptive ANC core's shared state must be lock-free");

// Single-producer, single-consumer latest-value exchange. Neither side ever
// waits: the writer fills back() and publishes; the reader takes the newest
// published value, if any, with acquire().
template <class T>
class TripleBuffer {
public:
    T &back() noexcept { return slots_[back_]; }
    void publish() noexcept {
        const auto previous = middle_.exchange(back_ | kFresh, std::memory_order_acq_rel);
        back_ = previous & kIndex;
    }
    bool acquire() noexcept {
        if ((middle_.load(std::memory_order_relaxed) & kFresh) == 0) return false;
        const auto previous = middle_.exchange(front_, std::memory_order_acq_rel);
        front_ = previous & kIndex;
        return true;
    }
    const T &front() const noexcept { return slots_[front_]; }

private:
    static constexpr std::uint32_t kIndex = 3, kFresh = 4;
    std::array<T, 3> slots_{};
    std::uint32_t back_ = 0;
    alignas(64) std::atomic<std::uint32_t> middle_{1};
    alignas(64) std::uint32_t front_ = 2;
};

// Linear-phase FIR decimator from the native rate to fs / floor(fs / 4000).
class Decimator {
public:
    explicit Decimator(double sampleRate);
    static std::uint32_t factorFor(double sampleRate) noexcept;
    std::uint32_t factor() const noexcept { return factor_; }
    std::uint32_t delayFrames() const noexcept { return (length_ - 1) / 2; }
    // True once the history holds a full filter length since the last reset.
    bool warm() const noexcept { return seen_ >= length_; }
    // Feeds one sample; returns true and sets out on every D-th sample.
    bool push(float x, double &out) noexcept;
    void reset() noexcept;

private:
    std::uint32_t factor_;
    std::uint32_t length_;
    std::vector<double> taps_;
    std::vector<double> history_;  // mirrored, 2 * length_
    std::uint32_t position_ = 0;
    std::uint32_t phase_ = 0;
    std::uint64_t seen_ = 0;
};

// Second-order notch at the decimated rate (transposed direct form II).
struct Notch {
    double b1 = 0, a1 = 0, a2 = 0;  // b0 = b2 = 1
    double z1 = 0, z2 = 0;
    void design(double cyclesPerSample, double radius) noexcept;
    double run(double x) noexcept;  // flushes decaying state to zero
};

// NLMS FIR model of the secondary path, from probe and error at fd.
class PathModel {
public:
    PathModel(std::uint32_t taps, double step);
    void update(double probe, double error) noexcept;
    Complex responseAt(double cyclesPerSample) const noexcept;
    void clearHistory() noexcept;
    void reset() noexcept;

private:
    std::uint32_t taps_;
    double step_;
    std::vector<double> weights_;
    std::vector<double> history_;  // mirrored, newest first from position_
    std::uint32_t position_ = 0;
    double power_ = 0;
};

class AdaptiveTonal {
public:
    // Control plane. The config must already be valid.
    explicit AdaptiveTonal(const N60AdaptiveTonalConfig &config);

    void process(const float *error, float *output, std::uint32_t frames) noexcept;
    void markDiscontinuity() noexcept;
    std::uint32_t service() noexcept;
    void requestReset() noexcept;
    N60AdaptiveTonalStatus status() noexcept;

private:
    static constexpr std::uint32_t kTones = N60_FXLMS_MAX_TONES;
    struct Weights {
        std::array<Complex, kTones> w{};
    };

    float nextProbe() noexcept;
    void adapt(std::uint64_t frame, double error, double probe) noexcept;
    void restartFilters() noexcept;
    void resetModel() noexcept;
    void refreshPath() noexcept;
    void publish() noexcept;

    // Fixed configuration.
    double sampleRate_;
    double decimatedRate_;
    std::uint32_t toneCount_;
    std::array<double, kTones> toneHz_{};
    std::array<Complex, kTones> toneSeed_{};
    double updateGain_;   // 2 / (tau fd)
    double leakage_;      // lambda / fd
    double toneCap_;
    double aggregateCap_;
    double pathFloor2_;
    bool probeEnabled_;
    bool shadow_;
    double meterAlpha_;
    double probeScale_;
    std::uint64_t probeSeed_;
    std::uint32_t chunkFrames_;
    std::uint32_t chunkCount_;

    // Ring of fixed-size chunks; the realtime side writes, the worker reads.
    std::vector<float> ringError_;
    std::vector<float> ringProbe_;
    std::vector<std::uint64_t> ringStart_;
    alignas(64) std::atomic<std::uint64_t> head_{0};
    alignas(64) std::atomic<std::uint64_t> tail_{0};

    // Realtime-thread state.
    alignas(64) std::uint64_t frame_ = 0;
    std::uint64_t probeState_;
    double probeB0_ = 0, probeB1_ = 0, probeB2_ = 0, probeA1_ = 0, probeA2_ = 0;
    double probeZ1_ = 0, probeZ2_ = 0;
    std::uint32_t chunkFill_ = 0;
    std::uint64_t chunkSlot_ = 0;
    bool chunkDropping_ = false;
    std::array<Complex, kTones> applied_{};
    std::array<double, kTones> stepRe_{};  // exp(j 2 pi f / fs)
    std::array<double, kTones> stepIm_{};
    alignas(64) std::atomic<std::uint64_t> droppedFrames_{0};
    std::atomic<bool> discontinuity_{false};

    // Worker-thread state.
    alignas(64) Decimator errorDecimator_;
    Decimator probeDecimator_;
    std::array<Notch, kTones> errorNotch_{};
    std::array<Notch, kTones> probeNotch_{};
    PathModel path_;
    std::array<Complex, kTones> weights_{};
    std::array<Complex, kTones> pathAtTone_{};
    std::array<bool, kTones> adapting_{};
    std::array<Complex, kTones> measuredTone_{};
    std::array<Complex, kTones> predictedTone_{};
    std::uint64_t expectedFrame_ = 0;
    bool started_ = false;
    std::uint64_t sinceRestart_ = 0;
    std::uint64_t pathUpdates_ = 0;     // since the last model reset
    std::uint64_t pathSettleSamples_;   // 3 T fd
    std::uint64_t modelResets_ = 0;
    std::uint32_t pathRefresh_ = 0;
    std::uint64_t decimatedSamples_ = 0;
    std::uint64_t gaps_ = 0;
    std::uint64_t sequence_ = 0;
    alignas(64) std::atomic<bool> resetRequested_{false};

    TripleBuffer<Weights> exchange_;
    TripleBuffer<N60AdaptiveTonalStatus> statusExchange_;
    N60AdaptiveTonalStatus lastStatus_{};
};

class BlockFxlms {
public:
    explicit BlockFxlms(const N60BlockFxlmsConfig &config);
    bool setPath(const float *taps, std::uint32_t count) noexcept;
    void update(const float *reference, const float *error, std::uint32_t frames) noexcept;
    void copyWeights(float *out, std::uint32_t count) const noexcept;
    void setWeights(const float *in, std::uint32_t count) noexcept;
    std::uint32_t taps() const noexcept { return taps_; }
    const double *weights() const noexcept { return weights_.data(); }
    void scaleWeights(double factor) noexcept;
    // Zeroes the histories, the pending gradient and the power estimate.
    void clearHistory() noexcept;

private:
    std::uint32_t taps_;
    std::uint32_t blockFrames_;
    double step_;
    double leakage_;  // per block
    std::vector<double> path_;
    std::vector<double> referenceHistory_;  // mirrored, path length
    std::uint32_t referencePosition_ = 0;
    std::vector<double> filteredHistory_;   // mirrored, taps_
    std::uint32_t filteredPosition_ = 0;
    std::vector<double> weights_;
    std::vector<double> gradient_;
    std::uint32_t blockPosition_ = 0;
    double power_ = 0;
};

}  // namespace n60::anc
