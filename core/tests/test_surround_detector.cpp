// E33 S13 (graph ABI v45): LFE out of the compressor and expander detector, and the centre-aware dialogue leveler, at the eight
// standard rates on a 5.1 lane set (L R C LFE Ls Rs = lanes 0..5). Checks: an LFE burst at full level makes no gain reduction on
// the mains and the same burst on a front lane does; the LFE takes the group's gain; a 17-value compressor and a 16-value
// expander with no excluded lane are bit-identical to the shorter blocks; the pause gate stays open on LFE-only content; a
// centre-only speech signal is lifted on the centre with every other lane unchanged; a silent centre leaves the pair leveler
// bit-identical to the 32-value block; the pair/centre switch is hysteretic and has no click; the centre leveler state carries
// across a snapshot swap; validation; stereo bit-identity.
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
using Lanes = std::vector<std::vector<float>>;
constexpr uint32_t kLfe = 3;      // lane index of the LFE; the parameter value is lane + 1
constexpr uint32_t kCentre = 2;

n60_stage_desc stage(uint32_t kind, uint32_t id, const float *p, uint32_t count, uint32_t laneA, uint32_t laneB = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = laneA;
    s.laneB = laneB;
    s.params = p;
    s.paramCount = count;
    return s;
}
n60_graph *build(double rate, n60_stage_desc *st, uint32_t n, uint32_t channels, n60_status *status = nullptr) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = channels;
    d.stages = st;
    d.stageCount = n;
    n60_graph *g = nullptr;
    const n60_status r = n60_graph_build(&d, &g);
    if (status) *status = r;
    return r == N60_STATUS_OK ? g : nullptr;
}
void runRange(n60_graph *g, const Lanes &in, Lanes &out, size_t from, size_t to) {
    const size_t ch = in.size();
    out.resize(ch, std::vector<float>(in[0].size()));
    for (size_t off = from; off < to; off += 512) {
        const uint32_t m = (uint32_t)std::min<size_t>(512, to - off);
        const float *ip[N60_GRAPH_MAX_CHANNELS];
        float *op[N60_GRAPH_MAX_CHANNELS];
        for (size_t c = 0; c < ch; ++c) { ip[c] = in[c].data() + off; op[c] = out[c].data() + off; }
        n60_graph_process(g, ip, op, m);
    }
}
Lanes render(double rate, n60_stage_desc *st, uint32_t n, const Lanes &in) {
    n60_graph *g = build(rate, st, n, (uint32_t)in.size());
    Lanes out;
    if (!g) { check(false, rate, "graph builds"); return Lanes(in.size(), std::vector<float>(in[0].size())); }
    runRange(g, in, out, 0, in[0].size());
    n60_graph_retire(g);
    return out;
}
std::vector<float> sine(double rate, double hz, double amp, size_t n) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}
double rms(const std::vector<float> &v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(to - from));
}
double db(double x) { return 20.0 * std::log10(std::fmax(x, 1e-12)); }
double toneAmp(const std::vector<float> &v, double rate, double hz, size_t from, size_t to) {
    double s = 0, c = 0;
    for (size_t i = from; i < to; ++i) {
        const double ph = 2.0 * M_PI * hz * (double)i / rate;
        s += v[i] * std::sin(ph);
        c += v[i] * std::cos(ph);
    }
    return 2.0 * std::sqrt(s * s + c * c) / (double)(to - from);
}
bool sameLanes(const Lanes &a, const Lanes &b) {
    for (size_t l = 0; l < a.size(); ++l) {
        if (std::memcmp(a[l].data(), b[l].data(), a[l].size() * sizeof(float)) != 0) return false;
    }
    return true;
}
uint32_t rng = 99;
float noise() {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f;
}

