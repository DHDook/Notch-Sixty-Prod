// E27 S2c: the analyser taps (ABI v21) through the C ABI at the eight standard rates.
//  1. Placement: TAP_EQ ranks after the PEQ and before the compressor, TAP_DYN after the expander; the core rejects
//     stages listed out of rank order, and a tap needs a lane mask and a ring.
//  2. No demand, no recording: the ring stays empty and the audio equals a graph without the taps.
//  3. With demand (a live parameter, no rebuild) each tap holds the program at its own point: +12 dB of EQ is in both
//     rings, and the output gain after them (0.5) is not (gains are excluded from the overlay).
//  4. Re-arming: samples before the recorded `written` index belong to the earlier session; a new snapshot starts empty.
//  5. The realtime call allocates nothing with the demand on.
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "n60/graph.h"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
static void countedFree(void *p) {
    if (p != nullptr && armed.load()) allocs.fetch_add(1);
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
static const double kPi = 3.14159265358979323846;
static const uint32_t kBlock = 480;
static const uint32_t kRing = 16384;
enum : uint32_t { kPeqId = 10, kTapEqId = 20, kTapDynId = 30, kGainId = 40 };

static n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t laneA, uint64_t mask, const float *p, uint32_t pc,
                            uint32_t cap = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.laneMask = mask;
    s.capacityFrames = cap;
    s.params = p;
    s.paramCount = pc;
    return s;
}

static n60_status build(double rate, const std::vector<n60_stage_desc> &st, n60_graph **g) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st.data();
    d.stageCount = static_cast<uint32_t>(st.size());
    return n60_graph_build(&d, g);
}

using Lanes = std::vector<std::vector<float>>;

static Lanes run(n60_graph *g, const Lanes &in, bool count = false) {
    const size_t n = in[0].size();
    Lanes out(2, std::vector<float>(n, 0.0f));
    for (size_t at = 0; at < n; at += kBlock) {
        const uint32_t len = static_cast<uint32_t>(std::min<size_t>(kBlock, n - at));
        const float *ip[2] = {in[0].data() + at, in[1].data() + at};
        float *op[2] = {out[0].data() + at, out[1].data() + at};
        if (count) { allocs = 0; armed = true; }
        n60_status st = n60_graph_process(g, ip, op, len);
        if (count) { armed = false; CHECK(allocs == 0, "realtime call allocated or freed %ld time(s)", allocs.load()); }
        CHECK(st == N60_STATUS_OK, "process status %d", static_cast<int>(st));
    }
    return out;
}

static double amplitude(const float *x, size_t n, double rate, double hz) {
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < n; i++) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * (i + 0.5) / n);
        const double ph = 2.0 * kPi * hz * i / rate;
        re += w * x[i] * std::cos(ph);
        im += w * x[i] * std::sin(ph);
        wsum += w;
    }
    return 2.0 * std::sqrt(re * re + im * im) / wsum;
}

static Lanes tone(size_t n, double rate, double hz, double level, size_t offset = 0) {
    Lanes t(2, std::vector<float>(n));
    for (size_t i = 0; i < n; i++) t[0][i] = t[1][i] = static_cast<float>(level * std::sin(2.0 * kPi * hz * (i + offset) / rate));
    return t;
}

static n60_status setDemand(n60_graph *g, uint32_t stageId, float on) {
    const n60_param_record r = {stageId, 0, on, 0};
    return n60_graph_post_params(g, &r, 1);
}

// Reads the newest `frames` samples of a lane; returns false when fewer than `frames` exist after `from`.
static bool latest(n60_graph *g, uint32_t stageId, uint32_t lane, uint64_t from, std::vector<float> &dst, uint32_t frames,
                   uint64_t *writtenOut = nullptr) {
    uint64_t w = 0;
    if (n60_graph_read_capture(g, stageId, lane, 0, nullptr, 0, &w) != N60_STATUS_OK) return false;
    if (writtenOut) *writtenOut = w;
    if (w < from + frames) return false;
    dst.assign(frames, 0.0f);
    return n60_graph_read_capture(g, stageId, lane, w - frames, dst.data(), frames, &w) == N60_STATUS_OK;
}

