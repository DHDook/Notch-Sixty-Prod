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
    void add(uint32_t kind, uint32_t id, std::vector<float> p, uint32_t laneA = N60_LANE_ALL, uint32_t laneB = 0, uint64_t mask = 0) {
        n60_stage_desc s;
        std::memset(&s, 0, sizeof s);
        s.structSize = sizeof s;
        s.kind = kind;
        s.stageId = id;
        s.laneA = laneA;
        s.laneB = laneB;
        s.laneMask = mask;
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

enum { kPeqId = 5, kXoverId = 7, kProtId = 8, kBassId = 12, kLoudId = 13, kMbId = 14, kCompId = 15, kExpId = 16, kDynId = 17 };

// E20 S10 (G14): the stereo LOUDNESS stage (match, per-band contour from the integrated level, leveler; rank 97) and BASS_MGMT
// (split on every lane but the sub and LFE, an EQ section on the sub, an LFE lane from four lanes up; rank 130), added in rank
// order, so the dumps cover both cascades.
void addLoudness(Chain &c, uint32_t lanes) {
    if (lanes >= 2) c.add(N60_STAGE_LOUDNESS, kLoudId, {1, 0, -20, 10, 0.5f, 2, 1, 0.6f, 1, 1, 80, 12, 3, 1,
                                                       1, 0, 300, 3500, 6, 3, 9, 200, 80, 600, -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f}, 0, 1);
}
void addBass(Chain &c, uint32_t lanes) {
    if (lanes < 3) return;
    const uint32_t split = lanes >= 4 ? lanes - 2 : lanes - 1;
    const float lfeLane = lanes >= 4 ? static_cast<float>(lanes - 1) : -1.0f;
    c.add(N60_STAGE_BASS_MGMT, kBassId, {80, 0, static_cast<float>(split), lfeLane, 120, -2, 3, 0, 1, 0, 50, 4, 1.0f}, 0, 0,
          (uint64_t(1) << split) - 1);
}

// E20 S10 part 4 (G14): the multiband pair stage (band-pass tree on odd lane counts, residual mid on even), the extended
// compressor (RMS detector, side-chain high-pass, lookahead, mix, link; unlinked on even lane counts) and the extended expander
// with its side-chain high-pass, in rank order (multiband 9.9, compressor 10, expander 11). Rank 17 CORE_DYNAMICS (legacy 10
// values, sidechain high-pass) and CROSSFEED are added by buildChain.
void addDynamics(Chain &c, uint32_t lanes) {
    const float split = (lanes & 1) != 0 ? 1.0f : 0.0f;
    if (lanes >= 2) {
        c.add(N60_STAGE_MULTIBAND, kMbId,
              {1, 250, 3000, 0, 0, -26, -24, -22, 3, 2.5f, 2, 4, 6, 8, 60, 90, 120, 3, 4, 2, 50, 0, 0, 1, 0, -1, 0, 1, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 30, 0, split}, 0, 1);
    }
    c.add(N60_STAGE_COMPRESSOR, kCompId, {-22, 3, 5, 3, 70, 0, lanes >= 4 && lanes < 8 ? 1.0f : 0.0f, 1, 120, static_cast<float>(lanes & 2) * 0.5f, 85, 60, 1, 20, 37, 0});
    c.add(N60_STAGE_EXPANDER, kExpId, {-50, 2, -20, 3, 60, 1, 20, 4, 1, 20, 90, 70, 0});
}

// E20 S10 part 5 (G14): CLEANUP (DC, 48 dB/oct infrasonic, three mains notches, detector; rank 3.7), the dynamic EQ (a peaking
// band with a boost side and an RMS detector, then a tilt band; rank 7), IMAGE (wide mono off, widener on) and DEESS (de-harsh and
// de-esser; ranks 9.6 and 9.8), in the chain on lane pairs so the scalar and vector builds are compared through their chunked paths.
void addPrograms(Chain &c, uint32_t lanes, int where) {
    if (where == 0) {  // after GAIN (rank 3.7)
        if (lanes >= 2) {
            std::vector<float> p = {1, 1, 20, 1, 1, 50, 3, 20, 1, 50};
            for (int i = 0; i < 16; ++i) p.push_back(i < 3 ? -20.0f : 0.0f);
            c.add(N60_STAGE_CLEANUP, 31, p, 0, 1);
        }
    } else if (where == 1) {  // after PEQ (rank 7)
        c.add(N60_STAGE_DYN_EQ, 32, {0, 0, 500, 1.2f, 1, -40, 2, -12, 10, 100, 2, -50, 2, 6, 1, 20,
                                     5, 2000, 0.8f, 0, -30, 3, -12, 5, 80, 0, -50, 2, 6, 0, 20});
    } else if (lanes >= 2) {
        if (where == 2) c.add(N60_STAGE_IMAGE, 33, {0, 1, 0, 200, 4000, 0.5f, 1.5f, 1.8f}, 0, 1);
        else c.add(N60_STAGE_DEESS, 34, {1, 5000, -4, 1, 6000, -40, 4, -12, 2, 5, 80, 0}, 0, 1);
    }
}

// withCoupling: M/S on lanes 0 and 1 and the linked limiter (both couple lanes). Without it every lane is independent.
void buildChain(Chain &c, uint32_t lanes, bool withCoupling) {
    c.add(N60_STAGE_SANITISE, 1, {});
    c.add(N60_STAGE_METER_IN, 2, {});
    c.add(N60_STAGE_GAIN, 3, {0.7f});
    if (withCoupling) addPrograms(c, lanes, 0);
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_MS_ENCODE, 4, {}, 0, 1);
    c.add(N60_STAGE_PEQ, kPeqId, {0, 60, 9, 2, 2, 6000, -6, 0.7f, 0, 250, -3, 1.2f, 0, 1500, 2, 1.5f, 1, 90, -2, 0.9f});
    if (withCoupling) addPrograms(c, lanes, 1);
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_MS_DECODE, 6, {}, 0, 1);
    if (withCoupling) addPrograms(c, lanes, 2);
    if (withCoupling) addLoudness(c, lanes);
    if (withCoupling) addPrograms(c, lanes, 3);
    if (withCoupling) addDynamics(c, lanes);
    c.add(N60_STAGE_METER_OUT, 9, {});
    if (withCoupling) addBass(c, lanes);
    if (withCoupling) c.add(N60_STAGE_CORE_DYNAMICS, kDynId, {-18, 3, 4, 2, 90, 1, 0, 1, 80, 0});  // legacy 10 values, side-chain high-pass
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_SYMMETRY, 11, {0.35f}, 0, 1);  // ramps in on the first block (G14)
    if (withCoupling && lanes >= 2) c.add(N60_STAGE_CROSSFEED, 18, {0.3f}, 0, 1);       // E20 S10 part 4: the blend ramps in too
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
    bool edited = false, edited2 = false;
    while (pos < total) {
        const uint32_t n = static_cast<uint32_t>(std::min<uint64_t>(block, total - pos));
        if (!edited && pos >= total / 3) {
            const n60_param_record rec[2] = {{kPeqId, 2, -8.0f, 0}, {kXoverId, 2, 120.0f, 0}};
            if (n60_graph_post_params(g, rec, 2) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
            edited = true;
        }
        if (!edited2 && pos >= 2 * total / 3) {  // crossover and LFE corner moves (crossfades), then the loudness parts switch off
            std::vector<n60_param_record> rec;
            if (withCoupling && lanes >= 3) { rec.push_back({kBassId, 0, 110.0f, 0}); rec.push_back({kBassId, 4, 90.0f, 0}); }
            if (withCoupling && lanes >= 2) { rec.push_back({kLoudId, 8, 0.0f, 0}); rec.push_back({kLoudId, 14, 0.0f, 0}); }
            if (!rec.empty() && n60_graph_post_params(g, rec.data(), static_cast<uint32_t>(rec.size())) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
            edited2 = true;
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
// G14: mix and ramp primitives against plain scalar maths (fma contraction as in the stages), every length 0..37.
void checkMixAndRamp() {
    using namespace n60::simd;
    float x[40], g[40], dst[40], ref[40];
    for (int i = 0; i < 40; ++i) { x[i] = 0.013f * static_cast<float>(i - 17); g[i] = 0.5f + 0.021f * static_cast<float>(i); }
    for (uint32_t n = 0; n <= 37; ++n) {
        for (int i = 0; i < 40; ++i) dst[i] = ref[i] = 0.1f * static_cast<float>(i);
        mulConst(dst, x, 0.7f, n);
        for (uint32_t i = 0; i < n; ++i) ref[i] = 0.7f * x[i];
        CHECK(std::memcmp(dst, ref, sizeof dst) == 0, "mulConst n=%u", n);
        macConst(dst, x, 0.3f, n);
        for (uint32_t i = 0; i < n; ++i) ref[i] = std::fma(0.3f, x[i], ref[i]);
        CHECK(std::memcmp(dst, ref, sizeof dst) == 0, "macConst n=%u", n);
        macVec(dst, x, g, n);
        for (uint32_t i = 0; i < n; ++i) ref[i] = std::fma(g[i], x[i], ref[i]);
        CHECK(std::memcmp(dst, ref, sizeof dst) == 0, "macVec n=%u", n);
        mulVec(dst, dst, g, n);  // in place
        for (uint32_t i = 0; i < n; ++i) ref[i] = g[i] * ref[i];
        CHECK(std::memcmp(dst, ref, sizeof dst) == 0, "mulVec n=%u", n);
    }
    // rampFill against the scalar rampNext recurrence, split across calls of any size.
    for (uint32_t total : {1u, 5u, 64u, 200u}) {
        for (uint32_t chunk : {1u, 3u, 4u, 7u, 16u, 37u}) {
            float cur = 0.25f, step = (1.5f - cur) / static_cast<float>(total), target = 1.5f;
            uint32_t rem = total;
            float rc = cur, rs = step;
            uint32_t rr = rem;
            std::vector<float> got, want;
            for (uint32_t done = 0; done < 3 * total + 5;) {
                const uint32_t n = std::min(chunk, 3 * total + 5 - done);
                float buf[40];
                rampFill(buf, cur, target, step, rem, n);
                got.insert(got.end(), buf, buf + n);
                done += n;
            }
            for (uint32_t i = 0; i < 3 * total + 5; ++i) {
                if (rr != 0) { --rr; rc = std::fma(-rs, static_cast<float>(rr), target); }
                want.push_back(rc);
            }
            CHECK(got == want, "rampFill total=%u chunk=%u", total, chunk);
            CHECK(got[total - 1] == target && rem == 0, "ramp ends exactly on target total=%u", total);
        }
    }
}

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

// G14: BASS_MGMT and LOUDNESS run a chunk (256 frames) at a time, so the output must not depend on the block size: the same
// programme, with the same edits at sample positions every block size divides, hashes identically for blocks of 1 to 1,000
// frames (which cross the chunk size in whole and part chunks), at the eight rates and with 3, 4 and 7 lanes.
uint64_t chunkHash(double rate, uint32_t lanes, uint32_t block, bool simpleStart = false) {
    const n60_param_record simpleRec = {kLoudId, 8, 0.0f, 0};
    Chain c;
    c.add(N60_STAGE_SANITISE, 1, {});
    addLoudness(c, lanes);
    addBass(c, lanes);
    n60_graph *g = nullptr;
    if (n60_graph_build(c.finish(rate, 1024, lanes), &g) != N60_STATUS_OK) return 0;
    std::vector<Rng> rng(lanes);
    for (uint32_t l = 0; l < lanes; ++l) rng[l].s = 0x9E3779B97F4A7C15ull * (l + 1);
    std::vector<std::vector<float>> in(lanes, std::vector<float>(block)), ob(lanes, std::vector<float>(block));
    std::vector<const float *> inp(lanes);
    std::vector<float *> outp(lanes);
    for (uint32_t l = 0; l < lanes; ++l) { inp[l] = in[l].data(); outp[l] = ob[l].data(); }
    std::vector<Hash> hl(lanes);  // per lane, so the order does not depend on the block size
    const uint32_t total = 9000;
    for (uint32_t pos = 0; pos < total; pos += block) {
        if (pos == 0 && simpleStart) n60_graph_post_params(g, &simpleRec, 1);
        if (pos == 3000) {
            std::vector<n60_param_record> rec = {{kLoudId, 8, 0.0f, 0}};
            if (lanes >= 3) { rec.push_back({kBassId, 0, 110.0f, 0}); rec.push_back({kBassId, 4, 90.0f, 0}); }
            n60_graph_post_params(g, rec.data(), static_cast<uint32_t>(rec.size()));
        }
        if (pos == 6000) {
            std::vector<n60_param_record> rec = {{kLoudId, 14, 0.0f, 0}, {kLoudId, 6, 0.0f, 0}, {kLoudId, 0, 0.0f, 0}};
            n60_graph_post_params(g, rec.data(), static_cast<uint32_t>(rec.size()));
        }
        for (uint32_t l = 0; l < lanes; ++l) for (uint32_t i = 0; i < block; ++i) in[l][i] = sampleAt(rng[l], l, pos + i, rate);
        if (n60_graph_process(g, inp.data(), outp.data(), block) != N60_STATUS_OK) { n60_graph_retire(g); return 0; }
        for (uint32_t l = 0; l < lanes; ++l) for (uint32_t i = 0; i < block; ++i) hl[l].addf(ob[l][i]);
    }
    n60_graph_retire(g);
    Hash all;
    for (const Hash &h : hl) all.add(&h.h, sizeof h.h);
    return all.h;
}

void checkChunkInvariance() {
    for (double rate : kRates) {
        for (uint32_t lanes : {2u, 3u, 4u, 7u}) {
            for (bool simple : {false, true}) {
            const uint64_t ref = chunkHash(rate, lanes, 1000, simple);
            CHECK(ref != 0, "chunk build %g/%u", rate, lanes);
            for (uint32_t block : {1u, 8u, 50u, 250u, 500u}) {
                CHECK(chunkHash(rate, lanes, block, simple) == ref, "BASS_MGMT/LOUDNESS output depends on block size %u (rate %g, %u lanes)", block, rate, lanes);
            }
            }
        }
    }
}


// ---- G37: committed scalar references for the chunked BASS_MGMT and LOUDNESS stages (E20 S10 part 4) ---------------------------
// An independent per-sample double-precision model written from the RBJ Audio EQ Cookbook, run against the real stage at all
// eight rates, over odd block sizes. The references use no stage code: only the documented parameters and the stages'
// documented arithmetic (state in double, float rounding at the points the stage rounds).
struct Coef { double b0, b1, b2, a1, a2; };
struct St { double z1 = 0, z2 = 0; };
enum class K { LP, HP, LowShelf, HighShelf };
Coef rbj(K k, double rate, double f, double gainDb, double q) {
    const double w = 2.0 * 3.14159265358979323846 * f / rate, c = std::cos(w), sn = std::sin(w), al = sn / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    const double A = std::pow(10.0, gainDb / 40.0), be = 2.0 * std::sqrt(A) * al;
    switch (k) {
        case K::LP: b0 = (1 - c) / 2; b1 = 1 - c; b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case K::HP: b0 = (1 + c) / 2; b1 = -(1 + c); b2 = b0; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al; break;
        case K::LowShelf:
            b0 = A * ((A + 1) - (A - 1) * c + be); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - be);
            a0 = (A + 1) + (A - 1) * c + be; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - be; break;
        default:
            b0 = A * ((A + 1) + (A - 1) * c + be); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - be);
            a0 = (A + 1) - (A - 1) * c + be; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - be; break;
    }
    return Coef{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}
double tdf2(const Coef &c, St &s, double x) {
    const double y = c.b0 * x + s.z1;
    s.z1 = c.b1 * x - c.a1 * y + s.z2;
    s.z2 = c.b2 * x - c.a2 * y;
    return y;
}
constexpr double kButter = 0.7071067811865476;

// Drives one stage chain with a programme of `lanes` lanes in blocks of `block` frames. `edits` are posted at the block
// boundary at or after the given frame. Returns every lane's output; `inputs` receives the programme.
struct Edit { uint32_t frame; n60_param_record rec; };
bool drive(double rate, uint32_t lanes, uint32_t block, uint32_t total, void (*build)(Chain &), const std::vector<Edit> &edits,
           std::vector<std::vector<float>> &in, std::vector<std::vector<float>> &out) {
    Chain c;
    build(c);
    n60_graph *g = nullptr;
    if (n60_graph_build(c.finish(rate, block, lanes), &g) != N60_STATUS_OK) return false;
    std::vector<Rng> rng(lanes);
    in.assign(lanes, {});
    out.assign(lanes, {});
    for (uint32_t l = 0; l < lanes; ++l) rng[l].s = 0x51ED270B0B0B0B0Bull * (l + 7);
    std::vector<std::vector<float>> ib(lanes, std::vector<float>(block)), ob(lanes, std::vector<float>(block));
    std::vector<const float *> ip(lanes);
    std::vector<float *> op(lanes);
    for (uint32_t l = 0; l < lanes; ++l) { ip[l] = ib[l].data(); op[l] = ob[l].data(); }
    uint32_t pos = 0;
    std::vector<bool> done(edits.size(), false);
    while (pos < total) {
        const uint32_t n = std::min(block, total - pos);
        for (size_t e = 0; e < edits.size(); ++e) {
            if (!done[e] && pos >= edits[e].frame) { done[e] = true; if (n60_graph_post_params(g, &edits[e].rec, 1) != N60_STATUS_OK) { n60_graph_retire(g); return false; } }
        }
        for (uint32_t l = 0; l < lanes; ++l) {
            for (uint32_t i = 0; i < n; ++i) ib[l][i] = sampleAt(rng[l], l, pos + i, rate);
            in[l].insert(in[l].end(), ib[l].begin(), ib[l].begin() + n);
        }
        if (n60_graph_process(g, ip.data(), op.data(), n) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
        for (uint32_t l = 0; l < lanes; ++l) out[l].insert(out[l].end(), ob[l].begin(), ob[l].begin() + n);
        pos += n;
    }
    n60_graph_retire(g);
    return true;
}

double maxDiff(const std::vector<float> &a, const std::vector<float> &b, size_t from = 0) {
    double m = 0;
    for (size_t i = from; i < a.size(); ++i) m = std::max(m, std::fabs(double(a[i]) - double(b[i])));
    return m;
}

// BASS_MGMT, mains 0 and 1, one sub on lane 2, redirect 0 dB, one sub, no sub EQ. lfeLane -1 or 2 (the LFE lane is the sub lane).
// Mains: LR4 high-pass as two identical Butterworth RBJ sections; bass sum: both low-passes plus the LFE low-pass (two
// Butterworth sections at 120 Hz), written to the sub lane after the LFE sample is read.
template <int kLfe>
void buildBass(Chain &c) { c.add(N60_STAGE_BASS_MGMT, kBassId, {80, 0, 2, static_cast<float>(kLfe), 120, 0, 0, 0, 0}, 0, 0, 3); }

template <int kLfe>
void checkBassReference() {
    for (double rate : kRates) {
        for (uint32_t block : {1u, 37u, 256u, 700u}) {
            const uint32_t total = block == 1 ? 1500 : 6000;
            std::vector<std::vector<float>> in, out;
            if (!drive(rate, 4, block, total, buildBass<kLfe>, {}, in, out)) { CHECK(false, "bass build"); continue; }
            const Coef hp = rbj(K::HP, rate, 80, 0, kButter), lp = rbj(K::LP, rate, 80, 0, kButter), lf = rbj(K::LP, rate, 120, 0, kButter);
            St h[2][2], l[2][2], f[2];
            std::vector<float> sub(total);
            std::vector<float> m[2] = {std::vector<float>(total), std::vector<float>(total)};
            for (uint32_t i = 0; i < total; ++i) {
                double acc = 0;
                for (int k = 0; k < 2; ++k) {
                    const double x = in[k][i];
                    m[k][i] = static_cast<float>(tdf2(hp, h[k][1], tdf2(hp, h[k][0], x)));
                    acc += tdf2(lp, l[k][1], tdf2(lp, l[k][0], x));
                }
                if (kLfe >= 0) acc += tdf2(lf, f[1], tdf2(lf, f[0], static_cast<double>(in[kLfe][i])));
                sub[i] = static_cast<float>(acc);
            }
            const double e0 = maxDiff(out[0], m[0]), e1 = maxDiff(out[1], m[1]), e2 = maxDiff(out[2], sub);
            CHECK(e0 < 2e-6 && e1 < 2e-6, "BASS_MGMT mains differ from the scalar reference by %g / %g (rate %g block %u lfe %d)", e0, e1, rate, block, kLfe);
            CHECK(e2 < 2e-6, "BASS_MGMT sub differs from the scalar reference by %g (rate %g block %u lfe %d)", e2, rate, block, kLfe);
            CHECK(out[3] == in[3], "BASS_MGMT altered a lane outside its mask (rate %g)", rate);
        }
    }
}

// LOUDNESS simple contour only: low shelf at 120 Hz then high shelf at 8 kHz (RBJ, Q 1/sqrt 2, +6 and +3 dB times strength),
// each section's output rounded to float, wet blended by a one-pole mix (5 ms, float) that ramps from 0 to 1. Phase 2 switches the
// contour off: the mix decays to the park threshold (1e-5) and the stage is then exactly transparent. Phase 3 switches it back
// on: state is cleared and the mix restarts from 0.
constexpr uint32_t kLdContourOn = 6;
void buildContour(Chain &c) {
    c.add(N60_STAGE_LOUDNESS, kLoudId, {0, 0, -20, 10, 0.5f, 2, 1, 0.6f, 0, 1, 80, 12, 3, 0.01f, 0, 1, 300, 3500, 6, 3, 9, 200, 80, 600,
                                        -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f}, 0, 1);
}
void checkContourReference() {
    for (double rate : kRates) {
        for (uint32_t block : {1u, 50u, 256u}) {
            const uint32_t total = 3 * (block == 1 ? 1000u : 4096u);
            const uint32_t off = (total / 3 / block) * block, on = (2 * total / 3 / block) * block;
            std::vector<std::vector<float>> in, out;
            const std::vector<Edit> edits = {{off, {kLoudId, kLdContourOn, 0.0f, 0}}, {on, {kLoudId, kLdContourOn, 1.0f, 0}}};
            if (!drive(rate, 2, block, total, buildContour, edits, in, out)) { CHECK(false, "contour build"); continue; }
            const double bass = double(6.0f) * double(0.6f), treble = double(3.0f) * double(0.6f);
            const Coef ls = rbj(K::LowShelf, rate, 120, bass, kButter), hs = rbj(K::HighShelf, rate, 8000, treble, kButter);
            const float coef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
            St a[2], b[2];
            float mix = 0.0f;
            bool parked = false, enabled = true;
            std::vector<float> ref[2] = {std::vector<float>(total), std::vector<float>(total)};
            for (uint32_t i = 0; i < total; ++i) {
                if (i == off) enabled = false;
                if (i == on) { enabled = true; }
                for (int k = 0; k < 2; ++k) ref[k][i] = in[k][i];
                if (!enabled && parked) continue;
                if (enabled && parked) { a[0] = a[1] = b[0] = b[1] = St{}; mix = 0.0f; parked = false; }
                float wet[2];
                for (int k = 0; k < 2; ++k) {
                    const float w1 = static_cast<float>(tdf2(ls, a[k], in[k][i]));
                    wet[k] = static_cast<float>(tdf2(hs, b[k], w1));
                }
                const float target = enabled ? 1.0f : 0.0f;
                mix = target + coef * (mix - target);
                if (!enabled && std::fabs(mix) <= 1.0e-5f) { a[0] = a[1] = b[0] = b[1] = St{}; mix = 0.0f; parked = true; continue; }
                for (int k = 0; k < 2; ++k) ref[k][i] = in[k][i] + (wet[k] - in[k][i]) * mix;
            }
            for (int k = 0; k < 2; ++k) {
                const double e = maxDiff(out[k], ref[k]);
                CHECK(e < 1e-5, "LOUDNESS simple contour differs from the scalar reference by %g (lane %d rate %g block %u)", e, k, rate, block);
            }
            // The fade-out ends exactly transparent: from the park point to the re-enable the output is the input.
            const uint32_t settle = off + static_cast<uint32_t>(rate * 0.005 * 14.0) + block;
            if (settle < on) {
                std::vector<float> tailOut(out[0].begin() + settle, out[0].begin() + on), tailIn(in[0].begin() + settle, in[0].begin() + on);
                CHECK(tailOut == tailIn, "LOUDNESS not transparent after the contour fade-out (rate %g block %u)", rate, block);
            }
        }
    }
}

// Leveler park and unpark: with the leveler off the stage is bit-transparent; switching it on after a parked stretch matches a
// run that started from reset (unpark clears every part of its state), so a park/unpark cycle leaves nothing behind.
constexpr uint32_t kLdLevOn = 14;
void buildLeveler(Chain &c) {
    c.add(N60_STAGE_LOUDNESS, kLoudId, {0, 0, -20, 10, 0.5f, 2, 0, 0.6f, 0, 1, 80, 12, 3, 1, 1, 0, 300, 3500, 6, 3, 9, 200, 80, 600,
                                        -60, 3, 7, 12, 800, 0.1f, 0.5f, 0.3f}, 0, 1);
}
// E20 S10 part 5 (G42): a deterministic two-tone programme that engages the leveler's boost: 80 Hz at -26 dBFS (outside the
// 300 to 3500 Hz dialogue band) and 1 kHz at -50 dBFS (inside it), so the programme sits 24 dB above the band, far over the
// 6 dB target gap, and the boost runs to its 9 dB maximum (boost ratio 3 gives 12 dB, capped). Phase is a function of the
// absolute frame index plus `offset`, so a fresh run can be fed the third segment of the long one.
float toneAt(uint32_t lane, uint64_t n, double rate) {
    const double t = static_cast<double>(n) / rate, sign = lane == 0 ? 1.0 : -0.5;
    return static_cast<float>(sign * (0.0501187 * std::sin(2.0 * 3.14159265358979323846 * 80.0 * t) +
                                      0.0031623 * std::sin(2.0 * 3.14159265358979323846 * 1000.0 * t)));
}
bool driveTone(double rate, uint32_t block, uint32_t total, uint64_t offset, const std::vector<Edit> &edits,
               std::vector<std::vector<float>> &in, std::vector<std::vector<float>> &out) {
    Chain c;
    buildLeveler(c);
    n60_graph *g = nullptr;
    if (n60_graph_build(c.finish(rate, block, 2), &g) != N60_STATUS_OK) return false;
    in.assign(2, {});
    out.assign(2, {});
    std::vector<std::vector<float>> ib(2, std::vector<float>(block)), ob(2, std::vector<float>(block));
    const float *ip[2] = {ib[0].data(), ib[1].data()};
    float *op[2] = {ob[0].data(), ob[1].data()};
    std::vector<bool> done(edits.size(), false);
    for (uint32_t pos = 0; pos < total; pos += block) {
        for (size_t e = 0; e < edits.size(); ++e)
            if (!done[e] && pos >= edits[e].frame) { done[e] = true; n60_graph_post_params(g, &edits[e].rec, 1); }
        for (uint32_t l = 0; l < 2; ++l) {
            for (uint32_t i = 0; i < block; ++i) ib[l][i] = toneAt(l, offset + pos + i, rate);
            in[l].insert(in[l].end(), ib[l].begin(), ib[l].end());
        }
        if (n60_graph_process(g, ip, op, block) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
        for (uint32_t l = 0; l < 2; ++l) out[l].insert(out[l].end(), ob[l].begin(), ob[l].end());
    }
    n60_graph_retire(g);
    return true;
}
// Phase 1 (leveler on): the boost engages (the output differs from the input by well over a rounding error, and by the amount
// a 9 dB boost of the 1 kHz tone gives). Phase 2 (off): the stage parks and is bit-transparent. Phase 3 (on again): the first
// segment's state is gone, so the third segment equals, to the last bit, a fresh graph run from reset on the same input.
void checkLevelerPark() {
    for (double rate : kRates) {
        const uint32_t block = 128, seg = (static_cast<uint32_t>(rate * 0.4) / block) * block, total = 3 * seg;
        std::vector<std::vector<float>> inA, outA, inB, outB;
        const std::vector<Edit> edits = {{seg, {kLoudId, kLdLevOn, 0.0f, 0}}, {2 * seg, {kLoudId, kLdLevOn, 1.0f, 0}}};
        if (!driveTone(rate, block, total, 0, edits, inA, outA)) { CHECK(false, "leveler build"); continue; }
        double boosted = 0;
        for (uint32_t i = seg * 3 / 4; i < seg; ++i) boosted = std::max(boosted, std::fabs(double(outA[0][i]) - double(inA[0][i])));
        CHECK(boosted > 1.0e-3 && boosted < 3.0e-2, "leveler boost not engaged or out of range: peak change %g (rate %g)", boosted, rate);
        std::vector<float> midOut(outA[0].begin() + seg + 3 * seg / 4, outA[0].begin() + 2 * seg), midIn(inA[0].begin() + seg + 3 * seg / 4, inA[0].begin() + 2 * seg);
        CHECK(midOut == midIn, "leveler stage not transparent while parked (rate %g)", rate);
        for (int k = 0; k < 2; ++k) for (float v : outA[k]) CHECK(std::isfinite(v), "leveler output not finite (rate %g)", rate);
        if (!driveTone(rate, block, seg, 2 * uint64_t(seg), {}, inB, outB)) { CHECK(false, "leveler build B"); continue; }
        for (int k = 0; k < 2; ++k) {
            const std::vector<float> third(outA[k].begin() + 2 * seg, outA[k].end());
            const double d = maxDiff(third, outB[k]);
            CHECK(d == 0.0, "leveler after park/unpark differs from a fresh run by %g (lane %d rate %g)", d, k, rate);
        }
    }
}

// Non-finite input straight into the compressor and expander side-chain high-pass (no SANITISE stage): the output stays finite
// of NaN latching and recovers, as the per-sample biquad() reset did before the lane-pair form (E20 S10 part 4).
void buildDynOnly(Chain &c) {
    c.add(N60_STAGE_COMPRESSOR, kCompId, {-22, 3, 5, 3, 70, 0, 0, 1, 120, 0, 100, 0, 0, 20, 0, 0});
    c.add(N60_STAGE_EXPANDER, kExpId, {-50, 2, -20, 3, 60, 0, 20, 4, 0, 20, 90, 0, 0});
}
void buildExpOnly(Chain &c) { c.add(N60_STAGE_EXPANDER, kExpId, {-50, 2, -20, 3, 60, 0, 20, 4, 0, 20, 90, 0, 0}); }
// G42: the expander alone (side-chain high-pass at 90 Hz), so nothing upstream hides a latched state: after a NaN and an Inf
// burst the output is finite and still passes the programme (the gate is open for 0.3-amplitude noise, so the tail energy
// stays near the input's, not collapsed by a poisoned detector).
void checkExpanderNonFinite() {
    for (double rate : kRates) {
        for (uint32_t lanes : {1u, 2u, 3u}) {
            Chain c;
            buildExpOnly(c);
            n60_graph *g = nullptr;
            if (n60_graph_build(c.finish(rate, 256, lanes), &g) != N60_STATUS_OK) { CHECK(false, "exp build"); continue; }
            std::vector<std::vector<float>> in(lanes, std::vector<float>(256)), ob(lanes, std::vector<float>(256));
            std::vector<const float *> ip(lanes);
            std::vector<float *> op(lanes);
            for (uint32_t l = 0; l < lanes; ++l) { ip[l] = in[l].data(); op[l] = ob[l].data(); }
            Rng rng{123};
            bool finiteTail = true;
            double eIn = 0, eOut = 0;
            for (int blk = 0; blk < 16; ++blk) {
                for (uint32_t l = 0; l < lanes; ++l)
                    for (uint32_t i = 0; i < 256; ++i) in[l][i] = 0.3f * rng.next();
                if (blk == 3) { in[0][10] = std::nanf(""); in[lanes - 1][200] = INFINITY; }
                n60_graph_process(g, ip.data(), op.data(), 256);
                if (blk >= 10) for (uint32_t l = 0; l < lanes; ++l) for (uint32_t i = 0; i < 256; ++i) {
                    finiteTail = finiteTail && std::isfinite(ob[l][i]);
                    eIn += double(in[l][i]) * in[l][i];
                    eOut += double(ob[l][i]) * ob[l][i];
                }
            }
            CHECK(finiteTail, "expander did not recover from a non-finite burst (rate %g lanes %u)", rate, lanes);
            CHECK(eOut > 0.5 * eIn, "expander stayed closed after a non-finite burst: out %g in %g (rate %g lanes %u)", eOut, eIn, rate, lanes);
            n60_graph_retire(g);
        }
    }
}
void checkDynNonFinite() {
    for (double rate : {48000.0, 384000.0}) {
        for (uint32_t lanes : {1u, 2u, 3u}) {
            Chain c;
            buildDynOnly(c);
            n60_graph *g = nullptr;
            if (n60_graph_build(c.finish(rate, 256, lanes), &g) != N60_STATUS_OK) { CHECK(false, "dyn build"); continue; }
            std::vector<std::vector<float>> in(lanes, std::vector<float>(256)), ob(lanes, std::vector<float>(256));
            std::vector<const float *> ip(lanes);
            std::vector<float *> op(lanes);
            for (uint32_t l = 0; l < lanes; ++l) { ip[l] = in[l].data(); op[l] = ob[l].data(); }
            Rng rng{99};
            bool finiteTail = true;
            for (int blk = 0; blk < 12; ++blk) {
                for (uint32_t l = 0; l < lanes; ++l)
                    for (uint32_t i = 0; i < 256; ++i) in[l][i] = 0.3f * rng.next();
                if (blk == 3) { in[0][10] = std::nanf(""); in[lanes - 1][200] = INFINITY; }
                n60_graph_process(g, ip.data(), op.data(), 256);
                if (blk >= 8) for (uint32_t l = 0; l < lanes; ++l) for (float v : ob[l]) finiteTail = finiteTail && std::isfinite(v);
            }
            CHECK(finiteTail, "compressor/expander did not recover from a non-finite burst (rate %g lanes %u)", rate, lanes);
            n60_graph_retire(g);
        }
    }
}

}  // namespace

int main(int argc, char **argv) {
    const std::string mode = argc > 1 ? argv[1] : "check";
    if (mode == "dump") return dump();
    std::printf("simd backend: %s\n", n60::simd::kBackend);
    checkPrimitives();
    checkMixAndRamp();
    checkLaneIndependence();
    checkChunkInvariance();
    checkBassReference<-1>();
    checkBassReference<2>();
    checkContourReference();
    checkLevelerPark();
    checkDynNonFinite();
    checkExpanderNonFinite();
    checkNonFiniteBurst();
    if (failures != 0) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("simd parity checks passed");
    return 0;
}
