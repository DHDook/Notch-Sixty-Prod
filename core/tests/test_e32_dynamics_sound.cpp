// E32 S5 at the eight standard rates (graph ABI v43). Flag-on parameters are the trailing words the Swift translator publishes
// only with `e32.dynamics-sound`: the limiter's sound-fixes word (attack cap, rate-based true-peak factor) and the expander's
// timing swap. Checks: (R7) a 0 dBFS burst with the attack above the look-ahead hits the safety clamp 0 times with the cap and
// at least once without it; (R9) the expander opens at the Attack time with the swap and at the Release time without; (R12) the
// true-peak guard holds a 4x reference peak within 0.6 dB at each rate's factor and the latency report equals the measured
// delay; the extra words at 0 render bit-identically to the shorter blocks (flag off is today); (G8) a make-up edit moves the
// make-up-free reduction reading by no more than 0.1 dB.
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

n60_graph *build(double rate, uint32_t kind, const float *params, uint32_t count, uint32_t block = 512) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = 5;
    s.laneA = N60_LANE_ALL;
    s.params = params;
    s.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = block;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

// Both lanes carry `in`; the output of lane 0 lands in `out`.
void run(n60_graph *g, const Vec &in, Vec &out, size_t from, size_t to, uint32_t block = 512) {
    static Vec spare(1 << 16);
    if (out.size() < in.size()) out.resize(in.size());
    for (size_t off = from; off < to; off += block) {
        const uint32_t n = (uint32_t)std::min<size_t>(block, to - off);
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {out.data() + off, spare.data()};
        n60_graph_process(g, ip, op, n);
    }
}

uint32_t clampCount(n60_graph *g) {
    n60_dynamics_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    return n60_graph_read_dynamics(g, 5, 0, &rb) == N60_STATUS_OK ? rb.reserved : 0xFFFFFFFFu;
}

// R7: silence, then a full-scale burst through a -6 dB ceiling with a 20 ms attack and a short look-ahead.
void limiterBurst(double rate, float lookaheadMs) {
    const size_t n = (size_t)(0.3 * rate), at = (size_t)(0.1 * rate);
    Vec in(n, 0.0f), out(n);
    for (size_t i = at; i < at + (size_t)(0.05 * rate); ++i) in[i] = (i & 1) ? -1.0f : 1.0f;
    // limiter, ceiling -6, attack 20, release 100, look-ahead, true-peak 0, factor 1
    const float off[7] = {1, -6, 20, 100, lookaheadMs, 0, 1};
    const float on[8] = {1, -6, 20, 100, lookaheadMs, 0, 1, 3};
    n60_graph *a = build(rate, N60_STAGE_PROTECTION, off, 7);
    n60_graph *b = build(rate, N60_STAGE_PROTECTION, on, 8);
    run(a, in, out, 0, n);
    const uint32_t clampsOff = clampCount(a);
    Vec outOn(n);
    run(b, in, outOn, 0, n);
    const uint32_t clampsOn = clampCount(b);
    check(clampsOff > 0, "attack above the look-ahead needs the safety clamp without the cap", rate, clampsOff, lookaheadMs);
    check(clampsOn == 0, "the capped attack never reaches the safety clamp", rate, clampsOn, lookaheadMs);
    float peak = 0;
    for (float v : outOn) peak = std::max(peak, std::fabs(v));
    check(peak <= 0.501188f, "capped output stays under the ceiling", rate, peak, 0.501188);
    n60_graph_retire(a);
    n60_graph_retire(b);
}

// R9: DC input stepping from far below the threshold to far above it; the time to reach -1 dB.
double openingSeconds(double rate, float atk, float rel, float swap, uint32_t count) {
    float p[15] = {-40, 4, -60, atk, rel, 0, 0, 0, 0, 50, 0, 100, 0, 0, swap};
    n60_graph *g = build(rate, N60_STAGE_EXPANDER, p, count);
    const size_t warm = (size_t)(3.0 * rate), n = warm + (size_t)(1.6 * rate);
    Vec in(n, 0.001f), out(n);
    for (size_t i = warm; i < n; ++i) in[i] = 0.5f;
    run(g, in, out, 0, n);
    n60_graph_retire(g);
    for (size_t i = warm; i < n; ++i) {
        if (out[i] >= 0.5f * 0.891f) return (double)(i - warm) / rate;
    }
    return 99.0;
}

