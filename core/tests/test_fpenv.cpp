// E20 S2: the realtime call owns its floating-point environment. n60_graph_process sets
// flush-to-zero for the call and restores the caller's state; decaying filter, dynamics and FIR
// tails therefore never emit subnormal samples and settle to exact zero; the load readback
// reports sane numbers.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"
#include "platform/fpenv.hpp"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static n60_stage_desc stage(uint32_t kind, uint32_t id, const float *p, uint32_t np) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = N60_LANE_ALL;
    s.params = p;
    s.paramCount = np;
    return s;
}

static n60_graph *build(double rate, uint32_t maxBlock, n60_stage_desc *st, uint32_t n) {
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = maxBlock;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = n;
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return nullptr;
    return g;
}

// Impulse, then silence. Returns false on any subnormal output; sets settled when the last block is exactly zero.
static float gLastPeak = 0.0f;
static void runTail(n60_graph *g, double rate, bool &subnormal, bool &settled, double seconds = 1.5) {
    constexpr uint32_t N = 512;
    std::vector<float> l(N, 0.0f), r(N, 0.0f), ol(N), orr(N);
    const float *in[2] = {l.data(), r.data()};
    float *out[2] = {ol.data(), orr.data()};
    subnormal = false;
    settled = false;
    const long blocks = static_cast<long>(rate * seconds / N) + 1;
    for (long b = 0; b < blocks; b++) {
        if (b == 0) { l[0] = 0.5f; r[0] = -0.5f; } else { l[0] = r[0] = 0.0f; }
        if (n60_graph_process(g, in, out, N) != N60_STATUS_OK) { CHECK(false, "process"); return; }
        bool allZero = true;
        float peak = 0.0f;
        for (uint32_t i = 0; i < N; i++) {
            if (std::fpclassify(ol[i]) == FP_SUBNORMAL || std::fpclassify(orr[i]) == FP_SUBNORMAL) subnormal = true;
            if (ol[i] != 0.0f || orr[i] != 0.0f) allZero = false;
            peak = std::fmax(peak, std::fmax(std::fabs(ol[i]), std::fabs(orr[i])));
        }
        if (b == blocks - 1) { settled = allZero; gLastPeak = peak; }
    }
}

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

    // The caller's FP state is untouched by a call, whether FZ was clear or already set.
    {
        const float g = 0.5f;
        n60_stage_desc st[1] = {stage(N60_STAGE_GAIN, 1, &g, 1)};
        n60_graph *gr = build(48000, 64, st, 1);
        CHECK(gr != nullptr, "build");
        float l[64] = {}, r[64] = {}, ol[64], orr[64];
        const float *in[2] = {l, r};
        float *out[2] = {ol, orr};
        const uint64_t before = n60::fpenvRead();
        CHECK(n60_graph_process(gr, in, out, 64) == N60_STATUS_OK, "process");
        CHECK(n60::fpenvRead() == before, "FP state restored (clear)");
        n60::fpenvWrite(before | n60::fpenvFlushMask());
        const uint64_t withFz = n60::fpenvRead();
        CHECK(n60_graph_process(gr, in, out, 64) == N60_STATUS_OK, "process");
        CHECK(n60::fpenvRead() == withFz, "FP state restored (FZ set)");
        n60::fpenvWrite(before);
        n60_graph_retire(gr);
    }

    for (double rate : rates) {
        // High-Q PEQ ringing down.
        {
            const float peq[8] = {0, static_cast<float>(2000 * rate / 48000), 12, 12, 1, static_cast<float>(300 * rate / 48000), -9, 8};
            n60_stage_desc st[1] = {stage(N60_STAGE_PEQ, 1, peq, 8)};
            n60_graph *g = build(rate, 512, st, 1);
            CHECK(g != nullptr, "peq build %.0f", rate);
            bool sub, settled;
            runTail(g, rate, sub, settled);
            CHECK(!sub, "peq subnormal output at %.0f", rate);
            CHECK(settled, "peq not settled to zero at %.0f", rate);
            n60_graph_retire(g);
        }
        // Compressor following a decaying input.
        {
            const float comp[10] = {-30, 4, 6, 1, 50, 0, 0, 1, 0, 1};
            const float peq[4] = {0, static_cast<float>(1000 * rate / 48000), 6, 6};
            n60_stage_desc st[2] = {stage(N60_STAGE_PEQ, 1, peq, 4), stage(N60_STAGE_COMPRESSOR, 2, comp, 10)};
            n60_graph *g = build(rate, 512, st, 2);
            CHECK(g != nullptr, "comp build %.0f", rate);
            bool sub, settled;
            runTail(g, rate, sub, settled);
            CHECK(!sub, "dynamics subnormal output at %.0f", rate);
            CHECK(settled, "dynamics not settled to zero at %.0f", rate);
            n60_graph_retire(g);
        }
        // FIR whose taps decay into the subnormal float range.
        {
            std::vector<float> taps(1024);
            for (size_t i = 0; i < taps.size(); i++) taps[i] = static_cast<float>(std::exp(-0.2 * static_cast<double>(i)));
            n60_stage_desc st[1] = {stage(N60_STAGE_FIR, 1, taps.data(), static_cast<uint32_t>(taps.size()))};
            n60_graph *g = build(rate, 512, st, 1);
            CHECK(g != nullptr, "fir build %.0f", rate);
            bool sub, settled;
            runTail(g, rate, sub, settled);
            CHECK(!sub, "fir subnormal output at %.0f", rate);
            CHECK(settled, "fir not settled to zero at %.0f", rate);
            n60_graph_retire(g);
        }

        // E20 S4 (G15): the pair and linked stages added since E6 settle to exact zero with no subnormal output.
        {
            float clean[26] = {1, 1, 20, 1, 1, 50, 3, 20, 1, 50};
            for (int i = 10; i < 26; ++i) clean[i] = -30;
            const float img[8] = {1, 1, 0, 200, 4000, 0.5f, 1.5f, 1.5f};
            const float ld[32] = {1, 1, -20, 10, 0.5f, 2, 1, 0.6f, 1, 1, 80, 12, 3, 0.5f,
                                  1, 1, 1000, 5000, 3, 6, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f};
            const float mb[29] = {1, 120, 2500, 1, 0, -30, -26, -28, 4, 3, 6, 10, 5, 2, 120, 80, 60, 6, 4, 0, 60, 0, 120, 0, 1, 0, 1, 0, 1};
            const float xt[2] = {800, 0.5f};
            const float hp[11] = {-3, 0.5f, 30, 0.09f, 700, 0, 0, 0, 0, 0, 0};
            const float pg[5] = {-90, 6, 10, 5, 5};
            struct Case { const char *name; uint32_t kind; const float *p; uint32_t np; bool pair; bool exactZero; } cases[] = {
                {"cleanup", N60_STAGE_CLEANUP, clean, 26, true, false}, {"image", N60_STAGE_IMAGE, img, 8, true, true},
                {"loudness", N60_STAGE_LOUDNESS, ld, 32, true, true}, {"multiband", N60_STAGE_MULTIBAND, mb, 29, true, true},
                {"crosstalk", N60_STAGE_CROSSTALK, xt, 2, true, true}, {"headphone", N60_STAGE_HEADPHONE, hp, 11, true, true},
                {"pause gate", N60_STAGE_PAUSE_GATE, pg, 5, false, true}};
            for (const Case &c : cases) {
                n60_stage_desc st[1] = {stage(c.kind, 1, c.p, c.np)};
                st[0].laneA = 0;
                if (c.pair) st[0].laneB = 1; else st[0].laneMask = 3;
                n60_graph *g = build(rate, 512, st, 1);
                CHECK(g != nullptr, "%s build %.0f", c.name, rate);
                if (!g) continue;
                bool sub, settled;
                runTail(g, rate, sub, settled, 1.5);
                CHECK(!sub, "%s subnormal output at %.0f", c.name, rate);
                // E20 G18: LOUDNESS and MULTIBAND settle to exact zero. CLEANUP keeps a gated noise floor (kEps 1e-12 in the denoiser
                // detector) that leaves a constant residual near 2.1e-12 (-234 dBFS) at every rate; the recorded bound is 1e-11.
                if (std::strcmp(c.name, "cleanup") == 0) CHECK(gLastPeak < 1.0e-11f, "cleanup residual %g at %.0f", gLastPeak, rate);
                if (c.exactZero) CHECK(settled, "%s not settled to zero at %.0f", c.name, rate);
                n60_graph_retire(g);
            }
        }
    }

    // A non-finite burst must not poison the dynamics stages' recursive state (a SANITISE stage normally precedes them): the stages recover once clean input returns.
    {
        const float comp[10] = {-30, 4, 6, 1, 50, 0, 0, 1, 0, 1};
        const float expd[6] = {-50, 2, -20, 1, 50, 0};
        n60_stage_desc st[2] = {stage(N60_STAGE_COMPRESSOR, 2, comp, 10), stage(N60_STAGE_EXPANDER, 3, expd, 6)};
        n60_graph *g = build(48000, 256, st, 2);
        CHECK(g != nullptr, "nan build");
        std::vector<float> l(256), r(256), ol(256), orr(256);
        const float *in[2] = {l.data(), r.data()};
        float *out[2] = {ol.data(), orr.data()};
        for (int b = 0; b < 400; b++) {
            for (int i = 0; i < 256; i++) {
                l[i] = r[i] = 0.2f * std::sin(0.05f * static_cast<float>(b * 256 + i));
                if (b == 20 && i < 4) { l[i] = NAN; r[i] = INFINITY; }
            }
            n60_graph_process(g, in, out, 256);
        }
        bool finite = true;
        float peak = 0.0f;
        for (int i = 0; i < 256; i++) {
            if (!std::isfinite(ol[i]) || !std::isfinite(orr[i])) finite = false;
            peak = std::fmax(peak, std::fabs(ol[i]));
        }
        CHECK(finite, "output non-finite after burst");
        CHECK(peak > 0.01f, "stage state poisoned after non-finite burst (peak %f)", peak);
        n60_graph_retire(g);
    }

    // Load readback: after more than one second of blocks a window is published.
    {
        const float g1 = 0.5f;
        n60_stage_desc st[1] = {stage(N60_STAGE_GAIN, 1, &g1, 1)};
        n60_graph *g = build(48000, 256, st, 1);
        n60_graph_load ld{};
        ld.structSize = sizeof ld;
        CHECK(n60_graph_read_load(g, &ld) == N60_STATUS_OK, "read_load");
        CHECK(ld.windowBlocks == 0, "no window yet");
        float l[256] = {}, r[256] = {}, ol[256], orr[256];
        const float *in[2] = {l, r};
        float *out[2] = {ol, orr};
        for (int b = 0; b < 48000 / 256 + 8; b++) n60_graph_process(g, in, out, 256);
        CHECK(n60_graph_read_load(g, &ld) == N60_STATUS_OK, "read_load");
        CHECK(ld.windowBlocks > 100, "window blocks %u", ld.windowBlocks);
        CHECK(std::isfinite(ld.meanLoad) && ld.meanLoad >= 0.0f, "mean %f", ld.meanLoad);
        CHECK(ld.peakLoad >= ld.meanLoad, "peak %f < mean %f", ld.peakLoad, ld.meanLoad);
        n60_graph_retire(g);
    }

    if (failures == 0) std::puts("test_fpenv: ok");
    return failures == 0 ? 0 : 1;
}
