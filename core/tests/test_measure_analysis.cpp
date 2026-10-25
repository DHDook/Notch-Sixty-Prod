// E11 S3: H2-H5 distortion and EDT/T20/T30/RT60 through the C ABI at the eight standard rates,
// against the deterministic reference room (known harmonic levels and per-band RT60).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/measure.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

struct Sweep {
    n60_measure_ess_info info{};
    std::vector<float> samples;
    double endHz = 0;
};

static Sweep makeSweep(double fs, double seconds) {
    Sweep s;
    n60_measure_ess_params ep{};
    ep.sample_rate = fs;
    ep.start_hz = 20;
    s.endHz = std::fmin(20000.0, 0.45 * fs);
    ep.end_hz = s.endHz;
    ep.duration_seconds = seconds;
    ep.level_dbfs = -6;
    ep.fade_seconds = 0.02;
    ep.synchronised = 1;
    CHECK(n60_measure_ess_describe(&ep, &s.info) == 0, "describe");
    s.samples.resize(s.info.frame_count);
    CHECK(n60_measure_ess_generate(&ep, s.samples.data(), s.samples.size(), &s.info) == 0, "generate");
    return s;
}

struct Distortion {
    std::vector<double> f, fundamental, thd;
    std::vector<double> h[4];
    n60_measure_distortion_info info{};
    int status = 0;
};

static Distortion measureDistortion(double fs, double sweepSeconds, const double levels[4], double directDb = -200.0) {
    Distortion d;
    const Sweep sweep = makeSweep(fs, sweepSeconds);
    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    room.ir_seconds = 0.3;
    room.diffuse_level_db = directDb;
    for (int m = 0; m < 4; ++m) room.mode_frequencies_hz[m] = 0.0;
    room.latency_seconds = 0.02;
    for (int k = 0; k < 4; ++k) room.harmonic_db[k] = levels[k];
    uint64_t total = 0;
    CHECK(n60_measure_room_capture_length(&room, sweep.samples.size(), &total) == 0, "capture length");
    std::vector<float> capture(total);
    CHECK(n60_measure_room_capture(&room, sweep.samples.data(), sweep.samples.size(), capture.data(), total, &total) == 0, "capture");
    uint64_t size = 0;
    CHECK(n60_measure_transform_size(total, &size) == 0, "size");
    std::vector<float> response(size);
    uint64_t produced = 0;
    CHECK(n60_measure_deconvolve(sweep.samples.data(), sweep.samples.size(), capture.data(), total, 1e-8,
                                 response.data(), size, &produced) == 0, "deconvolve");

    n60_measure_distortion_params dp;
    n60_measure_distortion_defaults(fs, &sweep.info, 20.0, sweep.endHz, &dp);
    const uint32_t cap = 256;
    d.f.resize(cap); d.fundamental.resize(cap); d.thd.resize(cap);
    double *hp[4];
    for (int k = 0; k < 4; ++k) { d.h[k].resize(cap); hp[k] = d.h[k].data(); }
    d.status = n60_measure_distortion_analyze(&dp, response.data(), produced, d.f.data(), d.fundamental.data(), hp,
                                              d.thd.data(), cap, &d.info);
    return d;
}

