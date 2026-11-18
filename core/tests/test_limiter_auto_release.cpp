// E33 S14 at the eight standard rates (graph ABI v46): the limiter's programme-dependent release. The PROTECTION stage's trailing
// word has bit 2 (value 4) set. Checks: off (bit clear) is bit-identical to the 7-value block; a single peak recovers at about the
// fast time; sustained over-level recovers several times slower; the slow state shows in n60_dynamics_readback.effectiveReleaseMs;
// the 50 Hz harmonic distortion under heavy limiting is lower than with the fastest fixed release (5 ms); the ceiling and the
// true-peak guard hold with auto release on; a word above 7 and old block sizes behave.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate, double a = 0, double b = 0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f (%g, %g)\n", what, rate, a, b); ++failures; }
}
using Vec = std::vector<float>;

n60_graph *build(double rate, const float *params, uint32_t count, n60_status *status = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_PROTECTION;
    s.stageId = 5;
    s.laneA = N60_LANE_ALL;
    s.params = params;
    s.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    const n60_status st = n60_graph_build(&d, &g);
    if (status != nullptr) *status = st;
    return st == N60_STATUS_OK ? g : nullptr;
}

// Both lanes carry `in`; lane 0's output lands in `out`.
void run(n60_graph *g, const Vec &in, Vec &out) {
    static Vec spare(1 << 16);
    out.assign(in.size(), 0.0f);
    for (size_t off = 0; off < in.size(); off += 512) {
        const uint32_t n = (uint32_t)std::min<size_t>(512, in.size() - off);
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {out.data() + off, spare.data()};
        n60_graph_process(g, ip, op, n);
    }
}

n60_dynamics_readback readback(n60_graph *g) {
    n60_dynamics_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_dynamics(g, 5, 0, &rb);
    return rb;
}

// Limiter: ceiling -12 dB (0.2512), attack 0.5 ms, look-ahead 2 ms, guard off, factor 1; `rel` is the fixed release, `word` the
// trailing word (negative: the 7-value block).
n60_graph *limiter(double rate, float rel, int word) {
    const float p[8] = {1, -12, 0.5f, rel, 2, 0, 1, (float)word};
    return build(rate, p, word < 0 ? 7 : 8);
}

// Seconds from the end of the loud part until the DC output has recovered 95% of the reduction it had at that point.
double recoverySeconds(double rate, int word, double loudSeconds, float loud) {
    const float base = 0.1f;
    const size_t loudN = (size_t)(loudSeconds * rate), warm = (size_t)(0.2 * rate), tail = (size_t)(2.5 * rate);
    Vec in(warm + loudN + tail, base), out;
    for (size_t i = warm; i < warm + loudN; ++i) in[i] = loud;
    n60_graph *g = limiter(rate, 100.0f, word);
    run(g, in, out);
    n60_graph_retire(g);
    // Latency: the look-ahead (2 ms) shifts the output; find the gain at the end of the loud part and after the tail.
    const size_t lat = (size_t)(0.002 * rate) + 8;
    const size_t endLoud = warm + loudN + lat;
    const double g0 = out[endLoud - 4 * lat] / loud;  // reduction while loud
    (void)g0;
    const double gStart = std::min(1.0, (double)out[endLoud + (size_t)(0.0005 * rate)] / base);
    const double target = gStart + 0.95 * (1.0 - gStart);
    for (size_t i = endLoud; i < in.size(); ++i) {
        if (out[i] / base >= target) return (double)(i - endLoud) / rate;
    }
    return 99.0;
}

void offIdentical(double rate) {
    Vec in((size_t)(0.5 * rate)), a, b;
    uint32_t seed = 7u;
    for (size_t i = 0; i < in.size(); ++i) {
        seed = seed * 1664525u + 1013904223u;
        in[i] = 1.2f * ((float)(seed >> 8) / 8388608.0f - 1.0f) * std::sin(2.0 * M_PI * 3.0 * (double)i / rate);
    }
    n60_graph *g7 = limiter(rate, 80.0f, -1), *g0 = limiter(rate, 80.0f, 0), *g3 = limiter(rate, 80.0f, 3);
    Vec c;
    run(g7, in, a);
    run(g0, in, b);
    run(g3, in, c);
    check(a == b, "word 0 is bit-identical to the 7-value block", rate);
    check(a != Vec() && a.size() == c.size(), "word 3 renders", rate);
    // Fixed release: word 3 (no auto) equals word 0 apart from the attack cap, which changes nothing at 0.5 ms attack > 2 ms? (attack
    // is below the look-ahead here), so the render is identical too.
    check(b == c, "word 3 (auto clear) equals word 0 when the attack is below the look-ahead", rate);
    n60_graph_retire(g7);
    n60_graph_retire(g0);
    n60_graph_retire(g3);
}

