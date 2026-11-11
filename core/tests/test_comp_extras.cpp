// E28 S7a (ABI v34): behaviour of the compressor extras at the eight standard rates: a 15-value block with defaults is
// bit-identical to the 10-value block, mix, link amount, the RMS detector and its window, lookahead (delay equals the
// reported latency, a burst no longer overshoots), the switch-on step, block-size independence, validation, and live
// edits that allocate nothing is covered in test_alloc.cpp.
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

// thr, ratio, knee, attack, release, makeup, topology, pdr, hp, linked, mix, link, detector, window, lookahead
struct Comp {
    float p[15] = {-20, 4, 0, 1, 100, 0, 0, 0, 0, 1, 100, 100, 0, 50, 0};
};

n60_graph *build(double rate, const float *p, uint32_t count, uint32_t channels, n60_status *st = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_COMPRESSOR;
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

Lanes renderOnce(double rate, const float *p, uint32_t count, const Lanes &in, uint32_t block) {
    n60_graph *g = build(rate, p, count, (uint32_t)in.size());
    Lanes out = run(g, in, block);
    n60_graph_retire(g);
    return out;
}

uint32_t rng = 12345;
float noise() {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}

std::vector<float> sine(double rate, double hz, double amp, size_t n) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}

double peakOf(const std::vector<float> &v, size_t from, size_t to) {
    double m = 0;
    for (size_t i = from; i < to; ++i) m = std::max(m, (double)std::fabs(v[i]));
    return m;
}
double dbOf(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }

void defaultsAreV20(double rate) {
    const size_t n = (size_t)(0.3 * rate);
    for (int linked = 0; linked < 2; ++linked) {
        for (int fb = 0; fb < 2; ++fb) {
            Comp c;
            c.p[9] = (float)linked;
            c.p[6] = (float)fb;
            c.p[7] = 1;
            c.p[8] = 80;
            Lanes in(3, std::vector<float>(n));
            for (size_t i = 0; i < n; ++i) {
                in[0][i] = 1.2f * noise();
                in[1][i] = 0.1f * noise() * (i < n / 2 ? 1.0f : 8.0f);
                in[2][i] = 0.6f * noise();
            }
            const Lanes a = renderOnce(rate, c.p, 10, in, 256), b = renderOnce(rate, c.p, 15, in, 256);
            bool same = true;
            for (size_t l = 0; l < 3; ++l) same = same && std::memcmp(a[l].data(), b[l].data(), n * sizeof(float)) == 0;
            check(same, rate, "15 values with defaults equal the 10-value stage", linked, fb);
        }
    }
}

void mixChecks(double rate) {
    const size_t n = (size_t)(0.3 * rate);
    Lanes in(2, std::vector<float>(n));
    for (size_t i = 0; i < n; ++i) { in[0][i] = 0.9f * noise(); in[1][i] = 0.9f * noise(); }
    Comp c;
    c.p[0] = -30;
    const Lanes full = renderOnce(rate, c.p, 15, in, 512);
    c.p[10] = 0;
    const Lanes dry = renderOnce(rate, c.p, 15, in, 512);
    c.p[10] = 50;
    const Lanes half = renderOnce(rate, c.p, 15, in, 512);
    double worstDry = 0, worstHalf = 0;
    for (size_t l = 0; l < 2; ++l) {
        for (size_t i = 0; i < n; ++i) {
            worstDry = std::max(worstDry, (double)std::fabs(dry[l][i] - in[l][i]));
            worstHalf = std::max(worstHalf, (double)std::fabs(half[l][i] - 0.5f * (in[l][i] + full[l][i])));
        }
    }
    check(worstDry == 0.0, rate, "mix 0 is the dry signal", worstDry);
    check(worstHalf < 1e-6, rate, "mix 50 is the mean of dry and wet", worstHalf);
    // With lookahead mix 0 is the delayed dry.
    const uint32_t L = (uint32_t)std::lround(5.0 * rate / 1000.0);
    c.p[10] = 0;
    c.p[14] = (float)L;
    const Lanes dd = renderOnce(rate, c.p, 15, in, 512);
    double worst = 0;
    for (size_t i = L; i < n; ++i) worst = std::max(worst, (double)std::fabs(dd[0][i] - in[0][i - L]));
    check(worst == 0.0, rate, "mix 0 with lookahead is the delayed dry", worst);
}

