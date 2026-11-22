// E21 S7a: behavioural harness for the multichannel calibration alignment maths (n60/correct.h section 8), through the
// C ABI. References are closed forms written here (weighted means, ceilings, octave spacing); nothing is shared with the
// implementation. Grid, timing and alignment cases run at the eight standard device rates and 1 to 8 subs.
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/correct.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static void testGrid() {
    for (double rate : kRates) {
        std::vector<float> g(128);
        const double high = std::fmin(20000.0, rate * 0.48);
        CHECK(n60_correct_calib_grid(20.0, high, 128, g.data()) == 0, "grid");
        CHECK(g[0] == 20.0f && std::fabs(g[127] / high - 1.0) < 1e-6, "ends %g", rate);
        bool ascending = true;
        for (int i = 1; i < 128; ++i) ascending = ascending && g[i] > g[i - 1];
        CHECK(ascending, "ascending");
        const double ratio = std::pow(high / 20.0, 1.0 / 127.0);
        CHECK(std::fabs(g[64] / g[63] - ratio) < 1e-5, "constant ratio");
    }
    float out[4];
    CHECK(n60_correct_calib_grid(20.0, 10.0, 4, out) == N60_CORRECT_ERR_ARGUMENT, "max below min");
    CHECK(n60_correct_calib_grid(20.0, 100.0, 1, out) == N60_CORRECT_ERR_ARGUMENT, "count 1");
}

static void testPolarityAndLevel() {
    std::vector<float> ir(100, 0.0f);
    ir[40] = -0.5f;
    ir[45] = 0.25f;
    CHECK(n60_correct_calib_direct_polarity(ir.data(), ir.size(), 40) == -1, "negative peak");
    ir[50] = 0.9f;  // 10 samples after the arrival, inside the 16 sample window
    CHECK(n60_correct_calib_direct_polarity(ir.data(), ir.size(), 40) == 1, "larger positive peak in window");
    CHECK(n60_correct_calib_direct_polarity(ir.data(), ir.size(), 20) == 1, "window from 20 ends at 35: a silent window is positive");
    ir[10] = 0.0f;
    CHECK(n60_correct_calib_direct_polarity(ir.data(), ir.size(), 1000) == 1, "arrival clamps to the last sample");
    CHECK(n60_correct_calib_direct_polarity(nullptr, 0, 0) == 1, "empty");

    const float f[] = {20, 50, 150, 1000, 12000};
    const float m[] = {10, 20, 30, 40, 50};
    CHECK(n60_correct_calib_broadband_level_db(f, m, 5, 0) == 35.0f, "speaker band 100..10000: 30 and 40");
    CHECK(n60_correct_calib_broadband_level_db(f, m, 5, 1) == 25.0f, "sub band 25..200: 20 and 30");
    const float f2[] = {1, 2};
    const float m2[] = {4, 8};
    CHECK(n60_correct_calib_broadband_level_db(f2, m2, 2, 0) == 6.0f, "falls back to every bin");
    CHECK(n60_correct_calib_broadband_level_db(f2, m2, 0, 0) == 0.0f, "empty");
}

