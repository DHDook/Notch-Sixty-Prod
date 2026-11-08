// E6 S12g2: N60_STAGE_LANE_DELAY (ABI v28), the lane delay that runs ahead of bass management, at the eight standard
// rates. The N-channel path delays a program lane before the crossover, so the bass sum carries the delay: with a lane
// delayed by d frames, every output (the high-passed main, the other main and the sub) equals the undelayed run with
// that lane's input delayed by d, bit for bit. The stage also reports its latency, takes a live frame change, and the
// chain order is enforced (it ranks before BASS_MGMT and after EXTERNAL; a DELAY stage may not precede it).
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f\n", what, rate); ++failures; }
}

constexpr uint32_t kBlock = 512;
constexpr uint32_t kChannels = 3;  // main 0, main 1, sub 2

n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t lane, uint64_t mask, const float *p, uint32_t count, uint32_t capacity = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = lane;
    s.laneMask = mask;
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
    d.inputChannels = d.outputChannels = kChannels;
    d.stages = st;
    d.stageCount = n;
    return n60_graph_build(&d, g);
}

using Lanes = std::vector<std::vector<float>>;

Lanes run(n60_graph *g, const Lanes &in) {
    const size_t total = in[0].size();
    Lanes out(kChannels, std::vector<float>(total));
    for (size_t off = 0; off < total; off += kBlock) {
        const uint32_t n = (uint32_t)std::fmin((double)kBlock, (double)(total - off));
        const float *ip[kChannels];
        float *op[kChannels];
        for (uint32_t c = 0; c < kChannels; ++c) { ip[c] = in[c].data() + off; op[c] = out[c].data() + off; }
        n60_graph_process(g, ip, op, n);
    }
    return out;
}

Lanes signal(size_t frames, double rate) {
    Lanes in(kChannels, std::vector<float>(frames, 0.0f));
    uint32_t s = 4242u;
    for (size_t i = 0; i < frames; ++i) {
        s = s * 1664525u + 1013904223u;
        in[0][i] = 0.3f * (float)std::sin(2.0 * M_PI * 60.0 * (double)i / rate) +
                   0.1f * ((float)((s >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        s = s * 1664525u + 1013904223u;
        in[1][i] = 0.2f * (float)std::sin(2.0 * M_PI * 1500.0 * (double)i / rate) +
                   0.1f * ((float)((s >> 8) & 0xFFFF) / 65536.0f - 0.5f);
    }
    return in;
}

// The graph: meters in/out, optional lane delay on lane `delayLane` (frames > 0), BASS_MGMT on lanes 0 and 1 -> sub 2.
bool makeGraph(double rate, uint32_t delayLane, uint32_t frames, n60_graph **g) {
    static const float bm[9] = {80, 0, 2, -1, 120, 0, 0, 0, 0};
    static float dl[1];
    dl[0] = (float)frames;
    n60_stage_desc st[3];
    uint32_t n = 0;
    if (frames > 0) st[n++] = stage(N60_STAGE_LANE_DELAY, 10, delayLane, 0, dl, 1, 4096);
    st[n++] = stage(N60_STAGE_BASS_MGMT, 20, 0, 0x3, bm, 9);
    return build(rate, st, n, g) == N60_STATUS_OK;
}

void testExactShift(double rate, uint32_t lane) {
    const uint32_t d = 37;
    const size_t frames = 6000;
    Lanes in = signal(frames, rate);
    n60_graph *ref = nullptr, *delayed = nullptr;
    check(makeGraph(rate, lane, 0, &ref) && makeGraph(rate, lane, d, &delayed), "build", rate);
    if (!ref || !delayed) return;
    Lanes shifted = in;
    for (size_t i = 0; i < frames; ++i) shifted[lane][i] = i >= d ? in[lane][i - d] : 0.0f;
    const Lanes expect = run(ref, shifted);
    const Lanes got = run(delayed, in);
    bool exact = true;
    for (uint32_t c = 0; c < kChannels; ++c) {
        // Lane `lane` is delayed by d; the graph's initial ramp on the stage is already settled at frame 0 (built, not changed).
        exact = exact && std::memcmp(expect[c].data(), got[c].data(), frames * sizeof(float)) == 0;
    }
    check(exact, "lane delay ahead of the crossover equals the shifted input on every output", rate);
    check(n60_graph_latency_frames(delayed) == d, "reported latency is the lane delay", rate);
    n60_graph_retire(ref);
    n60_graph_retire(delayed);
}

void testOrder(double rate) {
    static const float bm[9] = {80, 0, 2, -1, 120, 0, 0, 0, 0};
    static const float one[1] = {4};
    n60_graph *g = nullptr;
    // After BASS_MGMT: rank violation.
    n60_stage_desc after[2] = {stage(N60_STAGE_BASS_MGMT, 1, 0, 0x3, bm, 9), stage(N60_STAGE_LANE_DELAY, 2, 0, 0, one, 1, 16)};
    check(build(rate, after, 2, &g) == N60_STATUS_BAD_ARGUMENT, "lane delay after bass management rejected", rate);
    // A plain DELAY (rank 24) before it: rank violation.
    n60_stage_desc plain[2] = {stage(N60_STAGE_DELAY, 1, 0, 0, one, 1, 16), stage(N60_STAGE_LANE_DELAY, 2, 0, 0, one, 1, 16)};
    check(build(rate, plain, 2, &g) == N60_STATUS_BAD_ARGUMENT, "plain delay before the lane delay rejected", rate);
    // Capacity and parameter validation follow DELAY.
    static const float tooBig[1] = {32};
    n60_stage_desc big[1] = {stage(N60_STAGE_LANE_DELAY, 1, 0, 0, tooBig, 1, 16)};
    check(build(rate, big, 1, &g) == N60_STATUS_BAD_ARGUMENT, "delay beyond capacity rejected", rate);
    // Both together in rank order (lane delay, bass, plain delay for the sub) build.
    n60_stage_desc both[3] = {stage(N60_STAGE_LANE_DELAY, 1, 0, 0, one, 1, 16), stage(N60_STAGE_BASS_MGMT, 2, 0, 0x3, bm, 9),
                              stage(N60_STAGE_DELAY, 3, 2, 0, one, 1, 16)};
    check(build(rate, both, 3, &g) == N60_STATUS_OK, "lane delay, bass management, sub delay build", rate);
    if (g) n60_graph_retire(g);
}

void testLive(double rate) {
    n60_graph *g = nullptr;
    check(makeGraph(rate, 0, 64, &g), "live build", rate);
    if (!g) return;
    Lanes in = signal(4000, rate);
    run(g, in);
    n60_param_record rec;
    std::memset(&rec, 0, sizeof rec);
    rec.stageId = 10;
    rec.paramIndex = 0;
    rec.value = 100.0f;
    check(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "live frame change accepted", rate);
    run(g, in);
    check(n60_graph_latency_frames(g) == 100, "latency follows the live change", rate);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        testExactShift(rate, 0);
        testExactShift(rate, 1);
        testOrder(rate);
        testLive(rate);
    }
    if (failures == 0) std::printf("lane delay: ok\n");
    return failures == 0 ? 0 : 1;
}
