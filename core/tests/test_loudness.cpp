// E6 S12c: behaviour of the LOUDNESS stage (loudness match, loudness contour, dialogue leveler) at the eight standard
// rates: the match reaches the target, the contour follows the master gain without a step, the leveler boosts a quiet
// band, off is bit exact, readbacks, validation and live posting. Kernel parity is in test_loudness_parity.c.
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

enum { MOn = 0, MGate, Target, MaxCorr, MAtk, MRel, COn, Strength, PerBand, Source, Phons, MaxBoost, MaxCut, Master,
       LOn, LGate, Lo, Hi, Gap, Ratio, LMax, Det, LAtk, LRel, PGate, ModLo, ModHi, Env, Meas, CFl, CCe, MinC };

struct P {
    float p[32] = {0, 0, -20, 10, 0.5f, 2, 0, 0.6f, 0, 0, 80, 12, 3, 1,
                   0, 0, 300, 3500, 6, 3, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f};
};

n60_graph *build(double rate, const float *params, uint32_t count, n60_status *st = nullptr, uint32_t kind = N60_STAGE_LOUDNESS) {
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

void run(n60_graph *g, std::vector<float> &l, std::vector<float> &r, size_t from = 0, size_t to = 0) {
    if (to == 0) to = l.size();
    std::vector<float> ol(l.size()), orr(r.size());
    for (size_t off = from; off < to; off += 512) {
        const uint32_t n = (uint32_t)std::fmin(512.0, (double)(to - off));
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, n);
    }
    for (size_t i = from; i < to; ++i) { l[i] = ol[i]; r[i] = orr[i]; }
}

std::vector<float> sine(double rate, double hz, double amp, size_t n, double phase = 0.0) {
    std::vector<float> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = (float)(amp * std::sin(2.0 * M_PI * hz * (double)i / rate + phase));
    return v;
}

// Amplitude of the hz component over the last `len` samples (len a whole number of cycles).
double toneAmp(const std::vector<float> &v, double rate, double hz, size_t len) {
    double s = 0, c = 0;
    for (size_t i = v.size() - len; i < v.size(); ++i) {
        const double ph = 2.0 * M_PI * hz * (double)i / rate;
        s += v[i] * std::sin(ph);
        c += v[i] * std::cos(ph);
    }
    return 2.0 * std::sqrt(s * s + c * c) / (double)len;
}

