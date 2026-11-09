// E6 S12h part 2b: N60_STAGE_DELTA_CAPTURE and N60_STAGE_DELTA_SUBTRACT (ABI v30), the delta audition, at the eight
// standard rates. Delta is the output minus the input delayed by the latency each lane has before the subtract:
//  - a unity chain gives exactly zero, a 0.5 gain gives exactly -0.5 times the aligned input, on both lanes, with a
//    delay on one lane only (so the two lanes have different latencies);
//  - the protection stage's lookahead and half-band latency are part of that alignment;
//  - the pair is validated (both or neither, same lanes, a ring that holds a block plus the lane latency, no live edit);
//  - a rebuild carries the ring (a published copy of the graph gives the same delta as one that was never rebuilt).
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
using Vec = std::vector<float>;

n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t lane, uint32_t laneB, const float *p, uint32_t count, uint32_t capacity = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = lane;
    s.laneB = laneB;
    s.params = p;
    s.paramCount = count;
    s.capacityFrames = capacity;
    return s;
}

n60_graph_desc desc(double rate, n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = n;
    return d;
}

const float kOne[1] = {1.0f};

// CAPTURE, GAIN(g), DELAY on lane 0 (d frames, 0 = none), SUBTRACT. Ring `cap` frames.
struct Chain {
    float gain = 1.0f;
    uint32_t delay0 = 0;
    bool protection = false;
    uint32_t cap = 4096;
    n60_stage_desc st[6];
    float gp[1], dp[1];
    float pp[7] = {1.0f, -6.0f, 1.0f, 50.0f, 2.0f, 0.0f, 2.0f};
    uint32_t n = 0;
    n60_graph_desc make(double rate) {
        gp[0] = gain;
        dp[0] = (float)delay0;
        n = 0;
        st[n++] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, cap);
        st[n++] = stage(N60_STAGE_GAIN, 2, N60_LANE_ALL, 0, gp, 1);
        if (delay0 > 0) st[n++] = stage(N60_STAGE_DELAY, 3, 0, 0, dp, 1, 64);
        if (protection) st[n++] = stage(N60_STAGE_PROTECTION, 4, N60_LANE_ALL, 0, pp, 7);
        st[n++] = stage(N60_STAGE_DELTA_SUBTRACT, 5, 0, 1, kOne, 1);
        return desc(rate, st, n);
    }
};

n60_graph *buildChain(double rate, Chain &c) {
    n60_graph_desc d = c.make(rate);
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return nullptr;
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    n60_graph_set_rebuild_options(g, &o);
    return g;
}

void signal(double rate, size_t from, size_t n, double freq, Vec &l, Vec &r) {
    l.resize(n);
    r.resize(n);
    for (size_t i = 0; i < n; ++i) {
        const double t = double(from + i) / rate;
        l[i] = 0.1f * (float)std::sin(2 * M_PI * freq * t) + 0.02f * (float)std::sin(2 * M_PI * 313.0 * t);
        r[i] = 0.08f * (float)std::sin(2 * M_PI * freq * 0.7 * t) + 0.03f * (float)std::cos(2 * M_PI * 97.0 * t);
    }
}

