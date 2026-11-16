// Golden-hash scenarios shared by test_mb_nband.cpp: the legacy 29/43/44-value blocks rendered through the graph, hashed over
// the output float bits. The hashes were captured on macOS (arm64) from the three-band code before E33 S5b, so a match
// there proves the N-band generalisation leaves every legacy block bit-identical. The bits depend on the platform libm, so
// other platforms check the same scenarios through the 73-value layout instead (scenario(..., true)): a legacy block and
// its 73-value equivalent with a count of 3 must render bit-identically.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
#include "n60/graph.h"

#if defined(__clang__)
#pragma clang fp contract(off)
#endif
namespace golden {
using Vec = std::vector<float>;

inline n60_graph *buildBlock(double rate, const float *params, uint32_t count) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_MULTIBAND;
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
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : nullptr;
}

inline void signal(double rate, size_t n, Vec &l, Vec &r) {
    l.assign(n, 0.0f);
    r.assign(n, 0.0f);
    uint32_t rng = 12345;
    for (size_t i = 0; i < n; ++i) {
        rng = rng * 1664525u + 1013904223u;
        const float nz = ((float)((rng >> 8) & 0xFFFF) / 32768.0f - 1.0f) * 0.05f;
        const double t = (double)i / rate;
        const double env = (i / 3000) % 2 == 0 ? 1.0 : 0.25;
        l[i] = (float)(env * (0.30 * std::sin(6.283185307179586 * 70.0 * t) + 0.25 * std::sin(6.283185307179586 * 900.0 * t) + 0.15 * std::sin(6.283185307179586 * 6500.0 * t)) + nz);
        r[i] = (float)(env * (0.28 * std::sin(6.283185307179586 * 90.0 * t) + 0.22 * std::sin(6.283185307179586 * 1300.0 * t) + 0.12 * std::sin(6.283185307179586 * 8000.0 * t)) - nz);
    }
}

inline uint64_t hashOf(const Vec &a, const Vec &b) {
    uint64_t h = 1469598103934665603ull;
    for (const Vec *v : {&a, &b})
        for (float x : *v) {
            uint32_t u;
            std::memcpy(&u, &x, 4);
            for (int k = 0; k < 4; ++k) { h ^= (u >> (8 * k)) & 0xFF; h *= 1099511628211ull; }
        }
    return h;
}

// Legacy block builder: 44 values. on 0, corners 1-2, slopes 3-4, thr 5, ratio 8, atk 11, rel 14, knee 17, hpf 20, makeup 23,
// auto 26, bypass 29, solo 32, listen 35, detector 38, window 41, lookahead 42, split 43.
struct Legacy {
    float p[44] = {1, 120, 3500, 0, 0, -30, -30, -30, 4, 4, 4, 5, 5, 5, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 0, 0};
};

// One scenario: renders the block, optionally posting a live corner edit and a solo half way, and returns the hash.
inline uint64_t scenario(int which, double rate, bool widen = false) {
    Legacy m;
    uint32_t count = 44;
    switch (which) {
        case 0: count = 29; break;                                                       // v25 block, residual mid
        case 1: m.p[43] = 1; m.p[41] = 20; m.p[38] = m.p[39] = 1; break;                  // tree, RMS detectors
        case 2: m.p[42] = 64; m.p[26] = 1; m.p[27] = 1; m.p[29] = 0; m.p[30] = 1; break;  // residual + lookahead, auto, bypass mid
        case 3: m.p[43] = 1; m.p[42] = 100; m.p[3] = m.p[4] = 1; m.p[33] = 1; break;      // tree + lookahead, LR8, solo mid
        case 4: m.p[35] = 1; m.p[37] = 2; m.p[17] = 0; m.p[20] = 80; break;               // residual, listen sidechain/delta
        default: break;
    }
    float w[73] = {0};
    const float *block = m.p;
    uint32_t blockCount = count;
    if (widen) {
        // The legacy values plus count 3 and in-range settings for the unused bands 4 and 5 (corners 2 and 3 are unused too).
        std::memcpy(w, m.p, sizeof m.p);
        if (count == 29) w[43] = 0;
        w[44] = 3; w[45] = 5000; w[46] = 9000;
        w[51] = w[52] = 1; w[53] = w[54] = 10; w[55] = w[56] = 100;
        block = w;
        blockCount = 73;
    }
    n60_graph *g = buildBlock(rate, block, blockCount);
    if (!g) return 0;
    Vec l, r;
    const size_t n = (size_t)(rate * 0.35);
    signal(rate, n, l, r);
    Vec ol(n), orr(n);
    for (size_t off = 0; off < n; off += 512) {
        const uint32_t c = (uint32_t)std::min<size_t>(512, n - off);
        const float *ip[2] = {l.data() + off, r.data() + off};
        float *op[2] = {ol.data() + off, orr.data() + off};
        n60_graph_process(g, ip, op, c);
        if (off == 512 * 8 && count >= 44) {
            n60_param_record rec[2] = {{5, 1, 150.0f, 0}, {5, 2, 3000.0f, 0}};
            n60_graph_post_params(g, rec, 2);
        }
    }
    n60_graph_retire(g);
    return hashOf(ol, orr);
}
}  // namespace golden
