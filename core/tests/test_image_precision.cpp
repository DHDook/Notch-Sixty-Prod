// E6 S12h part 1 (G36): the image and de-ess stages keep float coefficients and state. This measures, at the eight standard
// rates, how far the graph is from a double-precision reference in the two places the 384 kHz review flagged:
//  - the widener's 80 Hz crossover corner (lowest allowed lowMid): a side-only signal through the stage against the
//    same RBJ design, cascade and band weights computed in double;
//  - the de-esser's 1000 ms release (the slowest allowed): the decay of the gain reduction after a burst, against the
//    ideal exp(-t / 1 s), and the value the reduction settles at after the range is relaxed (a smoothing step that is
//    smaller than half a float ulp of the running value stalls early).
// Result (E6 S12h): the de-esser release stays float (time constant within 1 percent of 1 s at every rate, no stall); the
// widener's crossover biquads moved to double (float error reached -35 dB at 352.8 kHz). The bounds fail if either worsens.
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
    st.laneB = 1;
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

struct Bq {
    double b0, b1, b2, a1, a2, z1 = 0, z2 = 0;
    double run(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
};
Bq rbj(bool lowPass, double rate, double f) {
    const double q = 0.7071067811865476, w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
    const double a0 = 1 + alpha;
    Bq b;
    b.b0 = (lowPass ? (1 - c) : (1 + c)) * 0.5 / a0;
    b.b1 = (lowPass ? (1 - c) : -(1 + c)) / a0;
    b.b2 = b.b0;
    b.a1 = -2 * c / a0;
    b.a2 = (1 - alpha) / a0;
    return b;
}

void widener(double rate) {
    const float p[8] = {0, 1, 0, 80, 4000, 0.5f, 1.5f, 1.4f};
    n60_graph *g = build(rate, N60_STAGE_IMAGE, p, 8);
    check(g != nullptr, "build image", rate);
    if (!g) return;
    const size_t total = (size_t)(rate * 3.0) / kBlock * kBlock;
    const double freqs[] = {30, 80, 150, 1000, 8000};
    std::vector<float> l(total), r(total), ol(total), orr(total);
    std::vector<double> s(total);
    for (size_t i = 0; i < total; ++i) {
        double v = 0;
        for (double f : freqs) v += 0.18 * std::sin(2 * kPi * f * (double)i / rate);
        s[i] = double(float(v));  // the same float input feeds both
        l[i] = (float)s[i];
        r[i] = -(float)s[i];
    }
    for (size_t off = 0; off < total; off += kBlock) {
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, kBlock);
    }
    Bq lp[2] = {rbj(true, rate, 80), rbj(true, rate, 80)}, hp[2] = {rbj(false, rate, 4000), rbj(false, rate, 4000)};
    double errSq = 0, refSq = 0;
    for (size_t i = 0; i < total; ++i) {
        // mid = 0, side = s: the output is the weighted three-band side.
        double low = s[i], high = s[i];
        for (int k = 0; k < 2; ++k) { low = lp[k].run(low); high = hp[k].run(high); }
        const double mid = s[i] - low - high;
        const double ref = low * 0.5 + mid * 1.5 + high * 1.4;
        if (i >= (size_t)(rate * 1.0)) {  // the 5 ms weight smoothing has settled
            const double e = double(ol[i]) - ref;
            errSq += e * e;
            refSq += ref * ref;
        }
    }
    const double db = 10 * std::log10(errSq / refSq + 1e-30);
    std::printf("widener 80 Hz at %.0f: float vs double error %.1f dB\n", rate, db);
    check(db < -75.0, "widener error below -75 dB (the float version reached -35 dB at 352.8 kHz)", rate);
    n60_graph_retire(g);
}

