// E33 S20 (G39): the Equalizer's per-speaker-group lists run as ordinary per-lane PEQ stages. On a 5.1-shaped graph a
// group list on the centre lane (a) leaves every other lane bit-identical to the same graph without it, (b) equals the
// session curve followed by the group's biquads on its own lane, and (c) with a program FIR covering every lane (what the
// linear-phase EQ adds) keeps the group lane at the same latency as an untouched lane. Eight standard rates, 6 lanes.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
constexpr uint32_t kLanes = 6, kCentre = 2, kLfe = 3, kBlock = 512, kFrames = 4096;
int failures = 0;
void check(bool ok, const char *what, double rate) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f\n", what, rate); ++failures; }
}

n60_stage_desc peq(uint32_t id, uint32_t lane, const float *p, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_PEQ;
    s.stageId = id;
    s.laneA = lane;
    s.params = p;
    s.paramCount = count;
    return s;
}

n60_stage_desc fir(uint32_t id, const float *taps, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_FIR;
    s.stageId = id;
    s.laneMask = (1u << kLanes) - 1u;
    s.params = taps;
    s.paramCount = count;
    return s;
}

n60_graph *build(double rate, std::vector<n60_stage_desc> &st) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = kLanes;
    d.stages = st.data();
    d.stageCount = (uint32_t)st.size();
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

using Planes = std::vector<std::vector<float>>;
Planes run(n60_graph *g, const std::vector<float> &in) {
    Planes out(kLanes, std::vector<float>(in.size()));
    for (size_t off = 0; off < in.size(); off += kBlock) {
        const uint32_t n = (uint32_t)std::fmin((double)kBlock, (double)(in.size() - off));
        const float *ip[kLanes];
        float *op[kLanes];
        for (uint32_t l = 0; l < kLanes; ++l) { ip[l] = in.data() + off; op[l] = out[l].data() + off; }
        n60_graph_process(g, ip, op, n);
    }
    return out;
}

struct Bq { double b0, b1, b2, a1, a2, z1 = 0, z2 = 0; };
double step(Bq &c, double x) {
    const double y = c.b0 * x + c.z1;
    c.z1 = c.b1 * x - c.a1 * y + c.z2;
    c.z2 = c.b2 * x - c.a2 * y;
    return y;
}
Bq peaking(double rate, double f, double gainDb, double q) {
    const double A = std::pow(10.0, gainDb / 40.0), w = 2.0 * M_PI * f / rate, alpha = std::sin(w) / (2.0 * q), cw = std::cos(w);
    const double a0 = 1 + alpha / A;
    return {(1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0, -2 * cw / a0, (1 - alpha / A) / a0};
}

std::vector<float> noise(size_t n) {
    std::vector<float> v(n);
    uint32_t s = 777u;
    for (auto &x : v) { s = s * 1664525u + 1013904223u; x = 0.4f * ((float)((s >> 8) & 0xFFFF) / 65536.0f - 0.5f); }
    return v;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const float session[4] = {0, 250, 3, 1.0f};                   // the session curve on every non-LFE lane
    const float group[8] = {0, 90, -6, 1.4f, 0, 3000, 4, 0.9f};   // the Centre list: two bands
    for (double rate : rates) {
        const auto in = noise(kFrames);
        for (int withFir = 0; withFir < 2; ++withFir) {
            const float taps[1] = {1.0f};
            auto stages = [&](bool grouped) {
                std::vector<n60_stage_desc> st;
                for (uint32_t l = 0; l < kLanes; ++l) if (l != kLfe) st.push_back(peq(800 + l, l, session, 4));
                if (grouped) st.push_back(peq(1300 + kCentre, kCentre, group, 8));
                if (withFir) st.push_back(fir(2000, taps, 1));
                return st;
            };
            auto without = stages(false), with = stages(true);
            n60_graph *g0 = build(rate, without), *g1 = build(rate, with);
            check(g0 && g1, "build", rate);
            if (!g0 || !g1) { if (g0) n60_graph_retire(g0); if (g1) n60_graph_retire(g1); continue; }
            const Planes a = run(g0, in), b = run(g1, in);
            // (a) every lane but the centre is bit-identical to the graph without the group list.
            for (uint32_t l = 0; l < kLanes; ++l) {
                if (l == kCentre) continue;
                check(std::memcmp(a[l].data(), b[l].data(), in.size() * sizeof(float)) == 0, "other lanes untouched", rate);
            }
            // The latency of an untouched lane (the LFE has no session curve): the impulse peak.
            size_t delay = 0;
            if (withFir) {
                std::vector<float> imp(kFrames, 0.0f);
                imp[0] = 1.0f;
                n60_graph *g2 = build(rate, with);
                const Planes p = run(g2, imp);
                float best = 0;
                for (size_t i = 0; i < imp.size(); ++i) if (std::fabs(p[kLfe][i]) > best) { best = std::fabs(p[kLfe][i]); delay = i; }
                n60_graph_retire(g2);
                check(delay > 0, "program FIR adds latency", rate);
            }
            // (b) and (c): the centre equals session curve then group bands, delayed like the other lanes.
            Bq s = peaking(rate, 250, 3, 1.0), g1a = peaking(rate, 90, -6, 1.4), g1b = peaking(rate, 3000, 4, 0.9);
            std::vector<double> ref(in.size());
            for (size_t i = 0; i < in.size(); ++i) ref[i] = step(g1b, step(g1a, step(s, in[i])));
            double err = 0;
            for (size_t i = delay; i < in.size(); ++i) err = std::fmax(err, std::fabs((double)b[kCentre][i] - ref[i - delay]));
            check(err < 2e-5, withFir ? "centre keeps equal latency with a program FIR" : "centre equals session plus group curve", rate);
            // The group list really changes the centre.
            double diff = 0;
            for (size_t i = 0; i < in.size(); ++i) diff = std::fmax(diff, std::fabs((double)a[kCentre][i] - b[kCentre][i]));
            check(diff > 1e-3, "group list audible on the centre", rate);
            n60_graph_retire(g0);
            n60_graph_retire(g1);
        }
    }
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("eq groups: ok");
    return 0;
}
