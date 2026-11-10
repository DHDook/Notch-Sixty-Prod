// E9 S6: per-output headroom maths (n60/headroom.h) at the eight standard rates.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/headroom.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

struct Chain {
    std::vector<n60_headroom_stage> stages;
};

static n60_headroom_stage stage(uint32_t kind, const std::vector<float> &p) {
    n60_headroom_stage s{};
    s.kind = kind;
    s.param_count = static_cast<uint32_t>(p.size());
    s.params = p.empty() ? nullptr : p.data();
    return s;
}

static n60_headroom_result run(double fs, const std::vector<n60_headroom_path> &paths, bool strict = false,
                               const std::vector<n60_headroom_stage> &tail = {}, double ceiling = 0.0, int *rc = nullptr) {
    n60_headroom_output o{};
    o.struct_size = sizeof(o);
    o.sample_rate = fs;
    o.strict = strict ? 1 : 0;
    o.path_count = static_cast<uint32_t>(paths.size());
    o.paths = paths.data();
    o.tail_stage_count = static_cast<uint32_t>(tail.size());
    o.tail_stages = tail.empty() ? nullptr : tail.data();
    o.ceiling_db = ceiling;
    n60_headroom_result r{};
    r.struct_size = sizeof(r);
    const int code = n60_headroom_evaluate(&o, &r);
    if (rc) *rc = code; else CHECK(code == 0, "evaluate returned %d", code);
    return r;
}

static n60_headroom_path path(const std::vector<n60_headroom_stage> &s, uint32_t combine = N60_HEADROOM_COMBINE_COHERENT) {
    n60_headroom_path p{};
    p.combine = combine;
    p.stage_count = static_cast<uint32_t>(s.size());
    p.stages = s.empty() ? nullptr : s.data();
    return p;
}

