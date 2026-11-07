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
constexpr uint64_t kBudget = 256 * 1024;  // graph.cpp kRtBudgetBytes

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
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK && g != nullptr, "build");
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

void runFrames(Rig &r, uint64_t frames) {
    for (uint64_t done = 0; done < frames; done += kBlock) r.step();
}

bool sameBits(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

// Renders `test` and `ref` in step for `frames`; returns the largest |test - ref|, ignoring blocks whose
// rebuild state was not idle at the end of the block when `idleOnly`.
double compareRun(Rig &test, Rig &ref, uint64_t frames, bool idleOnly, uint32_t *callbacks = nullptr) {
    double worst = 0;
    for (uint64_t done = 0; done < frames; done += kBlock) {
        test.step();
        ref.step();
        if (callbacks != nullptr) ++*callbacks;
        if (idleOnly && test.status().state != 0) continue;
        for (size_t i = 0; i < test.out.size(); ++i) worst = std::max<double>(worst, std::fabs(test.out[i] - ref.out[i]));
    }
    return worst;
}

// Drives the rebuild to the end, returning the callbacks spent warming (state 1) and the peak budget used.
uint32_t finishRebuild(Rig &r, uint32_t limit = 200000) {
    uint32_t warming = 0, n = 0;
    while (r.status().state != 0 && n++ < limit) {
        r.step();
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

// ---- 5. No fade: the whole copy is synchronous up to the uniform cap. ------------------------------------------

void testNoFadeCarry(double rate) {
    const uint32_t taps = 32768;
    std::vector<float> h = decaying(taps, 61, 0.02f);
    const float unity = 1.0f;
    n60_stage_desc a[1] = {stage(N60_STAGE_FIR, 1, h.data(), taps)};
    n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 2, &unity, 1), a[0]};
    Rig test(rate, 2, a, 1), ref(rate, 2, a, 1);
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    CHECK(n60_graph_set_rebuild_options(test.g, &o) == N60_STATUS_OK, "options");
    runFrames(test, taps + 4096);
    runFrames(ref, taps + 4096);
    test.publish(b, 2, rate);
    CHECK(compareRun(test, ref, 4 * 16384, false) == 0.0, "rate %.0f instant swap keeps the filter running", rate);
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
        testNoFadeCarry(rate);
        std::printf("rate %.0f done\n", rate);
    }
    testCpuRefusal(48000);
    if (failures != 0) {
        std::printf("test_conv_rebuild: %d failures\n", failures);
        return 1;
    }
    std::printf("test_conv_rebuild ok\n");
    return 0;
}
