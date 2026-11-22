// E21 S9b: behavioural harness for the crossover feasibility, cross-domain classifier, early-window magnitude and design
// preview maths (n60/speaker.h v2) through the C ABI, at the eight standard rates. References are closed forms written
// here; nothing is shared with the implementation. Parity with the Swift designers is the XCTest SpeakerMathsS9bParityTests.
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/speaker.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

struct Xover {
    std::vector<double> f, mr, mi, sr, si, w;
    n60_speaker_crossover_problem p{};
    void build(double rate, uint32_t seats, double sub_delay_s, double sub_sign) {
        n60_speaker_crossover_options o;
        n60_speaker_crossover_defaults(&o);
        f.resize(o.frequency_point_count);
        n60_speaker_crossover_frequencies(&o, f.data(), static_cast<uint32_t>(f.size()));
        const size_t n = f.size() * seats;
        mr.assign(n, 1.0); mi.assign(n, 0.0); sr.assign(n, 0.0); si.assign(n, 0.0);
        for (uint32_t s = 0; s < seats; ++s)
            for (size_t i = 0; i < f.size(); ++i) {
                sr[s * f.size() + i] = sub_sign * std::cos(-2 * kPi * f[i] * sub_delay_s);
                si[s * f.size() + i] = sub_sign * std::sin(-2 * kPi * f[i] * sub_delay_s);
            }
        w.assign(seats, 1.0 / seats);
        p.struct_size = sizeof p; p.seat_count = seats; p.point_count = static_cast<uint32_t>(f.size());
        p.sample_rate = rate; p.frequency_hz = f.data(); p.main_real = mr.data(); p.main_imag = mi.data();
        p.sub_real = sr.data(); p.sub_imag = si.data(); p.seat_weight = w.data(); p.options = o;
    }
};

static void testCrossover() {
    for (double rate : kRates) {
        n60_speaker_crossover_options o;
        n60_speaker_crossover_defaults(&o);
        CHECK(n60_speaker_crossover_options_valid(&o, rate) == 1, "defaults valid at %g", rate);
        n60_speaker_crossover_options bad = o;
        bad.center_hz = 20;
        CHECK(n60_speaker_crossover_options_valid(&bad, rate) == 0, "centre below 35 Hz");
        bad = o; bad.frequency_point_count = 8;
        CHECK(n60_speaker_crossover_options_valid(&bad, rate) == 0, "too few points");
        double fq[32];
        CHECK(n60_speaker_crossover_frequencies(&o, fq, 32) == 0, "grid");
        CHECK(std::fabs(fq[0] - 80.0 / std::sqrt(2.0)) < 1e-9 && std::fabs(fq[31] - 80.0 * std::sqrt(2.0)) < 1e-9, "band edges");

        // Mains flat, sub arrives 3 ms late: delaying the mains by 3 ms makes the sum coherent (+6.02 dB over each source).
        Xover x;
        x.build(rate, 3, 0.003, 1.0);
        std::vector<double> bl(3), sel(3), pk(3);
        n60_speaker_crossover_result r{};
        r.baseline_level_db = bl.data(); r.selected_level_db = sel.data(); r.selected_peak_above_db = pk.data();
        CHECK(n60_speaker_crossover_search(&x.p, &r) == 0, "search");
        CHECK(r.accepted == 1 && std::fabs(r.delay_ms - 3.0) < 1e-9 && r.invert_sub_polarity == 0, "delay %g inv %u", r.delay_ms, r.invert_sub_polarity);
        CHECK(std::fabs(sel[0] - 10 * std::log10(4.0)) < 1e-9, "coherent level %g", sel[0]);
        CHECK(r.aggregate_improvement_db > 0.25 && std::fabs(r.maximum_sum_above_strongest_db - 10 * std::log10(4.0)) < 1e-9, "improvement");

        // Mains and sub in anti-phase: polarity inversion is the answer, at zero delay.
        x.build(rate, 2, 0.0, -1.0);
        bl.resize(2); sel.resize(2); pk.resize(2);
        r = {};
        r.baseline_level_db = bl.data(); r.selected_level_db = sel.data(); r.selected_peak_above_db = pk.data();
        n60_speaker_crossover_search(&x.p, &r);
        CHECK(r.accepted == 1 && r.delay_ms == 0.0 && r.invert_sub_polarity == 1, "polarity answer");
        CHECK(bl[0] < -200.0, "anti-phase baseline cancels %g", bl[0]);

        // Already coherent: nothing clears the improvement guard, selected equals baseline.
        x.build(rate, 2, 0.0, 1.0);
        r = {};
        r.baseline_level_db = bl.data(); r.selected_level_db = sel.data(); r.selected_peak_above_db = pk.data();
        n60_speaker_crossover_search(&x.p, &r);
        CHECK(r.accepted == 0 && r.delay_ms == 0.0 && r.aggregate_improvement_db == 0.0 && sel[0] == bl[0], "no benefit");
    }
}

