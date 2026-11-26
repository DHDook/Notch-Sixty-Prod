// E12 S28b1: K-weighted pink-noise level of one output (n60_headroom_weighted_level) at the eight standard rates.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/headroom.h"
#include "n60/xover.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static n60_headroom_stage stage(uint32_t kind, const std::vector<float> &p) {
    n60_headroom_stage s{};
    s.kind = kind;
    s.param_count = static_cast<uint32_t>(p.size());
    s.params = p.empty() ? nullptr : p.data();
    return s;
}

static n60_headroom_path path(const std::vector<n60_headroom_stage> &s, uint32_t combine = N60_HEADROOM_COMBINE_COHERENT) {
    n60_headroom_path p{};
    p.combine = combine;
    p.stage_count = static_cast<uint32_t>(s.size());
    p.stages = s.empty() ? nullptr : s.data();
    return p;
}

static double level(double fs, const std::vector<n60_headroom_path> &paths, const std::vector<n60_headroom_stage> &tail = {},
                    int *rc = nullptr, double *ratio = nullptr) {
    n60_headroom_output o{};
    o.struct_size = sizeof(o);
    o.sample_rate = fs;
    o.path_count = static_cast<uint32_t>(paths.size());
    o.paths = paths.data();
    o.tail_stage_count = static_cast<uint32_t>(tail.size());
    o.tail_stages = tail.empty() ? nullptr : tail.data();
    n60_headroom_level_result r{};
    r.struct_size = sizeof(r);
    const int code = n60_headroom_weighted_level(&o, &r);
    if (rc) *rc = code; else CHECK(code == 0, "level returned %d", code);
    if (ratio) *ratio = r.power_ratio;
    return r.level_db;
}

static std::vector<float> biquads(const n60_xover_cascade &c) {
    std::vector<float> p;
    for (uint32_t i = 0; i < c.count; ++i) {
        const n60_xover_biquad &q = c.sections[i];
        p.insert(p.end(), {static_cast<float>(q.b0), static_cast<float>(q.b1), static_cast<float>(q.b2),
                           static_cast<float>(q.a1), static_cast<float>(q.a2)});
    }
    return p;
}

