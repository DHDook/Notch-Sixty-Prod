// E9 S2: long FIR across rebuilds (amortised carry, input-history seeding, budgeted reset), through the C ABI at
// the eight standard rates. Reference graphs are rendered next to the graph under test with the same input, so
// "identical" means bit-for-bit (the engine is deterministic).
//
// The internal header graph_debug.hpp gives the most bulk bytes (clear + copy) any callback has spent.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "graph_debug.hpp"
#include "n60/graph.h"

namespace {

int failures = 0;
#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);          \
            std::fprintf(stderr, __VA_ARGS__);                                 \
            std::fputc('\n', stderr);                                          \
            ++failures;                                                        \
        }                                                                      \
    } while (0)

constexpr double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr uint32_t kBlock = 200;  // deliberately not a multiple of the 256-frame partition
constexpr uint32_t kMaxBlock = 512;
const uint64_t kBudget = n60_graph_debug_rt_budget(kBlock);  // 1 KiB per frame, 4 KiB to 256 KiB (S2b)

uint64_t mix(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}
float noise(uint64_t pos, uint32_t lane, uint64_t seed) {
    return static_cast<float>(static_cast<int64_t>(mix(pos * 64 + lane + seed * 0x1000193ull)) >> 40) / 8388608.0f * 0.25f;
}

std::vector<float> decaying(uint32_t taps, uint64_t seed, float scale) {
    std::vector<float> h(taps);
    for (uint32_t n = 0; n < taps; ++n) {
        h[n] = noise(n, 0, seed) * scale * static_cast<float>(std::exp(-6.0 * n / taps));
    }
    return h;
}

n60_stage_desc stage(uint32_t kind, uint32_t id, const float *p, uint32_t n) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = N60_LANE_ALL;
    s.params = p;
    s.paramCount = n;
    return s;
}

n60_graph_desc desc(double rate, uint32_t ch, const n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kMaxBlock;
    d.inputChannels = d.outputChannels = ch;
    d.stages = st;
    d.stageCount = n;
    d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    return d;
}

// A graph plus the stream position it has consumed.
struct Rig {
    n60_graph *g = nullptr;
    uint32_t ch = 0;
    uint64_t pos = 0;
    std::vector<float> in, out;
    std::vector<float *> inP, outP;
    uint64_t seed = 1;

    Rig(double rate, uint32_t channels, const n60_stage_desc *st, uint32_t n, uint64_t sd = 1) : ch(channels), seed(sd) {
        n60_graph_desc d = desc(rate, channels, st, n);
        const n60_status rc = n60_graph_build(&d, &g);
        CHECK(rc == N60_STATUS_OK && g != nullptr, "build status %d", (int)rc);
        in.resize(size_t(ch) * kMaxBlock);
        out.resize(size_t(ch) * kMaxBlock);
        for (uint32_t c = 0; c < ch; ++c) {
            inP.push_back(in.data() + size_t(c) * kMaxBlock);
            outP.push_back(out.data() + size_t(c) * kMaxBlock);
        }
    }
    ~Rig() { n60_graph_retire(g); }
    // One block; the output stays in `out`.
    void step(uint32_t frames = kBlock) {
        for (uint32_t c = 0; c < ch; ++c) {
            for (uint32_t i = 0; i < frames; ++i) inP[c][i] = noise(pos + i, c, seed);
        }
        CHECK(n60_graph_process(g, inP.data(), outP.data(), frames) == N60_STATUS_OK, "process");
        pos += frames;
        n60_graph_collect(g);
    }
    n60_rebuild_status status() const {
        n60_rebuild_status s;
        std::memset(&s, 0, sizeof s);
        s.structSize = sizeof s;
        n60_graph_get_rebuild_status(g, &s);
        return s;
    }
    void publish(const n60_stage_desc *st, uint32_t n, double rate) {
        n60_graph_desc d = desc(rate, ch, st, n);
        n60_status rc = n60_graph_publish(g, &d);
        CHECK(rc == N60_STATUS_OK, "publish status %d", (int)rc);
    }
};

void runFrames(Rig &r, uint64_t frames, uint32_t blk = kBlock) {
    for (uint64_t done = 0; done < frames; done += blk) r.step(blk);
}

// Renders `test` and `ref` in step for `frames`; returns the largest |test - ref|, ignoring blocks whose
// rebuild state was not idle at the end of the block when `idleOnly`.
double compareRun(Rig &test, Rig &ref, uint64_t frames, bool idleOnly, uint32_t *callbacks = nullptr,
                  uint32_t blk = kBlock) {
    double worst = 0;
    for (uint64_t done = 0; done < frames; done += blk) {
        test.step(blk);
        ref.step(blk);
        if (callbacks != nullptr) ++*callbacks;
        if (idleOnly && test.status().state != 0) continue;
        for (size_t i = 0; i < test.out.size(); ++i) worst = std::max<double>(worst, std::fabs(test.out[i] - ref.out[i]));
    }
    return worst;
}

// Drives the rebuild to the end, returning the callbacks spent warming (state 1) and the peak budget used.
uint32_t finishRebuild(Rig &r, uint32_t limit = 200000, uint32_t blk = kBlock) {
    uint32_t warming = 0, n = 0;
    while (r.status().state != 0 && n++ < limit) {
        r.step(blk);
        if (r.status().state == 1) ++warming;
    }
    return warming;
}

// ---- 1. Unchanged long FIR across an unrelated rebuild: identical to an uninterrupted render. ------------------

