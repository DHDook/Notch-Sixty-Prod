/* E8 S13: N60_STAGE_THERMAL_LIMIT (ABI v49), the long-term power limit of one driver, at the eight standard rates.
 *  - a sine and pink noise above the level settle at the level within 0.5 dB;
 *  - a signal below the level is untouched (bit-identical);
 *  - a burst shorter than the time constant passes (thermal mass);
 *  - a live level edit moves the gain smoothly (no step);
 *  - out-of-range parameters and wrong counts are refused at build. */
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
const double kPi = 3.14159265358979323846;
const uint32_t kBlock = 1024;
int failures = 0;

void check(bool ok, const char *what, double rate, double value = 0.0) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s at %.0f Hz (value %.5f)\n", what, rate, value);
        failures++;
    }
}

n60_graph *build(double rate, float levelDb, float tauMs, uint32_t paramCount = 2, n60_status *status = nullptr) {
    float p[3] = {levelDb, tauMs, 0.0f};
    n60_stage_desc st;
    std::memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_THERMAL_LIMIT;
    st.stageId = 7;
    st.laneA = 0;
    st.params = p;
    st.paramCount = paramCount;
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = kBlock;
    d.inputChannels = d.outputChannels = 1;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    const n60_status s = n60_graph_build(&d, &g);
    if (status) *status = s;
    return s == N60_STATUS_OK ? g : nullptr;
}

/* Runs `in` through the graph and returns the output. */
std::vector<float> run(n60_graph *g, const std::vector<float> &in) {
    std::vector<float> out(in.size());
    std::vector<float> a(kBlock), b(kBlock);
    for (size_t pos = 0; pos < in.size(); pos += kBlock) {
        const uint32_t n = (uint32_t)std::min<size_t>(kBlock, in.size() - pos);
        std::copy(in.begin() + (long)pos, in.begin() + (long)(pos + n), a.begin());
        const float *ip = a.data();
        float *op = b.data();
        n60_graph_process(g, &ip, &op, n);
        std::copy(b.begin(), b.begin() + n, out.begin() + (long)pos);
    }
    return out;
}

double rmsDb(const std::vector<float> &x, size_t from, size_t to) {
    double acc = 0;
    for (size_t i = from; i < to; i++) acc += (double)x[i] * x[i];
    return 10.0 * std::log10(acc / (double)(to - from) + 1e-30);
}

std::vector<float> sine(double rate, double hz, double rmsDbfs, double seconds) {
    const size_t n = (size_t)(seconds * rate);
    const double amp = std::pow(10.0, rmsDbfs / 20.0) * std::sqrt(2.0);
    std::vector<float> x(n);
    for (size_t i = 0; i < n; i++) x[i] = (float)(amp * std::sin(2.0 * kPi * hz * (double)i / rate));
    return x;
}

/* Pink noise (Kellet filter) from a fixed-seed generator, scaled to the requested RMS over the whole run. */
std::vector<float> pink(double rate, double rmsDbfs, double seconds) {
    const size_t n = (size_t)(seconds * rate);
    std::vector<double> x(n);
    uint32_t s = 12345u;
    double b0 = 0, b1 = 0, b2 = 0;
    for (size_t i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        const double w = ((double)(s >> 8) / 8388608.0) - 1.0;
        b0 = 0.99765 * b0 + w * 0.0990460;
        b1 = 0.96300 * b1 + w * 0.2965164;
        b2 = 0.57000 * b2 + w * 1.0526913;
        x[i] = b0 + b1 + b2 + w * 0.1848;
    }
    double acc = 0;
    for (double v : x) acc += v * v;
    const double scale = std::pow(10.0, rmsDbfs / 20.0) / std::sqrt(acc / (double)n);
    std::vector<float> out(n);
    for (size_t i = 0; i < n; i++) out[i] = (float)(x[i] * scale);
    return out;
}
}  // namespace

