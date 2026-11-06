// E26 S7b1 (G1): the host feed for the anti-noise lanes (N60AncLaneFeed), at the eight standard rates.
//  1. Lanes: with a steady tonal snapshot, the left, right and sub lanes equal an independent offline render of the
//     same anti-noise through the shared production splitter (N60SpeakerBusSplitterProcess) within 1e-6.
//     Limit: N60SpeakerBusRenderFeed itself links CoreAudio and cannot be built here; it calls the same function.
//  2. Safety: exactly zero while disarmed, while armed without a lease, with an expired lease and after Disarm.
//  3. Lease expiry and Disarm silence the lanes within 20 ms (plus one block).
//  4. The default fade-in is a 3 s linear ramp.
//  5. Reset clears the arm, the lease and the history, and keeps the snapshot.
//  6. Programme and spare channels pass through untouched; a wrong channel count is refused and counted.
//  7. The live feed-forward path plays only while armed with a lease, and consumes the reference ring.
//  8. The realtime call allocates nothing.
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "N60AncLaneFeed.h"

static std::atomic<bool> armedCount{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armedCount.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
static void countedFree(void *p) {
    if (p != nullptr && armedCount.load()) allocs.fetch_add(1);
    std::free(p);
}
void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void *operator new(std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void *operator new[](std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void operator delete(void *p) noexcept { countedFree(p); }
void operator delete[](void *p) noexcept { countedFree(p); }
void operator delete(void *p, std::size_t) noexcept { countedFree(p); }
void operator delete[](void *p, std::size_t) noexcept { countedFree(p); }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const uint32_t kBlock = 480;
static const uint32_t kChannels = 6;  // 0 programme L, 1 programme R, 2 source L, 3 source R, 4 source sub, 5 spare

struct Rig {
    N60AncLaneFeed *feed = nullptr;
    double rate = 0.0;
    N60ActiveQuietZoneSnapshot tonal;
    N60SpeakerBusSplitterSnapshot splitter;
    std::vector<float> lanes[kChannels];
    std::vector<float> inLanes[kChannels];
    const float *inPtr[kChannels];
    float *outPtr[kChannels];
};

static bool makeSnapshots(Rig &r, bool withTone) {
    if (!N60SpeakerBusSplitterSnapshotMake(r.rate, N60SpeakerCrossoverModeMainsSub, 80.0,
                                           N60CrossoverTopologyLinkwitzRiley24, 2000.0,
                                           N60CrossoverTopologyLinkwitzRiley24, 1.0f, false, false, 80.0, 0.707,
                                           &r.splitter)) {
        return false;
    }
    r.tonal = N60ActiveQuietZoneSnapshotMakeBypassed();
    if (withTone) {
        N60ActiveQuietZoneToneSnapshot t[1] = {};
        t[0].frequencyHz = 60.0;
        t[0].leftReal = 0.05f;
        t[0].rightReal = 0.05f;
        if (!N60ActiveQuietZoneSnapshotSet(&r.tonal, t, 1u, 64u, r.rate, true)) return false;
        r.tonal.armGeneration = 1;
    }
    return true;
}

static bool rigInit(Rig &r, double rate, bool withTone, bool feedForward, double fadeIn) {
    r.rate = rate;
    if (!makeSnapshots(r, withTone)) return false;
    N60AncLaneFeedConfig c = {};
    c.sampleRate = rate;
    c.maxBlockFrames = 4096;
    c.channels = kChannels;
    c.programmeLeft = 0;
    c.programmeRight = 1;
    c.sourceLeft = 2;
    c.sourceRight = 3;
    c.sourceSub = 4;
    c.splitter = r.splitter;
    c.peakLimit = 1.0f;
    c.fadeInSeconds = fadeIn;
    c.feedForward = feedForward;
    r.feed = N60AncLaneFeedCreate(&c);
    if (r.feed == nullptr) return false;
    for (uint32_t ch = 0; ch < kChannels; ++ch) {
        r.lanes[ch].assign(kBlock, 0.0f);
        r.inLanes[ch].assign(kBlock, 0.0f);
        r.inPtr[ch] = r.inLanes[ch].data();
        r.outPtr[ch] = r.lanes[ch].data();
    }
    if (withTone) N60AncLaneFeedSetTonalSnapshot(r.feed, &r.tonal);
    return true;
}

static int block(Rig &r) {
    return N60AncLaneFeedProcess(r.feed, r.inPtr, r.outPtr, kChannels, kBlock);
}

static double peakOf(const std::vector<float> &v) {
    double p = 0.0;
    for (float x : v) p = std::fmax(p, std::fabs(x));
    return p;
}
static double sourcePeak(const Rig &r) {
    return std::fmax(peakOf(r.lanes[2]), std::fmax(peakOf(r.lanes[3]), peakOf(r.lanes[4])));
}
static bool sourcesExactlyZero(const Rig &r) {
    for (uint32_t ch = 2; ch <= 4; ++ch) {
        for (float x : r.lanes[ch]) if (x != 0.0f) return false;
    }
    return true;
}
static void runFrames(Rig &r, uint64_t frames) {
    for (uint64_t done = 0; done < frames; done += kBlock) block(r);
}

int main() {
    for (double rate : kRates) {
        const uint64_t leaseLong = static_cast<uint64_t>(rate * 600.0);

        // Config validation.
        {
            N60AncLaneFeedConfig bad = {};
            CHECK(!N60AncLaneFeedConfigIsValid(&bad), "empty config accepted");
            CHECK(!N60AncLaneFeedConfigIsValid(nullptr), "null config accepted");
        }

        // 2. Zero until armed, with a lease, and when the lease is gone.
        {
            Rig r;
            CHECK(rigInit(r, rate, true, false, 0.05), "rig at %.0f", rate);
            for (int i = 0; i < 40; ++i) { block(r); CHECK(sourcesExactlyZero(r), "output while disarmed at %.0f", rate); }
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            for (int i = 0; i < 10; ++i) { block(r); CHECK(sourcesExactlyZero(r), "output with lease but disarmed at %.0f", rate); }
            N60AncLaneFeedReleaseLease(r.feed);
            N60AncLaneFeedArm(r.feed);
            for (int i = 0; i < 10; ++i) { block(r); CHECK(sourcesExactlyZero(r), "output armed without lease at %.0f", rate); }
            N60AncLaneFeedRenewLease(r.feed, 1);  // expires after one frame
            runFrames(r, 4 * kBlock);
            CHECK(sourcesExactlyZero(r), "output with an expired lease at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }

        // 1. Lanes equal the offline render through the shared splitter.
        {
            Rig r;
            CHECK(rigInit(r, rate, true, false, 0.05), "rig at %.0f", rate);
            N60ActiveQuietZoneRuntime ref;
            N60ActiveQuietZoneRuntimeReset(&ref, rate);
            CHECK(N60ActiveQuietZoneRuntimeSchedule(&ref, &r.tonal, rate), "offline schedule at %.0f", rate);
            N60SpeakerBusSplitterRuntime split = {};
            split.snapshot = r.splitter;
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            const double upStep = 1.0 / (0.05 * rate);
            double gain = 0.0;
            double maxErr = 0.0, peak = 0.0;
            const uint64_t total = static_cast<uint64_t>(rate * 0.25);
            for (uint64_t done = 0; done < total; done += kBlock) {
                block(r);
                for (uint32_t i = 0; i < kBlock; ++i) {
                    N60ActiveQuietZoneRuntimeAccumulateProgramme(&ref, 0.0f, 0.0f);
                    float tl = 0.0f, tr = 0.0f;
                    N60ActiveQuietZoneRuntimeProcessFrame(&ref, &tl, &tr);
                    gain = std::fmin(1.0, gain + upStep);
                    const float g = static_cast<float>(gain);
                    const float cl = std::fmax(-1.0f, std::fmin(1.0f, tl * g));
                    const float cr = std::fmax(-1.0f, std::fmin(1.0f, tr * g));
                    float b[N60_SPLITTER_BUS_COUNT];
                    N60SpeakerBusSplitterProcess(&split, cl, cr, b);
                    const float eL = b[N60_SPLITTER_BUS_LEFT_LOW] + b[N60_SPLITTER_BUS_LEFT_MID] + b[N60_SPLITTER_BUS_LEFT_HIGH];
                    const float eR = b[N60_SPLITTER_BUS_RIGHT_LOW] + b[N60_SPLITTER_BUS_RIGHT_MID] + b[N60_SPLITTER_BUS_RIGHT_HIGH];
                    const float eS = b[N60_SPLITTER_BUS_SUB_MONO];
                    maxErr = std::fmax(maxErr, std::fabs(eL - r.lanes[2][i]));
                    maxErr = std::fmax(maxErr, std::fabs(eR - r.lanes[3][i]));
                    maxErr = std::fmax(maxErr, std::fabs(eS - r.lanes[4][i]));
                }
                peak = std::fmax(peak, sourcePeak(r));
            }
            CHECK(peak > 0.001, "lanes silent with a tone at %.0f (peak %g)", rate, peak);
            CHECK(maxErr < 1e-6, "lanes differ from the offline render by %g at %.0f", maxErr, rate);
            const N60AncLaneFeedStatus st = N60AncLaneFeedGetStatus(r.feed);
            CHECK(st.armed && st.leaseActive && st.gain > 0.99f, "status armed %d lease %d gain %g at %.0f",
                  st.armed, st.leaseActive, st.gain, rate);
            CHECK(st.renderedFrames == ((total + kBlock - 1) / kBlock) * kBlock, "rendered frames at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }

        // 3. Lease expiry and Disarm silence the lanes within 20 ms (plus one block).
        for (int mode = 0; mode < 2; ++mode) {
            Rig r;
            CHECK(rigInit(r, rate, true, false, 0.05), "rig at %.0f", rate);
            N60AncLaneFeedArm(r.feed);
            const uint64_t leaseFrames = static_cast<uint64_t>(rate * 0.3);
            N60AncLaneFeedRenewLease(r.feed, mode == 0 ? leaseFrames : leaseLong);
            runFrames(r, static_cast<uint64_t>(rate * 0.2));
            CHECK(sourcePeak(r) > 0.001, "not playing before the cut at %.0f", rate);
            uint64_t cutAt = 0;
            if (mode == 1) {
                N60AncLaneFeedDisarm(r.feed);
                cutAt = N60AncLaneFeedGetStatus(r.feed).renderedFrames;
            } else {
                cutAt = leaseFrames;
            }
            const uint64_t silentBy = cutAt + static_cast<uint64_t>(rate * 0.020) + 2u * kBlock;
            while (N60AncLaneFeedGetStatus(r.feed).renderedFrames < silentBy) block(r);
            block(r);
            CHECK(sourcesExactlyZero(r), "mode %d not silent within 20 ms at %.0f (peak %g)", mode, rate, sourcePeak(r));
            if (mode == 0) {
                CHECK(N60AncLaneFeedGetStatus(r.feed).leaseExpiries == 1, "lease expiry count at %.0f", rate);
            }
            N60AncLaneFeedDestroy(r.feed);
        }

        // 5. Reset clears the arm, the lease and the history, and keeps the snapshot.
        {
            Rig r;
            CHECK(rigInit(r, rate, true, false, 0.05), "rig at %.0f", rate);
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            runFrames(r, static_cast<uint64_t>(rate * 0.2));
            N60AncLaneFeedReset(r.feed);
            const N60AncLaneFeedStatus st = N60AncLaneFeedGetStatus(r.feed);
            CHECK(!st.armed && !st.leaseActive && st.gain == 0.0f && st.renderedFrames == 0,
                  "reset left state at %.0f", rate);
            runFrames(r, 4 * kBlock);
            CHECK(sourcesExactlyZero(r), "output after reset at %.0f", rate);
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            runFrames(r, static_cast<uint64_t>(rate * 0.2));
            CHECK(sourcePeak(r) > 0.001, "snapshot lost across reset at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }

        // 6. Pass-through and refusal.
        {
            Rig r;
            CHECK(rigInit(r, rate, true, false, 0.05), "rig at %.0f", rate);
            for (uint32_t i = 0; i < kBlock; ++i) {
                r.inLanes[0][i] = 0.1f * static_cast<float>(i % 7);
                r.inLanes[1][i] = -0.05f * static_cast<float>(i % 5);
                r.inLanes[5][i] = 0.3f;
            }
            for (uint32_t ch = 0; ch < kChannels; ++ch) r.lanes[ch] = r.inLanes[ch];
            // Same arrays in and out, as the graph passes them.
            for (uint32_t ch = 0; ch < kChannels; ++ch) r.inPtr[ch] = r.lanes[ch].data();
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            CHECK(block(r) == 1, "process failed at %.0f", rate);
            bool same = true;
            for (uint32_t i = 0; i < kBlock; ++i) {
                same = same && r.lanes[0][i] == r.inLanes[0][i] && r.lanes[1][i] == r.inLanes[1][i]
                    && r.lanes[5][i] == r.inLanes[5][i];
            }
            CHECK(same, "programme or spare lanes changed at %.0f", rate);
            CHECK(N60AncLaneFeedProcess(r.feed, r.inPtr, r.outPtr, kChannels - 1u, kBlock) == 0, "wrong channels accepted");
            CHECK(N60AncLaneFeedGetStatus(r.feed).faults == 1, "fault count at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }

        // 8. No allocation in the realtime call, including a block longer than the chunk.
        {
            Rig r;
            CHECK(rigInit(r, rate, true, true, 0.05), "rig at %.0f", rate);
            const uint32_t longFrames = 10000;  // 2.4 chunks of 4096
            std::vector<float> big[kChannels];
            const float *bi[kChannels];
            float *bo[kChannels];
            for (uint32_t ch = 0; ch < kChannels; ++ch) { big[ch].assign(longFrames, 0.0f); bi[ch] = bo[ch] = nullptr; }
            for (uint32_t ch = 0; ch < kChannels; ++ch) { bi[ch] = big[ch].data(); bo[ch] = big[ch].data(); }
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            allocs.store(0);
            armedCount.store(true);
            for (int i = 0; i < 20; ++i) N60AncLaneFeedProcess(r.feed, bi, bo, kChannels, longFrames);
            for (int i = 0; i < 20; ++i) block(r);
            armedCount.store(false);
            CHECK(allocs.load() == 0, "%ld allocations in process at %.0f", allocs.load(), rate);
            CHECK(N60AncLaneFeedGetStatus(r.feed).renderedFrames == 20u * longFrames + 20u * kBlock, "long block frames at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }

        // 7. Live feed-forward: plays only while armed with a lease; the reference ring advances with the output.
        {
            Rig r;
            CHECK(rigInit(r, rate, false, true, 0.05), "rig at %.0f", rate);
            float w[8] = {-0.5f, 0, 0, 0, 0, 0, 0, 0}, z[8] = {};
            CHECK(N60AncLaneFeedSetFeedForwardWeights(r.feed, w, z, 1u), "weights at %.0f", rate);
            uint64_t pushed = 0;
            auto pump = [&]() {
                const uint64_t want = N60AncLaneFeedReferenceOutputIndex(r.feed) + 4u * kBlock;
                while (pushed < want) {
                    float chunk[kBlock];
                    for (uint32_t i = 0; i < kBlock; ++i) {
                        chunk[i] = 0.5f * std::sin(static_cast<float>(2.0 * M_PI * 60.0 * static_cast<double>(pushed + i) / rate));
                    }
                    pushed = N60AncLaneFeedPushReference(r.feed, pushed, chunk, kBlock);
                }
            };
            // Not armed: the filter may arm, but nothing plays.
            CHECK(N60AncLaneFeedFeedForwardArm(r.feed, 0.010, 0.005) == N60FeedForwardLiveArmOK, "ff arm at %.0f", rate);
            double quiet = 0.0;
            for (int i = 0; i < 40; ++i) { pump(); block(r); quiet = std::fmax(quiet, sourcePeak(r)); }
            CHECK(quiet == 0.0, "ff played while the feed was disarmed at %.0f", rate);
            N60AncLaneFeedArm(r.feed);
            N60AncLaneFeedRenewLease(r.feed, leaseLong);
            double loud = 0.0;
            for (uint64_t done = 0; done < static_cast<uint64_t>(rate * 0.4); done += kBlock) { pump(); block(r); loud = std::fmax(loud, sourcePeak(r)); }
            CHECK(loud > 0.02, "ff silent while armed at %.0f (peak %g)", rate, loud);
            CHECK(N60AncLaneFeedReferenceOutputIndex(r.feed) == N60AncLaneFeedGetStatus(r.feed).renderedFrames,
                  "reference index %llu vs rendered %llu at %.0f",
                  static_cast<unsigned long long>(N60AncLaneFeedReferenceOutputIndex(r.feed)),
                  static_cast<unsigned long long>(N60AncLaneFeedGetStatus(r.feed).renderedFrames), rate);
            N60AncLaneFeedReleaseLease(r.feed);
            runFrames(r, static_cast<uint64_t>(rate * 0.1));
            for (int i = 0; i < 3; ++i) { pump(); block(r); }
            CHECK(sourcesExactlyZero(r), "ff played after the lease was released at %.0f", rate);
            N60AncLaneFeedDestroy(r.feed);
        }
    }

    // 4. The default fade-in is a 3 s linear ramp (checked once at 48 kHz; the step is rate-scaled by construction).
    {
        Rig r;
        CHECK(rigInit(r, 48000.0, true, false, 0.0), "rig for fade-in");
        N60AncLaneFeedArm(r.feed);
        N60AncLaneFeedRenewLease(r.feed, 48000ull * 600ull);
        runFrames(r, static_cast<uint64_t>(48000.0 * 1.5));
        const float half = N60AncLaneFeedGetStatus(r.feed).gain;
        CHECK(std::fabs(half - 0.5f) < 0.01f, "gain at 1.5 s is %g", half);
        runFrames(r, static_cast<uint64_t>(48000.0 * 1.5) + 2u * kBlock);
        CHECK(N60AncLaneFeedGetStatus(r.feed).gain >= 0.999f, "gain at 3 s is %g", N60AncLaneFeedGetStatus(r.feed).gain);
        N60AncLaneFeedDestroy(r.feed);
    }

    if (failures == 0) std::printf("e26_anc_lane_feed: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