void testCarryIdentical(double rate, uint32_t lanes, bool delayMode) {
    const uint32_t taps = 262144;
    std::vector<float> h = delayMode ? std::vector<float>(taps, 0.0f) : decaying(taps, 7, 0.02f);
    if (delayMode) h[taps - 1] = 1.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_METER_OUT, 2, nullptr, 0)};  // unrelated: a meter after the filter
    Rig test(rate, lanes, a, 1), ref(rate, lanes, a, 1);
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    test.publish(b, 2, rate);
    ref.step();
    test.step();
    const uint32_t warming = finishRebuild(test);
    // Bring the reference to the same position, then compare after the fade.
    while (ref.pos < test.pos) ref.step();
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f lanes %u delay %d completed", rate, lanes,
          delayMode);
    // Carried: the warm-up is the copy plus the settle, a small fraction of the 262,144-frame full warm.
    const uint64_t bytesPerLane = delayMode ? 4ull * taps : 2300000ull;
    const uint64_t copyCallbacks = (bytesPerLane * lanes + kBudget - 1) / kBudget + 1;
    const uint32_t settle = delayMode ? 0 : (48 * 256 + kBlock - 1) / kBlock;
    CHECK(warming <= copyCallbacks + settle + 10 && warming < taps / kBlock / 4,
          "rate %.0f lanes %u delay %d warm callbacks %u (copy %llu + settle %u)", rate, lanes, delayMode, warming,
          (unsigned long long)copyCallbacks, settle);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f lanes %u peak bulk bytes %llu", rate, lanes,
          (unsigned long long)n60_graph_debug_peak_rt_bytes(test.g));
    // The incoming instance equalled the outgoing one at the fade: the equal-power fade of equal signals is x (cos + sin).
    // After it, the two renders are identical bit for bit.
    CHECK(compareRun(test, ref, 3ull * 16384, true) == 0.0, "rate %.0f lanes %u delay %d output differs after carry", rate, lanes,
          delayMode);
}

// ---- 2. Changed taps, unchanged upstream: seeded; changed upstream: full warm. -------------------------------

void testSeed(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> hA = decaying(taps, 21, 0.02f), hB = decaying(taps, 22, 0.02f);
    const float unity = 1.0f;
    n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 2, &unity, 1), stage(N60_STAGE_FIR, 1, hA.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_FIR, 1, hB.data(), taps)};
    n60_stage_desc refB[2] = {a[0], b[1]};
    Rig test(rate, 2, a, 2), ref(rate, 2, refB, 2);
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    test.publish(b, 2, rate);
    test.step();
    const uint32_t warming = finishRebuild(test);
    while (ref.pos < test.pos) ref.step();
    CHECK(test.status().completed == 1, "rate %.0f seeded rebuild completed", rate);
    const uint32_t bound = (2 * 2300000u + kBudget - 1) / kBudget + 1 + (48 * 256 + kBlock - 1) / kBlock + 4;
    CHECK(warming <= bound, "rate %.0f seeded warm callbacks %u > %u", rate, warming, bound);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f seeded peak bytes", rate);
    // After the fade the output is a fresh render of the new filter on the same input.
    CHECK(compareRun(test, ref, 3ull * 16384, true) == 0.0, "rate %.0f seeded output is not a fresh render", rate);
}

void testUpstreamChanged(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> hA = decaying(taps, 31, 0.02f), hB = decaying(taps, 32, 0.02f);
    const float g1 = 1.0f, g2 = 0.5f;
    n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 2, &g1, 1), stage(N60_STAGE_FIR, 1, hA.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &g2, 1), stage(N60_STAGE_FIR, 1, hB.data(), taps)};
    Rig test(rate, 1, a, 2);
    runFrames(test, taps + 4096);
    test.publish(b, 2, rate);
    test.step();
    const uint32_t warming = finishRebuild(test);
    CHECK(test.status().completed == 1, "rate %.0f upstream-changed rebuild completed", rate);
    CHECK(warming >= taps / kBlock, "rate %.0f changed upstream must warm in full (%u callbacks)", rate, warming);
}

void testCpuRefusal(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> hA = decaying(taps, 41, 0.02f), hB = decaying(taps, 42, 0.02f);
    const float g1 = 1.0f, g2 = 0.5f;
    n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 2, &g1, 1), stage(N60_STAGE_FIR, 1, hA.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &g2, 1), stage(N60_STAGE_FIR, 1, hB.data(), taps)};
    Rig test(rate, 1, a, 2);
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 20.0f;
    o.cpuBudgetPercent = 1e-7f;
    CHECK(n60_graph_set_rebuild_options(test.g, &o) == N60_STATUS_OK, "options");
    runFrames(test, 8192);
    test.publish(b, 2, rate);
    test.step();
    finishRebuild(test);
    CHECK(test.status().refused == 1 && test.status().lastResult == 2, "rate %.0f CPU refusal still holds", rate);
}

// ---- 3. Reset (history invalidation) is budgeted and O(1) in delay mode. --------------------------------------

void testReset(double rate, bool delayMode) {
    const uint32_t taps = 262144, lanes = 8;
    std::vector<float> h = delayMode ? std::vector<float>(taps, 0.0f) : decaying(taps, 51, 0.02f);
    if (delayMode) h[taps - 1] = 1.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    Rig test(rate, lanes, a, 1), ref(rate, lanes, a, 1);
    runFrames(test, taps + 4096);
    n60_graph_invalidate_history(test.g);
    const uint64_t cut = test.pos;
    // The reference starts empty at the cut and sees the same input from there.
    ref.pos = cut;
    uint64_t peak = 0;
    for (uint64_t done = 0; done < uint64_t(taps) + 256 + 6 * 16384; done += kBlock) {
        test.step();
        ref.step();
        peak = std::max(peak, n60_graph_debug_peak_rt_bytes(test.g));
    }
    CHECK(peak <= kBudget, "rate %.0f delay %d reset used %llu bytes in a callback", rate, delayMode, (unsigned long long)peak);
    // Late enough that the input a budgeted reset drops no longer reaches the output, the two agree.
    // FFT block phase differs between the two (the budgeted reset restarts the lane a few callbacks later), so the
    // match is to rounding, not bit for bit; delay mode is exact.
    const double err = compareRun(test, ref, 4 * kBlock, false);
    CHECK(delayMode ? err == 0.0 : err < 2e-6, "rate %.0f delay %d output after reset differs by %g", rate, delayMode, err);
}

