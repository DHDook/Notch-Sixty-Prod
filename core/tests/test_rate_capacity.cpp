// E7 S1: capacities are times. At the eight standard rates (and 384 kHz is the worst case): framesFor is
// ceil(seconds * rate); a 20 ms DELAY capacity holds its time and the impulse arrives on the requested frame; a 500 ms
// fractional delay split as DELAY (whole frames above 16) plus FRAC_DELAY has the requested delay within one frame and
// reports it as latency; a 20 ms protection look-ahead at 4x oversampling (30,720 oversampled frames at 384 kHz) builds
// and runs; a longer look-ahead than the 65,536-frame ring is refused.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"
#include "n60/rate_capacity.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.1f\n", what, rate); ++failures; }
}

constexpr uint32_t kBlock = 4096;
const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

n60_stage_desc stage(uint32_t kind, uint32_t id, const float *p, uint32_t count, uint32_t capacity = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneMask = 0;
    s.params = p;
    s.paramCount = count;
    s.capacityFrames = capacity;
    return s;
}

n60_status build(double rate, n60_stage_desc *st, uint32_t n, n60_graph **g) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 1;
    d.stages = st;
    d.stageCount = n;
    return n60_graph_build(&d, g);
}

// Index of the largest |sample| after feeding a unit impulse at frame 0 through `total` frames.
long impulseArrival(n60_graph *g, size_t total) {
    std::vector<float> in(total, 0.0f), out(total, 0.0f);
    in[0] = 1.0f;
    for (size_t off = 0; off < total; off += kBlock) {
        const uint32_t n = static_cast<uint32_t>(std::fmin(static_cast<double>(kBlock), static_cast<double>(total - off)));
        const float *ip[1] = {in.data() + off};
        float *op[1] = {out.data() + off};
        n60_graph_process(g, ip, op, n);
    }
    long best = -1;
    float peak = 0.0f;
    for (size_t i = 0; i < total; ++i) {
        if (std::fabs(out[i]) > peak) { peak = std::fabs(out[i]); best = static_cast<long>(i); }
    }
    return best;
}

void testFramesFor(double rate) {
    check(n60::framesFor(0.020, rate) == static_cast<uint32_t>(std::ceil(0.020 * rate)), "framesFor 20 ms", rate);
    check(n60::framesFor(0.0, rate) == 0u && n60::framesFor(-1.0, rate) == 0u && n60::framesFor(NAN, rate) == 0u,
          "framesFor non-positive and NaN is 0", rate);
    check(n60::framesFor(1.0e12, rate) == UINT32_MAX, "framesFor saturates", rate);
}

void testHeadphoneDelay(double rate) {
    const uint32_t cap = n60::framesFor(0.020, rate);
    const float p[1] = {static_cast<float>(cap)};
    n60_stage_desc st[1] = {stage(N60_STAGE_DELAY, 1, p, 1, cap)};
    n60_graph *g = nullptr;
    check(build(rate, st, 1, &g) == N60_STATUS_OK, "20 ms delay builds", rate);
    if (!g) return;
    check(impulseArrival(g, cap + 2048) == static_cast<long>(cap), "20 ms delay arrives on the requested frame", rate);
    check(n60_graph_latency_frames(g) == cap, "20 ms delay reports its latency", rate);
    n60_graph_retire(g);
}

void testFractionalSplit(double rate) {
    const uint32_t total = n60::framesFor(0.500, rate);
    const uint32_t whole = total - 16;  // all but the last 16 whole frames go to DELAY
    const float dp[1] = {static_cast<float>(whole)};
    const float fp[2] = {16.0f, 0.0f};
    n60_stage_desc st[2] = {stage(N60_STAGE_DELAY, 1, dp, 1, whole), stage(N60_STAGE_FRAC_DELAY, 2, fp, 2)};
    n60_graph *g = nullptr;
    check(build(rate, st, 2, &g) == N60_STATUS_OK, "500 ms split fractional delay builds", rate);
    if (!g) return;
    const long arrival = impulseArrival(g, total + 2048);
    check(std::labs(arrival - static_cast<long>(total)) <= 1, "500 ms split delay within one frame", rate);
    check(std::labs(static_cast<long>(n60_graph_latency_frames(g)) - static_cast<long>(total)) <= 1,
          "500 ms split delay reports its latency", rate);
    n60_graph_retire(g);
    // A single FRAC_DELAY past its ring is still refused: the Swift side must split.
    const float over[2] = {static_cast<float>(total), 0.0f};
    n60_stage_desc one[1] = {stage(N60_STAGE_FRAC_DELAY, 1, over, 2)};
    if (total > 8190) check(build(rate, one, 1, &g) == N60_STATUS_BAD_ARGUMENT, "unsplit long fractional delay refused", rate);
}

void testLookAhead(double rate) {
    // limiter on, ceiling -1 dB, attack 0.5 ms, release 90 ms, look-ahead 20 ms, true-peak on, 4x oversampling.
    const float p[7] = {1, -1, 0.5f, 90, 20, 1, 4};
    n60_stage_desc st[1] = {stage(N60_STAGE_PROTECTION, 1, p, 7)};
    n60_graph *g = nullptr;
    check(build(rate, st, 1, &g) == N60_STATUS_OK, "20 ms look-ahead at 4x builds", rate);
    if (g) {
        std::vector<float> in(kBlock, 0.1f), out(kBlock, 0.0f);
        const float *ip[1] = {in.data()};
        float *op[1] = {out.data()};
        check(n60_graph_process(g, ip, op, kBlock) == N60_STATUS_OK, "20 ms look-ahead at 4x runs", rate);
        n60_graph_retire(g);
    }
    check(n60::framesFor(0.020, rate * 4.0) <= 65536u, "20 ms at 4x fits the 65,536-frame ring", rate);
    // 1 s at 4x and 384 kHz is 1.5 M oversampled frames: far past the ring, so the core refuses it.
    const float huge[7] = {1, -1, 0.5f, 90, 1000, 1, 4};
    n60_stage_desc big[1] = {stage(N60_STAGE_PROTECTION, 1, huge, 7)};
    n60_graph *h = nullptr;
    if (n60::framesFor(1.0, rate * 4.0) > 65536u) {
        check(build(rate, big, 1, &h) != N60_STATUS_OK, "look-ahead past the ring is refused", rate);
        if (h) n60_graph_retire(h);
    }
}
}  // namespace

int main() {
    for (double rate : kRates) {
        testFramesFor(rate);
        testHeadphoneDelay(rate);
        testFractionalSplit(rate);
        testLookAhead(rate);
    }
    if (failures == 0) std::printf("rate capacity: all passed\n");
    return failures == 0 ? 0 : 1;
}