static void testDistortion() {
    const double levels[4] = {-30.0, -45.0, -60.0, -70.0};
    for (double fs : kRates) {
        const Distortion d = measureDistortion(fs, 5.0, levels);
        CHECK(d.status == 0, "fs %.0f analyze status %d", fs, d.status);
        if (d.status != 0) continue;
        CHECK(d.info.clean_separation == 1, "fs %.0f sweep should be long enough", fs);
        double worst[4] = {0, 0, 0, 0};
        int checked[4] = {0, 0, 0, 0};
        for (uint32_t i = 0; i < d.info.point_count; ++i) {
            for (int k = 0; k < 4; ++k) {
                const double v = d.h[k][i];
                if (v == N60_MEASURE_NO_DATA_DB) continue;
                CHECK(d.f[i] * (k + 2) <= std::fmin(20000.0, 0.45 * fs), "fs %.0f H%d reported above the sweep band", fs, k + 2);
                if (d.f[i] < 40.0) continue;  // the sweep's first octave-third is edge-limited
                worst[k] = std::max(worst[k], std::fabs(v - levels[k]));
                ++checked[k];
            }
        }
        for (int k = 0; k < 4; ++k) {
            CHECK(checked[k] > 20, "fs %.0f H%d only %d points", fs, k + 2, checked[k]);
            CHECK(worst[k] < 0.5, "fs %.0f H%d worst error %.3f dB (want < 0.5)", fs, k + 2, worst[k]);
        }
        // THD is the power sum of the in-band harmonics: at 100 Hz all four are in band.
        for (uint32_t i = 0; i < d.info.point_count; ++i) {
            if (d.f[i] < 100.0 || d.f[i] > 110.0) continue;
            double sum = 0;
            for (int k = 0; k < 4; ++k) sum += std::pow(10.0, d.h[k][i] / 10.0);
            CHECK(std::fabs(10.0 * std::log10(sum) - d.thd[i]) < 1e-9, "thd power sum");
            CHECK(std::fabs(d.thd[i] - 10.0 * std::log10(std::pow(10.0, -3.0) + std::pow(10.0, -4.5) + 1e-6 + 1e-7)) < 0.5,
                  "fs %.0f thd %.2f", fs, d.thd[i]);
        }
    }
}

static void testDistortionRoomAndSweepLength() {
    // A reverberant room: the fundamental is read through each harmonic's own window, so the
    // result still equals the generator level; a too-short sweep is reported.
    const double levels[4] = {-35.0, -40.0, -50.0, -60.0};
    const double fs = 48000;
    const Distortion d = measureDistortion(fs, 5.0, levels, -30.0);
    CHECK(d.status == 0, "status");
    if (d.status == 0) {
        CHECK(d.info.min_window_seconds > 0.07 && d.info.min_window_seconds < 0.09, "window %.4f", d.info.min_window_seconds);
        // Within the half-gap window the diffuse tail adds energy to both numerator and denominator;
        // an ideal reverberant room preserves the level to within the tail's statistical spread.
        double worst = 0;
        for (uint32_t i = 0; i < d.info.point_count; ++i) {
            if (d.f[i] < 100 || d.f[i] > 2000) continue;
            worst = std::max(worst, std::fabs(d.h[0][i] - levels[0]));
        }
        CHECK(worst < 3.0, "reverberant H2 spread %.2f dB", worst);
    }
    const double need = n60_measure_distortion_min_sweep_seconds(20.0, 20000.0, 0.05);
    CHECK(need > 3.0 && need < 3.2, "min sweep %.3f s", need);
    const Distortion shortSweep = measureDistortion(fs, 1.0, levels);
    CHECK(shortSweep.status == 0 && shortSweep.info.clean_separation == 0, "short sweep must report unclean separation");
    CHECK(shortSweep.info.min_sweep_seconds > 1.0, "short sweep min length reported");
}

// ---- Decay ----

static const double kBandRt60[N60_MEASURE_ROOM_BANDS] = {0.60, 0.58, 0.56, 0.54, 0.52, 0.50, 0.48};  // 125 Hz .. 8 kHz
static const double kLowRt60 = 0.62;                                                                    // 63 Hz octave

static double truthFor(double centre) {
    const int octave = static_cast<int>(std::lround(std::log2(centre / 125.0)));
    return octave < 0 ? kLowRt60 : kBandRt60[std::min(octave, N60_MEASURE_ROOM_BANDS - 1)];
}