// ---- 4. No click when swapping two 262,144-tap filters. --------------------------------------------------------

void testClick(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> hA(taps, 0.0f), hB(taps, 0.0f);
    hA[5] = 1.0f;
    hA[200000] = 1e-3f;
    hB[9] = 0.8f;
    hB[150000] = 1e-3f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, hA.data(), taps)};
    n60_stage_desc b[1] = {stage(N60_STAGE_FIR, 1, hB.data(), taps)};
    n60_graph_desc d = desc(rate, 1, a, 1);
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build");
    std::vector<float> in(kMaxBlock), out(kMaxBlock);
    const float *inP[1] = {in.data()};
    float *outP[1] = {out.data()};
    uint64_t pos = 0;
    double prev = 0, worst = 0;
    const double w = 2.0 * 3.14159265358979323846 * 300.0 / rate;
    auto step = [&]() {
        for (uint32_t i = 0; i < kBlock; ++i) in[i] = static_cast<float>(0.5 * std::sin(w * double(pos + i)));
        n60_graph_process(g, inP, outP, kBlock);
        pos += kBlock;
        n60_graph_collect(g);
    };
    n60_rebuild_status s;
    for (uint64_t n = 0; n < (taps + 8192) / kBlock; ++n) {
        step();
        prev = out[kBlock - 1];
    }
    d = desc(rate, 1, b, 1);
    CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish");
    uint32_t n = 0;
    do {
        step();
        worst = std::max(worst, std::fabs(double(out[0]) - prev));
        for (uint32_t i = 1; i < kBlock; ++i) worst = std::max(worst, std::fabs(double(out[i]) - out[i - 1]));
        prev = out[kBlock - 1];
        std::memset(&s, 0, sizeof s);
        s.structSize = sizeof s;
        n60_graph_get_rebuild_status(g, &s);
    } while (s.state != 0 && n++ < 100000);
    // Two sines of amplitude 0.5 and 0.4 with a different phase: the crossfade is smooth, a click is many slopes.
    CHECK(s.completed == 1, "rate %.0f click rebuild completed", rate);
    CHECK(worst < 0.5 * w * 2.0, "rate %.0f swap step %g vs bound %g", rate, worst, 0.5 * w * 2.0);
    n60_graph_retire(g);
}

// ---- 5. No fade: a copy within the callback budget is whole and counted; a larger one defers the swap. ----------

// 2,048 taps on 2 lanes fit the budget: the swap is at once, the copy is counted in the peak.
void testNoFadeSync(double rate) {
    const uint32_t taps = 2048;
    std::vector<float> h = decaying(taps, 61, 0.02f);
    const float unity = 1.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &unity, 1), a[0]};  // moved: not in lockstep, copied whole
    Rig test(rate, 2, a, 1), ref(rate, 2, a, 1);
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    CHECK(n60_graph_set_rebuild_options(test.g, &o) == N60_STATUS_OK, "options");
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    const uint64_t before = n60_graph_debug_peak_rt_bytes(test.g);
    test.publish(b, 2, rate);
    test.step();
    ref.step();
    CHECK(test.status().state == 0 && test.status().completed == 0, "rate %.0f small fade-less swap is at once", rate);
    const uint64_t copied = n60_graph_debug_peak_rt_bytes(test.g);
    CHECK(copied > before && copied <= kBudget, "rate %.0f fade-less copy counted in the peak (%llu)", rate, (unsigned long long)copied);
    CHECK(compareRun(test, ref, 4 * 16384, false) == 0.0, "rate %.0f instant swap keeps the filter running", rate);
}

// 32,768 taps on 2 lanes are over the budget: same position, so the lane runs in lockstep and the swap waits for
// the copy; the output never differs from an uninterrupted render, and no callback exceeds the budget.
void testNoFadeDeferred(double rate) {
    const uint32_t taps = 32768;
    std::vector<float> h = decaying(taps, 62, 0.02f);
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_METER_OUT, 2, nullptr, 0)};
    Rig test(rate, 2, a, 1), ref(rate, 2, a, 1);
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    o.cpuBudgetPercent = 1e-7f;  // a fade-less snapshot is never refused for CPU
    CHECK(n60_graph_set_rebuild_options(test.g, &o) == N60_STATUS_OK, "options");
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    test.publish(b, 2, rate);
    test.step();
    ref.step();
    CHECK(test.status().state != 0, "rate %.0f large fade-less swap waits for the lazy copy", rate);
    CHECK(compareRun(test, ref, 4 * 16384, false) == 0.0, "rate %.0f deferred swap keeps the filter running", rate);
    CHECK(test.status().state == 0 && test.status().completed == 1 && test.status().refused == 0, "rate %.0f deferred swap done", rate);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f deferred peak %llu", rate,
          (unsigned long long)n60_graph_debug_peak_rt_bytes(test.g));
}

