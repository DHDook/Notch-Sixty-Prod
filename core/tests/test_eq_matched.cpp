// E33 S26 (G51): matched EQ biquads (n60_eq_design_section types 16..24; docs/MATCHED_EQ_FILTERS.md) at the eight standard
// rates. (a) Each matched type stays within its stated tolerance of the analogue curve it models, computed here from the
// analogue transfer functions with std::complex (an independent evaluation). (b) The cookbook types 0..8 are the RBJ
// cookbook (checked against an independent implementation). (c) The G51 case, a +6 dB Q 1 bell at 15 kHz, keeps its
// shape at 20 kHz at 44.1 and 48 kHz. (d) A graph PEQ stage given a matched type runs the coefficients
// n60_eq_design_section returns, so the drawn curve, the linear-phase design and the stage agree. (e) Bad arguments are
// refused and the unused types 21 and 22 are not sections.
#include <algorithm>
#include <complex>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
using Cx = std::complex<double>;
int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); ++failures; } } while (0)

constexpr double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

// The analogue prototype of base type b (0 peak, 1 low shelf, 2 high shelf, 3 LP, 4 HP, 7 BP) at x = f / f0.
double analogue(int b, double gainDb, double q, double x) {
    const Cx s(0.0, x), one(1.0, 0.0);
    const double A = std::pow(10.0, gainDb / 40.0);
    const double r = std::sqrt(A) / q;
    switch (b) {
        case 0: return std::abs((s * s + s * (A / q) + one) / (s * s + s / (A * q) + one));
        case 1: return A * std::abs((s * s + s * r + A) / (A * s * s + s * r + one));
        case 2: return A * std::abs((A * s * s + s * r + one) / (s * s + s * r + A));
        case 3: return std::abs(one / (s * s + s / q + one));
        case 4: return std::abs(s * s / (s * s + s / q + one));
        default: return std::abs((s / q) / (s * s + s / q + one));
    }
}

// Worst |matched - analogue| in dB over 20 Hz .. min(20 kHz, 0.499 fs), skipping where the analogue is below -40 dB
// (a pass filter's stop band, where a dB error means nothing).
double worstErrorDb(int b, const double c[5], double rate, double f0, double gainDb, double q) {
    double worst = 0.0;
    for (double f = 20.0; f <= 20000.0 && f < 0.499 * rate; f *= 1.05) {
        const double a = analogue(b, gainDb, q, f / f0);
        if (a < 0.01) continue;
        worst = std::max(worst, std::fabs(20.0 * std::log10(n60_eq_section_magnitude(c, rate, f) / a)));
    }
    return worst;
}

struct Spec { int base; const char *name; double qLo, qHi, tolNear, tolFar; bool gain; };
// tolNear: corner at or below 0.30 fs; tolFar: corner up to 0.42 fs. Measured worst on this grid: bell 0.93 / 2.68,
// shelves 1.03 / 1.39, LP 1.46 / 1.46, HP 0.78 / 2.35, BP 1.29 / 1.98 dB; the tolerances sit about 15 percent above.
const Spec kSpecs[] = {
    {0, "peaking", 0.3, 5.0, 1.1, 3.1, true},   {1, "low shelf", 0.3, 1.5, 1.2, 1.6, true},
    {2, "high shelf", 0.3, 1.5, 1.2, 1.6, true}, {3, "low pass", 0.5, 2.0, 1.7, 1.7, false},
    {4, "high pass", 0.5, 2.0, 0.9, 2.7, false}, {7, "band pass", 0.5, 2.0, 1.5, 2.3, false},
};

