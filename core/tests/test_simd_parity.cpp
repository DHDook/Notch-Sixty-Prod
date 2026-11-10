// E20 S3: the SIMD layer and the stages that use it.
//
//   test_simd_parity dump       prints one line per (rate, lanes, block) with an FNV-1a hash of every output sample and
//                               meter read of a chain that exercises each SIMD stage (GAIN, M/S, PEQ with a live edit and
//                               crossfade, XOVER, PROTECTION with the half-band guard, meters). ci/run_harnesses.sh builds
//                               the core twice (N60_SIMD=1 and N60_SIMD=0) and requires the two dumps to be identical.
//   test_simd_parity check      self-checks that need no second build: the SIMD primitives against plain scalar maths,
//                               and lane independence (a lane's output is the same whatever else shares the graph,
//                               for lane counts 1 to 16, so the odd-count tail path equals the pair path).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "n60/graph.h"
#include "simd/simd.hpp"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

namespace {

struct Rng {
    uint64_t s;
    float next() {  // uniform -1..1
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<float>(static_cast<int32_t>(s >> 33)) / 1073741824.0f - 1.0f;
    }
};

struct Hash {
    uint64_t h = 1469598103934665603ull;
    void add(const void *p, size_t n) {
        const uint8_t *b = static_cast<const uint8_t *>(p);
        for (size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ull; }
    }
    void addf(float v) { add(&v, sizeof v); }
};

struct Chain {
    std::vector<std::vector<float>> keep;
    std::vector<n60_stage_desc> stages;
    n60_graph_desc desc{};
    void add(uint32_t kind, uint32_t id, std::vector<float> p, uint32_t laneA = N60_LANE_ALL, uint32_t laneB = 0) {
        n60_stage_desc s;
        std::memset(&s, 0, sizeof s);
        s.structSize = sizeof s;
        s.kind = kind;
        s.stageId = id;
        s.laneA = laneA;
        s.laneB = laneB;
        keep.push_back(std::move(p));
        s.paramCount = static_cast<uint32_t>(keep.back().size());
        s.params = keep.back().empty() ? nullptr : keep.back().data();
        stages.push_back(s);
    }
    const n60_graph_desc *finish(double rate, uint32_t block, uint32_t lanes) {
        std::memset(&desc, 0, sizeof desc);
        desc.structSize = sizeof desc;
        desc.abiVersion = N60_GRAPH_ABI_VERSION;
        desc.sampleRate = rate;
        desc.maxBlockFrames = block;
        desc.inputChannels = desc.outputChannels = lanes;
        desc.stages = stages.data();
        desc.stageCount = static_cast<uint32_t>(stages.size());
        return &desc;
    }
};

enum { kPeqId = 5, kXoverId = 7, kProtId = 8 };

// withCoupling: M/S on lanes 0 and 1 and the linked limiter (both couple lanes). Without it every lane is independent.
void buildChain(Chain &c, uint32_t lanes, bool withCoupling) {
    c.add(N60_STAGE_SANITISE, 1, {});
    c.add(N60_STAGE_METER_IN, 2, {});
    c.add(N60_STAGE_GAIN, 3, {0.7f});
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_MS_ENCODE, 4, {}, 0, 1);
    c.add(N60_STAGE_PEQ, kPeqId, {0, 60, 9, 2, 2, 6000, -6, 0.7f, 0, 250, -3, 1.2f, 0, 1500, 2, 1.5f, 1, 90, -2, 0.9f});
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_MS_DECODE, 6, {}, 0, 1);
    c.add(N60_STAGE_METER_OUT, 9, {});
    // High-pass Linkwitz-Riley 4 at 60 Hz, low-pass off, trim -1 dB, one EQ section.
    c.add(N60_STAGE_XOVER, kXoverId, {2, 4, 60, 3, 0, 0, -1, 0, 0, 0, 0, 0, 0, 1, 0, 3000, 2, 1.1f});
    if (withCoupling) c.add(N60_STAGE_PROTECTION, kProtId, {1, -1, 1, 50, 5, 1, 2});
    c.add(N60_STAGE_FINAL_METER, 10, {});
}

// Deterministic programme per lane: noise, a tone and bursts that exceed the limiter ceiling.
float sampleAt(Rng &rng, uint32_t lane, uint64_t n, double rate) {
    const double t = static_cast<double>(n) / rate;
    const float tone = 0.4f * static_cast<float>(std::sin(6.283185307179586 * (110.0 + 37.0 * lane) * t));
    const float burst = ((n / 2048) % 5 == 3) ? 1.6f : 0.35f;
    return burst * (tone + 0.25f * rng.next());
}

