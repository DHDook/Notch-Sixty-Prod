// E6 S12a: behaviour of the CLEANUP stage at the eight standard rates: DC removal, infrasonic attenuation, mains notch
// depth, live parameter posting (enable edge, retune continuity), detector readback, validation, and the 26 parameter
// layout. Kernel parity is in test_cleanup_parity.c.
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

struct Params {
    float p[26];
    Params() { std::memset(p, 0, sizeof p); p[2] = 20; p[3] = 1; p[5] = 50; p[6] = 3; p[7] = 20; p[9] = 50; for (int i = 10; i < 26; ++i) p[i] = -30; }
};

n60_graph *build(double rate, const Params &pp, n60_status *st = nullptr, uint32_t paramCount = 26) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_CLEANUP;
    s.stageId = 7;
    s.laneA = 0;
    s.laneB = 1;
    s.params = pp.p;
    s.paramCount = paramCount;
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

std::vector<float> sine(double rate, double hz, double amp, double dc, size_t n) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(dc + amp * std::sin(2.0 * M_PI * hz * (double)i / rate));
    return v;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        const size_t n = (size_t)(rate * 1.5);
        // DC removal.
        {
            Params pp; pp.p[0] = 1;
            n60_graph *g = build(rate, pp);
            check(g != nullptr, "build dc", rate);
            auto l = sine(rate, 1000, 0.0, 0.2, n), r = l;
            run(g, l, r);
            check(rmsTail(l, n - (size_t)(rate * 0.2)) < 0.01, "dc removed", rate);
            n60_graph_retire(g);
        }
        // Infrasonic: 5 Hz well down, 1 kHz untouched.
        {
            Params pp; pp.p[1] = 1; pp.p[3] = 2;
            n60_graph *g = build(rate, pp);
            auto l = sine(rate, 5, 0.5, 0, n), r = sine(rate, 1000, 0.5, 0, n);
            run(g, l, r);
            check(rmsTail(l, n / 2) < 0.5 * 0.7071 * 0.02, "infrasonic 5 Hz down >34 dB", rate);
            check(std::fabs(rmsTail(r, n / 2) - 0.5 * 0.7071) < 0.01, "infrasonic passband", rate);
            n60_graph_retire(g);
        }
        // Mains notch: 50 Hz at -30 dB, 200 Hz clear.
        {
            Params pp; pp.p[4] = 1;
            n60_graph *g = build(rate, pp);
            auto l = sine(rate, 50, 0.5, 0, n), r = sine(rate, 400, 0.5, 0, n);
            run(g, l, r);
            check(rmsTail(l, n / 2) < 0.5 * 0.7071 * 0.06, "notch depth at 50 Hz", rate);
            check(std::fabs(rmsTail(r, n / 2) - 0.5 * 0.7071) < 0.01, "notch passband", rate);
            n60_graph_retire(g);
        }
        // Live enable and retune: no discontinuity above the signal slew, detector finds 50 Hz.
        {
            Params pp; pp.p[8] = 1;
            n60_graph *g = build(rate, pp);
            auto l = sine(rate, 50, 0.3, 0, n / 2), r = l;
            run(g, l, r);
            n60_param_record rec[2] = {{7, 4, 1.0f, 0}, {7, 5, 60.0f, 0}};
            check(n60_graph_post_params(g, rec, 2) == N60_STATUS_OK, "post live params", rate);
            auto l2 = sine(rate, 60, 0.3, 0, n / 2), r2 = l2;
            run(g, l2, r2);
            double worst = 0;
            for (size_t i = 1; i < l2.size(); ++i) worst = std::fmax(worst, std::fabs((double)l2[i] - l2[i - 1]));
            check(worst < 0.3 * 2 * M_PI * 60.0 / rate * 3.0 + 1e-3, "retune continuity", rate);
            n60_mains_readback mr; std::memset(&mr, 0, sizeof mr); mr.structSize = sizeof mr;
            check(n60_graph_read_mains(g, 7, &mr) == N60_STATUS_OK, "read mains", rate);
            n60_param_record bad[1] = {{7, 5, 99.0f, 0}};
            check(n60_graph_post_params(g, bad, 1) != N60_STATUS_OK, "reject out-of-range live param", rate);
            n60_graph_retire(g);
        }
        // Detector locks on a 50 Hz tone after the window fills.
        {
            Params pp; pp.p[8] = 1;
            n60_graph *g = build(rate, pp);
            auto l = sine(rate, 50, 0.3, 0, (size_t)(rate * 2.2)), r = l;
            run(g, l, r);
            n60_mains_readback mr; std::memset(&mr, 0, sizeof mr); mr.structSize = sizeof mr;
            n60_graph_read_mains(g, 7, &mr);
            check(std::fabs(mr.frequencyHz - 50.0f) < 0.1f && mr.confidence > 0.1f, "detector finds 50 Hz", rate);
            n60_graph_retire(g);
        }
        // Validation.
        {
            Params pp; n60_status st; pp.p[5] = 90;
            check(build(rate, pp, &st) == nullptr && st != N60_STATUS_OK, "reject fundamental 90", rate);
            Params q; q.p[3] = 3;
            check(build(rate, q, &st) == nullptr && st != N60_STATUS_OK, "reject slope 3", rate);
            Params s;
            check(build(rate, s, &st, 25) == nullptr && st != N60_STATUS_OK, "reject short params", rate);
        }
    }
    if (failures) return 1;
    std::puts("n60core cleanup: ok");
    return 0;
}
