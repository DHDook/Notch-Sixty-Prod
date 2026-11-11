// E28 S7b (ABI v35): behaviour of the expander extras and sidechain / delta listen at the eight standard rates: a 13-value
// expander block with defaults is bit-identical to the 6-value block, the soft knee against its analytic law (C1 at both
// edges), hold within one sample, the sidechain high-pass, the RMS detector, link, listen on the expander and the
// compressor (sidechain through the lookahead ring, delta before make-up), crossfade steps, block-size independence and
// validation.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
int failures = 0;
void check(bool ok, double rate, const char *what, double a = 0, double b = 0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f (%g, %g)\n", what, rate, a, b); ++failures; }
}

// thr, ratio, range, attack, release, linked, hold, knee, detector, window, hpf, link, listen
struct Exp {
    float p[13] = {-30, 3, -24, 1, 50, 1, 0, 0, 0, 50, 0, 100, 0};
};
// thr, ratio, knee, attack, release, makeup, topology, pdr, hp, linked, mix, link, detector, window, lookahead, listen
struct Comp {
    float p[16] = {-20, 4, 0, 1, 20, 0, 0, 0, 0, 1, 100, 100, 0, 50, 0, 0};
};

n60_graph *build(uint32_t kind, double rate, const float *p, uint32_t count, uint32_t channels, n60_status *st = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = 5;
    s.laneA = N60_LANE_ALL;
    s.params = p;
    s.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 4096;
    d.inputChannels = d.outputChannels = channels;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    const n60_status r = n60_graph_build(&d, &g);
    if (st) *st = r;
    return r == N60_STATUS_OK ? g : nullptr;
}

using Lanes = std::vector<std::vector<float>>;

Lanes run(n60_graph *g, const Lanes &in, uint32_t block) {
    const size_t n = in[0].size(), ch = in.size();
    Lanes out(ch, std::vector<float>(n));
    for (size_t off = 0; off < n; off += block) {
        const uint32_t m = (uint32_t)std::min<size_t>(block, n - off);
        const float *ip[N60_GRAPH_MAX_CHANNELS];
        float *op[N60_GRAPH_MAX_CHANNELS];
        for (size_t c = 0; c < ch; ++c) { ip[c] = in[c].data() + off; op[c] = out[c].data() + off; }
        n60_graph_process(g, ip, op, m);
    }
    return out;
}

Lanes renderOnce(uint32_t kind, double rate, const float *p, uint32_t count, const Lanes &in, uint32_t block) {
    n60_graph *g = build(kind, rate, p, count, (uint32_t)in.size());
    if (!g) return Lanes(in.size());
    Lanes out = run(g, in, block);
    n60_graph_retire(g);
    return out;
}

uint32_t rng = 777;
float noise() {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}
std::vector<float> sine(double rate, double hz, double amp, size_t n) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}
double dbOf(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }
double rmsOf(const std::vector<float> &v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(to - from));
}

void defaultsAreV20(double rate) {
    const size_t n = (size_t)(0.3 * rate);
    for (int linked = 0; linked < 2; ++linked) {
        Exp e;
        e.p[5] = (float)linked;
        Lanes in(3, std::vector<float>(n));
        for (size_t i = 0; i < n; ++i) {
            in[0][i] = 0.3f * noise() * (i < n / 2 ? 1.0f : 0.02f);
            in[1][i] = 0.1f * noise();
            in[2][i] = 0.01f * noise() * (i < n / 3 ? 1.0f : 8.0f);
        }
        const Lanes a = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 6, in, 256);
        const Lanes b = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 256);
        bool same = true;
        for (size_t l = 0; l < 3; ++l) same = same && std::memcmp(a[l].data(), b[l].data(), n * sizeof(float)) == 0;
        check(same, rate, "13 values with defaults equal the 6-value expander", linked);
    }
}

// Settled gain (dB) of a constant input of `levelDb` under the 13-value block.
double settledGainDb(double rate, Exp e, double levelDb) {
    const size_t n = (size_t)(0.05 * rate);
    const float amp = (float)std::pow(10.0, levelDb / 20.0);
    Lanes in(1, std::vector<float>(n, amp));
    const Lanes out = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 512);
    return dbOf(out[0][n - 1]) - levelDb;
}