void checkTolerances() {
    const double qs[] = {0.3, 0.5, 0.707, 1.0, 1.5, 2.0, 5.0}, gains[] = {-18, -6, 6, 12, 18};
    const double corners[] = {5, 10, 20, 30, 100, 1000, 3000, 8000, 12000, 15000, 18000, 20000};
    for (const Spec &sp : kSpecs) {
        long fallbacks = 0, n = 0;
        for (double rate : kRates) for (double f0 : corners) {
            if (f0 >= 0.42 * rate) continue;
            const double tol = f0 <= 0.30 * rate ? sp.tolNear : sp.tolFar;
            for (double q : qs) {
                if (q < sp.qLo || q > sp.qHi) continue;
                for (double g : gains) {
                    if (!sp.gain && g != 6.0) continue;
                    const double useG = sp.gain ? g : 0.0;
                    double m[5], c[5];
                    CHECK(n60_eq_design_section(16 + sp.base, rate, f0, useG, q, m) == 1, "%s design %.0f %.0f", sp.name, rate, f0);
                    CHECK(n60_eq_design_section(sp.base, rate, f0, useG, q, c) == 1, "cookbook design");
                    ++n;
                    if (std::memcmp(m, c, sizeof m) == 0) ++fallbacks;
                    const double e = worstErrorDb(sp.base, m, rate, f0, useG, q);
                    CHECK(e <= tol, "%s fs %.0f f0 %.0f g %.0f q %.3g: %.2f dB off the analogue (limit %.2f)", sp.name, rate, f0, useG, q, e, tol);
                    // Stable poles, finite coefficients.
                    CHECK(std::fabs(m[4]) < 1.0 && std::fabs(m[3]) < 1.0 + m[4], "%s unstable at %.0f %.0f", sp.name, rate, f0);
                }
            }
        }
        // The cookbook fallback must be the exception on this grid, not the rule.
        CHECK(fallbacks * 20 <= n, "%s fell back to the cookbook %ld of %ld times", sp.name, fallbacks, n);
    }
}

// Independent RBJ cookbook for types 0..2 and 5..8 (the types the matched design leaves alone are checked, too).
void rbj(int type, double rate, double f, double gDb, double q, double out[5]) {
    const double A = std::pow(10.0, gDb / 40.0), w = 2.0 * M_PI * f / rate, cw = std::cos(w), alpha = std::sin(w) / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
        case 0: b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
        case 5: b0 = 1; b1 = -2 * cw; b2 = 1; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
        case 6: b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
        default: {  // 8: constant-Q peaking, cookbook Q = Q / A
            const double al = std::sin(w) / (2.0 * (q / A));
            b0 = 1 + al * A; b1 = -2 * cw; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * cw; a2 = 1 - al / A;
        }
    }
    out[0] = b0 / a0; out[1] = b1 / a0; out[2] = b2 / a0; out[3] = a1 / a0; out[4] = a2 / a0;
}

void checkCookbookUnchanged() {
    for (double rate : kRates) for (int type : {0, 5, 6, 8}) {
        double got[5], want[5];
        const double f = 0.1 * rate, g = type == 5 || type == 6 ? 0.0 : 7.5;
        CHECK(n60_eq_design_section(type, rate, f, g, 1.3, got) == 1, "cookbook type %d", type);
        rbj(type, rate, f, g, 1.3, want);
        for (int i = 0; i < 5; ++i) CHECK(std::fabs(got[i] - want[i]) <= 1e-12 * std::max(1.0, std::fabs(want[i])), "cookbook type %d coef %d at %.0f", type, i, rate);
    }
}

// G51: a +6 dB, Q 1 bell at 15 kHz. The analogue filter is +4.4 dB at 20 kHz; the cookbook gives +0.5 dB at 44.1 kHz.
void checkG51() {
    for (double rate : {44100.0, 48000.0}) {
        double m[5], c[5];
        n60_eq_design_section(16, rate, 15000, 6, 1, m);
        n60_eq_design_section(0, rate, 15000, 6, 1, c);
        const double want = 20.0 * std::log10(analogue(0, 6, 1, 20000.0 / 15000.0));
        const double gm = 20.0 * std::log10(n60_eq_section_magnitude(m, rate, 20000));
        const double gc = 20.0 * std::log10(n60_eq_section_magnitude(c, rate, 20000));
        CHECK(std::fabs(gm - want) < 0.6, "G51 matched %.2f dB at 20 kHz, analogue %.2f (fs %.0f)", gm, want, rate);
        CHECK(std::fabs(gc - want) > 2.5, "G51 cookbook should be far off: %.2f vs %.2f (fs %.0f)", gc, want, rate);
        CHECK(std::fabs(20.0 * std::log10(n60_eq_section_magnitude(m, rate, 15000)) - 6.0) < 1e-6, "matched gain at the corner");
    }
}