static void testSensitivity(double rate) {
    Xover x;
    x.build(rate, 2, 0.003, 1.0);
    n60_speaker_sensitivity_options so;
    n60_speaker_sensitivity_defaults(&so);
    CHECK(n60_speaker_sensitivity_options_valid(&so) == 1, "defaults valid");
    n60_speaker_sensitivity_sample samples[9];
    n60_speaker_sensitivity_summary sum{};
    CHECK(n60_speaker_crossover_sensitivity(&x.p, 3.0, 0, &so, samples, &sum) == 0, "sensitivity");
    CHECK(samples[0].clock_offset_ms == -2.0 && samples[4].clock_offset_ms == 0.0 && samples[8].clock_offset_ms == 2.0, "offsets");
    // At zero assumed clock shift the hypothesis is the coherent sum against bypass: a gain.
    CHECK(samples[4].improvement_db > 0.25, "zero-shift gain %g", samples[4].improvement_db);
    // A 2 ms shift erases the gain at some assumed offset, so the worst case is below the zero-shift gain.
    CHECK(sum.worst_improvement_db < samples[4].improvement_db, "worst below nominal");
    so.sample_count = 4;
    CHECK(n60_speaker_crossover_sensitivity(&x.p, 3.0, 0, &so, samples, &sum) == N60_SPEAKER_ERR_SETTINGS, "even count refused");
}

static void testResponse() {
    const int n = 40;
    std::vector<double> grid(n), mag(2 * n, 6.0), ph(2 * n, 0.5);
    for (int i = 0; i < n; ++i) grid[i] = 20.0 * std::pow(2.0, i * 0.15);
    const double at[2] = {50.0, 200.0};
    double re[2], im[2];
    const double arrival = 0.004;
    CHECK(n60_speaker_crossover_response(grid.data(), n, 2, mag.data(), ph.data(), arrival, at, 2, re, im) == 0, "response");
    for (int k = 0; k < 2; ++k) {
        const double amp = std::pow(10.0, 6.0 / 20.0), phase = 0.5 - 2 * kPi * at[k] * arrival;
        CHECK(std::fabs(re[k] - amp * std::cos(phase)) < 1e-9 && std::fabs(im[k] - amp * std::sin(phase)) < 1e-9, "complex %d", k);
    }
    const double out_of_range[1] = {5.0};
    CHECK(n60_speaker_crossover_response(grid.data(), n, 2, mag.data(), ph.data(), arrival, out_of_range, 1, re, im) ==
              N60_SPEAKER_ERR_ARGUMENT, "outside the grid");
    std::vector<double> coarse = {20, 40, 80, 160};   // one-octave gaps exceed the 0.30 octave limit
    std::vector<double> cm(4, 0.0), cp(4, 0.0);
    CHECK(n60_speaker_crossover_response(coarse.data(), 4, 1, cm.data(), cp.data(), 0.0, at, 1, re, im) ==
              N60_SPEAKER_ERR_ARGUMENT, "coarse grid refused");
}

