// E33 S5a (ABI v41): expander lookahead at the eight standard rates. A 14-value block with lookahead 0 is bit-identical to the
// 13-value block; the reported latency equals the measured impulse delay; a gated tone burst's first period passes within 0.1 dB
// of dry when the lookahead covers the opening time; the ring and gain state carry across a rebuild (same and changed
// lookahead); block-size independence with listen on; the lookahead is validated and fixed at build.
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

// thr, ratio, range, attack, release, linked, hold, knee, detector, window, hpf, link, listen, lookahead frames
struct Exp {
    float p[16] = {-30, 3, -24, 1, 50, 1, 0, 0, 0, 50, 0, 100, 0, 0, 0, 0};  // two spare values for the over-long block check
};
using Lanes = std::vector<std::vector<float>>;

n60_stage_desc stageOf(const float *p, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_EXPANDER;
    s.stageId = 5;
    s.laneA = N60_LANE_ALL;
    s.params = p;
    s.paramCount = count;
    return s;
}
n60_graph_desc descOf(n60_stage_desc *s, double rate, uint32_t channels) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 4096;
    d.inputChannels = d.outputChannels = channels;
    d.stages = s;
    d.stageCount = 1;
    return d;
}
n60_graph *build(double rate, const float *p, uint32_t count, uint32_t channels, n60_status *st = nullptr) {
    n60_stage_desc s = stageOf(p, count);
    const n60_graph_desc d = descOf(&s, rate, channels);
    n60_graph *g = nullptr;
    const n60_status r = n60_graph_build(&d, &g);
    if (st) *st = r;
    return r == N60_STATUS_OK ? g : nullptr;
}
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
    if (!g) return Lanes(in.size());
    Lanes out = run(g, in, block);
    n60_graph_retire(g);
    return out;
}
uint32_t rng = 4242;
float noise() {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}
bool same(const Lanes &a, const Lanes &b) {
    for (size_t l = 0; l < a.size(); ++l) {
        if (std::memcmp(a[l].data(), b[l].data(), a[l].size() * sizeof(float)) != 0) return false;
    }
    return true;
}

void zeroLookaheadIsBitIdentical(double rate) {
    const size_t n = (size_t)(0.3 * rate);
    for (int linked = 0; linked < 2; ++linked) {
        for (int listen = 0; listen < 3; ++listen) {
            Exp e;
            e.p[5] = (float)linked;
            e.p[6] = 20; e.p[7] = 6; e.p[10] = 80; e.p[11] = 60;  // hold, knee, sidechain filter, link
            e.p[12] = (float)listen;
            Lanes in(3, std::vector<float>(n));
            for (size_t i = 0; i < n; ++i) {
                in[0][i] = 0.3f * noise() * (i < n / 2 ? 1.0f : 0.02f);
                in[1][i] = 0.1f * noise();
                in[2][i] = 0.01f * noise() * (i < n / 3 ? 1.0f : 8.0f);
            }
            check(same(renderOnce(rate, e.p, 13, in, 256), renderOnce(rate, e.p, 14, in, 256)), rate,
                  "lookahead 0 equals the 13-value block", linked, listen);
        }
    }
}

void latencyEqualsImpulseDelay(double rate) {
    const uint32_t looks[] = {1, 7, (uint32_t)(rate * 0.003), (uint32_t)(rate * 0.010)};
    for (uint32_t look : looks) {
        Exp e;
        e.p[1] = 1;  // ratio 1: the gain never leaves 0 dB, so the stage is a pure delay
        e.p[13] = (float)look;
        n60_graph *g = build(rate, e.p, 14, 2);
        if (!g) { check(false, rate, "14-value expander builds"); continue; }
        check(n60_graph_latency_frames(g) == look, rate, "reported latency equals the lookahead", n60_graph_latency_frames(g), look);
        const size_t n = look + 600;
        Lanes in(2, std::vector<float>(n, 0.0f));
        in[0][100] = 0.5f;
        in[1][37] = -0.25f;
        const Lanes out = run(g, in, 128);
        check(out[0][100 + look] == 0.5f && out[1][37 + look] == -0.25f, rate, "measured impulse delay equals the lookahead", out[0][100 + look]);
        double stray = 0;
        for (size_t i = 0; i < n; ++i) {
            if (i != 100 + look) stray = std::max(stray, (double)std::fabs(out[0][i]));
        }
        check(stray == 0.0, rate, "no other output", stray);
        n60_graph_retire(g);
    }
}

double rmsOf(const std::vector<float> &v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(to - from));
}

// Silence closes the gate to its range; a tone burst then starts. The opening time constant is 1 ms (attack = release = 1 ms, so
// the test does not depend on which of the two the core maps to opening); a lookahead of eight of them has the gate open when the
// burst reaches the output (the threshold sits far below the tone, so the peak detector's zero crossings do not ripple the gain), so the first period equals dry within 0.1 dB, while without lookahead it is clearly attenuated.
void burstFirstPeriod(double rate) {
    const double hz = 1000.0, amp = 0.3;
    const size_t t0 = (size_t)(0.15 * rate), period = (size_t)std::lround(rate / hz), n = t0 + 90 * period + (size_t)(0.02 * rate);
    std::vector<float> tone(n, 0.0f);
    for (size_t i = t0; i < t0 + 80 * period; ++i) tone[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)(i - t0) / rate));
    Lanes in(1, tone);
    for (uint32_t withLook = 0; withLook < 2; ++withLook) {
        Exp e;
        e.p[0] = -70; e.p[1] = 4; e.p[2] = -60; e.p[3] = 1; e.p[4] = 1;
        const uint32_t look = withLook ? (uint32_t)std::lround(0.02 * rate) : 0;
        e.p[13] = (float)look;
        const Lanes out = renderOnce(rate, e.p, 14, in, 512);
        const double dry = rmsOf(out[0], t0 + look + 50 * period, t0 + look + 51 * period), got = rmsOf(out[0], t0 + look, t0 + look + period);
        const double dbErr = 20.0 * std::log10(std::max(got, 1e-12) / dry);
        if (withLook) check(std::fabs(dbErr) < 0.1, rate, "first period within 0.1 dB of the settled level with lookahead", dbErr);
        else check(dbErr < -1.0, rate, "without lookahead the first period is clearly attenuated", dbErr);
    }
}