double analytic(double over, double ratio, double knee, double range) {
    const double s = ratio - 1.0, half = knee * 0.5;
    double c;
    if (over >= half) c = 0;
    else if (over > -half) c = -s * (over - half) * (over - half) / (2.0 * knee);
    else c = s * over;
    return std::max(c, range);
}

void kneeChecks(double rate) {
    Exp e;
    e.p[0] = -40; e.p[1] = 3; e.p[2] = -60; e.p[3] = 0.05f; e.p[4] = 1; e.p[7] = 12;
    double worst = 0;
    for (double lvl = -60; lvl <= -25; lvl += 1.0) {
        worst = std::max(worst, std::fabs(settledGainDb(rate, e, lvl) - analytic(lvl + 40, 3, 12, -60)));
    }
    check(worst < 0.02, rate, "knee curve matches the analytic law", worst);
    // C1 at the edges: the measured slope just inside and outside agrees.
    for (double edge : {-46.0, -34.0}) {
        const double d = 0.25;
        const double sOut = (settledGainDb(rate, e, edge - (edge < -40 ? d : -d) ) - settledGainDb(rate, e, edge - (edge < -40 ? 2 * d : -2 * d))) / (edge < -40 ? d : -d);
        const double sIn = (settledGainDb(rate, e, edge + (edge < -40 ? d : -d)) - settledGainDb(rate, e, edge)) / (edge < -40 ? d : -d);
        // Level step is in dB of input; slope = d(gain)/d(level).
        check(std::fabs(sOut - sIn) < 0.15, rate, "knee is C1 at its edges", sOut, sIn);
    }
    e.p[7] = 0;
    const double hard = settledGainDb(rate, e, -45);
    check(std::fabs(hard - analytic(-5, 3, 0, -60)) < 0.02, rate, "knee 0 is the hard law", hard);
}

void holdChecks(double rate) {
    for (float holdMs : {10.0f, 50.0f, 200.0f}) {
        Exp e;
        e.p[0] = -40; e.p[2] = -24; e.p[3] = 0.05f; e.p[4] = 400; e.p[6] = holdMs;
        const size_t open = (size_t)(0.05 * rate), n = open + (size_t)(0.4 * rate);
        Lanes in(1, std::vector<float>(n, 0.5f));
        for (size_t i = open; i < n; ++i) in[0][i] = 0.001f;
        const Lanes out = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 300);
        size_t first = 0;
        for (size_t i = open; i < n; ++i) {
            if (out[0][i] < 0.001f * 0.9999f) { first = i - open; break; }
        }
        const long want = std::lround((double)holdMs * rate / 1000.0);
        check(std::labs((long)first - want) <= 1, rate, "hold lasts its time within one sample", (double)first, (double)want);
    }
}