void process(n60_graph *g, const Vec &l, const Vec &r, Vec &ol, Vec &orr) {
    ol.resize(l.size());
    orr.resize(r.size());
    for (size_t off = 0; off < l.size(); off += kBlock) {
        const uint32_t n = (uint32_t)std::fmin((double)kBlock, (double)(l.size() - off));
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
}

double rms(const Vec &v, size_t from) {
    double a = 0;
    for (size_t i = from; i < v.size(); ++i) a += (double)v[i] * v[i];
    return std::sqrt(a / (double)(v.size() - from));
}

void testExact(double rate) {
    const uint32_t d = 37;
    const size_t frames = 6000;
    Vec l, r, ol, orr;
    signal(rate, 0, frames, 1000.0, l, r);
    Chain unity;
    unity.delay0 = d;
    n60_graph *g = buildChain(rate, unity);
    check(g != nullptr, "build unity", rate);
    if (!g) return;
    process(g, l, r, ol, orr);
    bool zero = true;
    for (size_t i = 0; i < frames; ++i) zero = zero && ol[i] == 0.0f && orr[i] == 0.0f;
    check(zero, "unity chain gives exactly zero on both lanes", rate);
    check(n60_graph_latency_frames(g) == d, "the pair adds no latency", rate);
    n60_graph_retire(g);

    Chain half;
    half.gain = 0.5f;
    half.delay0 = d;
    g = buildChain(rate, half);
    check(g != nullptr, "build half", rate);
    if (!g) return;
    process(g, l, r, ol, orr);
    bool exact = true;
    for (size_t i = 0; i < frames; ++i) {
        const float a = i >= d ? -0.5f * l[i - d] : 0.0f;
        exact = exact && ol[i] == a && orr[i] == -0.5f * r[i];
    }
    check(exact, "a 0.5 gain gives -0.5 times the lane-aligned input, lane 0 delayed", rate);
    n60_graph_retire(g);
}

// Protection's latency (half-band delay plus look-ahead) is part of the alignment. Without look-ahead the latency is a
// whole number of frames at every rate and the delta of an untouched signal is the half-band ripple only; with look-ahead
// the oversampled latency can be an odd number of half frames (a half-frame error is at most sin(pi f / fs) of the
// signal, 7 percent at 1 kHz and 44.1 kHz), and a whole frame of misalignment would be twice that.
void testProtectionLatency(double rate, float lookaheadMs, double limit) {
    const size_t frames = 24000;
    Vec l, r, ol, orr;
    signal(rate, 0, frames, 1000.0, l, r);
    Chain c;
    c.protection = true;
    c.cap = 8192;
    c.pp[4] = lookaheadMs;
    n60_graph *g = buildChain(rate, c);
    check(g != nullptr, "build protection", rate);
    if (!g) return;
    process(g, l, r, ol, orr);
    const uint32_t lat = n60_graph_latency_frames(g);
    check(lat > 0, "protection reports latency", rate);
    const size_t from = lat + 4096;
    check(from < frames, "test long enough", rate);
    const double sig = rms(l, from);
    const double res = rms(ol, from);
    check(res < limit * sig, lookaheadMs > 0.0f ? "delta through protection with look-ahead is aligned to within a half frame"
                                                : "delta through protection without look-ahead is the half-band ripple only", rate);
    n60_graph_retire(g);
}

void testValidation(double rate) {
    n60_stage_desc st[3];
    n60_graph *g = nullptr;
    const float zero[1] = {0.0f};
    st[0] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, 4096);
    n60_graph_desc d = desc(rate, st, 1);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a capture without a subtract is refused", rate);
    st[0] = stage(N60_STAGE_DELTA_SUBTRACT, 1, 0, 1, kOne, 1);
    d = desc(rate, st, 1);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a subtract without a capture is refused", rate);
    st[0] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, 4096);
    st[1] = stage(N60_STAGE_DELTA_SUBTRACT, 2, 1, 0, kOne, 1);
    d = desc(rate, st, 2);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a subtract on another pair is refused", rate);
    st[1] = stage(N60_STAGE_DELTA_SUBTRACT, 2, 0, 1, zero, 1);
    d = desc(rate, st, 2);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "params[0] must be 1", rate);
    st[0] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, 0);
    st[1] = stage(N60_STAGE_DELTA_SUBTRACT, 2, 0, 1, kOne, 1);
    d = desc(rate, st, 2);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a zero ring is refused", rate);
    st[0] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, kBlock - 1);
    d = desc(rate, st, 2);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a ring shorter than a block is refused", rate);
    // The ring must hold a block plus the lane latency: DELAY 37 on lane 0 needs kBlock + 37.
    float dp[1] = {37.0f};
    n60_stage_desc s3[3] = {stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, kBlock + 36), stage(N60_STAGE_DELAY, 2, 0, 0, dp, 1, 64),
                            stage(N60_STAGE_DELTA_SUBTRACT, 3, 0, 1, kOne, 1)};
    d = desc(rate, s3, 3);
    check(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "a ring one frame short of block plus latency is refused", rate);
    s3[0] = stage(N60_STAGE_DELTA_CAPTURE, 1, 0, 1, kOne, 1, kBlock + 37);
    d = desc(rate, s3, 3);
    check(n60_graph_build(&d, &g) == N60_STATUS_OK, "a ring of exactly block plus latency builds", rate);
    if (!g) return;
    n60_param_record rec = {3, 0, 1.0f, 0};
    check(n60_graph_post_params(g, &rec, 1) != N60_STATUS_OK, "the subtract takes no live edit", rate);
    // A live delay edit would misalign the subtraction (the ring delay is fixed at build time): it rebuilds instead.
    n60_param_record delayEdit = {2, 0, 5.0f, 0};
    check(n60_graph_post_params(g, &delayEdit, 1) != N60_STATUS_OK, "a live delay edit under a delta audition is refused", rate);
    n60_graph_retire(g);
}

// A rebuild starts the DELAY stage cold (its own history is not carried), so the first 37 frames after a swap have a
// silent processed lane; the delta there is minus the aligned input, which only a carried ring can supply (a cold ring
// would give 0). From frame 37 on the swapped graph equals one that was never rebuilt, bit for bit; lane 1 has no latency
// and matches throughout.
void testCarry(double rate, uint32_t newCap) {
    const uint32_t d = 37;
    const size_t pre = 5 * kBlock, post = 3 * kBlock;
    Vec l1, r1, l2, r2, a1, b1, a2, b2, c1, d1, c2, d2;
    signal(rate, 0, pre, 1000.0, l1, r1);
    signal(rate, pre, post, 1000.0, l2, r2);
    Chain c;
    c.gain = 0.5f;
    c.delay0 = d;
    c.cap = 4096;
    n60_graph *swap = buildChain(rate, c), *ref = buildChain(rate, c);
    check(swap && ref, "build carry", rate);
    if (!swap || !ref) return;
    process(swap, l1, r1, a1, b1);
    process(ref, l1, r1, c1, d1);
    Chain next = c;
    next.cap = newCap;
    n60_graph_desc desc2 = next.make(rate);
    check(n60_graph_publish(swap, &desc2) == N60_STATUS_OK, "publish", rate);
    process(swap, l2, r2, a2, b2);
    process(ref, l2, r2, c2, d2);
    bool head = true, tail = true, lane1 = true;
    for (size_t i = 0; i < post; ++i) {
        if (i < d) head = head && a2[i] == -l1[pre + i - d];
        else tail = tail && a2[i] == c2[i];
        lane1 = lane1 && b2[i] == d2[i];
    }
    check(head, newCap == c.cap ? "after a rebuild the first frames use the carried ring" : "after a rebuild with another ring length the first frames use the carried ring", rate);
    check(tail && lane1, "after the delay refills the swapped graph equals the unswapped one", rate);
    n60_graph_retire(swap);
    n60_graph_retire(ref);
}
}  // namespace

int main() {
    static const double rates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0};
    for (double rate : rates) {
        testExact(rate);
        testProtectionLatency(rate, 0.0f, 0.002);
        testProtectionLatency(rate, 2.0f, 0.1);
        testValidation(rate);
        testCarry(rate, 4096);
        testCarry(rate, 2048);
    }
    if (failures == 0) std::printf("delta audition: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