// Over the budget and not in lockstep (E9 S2c, G8): no whole copy is made and the stage does not start empty. It warms
// in full next to the live instance, the fade-less swap waits for it (never refused for CPU), and after the swap the
// output is what a fresh render of the new topology gives.
void testNoFadeTooLargeMoved(double rate) {
    const uint32_t taps = 32768;
    std::vector<float> h = decaying(taps, 63, 0.02f);
    const float unity = 1.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &unity, 1), a[0]};
    Rig test(rate, 2, a, 1), fresh(rate, 2, b, 2);
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    o.cpuBudgetPercent = 1e-7f;
    CHECK(n60_graph_set_rebuild_options(test.g, &o) == N60_STATUS_OK, "options");
    runFrames(test, taps + 4096);
    test.publish(b, 2, rate);
    test.step();
    CHECK(test.status().state != 0, "rate %.0f too-large moved filter waits for its warm", rate);
    const uint32_t warming = finishRebuild(test);
    CHECK(test.status().completed == 1 && test.status().refused == 0, "rate %.0f moved swap completed, not refused", rate);
    CHECK(warming >= taps / kBlock, "rate %.0f moved filter warmed in full (%u callbacks)", rate, warming);
    // E9 S2d (G9): the wait is bounded by the filter's own tap length plus one partition and the settle (at most
    // 0.68 s of audio at 262,144 taps and 384 kHz; the live chain is unchanged and audible meanwhile). The E22 bench
    // item records the worst callback during it.
    CHECK(warming <= (taps + 256 + 48 * 256) / kBlock + 8, "rate %.0f deferred swap wait %u callbacks is bounded", rate, warming);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f too-large peak", rate);
    // The fresh graph has seen the same input from the start, so it equals the swapped one once the swap is done.
    while (fresh.pos < test.pos) fresh.step();
    double worst = 0;
    for (int blk = 0; blk < 4 * 16384 / static_cast<int>(kBlock); ++blk) {
        test.step();
        fresh.step();
        for (size_t i = 0; i < test.out.size(); ++i) worst = std::max<double>(worst, std::fabs(test.out[i] - fresh.out[i]));
    }
    CHECK(worst < 1e-5, "rate %.0f moved filter equals a fresh render after the swap (%g)", rate, worst);
}

// E9 S2c, G7: a PEQ and a gain ahead of a lazily carried long FIR keep their running state across the rebuild, so
// the incoming instance's input history has no cold-start transient: after the fade the output is bit-identical to
// an uninterrupted render (the cold biquads would differ for thousands of frames).
void testUpstreamState(double rate, uint32_t blk) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 97, 0.02f);
    const float gain = 0.8f;
    const float peq[8] = {0.0f, 60.0f, 9.0f, 2.0f, 2.0f, 6000.0f, -6.0f, 0.7f};
    // One dynamic EQ band (the compressor and expander sit after the program FIR, so only DYN_EQ is upstream of it).
    const float dq[16] = {1.0f, 0.0f, 1000.0f, 1.0f, 0.0f, -40.0f, 3.0f, -12.0f, 10.0f, 100.0f, 0.0f, -40.0f, 3.0f, 6.0f, 0.0f, 20.0f};
    n60_stage_desc a[4] = {stage(N60_STAGE_GAIN, 3, &gain, 1), stage(N60_STAGE_PEQ, 2, peq, 8),
                           stage(N60_STAGE_DYN_EQ, 5, dq, 16), stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[5] = {a[0], a[1], a[2], a[3], stage(N60_STAGE_METER_OUT, 4, nullptr, 0)};
    Rig test(rate, 2, a, 4), ref(rate, 2, a, 4);
    runFrames(test, taps + 4096, blk);
    runFrames(ref, taps + 4096, blk);
    test.publish(b, 5, rate);
    ref.step(blk);
    test.step(blk);
    CHECK(test.status().state == 1, "rate %.0f block %u upstream state: rebuild running", rate, blk);
    finishRebuild(test, 2000000, blk);
    while (ref.pos < test.pos) ref.step(blk);
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f block %u upstream state completed", rate, blk);
    CHECK(n60_graph_debug_carry_abandoned(test.g) == 0, "rate %.0f block %u carry kept", rate, blk);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= n60_graph_debug_rt_budget(blk), "rate %.0f block %u peak", rate, blk);
    CHECK(compareRun(test, ref, 3ull * 16384, true, nullptr, blk) == 0.0, "rate %.0f block %u cold upstream state differs after carry",
          rate, blk);
}

// ---- 6. Blocks below 64 frames: the budget scales with the block, the carry stays exact. -------------------------

void testSmallBlocks(double rate, uint32_t lanes, uint32_t blk) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 91, 0.02f);
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_METER_OUT, 2, nullptr, 0)};
    Rig test(rate, lanes, a, 1), ref(rate, lanes, a, 1);
    runFrames(test, taps + 4096, blk);
    runFrames(ref, taps + 4096, blk);
    test.publish(b, 2, rate);
    test.step(blk);
    finishRebuild(test, 400000, blk);
    while (ref.pos < test.pos) ref.step(blk);
    const uint64_t budget = n60_graph_debug_rt_budget(blk);
    CHECK(budget == std::max<uint64_t>(4096, uint64_t(blk) * 1024), "rate %.0f block %u budget %llu", rate, blk, (unsigned long long)budget);
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f block %u rebuild completed", rate, blk);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= budget, "rate %.0f block %u peak %llu > %llu", rate, blk,
          (unsigned long long)n60_graph_debug_peak_rt_bytes(test.g), (unsigned long long)budget);
    CHECK(compareRun(test, ref, 3ull * 16384, true, nullptr, blk) == 0.0, "rate %.0f block %u output differs after carry", rate, blk);
}