void highPassAndDetector(double rate) {
    const size_t n = (size_t)(0.6 * rate);
    Exp e;
    e.p[0] = -20; e.p[1] = 4; e.p[2] = -30; e.p[3] = 1; e.p[4] = 20;
    Lanes in(1, sine(rate, 40, 0.316, n));
    const Lanes open = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 512);
    e.p[10] = 100;
    const Lanes hp = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 512);
    const double tail0 = rmsOf(open[0], n / 2, n), tail1 = rmsOf(hp[0], n / 2, n);
    check(dbOf(tail1) < dbOf(tail0) - 3.0, rate, "a 100 Hz sidechain filter keeps a 40 Hz tone from opening it", dbOf(tail1));
    // RMS reads a sine 3 dB below its peak: a 0.5 sine has an RMS of -9.03 dB, so a -12 dB threshold leaves it open and a
    // -6 dB threshold with ratio 2 expands it by about 3 dB.
    Exp r;
    r.p[0] = -12; r.p[1] = 2; r.p[2] = -30; r.p[3] = 0.5f; r.p[4] = 5; r.p[8] = 1; r.p[9] = 100;
    Lanes tone(1, sine(rate, 1000, 0.5, n));
    const Lanes rm = renderOnce(N60_STAGE_EXPANDER, rate, r.p, 13, tone, 512);
    r.p[0] = -6;
    const Lanes rc = renderOnce(N60_STAGE_EXPANDER, rate, r.p, 13, tone, 512);
    const double g0 = dbOf(rmsOf(rm[0], n / 2, n)) - dbOf(rmsOf(tone[0], n / 2, n));
    const double g1 = dbOf(rmsOf(rc[0], n / 2, n)) - dbOf(rmsOf(tone[0], n / 2, n));
    check(std::fabs(g0) < 0.2, rate, "RMS detector keeps the sine open at -12 dB", g0);
    check(g1 < -2.6 && g1 > -3.4, rate, "RMS detector expands the sine by about 3 dB at -6 dB", g1);
    // Link 0 keeps a loud left lane from opening the right lane.
    Exp k;
    k.p[0] = -30; k.p[1] = 4; k.p[2] = -40; k.p[3] = 1; k.p[4] = 20; k.p[11] = 0;
    Lanes two(2, std::vector<float>(n));
    two[0] = sine(rate, 1000, 0.5, n);
    two[1] = sine(rate, 1000, 0.002, n);
    const Lanes unl = renderOnce(N60_STAGE_EXPANDER, rate, k.p, 13, two, 256);
    k.p[11] = 100;
    const Lanes lnk = renderOnce(N60_STAGE_EXPANDER, rate, k.p, 13, two, 256);
    const double rIn = rmsOf(two[1], n / 2, n);
    check(dbOf(rmsOf(unl[1], n / 2, n)) - dbOf(rIn) < -10.0, rate, "link 0 expands the quiet lane on its own", 0);
    const double gq = dbOf(rmsOf(lnk[1], n / 2, n)) - dbOf(rIn);
    const double gl = dbOf(rmsOf(lnk[0], n / 2, n)) - dbOf(rmsOf(two[0], n / 2, n));
    check(std::fabs(gq - gl) < 0.05, rate, "link 100 gives both lanes the same gain", gq, gl);
}