static std::vector<double> logGrid(double lo, double hi, int n) {
    std::vector<double> g(n);
    for (int i = 0; i < n; ++i) g[i] = lo * std::pow(hi / lo, i / double(n - 1));
    return g;
}

static void testClassifier(double rate) {
    const double sc = rate / 48000.0;
    const int n = 120;
    std::vector<double> f = logGrid(100 * sc, 4000 * sc, n);
    auto bump = [&](double centre, double gain) {
        std::vector<double> v(n);
        for (int i = 0; i < n; ++i) { const double d = std::log2(f[i] / centre) / 0.08; v[i] = gain * std::exp(-0.5 * d * d); }
        return v;
    };
    // Mean of interpolated captures: exact on a magnitude that is linear in log frequency.
    std::vector<double> g = logGrid(20 * sc, 20000 * sc, 50), m(100);
    for (int i = 0; i < 50; ++i) { m[i] = 3.0 * std::log2(g[i]); m[50 + i] = 3.0 * std::log2(g[i]) + 2.0; }
    double got[2];
    const double at[2] = {333.0 * sc, 5000.0 * sc};
    CHECK(n60_speaker_mean_interpolated(g.data(), 50, m.data(), 2, at, 2, got) == 0, "mean interpolated");
    for (int k = 0; k < 2; ++k) CHECK(std::fabs(got[k] - (3.0 * std::log2(at[k]) + 1.0)) < 1e-9, "linear-in-log value %g", got[k]);
    const double outside[1] = {10.0 * sc};
    CHECK(n60_speaker_mean_interpolated(g.data(), 50, m.data(), 2, outside, 1, got) == N60_SPEAKER_ERR_ARGUMENT, "outside");

    // Constant and log-linear magnitudes have no local shape residual away from the ends.
    std::vector<double> flat(n, -20.0), res(n);
    CHECK(n60_speaker_local_residual(f.data(), flat.data(), n, 1.0 / 3.0, res.data()) == 0, "residual");
    for (int i = 0; i < n; ++i) CHECK(std::fabs(res[i]) < 1e-12, "flat residual");

    const int mid = n / 2 - 1;
    auto classifyMid = [&](const std::vector<double> &near, const std::vector<std::vector<double>> &seats) {
        std::vector<double> seatFlat;
        for (const auto &s : seats) seatFlat.insert(seatFlat.end(), s.begin(), s.end());
        n60_speaker_cross_domain_problem p{};
        p.struct_size = sizeof p; p.point_count = n; p.seat_count = static_cast<uint32_t>(seats.size());
        p.frequency_hz = f.data(); p.characterization_db = near.data(); p.seat_db = seatFlat.data();
        n60_speaker_classify_defaults(&p.options);
        std::vector<n60_speaker_cross_domain_point> pts(n);
        CHECK(n60_speaker_cross_domain_classify(&p, pts.data()) == 0, "classify");
        return pts[mid];
    };
    // Find the bump centre bin so the label is read where the feature sits.
    const double centre = f[mid];
    auto b = bump(centre, 6.0);
    auto none = classifyMid(flat, {flat, flat});
    CHECK(none.classification == N60_SPEAKER_CLASS_NO_DEVIATION, "flat is no deviation (%u)", none.classification);
    auto persistent = classifyMid(b, {b, b, b});
    CHECK(persistent.classification == N60_SPEAKER_CLASS_PERSISTENT && persistent.listening_seat_spread_db < 1e-9, "persistent (%u)", persistent.classification);
    auto room = classifyMid(flat, {b, flat});
    CHECK(room.classification == N60_SPEAKER_CLASS_ROOM_SEAT && room.listening_seat_spread_db > 1.5, "room (%u spread %g)", room.classification, room.listening_seat_spread_db);
    auto ambiguous = classifyMid(b, {flat, flat});
    CHECK(ambiguous.classification == N60_SPEAKER_CLASS_AMBIGUOUS, "disagreement is ambiguous (%u)", ambiguous.classification);
    // Absolute level does not drive the labels: an offset on every seat leaves them unchanged.
    std::vector<double> loud(n);
    for (int i = 0; i < n; ++i) loud[i] = b[i] + 17.0;
    CHECK(classifyMid(b, {loud, loud}).classification == N60_SPEAKER_CLASS_PERSISTENT, "level offset ignored");
    n60_speaker_cross_domain_problem badp{};
    badp.struct_size = sizeof badp; badp.point_count = n; badp.seat_count = 1;
    badp.frequency_hz = f.data(); badp.characterization_db = flat.data(); badp.seat_db = flat.data();
    n60_speaker_classify_defaults(&badp.options);
    badp.options.smoothing_octaves = 5;
    std::vector<n60_speaker_cross_domain_point> pts(n);
    CHECK(n60_speaker_cross_domain_classify(&badp, pts.data()) == N60_SPEAKER_ERR_SETTINGS, "invalid options");
}