// Runs the chain for `total` frames in blocks of `block` (a smaller last block), with a live PEQ edit and an XOVER corner
// edit part-way. Output goes to `out[lane]` when non-null; everything is hashed into `h`.
bool run(double rate, uint32_t lanes, uint32_t block, uint32_t total, bool withCoupling, const uint32_t *laneIds,
         std::vector<std::vector<float>> *out, Hash *h) {
    Chain c;
    buildChain(c, lanes, withCoupling);
    n60_graph *g = nullptr;
    const n60_status st = n60_graph_build(c.finish(rate, block, lanes), &g);
    if (st != N60_STATUS_OK) { std::fprintf(stderr, "build status %d\n", static_cast<int>(st)); return false; }
    std::vector<Rng> rng(lanes);
    for (uint32_t l = 0; l < lanes; ++l) rng[l].s = 0x9E3779B97F4A7C15ull * (laneIds[l] + 1);
    std::vector<std::vector<float>> in(lanes, std::vector<float>(block)), ob(lanes, std::vector<float>(block));
    std::vector<const float *> inp(lanes);
    std::vector<float *> outp(lanes);
    for (uint32_t l = 0; l < lanes; ++l) { inp[l] = in[l].data(); outp[l] = ob[l].data(); }
    if (out != nullptr) out->assign(lanes, {});
    uint64_t pos = 0;
    bool edited = false;
    while (pos < total) {
        const uint32_t n = static_cast<uint32_t>(std::min<uint64_t>(block, total - pos));
        if (!edited && pos >= total / 3) {
            const n60_param_record rec[2] = {{kPeqId, 2, -8.0f, 0}, {kXoverId, 2, 120.0f, 0}};
            if (n60_graph_post_params(g, rec, 2) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
            edited = true;
        }
        for (uint32_t l = 0; l < lanes; ++l) {
            for (uint32_t i = 0; i < n; ++i) in[l][i] = sampleAt(rng[l], laneIds[l], pos + i, rate);
        }
        if (n60_graph_process(g, inp.data(), outp.data(), n) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
        for (uint32_t l = 0; l < lanes; ++l) {
            for (uint32_t i = 0; i < n; ++i) {
                if (h != nullptr) h->addf(ob[l][i]);
                if (out != nullptr) (*out)[l].push_back(ob[l][i]);
            }
        }
        pos += n;
    }
    if (h != nullptr) {
        for (uint32_t l = 0; l < lanes; ++l) {
            float peak = 0, rms = 0;
            if (n60_graph_read_meter(g, 2, l, &peak, &rms) == N60_STATUS_OK) { h->addf(peak); h->addf(rms); }
            if (n60_graph_read_meter(g, 10, l, &peak, &rms) == N60_STATUS_OK) { h->addf(peak); h->addf(rms); }
            uint64_t over = 0;
            if (n60_graph_read_over_range(g, 2, l, &over) == N60_STATUS_OK) h->add(&over, sizeof over);
        }
    }
    n60_graph_retire(g);
    return true;
}

const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

int dump() {
    uint32_t ids[16];
    for (uint32_t i = 0; i < 16; ++i) ids[i] = i;
    for (double rate : kRates) {
        for (uint32_t lanes = 1; lanes <= 16; ++lanes) {
            for (uint32_t block : {1u, 7u, 64u, 1024u}) {
                Hash h;
                const uint32_t total = block == 1 ? 3000 : 12000;
                if (!run(rate, lanes, block, total, true, ids, nullptr, &h)) { std::printf("%g %u %u BUILD-FAILED\n", rate, lanes, block); return 1; }
                std::printf("%g %u %u %016llx\n", rate, lanes, block, static_cast<unsigned long long>(h.h));
            }
        }
    }
    return 0;
}

// ---- primitives -----------------------------------------------------------------------------------

void checkPrimitives() {
    using namespace n60::simd;
    // Exactly representable values, so the expected results are exact.
    float a[4] = {1.5f, -2.0f, 0.25f, 4.0f}, b[4] = {2.0f, 0.5f, -8.0f, 0.125f}, o[4];
    store4(o, fma(load4(a), load4(b), splat4(1.0f)));
    CHECK(o[0] == 4.0f && o[1] == 0.0f && o[2] == -1.0f && o[3] == 1.5f, "fma f32 %g %g %g %g", o[0], o[1], o[2], o[3]);
    store4(o, abs(load4(a)));
    CHECK(o[1] == 2.0f, "abs");
    CHECK(hsum(load4(a)) == 3.75f, "hsum %g", hsum(load4(a)));
    CHECK(hmax(load4(a)) == 4.0f, "hmax");
    const float nan = std::nanf("");
    float c[4] = {nan, 3.0f, 0.5f, nan};
    store4(o, maxGt(abs(load4(c)), splat4(1.0f)));  // a > b ? a : b: NaN loses to the second operand
    CHECK(o[0] == 1.0f && o[1] == 3.0f && o[2] == 1.0f && o[3] == 1.0f, "maxGt NaN handling");
    store4(o, selectGt(load4(c), splat4(1.0f), splat4(1.0f), splat4(0.0f)));
    CHECK(o[0] == 0.0f && o[1] == 1.0f && o[2] == 0.0f && o[3] == 0.0f, "selectGt");
    const f64x2 d = fma(pair(1.5, -2.0), pair(2.0, 4.0), splat2(0.5));
    CHECK(lane(d, 0) == 3.5 && lane(d, 1) == -7.5, "fma f64");
    CHECK(hsum(d) == -4.0, "hsum f64");
    // dot16 against the same four-accumulator order written out in plain float fma.
    float x[64], y[64];
    for (int i = 0; i < 64; ++i) { x[i] = 0.01f * static_cast<float>(i - 31); y[i] = 1.0f / static_cast<float>(i + 3); }
    float acc[16] = {};
    for (int i = 0; i < 64; i += 16) {
        for (int j = 0; j < 16; ++j) acc[j] = std::fma(x[i + j], y[i + j], acc[j]);
    }
    float s[4];
    for (int k = 0; k < 4; ++k) s[k] = (acc[k] + acc[4 + k]) + (acc[8 + k] + acc[12 + k]);
    // dot16 sums per-accumulator vectors: (a0 + a1) + (a2 + a3) element-wise, then hsum.
    float ref = (s[0] + s[1]) + (s[2] + s[3]);
    CHECK(dot16(x, y, 64) == ref, "dot16 %.9g vs %.9g", dot16(x, y, 64), ref);
    // scale, any length
    for (uint32_t n : {0u, 1u, 3u, 4u, 5u, 17u}) {
        float buf[17];
        for (int i = 0; i < 17; ++i) buf[i] = static_cast<float>(i + 1);
        scale(buf, n, 0.5f);
        for (uint32_t i = 0; i < 17; ++i) CHECK(buf[i] == (i < n ? 0.5f * static_cast<float>(i + 1) : static_cast<float>(i + 1)), "scale n=%u i=%u", n, i);
    }
}

// Lane independence: chain without coupling stages. Lane k of an N-lane graph equals a 1-lane graph fed lane k's signal.
void checkLaneIndependence() {
    const double rates[] = {44100, 96000, 384000};
    for (double rate : rates) {
        for (uint32_t lanes = 1; lanes <= 16; ++lanes) {
            for (uint32_t block : {1u, 5u, 256u}) {
                uint32_t ids[16];
                for (uint32_t i = 0; i < 16; ++i) ids[i] = i;
                std::vector<std::vector<float>> all;
                const uint32_t total = block == 1 ? 1500 : 6000;
                if (!run(rate, lanes, block, total, false, ids, &all, nullptr)) { CHECK(false, "build %g/%u", rate, lanes); continue; }
                for (uint32_t k = 0; k < lanes; ++k) {
                    std::vector<std::vector<float>> one;
                    const uint32_t only[1] = {k};
                    if (!run(rate, 1, block, total, false, only, &one, nullptr)) { CHECK(false, "build one"); continue; }
                    CHECK(one[0] == all[k], "lane %u of %u differs from a single-lane run (rate %g block %u)", k, lanes, rate, block);
                }
            }
        }
    }
}

// G13: a NaN or Inf burst at the input never reaches the PEQ, crossover or limiter state (SANITISE is first), so the
// output stays finite and recovers whatever the lane count.
void checkNonFiniteBurst() {
    for (uint32_t lanes : {1u, 2u, 5u, 8u}) {
        Chain c;
        buildChain(c, lanes, true);
        n60_graph *g = nullptr;
        if (n60_graph_build(c.finish(48000, 256, lanes), &g) != N60_STATUS_OK) { CHECK(false, "build"); continue; }
        std::vector<std::vector<float>> in(lanes, std::vector<float>(256)), ob(lanes, std::vector<float>(256));
        std::vector<const float *> inp(lanes);
        std::vector<float *> outp(lanes);
        for (uint32_t l = 0; l < lanes; ++l) { inp[l] = in[l].data(); outp[l] = ob[l].data(); }
        bool finite = true;
        float lastPeak = 0;
        for (int b = 0; b < 200; ++b) {
            for (uint32_t l = 0; l < lanes; ++l) {
                for (uint32_t i = 0; i < 256; ++i) {
                    float v = 0.3f * std::sin(0.05f * static_cast<float>(i + 256 * b));
                    if (b >= 10 && b < 14 && i % 7 == l % 7) v = (b % 2) ? std::nanf("") : INFINITY;
                    in[l][i] = v;
                }
            }
            n60_graph_process(g, inp.data(), outp.data(), 256);
            for (uint32_t l = 0; l < lanes; ++l) {
                for (uint32_t i = 0; i < 256; ++i) if (!std::isfinite(ob[l][i])) finite = false;
                lastPeak = std::max(lastPeak, std::fabs(ob[l][255]));
            }
        }
        CHECK(finite, "non-finite output with %u lanes", lanes);
        CHECK(lastPeak > 0.01f, "output did not recover with %u lanes", lanes);
        n60_graph_retire(g);
    }
}

}  // namespace

int main(int argc, char **argv) {
    const std::string mode = argc > 1 ? argv[1] : "check";
    if (mode == "dump") return dump();
    std::printf("simd backend: %s\n", n60::simd::kBackend);
    checkPrimitives();
    checkLaneIndependence();
    checkNonFiniteBurst();
    if (failures != 0) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("simd parity checks passed");
    return 0;
}