static void testAlign() {
    // Two speakers and one sub, two seats with weights 1 and 0.5 (and a third excluded seat).
    const float w[] = {1.0f, 0.5f, 0.0f};
    const uint8_t speaker[] = {1, 1, 0};
    // [source][seat]
    const uint32_t arrival[] = {100, 130, 9999, 160, 190, 9999, 5, 5, 5};
    const int8_t pol[] = {1, 1, -1, -1, -1, 1, 1, 1, 1};
    const float level[] = {-10, -16, 50, -20, -20, -50, 0, 0, 0};
    n60_correct_calib_align_source out[3];
    n60_correct_calib_align_problem p = {sizeof(p), 3, 3, w, speaker, arrival, pol, level};
    n60_correct_calib_align_result r = {0, 0, out};
    CHECK(n60_correct_calib_align(&p, &r) == 0, "align");
    // weighted arrival: (100 + 65) / 1.5 -> 100*(2/3) + 130*(1/3) = 110; second 160*(2/3)+190/3 = 170
    CHECK(std::fabs(out[0].weighted_arrival_frame - 110.0f) < 1e-3f, "arrival0 %g", out[0].weighted_arrival_frame);
    CHECK(std::fabs(out[1].weighted_arrival_frame - 170.0f) < 1e-3f, "arrival1 %g", out[1].weighted_arrival_frame);
    CHECK(r.reference_arrival_frame == 170, "reference %u", r.reference_arrival_frame);
    CHECK(out[0].delay_frames == 60 && out[1].delay_frames == 0, "delays %u %u", out[0].delay_frames, out[1].delay_frames);
    // levels: -10*2/3 - 16/3 = -12; -20
    CHECK(std::fabs(out[0].weighted_level_db + 12.0f) < 1e-4f && std::fabs(r.common_level_db + 20.0f) < 1e-4f, "levels");
    CHECK(std::fabs(out[0].trim_db - (-8.0f)) < 1e-4f && out[1].trim_db == 0.0f, "trims %g", out[0].trim_db);
    // variance of source 0: 2/3 * 4 + 1/3 * 16 = 8
    CHECK(std::fabs(out[0].seat_variance_db2 - 8.0f) < 1e-3f, "variance %g", out[0].seat_variance_db2);
    CHECK(out[0].polarity_inverted == 0 && out[1].polarity_inverted == 1, "polarity");
    CHECK(out[2].valid == 0 && out[2].delay_frames == 0, "sub not aligned as speaker");

    // Trim clamps at 24 dB attenuation.
    const float wide[] = {-60.0f, -0.0f};
    const float one[] = {1.0f};
    const uint8_t two[] = {1, 1};
    const uint32_t arr2[] = {10, 10};
    const int8_t pol2[] = {1, 1};
    n60_correct_calib_align_source out2[2];
    n60_correct_calib_align_problem q = {sizeof(q), 1, 2, one, two, arr2, pol2, wide};
    n60_correct_calib_align_result r2 = {0, 0, out2};
    CHECK(n60_correct_calib_align(&q, &r2) == 0, "align wide");
    CHECK(out2[1].trim_db == -24.0f && out2[0].trim_db == 0.0f, "clamp %g", out2[1].trim_db);

    // Errors.
    const float none[] = {0.0f};
    n60_correct_calib_align_problem e = {sizeof(e), 1, 2, none, two, arr2, pol2, wide};
    CHECK(n60_correct_calib_align(&e, &r2) == N60_CORRECT_ERR_ARGUMENT, "no weight");
    const uint8_t subs[] = {0, 0};
    n60_correct_calib_align_problem e2 = {sizeof(e2), 1, 2, one, subs, arr2, pol2, wide};
    CHECK(n60_correct_calib_align(&e2, &r2) == N60_CORRECT_ERR_ARGUMENT, "no speaker");
    const float nan[] = {NAN, 0.0f};
    n60_correct_calib_align_problem e3 = {sizeof(e3), 1, 2, one, two, arr2, pol2, nan};
    CHECK(n60_correct_calib_align(&e3, &r2) == N60_CORRECT_ERR_NONFINITE, "nan level");
}