void linkChecks(double rate) {
    const size_t n = (size_t)(0.4 * rate);
    Lanes in(2, std::vector<float>(n));
    in[0] = sine(rate, 440, 0.8, n);
    in[1] = sine(rate, 440, 0.01, n);
    Comp c;
    c.p[0] = -20;
    c.p[1] = 8;
    c.p[3] = 0.5f;
    c.p[5] = 0;
    c.p[11] = 0;
    Lanes out = renderOnce(rate, c.p, 15, in, 256);
    const size_t from = n - (size_t)(0.1 * rate);
    check(std::fabs(dbOf(peakOf(out[1], from, n)) - dbOf(0.01)) < 0.01, rate, "link 0 keeps the quiet lane untouched");
    check(dbOf(peakOf(out[0], from, n)) < dbOf(0.8) - 3.0, rate, "link 0 still compresses the loud lane");
    c.p[11] = 100;
    out = renderOnce(rate, c.p, 15, in, 256);
    check(dbOf(peakOf(out[1], from, n)) < dbOf(0.01) - 3.0, rate, "link 100 pulls the quiet lane down with the loud one");
    c.p[11] = 50;
    const Lanes mid = renderOnce(rate, c.p, 15, in, 256);
    const double mg = dbOf(peakOf(mid[1], from, n)) - dbOf(0.01);
    check(mg < -0.5 && mg > dbOf(peakOf(out[1], from, n)) - dbOf(0.01), rate, "link 50 sits between", mg);
}

// Steady sine, ratio 100, slow release: the peak detector reduces by about slope * (A - thr); RMS reads 3.01 dB lower.
double steadyGainDb(double rate, int rms, float window, double amp) {
    const size_t n = (size_t)(0.6 * rate);
    Lanes in(1, sine(rate, 1000, amp, n));
    Comp c;
    c.p[0] = -20;
    c.p[1] = 100;
    c.p[3] = 0.05f;
    c.p[4] = 5000;
    c.p[12] = (float)rms;
    c.p[13] = window;
    c.p[9] = 0;
    const Lanes out = renderOnce(rate, c.p, 15, in, 512);
    return dbOf(peakOf(out[0], n - (size_t)(0.1 * rate), n)) - dbOf(amp);
}

void rmsChecks(double rate) {
    const double peak = steadyGainDb(rate, 0, 50, 0.5), rms = steadyGainDb(rate, 1, 50, 0.5);
    const double diff = rms - peak;  // RMS reduces less by 0.99 * 3.01 dB
    check(std::fabs(diff - 0.99 * 3.0103) < 0.1, rate, "RMS reads a sine 3.01 dB below peak", diff, peak);
    // Window: DC at 0.5 crosses the threshold when sqrt(1 - exp(-t/tau)) = 0.5 sqrt(2)^-1... i.e. at tau * ln 2.
    for (float w : {20.0f, 100.0f}) {
        const size_t n = (size_t)(0.5 * rate);
        Lanes in(1, std::vector<float>(n, 0.5f));
        Comp c;
        c.p[0] = -9.0309f;
        c.p[1] = 100;
        c.p[3] = 0.05f;
        c.p[4] = 5000;
        c.p[9] = 0;
        c.p[12] = 1;
        c.p[13] = w;
        const Lanes out = renderOnce(rate, c.p, 15, in, 512);
        size_t first = n;
        for (size_t i = 0; i < n; ++i) {
            if (out[0][i] < 0.5f * 0.999f) { first = i; break; }
        }
        const double ms = 1000.0 * (double)first / rate, want = w * std::log(2.0);
        check(std::fabs(ms - want) < 0.02 * want, rate, "RMS window within 2 %", ms, want);
    }
}

