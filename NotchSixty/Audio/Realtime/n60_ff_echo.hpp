#pragma once

// E4 S22b3: the echo stage of the live feed-forward filter. It takes the speaker drive (programme plus
// anti-noise) out of the reference before the filter sees it: feedback neutralisation. C++20, no Apple
// framework. Owned by FeedForwardLive; the C interface is in N60FeedForwardLive.h.
//
// Method: the drive is decimated to fd = fs / D with the filter's own kernel, run through the leakage
// model's mean taps at fd, interpolated back to the native rate with the filter's polyphase
// interpolator, and subtracted from the native reference. A one-off search on the output clock (the
// reference ring and the drive share the output index) finds the lag.
//
// Realtime contract: allocation only in the constructor and SetModel's mailbox slot (control thread);
// the audio-thread calls never allocate, lock or log. Synchronisation: a TripleBuffer for the model and
// atomics for the timing and status. Latency: none (the prediction uses only drive already rendered).
// Rates: 8 kHz to 768 kHz (D from Decimator::factorFor). Channels: a stereo drive, a mono reference.
// Block size: a callback whose frame count differs from the drive pushed for it is an AlignmentLost
// fault (a hard trip while armed). Blocks are at most N60_FF_LIVE_MAX_BLOCK (8192) frames; the drive ring
// holds 2048 fd samples, 512 ms at any rate, so the 100 ms timing cap fits.
// Reset: Reset() clears audio state; a model or timing change (applied only while idle) restarts the search.

#include "N60FeedForwardLive.h"
#include "n60_fxlms.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <vector>

namespace n60::anc {

class LiveEcho {
public:
    static constexpr std::uint32_t kMaxTaps = N60FeedForwardLiveEchoMaxTaps;
    static constexpr std::uint32_t kRing = 2048;           // fd samples per drive channel
    static constexpr std::uint32_t kHistory = 9;           // interpolator phases
    static constexpr std::uint32_t kSearchHalfWidthMs = 10;
    static constexpr double kSearchSeconds = 5.0;
    static constexpr double kLockPeak = 0.7;
    static constexpr double kProgrammeFloor = 1e-5;        // -50 dBFS mean square
    static constexpr double kDivergeWindowSeconds = 0.25;   // the four parts together

    enum class Fault { None, AlignmentLost, Diverged };

    LiveEcho(double sampleRate, std::uint32_t factor, std::uint32_t half, std::uint32_t maxBlock,
             const std::vector<float> &decimatorReversed, const std::vector<float> &polyphase);

    // Control thread.
    bool setModel(const N60FeedForwardLiveEcho *echo) noexcept;
    bool setTiming(std::uint32_t baseLagFrames) noexcept;

    // Audio thread.
    void beginCallback(std::uint32_t frames) noexcept { callbackFrames_ = frames; }
    void applyPending(bool idle) noexcept;
    Fault pushDrive(const float *left, const float *right, std::uint32_t frames) noexcept;
    void noteGaps(std::uint32_t zeroFrames, std::uint32_t skippedFrames) noexcept;
    Fault clean(const float *reference, float *cleaned, std::uint32_t frames) noexcept;
    bool locked() const noexcept { return state_.load(std::memory_order_relaxed) == N60FeedForwardLiveEchoLocked; }
    bool enabled() const noexcept { return active_; }
    void dropLock() noexcept;
    void reset() noexcept;
    N60FeedForwardLiveEchoStatus status() const noexcept;

private:
    struct Model {
        std::array<std::vector<float>, 2> taps;   // reversed, left-aligned in [0, count)
        std::array<std::uint32_t, 2> count{0, 0};
        std::array<std::uint32_t, 2> bulk{0, 0};
        bool valid = false;
    };

    // Native-rate history plus the decimator: one fd sample every factor_ frames of the global index.
    struct Lane {
        std::vector<float> buffer;
        std::uint32_t last = 0;
    };