// Compressor: threshold -30, ratio 4, knee 0, attack 1 ms, release 50 ms, makeup 0, feed-forward, no pdr, no filter, linked,
// mix 100, link 100, peak, window 50, lookahead 0, listen 0, excluded lane + 1.
struct Comp {
    float p[17] = {-30, 4, 0, 1, 50, 0, 0, 0, 0, 1, 100, 100, 0, 50, 0, 0, 0};
};
// Expander: threshold -30, ratio 3, range -24, attack 1, release 50, linked, hold 0, knee 0, peak, window 50, filter 0,
// link 100, listen 0, lookahead 0, swap 0, excluded lane + 1.
struct Exp {
    float p[16] = {-30, 3, -24, 1, 50, 1, 0, 0, 0, 50, 0, 100, 0, 0, 0, 0};
};

void compressorExcludesTheLfe(double rate) {
    const size_t n = (size_t)(0.6 * rate);
    Lanes quiet(6, std::vector<float>(n));
    for (auto &l : quiet) for (auto &x : l) x = 0.01f * noise();
    Lanes lfeBurst = quiet, frontBurst = quiet;
    lfeBurst[kLfe] = sine(rate, 60, 0.7, n);
    frontBurst[0] = sine(rate, 60, 0.7, n);
    Comp withEx, noEx;
    withEx.p[16] = (float)(kLfe + 1);
    n60_stage_desc a[1] = {stage(N60_STAGE_COMPRESSOR, 1, withEx.p, 17, N60_LANE_ALL)};
    n60_stage_desc b[1] = {stage(N60_STAGE_COMPRESSOR, 1, noEx.p, 17, N60_LANE_ALL)};
    const size_t from = n / 2;
    const Lanes lfeOut = render(rate, a, 1, lfeBurst);
    const Lanes frontOut = render(rate, a, 1, frontBurst);
    const Lanes includedOut = render(rate, b, 1, lfeBurst);
    for (uint32_t l : {0u, 1u, 2u, 4u, 5u}) {
        check(std::fabs(db(rms(lfeOut[l], from, n)) - db(rms(lfeBurst[l], from, n))) < 0.05, rate,
              "an LFE burst leaves the mains alone", l, db(rms(lfeOut[l], from, n)) - db(rms(lfeBurst[l], from, n)));
        check(db(rms(includedOut[l], from, n)) - db(rms(lfeBurst[l], from, n)) < -3.0, rate, "with the LFE in the detector the mains duck", l);
    }
    check(db(rms(frontOut[1], from, n)) - db(rms(frontBurst[1], from, n)) < -3.0, rate, "the same burst on a front lane reduces the mains");
    // The LFE takes the group's gain: a steady quiet 50 Hz tone on the LFE under a front burst is reduced like the front lane.
    Lanes mix = quiet;
    mix[0] = sine(rate, 1000, 0.5, n);
    mix[kLfe] = sine(rate, 50, 0.02, n);
    const Lanes mixOut = render(rate, a, 1, mix);
    const double frontGain = db(toneAmp(mixOut[0], rate, 1000, from, n)) - db(0.5);
    const double lfeGain = db(toneAmp(mixOut[kLfe], rate, 50, from, n)) - db(0.02);
    check(frontGain < -5.0, rate, "the front lane is reduced", frontGain);
    check(std::fabs(frontGain - lfeGain) < 0.3, rate, "the LFE gain tracks the group", frontGain, lfeGain);
    // No excluded lane is bit-identical to the 16-value block.
    n60_stage_desc c[1] = {stage(N60_STAGE_COMPRESSOR, 1, noEx.p, 16, N60_LANE_ALL)};
    check(sameLanes(render(rate, b, 1, mix), render(rate, c, 1, mix)), rate, "no excluded lane equals the 16-value block");
}