void expanderTiming(double rate) {
    const double on = openingSeconds(rate, 5, 200, 1, 15), off = openingSeconds(rate, 5, 200, 0, 15);
    const double on20 = openingSeconds(rate, 20, 200, 1, 15);
    check(on < 0.05, "swapped expander opens at the Attack time", rate, on, 0.05);
    check(off > 0.3, "unswapped expander opens at the Release time", rate, off, 0.3);
    check(on20 > 2.5 * on && on20 < 5.5 * on, "opening time follows Attack", rate, on20, on);
    // The 14-value block is today's mapping: same opening time as the 15-value block with the swap off.
    const double legacy = openingSeconds(rate, 5, 200, 0, 14);
    check(std::fabs(legacy - off) < 1.0e-9, "swap 0 equals the 14-value block", rate, legacy, off);
}

// 4x reference true peak: windowed-sinc interpolation of `x` at quarter-sample offsets over [from, to).
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

uint32_t expectedFactor(double rate) { return rate >= 176399 ? 1u : (rate * 2 >= 176399 ? 2u : 4u); }

uint32_t expectedLatency(double rate, uint32_t factor, double laMs) {
    const double high = rate * factor;
    const uint32_t laHigh = (uint32_t)std::ceil((double)(float)laMs * 0.001 * high);
    return (factor == 2 ? 32u : (factor == 4 ? 48u : 0u)) + (laHigh + factor - 1) / factor;
}

void truePeakFactor(double rate) {
    const double laMs = 2.0;
    const float on[8] = {1, -6, 1, 100, (float)laMs, 1, 4, 3};
    const float off[8] = {1, -6, 1, 100, (float)laMs, 1, 4, 0};
    n60_graph *g = build(rate, N60_STAGE_PROTECTION, on, 8);
    n60_graph *o = build(rate, N60_STAGE_PROTECTION, off, 8);
    const uint32_t f = expectedFactor(rate);
    check(n60_graph_latency_frames(g) == expectedLatency(rate, f, laMs), "latency follows the rate's factor", rate,
          n60_graph_latency_frames(g), expectedLatency(rate, f, laMs));
    check(n60_graph_latency_frames(o) == expectedLatency(rate, 4, laMs), "word 0 keeps the 4x latency", rate,
          n60_graph_latency_frames(o), expectedLatency(rate, 4, laMs));
    // The reported latency equals the measured delay: an impulse well under the ceiling.
    {
        const size_t n = (size_t)(0.1 * rate) + 4096, at = 2000;
        Vec in(n, 0.0f), out(n, 0.0f);
        in[at] = 0.1f;
        run(g, in, out, 0, n);
        size_t best = 0;
        for (size_t i = 0; i < n; ++i) if (std::fabs(out[i]) > std::fabs(out[best])) best = i;
        const double measured = (double)best - (double)at;
        const double reported = n60_graph_latency_frames(g);
        check(std::fabs(measured - reported) <= 1.0, "reported latency equals the measured delay", rate, measured, reported);
    }
    n60_graph_retire(g);
    g = build(rate, N60_STAGE_PROTECTION, on, 8);
    // An audio-band tone at full scale through a -6 dB ceiling: the output's 4x reference peak stays within 0.6 dB.
    const size_t n = (size_t)(0.4 * rate);
    Vec in(n), out(n, 0.0f);
    for (size_t i = 0; i < n; ++i) in[i] = (float)std::sin(2.0 * M_PI * 19000.0 * (double)i / rate + 0.37);
    run(g, in, out, 0, n);
    const double ref = referencePeak(out, (size_t)(0.15 * rate), (size_t)(0.35 * rate));
    const double ceiling = 0.5 * std::pow(10.0, 0.6 / 20.0);
    check(ref <= ceiling, "true-peak guard holds the 4x reference peak within 0.6 dB", rate, ref, ceiling);
    // G10: the guard readback means "the true-peak guard is on", also at factor 1 (176.4 kHz and above); without the guard
    // (word on, guard off, user factor 1) it reads 0.
    {
        n60_dynamics_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        check(n60_graph_read_dynamics(g, 5, 0, &rb) == N60_STATUS_OK && rb.guardActive == 1u,
              "guard reads active at every rate with the sound fixes on", rate, rb.guardActive, expectedFactor(rate));
        const float noGuard[8] = {1, -6, 1, 100, 2, 0, 1, 3};
        n60_graph *ng = build(rate, N60_STAGE_PROTECTION, noGuard, 8);
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        Vec x(4096, 0.1f), y(4096, 0.0f);
        run(ng, x, y, 0, x.size());
        check(n60_graph_read_dynamics(ng, 5, 0, &rb) == N60_STATUS_OK && rb.guardActive == 0u,
              "guard reads idle with the guard off", rate, rb.guardActive, 0);
        n60_graph_retire(ng);
    }
    n60_graph_retire(g);
    n60_graph_retire(o);
}

