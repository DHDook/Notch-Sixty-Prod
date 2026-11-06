// E26 S7b: host feed for the anti-noise lanes. See N60AncLaneFeed.h for the contract.

#include "N60AncLaneFeed.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>

#if __cplusplus < 202002L
#error "n60_anc_lane_feed.cpp requires C++20"
#endif

namespace {

constexpr double kDefaultFadeInSeconds = 3.0;
constexpr double kFadeOutSeconds = 0.020;
constexpr double kTelemetrySpacingSeconds = N60_ACTIVE_QUIET_ZONE_TELEMETRY_MIN_SPACING_SECONDS;
constexpr uint32_t kRingMask = N60AncLaneFeedReferenceRingFrames - 1u;
static_assert((N60AncLaneFeedReferenceRingFrames & kRingMask) == 0u, "ring size is a power of two");

// Triple buffer for the tonal snapshot: one writer (control), one reader (audio). Index bits 0-1 are the
// middle slot, bit 2 marks it as fresh.
struct SnapshotBuffer {
    N60ActiveQuietZoneSnapshot slots[3];
    std::atomic<uint32_t> middle{1u};
    uint32_t writeSlot{0u};
    uint32_t readSlot{2u};
};

}  // namespace

struct N60AncLaneFeed {
    N60AncLaneFeedConfig config{};
    uint32_t chunkFrames{0};

    // Tonal canceller.
    N60ActiveQuietZoneRuntime tonal{};
    SnapshotBuffer snapshots;
    bool haveSnapshot{false};
    bool rescheduleKept{false};   // after Reset: prepare the tonal runtime from the kept snapshot again
    N60ActiveQuietZoneGainMailbox *mailbox{nullptr};
    N60ActiveQuietZoneTelemetry *telemetry{nullptr};
    std::atomic<uint64_t> hostTime{0};
    uint64_t telemetryLastFrame{0};
    bool telemetryHasLast{false};

    // Feed-forward.
    N60FeedForwardLive *ff{nullptr};
    std::unique_ptr<float[]> ring;
    std::atomic<uint64_t> refRead{0}, refWrite{0};
    std::atomic<uint64_t> zeroFrom{0}, zeroTo{0};
    std::atomic<uint32_t> zeroSeq{0};
    uint32_t underrunRun{0};
    std::atomic<uint64_t> underruns{0};
    // Scratch, each maxBlockFrames: reference, ff left, ff right, drive left, drive right.
    std::unique_ptr<float[]> scratch;
    uint32_t previousChunk{0};

    // Splitter and gain.
    N60SpeakerBusSplitterRuntime splitter{};
    std::atomic<bool> armed{false};
    std::atomic<uint64_t> leaseDeadline{0};
    std::atomic<uint64_t> leaseExpiries{0};
    bool leaseWasActive{false};
    double gain{0.0};
    std::atomic<float> gainShadow{0.0f};
    std::atomic<uint64_t> rendered{0};
    std::atomic<uint64_t> clamped{0};
    std::atomic<uint64_t> faults{0};

    float *refLane() { return scratch.get(); }
    float *ffLeft() { return scratch.get() + chunkFrames; }
    float *ffRight() { return scratch.get() + 2u * chunkFrames; }
    float *driveLeft() { return scratch.get() + 3u * chunkFrames; }
    float *driveRight() { return scratch.get() + 4u * chunkFrames; }
};