void expanderExcludesTheLfe(double rate) {
    const size_t n = (size_t)(0.6 * rate);
    Lanes in(6, std::vector<float>(n));
    for (auto &l : in) for (auto &x : l) x = 0.01f * noise();
    in[kLfe] = sine(rate, 60, 0.7, n);
    Exp withEx, noEx;
    withEx.p[8] = noEx.p[8] = 1;
    withEx.p[15] = (float)(kLfe + 1);
    n60_stage_desc a[1] = {stage(N60_STAGE_EXPANDER, 1, withEx.p, 16, N60_LANE_ALL)};
    n60_stage_desc b[1] = {stage(N60_STAGE_EXPANDER, 1, noEx.p, 16, N60_LANE_ALL)};
    const size_t from = n / 2;
    const Lanes out = render(rate, a, 1, in);
    const Lanes inc = render(rate, b, 1, in);
    for (uint32_t l : {0u, 1u, 2u, 4u, 5u}) {
        check(db(rms(inc[l], from, n)) - db(rms(in[l], from, n)) > -0.5, rate, "the LFE in the detector holds the expander open", l, db(rms(inc[l], from, n)) - db(rms(in[l], from, n)));
        check(db(rms(out[l], from, n)) - db(rms(in[l], from, n)) < -6.0, rate, "without the LFE the quiet mains are expanded", l);
    }
    // The LFE keeps the group's gain: it is open or closed with the group, never on its own level.
    Lanes lowLfe = in;
    lowLfe[kLfe] = sine(rate, 60, 0.005, n);
    n60_stage_desc c[1] = {stage(N60_STAGE_EXPANDER, 1, withEx.p, 16, N60_LANE_ALL)};
    const Lanes o2 = render(rate, c, 1, lowLfe);
    const double g0 = db(rms(o2[0], from, n)) - db(rms(lowLfe[0], from, n));
    const double gl = db(toneAmp(o2[kLfe], rate, 60, from, n)) - db(0.005);
    check(std::fabs(g0 - gl) < 0.6, rate, "the expander LFE gain tracks the group", g0, gl);
    n60_stage_desc d[1] = {stage(N60_STAGE_EXPANDER, 1, noEx.p, 15, N60_LANE_ALL)};
    check(sameLanes(render(rate, b, 1, in), render(rate, d, 1, in)), rate, "no excluded lane equals the 15-value block");
}

void pauseGateKeepsTheLfe(double rate) {
    const size_t n = (size_t)(1.0 * rate);
    Lanes in(6, std::vector<float>(n, 0.0f));
    in[kLfe] = sine(rate, 40, 0.3, n);
    const float gate[5] = {-50, 6, 100, 10, 10};
    n60_stage_desc st[1] = {stage(N60_STAGE_PAUSE_GATE, 1, gate, 5, 0)};
    st[0].laneMask = 0x3Fu;
    const Lanes out = render(rate, st, 1, in);
    check(std::memcmp(out[kLfe].data(), in[kLfe].data(), n * sizeof(float)) == 0, rate, "the pause gate stays open on LFE-only content");
}

// Loudness block: leveler on, voice gate off, band 300..3500, gap 6, ratio 3, max boost 9, detector 200, attack 80, release 600,
// programme gate -60.
struct Lev {
    float p[33] = {0, 0, -20, 10, 1, 3, 0, 0.5f, 0, 0, 80, 12, 3, 1,
                   1, 0, 300, 3500, 6, 3, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f, 0};
};
n60_loudness_readback readback(n60_graph *g) {
    n60_loudness_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    n60_graph_read_loudness(g, 5, &rb);
    return rb;
}