// ---- 7. A source lane whose history was invalidated and has not run since: the lazy path warms in full. ----------

void testStaleSource(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 92, 0.02f);
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_METER_OUT, 2, nullptr, 0)};
    Rig test(rate, 2, a, 1);
    runFrames(test, taps + 4096);
    n60_graph_invalidate_history(test.g);  // before the next callback: every source lane is stale
    test.publish(b, 2, rate);
    test.step();
    const uint32_t warming = finishRebuild(test);
    CHECK(test.status().completed == 1, "rate %.0f stale-source rebuild completed", rate);
    CHECK(warming >= taps / kBlock, "rate %.0f stale source warms in full (%u callbacks)", rate, warming);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f stale-source peak", rate);
    runFrames(test, 4 * 16384);
    for (size_t i = 0; i < test.out.size(); ++i) CHECK(std::isfinite(test.out[i]), "rate %.0f finite output", rate);
}

// ---- 8. A parameter post upstream of the carried filter during the copy window gives the carry up. ---------------

void testUpstreamPost(double rate, bool upstream) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 93, 0.02f);
    const float g1 = 1.0f;
    // Upstream case: the gain is before the filter. Downstream case: an output gain after it. Either way the new
    // snapshot adds a meter after the filter, so the filter itself is unchanged and carried lazily.
    n60_stage_desc a[2], bm[3];
    if (upstream) {
        a[0] = stage(N60_STAGE_GAIN, 2, &g1, 1);
        a[1] = stage(N60_STAGE_FIR, 1, h.data(), taps);
        bm[0] = a[0];
        bm[1] = a[1];
        bm[2] = stage(N60_STAGE_METER_OUT, 3, nullptr, 0);
    } else {
        a[0] = stage(N60_STAGE_FIR, 1, h.data(), taps);
        a[1] = stage(N60_STAGE_OUTPUT_GAIN, 2, &g1, 1);
        bm[0] = a[0];
        bm[1] = stage(N60_STAGE_METER_OUT, 3, nullptr, 0);
        bm[2] = a[1];
    }
    Rig test(rate, 2, a, 2), ref(rate, 2, a, 2);
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    test.publish(bm, 3, rate);
    test.step();
    for (int i = 0; i < 3; ++i) test.step();  // inside the copy window
    CHECK(test.status().state == 1, "rate %.0f copy window open", rate);
    n60_param_record rec = {2, 0, 0.5f, 0};
    CHECK(n60_graph_post_params(test.g, &rec, 1) == N60_STATUS_OK, "post");
    test.step();
    const uint32_t warming = finishRebuild(test);
    CHECK(test.status().completed == 1, "rate %.0f rebuild after post completed", rate);
    if (upstream) {
        CHECK(n60_graph_debug_carry_abandoned(test.g) == 1, "rate %.0f upstream post abandons the carry", rate);
        CHECK(warming >= taps / kBlock, "rate %.0f abandoned carry warms in full (%u callbacks)", rate, warming);
    } else {
        CHECK(n60_graph_debug_carry_abandoned(test.g) == 0, "rate %.0f downstream post keeps the carry", rate);
        CHECK(warming < taps / kBlock / 4, "rate %.0f carried warm %u", rate, warming);
    }
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f post peak", rate);
    // The post was aimed at the incoming epoch, so after the swap the output is a finite continuation.
    runFrames(test, 4 * 16384);
    for (size_t i = 0; i < test.out.size(); ++i) CHECK(std::isfinite(test.out[i]), "rate %.0f finite output", rate);
}

// Same taps behind a changed upstream stage: not in lockstep, so it warms in full (never a spliced history).
void testSameTapsUpstreamChanged(double rate) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 71, 0.02f);
    const float g1 = 1.0f, g2 = 0.5f;
    n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 2, &g1, 1), stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &g2, 1), a[1]};
    Rig test(rate, 1, a, 2);
    runFrames(test, taps + 4096);
    test.publish(b, 2, rate);
    test.step();
    const uint32_t warming = finishRebuild(test);
    CHECK(test.status().completed == 1 && warming >= taps / kBlock, "rate %.0f same taps behind new upstream warm %u", rate, warming);
}

// A history invalidation or a second publish while the carry is copying ends cleanly and the graph recovers.
void testInterrupted(double rate, bool invalidate) {
    const uint32_t taps = 262144;
    std::vector<float> h = decaying(taps, 81, 0.02f);
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {a[0], stage(N60_STAGE_METER_OUT, 2, nullptr, 0)};
    Rig test(rate, 8, a, 1), ref(rate, 8, a, 1);
    runFrames(test, taps + 4096);
    test.publish(b, 2, rate);
    for (int i = 0; i < 4; ++i) test.step();  // inside the copy
    CHECK(test.status().state != 0, "rate %.0f copy in progress", rate);
    if (invalidate) {
        n60_graph_invalidate_history(test.g);
    } else {
        test.publish(a, 1, rate);
    }
    finishRebuild(test);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= kBudget, "rate %.0f interrupted peak %llu", rate,
          (unsigned long long)n60_graph_debug_peak_rt_bytes(test.g));
    for (int i = 0; i < 4; ++i) test.step();
    for (size_t i = 0; i < test.out.size(); ++i) CHECK(std::isfinite(test.out[i]), "rate %.0f finite output", rate);
}


// ---- 9. E9 S2d (G9): every stateful stage kind ahead of a lazily carried FIR is carried or refused. ---------------