static void testEarlyWindow() {
    for (double rate : kRates) {
        const uint32_t count = static_cast<uint32_t>(rate * 0.06);
        std::vector<float> ir(count, 0.0f);
        const uint32_t arrival = static_cast<uint32_t>(rate * 0.01);
        ir[arrival] = 0.5f;
        const uint32_t late = arrival + static_cast<uint32_t>(rate * 0.011);   // beyond the 6 ms gate
        ir[late] = 0.5f;
        std::vector<double> tf = logGrid(20, std::fmin(20000, rate * 0.45), 200), mag(tf.size(), 0.0);
        n60_speaker_early_window_settings s;
        n60_speaker_early_window_defaults(&s);
        n60_speaker_early_window_result r{};
        CHECK(n60_speaker_early_window(ir.data(), count, rate, arrival / rate, 20.0, 20000.0, tf.data(),
                                       static_cast<uint32_t>(tf.size()), &s, mag.data(), &r) == 0, "window at %g", rate);
        const double post = std::llround(0.006 * rate) / rate;
        CHECK(std::fabs(r.retained_post_arrival_ms - post * 1000.0) < 1e-9, "retained post");
        CHECK(tf[r.first_index] >= 2.0 / post - 1e-9 && (r.first_index == 0 || tf[r.first_index - 1] < 2.0 / post), "gate-limited low edge");
        CHECK(r.count >= 8, "kept bins");
        // The late reflection is outside the gate, so the response is the direct delta alone: 0.5 is -6.02 dB, flat.
        for (uint32_t k = 0; k < r.count; ++k)
            CHECK(std::fabs(mag[r.first_index + k] - 20.0 * std::log10(0.5)) < 1e-9, "flat -6 dB at bin %u", k);
        // Errors.
        CHECK(n60_speaker_early_window(ir.data(), count, rate, 1.0, 20.0, 20000.0, tf.data(), static_cast<uint32_t>(tf.size()), &s,
                                       mag.data(), &r) == N60_SPEAKER_ERR_ARRIVAL, "arrival outside");
        CHECK(n60_speaker_early_window(ir.data(), count, rate, (count - 2) / rate, 20.0, 20000.0, tf.data(),
                                       static_cast<uint32_t>(tf.size()), &s, mag.data(), &r) == N60_SPEAKER_ERR_SHORT, "short");
        CHECK(n60_speaker_early_window(ir.data(), count, rate, arrival / rate, 18000.0, 100.0, tf.data(),
                                       static_cast<uint32_t>(tf.size()), &s, mag.data(), &r) == N60_SPEAKER_ERR_BAND, "no band");
        n60_speaker_early_window_settings bad = s;
        bad.post_arrival_ms = 1.0;
        CHECK(n60_speaker_early_window(ir.data(), count, rate, arrival / rate, 20.0, 20000.0, tf.data(),
                                       static_cast<uint32_t>(tf.size()), &bad, mag.data(), &r) == N60_SPEAKER_ERR_SETTINGS, "settings");
    }
}

