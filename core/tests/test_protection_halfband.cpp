// E20 G19: the PROTECTION stage's 2x half-band path (interp2 odd branch: centre tap plus a 32-tap dot over the odd taps, and
// the decimating 64-tap dot) against the old full 65-tap convolution evaluated in double precision. The two differ by float
// rounding only; this test records the bound (measured 6.2e-8 worst, asserted under 2e-7, at the eight rates). The tap table mirrors kHalfBand in stages_system.cpp (a change there fails here).
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

static const double kTaps[65] = {
    0.0, -8.93785157026247e-06, 0.0, 8.8329163000838e-05, 0.0, -0.000276868159748326, 0.0, 0.000625180796064176,
    0.0, -0.00120674594714632, 0.0, 0.00211986552642504, 0.0, -0.00349032377425427, 0.0, 0.00547729190001286,
    0.0, -0.00828756826069623, 0.0, 0.0122089119142877, 0.0, -0.0176878320018053, 0.0, 0.0255207897268248,
    0.0, -0.037383473403991, 0.0, 0.0576394659334684, 0.0, -0.102387515243912, 0.0, 0.31705153844599,
    0.499995782474098,
    0.317051538445991, 0.0, -0.102387515243912, 0.0, 0.0576394659334684, 0.0, -0.0373834734039911, 0.0,
    0.0255207897268248, 0.0, -0.0176878320018053, 0.0, 0.0122089119142877, 0.0, -0.00828756826069622, 0.0,
    0.00547729190001286, 0.0, -0.00349032377425427, 0.0, 0.00211986552642504, 0.0, -0.00120674594714632, 0.0,
    0.000625180796064177, 0.0, -0.000276868159748327, 0.0, 8.83291630008379e-05, 0.0, -8.93785157026247e-06, 0.0};

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    int failures = 0;
    constexpr int N = 8000;
    for (double rate : rates) {
        std::vector<float> in(N), outv(N);
        unsigned seed = 7;
        for (int i = 0; i < N; i++) {
            seed = seed * 1664525u + 1013904223u;
            in[i] = 0.2f * static_cast<float>(std::sin(2.0 * M_PI * 1000.0 * i / rate)) + 0.1f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        }
        const float p[7] = {1.0f, -6.0f, 1.0f, 50.0f, 10.0f, 0.0f, 2.0f};
        n60_stage_desc st;
        std::memset(&st, 0, sizeof st);
        st.structSize = sizeof st;
        st.kind = N60_STAGE_PROTECTION;
        st.stageId = 1;
        st.laneA = N60_LANE_ALL;
        st.params = p;
        st.paramCount = 7;
        n60_graph_desc d{};
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = N;
        d.inputChannels = d.outputChannels = 2;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *g = nullptr;
        if (n60_graph_build(&d, &g) != N60_STATUS_OK) { std::fprintf(stderr, "build failed\n"); return 1; }
        std::vector<float> r(N, 0.0f), orr(N);
        const float *ip[2] = {in.data(), r.data()};
        float *op[2] = {outv.data(), orr.data()};
        n60_graph_process(g, ip, op, N);
        const uint32_t lat = n60_graph_latency_frames(g);
        n60_graph_retire(g);

        // Reference: zero-stuff x2 (gain 2), 65-tap convolution, 65-tap convolution, keep every second sample.
        const int M = 2 * N;
        std::vector<double> up(M, 0.0), a(M, 0.0), b(M, 0.0);
        for (int i = 0; i < N; i++) up[2 * i] = 2.0 * in[i];
        for (int n = 0; n < M; n++) for (int k = 0; k < 65; k++) if (n - k >= 0) a[n] += kTaps[k] * up[n - k];
        for (int n = 0; n < M; n++) for (int k = 0; k < 65; k++) if (n - k >= 0) b[n] += kTaps[k] * a[n - k];
        // The stage's two-stage delay: 32 + 32 high-rate samples = 32 input samples; lat is the reported latency.
        double worst = 0;
        // The output also carries the limiter look-ahead, so search the input-sample lag (high-rate index 2 * (i - lag)).
        double best = 1e9;
        int bestShift = 0;
        for (int lag = 0; lag <= static_cast<int>(lat) + 40; lag++) {
            double w = 0;
            for (int i = static_cast<int>(lat) + 200; i < N; i++) {
                const int j = 2 * (i - lag);
                const double refv = (j >= 0 && j < M) ? b[j] : 0.0;
                w = std::fmax(w, std::fabs(refv - outv[i]));
            }
            if (w < best) { best = w; bestShift = lag; }
        }
        worst = best;
        std::printf("rate %.0f: latency %u, shift %d, worst deviation vs 65-tap double form %.3g\n", rate, lat, bestShift, worst);
        if (!(worst < 2.0e-7)) { std::fprintf(stderr, "FAIL rounding bound at %.0f\n", rate); failures++; }
    }
    if (failures) return 1;
    std::puts("test_protection_halfband: ok");
    return 0;
}
