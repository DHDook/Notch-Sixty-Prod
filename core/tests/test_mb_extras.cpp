// E28 S7c (ABI v36): behaviour of the multiband extras at the eight standard rates: a 43-value block with defaults is
// bit-identical to the 29-value block, per-band bypass (flat sum within 0.01 dB for LR4 and LR8), solo against the
// crossover's own output, two solos summing, the 5 ms solo ramp, the shared lookahead (latency reported, bands aligned),
// sidechain and delta listen, the RMS detector and validation (lookahead is topology).
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

// Indices: on 0, lowMid 1, midHigh 2, slopes 3-4, thr 5, ratio 8, atk 11, rel 14, knee 17, hpf 20, makeup 23, auto 26,
// bypass 29, solo 32, listen 35, detector 38, window 41, lookahead 42.
struct Mb {
    float p[43] = {1, 250, 2500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 0};
};

using Vec = std::vector<float>;

n60_graph *build(double rate, const float *params, uint32_t count, n60_status *st = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_MULTIBAND;
    s.stageId = 5;
    s.laneA = 0;
    s.laneB = 1;
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
    const n60_status r = n60_graph_build(&d, &g);
    if (st) *st = r;
    return r == N60_STATUS_OK ? g : nullptr;
}

// Processes the left input (the right lane carries the same) in blocks of `block`; returns the left output.
Vec run(n60_graph *g, const Vec &in, uint32_t block = 512, Vec *outR = nullptr) {
    Vec ol(in.size()), orr(in.size());
    for (size_t off = 0; off < in.size(); off += block) {
        const uint32_t n = (uint32_t)std::min<size_t>(block, in.size() - off);
        const float *ip[2] = {in.data() + off, in.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
    if (outR) *outR = orr;
    return ol;
}

Vec render(double rate, const Mb &m, const Vec &in, uint32_t count = 43) {
    n60_graph *g = build(rate, m.p, count);
    if (!g) return Vec(in.size());
    Vec out = run(g, in);
    n60_graph_retire(g);
    return out;
}

uint32_t rng = 4242;
Vec noise(size_t n, float amp) {
    Vec v(n);
    for (auto &x : v) {
        rng = rng * 1664525u + 1013904223u;
        x = amp * ((float)((rng >> 8) & 0xFFFF) / 32768.0f - 1.0f);
    }
    return v;
}
Vec sine(double rate, double hz, double amp, size_t n) {
    Vec v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}
double rms(const Vec &v, size_t from) {
    double s = 0;
    for (size_t i = from; i < v.size(); ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(v.size() - from));
}
double db(double x) { return 20.0 * std::log10(x); }
double maxDiff(const Vec &a, const Vec &b, size_t from, size_t shiftB = 0) {
    double m = 0;
    for (size_t i = from; i + shiftB < b.size() && i < a.size(); ++i) m = std::max(m, std::fabs((double)a[i] - (double)b[i + shiftB]));
    return m;
}

// Independent double reference of an LR4 band split (RBJ Butterworth sections, Q = 1/sqrt(2)).
struct Ref {
    double b0, b1, b2, a1, a2, z1 = 0, z2 = 0;
    Ref(bool hp, double rate, double f) {
        const double w = 2 * M_PI * f / rate, c = std::cos(w), al = std::sin(w) / (2 * 0.7071067811865476);
        const double a0 = 1 + al;
        b0 = (hp ? (1 + c) : (1 - c)) * 0.5 / a0;
        b1 = (hp ? -(1 + c) : (1 - c)) / a0;
        b2 = b0;
        a1 = -2 * c / a0;
        a2 = (1 - al) / a0;
    }
    double run(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
};
Vec refBand(double rate, bool hp, double f, const Vec &in) {
    Ref a(hp, rate, f), b(hp, rate, f);
    Vec out(in.size());
    for (size_t i = 0; i < in.size(); ++i) out[i] = (float)b.run(a.run(in[i]));
    return out;
}

void testRate(double rate) {
    const size_t n = (size_t)(rate * 0.6), from = n / 2;
    const Vec in = noise(n, 0.5f);
    // Float crossover state (E6 G25) limits agreement with the double reference; E23 S1b's double state tightens it to 1e-5.
    const double tol = rate > 300000 ? 2e-4 : 1e-4;
    // 1. A 43-value block with defaults equals the 29-value block, bit for bit (compression active).
    {
        Mb m;
        const Vec a = render(rate, m, in, 29), b = render(rate, m, in, 43);
        check(std::memcmp(a.data(), b.data(), n * 4) == 0, "defaults are bit-identical to v25", rate);
    }
    // 2. All bands bypassed: the sum is flat within 0.01 dB (LR4 and LR8).
    for (int lr8 = 0; lr8 < 2; ++lr8) {
        Mb m;
        m.p[3] = m.p[4] = (float)lr8;
        m.p[29] = m.p[30] = m.p[31] = 1;
        const Vec o = render(rate, m, in);
        check(std::fabs(db(rms(o, from) / rms(in, from))) < 0.01, lr8 ? "LR8 bypass sum is flat" : "LR4 bypass sum is flat", rate,
              db(rms(o, from) / rms(in, from)));
    }
    // 3. Solo equals the band's own crossover output; two solos sum.
    {
        Mb bypass;
        bypass.p[29] = bypass.p[30] = bypass.p[31] = 1;
        Mb lo = bypass, hi = bypass, mid = bypass, lm = bypass;
        lo.p[32] = 1;
        hi.p[34] = 1;
        mid.p[33] = 1;
        lm.p[32] = lm.p[33] = 1;
        const Vec oLo = render(rate, lo, in), oHi = render(rate, hi, in), oMid = render(rate, mid, in), oLm = render(rate, lm, in);
        const size_t settle = (size_t)(rate * 0.05);
        const Vec rLo = refBand(rate, false, 250, in), rHi = refBand(rate, true, 2500, in);
        check(maxDiff(oLo, rLo, settle) < tol, "solo low equals the low crossover output", rate, maxDiff(oLo, rLo, settle));
        check(maxDiff(oHi, rHi, settle) < tol, "solo high equals the high crossover output", rate, maxDiff(oHi, rHi, settle));
        double s = 0;
        for (size_t i = settle; i < n; ++i) s = std::max(s, std::fabs((double)oLm[i] - (double)oLo[i] - (double)oMid[i]));
        check(s < tol, "two solos sum", rate, s);
        // Mid is the residual: low + mid + high = dry.
        double r = 0;
        for (size_t i = settle; i < n; ++i) r = std::max(r, std::fabs((double)oLo[i] + oMid[i] + oHi[i] - in[i]));
        check(r < tol, "solo bands sum to the input", rate, r);
    }
    // 4. The solo ramp is a 5 ms one-pole: no step larger than its own slope (a plan bound of 1e-4 is below the slope of any
    // 5 ms ramp at these amplitudes; recorded in the ledger).
    {
        Mb m;
        m.p[29] = m.p[30] = m.p[31] = 1;
        n60_graph *g = build(rate, m.p, 43);
        Vec dc(n, 0.4f);
        Vec a = run(g, Vec(dc.begin(), dc.begin() + n / 2));
        n60_param_record rec[3] = {{5, 32, 0.0f, 0}, {5, 33, 1.0f, 0}, {5, 34, 0.0f, 0}};  // solo the mid band (DC: nothing)
        check(n60_graph_post_params(g, rec, 3) == N60_STATUS_OK, "post solo", rate);
        Vec b = run(g, Vec(dc.begin(), dc.begin() + n / 2));
        n60_graph_retire(g);
        const double pole = std::exp(-1.0 / (rate * 0.005));
        double worst = 0;
        for (size_t i = 1; i < b.size(); ++i) worst = std::max(worst, std::fabs((double)b[i] - b[i - 1]));
        check(worst <= 0.4 * (1.0 - pole) * 1.2 + 1e-6, "solo ramp steps follow the 5 ms slope", rate, worst, 0.4 * (1.0 - pole));
        (void)a;
    }
    // 5. One lookahead: latency reported, bands aligned (bypass sum equals the delayed input), detectors early.
    {
        Mb m;
        m.p[29] = m.p[30] = m.p[31] = 1;
        const uint32_t look = (uint32_t)(rate * 0.003);
        m.p[42] = (float)look;
        n60_graph *g = build(rate, m.p, 43);
        check(g != nullptr, "lookahead builds", rate);
        if (g) {
            check(n60_graph_latency_frames(g) == look, "latency reports the lookahead", rate, n60_graph_latency_frames(g), look);
            const Vec o = run(g, in, 384);
            check(maxDiff(Vec(o.begin() + look, o.end()), in, (size_t)(rate * 0.05)) < 2e-6, "bands stay aligned behind the lookahead", rate,
                  maxDiff(Vec(o.begin() + look, o.end()), in, (size_t)(rate * 0.05)));
            n60_graph_retire(g);
        }
        n60_param_record rec[1] = {{5, 42, 10.0f, 0}};
        g = build(rate, m.p, 43);
        check(n60_graph_post_params(g, rec, 1) == N60_STATUS_UNSUPPORTED, "lookahead is topology", rate);
        n60_graph_retire(g);
    }
    // 6. Listen. Sidechain (no filter, no lookahead): the band itself. With a lookahead: the same, delayed.
    {
        Mb bypass;
        bypass.p[29] = bypass.p[30] = bypass.p[31] = 1;
        Mb side = bypass;
        side.p[35] = 1;
        const Vec oSide = render(rate, side, in);
        const Vec rLo = refBand(rate, false, 250, in);
        const size_t settle = (size_t)(rate * 0.05);
        check(maxDiff(oSide, rLo, settle) < tol, "sidechain listen plays the band", rate, maxDiff(oSide, rLo, settle));
        Mb la = side;
        const uint32_t look = (uint32_t)(rate * 0.002);
        la.p[42] = (float)look;
        const Vec oLa = render(rate, la, in);
        check(maxDiff(Vec(oLa.begin() + look, oLa.end()), oSide, settle) < 1e-6, "listen latency equals the lookahead", rate);
        // Delta plus the soloed processed band is the band before gain.
        Mb comp;
        comp.p[32] = 1;       // solo low, compressing (no make-up)
        comp.p[5] = -40;      // low threshold
        comp.p[23] = 0;
        Mb delta = comp;
        delta.p[32] = 0;
        delta.p[35] = 2;
        Mb plain = bypass;
        plain.p[32] = 1;
        const Vec oC = render(rate, comp, in), oD = render(rate, delta, in), oP = render(rate, plain, in);
        double w = 0;
        for (size_t i = settle * 2; i < n; ++i) w = std::max(w, std::fabs((double)oC[i] + oD[i] - oP[i]));
        check(w < tol, "delta listen is what the band lost", rate, w);
        double mag = 0;
        for (size_t i = settle * 2; i < n; ++i) mag = std::max(mag, std::fabs((double)oD[i]));
        check(mag > 1e-3, "delta listen is not silent when compressing", rate, mag);
    }
    // 7. RMS detector reads about 3 dB lower than the peak detector on a sine, so it reduces less.
    {
        Mb peak;
        peak.p[5] = peak.p[6] = peak.p[7] = -20;
        peak.p[11] = peak.p[12] = peak.p[13] = 1;
        peak.p[14] = peak.p[15] = peak.p[16] = 100;
        Mb r = peak;
        r.p[38] = r.p[39] = r.p[40] = 1;
        const Vec tone = sine(rate, 800, 0.5, n);
        n60_multiband_readback a, b;
        std::memset(&a, 0, sizeof a); std::memset(&b, 0, sizeof b);
        a.structSize = b.structSize = sizeof a;
        n60_graph *g = build(rate, peak.p, 43);
        run(g, tone);
        n60_graph_read_multiband(g, 5, &a);
        n60_graph_retire(g);
        g = build(rate, r.p, 43);
        run(g, tone);
        n60_graph_read_multiband(g, 5, &b);
        n60_graph_retire(g);
        const double diff = a.grNowDb[1] - b.grNowDb[1];
        check(diff > 1.2 && diff < 3.2, "RMS detector reduces less than peak", rate, diff, a.grNowDb[1]);
    }
    // 8. Validation.
    {
        n60_status st;
        Mb m;
        check(build(rate, m.p, 30, &st) == nullptr && st != N60_STATUS_OK, "reject 30 values", rate);
        Mb a; a.p[35] = 3;
        check(build(rate, a.p, 43, &st) == nullptr && st != N60_STATUS_OK, "reject listen 3", rate);
        Mb b; b.p[42] = 16385;
        check(build(rate, b.p, 43, &st) == nullptr && st != N60_STATUS_OK, "reject lookahead 16385", rate);
        Mb c; c.p[41] = 4;
        check(build(rate, c.p, 43, &st) == nullptr && st != N60_STATUS_OK, "reject window 4", rate);
        Mb d; d.p[29] = 2;
        check(build(rate, d.p, 43, &st) == nullptr && st != N60_STATUS_OK, "reject bypass 2", rate);
        n60_graph *g = build(rate, m.p, 43);
        n60_param_record ok[2] = {{5, 33, 1.0f, 0}, {5, 36, 2.0f, 0}};
        check(n60_graph_post_params(g, ok, 2) == N60_STATUS_OK, "solo and listen are live", rate);
        n60_graph_retire(g);
    }
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) testRate(rate);
    if (failures) {
        std::fprintf(stderr, "n60core multiband extras: %d failures\n", failures);
        return 1;
    }
    std::puts("n60core multiband extras: ok");
    return 0;
}
