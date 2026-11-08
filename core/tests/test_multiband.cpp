// E6 S12d: behaviour of the MULTIBAND compressor stage at the eight standard rates: off is bit exact, a tone in each band
// is reduced while the other bands pass, gain-reduction readbacks (peak resets on read), auto release holds the
// reduction longer, live parameter posting (slopes are topology and refuse), validation, and the park after disable.
// Kernel parity is in test_multiband_parity.c.
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

struct Mb {
    // on, lowMid, midHigh, lowSlope, highSlope, thr[3], ratio[3], atk[3], rel[3], knee[3], hpf[3], makeup[3], auto[3]
    float p[29] = {0, 120, 2500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
};

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

void run(n60_graph *g, std::vector<float> &l, std::vector<float> &r) {
    std::vector<float> ol(l.size()), orr(r.size());
    for (size_t off = 0; off < l.size(); off += 512) {
        const uint32_t n = (uint32_t)std::fmin(512.0, (double)(l.size() - off));
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
    l = ol;
    r = orr;
}

double rmsTail(const std::vector<float> &v, size_t from) {
    double s = 0;
    for (size_t i = from; i < v.size(); ++i) s += (double)v[i] * v[i];
    return std::sqrt(s / (double)(v.size() - from));
}

std::vector<float> sine(double rate, double hz, double amp, size_t n) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}

double db(double x) { return 20.0 * std::log10(x); }

n60_multiband_readback rb(n60_graph *g, n60_status *st = nullptr) {
    n60_multiband_readback r;
    std::memset(&r, 0, sizeof r);
    r.structSize = sizeof r;
    const n60_status s = n60_graph_read_multiband(g, 5, &r);
    if (st) *st = s;
    return r;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        const size_t n = (size_t)(rate * 1.0);
        const size_t tail = n / 2;
        // Off is bit exact.
        {
            Mb m;
            n60_graph *g = build(rate, m.p, 29);
            check(g != nullptr, "build", rate);
            auto l = sine(rate, 1000, 0.5, 4096), r = sine(rate, 70, 0.3, 4096);
            auto l0 = l, r0 = r;
            run(g, l, r);
            check(std::memcmp(l.data(), l0.data(), l.size() * 4) == 0 && std::memcmp(r.data(), r0.data(), r.size() * 4) == 0, "off is bit exact", rate);
            n60_graph_retire(g);
        }
        // A loud tone in each band is reduced in that band only.
        const double hz[3] = {60, 800, 7000};
        for (int band = 0; band < 3; ++band) {
            Mb m;
            m.p[0] = 1;
            // All three bands compress: the mid band is the residual (dry - low - high), so a lone band would leave the phase error.
            n60_graph *g = build(rate, m.p, 29);
            auto l = sine(rate, hz[band], 0.5, n), r = l;
            run(g, l, r);
            const double red = db(rmsTail(l, tail) / (0.5 * 0.7071067811865476));
            check(red < -10.0 && red > -20.5, "band tone reduced", rate);
            const n60_multiband_readback x = rb(g);
            check(x.grMaxDb[band] > 10.0f && x.grMaxDb[band] < 20.5f, "band gain reduction readback", rate);
            check(x.grNowDb[band == 0 ? 2 : 0] < 0.5f, "far band sees no signal", rate);
            const n60_multiband_readback y = rb(g);
            check(y.grMaxDb[band] == 0.0f && y.grNowDb[band] > 10.0f, "peak resets on read, now holds", rate);
            n60_graph_retire(g);
        }
        // Quiet tone below every threshold passes (no make-up): unity within the crossover's flat-sum error.
        {
            Mb m;
            m.p[0] = 1;
            n60_graph *g = build(rate, m.p, 29);
            auto l = sine(rate, 800, 0.01, n), r = l;
            run(g, l, r);
            check(std::fabs(db(rmsTail(l, tail) / (0.01 * 0.7071067811865476))) < 0.1, "below threshold is unity", rate);
            n60_graph_retire(g);
        }
        // Make-up gain applies below threshold.
        {
            Mb m;
            m.p[0] = 1;
            m.p[23] = m.p[24] = m.p[25] = 6;
            n60_graph *g = build(rate, m.p, 29);
            auto l = sine(rate, 800, 0.01, n), r = l;
            run(g, l, r);
            check(std::fabs(db(rmsTail(l, tail) / (0.01 * 0.7071067811865476)) - 6.0) < 0.2, "make-up 6 dB", rate);
            n60_graph_retire(g);
        }
        // Auto release holds a deep reduction longer than the plain release (rel 100 ms).
        {
            double grNow[2];
            for (int a = 0; a < 2; ++a) {
                Mb m;
                m.p[0] = 1;
                m.p[26] = m.p[27] = m.p[28] = (float)a;
                n60_graph *g = build(rate, m.p, 29);
                auto l = sine(rate, 800, 0.5, (size_t)(rate * 0.5)), r = l;
                run(g, l, r);
                std::vector<float> z((size_t)(rate * 0.03), 0.0f), z2 = z;
                run(g, z, z2);
                grNow[a] = rb(g).grNowDb[1];
                n60_graph_retire(g);
            }
            if (!(grNow[1] > grNow[0] + 0.2)) std::fprintf(stderr, "auto %.3f off %.3f\n", grNow[1], grNow[0]);
            check(grNow[1] > grNow[0] + 0.2 && grNow[0] >= 0.0, "auto release is slower", rate);
        }
        // Live parameters: raise the threshold above the signal and the reduction releases; disable parks to unity.
        {
            Mb m;
            m.p[0] = 1;
            n60_graph *g = build(rate, m.p, 29);
            auto l = sine(rate, 800, 0.5, n / 2), r = l;
            run(g, l, r);
            n60_param_record thr[1] = {{5, 6, 0.0f, 0}};
            check(n60_graph_post_params(g, thr, 1) == N60_STATUS_OK, "post threshold", rate);
            auto l2 = sine(rate, 800, 0.5, n), r2 = l2;
            run(g, l2, r2);
            check(rb(g).grNowDb[1] < 0.05f, "released after the threshold rises", rate);
            n60_param_record off[1] = {{5, 0, 0.0f, 0}};
            check(n60_graph_post_params(g, off, 1) == N60_STATUS_OK, "post off", rate);
            auto l3 = sine(rate, 800, 0.5, n), r3 = l3;
            auto l30 = l3;
            run(g, l3, r3);
            double worst = 0;
            for (size_t i = n - 2048; i < n; ++i) worst = std::fmax(worst, std::fabs((double)l3[i] - l30[i]));
            check(worst < 2e-3, "disabled returns to unity", rate);
            // Parked: the output is bit exact again.
            auto l4 = sine(rate, 800, 0.5, 4096), r4 = l4;
            auto l40 = l4;
            run(g, l4, r4);
            check(std::memcmp(l4.data(), l40.data(), l4.size() * 4) == 0, "parked is bit exact", rate);
            n60_param_record slope[1] = {{5, 3, 1.0f, 0}};
            check(n60_graph_post_params(g, slope, 1) == N60_STATUS_UNSUPPORTED, "slope is not live", rate);
            n60_param_record bad[1] = {{5, 8, 0.5f, 0}};
            check(n60_graph_post_params(g, bad, 1) != N60_STATUS_OK, "reject ratio 0.5", rate);
            n60_graph_retire(g);
        }
        // LR8 builds and reduces.
        {
            Mb m;
            m.p[0] = 1; m.p[3] = 1; m.p[4] = 1;
            n60_graph *g = build(rate, m.p, 29);
            check(g != nullptr, "LR8 build", rate);
            auto l = sine(rate, 800, 0.5, n), r = l;
            run(g, l, r);
            check(db(rmsTail(l, tail) / (0.5 * 0.7071067811865476)) < -10.0, "LR8 reduces", rate);
            n60_graph_retire(g);
        }
        // Validation.
        {
            n60_status st;
            Mb ok;
            check(build(rate, ok.p, 28, &st) == nullptr && st != N60_STATUS_OK, "reject short params", rate);
            Mb a; a.p[1] = 20;
            check(build(rate, a.p, 29, &st) == nullptr && st != N60_STATUS_OK, "reject low/mid 20", rate);
            Mb b; b.p[2] = 9000;
            check(build(rate, b.p, 29, &st) == nullptr && st != N60_STATUS_OK, "reject mid/high 9000", rate);
            Mb c; c.p[11] = 0.5f;
            check(build(rate, c.p, 29, &st) == nullptr && st != N60_STATUS_OK, "reject attack 0.5", rate);
            Mb d; d.p[26] = 2;
            check(build(rate, d.p, 29, &st) == nullptr && st != N60_STATUS_OK, "reject auto 2", rate);
            Mb e; e.p[3] = 2;
            check(build(rate, e.p, 29, &st) == nullptr && st != N60_STATUS_OK, "reject slope 2", rate);
            n60_graph *g = build(rate, ok.p, 29);
            n60_multiband_readback bad; std::memset(&bad, 0, sizeof bad);
            check(n60_graph_read_multiband(g, 5, &bad) == N60_STATUS_ABI_MISMATCH, "readback struct size", rate);
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    std::puts("n60core multiband: ok");
    return 0;
}