namespace {

bool laneIndexesValid(const N60AncLaneFeedConfig &c) {
    const uint32_t lanes[5] = {c.programmeLeft, c.programmeRight, c.sourceLeft, c.sourceRight, c.sourceSub};
    for (uint32_t i = 0; i < 5; ++i) {
        if (lanes[i] >= c.channels) return false;
        for (uint32_t j = i + 1; j < 5; ++j) {
            if (lanes[i] == lanes[j]) return false;
        }
    }
    return true;
}

void resetFeedForwardState(N60AncLaneFeed &f) {
    if (f.ff != nullptr) N60FeedForwardLiveReset(f.ff);
    f.refRead.store(0, std::memory_order_release);
    f.refWrite.store(0, std::memory_order_release);
    f.zeroFrom.store(0, std::memory_order_relaxed);
    f.zeroTo.store(0, std::memory_order_relaxed);
    f.zeroSeq.store(0, std::memory_order_relaxed);
    f.underrunRun = 0;
    f.previousChunk = 0;
}

// Takes the reference for the next `n` output frames and runs the filter over the block (the kernel's
// N60RenderKernelPrepareFeedForward). A block the pump did not supply is zeros; two in a row while armed count
// as the reference being lost.
void prepareFeedForward(N60AncLaneFeed &f, uint32_t n) {
    if (f.ff == nullptr) return;
    // The previous chunk's pre-split drive (programme plus anti-noise) is the echo stage's drive signal.
    if (f.previousChunk > 0) {
        N60FeedForwardLivePushDrive(f.ff, f.driveLeft(), f.driveRight(), f.previousChunk);
    }
    float *ref = f.refLane();
    const uint64_t rd = f.refRead.load(std::memory_order_relaxed);
    const uint64_t wr = f.refWrite.load(std::memory_order_acquire);
    uint32_t zeroFrames = 0;
    if (wr >= rd + n) {
        for (uint32_t i = 0; i < n; ++i) ref[i] = f.ring[(rd + i) & kRingMask];
        f.underrunRun = 0;
        uint64_t zf = 0, zt = 0;
        bool stable = false;
        for (int attempt = 0; attempt < 3 && !stable; ++attempt) {
            const uint32_t s0 = f.zeroSeq.load(std::memory_order_acquire);
            zf = f.zeroFrom.load(std::memory_order_acquire);
            zt = f.zeroTo.load(std::memory_order_acquire);
            stable = (s0 & 1u) == 0u && s0 == f.zeroSeq.load(std::memory_order_acquire);
        }
        if (!stable) {
            zeroFrames = n;
        } else if (zt > zf && zt > rd && zf < rd + n) {
            const uint64_t a = std::max(zf, rd), b = std::min(zt, rd + n);
            zeroFrames = static_cast<uint32_t>(b - a);
        }
    } else {
        zeroFrames = n;
        std::memset(ref, 0, static_cast<size_t>(n) * sizeof(float));
        f.underruns.fetch_add(1, std::memory_order_relaxed);
        if (++f.underrunRun >= 2u && N60FeedForwardLiveGetStatus(f.ff).state == N60FeedForwardLiveArmed) {
            N60FeedForwardLiveMarkReferenceLost(f.ff);
        }
    }
    f.refRead.store(rd + n, std::memory_order_release);
    N60FeedForwardLiveNoteReferenceGaps(f.ff, zeroFrames, 0);
    N60FeedForwardLiveProcess(f.ff, ref, f.ffLeft(), f.ffRight(), n);
}

void applyTonalSnapshot(N60AncLaneFeed &f) {
    SnapshotBuffer &b = f.snapshots;
    const bool fresh = (b.middle.load(std::memory_order_relaxed) & 4u) != 0u;
    if (fresh || (f.rescheduleKept && f.haveSnapshot)) {
        if (fresh) {
            const uint32_t taken = b.middle.exchange(b.readSlot, std::memory_order_acq_rel);
            b.readSlot = taken & 3u;
        }
        f.haveSnapshot = true;
        f.rescheduleKept = false;
        if (!N60ActiveQuietZoneRuntimeSchedule(&f.tonal, &b.slots[b.readSlot], f.config.sampleRate)) {
            // A live frequency change beyond the glide limit fails closed, as in the kernel.
            N60ActiveQuietZoneRuntimeReset(&f.tonal, f.config.sampleRate);
        }
    }
    if (f.haveSnapshot) {
        N60ActiveQuietZoneRuntimeApplyMailbox(&f.tonal, f.mailbox, &b.slots[b.readSlot], f.config.sampleRate);
    }
}

void captureTelemetry(N60AncLaneFeed &f, uint64_t now) {
    const uint64_t host = f.hostTime.load(std::memory_order_relaxed);
    if (host == 0u || !f.haveSnapshot || !f.snapshots.slots[f.snapshots.readSlot].enabled) return;
    const uint64_t spacing = static_cast<uint64_t>(f.config.sampleRate * kTelemetrySpacingSeconds);
    if (f.telemetryHasLast && now >= f.telemetryLastFrame && now - f.telemetryLastFrame < spacing) return;
    N60ActiveQuietZoneTelemetryRecord record;
    if (N60ActiveQuietZoneRuntimeCaptureTelemetry(&f.tonal, host, now, &record)) {
        N60ActiveQuietZoneTelemetryPush(f.telemetry, &record);
        f.telemetryLastFrame = now;
        f.telemetryHasLast = true;
    }
}

// The target gain for this chunk. Counts an expiry on the active-to-expired change.
float chunkTargetGain(N60AncLaneFeed &f, uint64_t now) {
    const uint64_t deadline = f.leaseDeadline.load(std::memory_order_acquire);
    const bool active = deadline != 0u && now < deadline;
    if (f.leaseWasActive && !active) f.leaseExpiries.fetch_add(1, std::memory_order_relaxed);
    f.leaseWasActive = active;
    return (f.armed.load(std::memory_order_acquire) && active) ? 1.0f : 0.0f;
}

void renderChunk(N60AncLaneFeed &f, const float *const *in, float *const *out, uint32_t offset, uint32_t n) {
    const N60AncLaneFeedConfig &c = f.config;
    const uint64_t now = f.rendered.load(std::memory_order_relaxed);
    applyTonalSnapshot(f);
    captureTelemetry(f, now);
    (void)chunkTargetGain(f, now);  // counts lease expiries; the gain target is evaluated per frame below
    prepareFeedForward(f, n);

    const double upStep = 1.0 / (c.fadeInSeconds * c.sampleRate);
    const double downStep = 1.0 / (kFadeOutSeconds * c.sampleRate);
    const bool armedNow = f.armed.load(std::memory_order_acquire);
    const uint64_t deadline = f.leaseDeadline.load(std::memory_order_acquire);
    const float limit = c.peakLimit;
    const float *progL = in[c.programmeLeft] + offset;
    const float *progR = in[c.programmeRight] + offset;
    float *srcL = out[c.sourceLeft] + offset;
    float *srcR = out[c.sourceRight] + offset;
    float *srcS = out[c.sourceSub] + offset;
    const bool haveFF = f.ff != nullptr;
    uint64_t clamps = 0;

    for (uint32_t i = 0; i < n; ++i) {
        const float pl = std::isfinite(progL[i]) ? progL[i] : 0.0f;
        const float pr = std::isfinite(progR[i]) ? progR[i] : 0.0f;
        N60ActiveQuietZoneRuntimeAccumulateProgramme(&f.tonal, pl, pr);
        float tl = 0.0f, tr = 0.0f;
        N60ActiveQuietZoneRuntimeProcessFrame(&f.tonal, &tl, &tr);
        float al = tl, ar = tr;
        if (haveFF) {
            al += f.ffLeft()[i];
            ar += f.ffRight()[i];
        }
        // The lease is checked per frame, so the fade-out starts at the expiry frame, not at the next chunk.
        const double tgt = (armedNow && deadline != 0u && now + i < deadline) ? 1.0 : 0.0;
        if (tgt > f.gain) f.gain = std::min(tgt, f.gain + upStep);
        else if (tgt < f.gain) f.gain = std::max(tgt, f.gain - downStep);
        const float g = static_cast<float>(f.gain);
        al *= g;
        ar *= g;
        if (!std::isfinite(al)) al = 0.0f;
        if (!std::isfinite(ar)) ar = 0.0f;
        const float cl = std::clamp(al, -limit, limit);
        const float cr = std::clamp(ar, -limit, limit);
        if (cl != al || cr != ar) ++clamps;
        // The drive for the echo stage is what the speakers get: programme plus anti-noise, before the split.
        f.driveLeft()[i] = pl + cl;
        f.driveRight()[i] = pr + cr;

        float buses[N60_SPLITTER_BUS_COUNT];
        N60SpeakerBusSplitterProcess(&f.splitter, cl, cr, buses);
        float laneL = buses[N60_SPLITTER_BUS_LEFT_LOW] + buses[N60_SPLITTER_BUS_LEFT_MID]
            + buses[N60_SPLITTER_BUS_LEFT_HIGH];
        float laneR = buses[N60_SPLITTER_BUS_RIGHT_LOW] + buses[N60_SPLITTER_BUS_RIGHT_MID]
            + buses[N60_SPLITTER_BUS_RIGHT_HIGH];
        float laneS = buses[N60_SPLITTER_BUS_SUB_MONO];
        // Exactly zero while the gain is zero (the splitter tail would otherwise leave a decaying residue).
        if (f.gain == 0.0 && tgt == 0.0) laneL = laneR = laneS = 0.0f;
        srcL[i] = std::clamp(laneL, -limit, limit);
        srcR[i] = std::clamp(laneR, -limit, limit);
        srcS[i] = std::clamp(laneS, -limit, limit);
    }
    f.previousChunk = haveFF ? n : 0u;
    if (clamps != 0u) f.clamped.fetch_add(clamps, std::memory_order_relaxed);
    f.gainShadow.store(static_cast<float>(f.gain), std::memory_order_relaxed);
    f.rendered.store(now + n, std::memory_order_release);
}

}  // namespace