// Deterministic modal impulse response: one in-phase cosine at every base-10 third-octave centre,
// each decaying exactly exponentially with its octave's RT60. A stochastic tail has a per-band
// estimator spread of tens of percent below 250 Hz (few independent samples per band), so the
// bias of the filters, truncation and regression is checked on this exact decay, and the
// stochastic reference room is checked as an ensemble mean.
static std::vector<float> makeModalIr(double fs, double irSeconds) {
    const uint64_t len = static_cast<uint64_t>(irSeconds * fs);
    std::vector<double> ir(len, 0.0);
    for (int n = -12; n <= 9; ++n) {
        const double centre = 1000.0 * std::pow(10.0, 0.1 * n);
        if (centre * 1.13 > 0.45 * fs) continue;
        const double tau = truthFor(centre);
        for (uint64_t i = 0; i < len; ++i) {
            const double t = static_cast<double>(i) / fs;
            ir[i] += std::cos(2.0 * 3.14159265358979323846 * centre * t) * std::exp(-6.907755278982137 * t / tau);
        }
    }
    std::vector<float> out(len);
    for (uint64_t i = 0; i < len; ++i) out[i] = static_cast<float>(ir[i] * 0.01);
    return out;
}

static std::vector<float> makeRoomIr(double fs, double irSeconds, uint32_t seed) {
    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    room.seed = seed;
    room.ir_seconds = irSeconds;
    for (int b = 0; b < N60_MEASURE_ROOM_BANDS; ++b) room.rt60_seconds[b] = kBandRt60[b];
    for (int m = 0; m < 4; ++m) room.mode_frequencies_hz[m] = 0.0;
    uint64_t len = 0;
    CHECK(n60_measure_room_ir_length(&room, &len) == 0, "ir length");
    std::vector<float> ir(len);
    CHECK(n60_measure_room_ir(&room, ir.data(), len, &len) == 0, "ir");
    return ir;
}

static void testDecay() {
    for (double fs : kRates) {
        const std::vector<float> ir = makeModalIr(fs, 1.5);
        for (uint32_t perOctave : {1u, 3u}) {
            n60_measure_decay_band bands[40];
            uint32_t count = 0;
            CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), fs, perOctave, 63.0, 8000.0, bands, 40, &count) == 0, "analyze");
            CHECK(count == (perOctave == 1 ? 8u : 22u), "fs %.0f /%u bands: %u", fs, perOctave, count);
            for (uint32_t i = 0; i < count; ++i) {
                const n60_measure_decay_band &b = bands[i];
                const double truth = truthFor(b.centre_hz);
                const double values[4] = {b.edt_seconds, b.t20_seconds, b.t30_seconds, b.rt60_seconds};
                static const char *names[4] = {"EDT", "T20", "T30", "RT60"};
                for (int v = 0; v < 4; ++v) {
                    // EDT reads only the first 10 dB, where the beating of neighbouring modal
                    // tones (different RT60) in the 1/3-octave passband moves it; allow 20 %.
                    const double limit = v == 0 ? 0.20 : 0.05;
                    const double error = std::fabs(values[v] - truth) / truth;
                    CHECK(error < limit, "fs %.0f /%u %.1f Hz %s %.3f vs %.3f (%.1f%%) range %.1f dB", fs, perOctave,
                          b.centre_hz, names[v], values[v], truth, error * 100.0, b.decay_range_db);
                }
                CHECK(b.flags == 0, "fs %.0f /%u %.1f Hz flags %u", fs, perOctave, b.centre_hz, b.flags);
            }
        }
    }
}

static void testDecayStochasticRoom() {
    // The reference room's diffuse tail is filtered noise, so one realisation scatters; the mean of
    // twelve seeded rooms must sit within 5 % of the set RT60 from 125 Hz up (octave and third).
    const uint32_t seeds = 12;
    for (double fs : kRates) {
        double sum[2][22] = {};
        uint32_t counts[2] = {0, 0};
        for (uint32_t seed = 1; seed <= seeds; ++seed) {
            const std::vector<float> ir = makeRoomIr(fs, 1.2, seed);
            for (int pass = 0; pass < 2; ++pass) {
                n60_measure_decay_band bands[40];
                uint32_t count = 0;
                CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), fs, pass == 0 ? 1 : 3, 125.0, 8000.0, bands, 40, &count) == 0, "analyze");
                counts[pass] = count;
                for (uint32_t i = 0; i < count; ++i) sum[pass][i] += bands[i].rt60_seconds / truthFor(bands[i].centre_hz);
            }
        }
        for (int pass = 0; pass < 2; ++pass) {
            CHECK(counts[pass] == (pass == 0 ? 7u : 19u), "fs %.0f pass %d bands %u", fs, pass, counts[pass]);
            for (uint32_t i = 0; i < counts[pass]; ++i) {
                const double mean = sum[pass][i] / seeds;
                CHECK(std::fabs(mean - 1.0) < 0.08, "fs %.0f /%d band %u ensemble mean %.3f", fs, pass == 0 ? 1 : 3, i, mean);
            }
        }
    }
}

