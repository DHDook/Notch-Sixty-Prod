// E33 S20 part 3 (G77): acoustic reference lab, probe half. A 5.1 graph where the session EQ is a linear-phase FIR on
// every lane but the LFE, the Centre carries its own FIR (session curve times Centre group curve, the way
// StereoEQConfiguration.groupCurves designs it), and the LFE gets the alignment delta the translator adds. The probe
// prints each lane's impulse-response delay and its magnitude (dB) at fixed frequencies; the Python half checks them
// against the RBJ formulas.  Output lines: "LANE <rate> <lane> <delay> <dB at each of 5 frequencies>".
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
constexpr uint32_t kLanes = 6, kCentre = 2, kLfe = 3, kBlock = 512;
const double kFreqs[5] = {150.0, 250.0, 800.0, 3000.0, 8000.0};

extern "C" uint32_t e33_lab_design(double, const double *, uint32_t, float *, uint32_t, uint32_t *);

std::vector<float> design(double rate, const std::vector<double> &triples, uint32_t &latency) {
    std::vector<float> taps(20000);
    const uint32_t n = e33_lab_design(rate, triples.data(), (uint32_t)(triples.size() / 3), taps.data(), (uint32_t)taps.size(), &latency);
    if (n == 0) std::exit(2);
    taps.resize(n);
    return taps;
}

n60_stage_desc fir(uint32_t id, uint64_t mask, uint32_t capacity, const std::vector<float> &taps) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_FIR;
    s.stageId = id;
    s.laneMask = mask;
    s.capacityFrames = capacity;
    s.params = taps.data();
    s.paramCount = (uint32_t)taps.size();
    return s;
}
}  // namespace

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        uint32_t latency = 0, latencyGroup = 0;
        const auto session = design(rate, {250, 3, 1.0}, latency);
        const auto centre = design(rate, {250, 3, 1.0, 800, -6, 1.4}, latencyGroup);
        if (latency != latencyGroup || session.size() != centre.size()) return 3;
        std::vector<float> delta(latency + 1, 0.0f);
        delta[latency] = 1.0f;
        std::vector<n60_stage_desc> st;
        const uint64_t all = (1u << kLanes) - 1u;
        st.push_back(fir(2000, all & ~(1u << kCentre) & ~(1u << kLfe), latency, session));
        st.push_back(fir(3600 + kCentre, 1u << kCentre, latency, centre));
        st.push_back(fir(899, 1u << kLfe, latency, delta));
        n60_graph_desc d;
        std::memset(&d, 0, sizeof d);
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = kBlock;
        d.inputChannels = d.outputChannels = kLanes;
        d.stages = st.data();
        d.stageCount = (uint32_t)st.size();
        n60_graph *g = nullptr;
        if (n60_graph_build(&d, &g) != N60_STATUS_OK) return 4;
        const size_t frames = ((size_t)(session.size() + 2 * kBlock) / kBlock + 1) * kBlock;
        std::vector<float> in(frames, 0.0f);
        in[0] = 1.0f;
        std::vector<std::vector<float>> out(kLanes, std::vector<float>(frames));
        for (size_t off = 0; off < frames; off += kBlock) {
            const float *ip[kLanes];
            float *op[kLanes];
            for (uint32_t l = 0; l < kLanes; ++l) { ip[l] = in.data() + off; op[l] = out[l].data() + off; }
            n60_graph_process(g, ip, op, kBlock);
        }
        n60_graph_retire(g);
        for (uint32_t l = 0; l < kLanes; ++l) {
            size_t delay = 0;
            float best = 0;
            for (size_t i = 0; i < frames; ++i) if (std::fabs(out[l][i]) > best) { best = std::fabs(out[l][i]); delay = i; }
            std::printf("LANE %.0f %u %zu", rate, l, delay);
            for (double f : kFreqs) {
                double re = 0, im = 0;
                for (size_t i = 0; i < frames; ++i) {
                    const double w = 2.0 * M_PI * f * (double)i / rate;
                    re += out[l][i] * std::cos(w);
                    im -= out[l][i] * std::sin(w);
                }
                std::printf(" %.4f", 20.0 * std::log10(std::sqrt(re * re + im * im) + 1e-12));
            }
            std::printf("\n");
        }
    }
    return 0;
}