int main() {
    CHECK(n60_headroom_abi_version() == N60_HEADROOM_ABI_VERSION, "abi");
    for (double fs : kRates) {
        // A +6 dB peaking filter reads +6.0 dB at its centre (640 Hz is on the 1/48-octave grid).
        for (double hz : {640.0, 1000.0}) {
            std::vector<float> peq = {0, static_cast<float>(hz), 6.0f, 1.0f};
            std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_PEQ, peq)};
            const n60_headroom_result r = run(fs, {path(st)});
            CHECK(std::fabs(r.peak_gain_db - 6.0) < 0.05, "%.0f Hz peq at %.0f: %.4f", hz, fs, r.peak_gain_db);
            CHECK(std::fabs(r.peak_hz / hz - 1.0) < 0.02, "peak freq %.1f vs %.0f", r.peak_hz, hz);
            CHECK(std::fabs(r.required_trim_db - 6.5) < 0.05, "required %.3f", r.required_trim_db);
        }
        // A cut-only EQ peaks at about 0 dB (its flat region); the need is just the true-peak margin.
        {
            std::vector<float> peq = {0, 1000.0f, -6.0f, 1.0f};
            std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_PEQ, peq)};
            const n60_headroom_result r = run(fs, {path(st)});
            CHECK(r.peak_gain_db < 0.01 && r.peak_gain_db > -0.1 && std::fabs(r.required_trim_db - std::max(0.0, r.peak_gain_db + 0.5)) < 1e-12, "cut %.3f", r.peak_gain_db);
        }
        // A FIR with a known peak: unit impulse delayed by 5 samples, x 2.0 (+6.02 dB, flat).
        {
            std::vector<float> taps(64, 0.0f);
            taps[5] = 2.0f;
            n60_headroom_stage f{};
            f.kind = N60_HEADROOM_STAGE_FIR;
            f.tap_count = 64;
            f.taps = taps.data();
            const n60_headroom_result r = run(fs, {path({f})});
            CHECK(std::fabs(r.peak_gain_db - 6.0206) < 0.01, "fir flat %.4f", r.peak_gain_db);
            // Two taps 0.5/0.5 is a low pass with unity gain at DC: peak 0 dB at the lowest grid point.
            std::vector<float> lp = {0.5f, 0.5f};
            f.tap_count = 2;
            f.taps = lp.data();
            const n60_headroom_result r2 = run(fs, {path({f})});
            CHECK(std::fabs(r2.peak_gain_db) < 0.01 && r2.peak_hz < 11.0, "fir lowpass %.4f at %.1f", r2.peak_gain_db, r2.peak_hz);
        }
        // Stereo bass into one sub: two identical lanes, Strict and the default model for the coherent front pair.
        {
            std::vector<float> g = {1.0f};
            std::vector<n60_headroom_stage> a = {stage(N60_HEADROOM_STAGE_GAIN, g)};
            const n60_headroom_result strict = run(fs, {path(a), path(a)}, true);
            CHECK(std::fabs(strict.peak_gain_db - 6.0206) < 0.01, "strict %.4f", strict.peak_gain_db);
            const n60_headroom_result front = run(fs, {path(a), path(a)}, false);
            CHECK(std::fabs(front.peak_gain_db - 6.0206) < 0.01, "front pair coherent %.4f", front.peak_gain_db);
            // Two uncorrelated surround lanes add as power: +3.01 dB; Strict makes them +6.02.
            const n60_headroom_result surr = run(fs, {path(a, N60_HEADROOM_COMBINE_POWER), path(a, N60_HEADROOM_COMBINE_POWER)}, false);
            CHECK(std::fabs(surr.peak_gain_db - 3.0103) < 0.01, "surround power %.4f", surr.peak_gain_db);
            const n60_headroom_result surrStrict = run(fs, {path(a, N60_HEADROOM_COMBINE_POWER), path(a, N60_HEADROOM_COMBINE_POWER)}, true);
            CHECK(std::fabs(surrStrict.peak_gain_db - 6.0206) < 0.01, "surround strict %.4f", surrStrict.peak_gain_db);
            // Front pair plus one surround lane: sqrt(2^2 + 1) = sqrt(5), 6.99 dB.
            const n60_headroom_result mix = run(fs, {path(a), path(a), path(a, N60_HEADROOM_COMBINE_POWER)}, false);
            CHECK(std::fabs(mix.peak_gain_db - 20.0 * std::log10(std::sqrt(5.0))) < 0.01, "mixed %.4f", mix.peak_gain_db);
        }
        // Polarity: opposite-polarity lanes cancel when coherent (floor), add as power when uncorrelated.
        {
            std::vector<float> pos = {1.0f}, neg = {-1.0f};
            std::vector<n60_headroom_stage> a = {stage(N60_HEADROOM_STAGE_GAIN, pos)}, b = {stage(N60_HEADROOM_STAGE_GAIN, neg)};
            const n60_headroom_result cancel = run(fs, {path(a), path(b)}, false);
            CHECK(cancel.peak_gain_db < -100.0, "cancel %.2f", cancel.peak_gain_db);
            const n60_headroom_result power = run(fs, {path(a, N60_HEADROOM_COMBINE_POWER), path(b, N60_HEADROOM_COMBINE_POWER)}, false);
            CHECK(std::fabs(power.peak_gain_db - 3.0103) < 0.01, "power ignores polarity %.4f", power.peak_gain_db);
        }
        // Delay: a half-period delay on one of two coherent lanes cancels at that frequency; the peak elsewhere is below +6.02.
        {
            std::vector<float> g = {1.0f};
            const float d = static_cast<float>(fs / 1000.0 / 2.0);  // half a period at 1 kHz
            std::vector<float> dl = {d};
            std::vector<n60_headroom_stage> a = {stage(N60_HEADROOM_STAGE_GAIN, g)};
            std::vector<n60_headroom_stage> b = {stage(N60_HEADROOM_STAGE_DELAY, dl)};
            const n60_headroom_result r = run(fs, {path(a), path(b)}, false);
            CHECK(r.peak_gain_db <= 6.0207 && r.peak_gain_db > 5.9, "delay peak %.4f", r.peak_gain_db);
            // A delay of exactly half a period of a 100 Hz grid-ish tone: a sub-sample-period delay does not change the DC-side peak.
            std::vector<float> one = {1.0f};
            n60_headroom_stage dz = stage(N60_HEADROOM_STAGE_DELAY, one);
            const n60_headroom_result r2 = run(fs, {path({dz})});
            CHECK(std::fabs(r2.peak_gain_db) < 0.001, "pure delay is flat %.5f", r2.peak_gain_db);
        }
        // Dynamic EQ counts its maximum boost: static +2, boost direction, max boost +6 -> +8 dB.
        {
            std::vector<float> dq = {0.0f, 0, 640.0f, 1.0f, 2.0f, -30.0f, 2.0f, -12.0f, 10.0f, 100.0f, 1.0f, -40.0f, 2.0f, 6.0f, 0.0f, 20.0f};
            std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_DYN_EQ, dq)};
            const n60_headroom_result r = run(fs, {path(st)});
            CHECK(std::fabs(r.peak_gain_db - 8.0) < 0.05, "dyn eq max boost %.4f", r.peak_gain_db);
            // Direction cut: only the static gain counts.
            dq[1 + 9] = 0.0f;
            const n60_headroom_result r2 = run(fs, {path(st)});
            CHECK(std::fabs(r2.peak_gain_db - 2.0) < 0.05, "dyn eq cut direction %.4f", r2.peak_gain_db);
        }
        // Compressor make-up counts; a tail chain (output gain) subtracts; the ceiling moves the need.
        {
            std::vector<float> comp = {-20.0f, 4.0f, 6.0f, 10.0f, 100.0f, 3.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_COMPRESSOR, comp)};
            std::vector<float> trim = {static_cast<float>(std::pow(10.0, -2.0 / 20.0))};
            std::vector<n60_headroom_stage> tail = {stage(N60_HEADROOM_STAGE_GAIN, trim)};
            const n60_headroom_result r = run(fs, {path(st)}, false, tail, -1.0);
            CHECK(std::fabs(r.peak_gain_db - 1.0) < 0.01, "makeup +3 then -2: %.4f", r.peak_gain_db);
            CHECK(std::fabs(r.required_trim_db - 2.5) < 0.01, "need = 1 + 0.5 + 1 = %.4f", r.required_trim_db);
        }
        // A BIQUAD cascade (a unity gain 2nd-order section: b = a) is flat.
        {
            std::vector<float> bq = {1.0f, 0.5f, 0.25f, 0.5f, 0.25f};
            std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_BIQUAD, bq)};
            const n60_headroom_result r = run(fs, {path(st)});
            CHECK(std::fabs(r.peak_gain_db) < 1e-6, "biquad flat %.9f", r.peak_gain_db);
        }
        // Grid: 10 Hz to 0.45 fs at 48 steps per octave.
        {
            std::vector<float> g = {1.0f};
            std::vector<n60_headroom_stage> a = {stage(N60_HEADROOM_STAGE_GAIN, g)};
            const n60_headroom_result r = run(fs, {path(a)});
            const double expect = std::floor(48.0 * std::log2(0.45 * fs / 10.0)) + 1.0;
            CHECK(std::fabs(r.grid_points - expect) <= 1.0, "grid %u vs %.0f", r.grid_points, expect);
            CHECK(std::fabs(r.true_peak_margin_db - 0.5) < 1e-12, "margin");
        }
    }
    // A long FIR (262,144 taps, an exponentially decaying random filter): the peak equals the maximum of a direct DFT.
    {
        const uint32_t n = N60_HEADROOM_MAX_FIR_TAPS;
        std::vector<float> h(n);
        uint32_t seed = 12345;
        for (uint32_t i = 0; i < n; ++i) {
            seed = seed * 1664525u + 1013904223u;
            const double u = (static_cast<double>(seed >> 8) / 16777216.0) * 2.0 - 1.0;
            h[i] = static_cast<float>(u * std::exp(-static_cast<double>(i) / 20000.0));
        }
        n60_headroom_stage f{};
        f.kind = N60_HEADROOM_STAGE_FIR;
        f.tap_count = n;
        f.taps = h.data();
        const n60_headroom_result r = run(48000.0, {path({f})});
        // Independent check at the reported peak frequency with a long-double DFT.
        long double re = 0, im = 0;
        const long double w = 2.0L * 3.14159265358979323846L * r.peak_hz / 48000.0L;
        for (uint32_t i = 0; i < n; ++i) {
            re += h[i] * cosl(w * i);
            im -= h[i] * sinl(w * i);
        }
        const double ref = 20.0 * std::log10(std::sqrt(static_cast<double>(re * re + im * im)));
        CHECK(std::fabs(ref - r.peak_gain_db) < 0.01, "long fir %.4f vs %.4f", r.peak_gain_db, ref);
    }
    // Refusals.
    {
        int rc = 0;
        std::vector<float> bad = {9.0f, 1000.0f, 6.0f, 1.0f};
        std::vector<n60_headroom_stage> st = {stage(N60_HEADROOM_STAGE_PEQ, bad)};
        run(48000.0, {path(st)}, false, {}, 0.0, &rc);
        CHECK(rc == N60_HEADROOM_ERR_STAGE, "bad peq type %d", rc);
        std::vector<n60_headroom_stage> unknown = {stage(99u, {})};
        run(48000.0, {path(unknown)}, false, {}, 0.0, &rc);
        CHECK(rc == N60_HEADROOM_ERR_STAGE, "unknown kind %d", rc);
        run(1000.0, {path({})}, false, {}, 0.0, &rc);
        CHECK(rc == N60_HEADROOM_ERR_ARGUMENT, "bad rate %d", rc);
        n60_headroom_result r{};
        CHECK(n60_headroom_evaluate(nullptr, &r) == N60_HEADROOM_ERR_ARGUMENT, "null");
    }
    if (failures == 0) std::printf("headroom: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
