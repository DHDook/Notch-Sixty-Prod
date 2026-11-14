/* E8 housekeeping (supersedes the evidence asked for in issue #121): the ACTUAL engine crossover stages, as the graph
 * renders them, summed coherently. Drives N60_STAGE_STEREO_CROSSOVER (mains-only and sub-only monitor modes) and
 * N60_STAGE_BASS_MGMT (LR4 default and an LR8 filter-spec trailer) with sines at 25, 45, 80, 160 and 320 Hz at the eight
 * standard rates, measures the complex response of each branch by projection, and requires |HP + LP| within 0.018 of
 * unity (the limit of the issue). LR4 and LR8 high/low-pass pairs are in phase, so no inversion is needed (an even
 * multiple of 90 degrees at every frequency); the sub polarity is left normal. Reports the worst error per rate. */
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
const double kFreqs[] = {25, 45, 80, 160, 320};
const double kPi = 3.14159265358979323846;
const double kLimit = 0.018;
const uint32_t kBlock = 4096;

n60_graph *build(double rate, uint32_t channels, n60_stage_desc st) {
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = channels;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

/* Runs a unit sine into the input lanes in `feed`, settles, then returns the complex amplitude (relative to the unit
 * input) of output lane `outLane` measured over whole cycles. */
std::complex<double> response(n60_graph *g, uint32_t channels, double rate, double hz, const std::vector<uint32_t> &feed,
                              uint32_t outLane) {
    const double settle = 2.0 + 60.0 / hz;  /* seconds: long enough for an LR8 at 25 Hz to decay far below 1e-6 */
    const uint64_t settleFrames = (uint64_t)(settle * rate);
    const uint64_t measureFrames = (uint64_t)std::llround(40.0 * rate / hz);
    std::vector<std::vector<float>> in(channels, std::vector<float>(kBlock)), out(channels, std::vector<float>(kBlock));
    std::vector<const float *> ip(channels);
    std::vector<float *> op(channels);
    for (uint32_t c = 0; c < channels; c++) { ip[c] = in[c].data(); op[c] = out[c].data(); }
    std::complex<double> acc(0, 0);
    uint64_t pos = 0;
    const uint64_t total = settleFrames + measureFrames;
    while (pos < total) {
        const uint32_t n = (uint32_t)std::min<uint64_t>(kBlock, total - pos);
        for (uint32_t c = 0; c < channels; c++) std::fill(in[c].begin(), in[c].end(), 0.0f);
        for (uint32_t i = 0; i < n; i++) {
            const float s = (float)std::sin(2.0 * kPi * hz * (double)(pos + i) / rate);
            for (uint32_t c : feed) in[c][i] = s;
        }
        n60_graph_process(g, ip.data(), op.data(), n);
        for (uint32_t i = 0; i < n; i++) {
            if (pos + i < settleFrames) continue;
            const double ph = 2.0 * kPi * hz * (double)(pos + i) / rate;
            acc += (double)out[outLane][i] * std::complex<double>(std::sin(ph), -std::cos(ph));
        }
        pos += n;
    }
    /* y = A sin(ph + phi): sum y * (sin - i cos) = N A/2 * e^{i phi} */
    return acc * (2.0 / (double)measureFrames);
}

n60_stage_desc stage(uint32_t kind, uint32_t laneA, uint32_t laneB, uint64_t mask, const float *p, uint32_t pc) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = 1;
    s.laneA = laneA;
    s.laneB = laneB;
    s.laneMask = mask;
    s.params = p;
    s.paramCount = pc;
    return s;
}

int failures = 0;
double worstByRate[8];

void record(int rateIdx, const char *what, double hz, double err) {
    if (err > worstByRate[rateIdx]) worstByRate[rateIdx] = err;
    if (!(err < kLimit)) {
        std::fprintf(stderr, "FAIL %s rate %.0f %.0f Hz: |HP+LP|-1 = %.5f (limit %.3f)\n", what, kRates[rateIdx], hz, err, kLimit);
        failures++;
    }
}

void stereoCrossover(int ri, int lr48) {
    const double rate = kRates[ri];
    for (double hz : kFreqs) {
        std::complex<double> r[2];
        for (int mode = 1; mode <= 2; mode++) {
            const float p[8] = {(float)hz, (float)lr48, (float)mode, 1.0f, 0, 0, 63.0f, 0.9f};
            n60_graph *g = build(rate, 2, stage(N60_STAGE_STEREO_CROSSOVER, 0, 1, 0, p, 8));
            if (!g) { std::fprintf(stderr, "FAIL stereo build rate %.0f\n", rate); failures++; return; }
            r[mode - 1] = response(g, 2, rate, hz, {0, 1}, 0);
            n60_graph_retire(g);
        }
        record(ri, lr48 ? "stereo LR48" : "stereo LR24", hz, std::fabs(std::abs(r[0] + r[1]) - 1.0));
    }
}

void bassMgmt(int ri, int lr48) {
    const double rate = kRates[ri];
    for (double hz : kFreqs) {
        /* mains lanes 0,1; sub lane 2; LFE none; one sub at 0 dB, no EQ. Only lane 0 is fed, so the bass sum is LP(lane 0). */
        float p[14] = {(float)hz, 0, 2, -1, 120, 0, 0, 0, 0, 0 /* extension word */,
                       (float)N60_GRAPH_FILTER_LINKWITZ_RILEY, 8, (float)N60_GRAPH_FILTER_LINKWITZ_RILEY, 8};
        const uint32_t pc = lr48 ? 14 : 9;
        if (lr48) { /* trailer: HP family, order, LP family, order */
            p[10] = (float)N60_GRAPH_FILTER_LINKWITZ_RILEY; p[11] = 8; p[12] = (float)N60_GRAPH_FILTER_LINKWITZ_RILEY; p[13] = 8;
        }
        n60_graph *g = build(rate, 4, stage(N60_STAGE_BASS_MGMT, 0, 0, 0x3, p, pc));
        if (!g) { std::fprintf(stderr, "FAIL bass build rate %.0f lr48 %d\n", rate, lr48); failures++; return; }
        /* One run yields both branches on separate lanes, so measure them from identical processing. */
        const std::complex<double> hp = response(g, 4, rate, hz, {0}, 0);
        n60_graph_retire(g);
        g = build(rate, 4, stage(N60_STAGE_BASS_MGMT, 0, 0, 0x3, p, pc));
        const std::complex<double> lp = response(g, 4, rate, hz, {0}, 2);
        n60_graph_retire(g);
        record(ri, lr48 ? "bass-mgmt LR48" : "bass-mgmt LR24", hz, std::fabs(std::abs(hp + lp) - 1.0));
    }
}
}  // namespace

int main() {
    for (int ri = 0; ri < 8; ri++) {
        for (int lr48 = 0; lr48 <= 1; lr48++) {
            stereoCrossover(ri, lr48);
            bassMgmt(ri, lr48);
        }
        std::printf("rate %.0f: worst coherent-sum error %.5f (limit %.3f)\n", kRates[ri], worstByRate[ri], kLimit);
    }
    if (failures) { std::fprintf(stderr, "%d failures\n", failures); return 1; }
    std::puts("n60core xover high-rate engine check: PASS");
    return 0;
}
