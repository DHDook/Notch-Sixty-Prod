// E26 S6a: the ANC stages with the sub lane as an actuator (design 7), through the C ABI at the eight standard rates.
//  1. Placement: ANC_INJECT lands after the output gain and before MUTE; the core rejects stages listed out of rank order.
//  2. Lane rules: single-lane stages reject masks and out-of-range lanes; capture takes a mask.
//  3. Three actuators (left main, right main, sub): a 50 Hz noise is cancelled at a model microphone by three
//     anti-noise sources, each injected on its own lane; the sub's source has its own room delay.
//  4. The unauthorised stage is silent, and the source lanes never reach an output.
//  5. The realtime call allocates nothing.
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
// Lanes: 0 left main, 1 right main, 2 sub, 3..5 anti-noise sources for lanes 0..2, 6 error microphone (capture only).
static const uint32_t kLanes = 7;

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

static n60_status build(double rate, const std::vector<n60_stage_desc> &st, n60_graph **g, uint32_t lanes = kLanes) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = lanes;
    d.stages = st.data();
    d.stageCount = static_cast<uint32_t>(st.size());
    return n60_graph_build(&d, g);
}

using Lanes = std::vector<std::vector<float>>;

static Lanes run(n60_graph *g, const Lanes &in, bool count = false) {
    const size_t n = in[0].size();
    Lanes out(in.size(), std::vector<float>(n, 0.0f));
    for (size_t at = 0; at < n; at += kBlock) {
        const uint32_t len = static_cast<uint32_t>(std::min<size_t>(kBlock, n - at));
        const float *ip[16];
        float *op[16];
        for (size_t l = 0; l < in.size(); l++) { ip[l] = in[l].data() + at; op[l] = out[l].data() + at; }
        if (count) { allocs = 0; armed = true; }
        n60_status st = n60_graph_process(g, ip, op, len);
        if (count) { armed = false; CHECK(allocs == 0, "realtime call allocated or freed %ld time(s)", allocs.load()); }
        CHECK(st == N60_STATUS_OK, "process status %d", static_cast<int>(st));
    }
    return out;
}

static double amplitude(const std::vector<float> &x, double rate, double hz, size_t span) {
    const size_t start = x.size() - span;
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < span; i++) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * (i + 0.5) / span);
        const double ph = 2.0 * kPi * hz * (start + i) / rate;
        re += w * x[start + i] * std::cos(ph);
        im += w * x[start + i] * std::sin(ph);
        wsum += w;
    }
    return 2.0 * std::sqrt(re * re + im * im) / wsum;
}

static std::vector<float> tone(size_t n, double rate, double hz, double level, double phase = 0.0) {
    std::vector<float> t(n);
    for (size_t i = 0; i < n; i++) t[i] = static_cast<float>(level * std::sin(2.0 * kPi * hz * i / rate + phase));
    return t;
}