void lookaheadChecks(double rate) {
    for (float ms : {1.0f, 5.0f, 10.0f}) {
        const uint32_t L = (uint32_t)std::lround(ms * rate / 1000.0);
        const size_t n = L + 2048;
        Lanes in(2, std::vector<float>(n, 0.0f));
        in[0][10] = 1.0f;
        Comp c;
        c.p[0] = 0;  // never reduces
        c.p[14] = (float)L;
        n60_graph *g = build(rate, c.p, 15, 2);
        const uint32_t reported = n60_graph_latency_frames(g);
        const Lanes out = run(g, in, 300);
        n60_graph_retire(g);
        size_t at = 0;
        for (size_t i = 0; i < n; ++i) if (out[0][i] != 0.0f) at = i;
        check(reported == L, rate, "reported latency is the lookahead", reported, L);
        check(at == 10 + L && out[0][at] == 1.0f, rate, "impulse delay equals the latency", (double)at, 10.0 + L);
    }
    // A 0 dBFS burst (a held full-scale level) after silence: with 5 ms lookahead and a 1 ms attack the output stays within 0.5 dB of the curve.
    const size_t n = (size_t)(0.12 * rate), start = (size_t)(0.02 * rate);
    Lanes in(1, std::vector<float>(n, 0.0f));
    for (size_t i = start; i < n; ++i) in[0][i] = 1.0f;  // a 0 dBFS step: the detector level is steady, so the curve is exact
    Comp c;
    c.p[0] = -20;
    c.p[1] = 10;
    c.p[3] = 1;
    c.p[4] = 200;
    c.p[9] = 0;
    const double ideal = dbOf(1.0) + (1.0 / 10.0 - 1.0) * (0.0 + 20.0);
    const double without = dbOf(peakOf(renderOnce(rate, c.p, 15, in, 256)[0], 0, n));
    c.p[14] = (float)std::lround(5.0 * rate / 1000.0);
    const double with = dbOf(peakOf(renderOnce(rate, c.p, 15, in, 256)[0], 0, n));
    check(with - ideal < 0.5, rate, "burst overshoots the curve by under 0.5 dB with lookahead", with, ideal);
    check(without - ideal > 1.0, rate, "the same burst overshoots without lookahead", without, ideal);
}

void switchOnStep(double rate) {
    // Rebuilding with lookahead on a -6 dBFS sine goes through the rebuild fade: no sample step above 1.05 x the sine's.
    const size_t n = (size_t)(0.6 * rate);
    Lanes in(1, sine(rate, 1000, 0.5, n));
    double own = 0;
    for (size_t i = 1; i < n; ++i) own = std::max(own, (double)std::fabs(in[0][i] - in[0][i - 1]));
    Comp a, b;
    a.p[0] = b.p[0] = 0;
    b.p[14] = (float)std::lround(5.0 * rate / 1000.0);
    n60_stage_desc s[2];
    const float *pr[2] = {a.p, b.p};
    n60_graph_desc d[2];
    for (int k = 0; k < 2; ++k) {
        std::memset(&s[k], 0, sizeof s[k]);
        s[k].structSize = sizeof s[k];
        s[k].kind = N60_STAGE_COMPRESSOR;
        s[k].stageId = 5;
        s[k].laneA = N60_LANE_ALL;
        s[k].params = pr[k];
        s[k].paramCount = 15;
        std::memset(&d[k], 0, sizeof d[k]);
        d[k].structSize = sizeof d[k];
        d[k].abiVersion = N60_GRAPH_ABI_VERSION;
        d[k].sampleRate = rate;
        d[k].maxBlockFrames = 4096;
        d[k].inputChannels = d[k].outputChannels = 1;
        d[k].stages = &s[k];
        d[k].stageCount = 1;
    }
    n60_graph *g = nullptr;
    if (n60_graph_build(&d[0], &g) != N60_STATUS_OK) { check(false, rate, "build"); return; }
    const n60_rebuild_options linear{sizeof(n60_rebuild_options), 20.0f, 0.0f, 1u};  // the same signal in both graphs
    n60_graph_set_rebuild_options(g, &linear);
    std::vector<float> out(n);
    const size_t half = n / 3;
    for (size_t off = 0; off < n; off += 256) {
        if (off == half / 256 * 256) n60_graph_publish(g, &d[1]);
        const uint32_t m = (uint32_t)std::min<size_t>(256, n - off);
        const float *ip[1] = {in[0].data() + off};
        float *op[1] = {out.data() + off};
        n60_graph_process(g, ip, op, m);
    }
    n60_graph_retire(g);
    double step = 0;
    size_t where = 0;
    for (size_t i = 1; i < n; ++i) if (std::fabs(out[i] - out[i - 1]) > step) { step = std::fabs(out[i] - out[i - 1]); where = i; }
    if (step > 1.05 * own) std::fprintf(stderr, "step at %zu of %zu (switch %zu)\n", where, n, half);
    check(step <= 1.05 * own, rate, "switching lookahead on steps no more than 1.05x the sine's own step", step, own);
}