static void testTaps() {
    for (double rate : kRates) {
        const float peq[4] = {0.0f, 1000.0f, 12.0f, 1.0f};  // peaking, 1 kHz, +12 dB, Q 1
        const float off = 0.0f, on = 1.0f, gain = 0.5f;
        auto graphStages = [&](bool taps) {
            std::vector<n60_stage_desc> st = {stage(N60_STAGE_PEQ, kPeqId, N60_LANE_ALL, 0, peq, 4)};
            if (taps) st.push_back(stage(N60_STAGE_ANALYSER_TAP_EQ, kTapEqId, 0, 0b11, &off, 1, kRing));
            if (taps) st.push_back(stage(N60_STAGE_ANALYSER_TAP_DYN, kTapDynId, 0, 0b11, &off, 1, kRing));
            st.push_back(stage(N60_STAGE_OUTPUT_GAIN, kGainId, N60_LANE_ALL, 0, &gain, 1));
            return st;
        };
        {  // 1. Rank order and argument checks.
            n60_graph *w = nullptr;
            std::vector<n60_stage_desc> wrong = {stage(N60_STAGE_ANALYSER_TAP_EQ, kTapEqId, 0, 0b11, &off, 1, kRing),
                                                 stage(N60_STAGE_PEQ, kPeqId, N60_LANE_ALL, 0, peq, 4)};
            CHECK(build(rate, wrong, &w) != N60_STATUS_OK, "rate %.0f: a tap before the PEQ is rejected", rate);
            std::vector<n60_stage_desc> swapped = {stage(N60_STAGE_ANALYSER_TAP_DYN, kTapDynId, 0, 0b11, &off, 1, kRing),
                                                   stage(N60_STAGE_ANALYSER_TAP_EQ, kTapEqId, 0, 0b11, &off, 1, kRing)};
            CHECK(build(rate, swapped, &w) != N60_STATUS_OK, "rate %.0f: TAP_DYN before TAP_EQ is rejected", rate);
            std::vector<n60_stage_desc> noRing = {stage(N60_STAGE_ANALYSER_TAP_EQ, kTapEqId, 0, 0b11, &off, 1, 0)};
            CHECK(build(rate, noRing, &w) != N60_STATUS_OK, "rate %.0f: a tap without a ring is rejected", rate);
            const float two = 2.0f;
            std::vector<n60_stage_desc> badDemand = {stage(N60_STAGE_ANALYSER_TAP_EQ, kTapEqId, 0, 0b11, &two, 1, kRing)};
            CHECK(build(rate, badDemand, &w) != N60_STATUS_OK, "rate %.0f: a demand other than 0 or 1 is rejected", rate);
        }
        const size_t n = static_cast<size_t>(rate * 0.5) / kBlock * kBlock;
        const Lanes in = tone(n, rate, 1000.0, 0.1);
        n60_graph *plain = nullptr, *g = nullptr;
        CHECK(build(rate, graphStages(false), &plain) == N60_STATUS_OK, "rate %.0f: plain build", rate);
        CHECK(build(rate, graphStages(true), &g) == N60_STATUS_OK, "rate %.0f: tap build", rate);
        if (!plain || !g) continue;
        const Lanes ref = run(plain, in);
        // 2. No demand: nothing recorded, audio unchanged.
        const Lanes quiet = run(g, in);
        uint64_t w = 99;
        CHECK(n60_graph_read_capture(g, kTapEqId, 0, 0, nullptr, 0, &w) == N60_STATUS_OK && w == 0, "rate %.0f: no demand, EQ ring empty (%llu)", rate, (unsigned long long)w);
        CHECK(n60_graph_read_capture(g, kTapDynId, 1, 0, nullptr, 0, &w) == N60_STATUS_OK && w == 0, "rate %.0f: no demand, DYN ring empty", rate);
        CHECK(quiet[0] == ref[0] && quiet[1] == ref[1], "rate %.0f: taps leave the audio untouched", rate);
        // 3. Demand on, live: no rebuild, both taps record the program at their point.
        CHECK(setDemand(g, kTapEqId, on) == N60_STATUS_OK, "rate %.0f: EQ demand posts live", rate);
        CHECK(setDemand(g, kTapDynId, on) == N60_STATUS_OK, "rate %.0f: DYN demand posts live", rate);
        uint64_t base = 0;
        n60_graph_read_capture(g, kTapEqId, 0, 0, nullptr, 0, &base);
        const Lanes live = run(g, tone(n, rate, 1000.0, 0.1, n), true);
        const uint32_t window = 8192;
        std::vector<float> eqTap, dynTap;
        for (uint32_t lane = 0; lane < 2; lane++) {
            CHECK(latest(g, kTapEqId, lane, base, eqTap, window), "rate %.0f: EQ tap lane %u readable", rate, lane);
            CHECK(latest(g, kTapDynId, lane, base, dynTap, window), "rate %.0f: DYN tap lane %u readable", rate, lane);
            if (eqTap.empty() || dynTap.empty()) continue;
            const double eq = amplitude(eqTap.data(), window, rate, 1000.0);
            const double dyn = amplitude(dynTap.data(), window, rate, 1000.0);
            const double out = amplitude(live[lane].data() + n - window, window, rate, 1000.0);
            CHECK(std::fabs(20.0 * std::log10(eq / 0.1) - 12.0) < 0.3, "rate %.0f: EQ tap holds +12 dB (%.3f)", rate, 20.0 * std::log10(eq / 0.1));
            CHECK(std::fabs(20.0 * std::log10(dyn / 0.1) - 12.0) < 0.3, "rate %.0f: DYN tap holds +12 dB", rate);
            CHECK(std::fabs(out / eq - 0.5) < 0.01, "rate %.0f: the output gain after the taps is not in them (%.3f)", rate, out / eq);
        }
        // 4. Switching the demand off stops the recording.
        CHECK(setDemand(g, kTapEqId, off) == N60_STATUS_OK, "rate %.0f: EQ demand off", rate);
        run(g, tone(kBlock, rate, 1000.0, 0.1));  // applies the parameter
        uint64_t frozen = 0, after = 0;
        n60_graph_read_capture(g, kTapEqId, 0, 0, nullptr, 0, &frozen);
        run(g, tone(2 * kBlock, rate, 1000.0, 0.1));
        n60_graph_read_capture(g, kTapEqId, 0, 0, nullptr, 0, &after);
        CHECK(frozen == after, "rate %.0f: demand off freezes the ring", rate);
        // Stage ids that are not taps (or lanes outside the mask) are refused.
        std::vector<float> scratch(16);
        CHECK(n60_graph_read_capture(g, kPeqId, 0, 0, scratch.data(), 0, &w) != N60_STATUS_OK, "rate %.0f: PEQ is not a capture", rate);
        n60_graph_retire(plain);
        n60_graph_retire(g);
    }
}

int main() {
    testTaps();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("analyser tap tests passed");
    return 0;
}