static void testTiming() {
    for (double rate : kRates) {
        for (uint32_t subs = 1; subs <= 8; ++subs) {
            const float w[] = {1.0f, 1.0f};
            std::vector<uint32_t> arrival;
            std::vector<float> extra;
            double latest = 0.0;
            for (uint32_t s = 0; s < subs; ++s) {
                const uint32_t a0 = static_cast<uint32_t>(rate * 0.004) + 50 * s, a1 = a0 + 20;
                arrival.push_back(a0);
                arrival.push_back(a1);
                extra.push_back(static_cast<float>(s) * 0.25f);
                latest = std::fmax(latest, 0.5 * (a0 + a1) + extra.back() * rate / 1000.0);
            }
            double sp = -1, sb = -1;
            n60_correct_calib_timing_problem t = {sizeof(t), 2, subs, rate, static_cast<uint32_t>(rate * 0.005), w,
                                                  arrival.data(), extra.data()};
            CHECK(n60_correct_calib_timing_offsets(&t, &sp, &sb) == 0, "timing");
            const double ref = static_cast<double>(t.speaker_reference_arrival_frame);
            const double expectSp = latest > ref ? (latest - ref) / rate * 1000.0 : 0.0;
            const double expectSb = latest > ref ? 0.0 : (ref - latest) / rate * 1000.0;
            CHECK(std::fabs(sp - expectSp) < 1e-6 && std::fabs(sb - expectSb) < 1e-6, "%g Hz %u subs: %g %g vs %g %g", rate, subs, sp, sb, expectSp, expectSb);
            CHECK((sp == 0.0) != (sb == 0.0) || (sp == 0.0 && sb == 0.0), "one side only");
        }
    }
    double sp, sb;
    n60_correct_calib_timing_problem none = {sizeof(none), 0, 0, 48000.0, 0, nullptr, nullptr, nullptr};
    CHECK(n60_correct_calib_timing_offsets(&none, &sp, &sb) == 0 && sp == 0.0 && sb == 0.0, "no subs");
    const float zero[] = {0.0f};
    const uint32_t a[] = {1};
    const float e[] = {0.0f};
    n60_correct_calib_timing_problem bad = {sizeof(bad), 1, 1, 48000.0, 0, zero, a, e};
    CHECK(n60_correct_calib_timing_offsets(&bad, &sp, &sb) == N60_CORRECT_ERR_ARGUMENT, "no weight");
}

static void testSubEq() {
    const float f[] = {15, 25, 30, 31, 40, 80, 150, 290, 400};
    const float t[] = {-9, -3, -6, -5, -0.5f, -2, -1, -12, -9};
    double of[5], og[5], oq[5];
    uint32_t n = 0;
    CHECK(n60_correct_calib_sub_eq_fit(f, t, 9, 20.0f, 300.0f, 5, of, og, oq, &n) == 0, "fit");
    // Deepest first inside 20..300 Hz: 290 (-12), 30 (-6), 31 (-5; within 0.33 oct of 30, skipped), 25 (-3; log2(30/25)=0.263 skipped),
    // 80 (-2), 150 (-1). 40 is above -0.75 and excluded; 15 and 400 are outside the range.
    CHECK(n == 4, "count %u", n);
    CHECK(n == 4 && of[0] == 30 && of[1] == 80 && of[2] == 150 && of[3] == 290, "ascending %g %g %g %g", of[0], of[1], of[2], of[3]);
    CHECK(n == 4 && std::fabs(og[3] - (-8.0)) < 1e-12 && std::fabs(og[0] - (-4.32)) < 1e-6 && oq[0] == 1.15, "gains %g %g", og[3], og[0]);
    uint32_t m = 99;
    CHECK(n60_correct_calib_sub_eq_fit(f, t, 9, 20.0f, 300.0f, 2, of, og, oq, &m) == 0 && m == 2, "capped at max bands");
    CHECK(of[0] == 30 && of[1] == 290, "capped keeps the deepest");
    CHECK(n60_correct_calib_sub_eq_fit(nullptr, nullptr, 0, 20.0f, 300.0f, 2, of, og, oq, &m) == 0 && m == 0, "empty");
}

int main() {
    testGrid();
    testPolarityAndLevel();
    testAlign();
    testTiming();
    testSubEq();
    CHECK(n60_correct_abi_version() == N60_CORRECT_ABI_VERSION, "abi");
    if (failures == 0) std::puts("test_calibration_align: ok");
    return failures == 0 ? 0 : 1;
}