static void testPlacementAndAuthorisation() {
    for (double rate : kRates) {
        const float og = 0.5f, mute0 = 0.0f, mute1 = 1.0f;
        const float auth[3][3] = {{3, 1, 0}, {4, 1, 0}, {5, 1, 0}}, off[3][3] = {{3, 0, 0}, {4, 0, 0}, {5, 0, 0}};
        const size_t n = static_cast<size_t>(rate * 0.4);
        for (int mode = 0; mode < 3; mode++) {  // 0 authorised, 1 unauthorised, 2 authorised and muted
            // The core requires rank order: output gain (21), injects (26), mute (28).
            std::vector<n60_stage_desc> st = {stage(N60_STAGE_OUTPUT_GAIN, 30, 2, 0, &og, 1)};
            for (int k = 0; k < 3; k++) st.push_back(stage(N60_STAGE_ANC_INJECT, 10 + k, k, 0, mode == 1 ? off[k] : auth[k], 3));
            st.push_back(stage(N60_STAGE_MUTE, 20, N60_LANE_ALL, 0, mode == 2 ? &mute1 : &mute0, 1));
            {
                std::vector<n60_stage_desc> wrong = {st[4], st[1]};  // MUTE before INJECT
                n60_graph *w = nullptr;
                CHECK(build(rate, wrong, &w) != N60_STATUS_OK, "rate %.0f: stages out of rank order are rejected", rate);
            }
            n60_graph *g = nullptr;
            { n60_status bs = build(rate, st, &g); CHECK(bs == N60_STATUS_OK, "rate %.0f: placement build status %d", rate, static_cast<int>(bs)); }
            if (!g) continue;
            Lanes in(kLanes, std::vector<float>(n, 0.0f));
            in[2] = tone(n, rate, 50.0, 0.4);                  // programme on the sub lane
            for (int k = 0; k < 3; k++) in[3 + k] = tone(n, rate, 50.0, 0.2);  // anti-noise sources
            const Lanes out = run(g, in);
            const size_t span = n / 2;
            const double sub = amplitude(out[2], rate, 50.0, span);
            // Gain 0.5 on the programme (0.4 -> 0.2) is applied before the injection point; the anti-noise (0.2) adds on top.
            if (mode == 0) CHECK(std::fabs(sub - 0.4) < 0.01, "rate %.0f: sub lane programme 0.2 + anti-noise 0.2 = 0.4 (%.4f)", rate, sub);
            if (mode == 1) CHECK(std::fabs(sub - 0.2) < 0.01, "rate %.0f: unauthorised: programme only (%.4f)", rate, sub);
            if (mode == 2) CHECK(sub < 1e-4, "rate %.0f: MUTE follows the injection (%.5f)", rate, sub);
            for (int k = 0; k < 3; k++) {
                CHECK(amplitude(out[3 + k], rate, 50.0, span) == 0.0, "rate %.0f: source lane %d never reaches an output", rate, 3 + k);
                const double lane = amplitude(out[k], rate, 50.0, span);
                if (k < 2 && mode == 0) CHECK(std::fabs(lane - 0.2) < 0.01, "rate %.0f: main lane %d carries only its own source (%.4f)", rate, k, lane);
                if (k < 2 && mode == 1) CHECK(lane < 1e-6, "rate %.0f: unauthorised main lane %d silent (%.6f)", rate, k, lane);
            }
            n60_graph_retire(g);
        }
        (void)auth; (void)off;
    }
}

static void testLaneRules() {
    const double rate = 48000;
    const float inj[3] = {3, 1, 0};
    const float injBadSource[3] = {static_cast<float>(kLanes), 1, 0};
    const float injShort[2] = {3, 1};
    const float cap[1] = {1};
    n60_graph *g = nullptr;
    CHECK(build(rate, {stage(N60_STAGE_ANC_INJECT, 1, 2, 0, inj, 3)}, &g) == N60_STATUS_OK, "valid inject builds");
    if (g) n60_graph_retire(g);
    g = nullptr;
    CHECK(build(rate, {stage(N60_STAGE_ANC_INJECT, 1, static_cast<uint32_t>(kLanes), 0, inj, 3)}, &g) != N60_STATUS_OK, "target lane out of range");
    CHECK(build(rate, {stage(N60_STAGE_ANC_INJECT, 1, 2, 0, injBadSource, 3)}, &g) != N60_STATUS_OK, "source lane out of range");
    CHECK(build(rate, {stage(N60_STAGE_ANC_INJECT, 1, 2, 0, injShort, 2)}, &g) != N60_STATUS_OK, "two params rejected");
    CHECK(build(rate, {stage(N60_STAGE_ANC_INJECT, 1, 2, 0x4, inj, 3)}, &g) != N60_STATUS_OK, "inject takes one lane, not a mask");
    CHECK(build(rate, {stage(N60_STAGE_ANC_CAPTURE, 1, 0, 0x40, cap, 1, 1024)}, &g) == N60_STATUS_OK, "capture takes a mask");
    if (g) { n60_graph_retire(g); g = nullptr; }
    CHECK(build(rate, {stage(N60_STAGE_ANC_CAPTURE, 1, 0, 0x40, cap, 1, 0)}, &g) != N60_STATUS_OK, "capture needs a ring");
    const float guard[28] = {6, 6, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0,
                             -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100};
    CHECK(build(rate, {stage(N60_STAGE_ANC_GUARD, 1, 3, 0, guard, 28)}, &g) == N60_STATUS_OK, "guard on one source lane builds");
    if (g) { n60_graph_retire(g); g = nullptr; }
    CHECK(build(rate, {stage(N60_STAGE_ANC_GUARD, 1, 3, 0x8, guard, 28)}, &g) != N60_STATUS_OK, "guard takes one lane, not a mask");
}