n60_stage_desc stageLanes(uint32_t kind, uint32_t id, uint32_t laneA, uint32_t laneB, uint64_t mask, const float *p, uint32_t n) {
    n60_stage_desc s = stage(kind, id, p, n);
    s.laneA = laneA;
    s.laneB = laneB;
    s.laneMask = mask;
    return s;
}

// The chain every case below shares: gain, cleanup, PEQ, dynamic EQ, compressor, expander, meter, bass management,
// stereo crossover, ambient compensation, core dynamics, then the driver FIR (all lanes of a four-lane graph).
struct Chain {
    std::vector<float> taps;
    float cleanup[26], gain = 0.8f, peq[8], dq[16], comp[10], exp[6], bass[9], xo[8], amb[10], core[10];
    n60_stage_desc st[13];
    uint32_t n = 0;

    Chain(uint32_t tapCount, uint64_t seed) : taps(decaying(tapCount, seed, 0.02f)) {
        std::memset(cleanup, 0, sizeof cleanup);
        cleanup[0] = 1;
        cleanup[1] = 1;
        cleanup[2] = 20;
        cleanup[3] = 1;
        cleanup[5] = 50;
        cleanup[6] = 3;
        cleanup[7] = 20;
        cleanup[9] = 50;
        for (int i = 10; i < 26; ++i) cleanup[i] = -30;
        const float peqv[8] = {0.0f, 60.0f, 9.0f, 2.0f, 2.0f, 6000.0f, -6.0f, 0.7f};
        std::memcpy(peq, peqv, sizeof peq);
        const float dqv[16] = {1.0f, 0.0f, 1000.0f, 1.0f, 0.0f, -40.0f, 3.0f, -12.0f, 10.0f, 100.0f, 0.0f, -40.0f, 3.0f, 6.0f, 0.0f, 20.0f};
        std::memcpy(dq, dqv, sizeof dq);
        const float cv[10] = {-30.0f, 4.0f, 6.0f, 5.0f, 80.0f, 2.0f, 0.0f, 1.0f, 100.0f, 1.0f};
        std::memcpy(comp, cv, sizeof comp);
        std::memcpy(core, cv, sizeof core);
        const float ev[6] = {-50.0f, 2.0f, -20.0f, 5.0f, 80.0f, 1.0f};
        std::memcpy(exp, ev, sizeof exp);
        const float bv[9] = {80, 0, 2, 3, 120, 0, 0, 0, 0};
        std::memcpy(bass, bv, sizeof bass);
        const float xv[8] = {90.0f, 0, 0, 1.0f, 0, 0, 100.0f, 0.7f};
        std::memcpy(xo, xv, sizeof xo);
        const float av[10] = {6.0f, 100, 0, 1, 1000, 0, 1, 8000, 0, 1};
        std::memcpy(amb, av, sizeof amb);
        st[n++] = stage(N60_STAGE_GAIN, 3, &gain, 1);
        st[n++] = stageLanes(N60_STAGE_CLEANUP, 12, 0, 1, 0, cleanup, 26);
        st[n++] = stage(N60_STAGE_PEQ, 2, peq, 8);
        st[n++] = stage(N60_STAGE_DYN_EQ, 5, dq, 16);
        st[n++] = stage(N60_STAGE_COMPRESSOR, 6, comp, 10);
        st[n++] = stage(N60_STAGE_EXPANDER, 7, exp, 6);
        st[n++] = stage(N60_STAGE_METER_OUT, 8, nullptr, 0);
        st[n++] = stageLanes(N60_STAGE_BASS_MGMT, 9, 0, 0, 0x3, bass, 9);
        st[n++] = stageLanes(N60_STAGE_STEREO_CROSSOVER, 10, 0, 1, 0, xo, 8);
        st[n++] = stage(N60_STAGE_AMBIENT, 11, amb, 10);
        st[n++] = stage(N60_STAGE_CORE_DYNAMICS, 13, core, 10);
        st[n++] = stage(N60_STAGE_DRIVER_FIR, 1, taps.data(), tapCount);
    }
};

// `apply` runs on both rigs just before the publish (a live parameter post, so a stage is mid-transition when the
// state is copied); `bm` is the same chain with a meter added. After the fade the output is bit-identical to a graph
// that was never rebuilt.
void testChainState(double rate, uint32_t blk, int post) {
    const uint32_t taps = 262144;
    Chain c(taps, 211);
    n60_stage_desc a[12], b[13];
    std::memcpy(a, c.st, sizeof a);
    std::memcpy(b, c.st, sizeof a);
    b[12] = stage(N60_STAGE_FINAL_METER, 14, nullptr, 0);
    Rig test(rate, 4, a, 12), ref(rate, 4, a, 12);
    runFrames(test, taps + 4096, blk);
    runFrames(ref, taps + 4096, blk);
    if (post != 0) {
        // 1: a PEQ section gain moves (crossfade between two biquads). 2: a dynamic EQ band's static gain moves (a
        // smoothed value mid-glide). Both are live; the rebuilt chain carries the new target.
        n60_param_record rec = post == 1 ? n60_param_record{2, 2, 3.0f, 0} : n60_param_record{5, 4, -9.0f, 0};
        CHECK(n60_graph_post_params(test.g, &rec, 1) == N60_STATUS_OK, "post");
        CHECK(n60_graph_post_params(ref.g, &rec, 1) == N60_STATUS_OK, "post ref");
        if (post == 1) c.peq[2] = 3.0f;
        else c.dq[4] = -9.0f;
        test.step(blk);
        ref.step(blk);
    }
    test.publish(b, 13, rate);
    test.step(blk);
    ref.step(blk);
    CHECK(test.status().state == 1, "rate %.0f block %u post %d chain: rebuild running", rate, blk, post);
    const uint32_t warming = finishRebuild(test, 4000000, blk);
    while (ref.pos < test.pos) ref.step(blk);
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f block %u post %d chain completed", rate, blk, post);
    CHECK(n60_graph_debug_carry_abandoned(test.g) == 0, "rate %.0f block %u post %d chain carry kept", rate, blk, post);
    CHECK(warming < taps / blk / 2, "rate %.0f block %u post %d chain carried, not warmed in full (%u)", rate, blk, post, warming);
    CHECK(n60_graph_debug_peak_rt_bytes(test.g) <= n60_graph_debug_rt_budget(blk), "rate %.0f block %u post %d chain peak", rate, blk, post);
    CHECK(compareRun(test, ref, 3ull * 16384, true, nullptr, blk) == 0.0, "rate %.0f block %u post %d chain output differs after carry",
          rate, blk, post);
}