void listenChecks(double rate) {
    const size_t n = (size_t)(0.4 * rate), tail = n / 2;
    // Expander sidechain listen with no filter is the input; with a filter 1 kHz passes and 40 Hz is cut.
    Exp e;
    e.p[0] = -20; e.p[1] = 4; e.p[12] = 1;
    Lanes in(2, std::vector<float>(n));
    for (size_t i = 0; i < n; ++i) { in[0][i] = 0.3f * noise(); in[1][i] = 0.05f * noise(); }
    const Lanes sc = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 333);
    double worst = 0;
    for (size_t l = 0; l < 2; ++l)
        for (size_t i = tail; i < n; ++i) worst = std::max(worst, (double)std::fabs(sc[l][i] - in[l][i]));
    check(worst < 1e-6, rate, "expander sidechain listen is the detector input", worst);
    e.p[10] = 100;
    Lanes tones(1, sine(rate, 1000, 0.3, n));
    const Lanes pass = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, tones, 512);
    Lanes low(1, sine(rate, 40, 0.3, n));
    const Lanes cut = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, low, 512);
    check(std::fabs(dbOf(rmsOf(pass[0], tail, n)) - dbOf(rmsOf(tones[0], tail, n))) < 0.01, rate, "listen passes 1 kHz at unity");
    check(dbOf(rmsOf(cut[0], tail, n)) - dbOf(rmsOf(low[0], tail, n)) < -10.0, rate, "listen shows the filtered 40 Hz");
    // Expander delta: dry minus wet.
    Exp d;
    d.p[0] = -20; d.p[1] = 4; d.p[2] = -30; d.p[3] = 1; d.p[4] = 20;
    Lanes q(1, sine(rate, 1000, 0.01, n));
    const Lanes wet = renderOnce(N60_STAGE_EXPANDER, rate, d.p, 13, q, 256);
    d.p[12] = 2;
    const Lanes del = renderOnce(N60_STAGE_EXPANDER, rate, d.p, 13, q, 256);
    worst = 0;
    for (size_t i = tail; i < n; ++i) worst = std::max(worst, (double)std::fabs(del[0][i] - (q[0][i] - wet[0][i])));
    check(worst < 1e-6, rate, "expander delta listen is dry minus wet", worst);

    // Compressor sidechain listen through the lookahead ring.
    const uint32_t L = (uint32_t)std::lround(5.0 * rate / 1000.0);
    Comp c;
    c.p[14] = (float)L;
    c.p[15] = 1;
    c.p[5] = 6;  // make-up must not appear
    Lanes x(2, std::vector<float>(n));
    for (size_t i = 0; i < n; ++i) { x[0][i] = 0.8f * noise(); x[1][i] = 0.4f * noise(); }
    n60_graph *g = build(N60_STAGE_COMPRESSOR, rate, c.p, 16, 2);
    check(g != nullptr, rate, "16-value compressor block builds");
    if (!g) return;
    const uint32_t lat = n60_graph_latency_frames(g);
    const Lanes cs = run(g, x, 512);
    n60_graph_retire(g);
    worst = 0;
    for (size_t l = 0; l < 2; ++l)
        for (size_t i = tail; i < n; ++i) worst = std::max(worst, (double)std::fabs(cs[l][i] - x[l][i - L]));
    check(worst < 1e-6, rate, "compressor sidechain listen is the delayed detector input", worst);
    check(lat == L, rate, "listen does not change the reported latency", lat, L);
    // Delta before make-up: with listen 0 and make-up 0 the same gain trajectory settles to the same gain.
    Comp dc;
    dc.p[3] = 1; dc.p[4] = 5;
    dc.p[5] = 6;
    dc.p[15] = 2;
    const Lanes dl = renderOnce(N60_STAGE_COMPRESSOR, rate, dc.p, 16, x, 256);
    dc.p[5] = 0;
    dc.p[15] = 0;
    const Lanes w0 = renderOnce(N60_STAGE_COMPRESSOR, rate, dc.p, 16, x, 256);
    worst = 0;
    for (size_t l = 0; l < 2; ++l)
        for (size_t i = (size_t)(0.2 * rate); i < n; ++i)
            worst = std::max(worst, (double)std::fabs(dl[l][i] - (x[l][i] - w0[l][i])));
    check(worst < 1e-5, rate, "compressor delta listen is dry minus wet before make-up", worst);
    // Silent below -120 dBFS with no reduction.
    Comp sc2;
    sc2.p[15] = 2;
    sc2.p[5] = 0;
    Lanes tiny(1, sine(rate, 1000, 1e-6, n));
    const Lanes z = renderOnce(N60_STAGE_COMPRESSOR, rate, sc2.p, 16, tiny, 512);
    double peak = 0;
    for (size_t i = tail; i < n; ++i) peak = std::max(peak, (double)std::fabs(z[0][i]));
    check(peak == 0.0, rate, "delta listen is silent with no reduction", peak);
    // Both stages with listen 0: the 16-value block equals the 15-value one.
    Comp zero;
    const Lanes a15 = renderOnce(N60_STAGE_COMPRESSOR, rate, zero.p, 15, x, 256);
    const Lanes a16 = renderOnce(N60_STAGE_COMPRESSOR, rate, zero.p, 16, x, 256);
    check(std::memcmp(a15[0].data(), a16[0].data(), n * sizeof(float)) == 0, rate, "listen 0 equals the 15-value block");
}