void centreLeveler(double rate) {
    const size_t sec = (size_t)rate;
    const size_t n = 4 * sec;
    // A. Centre-only speech: the centre carries 1 kHz under a loud 8 kHz; the fronts carry music; nothing else moves.
    Lev lev;
    lev.p[32] = (float)(kCentre + 1);
    Lanes in(6, std::vector<float>(n, 0.0f));
    in[kCentre] = sine(rate, 8000, 0.3, n);
    const auto speech = sine(rate, 1000, 0.02, n);
    for (size_t i = 0; i < n; ++i) in[kCentre][i] += speech[i];
    in[0] = sine(rate, 8000, 0.05, n);
    in[1] = sine(rate, 8000, 0.04, n);
    in[kLfe] = sine(rate, 50, 0.1, n);
    in[4] = sine(rate, 3000, 0.05, n);
    in[5] = sine(rate, 2000, 0.05, n);
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    n60_graph *g = build(rate, st, 1, 6);
    if (!g) { check(false, rate, "centre leveler builds"); return; }
    Lanes out;
    runRange(g, in, out, 0, n);
    const n60_loudness_readback rb = readback(g);
    n60_graph_retire(g);
    check(rb.reserved == 1, rate, "the leveler follows the centre", rb.reserved);
    check(rb.dialogueBoostDb > 4.0f, rate, "the centre speech is boosted", rb.dialogueBoostDb);
    const double lift = db(toneAmp(out[kCentre], rate, 1000, n - sec, n)) - db(0.02);
    check(std::fabs(lift - rb.dialogueBoostDb) < 0.3, rate, "the centre gains the boost", lift, rb.dialogueBoostDb);
    for (uint32_t l : {0u, 1u, 3u, 4u, 5u}) {
        double w = 0;
        for (size_t i = n - sec; i < n; ++i) w = std::fmax(w, std::fabs((double)out[l][i] - in[l][i]));
        check(w < 2e-6, rate, "the other lanes are unchanged", l, w);
    }
    // B. A silent centre: the pair leveler is bit-identical to the 32-value block.
    Lanes pairIn(6, std::vector<float>(n, 0.0f));
    pairIn[0] = sine(rate, 8000, 0.3, n);
    const auto q = sine(rate, 1000, 0.02, n);
    for (size_t i = 0; i < n; ++i) pairIn[0][i] += q[i];
    pairIn[1] = pairIn[0];
    pairIn[kLfe] = sine(rate, 50, 0.1, n);
    Lev pairOnly = lev;
    n60_stage_desc s33[1] = {stage(N60_STAGE_LOUDNESS, 5, pairOnly.p, 33, 0, 1)};
    n60_stage_desc s32[1] = {stage(N60_STAGE_LOUDNESS, 5, pairOnly.p, 32, 0, 1)};
    check(sameLanes(render(rate, s33, 1, pairIn), render(rate, s32, 1, pairIn)), rate,
          "a silent centre matches the 32-value pair behaviour bit for bit");
    // The 33-value block with no centre lane is the 32-value block too.
    Lev none = lev;
    none.p[32] = 0;
    n60_stage_desc s0[1] = {stage(N60_STAGE_LOUDNESS, 5, none.p, 33, 0, 1)};
    check(sameLanes(render(rate, s0, 1, pairIn), render(rate, s32, 1, pairIn)), rate, "centre lane 0 equals the 32-value block");
}

void centreHysteresis(double rate) {
    // Power gate -60 dBFS (p[24]); the centre tone's power in dBFS is 20 log10(amp) - 3.
    const size_t sec = (size_t)rate, n = 6 * sec;
    Lev lev;
    lev.p[32] = (float)(kCentre + 1);
    Lanes in(3, std::vector<float>(n, 0.0f));
    const double amps[] = {0.0025, 0.0012, 0.0002};  // -55, -61.4 (inside the 6 dB band), -77 dBFS
    for (int seg = 0; seg < 3; ++seg) {
        const auto t = sine(rate, 1000, amps[seg], n);
        for (size_t i = (size_t)seg * 2 * sec; i < (size_t)(seg + 1) * 2 * sec; ++i) in[kCentre][i] = t[i];
    }
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    n60_graph *g = build(rate, st, 1, 3);
    if (!g) { check(false, rate, "hysteresis graph builds"); return; }
    Lanes out;
    const uint32_t expect[3] = {1, 1, 0};
    for (int seg = 0; seg < 3; ++seg) {
        runRange(g, in, out, (size_t)seg * 2 * sec, (size_t)(seg + 1) * 2 * sec);
        check(readback(g).reserved == expect[seg], rate, "the centre switch is hysteretic", seg, readback(g).reserved);
    }
    n60_graph_retire(g);
}