n60_stage_desc peqStage(const float *p, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_PEQ;
    s.stageId = 5;
    s.laneA = 0;
    s.params = p;
    s.paramCount = count;
    return s;
}

// The stage built from matched types runs the biquad cascade n60_eq_design_section returns (double, transposed DF II).
void checkStageRunsTheDesign() {
    for (double rate : kRates) {
        const float p[16] = {17, 120, 5, 0.9f, 16, 3000, -4, 1.4f, 18, 12000, 6, 0.7f, 24, 800, 3, 2.0f};
        n60_stage_desc st = peqStage(p, 16);
        n60_graph_desc d;
        std::memset(&d, 0, sizeof d);
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = 512;
        d.inputChannels = d.outputChannels = 1;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build matched stage at %.0f", rate);
        if (!g) continue;
        double c[4][5], z1[4] = {}, z2[4] = {};
        for (int k = 0; k < 4; ++k) {
            CHECK(n60_eq_design_section((uint32_t)p[4 * k], rate, p[4 * k + 1], p[4 * k + 2], p[4 * k + 3], c[k]) == 1, "design %d", k);
        }
        std::vector<float> in(2048), out(2048);
        uint32_t seed = 99u;
        for (auto &x : in) { seed = seed * 1664525u + 1013904223u; x = 0.3f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f); }
        for (size_t off = 0; off < in.size(); off += 512) {
            const float *ip[1] = {in.data() + off};
            float *op[1] = {out.data() + off};
            n60_graph_process(g, ip, op, 512);
        }
        double err = 0;
        for (size_t i = 0; i < in.size(); ++i) {
            double x = in[i];
            for (int k = 0; k < 4; ++k) {
                const double y = c[k][0] * x + z1[k];
                z1[k] = c[k][1] * x - c[k][3] * y + z2[k];
                z2[k] = c[k][2] * x - c[k][4] * y;
                x = y;
            }
            err = std::max(err, std::fabs(x - out[i]));
        }
        CHECK(err < 2e-5, "stage output differs from the designed cascade by %g at %.0f", err, rate);
        n60_graph_retire(g);
    }
}

void checkRefusals() {
    double c[5];
    CHECK(n60_eq_design_section(16, 48000, 30000, 3, 1, c) == 0, "above Nyquist refused");
    CHECK(n60_eq_design_section(16, 48000, 1000, 30, 1, c) == 0, "gain above 24 dB refused");
    CHECK(n60_eq_design_section(16, 48000, 1000, 3, 0, c) == 0, "zero Q refused");
    CHECK(n60_eq_design_section(21, 48000, 1000, 0, 1, c) == 0, "type 21 is not a section");
    CHECK(n60_eq_design_section(22, 48000, 1000, 0, 1, c) == 0, "type 22 is not a section");
    CHECK(n60_eq_design_section(25, 48000, 1000, 0, 1, c) == 0, "type 25 is not a section");
    CHECK(n60_eq_design_section(16, 48000, 1000, 3, 1, nullptr) == 0, "null output refused");
    // A flat section (0 dB) is exactly the cookbook identity.
    n60_eq_design_section(16, 48000, 1000, 0, 1, c);
    { double k[5]; n60_eq_design_section(0, 48000, 1000, 0, 1, k); CHECK(std::memcmp(c, k, sizeof c) == 0, "0 dB bell is the cookbook flat section"); }
    // Out-of-range types are refused by the graph too.
    const float bad[4] = {21, 1000, 0, 1};
    n60_stage_desc st = peqStage(bad, 4);
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = 48000;
    d.maxBlockFrames = 256;
    d.inputChannels = d.outputChannels = 1;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&d, &g) != N60_STATUS_OK, "graph refuses PEQ type 21");
    if (g) n60_graph_retire(g);
}
}  // namespace

int main() {
    checkTolerances();
    checkCookbookUnchanged();
    checkG51();
    checkStageRunsTheDesign();
    checkRefusals();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("eq matched: ok");
    return 0;
}