// The extra word at 0 is today's render.
void flagOffIdentical(double rate) {
    const size_t n = (size_t)(0.25 * rate);
    Vec in(n);
    for (size_t i = 0; i < n; ++i) in[i] = 1.2f * (float)std::sin(2.0 * M_PI * 440.0 * (double)i / rate);
    const float p7[7] = {1, -3, 5, 80, 2, 1, 2}, p8[8] = {1, -3, 5, 80, 2, 1, 2, 0};
    n60_graph *a = build(rate, N60_STAGE_PROTECTION, p7, 7), *b = build(rate, N60_STAGE_PROTECTION, p8, 8);
    Vec oa(n), ob(n);
    run(a, in, oa, 0, n);
    run(b, in, ob, 0, n);
    check(std::memcmp(oa.data(), ob.data(), n * sizeof(float)) == 0, "protection word 0 is bit-identical", rate);
    check(n60_graph_latency_frames(a) == n60_graph_latency_frames(b), "protection word 0 keeps the latency", rate);
    n60_graph_retire(a);
    n60_graph_retire(b);
}

// G8: a make-up edit while a steady level is compressed does not move the make-up-free reading.
void makeupEdit(double rate) {
    const float level = 0.3f;
    const double expected = (20.0 * std::log10((double)level) + 20.0) * (1.0 - 1.0 / 4.0);  // threshold -20 dB, 4:1, no knee
    const float p[15] = {-20, 4, 0, 1, 100, 0, 0, 0, 0, 1, 100, 100, 0, 50, 0};
    n60_graph *g = build(rate, N60_STAGE_COMPRESSOR, p, 15);
    const size_t warm = (size_t)(0.8 * rate), n = warm + (size_t)(0.4 * rate);
    Vec in(n, level), out(n);
    run(g, in, out, 0, warm);
    n60_dynamics_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_dynamics(g, 5, 0, &rb);  // reset the peak
    n60_param_record rec[1] = {{5, 5, 6.0f, 0}};
    n60_graph_post_params(g, rec, 1);
    run(g, in, out, warm, n);
    n60_graph_read_dynamics(g, 5, 0, &rb);
    check(std::fabs(rb.grMaxDb - expected) < 0.1, "make-up edit leaves the reduction reading unmoved", rate, rb.grMaxDb, expected);
    check(std::fabs(rb.grNowDb - expected) < 0.1, "make-up edit leaves the reduction now-reading unmoved", rate, rb.grNowDb, expected);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        limiterBurst(rate, 2.0f);
        limiterBurst(rate, 0.0f);
        expanderTiming(rate);
        truePeakFactor(rate);
        flagOffIdentical(rate);
        makeupEdit(rate);
    }
    if (failures) {
        std::fprintf(stderr, "n60core e32 dynamics sound: %d failures\n", failures);
        return 1;
    }
    std::puts("n60core e32 dynamics sound: ok");
    return 0;
}