n60_loudness_readback readback(n60_graph *g, n60_status *st = nullptr) {
    n60_loudness_readback rb;
    std::memset(&rb, 0, sizeof rb);
    rb.structSize = sizeof rb;
    const n60_status s = n60_graph_read_loudness(g, 5, &rb);
    if (st) *st = s;
    return rb;
}

}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        const size_t sec = (size_t)rate;
        // Match: the 3 s measurement and the attack bring a loud tone to the target, inside the correction limit.
        {
            P pp; pp.p[MOn] = 1; pp.p[Target] = -18;
            n60_graph *g = build(rate, pp.p, 32);
            check(g != nullptr, "build loudness", rate);
            auto l = sine(rate, 1000, 0.5, 14 * sec), r = l;
            run(g, l, r);
            const n60_loudness_readback rb = readback(g);
            check(std::fabs(rb.shortTermLufs - (-9.32f)) < 0.15f, "measured LUFS of a 0.5 sine", rate);
            check(std::fabs(rb.matchGainDb - (-18.0f - rb.shortTermLufs)) < 0.3f, "match gain reaches target minus measured", rate);
            const double outDb = 20 * std::log10(toneAmp(l, rate, 1000, sec) / 0.5);
            check(std::fabs(outDb - rb.matchGainDb) < 0.3, "output level follows the gain", rate);
            n60_graph_retire(g);
            // A quiet signal is held by the gate and by the correction limit.
            P q; q.p[MOn] = 1; q.p[MGate] = 1; q.p[MaxCorr] = 3;
            g = build(rate, q.p, 32);
            auto l2 = sine(rate, 1000, 0.0005, 8 * sec), r2 = l2;  // about -69 LUFS: under the -60 gate
            run(g, l2, r2);
            check(std::fabs(readback(g).matchGainDb) < 0.05f, "dialogue gate holds the gain at 0", rate);
            n60_graph_retire(g);
            P w; w.p[MOn] = 1; w.p[MaxCorr] = 3;
            g = build(rate, w.p, 32);
            auto l3 = sine(rate, 1000, 0.5, 14 * sec), r3 = l3;
            run(g, l3, r3);
            check(std::fabs(readback(g).matchGainDb - (-3.0f)) < 0.05f, "correction limited to 3 dB", rate);
            n60_graph_retire(g);
        }
        // Contour, simple: a master gain step posted mid-stream moves the contour without a step.
        {
            P pp; pp.p[COn] = 1; pp.p[Strength] = 1; pp.p[Master] = 1;
            const size_t n = 2 * sec, at = sec;
            std::vector<float> keep[3];
            for (int mode = 0; mode < 3; ++mode) {  // 0 stepped, 1 steady dry, 2 steady wet
                P cc = pp;
                cc.p[Master] = mode == 2 ? 0.01f : 1.0f;
                n60_graph *g = build(rate, cc.p, 32);
                auto l = sine(rate, 100, 0.3, n), r = l;
                run(g, l, r, 0, at);
                if (mode == 0) {
                    n60_param_record rec[1] = {{5, Master, 0.01f, 0}};
                    check(n60_graph_post_params(g, rec, 1) == N60_STATUS_OK, "post master gain", rate);
                }
                run(g, l, r, at, n);
                keep[mode] = l;
                if (mode == 0) {
                    const n60_loudness_readback rb = readback(g);
                    check(std::fabs(rb.contourScale - 1.0f) < 0.01f, "contour scale full at -40 dB master", rate);
                    check(std::fabs(rb.lowCompensationDb - 6.0f) < 0.1f && std::fabs(rb.highCompensationDb - 3.0f) < 0.1f, "shelf compensation 6 / 3 dB", rate);
                }
                n60_graph_retire(g);
            }
            // The stepped run is the dry input crossfaded to the settled wet run by the 5 ms one-pole mix: no sample strays
            // from that smooth model by more than -90 dBFS.
            const auto in = sine(rate, 100, 0.3, n);
            const double pole = std::exp(-1.0 / (rate * 0.005));
            double worst = 0;
            for (size_t i = at; i < at + sec / 4; ++i) {
                const double mix = 1.0 - std::pow(pole, (double)(i - at + 1));
                const double expect = in[i] + ((double)keep[2][i] - in[i]) * mix;
                worst = std::fmax(worst, std::fabs((double)keep[0][i] - expect));
            }
            check(worst < 3.2e-5, "master gain step has no click above -90 dBFS", rate);
            check(toneAmp(keep[0], rate, 100, sec) > toneAmp(keep[1], rate, 100, sec) * 1.5, "100 Hz raised after the step", rate);
        }
        // Contour, per-band from system volume: low master volume boosts the low band by the phon deficit.
        {
            P pp; pp.p[COn] = 1; pp.p[PerBand] = 1; pp.p[Strength] = 1; pp.p[Master] = 0.01f;
            n60_graph *g = build(rate, pp.p, 32);
            auto l = sine(rate, 100, 0.2, 2 * sec), r = l;
            run(g, l, r);
            const n60_loudness_readback rb = readback(g);
            check(std::fabs(rb.estimatedPhons - 46.0f) < 0.05f, "phon estimate from master gain", rate);
            check(std::fabs(rb.lowCompensationDb - 8.5f) < 0.1f && std::fabs(rb.highCompensationDb - 4.25f) < 0.1f, "per-band compensation", rate);
            n60_graph_retire(g);
        }
        // Leveler: a quiet in-band tone under a loud out-of-band one is boosted by the readback amount.
        {
            P pp; pp.p[LOn] = 1;
            n60_graph *g = build(rate, pp.p, 32);
            auto l = sine(rate, 8000, 0.3, 4 * sec), q = sine(rate, 1000, 0.02, 4 * sec);
            for (size_t i = 0; i < l.size(); ++i) l[i] += q[i];
            auto r = l;
            run(g, l, r);
            const n60_loudness_readback rb = readback(g);
            check(rb.dialogueBoostDb > 5.0f && std::fabs(rb.dialogueBoostDb - (rb.dialogueGapDb - 6.0f) * (2.0f / 3.0f)) < 0.2f, "leveler boosts toward the limit", rate);
            check(rb.dialogueGapDb > 6.0f, "gap above target", rate);
            const double outDb = 20 * std::log10(toneAmp(l, rate, 1000, sec) / 0.02);
            check(std::fabs(outDb - rb.dialogueBoostDb) < 0.3, "1 kHz gains the boost", rate);
            n60_graph_retire(g);
        }
        // Everything off: bit exact pass-through and zero telemetry.
        {
            P pp;
            n60_graph *g = build(rate, pp.p, 32);
            auto l = sine(rate, 1000, 0.5, 4096), r = sine(rate, 2000, 0.3, 4096);
            auto l0 = l, r0 = r;
            run(g, l, r);
            check(std::memcmp(l.data(), l0.data(), l.size() * 4) == 0 && std::memcmp(r.data(), r0.data(), r.size() * 4) == 0, "off is bit exact", rate);
            const n60_loudness_readback rb = readback(g);
            check(rb.matchGainDb == 0.0f && rb.dialogueBoostDb == 0.0f && rb.contourScale == 0.0f, "off readbacks are zero", rate);
            n60_graph_retire(g);
        }
        // Live parameters and validation.
        {
            P pp; pp.p[MOn] = 1;
            n60_graph *g = build(rate, pp.p, 32);
            auto l = sine(rate, 1000, 0.5, 8 * sec), r = l;
            run(g, l, r);
            check(readback(g).matchGainDb < -3.0f, "match active", rate);
            n60_param_record off[1] = {{5, MOn, 0.0f, 0}};
            check(n60_graph_post_params(g, off, 1) == N60_STATUS_OK, "post match off", rate);
            auto l2 = sine(rate, 1000, 0.5, sec), r2 = l2;
            run(g, l2, r2);
            check(std::fabs(toneAmp(l2, rate, 1000, sec / 2) / 0.5 - 1.0) < 0.01, "match off restores unity", rate);
            n60_param_record bad[1] = {{5, Target, -30.0f, 0}};
            check(n60_graph_post_params(g, bad, 1) != N60_STATUS_OK, "reject target -30", rate);
            n60_param_record bad2[1] = {{5, Lo, 4000.0f, 0}};
            check(n60_graph_post_params(g, bad2, 1) != N60_STATUS_OK, "reject band low above band high", rate);
            n60_param_record bad3[1] = {{5, MOn, 0.5f, 0}};
            check(n60_graph_post_params(g, bad3, 1) != N60_STATUS_OK, "reject non-flag", rate);
            n60_param_record ok[1] = {{5, Lo, 500.0f, 0}};
            check(n60_graph_post_params(g, ok, 1) == N60_STATUS_OK, "accept band low 500", rate);
            n60_status st;
            n60_loudness_readback rb;
            std::memset(&rb, 0, sizeof rb);
            rb.structSize = sizeof rb - 4;
            check(n60_graph_read_loudness(g, 5, &rb) == N60_STATUS_ABI_MISMATCH, "readback structSize checked", rate);
            readback(g, &st);
            check(st == N60_STATUS_OK, "readback ok", rate);
            rb.structSize = sizeof rb;
            check(n60_graph_read_loudness(g, 99, &rb) != N60_STATUS_OK, "readback of another stage rejected", rate);
            n60_graph_retire(g);
        }
        {
            n60_status st;
            P a; a.p[MAtk] = 0.1f;
            check(build(rate, a.p, 32, &st) == nullptr && st != N60_STATUS_OK, "reject attack 0.1", rate);
            P b; b.p[Lo] = 4000;
            check(build(rate, b.p, 32, &st) == nullptr && st != N60_STATUS_OK, "reject inverted band", rate);
            P c;
            check(build(rate, c.p, 31, &st) == nullptr && st != N60_STATUS_OK, "reject short params", rate);
            P d; d.p[CFl] = 0.6f;
            check(build(rate, d.p, 32, &st) == nullptr && st != N60_STATUS_OK, "reject floor above ceiling", rate);
        }
    }
    if (failures) return 1;
    std::puts("n60core loudness: ok");
    return 0;
}