void blockSizes(double rate) {
    const size_t n = (size_t)(0.2 * rate);
    Lanes in(3, std::vector<float>(n));
    for (size_t i = 0; i < n; ++i) { in[0][i] = noise(); in[1][i] = 0.3f * noise(); in[2][i] = 1.1f * noise(); }
    Comp c;
    c.p[0] = -30;
    c.p[10] = 70;
    c.p[11] = 35;
    c.p[12] = 1;
    c.p[13] = 20;
    c.p[14] = (float)std::lround(3.0 * rate / 1000.0);
    const Lanes ref = renderOnce(rate, c.p, 15, in, 4096);
    for (uint32_t block : {1u, 13u, 256u}) {
        const Lanes o = renderOnce(rate, c.p, 15, in, block);
        bool same = true;
        for (size_t l = 0; l < 3; ++l) same = same && std::memcmp(ref[l].data(), o[l].data(), n * sizeof(float)) == 0;
        check(same, rate, "block size does not change the result", block);
    }
}

void liveAndValidation(double rate) {
    Comp c;
    n60_status st;
    n60_graph *g = build(rate, c.p, 15, 2, &st);
    check(g != nullptr, rate, "15-value block builds");
    if (g) {
        n60_param_record ok[4] = {{5, 10, 50.0f, 0}, {5, 11, 25.0f, 0}, {5, 12, 1.0f, 0}, {5, 13, 80.0f, 0}};
        check(n60_graph_post_params(g, ok, 4) == N60_STATUS_OK, rate, "mix, link, detector and window are live");
        n60_graph_retire(g);
    }
    Comp bad = c;
    bad.p[10] = 101;
    check(build(rate, bad.p, 15, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "mix above 100 refused");
    bad = c;
    bad.p[14] = 9000;
    check(build(rate, bad.p, 15, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "lookahead above the cap refused");
    bad = c;
    bad.p[14] = 2.5f;
    check(build(rate, bad.p, 15, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "fractional lookahead refused");
    check(build(rate, c.p, 12, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "a 12-value block is refused");
    g = build(rate, c.p, 10, 2, &st);
    check(g != nullptr, rate, "10-value block still builds");
    if (g) {
        n60_param_record rec = {5, 10, 50.0f, 0};
        (void)n60_graph_post_params(g, &rec, 1); // must not crash; an index past the block is dropped
        n60_graph_retire(g);
    }
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        defaultsAreV20(rate);
        mixChecks(rate);
        linkChecks(rate);
        rmsChecks(rate);
        lookaheadChecks(rate);
        switchOnStep(rate);
        blockSizes(rate);
        liveAndValidation(rate);
    }
    if (failures == 0) std::printf("comp extras: ok\n");
    return failures == 0 ? 0 : 1;
}