// A stateful stage ahead of the FIR that cannot be carried (the denoiser, an upstream FIR carried lazily, or a state
// over the callback budget) refuses lockstep: the stage warms in full and the output is finite.
void testRefused(double rate, int what) {
    const uint32_t taps = 32768;
    std::vector<float> h = decaying(taps, 217, 0.02f), h2 = decaying(taps, 219, 0.02f);
    const float dn[9] = {1, 0, 0.5f, -60, 0, 0, 0, 0, 0};
    const float bass[9] = {80, 0, 2, 3, 120, 0, 0, 0, 0};
    uint32_t blk = kBlock;
    n60_stage_desc a[3], b[4];
    uint32_t na = 0;
    if (what == 0) {  // denoiser ahead of the program FIR
        a[na++] = stage(N60_STAGE_DENOISER, 4, dn, 9);
        a[na++] = stage(N60_STAGE_FIR, 1, h.data(), taps);
    } else if (what == 1) {  // program FIR ahead of a room FIR: the first is carried lazily, so it is not exact
        a[na++] = stage(N60_STAGE_FIR, 1, h.data(), taps);
        a[na++] = stage(N60_STAGE_ROOM_FIR, 2, h2.data(), taps);
    } else {  // bass management larger than a 4-frame block's 4 KiB budget
        blk = 4;
        a[na++] = stageLanes(N60_STAGE_BASS_MGMT, 9, 0, 0, 0x3, bass, 9);
        a[na++] = stage(N60_STAGE_ROOM_FIR, 2, h2.data(), taps);
    }
    for (uint32_t i = 0; i < na; ++i) b[i] = a[i];
    b[na] = stage(N60_STAGE_FINAL_METER, 14, nullptr, 0);
    const uint32_t ch = what == 2 ? 4 : 2;
    Rig test(rate, ch, a, na);
    runFrames(test, taps + 4096, blk);
    test.publish(b, na + 1, rate);
    test.step(blk);
    const uint32_t warming = finishRebuild(test, 4000000, blk);
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f refused %d completed", rate, what);
    CHECK(warming >= taps / blk, "rate %.0f refused %d warms in full (%u callbacks)", rate, what, warming);
    runFrames(test, 4 * 16384, blk);
    for (size_t i = 0; i < test.out.size(); ++i) CHECK(std::isfinite(test.out[i]), "rate %.0f refused %d finite output", rate, what);
}

// E9 S5 (G10): every other stateful kind ahead of a lazily carried FIR is named as refused. The FIR behind it warms in
// full next to the live instance (no lockstep carry), the rebuild completes, and the output is finite. Each kind sits
// ahead of the FIR kind that follows it in the stage order (ROUTE, XOVER and the pair stages ahead of the driver FIR,
// the generator, the external processor, image, loudness, de-ess and multiband ahead of the room FIR).
struct RefusedKind {
    const char *name;
    uint32_t kind;
    uint32_t firKind;
};
constexpr RefusedKind kRefusedKinds[] = {
    {"SYMMETRY", N60_STAGE_SYMMETRY, N60_STAGE_DRIVER_FIR},   {"CROSSFEED", N60_STAGE_CROSSFEED, N60_STAGE_DRIVER_FIR},
    {"CROSSTALK", N60_STAGE_CROSSTALK, N60_STAGE_DRIVER_FIR}, {"HEADPHONE", N60_STAGE_HEADPHONE, N60_STAGE_DRIVER_FIR},
    {"PAUSE_GATE", N60_STAGE_PAUSE_GATE, N60_STAGE_DRIVER_FIR}, {"ROUTE", N60_STAGE_ROUTE, N60_STAGE_DRIVER_FIR},
    {"XOVER", N60_STAGE_XOVER, N60_STAGE_DRIVER_FIR},         {"GENERATOR", N60_STAGE_GENERATOR, N60_STAGE_ROOM_FIR},
    {"EXTERNAL", N60_STAGE_EXTERNAL, N60_STAGE_ROOM_FIR},     {"IMAGE", N60_STAGE_IMAGE, N60_STAGE_ROOM_FIR},
    {"LOUDNESS", N60_STAGE_LOUDNESS, N60_STAGE_ROOM_FIR},     {"DEESS", N60_STAGE_DEESS, N60_STAGE_ROOM_FIR},
    {"MULTIBAND", N60_STAGE_MULTIBAND, N60_STAGE_ROOM_FIR},
};