void recovery(double rate) {
    const double single = recoverySeconds(rate, 7, 0.003, 0.5f);
    const double fixedSlow = recoverySeconds(rate, 3, 0.003, 0.5f);  // fixed 100 ms release
    const double sustained = recoverySeconds(rate, 7, 3.0, 0.5f);
    check(single > 0.03 && single < 0.12, "a single peak recovers within about four fast time constants", rate, single, 0.12);
    check(single < fixedSlow, "a single peak recovers faster than the 100 ms fixed release", rate, single, fixedSlow);
    check(sustained > 2.5 * single, "sustained over-level recovers several times slower than a single peak", rate, sustained, single);
    check(sustained > 0.2 && sustained < 1.2, "sustained recovery is in the slow range", rate, sustained, 0.2);
}

void readbackTimes(double rate) {
    Vec in((size_t)(3.5 * rate), 0.5f), out;
    n60_graph *g = limiter(rate, 100.0f, 7);
    run(g, in, out);
    const n60_dynamics_readback held = readback(g);
    check(held.effectiveReleaseMs > 250.0f && held.effectiveReleaseMs <= 400.5f, "held limiting reads a slow effective release", rate,
          held.effectiveReleaseMs, 400);
    n60_graph_retire(g);
    Vec shortIn((size_t)(0.5 * rate), 0.1f);
    for (size_t i = (size_t)(0.2 * rate); i < (size_t)(0.2 * rate) + (size_t)(0.002 * rate); ++i) shortIn[i] = 0.5f;
    g = limiter(rate, 100.0f, 7);
    run(g, shortIn, out);
    const n60_dynamics_readback single = readback(g);
    check(single.effectiveReleaseMs >= 29.9f && single.effectiveReleaseMs < 45.0f, "a single peak reads about the fast time", rate,
          single.effectiveReleaseMs, 30);
    n60_graph_retire(g);
    g = limiter(rate, 100.0f, 3);
    run(g, in, out);
    check(readback(g).effectiveReleaseMs == 0.0f, "fixed release reads 0", rate);
    n60_graph_retire(g);
}

// Energy outside the 50 Hz fundamental over the last 25 periods, relative to the fundamental.
double distortion(const Vec &out, double rate) {
    const size_t period = (size_t)std::llround(rate / 50.0), n = 25 * period, from = out.size() - n;
    double sc = 0, ss = 0, tot = 0;
    for (size_t i = 0; i < n; ++i) {
        const double ph = 2.0 * M_PI * 50.0 * (double)i / rate, v = out[from + i];
        sc += v * std::cos(ph);
        ss += v * std::sin(ph);
        tot += v * v;
    }
    const double fund = 2.0 * (sc * sc + ss * ss) / (double)n;  // sum of squares of the fundamental component
    const double resid = std::max(0.0, tot - fund);
    return std::sqrt(resid / std::max(fund, 1e-30));
}

void lowFrequencyDistortion(double rate) {
    Vec in((size_t)(2.0 * rate)), a, b;
    for (size_t i = 0; i < in.size(); ++i) in[i] = 0.7f * std::sin(2.0 * M_PI * 50.0 * (double)i / rate);
    n60_graph *gf = limiter(rate, 5.0f, 3), *ga = limiter(rate, 5.0f, 7);
    run(gf, in, a);
    run(ga, in, b);
    n60_graph_retire(gf);
    n60_graph_retire(ga);
    const double fixedD = distortion(a, rate), autoD = distortion(b, rate);
    check(autoD < 0.8 * fixedD, "auto release lowers 50 Hz distortion under limiting versus the 5 ms fixed release", rate, autoD, fixedD);
}

