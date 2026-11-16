// E32 S4 at the eight standard rates: (R8) the compressor and multiband gain-reduction readbacks exclude make-up, so they equal
// the static transfer curve with make-up 0, +6 dB and an auto-make-up-sized value; (R10) a multiband crossover swept across a
// playing tone through 20 live edits stays within a bound of the no-edit reference's own sample-to-sample step and the realtime
// call allocates nothing; (R11) a limiter lookahead or true-peak toggle is a rebuild that warms and crossfades, with no step
// above the fade bound.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include "n60/graph.h"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

namespace {
int failures = 0;
void check(bool ok, const char *what, double rate, double a = 0, double b = 0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s at %.0f (%g, %g)\n", what, rate, a, b); ++failures; }
}
using Vec = std::vector<float>;
constexpr double TONE = 120.0;  // Hz: low, so its own second difference is tiny and a coefficient click stands out

n60_graph *build(double rate, uint32_t kind, const float *params, uint32_t count, bool pair, uint32_t block = 512) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = 5;
    s.laneA = pair ? 0 : N60_LANE_ALL;
    s.laneB = pair ? 1 : 0;
    s.params = params;
    s.paramCount = count;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = block;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

void process(n60_graph *g, const Vec &in, Vec &out, size_t off, uint32_t n) {
    const float *ip[2] = {in.data() + off, in.data() + off};
    static Vec r(1 << 16);  // sized once, outside any armed region
    float *op[2] = {out.data() + off, r.data()};
    n60_graph_process(g, ip, op, n);
}

// R8: a steady level through a 4:1 compressor with no knee reads the static curve's reduction whatever the make-up.
void compressorReadback(double rate) {
    const float level = 0.3f;
    const double over = 20.0 * std::log10((double)level) + 20.0;  // threshold -20 dB
    const double expected = over * (1.0 - 1.0 / 4.0);
    for (float makeup : {0.0f, 6.0f, 9.5f}) {
        const float p[15] = {-20, 4, 0, 1, 100, makeup, 0, 0, 0, 1, 100, 100, 0, 50, 0};
        n60_graph *g = build(rate, N60_STAGE_COMPRESSOR, p, 15, false);
        const size_t n = (size_t)(1.2 * rate);
        Vec in(n, level), out(n);
        for (size_t off = 0; off < n; off += 512) process(g, in, out, off, (uint32_t)std::min<size_t>(512, n - off));
        n60_dynamics_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_dynamics(g, 5, 0, &rb);  // drop the start-up rise of the gain from 0 dB to the make-up
        for (size_t off = 0; off < n / 4; off += 512) process(g, in, out, off, 512);
        check(n60_graph_read_dynamics(g, 5, 0, &rb) == N60_STATUS_OK, "read dynamics", rate);
        check(std::fabs(rb.grNowDb - expected) < 0.02, "compressor grNow is makeup-free", rate, rb.grNowDb, expected);
        check(std::fabs(rb.grMaxDb - expected) < 0.02, "compressor grMax is makeup-free", rate, rb.grMaxDb, expected);
        // The audio keeps the make-up.
        const double gain = 20.0 * std::log10((double)out[n - 1] / level);
        check(std::fabs(gain - (makeup - expected)) < 0.02, "audio carries make-up", rate, gain, makeup - expected);
        n60_graph_retire(g);
    }
}

// thr 5, ratio 8, atk 11, rel 14, knee 17, hpf 20, makeup 23, auto 26, bypass 29, solo 32, listen 35, detector 38, window 41,
// lookahead 42, split 43.
struct Mb {
    float p[44] = {1, 120, 3500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                   1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 0, 1};
};

void multibandReadback(double rate) {
    const float level = 0.3f;
    const double expected = (20.0 * std::log10((double)level) + 30.0) * (1.0 - 1.0 / 4.0);
    // A DC level lands in the low band (low-pass settles to it); only that band reduces.
    for (float makeup : {0.0f, 6.0f}) {
        Mb m;
        m.p[23] = makeup;
        m.p[17] = m.p[18] = m.p[19] = 0;
        m.p[29] = m.p[30] = m.p[31] = 0;  // not bypassed
        n60_graph *g = build(rate, N60_STAGE_MULTIBAND, m.p, 44, true);
        const size_t n = (size_t)(1.0 * rate);
        Vec in(n, level), out(n);
        for (size_t off = 0; off < n; off += 512) process(g, in, out, off, (uint32_t)std::min<size_t>(512, n - off));
        n60_multiband_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_multiband(g, 5, &rb);
        for (size_t off = 0; off < n / 4; off += 512) process(g, in, out, off, 512);
        check(n60_graph_read_multiband(g, 5, &rb) == N60_STATUS_OK, "read multiband", rate);
        check(std::fabs(rb.grNowDb[0] - expected) < 0.05, "multiband low-band grNow is makeup-free", rate, rb.grNowDb[0], expected);
        check(rb.grNowDb[1] < 0.05 && rb.grNowDb[2] < 0.05, "other bands read no reduction", rate, rb.grNowDb[1], rb.grNowDb[2]);
        n60_graph_retire(g);
    }
}

// R10: a tone at 120 Hz while the low/mid corner sweeps 200 -> 250 Hz in 20 edits (E33 S5b: the old limit was 250 Hz, so edits above
// it were rejected and this test never exercised them; the wide jump below now applies and has its own looser bound, ledger G16); the bands have different make-up so the
// corner crossing the tone changes the tone's band and the output would step without the crossfade.
double maxStep(const Vec &v, size_t from, size_t to) {
    double m = 0;
    for (size_t i = from + 1; i < to; ++i) m = std::max(m, std::fabs((double)v[i] - 2.0 * v[i - 1] + (i > 1 ? v[i - 2] : 0.0f)));  // second difference: a click, not the tone's slope
    return m;
}

void crossoverSweep(double rate, int mode, Vec &out, long *allocCount) {  // mode 0 none, 1 sweep, 2 jump to 230, 3 wide jump to 2500
    Mb m;
    m.p[1] = 200;
    m.p[2] = 6000;
    m.p[23] = 6;   // low band +6 dB
    m.p[24] = 0;
    m.p[25] = -6;  // high band -6 dB
    m.p[5] = m.p[6] = m.p[7] = 0;  // thresholds at 0 dB: no reduction
    m.p[8] = m.p[9] = m.p[10] = 1;
    m.p[17] = m.p[18] = m.p[19] = 0;
    m.p[29] = m.p[30] = m.p[31] = 0;
    n60_graph *g = build(rate, N60_STAGE_MULTIBAND, m.p, 44, true);
    const size_t n = (size_t)(1.2 * rate);
    Vec in(n), o(n);
    for (size_t i = 0; i < n; ++i) in[i] = 0.4f * (float)std::sin(2.0 * M_PI * TONE * (double)i / rate);
    const uint32_t block = 128;
    const size_t editEvery = (size_t)(0.02 * rate) / block * block;  // about 20 ms apart: 20 edits across 0.4 s
    const size_t editStart = (size_t)(0.4 * rate) / block * block;
    int edit = 0;
    long total = 0;
    for (size_t off = 0; off < n; off += block) {
        const uint32_t cnt = (uint32_t)std::min<size_t>(block, n - off);
        if (mode == 1 && off >= editStart && edit < 20 && (off - editStart) % editEvery == 0) {
            const float hz = 200.0f * std::pow(1.25f, (float)(edit + 1) / 20.0f);
            n60_param_record rec[1] = {{5, 1, hz, 0}};
            n60_graph_post_params(g, rec, 1);
            ++edit;
        }
        if ((mode == 2 || mode == 3) && off == editStart) {
            n60_param_record rec[1] = {{5, 1, mode == 2 ? 230.0f : 2500.0f, 0}};
            n60_graph_post_params(g, rec, 1);
        }
        allocs = 0;
        armed = true;
        process(g, in, o, off, cnt);
        armed = false;
        total += allocs.load();
    }
    if (allocCount) *allocCount = total;
    out = o;
    n60_graph_retire(g);
}

void crossoverRamp(double rate) {
    Vec ref, swept;
    long a0 = 0, a1 = 0;
    Vec jump;
    long a2 = 0;
    crossoverSweep(rate, 0, ref, &a0);
    crossoverSweep(rate, 1, swept, &a1);
    crossoverSweep(rate, 2, jump, &a2);
    Vec wide;
    long a3 = 0;
    crossoverSweep(rate, 3, wide, &a3);
    const double jumpStep = maxStep(jump, (size_t)(0.35 * rate), ref.size());
    const size_t from = (size_t)(0.45 * rate), to = ref.size();
    const double refStep = maxStep(ref, from, to);
    const double step = maxStep(swept, (size_t)(0.35 * rate), to);
    // Measured by the second difference: the tone's own is refStep (a click shows far above it). Without the crossfade the old
    // build reads 14x the reference at 44.1 kHz and 100x at 384 kHz; with it the sweep stays within 2x (the 4e-5 floor covers float noise).
    const double bound = 4.0 * refStep + 4.0e-5;
    check(step < bound, "crossover sweep has no click above the bound", rate, step, bound);
    check(jumpStep < bound, "one large crossover jump has no click above the bound", rate, jumpStep, bound);
    // G16: a 12x corner jump (200 -> 2500 Hz, possible since E33 S5b widened the limit) leaves a step from the transplanted filter
    // state at the higher rates; bounded here at -34 dB of the 0.4 tone (second difference), not at the sweep's tight bound.
    const double wideStep = maxStep(wide, (size_t)(0.35 * rate), ref.size());
    check(wideStep < 8.0e-3, "wide crossover jump stays under the loose bound", rate, wideStep, 8.0e-3);
    check(a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0, "crossover edits allocate nothing", rate, (double)(a1 + a2 + a3));
}

// R11: a limiter lookahead and true-peak toggle through a rebuild (publish) crossfades: no step above the fade bound.
void lookaheadToggle(double rate) {
    // limiter 1, ceiling -6, attack 1, release 50, lookahead 1 ms, true-peak 0, oversample 1
    float pa[7] = {1, -6, 1, 50, 1, 0, 1};
    float pb[7] = {1, -6, 1, 50, 5, 1, 1};
    n60_graph *g = build(rate, N60_STAGE_PROTECTION, pa, 7, false, 512);
    n60_rebuild_options opt;
    std::memset(&opt, 0, sizeof opt);
    opt.structSize = sizeof opt;
    opt.fadeMs = 20;
    n60_graph_set_rebuild_options(g, &opt);
    const size_t n = (size_t)(0.5 * rate);
    Vec in(n), out(n);
    const double amp = 0.1;  // well under the -6 dB ceiling: only the delay and the filters differ between the two snapshots
    for (size_t i = 0; i < n; ++i) in[i] = (float)(amp * std::sin(2.0 * M_PI * 300.0 * (double)i / rate));
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_PROTECTION;
    s.stageId = 5;
    s.laneA = N60_LANE_ALL;
    s.params = pb;
    s.paramCount = 7;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    for (size_t off = 0; off < n; off += 512) {
        if (off == (size_t)(0.1 * rate) / 512 * 512) check(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish", rate);
        process(g, in, out, off, (uint32_t)std::min<size_t>(512, n - off));
    }
    const double sineStep = amp * 2.0 * M_PI * 300.0 / rate;
    const double step = maxStep(out, (size_t)(0.02 * rate), n);
    check(step < 2.0 * sineStep, "lookahead toggle has no step above the fade bound", rate, step, sineStep);
    n60_graph_retire(g);
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        compressorReadback(rate);
        multibandReadback(rate);
        crossoverRamp(rate);
        lookaheadToggle(rate);
    }
    if (failures) {
        std::fprintf(stderr, "n60core e32 dynamics core: %d failures\n", failures);
        return 1;
    }
    std::puts("n60core e32 dynamics core: ok");
    return 0;
}
