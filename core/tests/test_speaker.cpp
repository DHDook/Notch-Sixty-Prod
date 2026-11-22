// E21 S9a: behavioural harness for the speaker maths (n60/speaker.h) through the C ABI, at the eight standard rates.
// References are closed forms written here; nothing is shared with the implementation. Parity with the Swift and legacy C
// designers is the XCTest SpeakerMathsCoreParityTests.
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/speaker.h"
#include "n60/correct.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static double bump(double f, double centre, double gain, double octaves) {
    const double d = std::log2(f / centre) / octaves;
    return gain * std::exp(-0.5 * d * d);
}

static void testInterpolation() {
    const double f[] = {100, 400, 1600};
    const double v[] = {0, 6, 18};
    double out = -1;
    CHECK(n60_speaker_interpolate_log(f, v, 3, 200, &out) == 0 && std::fabs(out - 3.0) < 1e-12, "midpoint of an octave pair %g", out);
    CHECK(n60_speaker_interpolate_log(f, v, 3, 800, &out) == 0 && std::fabs(out - 12.0) < 1e-12, "second segment %g", out);
    CHECK(n60_speaker_interpolate_log(f, v, 3, 50, &out) == 0 && out == 0.0, "flat below");
    CHECK(n60_speaker_interpolate_log(f, v, 3, 5000, &out) == 0 && out == 18.0, "flat above");
    CHECK(n60_speaker_interpolate_log(f, v, 1, 200, &out) == N60_SPEAKER_ERR_ARGUMENT, "one point");
    CHECK(n60_speaker_interpolate_log(f, v, 3, -1, &out) == N60_SPEAKER_ERR_ARGUMENT, "negative frequency");
    CHECK(std::fabs(n60_speaker_target_gain_db(f, v, 3, 200) - 3.0) < 1e-12, "target midpoint");
    CHECK(n60_speaker_target_gain_db(f, v, 1, 200) == 0.0, "short target is flat");
}

static std::vector<float> grid(double rate, int count) {
    const double high = std::fmin(20000.0, rate * 0.48);
    std::vector<float> g(count);
    for (int i = 0; i < count; ++i) g[i] = static_cast<float>(20.0 * std::pow(high / 20.0, i / double(count - 1)));
    return g;
}

static void testCorrectionDesign() {
    for (double rate : kRates) {
        const int bins = 320, seats = 2, sources = 2;
        std::vector<float> f = grid(rate, bins), target(bins, 0.0f), mag(sources * seats * bins);
        const float weights[2] = {1.0f, 0.5f};
        for (int s = 0; s < sources; ++s)
            for (int k = 0; k < seats; ++k)
                for (int i = 0; i < bins; ++i)
                    mag[(s * seats + k) * bins + i] = static_cast<float>(
                        bump(f[i], 900.0 * (1 + 0.02 * k), s == 0 ? 7.0 : 5.0, 0.25) - 3.0);
        for (int i = 0; i < bins; ++i) target[i] = -3.0f;
        const uint8_t valid[4] = {1, 1, 1, 1};
        const float trim[2] = {-1.0f, 0.0f};
        const uint32_t delay[2] = {12, 0};
        const uint8_t inverted[2] = {0, 1};
        n60_speaker_correction_problem p{};
        p.struct_size = sizeof p;
        p.source_count = sources; p.seat_count = seats; p.bin_count = bins; p.sample_rate = rate;
        p.frequency_hz = f.data(); p.target_db = target.data(); p.seat_weight = weights;
        p.magnitude_db = mag.data(); p.response_valid = valid;
        p.source_trim_db = trim; p.source_delay_frames = delay; p.source_polarity_inverted = inverted;
        n60_speaker_correction_defaults(&p.settings);
        p.settings.maximum_boost_db = 0;
        n60_speaker_correction_source out[2];
        CHECK(n60_speaker_correction_design(&p, out) == 0, "design %g", rate);
        for (int s = 0; s < sources; ++s) {
            CHECK(out[s].valid == 1 && out[s].band_count >= 1, "source %d has a band at %g", s, rate);
            CHECK(out[s].post_rms_error_db < out[s].pre_rms_error_db, "improves %g", rate);
            CHECK(out[s].band_count <= p.settings.maximum_band_count, "band cap");
            CHECK(std::fabs(out[s].bands[0].frequency_hz / 900.0 - 1.0) < 0.2, "first band near the bump %g: %g", rate, out[s].bands[0].frequency_hz);
            for (uint32_t b = 0; b < out[s].band_count; ++b) CHECK(out[s].bands[b].gain_db <= 0 && out[s].bands[b].gain_db >= -10, "cut only");
        }
        CHECK(out[0].trim_db == -1.0f && out[0].delay_frames == 12 && out[0].polarity_inverted == 0, "alignment carried");
        CHECK(out[1].polarity_inverted == 1, "polarity carried");
        // A flat response needs no band.
        std::vector<float> flat(sources * seats * bins, -3.0f);
        p.magnitude_db = flat.data();
        CHECK(n60_speaker_correction_design(&p, out) == 0 && out[0].band_count == 0 && out[0].post_rms_error_db == out[0].pre_rms_error_db, "flat");
        p.response_valid = valid;
        const uint8_t bad[4] = {1, 0, 1, 1};
        p.response_valid = bad;
        CHECK(n60_speaker_correction_design(&p, out) == N60_SPEAKER_ERR_ARGUMENT, "an invalid response fails");
        float zero[2] = {0, 0};
        p.response_valid = valid;
        p.seat_weight = zero;
        CHECK(n60_speaker_correction_design(&p, out) == N60_SPEAKER_ERR_ARGUMENT, "no weight fails");
    }
    n60_speaker_correction_settings s;
    n60_speaker_correction_defaults(&s);
    CHECK(n60_speaker_correction_settings_valid(&s, 48000) == 1, "defaults valid");
    CHECK(n60_speaker_correction_settings_valid(&s, 30000) == 0, "max correction beyond Nyquist is invalid");
    s.maximum_band_count = 9;
    CHECK(n60_speaker_correction_settings_valid(&s, 48000) == 0, "band count");
}