// Gain reduction decay after a burst: ln(GR1 / GR2) / (t2 - t1) is 1 / tau.
void deessRelease(double rate) {
    // harsh off, ess on at 6500 Hz, threshold -40 dB, ratio 4, range -6 dB (the loud burst sits on the range), Q 2,
    // attack 1 ms, release 1000 ms, wideband (dynEq off).
    float p[12] = {0, 3500, -3, 1, 6500, -40, 4, -6, 2, 1, 1000, 0};
    n60_graph *g = build(rate, N60_STAGE_DEESS, p, 12);
    check(g != nullptr, "build deess", rate);
    if (!g) return;
    auto run = [&](double seconds, double amp) {
        const size_t total = (size_t)(rate * seconds) / kBlock * kBlock;
        static std::vector<float> l, r, ol, orr;
        l.resize(kBlock); r.resize(kBlock); ol.resize(kBlock); orr.resize(kBlock);
        static double phase = 0;
        for (size_t off = 0; off < total; off += kBlock) {
            for (uint32_t i = 0; i < kBlock; ++i) {
                l[i] = r[i] = (float)(amp * std::sin(phase));
                phase += 2 * kPi * 6500.0 / rate;
                if (phase > 2 * kPi) phase -= 2 * kPi;
            }
            const float *ip[2] = {l.data(), r.data()};
            float *op[2] = {ol.data(), orr.data()};
            n60_graph_process(g, ip, op, kBlock);
        }
    };
    auto grNow = [&]() {
        n60_dynamics_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_dynamics(g, 5, 0, &rb);
        return (double)rb.grNowDb;
    };
    run(0.5, 0.9);
    const double gr0 = grNow();
    check(std::fabs(gr0 - 6.0) < 0.3, "burst reaches the range", rate);
    // Silence: the target returns to 0 dB and the reduction decays with the release pole.
    run(1.0, 0.0);
    const double gr1 = grNow();
    run(1.0, 0.0);
    const double gr2 = grNow();
    const double tau = gr1 > 1e-3 && gr2 > 1e-3 ? 1.0 / std::log(gr1 / gr2) : 0.0;
    std::printf("de-esser release 1000 ms at %.0f: measured time constant %.4f s (reduction %.3f -> %.3f -> %.3f dB)\n", rate,
                tau, gr0, gr1, gr2);
    check(std::fabs(tau - 1.0) < 0.03, "release time constant within 3 percent of 1 s", rate);
    // Relax the range to -3 dB under the same loud tone: the reduction moves 6 -> 3 dB with the release pole and
    // must end at the new target (a stall would leave it measurably above 3 dB after six time constants).
    n60_graph_retire(g);
    g = build(rate, N60_STAGE_DEESS, p, 12);
    run(0.5, 0.9);
    n60_param_record rec[1] = {{5, 7, -3.0f, 0}};
    check(n60_graph_post_params(g, rec, 1) == N60_STATUS_OK, "post range", rate);
    run(7.0, 0.9);
    const double grEnd = grNow();
    std::printf("de-esser range relaxed 6 -> 3 dB at %.0f: settled reduction %.4f dB (ideal 3.0000)\n", rate, grEnd);
    check(std::fabs(grEnd - 3.0) < 0.1, "reduction settles within 0.1 dB of the relaxed range", rate);
    n60_graph_retire(g);
}
// E20 S10 part 6 (G45): the de-harsh high shelf (float coefficients, float state, single-rounded fma kernel) against a double
// state reference that uses the SAME float coefficients, so what is measured is arithmetic rounding only, not coefficient
// quantisation (which the kernel shares). The plain float form the legacy kernel used (b0*x + z1 and so on, no fma) is run
// beside it: the bulk path must be no worse than that form, which shows the loosened kernel-parity bound
// (test_image_parity.c) is float noise of either implementation and not a regression in the stage.
void harshShelf(double rate) {
    const float p[12] = {1, 3500, -3, 0, 6500, -40, 4, -6, 2, 1, 100, 0};
    n60_graph *g = build(rate, N60_STAGE_DEESS, p, 12);
    check(g != nullptr, "build harsh", rate);
    if (!g) return;
    // The stage's design: RBJ high shelf, Q = 0.7071067811865476, normalised in double, stored as float.
    const double q = 0.7071067811865476, w = 2 * kPi * 3500.0 / rate, c = std::cos(w), sn = std::sin(w);
    const double A = std::pow(10.0, -3.0 / 40.0), alpha = sn / (2 * q), beta = 2 * std::sqrt(A) * alpha;
    const double a0 = (A + 1) - (A - 1) * c + beta;
    const float cf[5] = {float(A * ((A + 1) + (A - 1) * c + beta) / a0), float(-2 * A * ((A - 1) + (A + 1) * c) / a0),
                         float(A * ((A + 1) + (A - 1) * c - beta) / a0), float(2 * ((A - 1) - (A + 1) * c) / a0),
                         float(((A + 1) - (A - 1) * c - beta) / a0)};
    const size_t total = (size_t)(rate * 2.0) / kBlock * kBlock;
    std::vector<float> l(total), r(total), ol(total), orr(total);
    unsigned seed = 11;
    for (size_t i = 0; i < total; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const float noise = 0.05f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        l[i] = 0.3f * (float)std::sin(2 * kPi * 440.0 * (double)i / rate) + 0.25f * (float)std::sin(2 * kPi * 6800.0 * (double)i / rate) + noise;
        r[i] = -0.8f * l[i];
    }
    for (size_t off = 0; off < total; off += kBlock) {
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, kBlock);
    }
    // The stage crossfades dry and shelf with a float-smoothed mix that settles near (not exactly at) 1, so the output is
    // dry + m * (wet - dry) with m fixed over the measured second: fit m by least squares and measure the residual, which is
    // the shelf's arithmetic rounding (plus the final blend's one rounding).
    std::vector<double> dry(total), wet(total);
    std::vector<float> plain(total);
    double rz1 = 0, rz2 = 0;      // double reference, left channel
    float fz1 = 0, fz2 = 0;       // plain float form (no fma)
    for (size_t i = 0; i < total; ++i) {
        const double x = l[i];
        const double y = double(cf[0]) * x + rz1;
        rz1 = double(cf[1]) * x - double(cf[3]) * y + rz2;
        rz2 = double(cf[2]) * x - double(cf[4]) * y;
        const float xf = l[i];
        const float yf = cf[0] * xf + fz1;
        fz1 = cf[1] * xf - cf[3] * yf + fz2;
        fz2 = cf[2] * xf - cf[4] * yf;
        dry[i] = x;
        wet[i] = y;
        plain[i] = yf;
    }
    const size_t from = (size_t)(rate * 1.0);  // the 5 ms bypass crossfade has settled
    double num = 0, den = 0;
    for (size_t i = from; i < total; ++i) {
        num += (double(ol[i]) - dry[i]) * (wet[i] - dry[i]);
        den += (wet[i] - dry[i]) * (wet[i] - dry[i]);
    }
    const double m = num / den;
    double peakStage = 0, peakPlain = 0, sumStage = 0, sumPlain = 0;
    const size_t counted = total - from;
    for (size_t i = from; i < total; ++i) {
        const double es = std::fabs(double(ol[i]) - (dry[i] + m * (wet[i] - dry[i]))), ep = std::fabs(double(plain[i]) - wet[i]);
        peakStage = std::max(peakStage, es);
        peakPlain = std::max(peakPlain, ep);
        sumStage += es * es;
        sumPlain += ep * ep;
    }
    const double dbS = 20 * std::log10(peakStage + 1e-30), dbP = 20 * std::log10(peakPlain + 1e-30);
    const double rmsS = 10 * std::log10(sumStage / double(counted) + 1e-60), rmsP = 10 * std::log10(sumPlain / double(counted) + 1e-60);
    std::printf("de-harsh shelf at %.0f: settled mix %.7f; stage vs double peak %.1f rms %.1f dBFS; plain float form peak %.1f rms %.1f dBFS\n",
                rate, m, dbS, rmsS, dbP, rmsP);
    check(std::fabs(m - 1.0) < 1.0e-3, "de-harsh mix settles within 1e-3 of 1", rate);
    check(dbS < -105.0, "de-harsh shelf peak error below -105 dBFS against the double reference", rate);
    check(rmsS < -120.0, "de-harsh shelf rms error below -120 dBFS against the double reference", rate);
    // The stage's single-rounded form is no worse than the plain float form (3 dB of margin on the rms for run-to-run
    // differences in which samples round the wrong way).
    check(rmsS < rmsP + 3.0, "de-harsh shelf no noisier than the plain float form", rate);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        widener(rate);
        deessRelease(rate);
        harshShelf(rate);
    }
    if (failures) return 1;
    std::puts("n60core image precision (G36): OK");
    return 0;
}