// Three actuators cancel a 50 Hz noise at a model microphone. The sub's room path has its own delay and gain.
static void testThreeActuatorCancellation() {
    for (double rate : kRates) {
        const double hz = 50.0, noiseLevel = 0.1, w = 2.0 * kPi * hz;
        const double gain[3] = {0.8, 0.8, 1.5};
        const size_t subDelay = static_cast<size_t>(std::lround(0.005 * rate));
        const double tauSub = static_cast<double>(subDelay) / rate;
        const size_t n = static_cast<size_t>(rate * 1.0);
        // The sub carries half the correction, each main a quarter (the common-mode split of design 4).
        const double share[3] = {0.25, 0.25, 0.5};
        const double phase[3] = {kPi, kPi, kPi + w * tauSub};
        const float guard[28] = {6, 6, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0,
                                 -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100};
        const float cap[1] = {1};
        const float auth[3][3] = {{3, 1, 0}, {4, 1, 0}, {5, 1, 0}};
        std::vector<n60_stage_desc> st;
        for (int k = 0; k < 3; k++) st.push_back(stage(N60_STAGE_ANC_INJECT, 10 + k, k, 0, auth[k], 3));
        st.push_back(stage(N60_STAGE_ANC_CAPTURE, 20, 0, 0x7, cap, 1, static_cast<uint32_t>(n)));
        (void)guard;
        n60_graph *g = nullptr;
        CHECK(build(rate, st, &g) == N60_STATUS_OK, "rate %.0f: three-actuator build", rate);
        if (!g) continue;
        Lanes in(kLanes, std::vector<float>(n, 0.0f));
        for (int k = 0; k < 3; k++) in[3 + k] = tone(n, rate, hz, noiseLevel * share[k] / gain[k], phase[k]);
        const std::vector<float> noise = tone(n, rate, hz, noiseLevel);
        const Lanes out = run(g, in, true);
        std::vector<float> mic(n), before(n);
        for (size_t i = 0; i < n; i++) {
            double m = noise[i];
            m += gain[0] * out[0][i] + gain[1] * out[1][i];
            if (i >= subDelay) m += gain[2] * out[2][i - subDelay];
            mic[i] = static_cast<float>(m);
            before[i] = noise[i];
        }
        const size_t span = n / 2;
        const double residual = amplitude(mic, rate, hz, span), base = amplitude(before, rate, hz, span);
        const double reductionDb = 20.0 * std::log10(base / std::max(residual, 1e-12));
        CHECK(reductionDb > 40.0, "rate %.0f: three actuators cancel the noise by %.1f dB (need > 40)", rate, reductionDb);
        // With only the mains (no sub) the same sources would not cancel: the sub carries half the work.
        std::vector<float> noSub(n);
        for (size_t i = 0; i < n; i++) noSub[i] = static_cast<float>(noise[i] + gain[0] * out[0][i] + gain[1] * out[1][i]);
        CHECK(amplitude(noSub, rate, hz, span) > 0.3 * base, "rate %.0f: the sub lane is a real actuator", rate);
        // The capture ring holds the lanes as the stage saw them (after injection), 3 lanes.
        std::vector<float> ring(256);
        uint64_t written = 0;
        CHECK(n60_graph_read_capture(g, 20, 2, 0, ring.data(), 256, &written) == N60_STATUS_OK && written >= 256,
              "rate %.0f: capture ring readable on the sub lane", rate);
        n60_graph_retire(g);
    }
}

int main() {
    testPlacementAndAuthorisation();
    testLaneRules();
    testThreeActuatorCancellation();
    if (failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::puts("anc actuators: all checks passed");
    return 0;
}