struct Candidate {
    std::vector<double> f, target, desired, pos, weight;
    std::vector<uint8_t> auth;
    n60_speaker_candidate_problem p{};
    Candidate(double rate, int bins, int positions, double bumpGain) {
        const double high = std::fmin(16000.0, rate * 0.45);
        for (int i = 0; i < bins; ++i) f.push_back(30.0 * std::pow(high / 30.0, i / double(bins - 1)));
        target.assign(bins, 0.0);
        for (int k = 0; k < positions; ++k) {
            weight.push_back(1.0 / positions);
            for (int i = 0; i < bins; ++i) pos.push_back(bump(f[i], 300.0 * (1 + 0.03 * k), bumpGain, 0.35));
        }
        desired.resize(bins);
        for (int i = 0; i < bins; ++i) desired[i] = -bump(f[i], 300.0, bumpGain, 0.35);
        p.struct_size = sizeof p; p.bin_count = bins; p.position_count = positions; p.sample_rate = rate;
        p.frequency_hz = f.data(); p.target_db = target.data(); p.desired_db = desired.data();
        p.position_db = pos.data(); p.position_weight = weight.data();
        p.maximum_boost_db = 0; p.maximum_cut_db = 8; p.maximum_seat_degradation_db = 0.25; p.protected_leakage_db = -1;
    }
};

static n60_speaker_peq_constraints peqConstraints() {
    n60_speaker_peq_constraints c{};
    c.maximum_bands = 6; c.minimum_q = 0.55; c.maximum_q = 4.0; c.maximum_band_gain_db = 6.0;
    c.maximum_headroom_db = 3.5; c.maximum_out_of_band_db = 1.0; c.minimum_improvement_db = 0.03;
    return c;
}

static void testPeq() {
    for (double rate : kRates) {
        Candidate cand(rate, 160, 3, 5.0);
        std::vector<double> corr(160);
        n60_speaker_peq_result r{};
        r.correction_db = corr.data();
        const n60_speaker_peq_constraints c = peqConstraints();
        CHECK(n60_speaker_peq_design(&cand.p, &c, &r) == 0, "peq %g", rate);
        CHECK(r.band_count >= 1 && r.band_count <= 6, "bands %u", r.band_count);
        CHECK(r.rmse_after_db < r.rmse_before_db, "improves %g: %g -> %g", rate, r.rmse_before_db, r.rmse_after_db);
        CHECK(std::fabs(r.bands[0].frequency_hz / 300.0 - 1.0) < 0.3, "first band near 300 Hz: %g", r.bands[0].frequency_hz);
        for (uint32_t b = 0; b < r.band_count; ++b)
            CHECK(r.bands[b].gain_db < 0 && r.bands[b].gain_db >= -6 && r.bands[b].q >= 0.55 && r.bands[b].q <= 4.0, "cut only inside limits");
        CHECK(r.maximum_positive_gain_db <= 1e-6 && r.recommended_headroom_db == 0, "no headroom for a cut-only filter");
        CHECK(r.worst_seat_regression_db < 0.25, "seat regression %g", r.worst_seat_regression_db);
        // A single band limit.
        n60_speaker_peq_constraints one = c;
        one.maximum_bands = 1;
        CHECK(n60_speaker_peq_design(&cand.p, &one, &r) == 0 && r.band_count == 1, "one band");
        // Nothing authorised: the search stays empty.
        std::vector<uint8_t> none(160, 0);
        cand.p.authorized = none.data();
        CHECK(n60_speaker_peq_design(&cand.p, &c, &r) == 0 && r.band_count == 0 && r.rmse_after_db == r.rmse_before_db, "no authorised bins");
        // A flat response needs no band.
        Candidate flat(rate, 160, 2, 0.0);
        CHECK(n60_speaker_peq_design(&flat.p, &c, &r) == 0 && r.band_count == 0, "flat");
        // Invalid problem.
        cand.p.bin_count = 8;
        CHECK(n60_speaker_peq_design(&cand.p, &c, &r) == N60_SPEAKER_ERR_ARGUMENT, "too few bins");
    }
}

