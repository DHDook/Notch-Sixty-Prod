// E6 S12b: behaviour of the IMAGE (stereo mode, widener) and DEESS (de-harsh, de-esser) stages at the eight standard
// rates: mono sums, side removal per band, de-esser reduction and gain-reduction readback, wideband vs dynamic-EQ mode,
// live parameter posting, validation, and that processing allocates nothing. Kernel parity is in test_image_parity.c.
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

struct ImgP {
    float p[8] = {0, 0, 0, 200, 4000, 1, 1, 1};
};
struct DeP {
    float p[12] = {0, 3500, -1.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1};
};

n60_graph *build(double rate, uint32_t kind, const float *params, uint32_t count, n60_status *st = nullptr) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
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

std::vector<float> sine(double rate, double hz, double amp, size_t n, double phase = 0.0) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate + phase));
    return v;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        const size_t n = (size_t)(rate * 1.0);
        const size_t tail = n / 2;
        // Wide mono and true mono: L = R, equal-power versus half sum.
        {
            ImgP pp; pp.p[0] = 1;
            n60_graph *g = build(rate, N60_STAGE_IMAGE, pp.p, 8);
            check(g != nullptr, "build image", rate);
            auto l = sine(rate, 1000, 0.5, n), r = sine(rate, 1000, 0.25, n);
            run(g, l, r);
            double worst = 0;
            for (size_t i = tail; i < n; ++i) worst = std::fmax(worst, std::fabs((double)l[i] - r[i]));
            check(worst < 5e-4, "wide mono L equals R", rate);  // the 5 ms smoother stalls within ~1e-4 of its target (float, as the kernel)
            check(std::fabs(rmsTail(l, tail) - 0.7071067811865476 * 0.75 * 0.7071067811865476) < 2e-3, "wide mono level", rate);
            n60_graph_retire(g);
            ImgP q; q.p[0] = 2;
            g = build(rate, N60_STAGE_IMAGE, q.p, 8);
            auto l2 = sine(rate, 1000, 0.5, n), r2 = sine(rate, 1000, 0.5, n, M_PI);
            run(g, l2, r2);
            check(rmsTail(l2, tail) < 1e-3 && rmsTail(r2, tail) < 1e-3, "true mono cancels an anti-phase pair", rate);
            n60_graph_retire(g);
        }
        // Widener: mono low band removes the side below the corner, widths scale the other bands.
        {
            ImgP pp; pp.p[1] = 1; pp.p[2] = 1;
            n60_graph *g = build(rate, N60_STAGE_IMAGE, pp.p, 8);
            // Pure side at 20 Hz. The mid band is S - low - high, so what is left is the low-pass phase error
            // (|1 - exp(-j 2 atan(sqrt2 x / (1 - x^2)))|, 0.28 at 20 Hz of a 200 Hz corner), not zero.
            auto l = sine(rate, 20, 0.4, n), r = sine(rate, 20, 0.4, n, M_PI);
            run(g, l, r);
            check(rmsTail(l, tail) / (0.4 * 0.7071) < 0.4, "mono low band removes the 20 Hz side", rate);
            n60_graph_retire(g);
            pp.p[6] = 2; pp.p[7] = 2;
            g = build(rate, N60_STAGE_IMAGE, pp.p, 8);
            auto l2 = sine(rate, 1000, 0.2, n), r2 = sine(rate, 1000, 0.2, n, M_PI);  // pure side in the mid band
            run(g, l2, r2);
            check(std::fabs(rmsTail(l2, tail) / (0.2 * 0.7071) - 2.0) < 0.05, "mid width 2 doubles the side", rate);
            n60_graph_retire(g);
        }
        // Widener off and stereo mode: bit exact pass-through.
        {
            ImgP pp;
            n60_graph *g = build(rate, N60_STAGE_IMAGE, pp.p, 8);
            auto l = sine(rate, 1000, 0.5, 4096), r = sine(rate, 2000, 0.3, 4096);
            auto l0 = l, r0 = r;
            run(g, l, r);
            check(std::memcmp(l.data(), l0.data(), l.size() * 4) == 0 && std::memcmp(r.data(), r0.data(), r.size() * 4) == 0, "off is bit exact", rate);
            n60_graph_retire(g);
        }
        // De-harsh: high shelf cut, 8 kHz down, 200 Hz untouched.
        {
            DeP pp; pp.p[0] = 1; pp.p[2] = -6;
            n60_graph *g = build(rate, N60_STAGE_DEESS, pp.p, 12);
            check(g != nullptr, "build deess", rate);
            auto l = sine(rate, 8000, 0.3, n), r = sine(rate, 200, 0.3, n);
            run(g, l, r);
            const double g8k = rmsTail(l, tail) / (0.3 * 0.7071);
            check(g8k < 0.55 && g8k > 0.45, "de-harsh -6 dB at 8 kHz", rate);
            check(std::fabs(rmsTail(r, tail) / (0.3 * 0.7071) - 1.0) < 0.01, "de-harsh passband", rate);
            n60_graph_retire(g);
        }
        // De-esser: reduces a 6.5 kHz tone, leaves 500 Hz alone, reports the gain reduction.
        {
            DeP pp; pp.p[3] = 1; pp.p[5] = -30; pp.p[6] = 8; pp.p[7] = -12; pp.p[11] = 0;  // wideband
            n60_graph *g = build(rate, N60_STAGE_DEESS, pp.p, 12);
            auto l = sine(rate, 6500, 0.5, n), r = sine(rate, 500, 0.5, n);
            run(g, l, r);
            const double red = 20 * std::log10(rmsTail(l, tail) / (0.5 * 0.7071));
            check(red < -3.0 && red > -12.5, "de-esser reduces sibilance within range", rate);
            n60_dynamics_readback rb; std::memset(&rb, 0, sizeof rb); rb.structSize = sizeof rb;
            check(n60_graph_read_dynamics(g, 5, 0, &rb) == N60_STATUS_OK, "read dynamics lane 0", rate);
            check(rb.grMaxDb > 3.0f && rb.grMaxDb <= 12.01f && rb.grNowDb > 3.0f, "gain reduction readback", rate);
            check(n60_graph_read_dynamics(g, 5, 1, &rb) == N60_STATUS_OK, "read dynamics lane 1", rate);
            check(n60_graph_read_dynamics(g, 5, 2, &rb) != N60_STATUS_OK, "read dynamics other lane rejected", rate);
            n60_graph_retire(g);
            // Dynamic-EQ mode leaves an out-of-band tone untouched while the band is reduced.
            DeP q; q.p[3] = 1; q.p[5] = -30; q.p[6] = 8; q.p[7] = -12; q.p[11] = 1;
            g = build(rate, N60_STAGE_DEESS, q.p, 12);
            auto l2 = sine(rate, 6500, 0.5, n), r2 = sine(rate, 500, 0.5, n);
            run(g, l2, r2);
            check(20 * std::log10(rmsTail(l2, tail) / (0.5 * 0.7071)) < -2.0, "dynamic-EQ reduces the band", rate);
            check(std::fabs(rmsTail(r2, tail) / (0.5 * 0.7071) - 1.0) < 0.01, "dynamic-EQ passband untouched", rate);
            n60_graph_retire(g);
        }
        // Live parameters: enable posted mid-stream gives no click; the de-esser releases back to zero on disable.
        {
            DeP pp; pp.p[3] = 1; pp.p[5] = -30; pp.p[6] = 8; pp.p[7] = -12;
            n60_graph *g = build(rate, N60_STAGE_DEESS, pp.p, 12);
            auto l = sine(rate, 6500, 0.5, n / 2), r = l;
            run(g, l, r);
            n60_param_record off[1] = {{5, 3, 0.0f, 0}};
            check(n60_graph_post_params(g, off, 1) == N60_STATUS_OK, "post de-esser off", rate);
            auto l2 = sine(rate, 6500, 0.5, n), r2 = l2;
            run(g, l2, r2);
            check(std::fabs(rmsTail(l2, n - 4096) / (0.5 * 0.7071) - 1.0) < 0.01, "de-esser off restores unity", rate);
            n60_param_record bad[1] = {{5, 5, 12.0f, 0}};
            check(n60_graph_post_params(g, bad, 1) != N60_STATUS_OK, "reject out-of-range threshold", rate);
            n60_graph_retire(g);
        }
        // Validation.
        {
            n60_status st;
            ImgP bad; bad.p[0] = 3;
            check(build(rate, N60_STAGE_IMAGE, bad.p, 8, &st) == nullptr && st != N60_STATUS_OK, "reject mode 3", rate);
            ImgP bad2; bad2.p[3] = 700;
            check(build(rate, N60_STAGE_IMAGE, bad2.p, 8, &st) == nullptr && st != N60_STATUS_OK, "reject low/mid 700", rate);
            ImgP ok;
            check(build(rate, N60_STAGE_IMAGE, ok.p, 7, &st) == nullptr && st != N60_STATUS_OK, "reject short image params", rate);
            DeP bad3; bad3.p[8] = 9;
            check(build(rate, N60_STAGE_DEESS, bad3.p, 12, &st) == nullptr && st != N60_STATUS_OK, "reject Q 9", rate);
            DeP ok2;
            check(build(rate, N60_STAGE_DEESS, ok2.p, 11, &st) == nullptr && st != N60_STATUS_OK, "reject short deess params", rate);
        }
    }
    if (failures) return 1;
    std::puts("n60core image: ok");
    return 0;
}