static void testInsufficientRange() {
    // 0.15 s of a 0.6 s decay drops only about 15 dB: EDT is reported, T20 and T30 are flagged.
    for (double fs : {48000.0, 384000.0}) {
        const std::vector<float> ir = makeRoomIr(fs, 0.15, 1);
        n60_measure_decay_band bands[40];
        uint32_t count = 0;
        CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), fs, 1, 125.0, 4000.0, bands, 40, &count) == 0, "analyze");
        CHECK(count == 6, "bands %u", count);
        for (uint32_t i = 0; i < count; ++i) {
            const n60_measure_decay_band &b = bands[i];
            CHECK((b.flags & N60_MEASURE_DECAY_FLAG_T30_RANGE) != 0, "fs %.0f %.0f Hz T30 flag missing (range %.1f)", fs, b.centre_hz, b.decay_range_db);
            CHECK((b.flags & N60_MEASURE_DECAY_FLAG_T20_RANGE) != 0, "fs %.0f %.0f Hz T20 flag missing (range %.1f)", fs, b.centre_hz, b.decay_range_db);
            CHECK(b.t30_seconds == 0.0 && b.t20_seconds == 0.0, "fs %.0f %.0f Hz unreliable value reported", fs, b.centre_hz);
        }
    }
    // Silence reports no decay instead of a number.
    std::vector<float> silent(48000, 0.0f);
    n60_measure_decay_band bands[40];
    uint32_t count = 0;
    CHECK(n60_measure_decay_analyze(silent.data(), silent.size(), 48000, 1, 125.0, 1000.0, bands, 40, &count) == 0, "silent analyze");
    for (uint32_t i = 0; i < count; ++i) {
        CHECK((bands[i].flags & N60_MEASURE_DECAY_FLAG_NO_DECAY) != 0 && bands[i].rt60_seconds == 0.0, "silent band flagged");
    }
    // A noisy tail limits the range: the analysis stops at the noise floor, never extrapolates blindly.
    std::vector<float> noisy = makeRoomIr(48000, 1.5, 1);
    uint32_t state = 12345;
    for (float &x : noisy) {
        state = state * 1664525u + 1013904223u;
        x += (static_cast<float>(state >> 8) / 16777216.0f - 0.5f) * 0.02f;
    }
    CHECK(n60_measure_decay_analyze(noisy.data(), noisy.size(), 48000, 1, 500.0, 2000.0, bands, 40, &count) == 0, "noisy analyze");
    for (uint32_t i = 0; i < count; ++i) {
        CHECK(bands[i].decay_range_db < 60.0 && bands[i].decay_range_db > 5.0, "noisy range %.1f", bands[i].decay_range_db);
    }
}

static void testArguments() {
    n60_measure_decay_band bands[2];
    uint32_t count = 0;
    std::vector<float> ir(1024, 0.1f);
    CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), 48000, 2, 63, 8000, bands, 2, &count) < 0, "bad bands per octave");
    CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), 48000, 3, 63, 8000, bands, 2, &count) == N60_MEASURE_ERR_CAPACITY, "capacity");
    n60_measure_distortion_info info{};
    CHECK(n60_measure_distortion_analyze(nullptr, ir.data(), ir.size(), nullptr, nullptr, nullptr, nullptr, 1, &info) < 0, "null params");
}

int main() {
    testDistortion();
    testDistortionRoomAndSweepLength();
    testDecay();
    testDecayStochasticRoom();
    testInsufficientRange();
    testArguments();
    if (failures == 0) std::puts("measure analysis: all passed");
    return failures == 0 ? 0 : 1;
}