int main() {
    for (double fs : kRates) {
        // Flat chain reads 0 dB; a unity-gain gain stage and a pure delay do too.
        CHECK(std::fabs(level(fs, {path({})})) < 1e-9, "flat at %.0f", fs);
        std::vector<float> one = {1.0f}, d = {37.0f}, half = {0.5f}, two = {2.0f};
        CHECK(std::fabs(level(fs, {path({stage(N60_HEADROOM_STAGE_GAIN, one), stage(N60_HEADROOM_STAGE_DELAY, d)})})) < 1e-9, "unity+delay");
        // A broadband gain moves the level by exactly its value, and a tail gain does the same.
        CHECK(std::fabs(level(fs, {path({stage(N60_HEADROOM_STAGE_GAIN, half)})}) + 6.0205999) < 1e-6, "half gain");
        CHECK(std::fabs(level(fs, {path({})}, {stage(N60_HEADROOM_STAGE_GAIN, two)}) - 6.0205999) < 1e-6, "tail x2");
        // Polarity does not change the level of one path.
        std::vector<float> neg = {-1.0f};
        CHECK(std::fabs(level(fs, {path({stage(N60_HEADROOM_STAGE_GAIN, neg)})})) < 1e-9, "polarity");
        // A 6 dB broadband peaking boost far below the weighting band moves the level by less than 6 dB, more than 0.
        {
            std::vector<float> peq = {0, 100.0f, 6.0f, 0.7f};
            const double v = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})});
            CHECK(v > 0.05 && v < 3.0, "peq 100 Hz level %.3f at %.0f", v, fs);
            // The same boost at 3 kHz (inside the K-weighted band) matters more than at 100 Hz.
            std::vector<float> hi = {0, 3000.0f, 6.0f, 0.7f};
            const double w = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, hi)})});
            CHECK(w > v, "weighting: 3k %.3f vs 100 %.3f", w, v);
        }
        // LR24 low-pass plus high-pass recombine to 0 dB within 0.05 dB.
        {
            n60_xover_spec lp{sizeof(n60_xover_spec), N60_XOVER_FAMILY_LINKWITZ_RILEY, 4, 80.0};
            n60_xover_cascade cl{}, ch{};
            CHECK(n60_xover_design(&lp, 0, fs, &cl) == N60_XOVER_OK, "lp design");
            CHECK(n60_xover_design(&lp, 1, fs, &ch) == N60_XOVER_OK, "hp design");
            std::vector<float> pl = biquads(cl), ph = biquads(ch);
            const float sign = n60_xover_lr_inverts_hp(4) ? -1.0f : 1.0f;
            std::vector<float> sg = {sign};
            const double v = level(fs, {path({stage(N60_HEADROOM_STAGE_BIQUAD, pl)}),
                                        path({stage(N60_HEADROOM_STAGE_BIQUAD, ph), stage(N60_HEADROOM_STAGE_GAIN, sg)})});
            CHECK(std::fabs(v) < 0.05, "LR24 recombined %.4f at %.0f", v, fs);
            // Sub path alone at +6 dB: the level moves by the predicted amount (ratio scales by 10^(0.6)).
            std::vector<float> g6 = {static_cast<float>(std::pow(10.0, 6.0 / 20.0))};
            double r0 = 0, r6 = 0;
            level(fs, {path({stage(N60_HEADROOM_STAGE_BIQUAD, pl)})}, {}, nullptr, &r0);
            level(fs, {path({stage(N60_HEADROOM_STAGE_BIQUAD, pl), stage(N60_HEADROOM_STAGE_GAIN, g6)})}, {}, nullptr, &r6);
            CHECK(std::fabs(10.0 * std::log10(r6 / r0) - 6.0) < 1e-4, "sub +6 dB moved %.5f", 10.0 * std::log10(r6 / r0));
            // The LR24 low-pass alone is far below the full-range level (weighted pink is mostly above 80 Hz).
            CHECK(10.0 * std::log10(r0) < -6.0, "lp alone %.2f", 10.0 * std::log10(r0));
        }
        // Power-combined equal paths add 3.01 dB, coherent add 6.02 dB (flat chains).
        {
            const double p = level(fs, {path({}, N60_HEADROOM_COMBINE_POWER), path({}, N60_HEADROOM_COMBINE_POWER)});
            CHECK(std::fabs(p - 3.0103) < 1e-3, "power %.4f", p);
            const double c = level(fs, {path({}), path({})});
            CHECK(std::fabs(c - 6.0206) < 1e-3, "coherent %.4f", c);
        }
        // Bit-equal repeat.
        {
            std::vector<float> peq = {0, 250.0f, -4.0f, 1.2f};
            const double a = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})});
            const double b = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})});
            CHECK(std::memcmp(&a, &b, sizeof a) == 0, "not bit-equal");
        }
        // Reference-lab case: two sides trimmed by their level difference land within 0.1 dB.
        {
            std::vector<float> peq = {0, 2000.0f, 5.0f, 0.9f};
            const double sideA = level(fs, {path({})});
            const double sideB = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})});
            const float trim = static_cast<float>(std::pow(10.0, (sideA - sideB) / 20.0));
            std::vector<float> t = {trim};
            const double after = level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq), stage(N60_HEADROOM_STAGE_GAIN, t)})});
            CHECK(std::fabs(after - sideA) < 0.1, "trimmed pair differs %.4f at %.0f", after - sideA, fs);
        }
    }
    // The same non-flat chain reads alike at every rate (grid capped at 20 kHz).
    {
        std::vector<float> peq = {0, 150.0f, -6.0f, 0.8f};
        const double ref = level(48000.0, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})});
        for (double fs : kRates) CHECK(std::fabs(level(fs, {path({stage(N60_HEADROOM_STAGE_PEQ, peq)})}) - ref) < 0.1, "cross-rate %.0f", fs);
    }
    // Refusals.
    {
        int rc = 0;
        std::vector<n60_headroom_stage> unknown = {stage(99u, {})};
        level(48000.0, {path(unknown)}, {}, &rc);
        CHECK(rc == N60_HEADROOM_ERR_STAGE, "unknown kind %d", rc);
        level(1000.0, {path({})}, {}, &rc);
        CHECK(rc == N60_HEADROOM_ERR_ARGUMENT, "bad rate %d", rc);
        n60_headroom_level_result r{};
        CHECK(n60_headroom_weighted_level(nullptr, &r) == N60_HEADROOM_ERR_ARGUMENT, "null");
    }
    if (failures == 0) std::printf("headroom level: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
