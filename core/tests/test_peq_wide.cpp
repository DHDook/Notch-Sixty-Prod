// E6 S12e: the PEQ stage's kernel types (ABI v26) at the eight standard rates. Constant-Q peaking (type 8) and the
// Linkwitz transform as a numerator/denominator pair (types 9 and 10) match the kernel's biquads, a chain of three PEQ
// stages (more than 16 sections) matches the sections run one after another, and the pairing rules refuse stray halves.
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

n60_stage_desc stage(uint32_t id, const float *p, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_PEQ;
    s.stageId = id;
    s.laneA = 0;
    s.params = p;
    s.paramCount = count;
    return s;
}

n60_status build(double rate, n60_stage_desc *st, uint32_t n, n60_graph **g) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 1;
    d.stages = st;
    d.stageCount = n;
    return n60_graph_build(&d, g);
}

std::vector<float> run(n60_graph *g, const std::vector<float> &in) {
    std::vector<float> out(in.size());
    for (size_t off = 0; off < in.size(); off += 512) {
        const uint32_t n = (uint32_t)std::fmin(512.0, (double)(in.size() - off));
        const float *ip[1] = {in.data() + off};
        float *op[1] = {out.data() + off};
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

// Cookbook peaking with the given (Q already adjusted) at double precision.
Bq peaking(double rate, double f, double gainDb, double q) {
    const double A = std::pow(10.0, gainDb / 40.0), w = 2.0 * M_PI * f / rate, alpha = std::sin(w) / (2.0 * q), cw = std::cos(w);
    const double a0 = 1 + alpha / A;
    return {(1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0, -2 * cw / a0, (1 - alpha / A) / a0};
}

std::vector<float> noise(size_t n) {
    std::vector<float> v(n);
    uint32_t s = 12345u;
    for (auto &x : v) { s = s * 1664525u + 1013904223u; x = 0.4f * ((float)((s >> 8) & 0xFFFF) / 65536.0f - 0.5f); }
    return v;
}

double maxDiff(const std::vector<float> &a, const std::vector<double> &b) {
    double m = 0;
    for (size_t i = 0; i < a.size(); ++i) m = std::fmax(m, std::fabs((double)a[i] - b[i]));
    return m;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        const auto in = noise(4096);
        // Type 8: classic electrical Q, so the cookbook Q is Q / A.
        {
            const float p[4] = {8, 1500, 9, 2.0f};
            n60_stage_desc st[1] = {stage(1, p, 4)};
            n60_graph *g = nullptr;
            check(build(rate, st, 1, &g) == N60_STATUS_OK, "build type 8", rate);
            if (!g) continue;
            Bq c = peaking(rate, 1500, 9, 2.0 / std::pow(10.0, 9.0 / 40.0));
            std::vector<double> ref(in.size());
            for (size_t i = 0; i < in.size(); ++i) ref[i] = step(c, in[i]);
            check(maxDiff(run(g, in), ref) < 1e-5, "constant-Q parity", rate);
            n60_graph_retire(g);
        }
        // Types 9 and 10: the prepared biquad as numerator then denominator.
        {
            const double b0 = 1.02, b1 = -1.9, b2 = 0.9, a1 = -1.88, a2 = 0.885;
            const float p[8] = {9, (float)b0, (float)b1, (float)b2, 10, (float)a1, (float)a2, 0};
            n60_stage_desc st[1] = {stage(1, p, 8)};
            n60_graph *g = nullptr;
            check(build(rate, st, 1, &g) == N60_STATUS_OK, "build pair", rate);
            if (!g) continue;
            Bq c = {(float)b0, (float)b1, (float)b2, (float)a1, (float)a2};
            std::vector<double> ref(in.size());
            for (size_t i = 0; i < in.size(); ++i) ref[i] = step(c, in[i]);
            check(maxDiff(run(g, in), ref) < 1e-5, "prepared biquad parity", rate);
            n60_graph_retire(g);
        }
        // 40 peaking sections over three stages equal the sections run in order.
        {
            std::vector<float> a(64), b(64), c3(32);
            std::vector<Bq> chain;
            for (int k = 0; k < 40; ++k) {
                const float row[4] = {0, (float)(150.0 + 120.0 * k), (float)((k % 5) - 2), 1.1f};
                float *dst = k < 16 ? a.data() + 4 * k : k < 32 ? b.data() + 4 * (k - 16) : c3.data() + 4 * (k - 32);
                std::memcpy(dst, row, sizeof row);
                chain.push_back(peaking(rate, row[1], row[2], row[3]));
            }
            n60_stage_desc st[3] = {stage(1, a.data(), 64), stage(2, b.data(), 64), stage(3, c3.data(), 32)};
            n60_graph *g = nullptr;
            check(build(rate, st, 3, &g) == N60_STATUS_OK, "build chain", rate);
            if (!g) continue;
            std::vector<double> ref(in.size());
            for (size_t i = 0; i < in.size(); ++i) {
                double x = in[i];
                for (auto &c : chain) x = step(c, x);
                ref[i] = x;
            }
            check(maxDiff(run(g, in), ref) < 1e-5, "wide chain parity", rate);
            n60_graph_retire(g);
        }
        // Stray halves and out-of-range types are refused.
        {
            const float num[4] = {9, 1, 0, 0}, den[4] = {10, 0, 0, 0}, bad[4] = {11, 1000, 0, 1};
            const float nanPair[8] = {9, NAN, 0, 0, 10, 0, 0, 0};
            const float unstable[8] = {9, 1, 0, 0, 10, -2.5f, 1.2f, 0};
            const float *cases[5] = {num, den, bad, nanPair, unstable};
            const uint32_t counts[5] = {4, 4, 4, 8, 8};
            for (int k = 0; k < 5; ++k) {
                n60_stage_desc st[1] = {stage(1, cases[k], counts[k])};
                n60_graph *g = nullptr;
                const n60_status r = build(rate, st, 1, &g);
                check(r != N60_STATUS_OK, "refuses malformed section", rate);
                if (r == N60_STATUS_OK && g) n60_graph_retire(g);
            }
        }
    }
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("peq wide: ok");
    return 0;
}
