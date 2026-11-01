#pragma once

// E4 S25a: live broadband feed-forward filter (head FIR at the native rate plus a decimated
// tail). The C interface, the design and the realtime contract are in N60FeedForwardLive.h.

#include "N60FeedForwardLive.h"
#include "n60_fxlms.hpp"

#include <array>
#include <atomic>
#include <cstdint>
#include <vector>

namespace n60::anc {

class FeedForwardLive {
public:
    static constexpr std::uint32_t kChannels = 2;
    static constexpr std::uint32_t kMaxTaps = N60FeedForwardLiveMaxTaps;
    static constexpr std::uint32_t kHistory = 9;   // interpolator phases of fd outputs

    explicit FeedForwardLive(const N60FeedForwardLiveConfig &config);

    bool setWeights(const float *left, const float *right, std::uint32_t count) noexcept;
    std::uint32_t arm(double leadSeconds, double requiredSeconds) noexcept;
    void disarm() noexcept { armRequested_.store(false, std::memory_order_release); }
    void markReferenceLost() noexcept { referenceLost_.store(true, std::memory_order_release); }
    void process(const float *reference, float *left, float *right, std::uint32_t frames) noexcept;
    void reset() noexcept;
    N60FeedForwardLiveStatus status() const noexcept;

private:
    // One weight set, already split. The head is stored reversed for a contiguous dot product,
    // the tail reversed and zero-padded to kMaxTaps.
    struct Set {
        std::array<std::vector<float>, kChannels> head;   // headCapacity_ floats, right-aligned
        std::array<std::vector<float>, kChannels> tail;   // kMaxTaps floats
        std::uint32_t tailTaps = 0;
        bool valid = false;
    };

    void makeSet(Set &set, const float *left, const float *right, std::uint32_t count) const;
    void copySet(Set &to, const Set &from) const noexcept;
    void processChunk(const float *reference, float *left, float *right,
                      std::uint32_t frames) noexcept;
    static float dot(const float *a, const float *b, std::uint32_t count) noexcept;
    void restartState() noexcept;

    // Fixed after construction.
    std::uint32_t factor_;
    std::uint32_t half_;
    std::uint32_t offset_;           // T0, fd samples
    std::uint32_t kernelLength_;     // 2 half D + 1
    std::uint32_t headLength_;       // (2 T0 - 1) D + 1
    std::uint32_t headCapacity_;     // padded to a multiple of 8
    std::uint32_t maxBlock_;
    std::uint32_t fadeFrames_;
    std::uint32_t rampUp_;
    std::uint32_t rampDown_;
    float peakLimit_;
    std::vector<double> decimator_;      // unity DC gain
    std::vector<double> interpolator_;   // DC gain D
    std::vector<double> chain_;          // decimator * interpolator
    std::vector<float> decimatorReversed_;
    std::vector<float> polyphase_;       // [D][kHistory]

    // Control plane.
    TripleBuffer<Set> mailbox_;
    std::atomic<bool> armRequested_{false};
    std::atomic<bool> referenceLost_{false};
    std::atomic<bool> hasWeights_{false};
    std::atomic<std::uint32_t> publishedTail_{0};

    // Audio thread state.
    Set active_, previous_;
    bool haveActive_ = false;
    std::uint32_t fadeLeft_ = 0;
    std::vector<float> history_;
    std::uint32_t lastFrames_ = 0;
    std::uint32_t historyKept_;          // headCapacity_ - 1 samples preserved between chunks
    std::vector<float> decimated_;       // mirrored ring, 2 * kMaxTaps
    std::uint32_t decimatedPosition_ = 0;
    std::uint32_t phase_ = 0;
    std::uint32_t sinceOutput_ = 0;
    std::array<std::array<float, kHistory>, kChannels> outputs_{};
    float gain_ = 0;
    std::atomic<std::uint32_t> state_{N60FeedForwardLiveIdle};
    std::atomic<std::uint32_t> tripReason_{N60FeedForwardLiveTripNone};
    std::atomic<std::uint64_t> setsApplied_{0};
    std::atomic<std::uint64_t> clamped_{0};
    std::atomic<float> peak_{0};
    std::atomic<float> gainPublished_{0};
};

}  // namespace n60::anc