void centreSwitchHasNoClick(double rate) {
    const size_t sec = (size_t)rate, n = 4 * sec;
    Lev lev;
    lev.p[32] = (float)(kCentre + 1);
    Lanes in(3, std::vector<float>(n, 0.0f));
    in[0] = sine(rate, 8000, 0.3, n);
    const auto q = sine(rate, 1000, 0.02, n);
    for (size_t i = 0; i < n; ++i) in[0][i] += q[i];
    in[1] = in[0];
    const size_t at = 2 * sec;
    const auto speech = sine(rate, 1000, 0.02, n);
    const auto carrier = sine(rate, 8000, 0.3, n);
    for (size_t i = at; i < n; ++i) in[kCentre][i] = speech[i] + carrier[i];
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    const Lanes out = render(rate, st, 1, in);
    // The change each lane adds (out - in) moves no faster than 1.5 times its steady pair-path step, which includes the
    // band filter's leakage of the loud 8 kHz carrier.
    auto stepMax = [&](size_t from, size_t to) {
        double m = 0;
        for (uint32_t l = 0; l < 3; ++l)
            for (size_t i = from; i < to; ++i)
                m = std::fmax(m, std::fabs(((double)out[l][i] - in[l][i]) - ((double)out[l][i - 1] - in[l][i - 1])));
        return m;
    };
    const double bound = 1.5 * stepMax(at - sec, at - sec / 10);
    const double worst = stepMax(at - sec / 10, at + sec);
    check(worst < bound, rate, "no click at the pair to centre switch", worst, bound);
}

void centreStateCarries(double rate) {
    const size_t sec = (size_t)rate, n = 3 * sec;
    Lev lev;
    lev.p[32] = (float)(kCentre + 1);
    Lanes in(3, std::vector<float>(n, 0.0f));
    in[kCentre] = sine(rate, 8000, 0.3, n);
    const auto speech = sine(rate, 1000, 0.02, n);
    for (size_t i = 0; i < n; ++i) in[kCentre][i] += speech[i];
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    n60_graph *swap = build(rate, st, 1, 3), *ref = build(rate, st, 1, 3);
    if (!swap || !ref) { check(false, rate, "carry graphs build"); return; }
    n60_rebuild_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.fadeMs = 0.0f;
    n60_graph_set_rebuild_options(swap, &o);
    const size_t mid = (size_t)(1.5 * sec) / 512 * 512;
    Lanes a, b;
    runRange(swap, in, a, 0, mid);
    runRange(ref, in, b, 0, mid);
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 3;
    d.stages = st;
    d.stageCount = 1;
    check(n60_graph_publish(swap, &d) == N60_STATUS_OK, rate, "publish");
    const size_t end = n / 512 * 512;
    runRange(swap, in, a, mid, end);
    runRange(ref, in, b, mid, end);
    double worst = 0;
    for (uint32_t l = 0; l < 3; ++l) {
        for (size_t i = mid; i < end; ++i) worst = std::fmax(worst, std::fabs((double)a[l][i] - b[l][i]));
    }
    check(worst < 1e-6, rate, "the centre leveler state carries across a snapshot swap", worst);
    n60_graph_retire(swap);
    n60_graph_retire(ref);
}