int main() {
    for (double rate : kRates) {
        /* A sine 10 dB over the level settles at the level. */
        {
            n60_graph *g = build(rate, -20.0f, 200.0f);
            check(g != nullptr, "build", rate);
            if (!g) continue;
            const std::vector<float> in = sine(rate, 1000.0, -10.0, 4.0);
            const std::vector<float> out = run(g, in);
            const double settled = rmsDb(out, (size_t)(3.0 * rate), out.size());
            check(std::fabs(settled + 20.0) < 0.5, "sine settles at the level", rate, settled);
            n60_graph_retire(g);
        }
        /* Pink noise over the level: the mean output level holds the level. */
        {
            n60_graph *g = build(rate, -20.0f, 200.0f);
            const std::vector<float> in = pink(rate, -10.0, 16.0);
            const std::vector<float> out = run(g, in);
            const double settled = rmsDb(out, (size_t)(4.0 * rate), out.size());
            check(std::fabs(settled + 20.0) < 0.5, "pink noise holds the level", rate, settled);
            n60_graph_retire(g);
        }
        /* Below the level the stage is transparent, bit for bit. */
        {
            n60_graph *g = build(rate, -20.0f, 200.0f);
            const std::vector<float> in = sine(rate, 440.0, -26.0, 1.0);
            const std::vector<float> out = run(g, in);
            check(std::memcmp(in.data(), out.data(), in.size() * sizeof(float)) == 0, "transparent below the level", rate);
            n60_graph_retire(g);
        }
        /* A burst much shorter than the time constant passes at its full level. */
        {
            n60_graph *g = build(rate, -20.0f, 5000.0f);
            const std::vector<float> in = sine(rate, 1000.0, -3.0, 0.05);
            const std::vector<float> out = run(g, in);
            double peakIn = 0, peakOut = 0;
            for (size_t i = 0; i < in.size(); i++) {
                peakIn = std::max(peakIn, (double)std::fabs(in[i]));
                peakOut = std::max(peakOut, (double)std::fabs(out[i]));
            }
            check(peakOut > 0.9 * peakIn, "short burst passes", rate, peakOut / peakIn);
            n60_graph_retire(g);
        }
        /* A live level edit ramps the gain: the sample-to-sample change in gain stays small. */
        {
            n60_graph *g = build(rate, -3.0f, 100.0f);
            const std::vector<float> in = sine(rate, 997.0, -12.0, 2.0);
            const std::vector<float> first(in.begin(), in.begin() + (long)(1.0 * rate));
            const std::vector<float> second(in.begin() + (long)(1.0 * rate), in.end());
            run(g, first);
            n60_param_record rec = {7, 0, -40.0f, 0};
            check(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "live level post", rate);
            const std::vector<float> out = run(g, second);
            double maxStep = 0, prev = 1.0;
            bool havePrev = false;
            for (size_t i = 0; i < out.size(); i++) {
                if (std::fabs(second[i]) < 0.1f) { havePrev = false; continue; }  /* only consecutive samples compare */
                const double gain = (double)out[i] / (double)second[i];
                if (havePrev) maxStep = std::max(maxStep, std::fabs(gain - prev));
                prev = gain;
                havePrev = true;
            }
            check(maxStep < 0.01, "level edit is click free", rate, maxStep);
            check(rmsDb(out, out.size() - (size_t)(0.1 * rate), out.size()) < -30.0, "level edit takes effect", rate);
            n60_graph_retire(g);
        }
        /* A non-finite sample does not poison the window: the lane keeps limiting afterwards. */
        {
            n60_graph *g = build(rate, -20.0f, 200.0f);
            std::vector<float> in = sine(rate, 1000.0, -10.0, 4.0);
            in[100] = std::nanf("");
            in[200] = INFINITY;
            const std::vector<float> out = run(g, in);
            const double settled = rmsDb(out, (size_t)(3.0 * rate), out.size());
            check(std::isfinite(settled) && std::fabs(settled + 20.0) < 0.5, "limits after a non-finite sample", rate, settled);
            n60_graph_retire(g);
        }
        /* Refusals. */
        {
            n60_status st;
            check(build(rate, 3.0f, 200.0f, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, "level above 0 refused", rate);
            check(build(rate, -20.0f, 50.0f, 2, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, "short time constant refused", rate);
            check(build(rate, -20.0f, 200.0f, 3, &st) == nullptr && st == N60_STATUS_BAD_ARGUMENT, "paramCount 3 refused", rate);
        }
    }
    if (failures) {
        std::fprintf(stderr, "%d failures\n", failures);
        return 1;
    }
    std::printf("thermal limit: ok at 8 rates\n");
    return 0;
}
