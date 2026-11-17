// E33 S10 (graph ABI v44): the input-over detector at METER_IN, at the eight standard rates. Checks: the BS.1770-4 style
// inter-sample test signal (a sine at fs/4 phased 45 degrees: samples at 0.707 of the peak) counts overs while its sample peak
// stays below 0 dBFS at the 4x and 2x rates; at the 1x rates an audio-band sine at +1 dBTP counts overs; a -1 dBTP signal
// counts zero at every rate; detect 0 counts nothing and changes no output bit; the count survives a graph rebuild and is
// cleared only by the generation parameter.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include <atomic>
#include <cstdlib>
#include <new>

#include "n60/graph.h"

// Zero allocation: counting global allocators, armed around n60_graph_process only.
static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
void *operator new(std::size_t n) { if (armed.load()) allocs.fetch_add(1); return std::malloc(n ? n : 1); }
void *operator new[](std::size_t n) { if (armed.load()) allocs.fetch_add(1); return std::malloc(n ? n : 1); }
void operator delete(void *p) noexcept { if (p != nullptr && armed.load()) allocs.fetch_add(1); std::free(p); }
void operator delete[](void *p) noexcept { if (p != nullptr && armed.load()) allocs.fetch_add(1); std::free(p); }
void operator delete(void *p, std::size_t) noexcept { if (p != nullptr && armed.load()) allocs.fetch_add(1); std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { if (p != nullptr && armed.load()) allocs.fetch_add(1); std::free(p); }

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate, double a = 0, double b = 0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f (%g, %g)\n", what, rate, a, b); ++failures; }
}
using Vec = std::vector<float>;
constexpr uint32_t kStage = 7;

n60_stage_desc stage(const float *params, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_METER_IN;
    s.stageId = kStage;
    s.laneA = N60_LANE_ALL;
    s.params = params;
    s.paramCount = count;
    return s;
}

n60_graph_desc desc(double rate, n60_stage_desc *s) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = s;
    d.stageCount = 1;
    return d;
}

void run(n60_graph *g, const Vec &in, Vec &out) {
    static Vec spare(512);
    out.assign(in.size(), 0.0f);
    armed.store(true);
    for (size_t off = 0; off < in.size(); off += 512) {
        const uint32_t n = (uint32_t)std::min<size_t>(512, in.size() - off);
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {out.data() + off, spare.data()};
        n60_graph_process(g, ip, op, n);
    }
    armed.store(false);
}

uint64_t overs(n60_graph *g, uint32_t lane = 0) {
    uint64_t c = ~0ull;
    if (n60_graph_read_input_overs(g, kStage, lane, &c) != N60_STATUS_OK) return ~0ull;
    return c;
}

void post(n60_graph *g, uint32_t index, float value) {
    n60_param_record r = {kStage, index, value, 0};
    check(n60_graph_post_params(g, &r, 1) == N60_STATUS_OK, "post", 0, index, value);
}

n60_graph *build(double rate, const float *params, uint32_t count) {
    n60_stage_desc s = stage(params, count);
    n60_graph_desc d = desc(rate, &s);
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

constexpr double kPi = 3.14159265358979323846;

void atRate(double rate) {
    const size_t n = (size_t)(0.25 * rate);
    const uint32_t factor = rate >= 176399.0 ? 1u : (rate * 2.0 >= 176399.0 ? 2u : 4u);
    const float on[2] = {1, 0};
    n60_graph *g = build(rate, on, 2);
    check(g != nullptr, "build", rate);
    if (g == nullptr) return;
    Vec in(n), out;
    // 1. a -1 dBTP signal: zero overs. At 1x an audio-band tone, otherwise the fs/4 test signal.
    const double lo = std::pow(10.0, -1.0 / 20.0);
    for (size_t i = 0; i < n; ++i) {
        in[i] = factor > 1 ? (float)(lo * std::sin(0.5 * kPi * i + 0.25 * kPi)) : (float)(lo * std::sin(2 * kPi * 1000.0 * i / rate));
    }
    run(g, in, out);
    check(overs(g) == 0, "-1 dBTP counts zero", rate, (double)overs(g));
    // 2. +1.5 dBTP.
    const double hi = std::pow(10.0, 1.5 / 20.0);
    float samplePeak = 0.0f;
    for (size_t i = 0; i < n; ++i) {
        in[i] = factor > 1 ? (float)(hi * std::sin(0.5 * kPi * i + 0.25 * kPi)) : (float)(hi * std::sin(2 * kPi * 1000.0 * i / rate));
        samplePeak = std::max(samplePeak, std::fabs(in[i]));
    }
    if (factor > 1) check(samplePeak < 1.0f, "the test signal's sample peak is below 0 dBFS", rate, samplePeak);
    const uint64_t before = overs(g);
    run(g, in, out);
    const uint64_t counted = overs(g) - before;
    check(counted > 0, "an over above 0 dBTP is counted", rate, (double)counted);
    if (factor > 1) check(counted > n / 4, "the fs/4 test signal counts at its peaks", rate, (double)counted, (double)n);
    // 3. the other lane carries the same signal and counts the same.
    check(overs(g, 1) == overs(g, 0), "both lanes count", rate, (double)overs(g, 0), (double)overs(g, 1));
    // 4. a read never clears; a rebuild keeps the total.
    check(overs(g) == overs(g) && overs(g) > 0, "a read does not clear", rate);
    const uint64_t total = overs(g);
    n60_stage_desc s2 = stage(on, 2);
    n60_graph_desc d2 = desc(rate, &s2);
    check(n60_graph_publish(g, &d2) == N60_STATUS_OK, "publish", rate);
    Vec quiet(512, 0.0f);
    for (int i = 0; i < 40; ++i) run(g, quiet, out);
    check(overs(g) == total, "the count survives a rebuild", rate, (double)overs(g), (double)total);
    // 5. generation clears.
    post(g, 1, 1.0f);
    run(g, quiet, out);
    check(overs(g) == 0, "a new generation clears the count", rate, (double)overs(g));
    n60_graph_retire(g);
    // 6. detect 0 counts nothing and changes no output bit against a graph with no parameters.
    const float off[2] = {0, 0};
    n60_graph *a = build(rate, off, 2), *b = build(rate, nullptr, 0);
    Vec oa, ob;
    run(a, in, oa);
    run(b, in, ob);
    check(overs(a) == 0, "detect 0 counts nothing", rate, (double)overs(a));
    check(oa.size() == ob.size() && std::memcmp(oa.data(), ob.data(), oa.size() * sizeof(float)) == 0, "detect 0 is bit-identical", rate);
    check(std::memcmp(oa.data(), in.data(), oa.size() * sizeof(float)) == 0, "the audio is untouched", rate);
    // 7. a stage without parameters has no reading.
    uint64_t c;
    check(n60_graph_read_input_overs(b, kStage, 0, &c) != N60_STATUS_OK, "no reading without parameters", rate);
    // 8. switching detect on live starts counting.
    post(a, 0, 1.0f);
    run(a, in, oa);
    check(overs(a) > 0, "detect on starts counting", rate, (double)overs(a));
    // 9. out of range parameter is refused.
    n60_param_record bad = {kStage, 0, 2.0f, 0};
    check(n60_graph_post_params(a, &bad, 1) != N60_STATUS_OK, "detect 2 refused", rate);
    n60_graph_retire(a);
    n60_graph_retire(b);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double r : rates) atRate(r);
    check(allocs.load() == 0, "no allocation or free inside n60_graph_process", 0, (double)allocs.load());
    if (failures == 0) std::printf("input overs: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