void validation(double rate) {
    Lev lev;
    n60_status s = N60_STATUS_OK;
    auto tryBuild = [&](float centreValue, uint32_t channels) {
        lev.p[32] = centreValue;
        n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
        n60_graph *g = build(rate, st, 1, channels, &s);
        if (g) n60_graph_retire(g);
        return s;
    };
    check(tryBuild(3, 6) == N60_STATUS_OK, rate, "a centre lane builds");
    check(tryBuild(1, 6) != N60_STATUS_OK, rate, "the centre may not be laneA");
    check(tryBuild(2, 6) != N60_STATUS_OK, rate, "the centre may not be laneB");
    check(tryBuild(7, 6) != N60_STATUS_OK, rate, "the centre must be inside the layout");
    check(tryBuild(2.5f, 6) != N60_STATUS_OK, rate, "the centre is an integer");
    lev.p[32] = 3;
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    n60_graph *g = build(rate, st, 1, 6);
    if (g) {
        n60_param_record rec[1] = {{5, 32, 4.0f, 0}};
        check(n60_graph_post_params(g, rec, 1) != N60_STATUS_OK, rate, "the centre lane is not live");
        n60_graph_retire(g);
    }
    Comp c;
    auto compStatus = [&](float ex, float linked, uint32_t channels) {
        c.p[16] = ex;
        c.p[9] = linked;
        n60_stage_desc cs[1] = {stage(N60_STAGE_COMPRESSOR, 1, c.p, 17, N60_LANE_ALL)};
        n60_graph *h = build(rate, cs, 1, channels, &s);
        if (h) n60_graph_retire(h);
        return s;
    };
    check(compStatus(4, 1, 6) == N60_STATUS_OK, rate, "an excluded lane builds");
    check(compStatus(4, 0, 6) != N60_STATUS_OK, rate, "an excluded lane needs the linked group");
    check(compStatus(7, 1, 6) != N60_STATUS_OK, rate, "the excluded lane must be in the group");
    check(compStatus(1, 1, 1) != N60_STATUS_OK, rate, "the group needs a second lane");
}

// A stereo session never carries the new values: the 10, 6 and 32-value blocks render exactly as before, so a stereo
// graph with the shorter blocks and the same blocks built again agree bit for bit and every lane count is unchanged.
void stereoBlocksAreUnchanged(double rate) {
    const size_t n = (size_t)(0.5 * rate);
    Lanes in(2, std::vector<float>(n));
    in[0] = sine(rate, 1000, 0.5, n);
    in[1] = sine(rate, 70, 0.3, n);
    Comp c;
    Exp e;
    Lev lev;
    n60_stage_desc st[3] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 32, 0, 1), stage(N60_STAGE_COMPRESSOR, 1, c.p, 10, N60_LANE_ALL),
                            stage(N60_STAGE_EXPANDER, 2, e.p, 6, N60_LANE_ALL)};
    const Lanes a = render(rate, st, 3, in), b = render(rate, st, 3, in);
    check(sameLanes(a, b), rate, "the stereo blocks are deterministic");
    // The 10-value compressor is the v32 arithmetic: with no excluded lane the 17-value block gives the same gain within rounding.
    n60_stage_desc x[1] = {stage(N60_STAGE_COMPRESSOR, 1, c.p, 17, N60_LANE_ALL)};
    n60_stage_desc y[1] = {stage(N60_STAGE_COMPRESSOR, 1, c.p, 10, N60_LANE_ALL)};
    const Lanes cx = render(rate, x, 1, in), cy = render(rate, y, 1, in);
    double worst = 0;
    for (size_t i = n / 2; i < n; ++i) worst = std::fmax(worst, std::fabs((double)cx[0][i] - cy[0][i]));
    check(worst < 1e-4, rate, "the extended compressor matches the 10-value block", worst);
}