void testRefusedKind(double rate, size_t which) {
    const RefusedKind &k = kRefusedKinds[which];
    const uint32_t taps = 32768;
    std::vector<float> h = decaying(taps, 223, 0.02f);
    const float sym[1] = {0.2f}, cf[1] = {0.2f}, ct[2] = {900, 0.3f}, gate[5] = {-90, 6, 10, 5, 5};
    const float hp[11] = {-1, 0.5f, 45, 0.09f, 700, 0, 0, 0, 0, 0, 0};
    const float gen[11] = {1, -20, -6, 1000, 1000, 4000, 4096, 1, 1, 1, 600};
    const float ext[1] = {0};
    const float img[8] = {0, 1, 0, 200, 4000, 1, 1.5f, 1.4f};
    const float de[12] = {1, 3500, -3, 1, 6500, -40, 4, -24, 2, 1, 50, 1};
    const float loud[32] = {1, 0, -16, 10, 0.5f, 2, 1, 0.6f, 1, 0, 80, 12, 3, 1, 1, 0, 300, 3500, 6, 3, 9, 200, 80, 600,
                            -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f};
    const float mb[29] = {1, 120, 2500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    float route[16];
    for (int i = 0; i < 16; ++i) route[i] = (i & 1) ? 0.0f : -1.0f;
    route[0] = 0.0f;
    route[1] = 0.5f;
    const float xo[14] = {3, 0, 100, 3, 0, 1000, 0, 0, 0, 50, 0.707f, 25, 0.5f, 0};
    n60_stage_desc up;
    switch (k.kind) {
        case N60_STAGE_SYMMETRY: up = stageLanes(k.kind, 4, 0, 1, 0, sym, 1); break;
        case N60_STAGE_CROSSFEED: up = stageLanes(k.kind, 4, 0, 1, 0, cf, 1); break;
        case N60_STAGE_CROSSTALK: up = stageLanes(k.kind, 4, 0, 1, 0, ct, 2); break;
        case N60_STAGE_HEADPHONE: up = stageLanes(k.kind, 4, 0, 1, 0, hp, 11); break;
        case N60_STAGE_PAUSE_GATE: up = stageLanes(k.kind, 4, 0, 0, 0x3, gate, 5); break;
        case N60_STAGE_ROUTE: up = stageLanes(k.kind, 4, 0, 0, 1u << 1, route, 16); break;
        case N60_STAGE_XOVER: up = stage(k.kind, 4, xo, 14); break;
        case N60_STAGE_GENERATOR: up = stage(k.kind, 4, gen, 11); break;
        case N60_STAGE_EXTERNAL: up = stageLanes(k.kind, 4, 0, 0, 0x3, ext, 1); break;
        case N60_STAGE_IMAGE: up = stageLanes(k.kind, 4, 0, 1, 0, img, 8); break;
        case N60_STAGE_LOUDNESS: up = stageLanes(k.kind, 4, 0, 1, 0, loud, 32); break;
        case N60_STAGE_DEESS: up = stageLanes(k.kind, 4, 0, 1, 0, de, 12); break;
        default: up = stageLanes(k.kind, 4, 0, 1, 0, mb, 29); break;
    }
    n60_stage_desc a[2], b[3];
    a[0] = up;
    a[1] = stage(k.firKind, 1, h.data(), taps);
    b[0] = a[0];
    b[1] = a[1];
    b[2] = stage(N60_STAGE_FINAL_METER, 14, nullptr, 0);
    const uint32_t blk = kBlock;
    Rig test(rate, 4, a, 2);
    runFrames(test, taps + 4096, blk);
    test.publish(b, 3, rate);
    test.step(blk);
    const uint32_t warming = finishRebuild(test, 4000000, blk);
    CHECK(test.status().completed == 1 && test.status().lastResult == 1, "rate %.0f %s completed", rate, k.name);
    CHECK(warming >= taps / blk, "rate %.0f %s refused: FIR warms in full (%u callbacks)", rate, k.name, warming);
    runFrames(test, 4 * 16384, blk);
    for (size_t i = 0; i < test.out.size(); ++i) CHECK(std::isfinite(test.out[i]), "rate %.0f %s finite output", rate, k.name);
}

}  // namespace

int main() {
    for (double rate : kRates) {
        testCarryIdentical(rate, 2, false);
        testCarryIdentical(rate, 8, false);
        testCarryIdentical(rate, 8, true);
        testSeed(rate);
        testUpstreamChanged(rate);
        testSameTapsUpstreamChanged(rate);
        testInterrupted(rate, true);
        testInterrupted(rate, false);
        testReset(rate, false);
        testReset(rate, true);
        testClick(rate);
        testNoFadeSync(rate);
        testNoFadeDeferred(rate);
        testNoFadeTooLargeMoved(rate);
        testUpstreamState(rate, kBlock);
        testSmallBlocks(rate, 2, 32);
        testSmallBlocks(rate, 2, 48);
        testStaleSource(rate);
        testUpstreamPost(rate, true);
        testUpstreamPost(rate, false);
        testChainState(rate, kBlock, 0);
        testChainState(rate, kBlock, 1);
        testChainState(rate, 32, 1);
        testChainState(rate, 32, 2);
        testRefused(rate, 0);
        testRefused(rate, 1);
        testRefused(rate, 2);
        for (size_t w = 0; w < sizeof kRefusedKinds / sizeof kRefusedKinds[0]; ++w) testRefusedKind(rate, w);
        std::printf("rate %.0f done\n", rate);
    }
    testSmallBlocks(384000, 8, 32);
    testUpstreamState(384000, 32);
    testUpstreamState(384000, 48);
    testCpuRefusal(48000);
    if (failures != 0) {
        std::printf("test_conv_rebuild: %d failures\n", failures);
        return 1;
    }
    std::printf("test_conv_rebuild ok\n");
    return 0;
}