void blockSizesWithListen(double rate) {
    const size_t n = (size_t)(0.2 * rate);
    for (int listen = 0; listen < 3; ++listen) {
        Exp e;
        e.p[12] = (float)listen;
        e.p[13] = (float)std::lround(0.004 * rate);
        Lanes in(3, std::vector<float>(n));
        for (size_t i = 0; i < n; ++i) {
            const float env = (i / (size_t)(0.03 * rate)) % 2 ? 0.01f : 0.4f;
            for (int l = 0; l < 3; ++l) in[l][i] = env * noise();
        }
        const Lanes a = renderOnce(rate, e.p, 14, in, 4096), b = renderOnce(rate, e.p, 14, in, 61), c = renderOnce(rate, e.p, 14, in, 1);
        check(same(a, b) && same(a, c), rate, "output does not depend on block size", listen);
    }
}

// Gate held open (ratio 1) so the output is the input delayed; after the swap the carried graph equals one built at the new
// lookahead from the start, wherever the carried ring holds audio.
void ringCarry(double rate) {
    const size_t pre = (size_t)(rate * 0.2) / 512 * 512, post = (size_t)(rate * 0.1) / 512 * 512;
    Lanes all(2, std::vector<float>(pre + post));
    for (auto &lane : all) for (auto &x : lane) x = 0.4f * noise();
    Lanes in1(2), in2(2);
    for (int l = 0; l < 2; ++l) {
        in1[l].assign(all[l].begin(), all[l].begin() + (long)pre);
        in2[l].assign(all[l].begin() + (long)pre, all[l].end());
    }
    const uint32_t a4 = (uint32_t)(rate * 0.004), a15 = (uint32_t)(rate * 0.0015);
    const uint32_t looks[3][2] = {{a4, a15}, {a15, a4}, {a4, a4}};
    for (const auto &lk : looks) {
        Exp a, b;
        a.p[1] = b.p[1] = 1;
        a.p[13] = (float)lk[0];
        b.p[13] = (float)lk[1];
        n60_graph *g = build(rate, a.p, 14, 2), *ref = build(rate, b.p, 14, 2);
        if (!g || !ref) { check(false, rate, "ring carry builds"); return; }
        n60_rebuild_options o;
        std::memset(&o, 0, sizeof o);
        o.structSize = sizeof o;
        o.fadeMs = 0.0f;
        n60_graph_set_rebuild_options(g, &o);
        run(g, in1, 512);
        const Lanes refAll = run(ref, all, 512);
        n60_stage_desc sd = stageOf(b.p, 14);
        n60_graph_desc d = descOf(&sd, rate, 2);
        check(n60_graph_publish(g, &d) == N60_STATUS_OK, rate, "ring carry publish");
        const Lanes out2 = run(g, in2, 512);
        const size_t skip = lk[1] > lk[0] ? lk[1] - lk[0] : 0;
        double m = 0;
        for (int l = 0; l < 2; ++l) {
            for (size_t i = skip; i < out2[l].size(); ++i) m = std::max(m, std::fabs((double)out2[l][i] - (double)refAll[l][pre + i]));
        }
        check(m < 1e-6, rate, "carried ring matches a graph built at the new lookahead", m, (double)lk[1]);
        double lead = 0;
        for (size_t i = 0; i < 64; ++i) lead = std::max(lead, std::fabs((double)out2[0][i]));
        check(lead > 1e-4 || lk[1] > lk[0], rate, "no silent gap after the swap", lead);
        n60_graph_retire(g);
        n60_graph_retire(ref);
    }
}

void validation(double rate) {
    Exp e;
    n60_status st;
    e.p[13] = 8192;
    n60_graph *g = build(rate, e.p, 14, 2, &st);
    check(g != nullptr, rate, "the 8192-frame ring builds");
    if (g) {
        n60_param_record look = {5, 13, 100.0f, 0};
        check(n60_graph_post_params(g, &look, 1) != N60_STATUS_OK, rate, "the lookahead is fixed at build");
        n60_param_record hold = {5, 6, 20.0f, 0};
        check(n60_graph_post_params(g, &hold, 1) == N60_STATUS_OK, rate, "hold stays live");
        n60_graph_retire(g);
    }
    Exp bad = e;
    bad.p[13] = 8193;
    check(build(rate, bad.p, 14, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "8193 frames refused");
    bad.p[13] = 1.5f;
    check(build(rate, bad.p, 14, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "a fractional lookahead refused");
    bad.p[13] = -1;
    check(build(rate, bad.p, 14, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "a negative lookahead refused");
    bad.p[13] = 0;
    check(build(rate, bad.p, 15, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, rate, "a 15-value block is refused");
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        zeroLookaheadIsBitIdentical(rate);
        latencyEqualsImpulseDelay(rate);
        burstFirstPeriod(rate);
        blockSizesWithListen(rate);
        ringCarry(rate);
        validation(rate);
    }
    if (failures == 0) std::printf("exp lookahead OK\n");
    return failures == 0 ? 0 : 1;
}