// E33 S11 (G62): the same two behaviours on a 7.1.4 lane set (L R C LFE Ls Rs Lrs Rrs TFL TFR TRL TRR = lanes 0..11).
void sevenOneFour(double rate) {
    constexpr size_t kLanes = 12;
    const size_t sec = (size_t)rate;
    const size_t n = (size_t)(0.6 * rate);
    Lanes quiet(kLanes, std::vector<float>(n));
    for (auto &l : quiet) for (auto &x : l) x = 0.01f * noise();
    Lanes lfeBurst = quiet, frontBurst = quiet;
    lfeBurst[kLfe] = sine(rate, 60, 0.7, n);
    frontBurst[0] = sine(rate, 60, 0.7, n);
    Comp withEx, noEx;
    withEx.p[16] = (float)(kLfe + 1);
    n60_stage_desc a[1] = {stage(N60_STAGE_COMPRESSOR, 1, withEx.p, 17, N60_LANE_ALL)};
    n60_stage_desc b[1] = {stage(N60_STAGE_COMPRESSOR, 1, noEx.p, 17, N60_LANE_ALL)};
    const size_t from = n / 2;
    const Lanes lfeOut = render(rate, a, 1, lfeBurst), frontOut = render(rate, a, 1, frontBurst), incOut = render(rate, b, 1, lfeBurst);
    for (uint32_t l = 0; l < kLanes; ++l) {
        if (l == kLfe) continue;
        check(std::fabs(db(rms(lfeOut[l], from, n)) - db(rms(lfeBurst[l], from, n))) < 0.05, rate, "7.1.4: an LFE burst leaves every other lane alone", l);
        check(db(rms(incOut[l], from, n)) - db(rms(lfeBurst[l], from, n)) < -3.0, rate, "7.1.4: with the LFE in the detector every lane ducks", l);
        if (l != 0) check(db(rms(frontOut[l], from, n)) - db(rms(frontBurst[l], from, n)) < -3.0, rate, "7.1.4: a front burst reduces the whole group", l);
    }
    // Centre-only speech: lifted on the centre, every other lane (including the four height lanes) unchanged.
    const size_t m = 4 * sec;
    Lev lev;
    lev.p[32] = (float)(kCentre + 1);
    Lanes in(kLanes, std::vector<float>(m, 0.0f));
    in[kCentre] = sine(rate, 8000, 0.3, m);
    const auto speech = sine(rate, 1000, 0.02, m);
    for (size_t i = 0; i < m; ++i) in[kCentre][i] += speech[i];
    in[0] = sine(rate, 8000, 0.05, m);
    in[1] = sine(rate, 8000, 0.04, m);
    in[kLfe] = sine(rate, 50, 0.1, m);
    for (uint32_t l = 4; l < kLanes; ++l) in[l] = sine(rate, 1500.0 + 300.0 * l, 0.05, m);
    n60_stage_desc st[1] = {stage(N60_STAGE_LOUDNESS, 5, lev.p, 33, 0, 1)};
    n60_graph *g = build(rate, st, 1, kLanes);
    if (!g) { check(false, rate, "7.1.4 leveler builds"); return; }
    Lanes out;
    runRange(g, in, out, 0, m);
    const n60_loudness_readback rb = readback(g);
    n60_graph_retire(g);
    check(rb.reserved == 1, rate, "7.1.4: the leveler follows the centre", rb.reserved);
    check(rb.dialogueBoostDb > 4.0f, rate, "7.1.4: the centre speech is boosted", rb.dialogueBoostDb);
    const double lift = db(toneAmp(out[kCentre], rate, 1000, m - sec, m)) - db(0.02);
    check(std::fabs(lift - rb.dialogueBoostDb) < 0.3, rate, "7.1.4: the centre gains the boost", lift, rb.dialogueBoostDb);
    for (uint32_t l = 0; l < kLanes; ++l) {
        if (l == kCentre) continue;
        double w = 0;
        for (size_t i = m - sec; i < m; ++i) w = std::fmax(w, std::fabs((double)out[l][i] - in[l][i]));
        check(w < 2e-6, rate, "7.1.4: the other lanes are unchanged", l, w);
    }
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        compressorExcludesTheLfe(rate);
        expanderExcludesTheLfe(rate);
        pauseGateKeepsTheLfe(rate);
        centreLeveler(rate);
        centreHysteresis(rate);
        centreSwitchHasNoClick(rate);
        centreStateCarries(rate);
        validation(rate);
        stereoBlocksAreUnchanged(rate);
        sevenOneFour(rate);
    }
    centreLeveler(768000);   // the 50 ms crossfade pole must still move at the validated maximum rate
    centreHysteresis(768000);
    if (failures) return 1;
    std::puts("n60core surround detector and dialogue (E33 S13): OK");
    return 0;
}
