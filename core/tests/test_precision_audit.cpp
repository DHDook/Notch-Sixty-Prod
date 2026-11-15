// E7 S4 (design note 5, owner decision Q4): the smoothers of the dynamics stages at their slowest UI time constants, at
// the eight standard rates. A smoother passes when its measured time constant is within 1 percent of the set value and it
// does not stall short of its target. A float pole at 5 s and 384 kHz is 1 - 5.2e-8, below its own spacing, and a float
// gain state stops moving when its step is under half an ulp, so these were the stages that needed double.
// The filters of the graph stages are covered by their own double references (test_image_precision.cpp, test_peq_wide.cpp,
// test_xover_highrate_engine.cpp, test_multiband.cpp, test_loudness.cpp, test_cleanup.cpp); the table of results is in
// docs/epics/E7.md (S4).
#include <algorithm>
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
constexpr double kPi = 3.14159265358979323846;

n60_graph *build(double rate, uint32_t kind, const float *p, uint32_t count) {
    n60_stage_desc st;
    std::memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = kind;
    st.stageId = 5;
    st.laneA = 0;
    st.laneB = kind == N60_STAGE_LOUDNESS ? 1 : 0;  // the loudness stage is a pair stage
    st.params = p;
    st.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

// A 1 kHz sine of the given amplitude on both lanes for `seconds`; returns the RMS of the last 20 ms of lane 0.
struct Driver {
    n60_graph *g;
    double rate, phase = 0;
    bool square = false;  // constant magnitude, so a per-sample peak detector holds its level
    double run(double seconds, double amp) {
        const size_t total = (size_t)(rate * seconds) / kBlock * kBlock;
        const size_t tailFrom = total > (size_t)(rate * 0.02) ? total - (size_t)(rate * 0.02) : 0;
        std::vector<float> l(kBlock), r(kBlock), ol(kBlock), orr(kBlock);
        double sq = 0;
        size_t cnt = 0;
        for (size_t off = 0; off < total; off += kBlock) {
            for (uint32_t i = 0; i < kBlock; ++i) {
                l[i] = r[i] = (float)(square ? (phase < kPi ? amp : -amp) : amp * std::sin(phase));
                phase += 2 * kPi * 1000.0 / rate;
                if (phase > 2 * kPi) phase -= 2 * kPi;
            }
            const float *ip[2] = {l.data(), r.data()};
            float *op[2] = {ol.data(), orr.data()};
            n60_graph_process(g, ip, op, kBlock);
            if (off >= tailFrom) {
                for (uint32_t i = 0; i < kBlock; ++i) sq += double(ol[i]) * double(ol[i]);
                cnt += kBlock;
            }
        }
        return cnt ? std::sqrt(sq / double(cnt)) : 0.0;
    }
    double grNow() {
        n60_dynamics_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_dynamics(g, 5, 0, &rb);
        return (double)rb.grNowDb;
    }
};

// Time constant from two reductions one tau apart: gr(t) = gr0 * exp(-t / tau), so tau = dt / ln(gr1 / gr2).
double tauFrom(double dt, double gr1, double gr2) { return gr1 > 1e-3 && gr2 > 1e-3 && gr1 > gr2 ? dt / std::log(gr1 / gr2) : 0.0; }

// Compressor, release 5000 ms (the UI maximum): loud burst, then silence; the reduction decays with the release pole.
void compressorRelease(double rate) {
    float p[10] = {-40, 4, 0, 0.05f, 5000, 0, 0, 0, 0, 0};
    n60_graph *g = build(rate, N60_STAGE_COMPRESSOR, p, 10);
    check(g != nullptr, "build compressor", rate);
    if (!g) return;
    Driver d{g, rate};
    d.run(0.5, 0.9);
    const double gr0 = d.grNow();
    check(gr0 > 20.0, "compressor burst reduces", rate);
    d.run(5.0, 0.0);
    const double gr1 = d.grNow();
    d.run(5.0, 0.0);
    const double gr2 = d.grNow();
    const double tau = tauFrom(5.0, gr1, gr2);
    std::printf("compressor release 5000 ms at %.0f: tau %.4f s (reduction %.3f -> %.3f -> %.3f dB)\n", rate, tau, gr0, gr1, gr2);
    check(std::fabs(tau / 5.0 - 1.0) < 0.01, "compressor release within 1 percent", rate);
    n60_graph_retire(g);
}

// Extended compressor (16 values), same measurement: the second code path.
void compressorExtendedRelease(double rate) {
    float p[16] = {-40, 4, 0, 0.05f, 5000, 0, 0, 0, 0, 0, 100, 0, 0, 50, 0, 0};
    n60_graph *g = build(rate, N60_STAGE_COMPRESSOR, p, 16);
    check(g != nullptr, "build compressor x", rate);
    if (!g) return;
    Driver d{g, rate};
    d.run(0.5, 0.9);
    d.run(5.0, 0.0);
    const double gr1 = d.grNow();
    d.run(5.0, 0.0);
    const double gr2 = d.grNow();
    const double tau = tauFrom(5.0, gr1, gr2);
    std::printf("compressor (16) release 5000 ms at %.0f: tau %.4f s\n", rate, tau);
    check(std::fabs(tau / 5.0 - 1.0) < 0.01, "compressor (16) release within 1 percent", rate);
    n60_graph_retire(g);
}

// Expander, release 5000 ms: the gain opens from the closed range with the release pole.
void expanderRelease(double rate) {
    float p[6] = {-30, 4, -40, 0.05f, 5000, 0};
    n60_graph *g = build(rate, N60_STAGE_EXPANDER, p, 6);
    check(g != nullptr, "build expander", rate);
    if (!g) return;
    Driver d{g, rate};
    d.square = true;
    d.run(0.5, 0.0);
    check(d.grNow() > 30.0, "expander closes", rate);
    d.run(5.0, 0.9);
    const double gr1 = d.grNow();
    d.run(5.0, 0.9);
    const double gr2 = d.grNow();
    const double tau = tauFrom(5.0, gr1, gr2);
    std::printf("expander release 5000 ms at %.0f: tau %.4f s\n", rate, tau);
    check(std::fabs(tau / 5.0 - 1.0) < 0.01, "expander release within 1 percent", rate);
    n60_graph_retire(g);
}

// Dynamic EQ, release 1000 ms (the UI maximum): the cut of a peak band at 1 kHz decays after a burst; the probe tone is
// 60 dB down (under the threshold), its output level shows the cut in dB.
void dynEqRelease(double rate) {
    float p[16] = {0, 0, 1000, 1, 0, -40, 10, -24, 1, 1000, 0, -60, 1, 0, 0, 50};
    n60_graph *g = build(rate, N60_STAGE_DYN_EQ, p, 16);
    check(g != nullptr, "build dyn eq", rate);
    if (!g) return;
    Driver d{g, rate};
    d.run(0.5, 0.9);
    const double probe = 0.001 / std::sqrt(2.0);
    const double cut1 = -20 * std::log10(std::max(d.run(1.0, 0.001), 1e-12) / probe);
    const double cut2 = -20 * std::log10(std::max(d.run(1.0, 0.001), 1e-12) / probe);
    // The windows are the last 20 ms of the first and second second of release.
    const double tau = tauFrom(1.0, cut1, cut2);
    std::printf("dynamic EQ release 1000 ms at %.0f: tau %.4f s (cut %.3f -> %.3f dB)\n", rate, tau, cut1, cut2);
    // Measured through the output level of a probe tone (no gain readback exists), so the resolution is about 1.5 percent.
    check(std::fabs(tau - 1.0) < 0.02, "dynamic EQ release within 2 percent", rate);
    n60_graph_retire(g);
}

// Loudness match, release 5 s (the clamp of its pole): once the 3 s measurement has settled, the target is raised by 4 dB and
// the gain climbs with the release pole; the time constant comes from the distance to the final value 5 s and 10 s later.
void loudnessMatchRelease(double rate) {
    float p[32] = {1, 0, -24, 20, 5, 5, 0, 0.6f, 0, 0, 80, 12, 3, 1,
                   0, 0, 300, 3500, 6, 3, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f};
    n60_graph *g = build(rate, N60_STAGE_LOUDNESS, p, 32);
    check(g != nullptr, "build loudness", rate);
    if (!g) return;
    Driver d{g, rate};
    auto gain = [&]() {
        n60_loudness_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_loudness(g, 5, &rb);
        return (double)rb.matchGainDb;
    };
    d.run(30.0, 0.3);
    const double g0 = gain();
    check(g0 < -3.0, "loudness match attenuates", rate);
    n60_param_record rec[1] = {{5, 2, -20.0f, 0}};
    check(n60_graph_post_params(g, rec, 1) == N60_STATUS_OK, "post target", rate);
    d.run(5.0, 0.3);
    const double g1 = gain();
    d.run(5.0, 0.3);
    const double g2 = gain();
    d.run(40.0, 0.3);
    const double gInf = gain();
    const double tau = gInf - g1 > 1e-3 && gInf - g2 > 1e-3 ? 5.0 / std::log((gInf - g1) / (gInf - g2)) : 0.0;
    std::printf("loudness match release 5 s at %.0f: tau %.4f s (gain %.3f -> %.3f -> %.3f -> %.3f dB)\n", rate, tau, g0, g1, g2, gInf);
    check(std::fabs(tau / 5.0 - 1.0) < 0.01, "loudness match release within 1 percent", rate);
    n60_graph_retire(g);
}

// Fractional delay: a third-order Thiran all-pass with float coefficients and float history. The reference runs the same
// recursion in double on the same float coefficients (rebuilt here from the design), so what is measured is the rounding
// of the history only. Passing bound: -100 dB relative to the output (owner decision Q4; measured -116 dB worst, at a fraction of 0.001, at every rate: the design does not depend on the rate).
void fracDelay(double rate, float fraction) {
    const double whole = 4.0, want = 3.0 - 1.0 + fraction;  // total = whole + fraction; order 3 takes two of the whole frames
    float p[2] = {4.0f, fraction};
    n60_graph *g = build(rate, N60_STAGE_FRAC_DELAY, p, 2);
    check(g != nullptr, "build frac delay", rate);
    if (!g) return;
    (void)whole;
    // Thiran denominator for order 3 and delay D = 2 + fraction (the stage design, in double, stored as float).
    const double D = want;
    static const double binom[4] = {1, 3, 3, 1};
    float den[4] = {1.0f, 0, 0, 0};
    for (uint32_t k = 1; k <= 3; ++k) {
        double prod = 1.0;
        for (uint32_t n = 0; n <= 3; ++n) prod *= (D - 3 + n) / (D - 3 + k + n);
        den[k] = static_cast<float>(((k & 1u) ? -1.0 : 1.0) * binom[k] * prod);
    }
    const size_t total = (size_t)(rate * 2.0) / kBlock * kBlock;
    std::vector<float> in(total), out(total), junk(total);
    unsigned seed = 5;
    for (size_t i = 0; i < total; ++i) {
        seed = seed * 1664525u + 1013904223u;
        in[i] = 0.4f * ((float)((seed >> 8) & 0xFFFF) / 32768.0f - 1.0f) + 0.3f * (float)std::sin(2 * kPi * 50.0 * (double)i / rate);
    }
    for (size_t off = 0; off < total; off += kBlock) {
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {out.data() + off, junk.data() + off};
        n60_graph_process(g, ip, op, kBlock);
    }
    double xh[3] = {0, 0, 0}, yh[3] = {0, 0, 0}, errSq = 0, refSq = 0;
    for (size_t i = 0; i < total; ++i) {
        const double x = i >= 2 ? double(in[i - 2]) : 0.0;  // the integer part: 4 - 2 frames
        double y = double(den[3]) * x;
        for (int k = 1; k <= 3; ++k) y += double(den[3 - k]) * xh[k - 1] - double(den[k]) * yh[k - 1];
        xh[2] = xh[1]; xh[1] = xh[0]; xh[0] = x;
        yh[2] = yh[1]; yh[1] = yh[0]; yh[0] = y;
        const double e = double(out[i]) - y;
        errSq += e * e;
        refSq += y * y;
    }
    const double db = 10 * std::log10(errSq / refSq + 1e-30);
    std::printf("fractional delay %.3f at %.0f: float history vs double %.1f dB\n", fraction, rate, db);
    check(db < -100.0, "fractional delay state error below -100 dB", rate);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        compressorRelease(rate);
        compressorExtendedRelease(rate);
        expanderRelease(rate);
        dynEqRelease(rate);
        loudnessMatchRelease(rate);
        for (float f : {0.001f, 0.5f, 0.999f}) fracDelay(rate, f);
    }
    if (failures) return 1;
    std::puts("n60core precision audit (E7 S4): OK");
    return 0;
}