static void testPreview(double rate) {
    const double sc = rate / 48000.0;
    const int n = 150;
    std::vector<double> f = logGrid(50 * sc, 10000 * sc, n);
    std::vector<double> flat(n, -10.0), bump(n);
    for (int i = 0; i < n; ++i) { const double d = std::log2(f[i] / (1000.0 * sc)) / 0.1; bump[i] = -10.0 + 5.0 * std::exp(-0.5 * d * d); }
    std::vector<double> target(n), corr(n);
    n60_speaker_preview_problem p{};
    p.struct_size = sizeof p; p.bin_count = n; p.seat_count = 1; p.frequency_hz = f.data();
    double w1 = 1.0;
    p.seat_weight = &w1;
    n60_speaker_preview_defaults(&p.options);
    n60_speaker_preview_result r{};
    r.target_db = target.data(); r.correction_db = corr.data();

    p.seat_db = flat.data();
    CHECK(n60_speaker_design_preview(&p, &r) == 0, "flat");
    CHECK(r.rmse_before_db == 0.0 && r.rmse_after_db < 1e-12, "flat stays flat");
    for (int i = 0; i < n; ++i) CHECK(std::fabs(corr[i]) < 1e-12 && target[i] == -10.0, "unity");

    p.seat_db = bump.data();
    CHECK(n60_speaker_design_preview(&p, &r) == 0, "bump");
    double lo = 0, hi = 0;
    for (int i = 0; i < n; ++i) { lo = std::fmin(lo, corr[i]); hi = std::fmax(hi, corr[i]); }
    CHECK(hi == 0.0 && lo < -1.0 && lo >= -6.0, "cut only, bounded: %g .. %g", lo, hi);
    CHECK(r.rmse_after_db < r.rmse_before_db && r.reverted == 0, "bump improved");
    p.options.maximum_cut_db = 0.5;
    n60_speaker_design_preview(&p, &r);
    lo = 0;
    for (int i = 0; i < n; ++i) lo = std::fmin(lo, corr[i]);
    CHECK(std::fabs(lo + 0.5) < 1e-12, "cut limit %g", lo);
    p.options.maximum_cut_db = 6.0;
    p.options.target_tilt_db_per_octave = 1.0;
    n60_speaker_design_preview(&p, &r);
    CHECK(std::fabs((target[n - 1] - target[0]) - std::log2(f[n - 1] / f[0])) < 1e-9, "tilt");
    p.options.target_tilt_db_per_octave = 0.0;

    // A bump on one seat only: cutting it worsens the flat seat, and a zero degradation limit reverts to unity.
    std::vector<double> two(2 * n);
    for (int i = 0; i < n; ++i) { two[i] = bump[i]; two[n + i] = flat[i]; }
    const double w2[2] = {0.5, 0.5};
    p.seat_count = 2; p.seat_db = two.data(); p.seat_weight = w2;
    p.options.maximum_seat_degradation_db = 0.0;
    CHECK(n60_speaker_design_preview(&p, &r) == 0, "two seats");
    CHECK(r.reverted == 1 && r.rmse_after_db == r.rmse_before_db, "reverted");
    for (int i = 0; i < n; ++i) CHECK(corr[i] == 0.0, "unity after revert");
    p.options.maximum_cut_db = 20.0;
    CHECK(n60_speaker_design_preview(&p, &r) == N60_SPEAKER_ERR_SETTINGS, "invalid options");
}

int main() {
    CHECK(n60_speaker_abi_version() == N60_SPEAKER_ABI_VERSION && N60_SPEAKER_ABI_VERSION >= 2u, "abi");
    testCrossover();
    testResponse();
    // Classifier, sensitivity and preview scoring: frequency grids scale with the rate so each rate exercises its own band.
    for (double rate : kRates) { testSensitivity(rate); testClassifier(rate); testPreview(rate); }
    testEarlyWindow();
    if (failures == 0) std::printf("speaker s9b ok\n");
    return failures == 0 ? 0 : 1;
}