    template <class Sink>
    void decimate(Lane &lane, const float *in, std::uint32_t frames, std::uint64_t first, Sink &&sink) noexcept;
    static float dot(const float *a, const float *b, std::uint32_t count) noexcept;
    float windowDot(const std::vector<float> &taps, const float *ring, std::int64_t end,
                    std::uint32_t count) const noexcept;
    void storeDrive(std::uint32_t channel, std::int64_t m, float value) noexcept;
    void resetDriveLine(std::uint64_t driveStart) noexcept;
    void restartSearch() noexcept;
    void computeModelPrediction() noexcept;
    void evaluateSearch() noexcept;
    float refinedLag(const std::vector<double> &corr, std::uint32_t peak) const noexcept;
    void configureLock(std::uint32_t lagNative) noexcept;
    void clearMeters() noexcept;

    struct Biquad {
        double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
        void design(bool highPass, double fc, double fs) noexcept;
        double run(double x) noexcept {
            const double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
        void clear() noexcept { z1 = z2 = 0; }
    };
    struct Band {
        Biquad high, low;
        double run(double x) noexcept { return low.run(high.run(x)); }
        void clear() noexcept { high.clear(); low.clear(); }
    };

    // Fixed after construction.
    double sampleRate_;
    std::uint32_t factor_, half_, chain_, kernelLength_, maxBlock_;
    std::uint32_t searchHalf_;       // fd samples either side of the base lag
    std::uint32_t maxFd_;            // fd samples a block can hold, plus slack
    const std::vector<float> &decimatorReversed_;
    const std::vector<float> &polyphase_;

    // Control plane.
    TripleBuffer<Model> modelBox_;
    std::atomic<std::uint32_t> modelGeneration_{0};
    std::atomic<std::uint32_t> timingGeneration_{0};
    std::atomic<std::uint32_t> timingFrames_{0};
    std::atomic<std::uint32_t> timingValid_{0};

    // Audio thread.
    Model model_;
    bool active_ = false;
    std::uint32_t appliedModel_ = 0, appliedTiming_ = 0;
    std::uint32_t baseLag_ = 0;
    std::uint32_t callbackFrames_ = 0;   // latest Process call: the next drive push has this many frames
    bool gapPending_ = false, zeroSkip_ = false;
    std::uint64_t refFrame_ = 0;
    std::uint64_t ddNext_ = 0, pmNext_ = 0;
    bool loud_ = false;
    std::array<Lane, 2> driveLanes_;
    Lane rawLane_, cleanLane_;
    std::array<std::vector<float>, 2> ddRing_;   // 2 * kRing, mirrored
    std::vector<float> pmRing_;                  // kRing
    std::vector<float> rawFd_, cleanFd_;
    std::vector<std::uint64_t> fdIndex_;
    std::uint32_t fdCount_ = 0;

    // Search.
    std::uint32_t lo_ = 0, width_ = 0, searchBlock_ = 0;
    bool edgeTruncated_ = false;
    std::vector<double> corr_;
    double energyRef_ = 0, energyPm_ = 0, searchSeconds_ = 0, nextCheck_ = 0;
    // Lock.
    std::uint32_t lagNative_ = 0, remainder_ = 0;
    std::array<std::int64_t, 2> q_{0, 0};
    std::array<float, kHistory> predicted_{};
    std::vector<float> delayLine_;               // 128 native samples of the interpolated prediction
    std::uint64_t phaseFrame_ = 0;
    std::array<Band, 2> bands_;                  // raw, cleaned
    double meterBefore_ = 0, meterAfter_ = 0, meterSeconds_ = 0, meterCount_ = 0;
    // Divergence: four 62.5 ms sub-windows slide, so a fault is seen within about 190 ms.
    static constexpr std::uint32_t kDivergeParts = 4;
    std::array<double, kDivergeParts> partBefore_{}, partAfter_{};
    std::uint32_t partIndex_ = 0, partsFilled_ = 0;
    double partSeconds_ = 0;

    // Published.
    std::atomic<std::uint32_t> state_{N60FeedForwardLiveEchoOff};
    std::atomic<std::uint32_t> publishedLag_{0};
    std::atomic<std::uint32_t> publishedBase_{0};
    std::atomic<std::uint32_t> discontinuities_{0};
    std::atomic<float> peak_{0};
    std::atomic<float> drivePower_{0};
    std::atomic<double> seconds_{0};
    std::atomic<double> before_{0}, after_{0};
    std::atomic<std::uint64_t> restarts_{0};
};

}  // namespace n60::anc