void switchStep(double rate) {
    const size_t n = (size_t)(0.5 * rate);
    Comp c;
    c.p[0] = -20; c.p[1] = 4;
    Lanes in(1, sine(rate, 1000, 0.5, n));
    n60_graph *g = build(N60_STAGE_COMPRESSOR, rate, c.p, 16, 1);
    if (!g) { check(false, rate, "switch graph builds"); return; }
    Lanes out(1, std::vector<float>(n));
    const uint32_t block = 64;
    for (size_t off = 0; off < n; off += block) {
        if (off == n / 3) { n60_param_record r = {5, 15, 1.0f, 0}; (void)n60_graph_post_params(g, &r, 1); }
        if (off == 2 * n / 3) { n60_param_record r = {5, 15, 2.0f, 0}; (void)n60_graph_post_params(g, &r, 1); }
        const float *ip[1] = {in[0].data() + off};
        float *op[1] = {out[0].data() + off};
        n60_graph_process(g, ip, op, block);
    }
    n60_graph_retire(g);
    double own = 0, step = 0;
    for (size_t i = 1; i < n; ++i) {
        own = std::max(own, (double)std::fabs(in[0][i] - in[0][i - 1]));
        step = std::max(step, (double)std::fabs(out[0][i] - out[0][i - 1]));
    }
    check(step <= own * 1.05, rate, "listen switches step no more than the sine's own step", step, own);
}

void blockSizes(double rate) {
    const size_t n = (size_t)(0.25 * rate);
    Exp e;
    e.p[0] = -25; e.p[1] = 3; e.p[3] = 0.5f; e.p[4] = 30; e.p[6] = 20; e.p[7] = 8; e.p[8] = 1; e.p[10] = 80;
    e.p[11] = 40; e.p[12] = 1;
    Lanes in(2, std::vector<float>(n));
    for (size_t i = 0; i < n; ++i) { in[0][i] = 0.4f * noise(); in[1][i] = 0.05f * noise(); }
    const Lanes ref = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, 4096);
    for (uint32_t block : {1u, 13u, 256u}) {
        const Lanes o = renderOnce(N60_STAGE_EXPANDER, rate, e.p, 13, in, block);
        bool same = true;
        for (size_t l = 0; l < 2; ++l) same = same && std::memcmp(ref[l].data(), o[l].data(), n * sizeof(float)) == 0;
        check(same, rate, "block size does not change the expander result", block);
    }
}

void liveAndValidation(double rate) {
    Exp e;
    n60_status st;
    n60_graph *g = build(N60_STAGE_EXPANDER, rate, e.p, 13, 2, &st);
    check(g != nullptr, rate, "13-value expander builds");
    if (g) {
        n60_param_record ok[6] = {{5, 6, 20.0f, 0}, {5, 7, 6.0f, 0}, {5, 8, 1.0f, 0}, {5, 9, 80.0f, 0}, {5, 10, 100.0f, 0}, {5, 12, 1.0f, 0}};
        check(n60_graph_post_params(g, ok, 6) == N60_STATUS_OK, rate, "hold, knee, detector, window, filter and listen are live");
        n60_param_record link = {5, 11, 30.0f, 0};
        check(n60_graph_post_params(g, &link, 1) == N60_STATUS_OK, rate, "link is live");
        n60_graph_retire(g);
    }
    Exp bad = e;
    bad.p[6] = 501;
    check(build(N60_STAGE_EXPANDER, rate, bad.p, 13, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "hold above 500 refused");
    bad = e; bad.p[7] = 25;
    check(build(N60_STAGE_EXPANDER, rate, bad.p, 13, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "knee above 24 refused");
    bad = e; bad.p[10] = 301;
    check(build(N60_STAGE_EXPANDER, rate, bad.p, 13, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "filter above 300 refused");
    bad = e; bad.p[12] = 3;
    check(build(N60_STAGE_EXPANDER, rate, bad.p, 13, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "listen 3 refused");
    check(build(N60_STAGE_EXPANDER, rate, e.p, 8, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "an 8-value block is refused");
    Comp c;
    bad = e;
    c.p[15] = 3;
    check(build(N60_STAGE_COMPRESSOR, rate, c.p, 16, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "compressor listen 3 refused");
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        defaultsAreV20(rate);
        kneeChecks(rate);
        holdChecks(rate);
        highPassAndDetector(rate);
        listenChecks(rate);
        switchStep(rate);
        blockSizes(rate);
        liveAndValidation(rate);
    }
    if (failures == 0) std::printf("exp extras OK\n");
    return failures == 0 ? 0 : 1;
}