extern "C" {

bool N60AncLaneFeedConfigIsValid(const N60AncLaneFeedConfig *config) {
    if (config == nullptr) return false;
    const N60AncLaneFeedConfig &c = *config;
    if (!(c.sampleRate >= 8000.0 && c.sampleRate <= 768000.0)) return false;
    if (c.maxBlockFrames < 16u || c.maxBlockFrames > N60AncLaneFeedMaxBlockFrames) return false;
    if (c.channels < 5u || c.channels > N60AncLaneFeedMaxChannels || !laneIndexesValid(c)) return false;
    if (!c.splitter.enabled || c.splitter.mode != N60SpeakerCrossoverModeMainsSub
        || c.splitter.lowerSectionCount == 0u || c.splitter.lowerSectionCount > N60_MAX_CROSSOVER_SECTIONS) {
        return false;
    }
    if (!(c.peakLimit >= 0.0f && c.peakLimit <= 1.0f)) return false;
    if (c.fadeInSeconds != 0.0 && !(c.fadeInSeconds >= 0.01 && c.fadeInSeconds <= 30.0)) return false;
    return true;
}

N60AncLaneFeed *N60AncLaneFeedCreate(const N60AncLaneFeedConfig *config) {
    if (!N60AncLaneFeedConfigIsValid(config)) return nullptr;
    std::unique_ptr<N60AncLaneFeed> f(new (std::nothrow) N60AncLaneFeed());
    if (!f) return nullptr;
    f->config = *config;
    if (f->config.peakLimit == 0.0f) f->config.peakLimit = 1.0f;
    if (f->config.fadeInSeconds == 0.0) f->config.fadeInSeconds = kDefaultFadeInSeconds;
    f->chunkFrames = f->config.maxBlockFrames;
    f->scratch.reset(new (std::nothrow) float[5u * static_cast<size_t>(f->chunkFrames)]());
    f->mailbox = N60ActiveQuietZoneGainMailboxCreate();
    f->telemetry = N60ActiveQuietZoneTelemetryCreate();
    if (!f->scratch || f->mailbox == nullptr || f->telemetry == nullptr) {
        N60ActiveQuietZoneGainMailboxDestroy(f->mailbox);
        N60ActiveQuietZoneTelemetryDestroy(f->telemetry);
        return nullptr;
    }
    if (f->config.feedForward) {
        N60FeedForwardLiveConfig ffc = {};
        ffc.sampleRate = f->config.sampleRate;
        ffc.maxBlockFrames = f->chunkFrames;
        ffc.peakLimit = f->config.peakLimit;
        ffc.armRampSeconds = 0.01;  // the feed's gain carries the 3 s fade-in
        f->ring.reset(new (std::nothrow) float[N60AncLaneFeedReferenceRingFrames]());
        if (f->ring && N60FeedForwardLiveConfigIsValid(&ffc)) f->ff = N60FeedForwardLiveCreate(&ffc);
        if (f->ff == nullptr) {
            N60ActiveQuietZoneGainMailboxDestroy(f->mailbox);
            N60ActiveQuietZoneTelemetryDestroy(f->telemetry);
            return nullptr;
        }
    }
    f->snapshots.slots[0] = f->snapshots.slots[1] = f->snapshots.slots[2] = N60ActiveQuietZoneSnapshotMakeBypassed();
    f->splitter.snapshot = f->config.splitter;
    N60ActiveQuietZoneRuntimeReset(&f->tonal, f->config.sampleRate);
    return f.release();
}

void N60AncLaneFeedDestroy(N60AncLaneFeed *feed) {
    if (feed == nullptr) return;
    N60FeedForwardLiveDestroy(feed->ff);
    N60ActiveQuietZoneGainMailboxDestroy(feed->mailbox);
    N60ActiveQuietZoneTelemetryDestroy(feed->telemetry);
    delete feed;
}

int N60AncLaneFeedProcess(void *context, const float *const *in, float *const *out, uint32_t channels,
                          uint32_t frames) {
    auto *f = static_cast<N60AncLaneFeed *>(context);
    if (f == nullptr || in == nullptr || out == nullptr) return 0;
    if (channels != f->config.channels) {
        f->faults.fetch_add(1, std::memory_order_relaxed);
        return 0;
    }
    for (uint32_t ch = 0; ch < channels; ++ch) {
        if (in[ch] == nullptr || out[ch] == nullptr) {
            f->faults.fetch_add(1, std::memory_order_relaxed);
            return 0;
        }
    }
    for (uint32_t offset = 0; offset < frames; offset += f->chunkFrames) {
        renderChunk(*f, in, out, offset, std::min(f->chunkFrames, frames - offset));
    }
    return 1;
}

bool N60AncLaneFeedSetTonalSnapshot(N60AncLaneFeed *feed, const N60ActiveQuietZoneSnapshot *snapshot) {
    if (feed == nullptr || snapshot == nullptr) return false;
    SnapshotBuffer &b = feed->snapshots;
    b.slots[b.writeSlot] = *snapshot;
    const uint32_t taken = b.middle.exchange(b.writeSlot | 4u, std::memory_order_acq_rel);
    b.writeSlot = taken & 3u;
    return true;
}

N60ActiveQuietZoneGainMailbox *N60AncLaneFeedMailbox(N60AncLaneFeed *feed) { return feed->mailbox; }
N60ActiveQuietZoneTelemetry *N60AncLaneFeedTelemetry(N60AncLaneFeed *feed) { return feed->telemetry; }

void N60AncLaneFeedSetHostTime(N60AncLaneFeed *feed, uint64_t hostTime) {
    feed->hostTime.store(hostTime, std::memory_order_relaxed);
}

void N60AncLaneFeedArm(N60AncLaneFeed *feed) { feed->armed.store(true, std::memory_order_release); }

void N60AncLaneFeedDisarm(N60AncLaneFeed *feed) {
    feed->armed.store(false, std::memory_order_release);
    if (feed->ff != nullptr) N60FeedForwardLiveDisarm(feed->ff);
}

void N60AncLaneFeedRenewLease(N60AncLaneFeed *feed, uint64_t durationFrames) {
    if (durationFrames == 0u) return;
    const uint64_t now = feed->rendered.load(std::memory_order_acquire);
    uint64_t deadline = now + durationFrames;
    if (deadline < now) deadline = UINT64_MAX;
    feed->leaseDeadline.store(deadline, std::memory_order_release);
}

void N60AncLaneFeedReleaseLease(N60AncLaneFeed *feed) { feed->leaseDeadline.store(0, std::memory_order_release); }

bool N60AncLaneFeedSetFeedForwardWeights(N60AncLaneFeed *feed, const float *left, const float *right,
                                         uint32_t count) {
    return feed->ff != nullptr && N60FeedForwardLiveSetWeights(feed->ff, left, right, count);
}

uint32_t N60AncLaneFeedFeedForwardArm(N60AncLaneFeed *feed, double leadSeconds, double requiredSeconds) {
    if (feed->ff == nullptr) return N60FeedForwardLiveArmNoWeights;
    return N60FeedForwardLiveArm(feed->ff, leadSeconds, requiredSeconds);
}

void N60AncLaneFeedFeedForwardDisarm(N60AncLaneFeed *feed) {
    if (feed->ff != nullptr) N60FeedForwardLiveDisarm(feed->ff);
}

bool N60AncLaneFeedSetFeedForwardEcho(N60AncLaneFeed *feed, const N60FeedForwardLiveEcho *echo) {
    return feed->ff != nullptr && N60FeedForwardLiveSetEcho(feed->ff, echo);
}

bool N60AncLaneFeedSetFeedForwardEchoTiming(N60AncLaneFeed *feed, uint32_t baseLagFrames) {
    return feed->ff != nullptr && N60FeedForwardLiveSetEchoTiming(feed->ff, baseLagFrames);
}

uint64_t N60AncLaneFeedPushReference(N60AncLaneFeed *feed, uint64_t startIndex, const float *samples,
                                     uint32_t count) {
    N60AncLaneFeed &f = *feed;
    if (f.ff == nullptr || !f.ring || samples == nullptr) return startIndex;
    const uint64_t rd = f.refRead.load(std::memory_order_acquire);
    uint64_t wr = f.refWrite.load(std::memory_order_relaxed);
    uint64_t first = startIndex;
    uint32_t skip = 0;
    if (first < rd) {
        const uint64_t late = rd - first;
        skip = late < count ? static_cast<uint32_t>(late) : count;
        first += skip;
    }
    uint32_t n = count - skip;
    if (first >= rd + N60AncLaneFeedReferenceRingFrames) n = 0;
    else if (first + n > rd + N60AncLaneFeedReferenceRingFrames) {
        n = static_cast<uint32_t>(rd + N60AncLaneFeedReferenceRingFrames - first);
    }
    if (n == 0) return startIndex + count;
    if (wr < rd) wr = rd;
    for (uint64_t g = wr; g < first; ++g) f.ring[g & kRingMask] = 0.0f;
    if (first > wr) {
        // The zero-filled span, so the echo stage skips subtraction over it (merged while unconsumed).
        const uint64_t zf = f.zeroFrom.load(std::memory_order_relaxed);
        const uint64_t zt = f.zeroTo.load(std::memory_order_relaxed);
        const bool pending = zt > zf && zt > rd;
        const uint32_t seq = f.zeroSeq.load(std::memory_order_relaxed);
        f.zeroSeq.store(seq + 1u, std::memory_order_release);
        f.zeroFrom.store(pending && zf < wr ? zf : wr, std::memory_order_release);
        f.zeroTo.store(first, std::memory_order_release);
        f.zeroSeq.store(seq + 2u, std::memory_order_release);
    }
    for (uint32_t i = 0; i < n; ++i) f.ring[(first + i) & kRingMask] = samples[skip + i];
    if (first + n > wr) f.refWrite.store(first + n, std::memory_order_release);
    return startIndex + count;
}

uint64_t N60AncLaneFeedReferenceOutputIndex(const N60AncLaneFeed *feed) {
    return feed->ff == nullptr ? 0u : feed->refRead.load(std::memory_order_acquire);
}

N60FeedForwardLiveStatus N60AncLaneFeedFeedForwardStatus(const N60AncLaneFeed *feed) {
    if (feed->ff == nullptr) return N60FeedForwardLiveStatus{};
    return N60FeedForwardLiveGetStatus(feed->ff);
}

void N60AncLaneFeedReset(N60AncLaneFeed *feed) {
    N60AncLaneFeed &f = *feed;
    f.armed.store(false, std::memory_order_release);
    f.leaseWasActive = false;
    f.gain = 0.0;
    f.gainShadow.store(0.0f, std::memory_order_relaxed);
    f.rendered.store(0, std::memory_order_release);
    // Cleared after `rendered`, so a RenewLease that read the old frame count cannot leave a stale deadline
    // (it would be far beyond the new count); Arm after Reset needs a fresh lease in any case.
    f.leaseDeadline.store(0, std::memory_order_release);
    f.telemetryHasLast = false;
    f.telemetryLastFrame = 0;
    f.splitter = N60SpeakerBusSplitterRuntime{};
    f.splitter.snapshot = f.config.splitter;
    N60ActiveQuietZoneRuntimeReset(&f.tonal, f.config.sampleRate);
    f.rescheduleKept = f.haveSnapshot;
    resetFeedForwardState(f);
    if (f.ff != nullptr) N60FeedForwardLiveDisarm(f.ff);
    std::memset(f.scratch.get(), 0, 5u * static_cast<size_t>(f.chunkFrames) * sizeof(float));
}

N60AncLaneFeedStatus N60AncLaneFeedGetStatus(const N60AncLaneFeed *feed) {
    N60AncLaneFeedStatus s{};
    s.armed = feed->armed.load(std::memory_order_acquire);
    const uint64_t deadline = feed->leaseDeadline.load(std::memory_order_acquire);
    s.renderedFrames = feed->rendered.load(std::memory_order_acquire);
    s.leaseActive = deadline != 0u && s.renderedFrames < deadline;
    s.gain = feed->gainShadow.load(std::memory_order_relaxed);
    s.leaseExpiries = feed->leaseExpiries.load(std::memory_order_relaxed);
    s.referenceUnderruns = feed->underruns.load(std::memory_order_relaxed);
    s.clampedSamples = feed->clamped.load(std::memory_order_relaxed);
    s.faults = feed->faults.load(std::memory_order_relaxed);
    return s;
}

}  // extern "C"