// 4x reference true peak of x over [from, to).
double referencePeak(const Vec &x, size_t from, size_t to) {
    double peak = 0;
    const int K = 48;
    for (size_t i = from; i < to; ++i) {
        for (int q = 0; q < 4; ++q) {
            const double frac = 0.25 * q;
            double acc = 0;
            for (int k = -K; k <= K; ++k) {
                const double t = (double)k - frac;
                const double sinc = std::fabs(t) < 1e-12 ? 1.0 : std::sin(M_PI * t) / (M_PI * t);
                const double w = 0.5 + 0.5 * std::cos(M_PI * t / (K + 1));
                acc += (double)x[i + k] * sinc * w;
            }
            peak = std::max(peak, std::fabs(acc));
        }
    }
    return peak;
}

void ceilingAndGuard(double rate) {
    const size_t n = (size_t)(0.6 * rate);
    Vec in(n), out;
    uint32_t seed = 99u;
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = ((double)(seed >> 8) / 8388608.0 - 1.0) * 0.05;
        in[i] = (float)(0.8 * std::sin(2.0 * M_PI * 0.2493 * rate * (double)i / rate) + noise + 0.4 * std::sin(2.0 * M_PI * 60.0 * (double)i / rate));
    }
    // Sample-peak case: guard off, factor 1, ceiling -6 dB.
    const float noGuard[8] = {1, -6, 1, 100, 2, 0, 1, 7};
    n60_graph *g = build(rate, noGuard, 8);
    run(g, in, out);
    n60_graph_retire(g);
    float peak = 0;
    for (size_t i = (size_t)(0.05 * rate); i < n; ++i) peak = std::max(peak, std::fabs(out[i]));
    check(peak <= 0.501188f * 1.0005f, "sample peak stays at the ceiling with auto release", rate, peak, 0.501188);
    // True-peak guard on (rate-based factor): the 4x reference peak within 0.6 dB of the ceiling.
    const float guard[8] = {1, -6, 1, 100, 2, 1, 4, 7};
    g = build(rate, guard, 8);
    run(g, in, out);
    const n60_dynamics_readback rb = readback(g);
    n60_graph_retire(g);
    const double tp = referencePeak(out, (size_t)(0.3 * rate), (size_t)(0.3 * rate) + 2000);
    check(tp <= 0.501188 * 1.0715, "true peak holds within 0.6 dB with auto release", rate, tp, 0.501188 * 1.0715);
    check(rb.guardActive == 1u || rate >= 176399, "guard reported", rate, rb.guardActive);
}

void blocks(double rate) {
    n60_status st = N60_STATUS_OK;
    const float seven[7] = {1, -6, 1, 100, 2, 0, 1};
    const float eighteen[18] = {1, -6, 1, 100, 2, 0, 1, 0, 0, -1.5f, 0.5f, 0, 0, 0, 0, 3, 6, 1};
    float withWord[19];
    std::memcpy(withWord, eighteen, sizeof eighteen);
    withWord[18] = 7;
    n60_graph *g = build(rate, seven, 7, &st);
    check(g != nullptr, "7-value block builds", rate);
    if (g) n60_graph_retire(g);
    g = build(rate, eighteen, 18, &st);
    check(g != nullptr, "18-value block builds", rate);
    if (g) n60_graph_retire(g);
    g = build(rate, withWord, 19, &st);
    check(g != nullptr, "19-value block with auto release builds", rate);
    if (g) n60_graph_retire(g);
    float bad[8] = {1, -6, 1, 100, 2, 0, 1, 8};
    g = build(rate, bad, 8, &st);
    check(g == nullptr && st != N60_STATUS_OK, "a word above 7 is refused", rate);
    if (g) n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        offIdentical(rate);
        recovery(rate);
        readbackTimes(rate);
        lowFrequencyDistortion(rate);
        ceilingAndGuard(rate);
        blocks(rate);
    }
    if (failures) {
        std::fprintf(stderr, "n60core limiter auto release: %d failures\n", failures);
        return 1;
    }
    std::puts("n60core limiter auto release: ok");
    return 0;
}