static void testFir() {
    for (double rate : kRates) {
        Candidate cand(rate, 160, 3, 4.0);
        const uint32_t taps = 2 * static_cast<uint32_t>(std::lround(1024 * rate / 48000.0)) + 1;
        std::vector<float> t(taps);
        std::vector<double> resp(160);
        n60_speaker_fir_result r{};
        r.taps = t.data();
        r.response_db = resp.data();
        n60_speaker_fir_constraints c{};
        c.tap_count = taps; c.maximum_taps = N60_CORRECT_STAGE_TAPS; c.single_band_cap = N60_CORRECT_STAGE_TAPS;
        c.maximum_headroom_db = 3.5; c.maximum_out_of_band_db = 1.0; c.maximum_seat_degradation_db = 0.25;
        c.minimum_improvement_db = 0.05; c.maximum_truncation_overshoot_db = 0.35;
        cand.p.maximum_boost_db = 3.0;
        const int32_t status = n60_speaker_fir_design(&cand.p, &c, &r);
        CHECK(status == 0, "fir %g status %d", rate, status);
        if (status != 0) continue;
        CHECK(r.blockers == 0, "accepted %g blockers %u", rate, r.blockers);
        CHECK(r.rmse_after_db < r.rmse_before_db, "improves %g", rate);
        const uint32_t half = (taps - 1) / 2;
        for (uint32_t i = 0; i < half; ++i) CHECK(std::fabs(t[i] - t[2 * half - i]) < 1e-6, "symmetric tap %u at %g", i, rate);
        // The modelled response follows the requested correction in the middle of the band (a cut at the bump).
        int near = 0;
        for (int i = 0; i < 160; ++i) if (std::fabs(cand.f[i] / 300.0 - 1.0) < 0.05) near = i;
        CHECK(std::fabs(resp[near] - cand.desired[near]) < 1.0, "response %g vs %g at %g", resp[near], cand.desired[near], rate);
        // A longer filter than the cap: refused with the named status, never a silent two-band design.
        c.tap_count = 300001;
        std::vector<float> big(c.tap_count);
        r.taps = big.data();
        c.maximum_taps = N60_CORRECT_STAGE_TAPS_LONG;
        c.single_band_cap = N60_CORRECT_STAGE_TAPS_LONG;
        CHECK(n60_speaker_fir_design(&cand.p, &c, &r) == N60_SPEAKER_ERR_TOO_LONG, "too long for the single band cap");
        c.tap_count = 2 * N60_CORRECT_STAGE_TAPS + 1;
        c.maximum_taps = N60_CORRECT_STAGE_TAPS;
        c.single_band_cap = N60_CORRECT_STAGE_TAPS;
        CHECK(n60_speaker_fir_design(&cand.p, &c, &r) == N60_SPEAKER_ERR_ARGUMENT, "transform bound");
    }
    // A response with no correction available is blocked: nothing improves.
    Candidate flat(48000, 160, 2, 0.0);
    std::vector<float> t(2049);
    std::vector<double> resp(160);
    n60_speaker_fir_result r{};
    r.taps = t.data();
    r.response_db = resp.data();
    n60_speaker_fir_constraints c{};
    c.tap_count = 2049; c.maximum_taps = N60_CORRECT_STAGE_TAPS; c.single_band_cap = N60_CORRECT_STAGE_TAPS;
    c.maximum_headroom_db = 3.5; c.maximum_out_of_band_db = 1.0; c.maximum_seat_degradation_db = 0.25;
    c.minimum_improvement_db = 0.05; c.maximum_truncation_overshoot_db = 0.35;
    CHECK(n60_speaker_fir_design(&flat.p, &c, &r) == 0 && (r.blockers & N60_SPEAKER_FIR_BLOCK_NO_GAIN) != 0, "no gain is blocked");
}

int main() {
    testInterpolation();
    testCorrectionDesign();
    testPeq();
    testFir();
    if (failures == 0) std::printf("speaker ok\n");
    return failures == 0 ? 0 : 1;
}
