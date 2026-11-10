// E19 S1: predicted treated IR (n60_measure_predict_treated_ir) and per-source modes in the multi-source
// reference room, at the eight standard rates.
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
constexpr double kPi = 3.14159265358979323846;
constexpr double kLn1000 = 6.907755278982137;

// A quiet room: modes only (no diffuse tail, reflections, seat variation), so the analytic mode decay is the truth.
static n60_measure_multiroom_params modalRoom(double fs, uint32_t sources, double seconds) {
    n60_measure_multiroom_params p;
    n60_measure_multiroom_defaults(fs, &p);
    p.source_count = sources;
    p.seat_count = 1;
    p.base.ir_seconds = seconds;
    p.base.diffuse_level_db = -200.0;
    p.modal_variation = 0.0;
    p.reflection_count = 0;
    return p;
}

static void setMode(n60_measure_multiroom_params &p, int m, double hz, double decay) {
    const double alpha = kLn1000 / (decay * p.base.sample_rate);
    p.base.mode_frequencies_hz[m] = hz;
    p.base.mode_decay_seconds[m] = decay;
    // Spectral peak A / (2 alpha) = 100 x the direct sound: a strong resonance, so the mode (not the direct
    // impulse's ring in the band filter) sets the decay slope.
    p.base.mode_level_db[m] = 20.0 * std::log10(100.0 * 2.0 * alpha / p.base.direct_gain);
}

static std::vector<float> plant(const n60_measure_multiroom_params &p, uint32_t source) {
    uint64_t len = 0;
    CHECK(n60_measure_multiroom_ir_length(&p, &len) == 0, "ir length");
    std::vector<float> ir(len);
    uint64_t n = 0;
    CHECK(n60_measure_multiroom_ir(&p, source, 0, ir.data(), len, &n) == 0 && n == len, "ir");
    return ir;
}

static std::vector<float> predict(const std::vector<std::vector<float>> &plants, const std::vector<std::vector<float>> &filters,
                                  int expectStatus = 0) {
    std::vector<const float *> pp, fp;
    std::vector<uint64_t> pc, fc;
    for (size_t s = 0; s < plants.size(); ++s) {
        pp.push_back(plants[s].data()); pc.push_back(plants[s].size());
        fp.push_back(filters[s].data()); fc.push_back(filters[s].size());
    }
    uint64_t len = 0;
    CHECK(n60_measure_predict_treated_length(static_cast<uint32_t>(plants.size()), pc.data(), fc.data(), &len) == 0, "length");
    std::vector<float> out(len);
    uint64_t n = 0;
    const int32_t st = n60_measure_predict_treated_ir(static_cast<uint32_t>(plants.size()), pp.data(), pc.data(), fp.data(), fc.data(),
                                                      out.data(), len, &n);
    CHECK(st == expectStatus, "predict status %d want %d", st, expectStatus);
    CHECK(st != 0 || n == len, "count");
    return out;
}

static void testIdentity() {
    for (double fs : kRates) {
        n60_measure_multiroom_params room;
        n60_measure_multiroom_defaults(fs, &room);
        room.source_count = 3;
        room.seat_count = 1;
        room.base.ir_seconds = 0.3;
        room.source_delay_seconds[1] = 0.0007;
        room.source_delay_seconds[2] = 0.0013;
        std::vector<std::vector<float>> plants, filters;
        for (uint32_t s = 0; s < 3; ++s) { plants.push_back(plant(room, s)); filters.push_back({1.0f}); }
        const std::vector<float> out = predict(plants, filters);
        double worst = 0, peak = 0;
        for (size_t i = 0; i < out.size(); ++i) {
            double sum = 0;
            for (auto &p : plants) if (i < p.size()) sum += p[i];
            peak = std::max(peak, std::fabs(sum));
            worst = std::max(worst, std::fabs(static_cast<double>(out[i]) - static_cast<double>(static_cast<float>(sum))));
        }
        CHECK(out.size() == plants[0].size(), "fs %.0f identity keeps the length", fs);
        // The sum is formed in double and rounded once to float: it matches the float-rounded sum, bar one ulp.
        CHECK(worst <= 1.2e-7 * peak, "fs %.0f identity error %.3g (peak %.3g)", fs, worst, peak);
    }
}

static void testKnownFilter() {
    for (double fs : kRates) {
        n60_measure_multiroom_params room;
        n60_measure_multiroom_defaults(fs, &room);
        room.source_count = 3;
        room.seat_count = 1;
        room.base.ir_seconds = 0.25;
        room.source_delay_seconds[1] = 0.0011;
        std::vector<std::vector<float>> plants, filters;
        const uint64_t taps = 1500;
        for (uint32_t s = 0; s < 3; ++s) {
            plants.push_back(plant(room, s));
            std::vector<float> f(taps);
            for (uint64_t k = 0; k < taps; ++k)
                f[k] = static_cast<float>((s == 1 ? -0.8 : 0.6 + 0.2 * s) * std::exp(-4.0 * k / taps) * std::cos(0.05 * (s + 1) * k));
            filters.push_back(f);
        }
        const std::vector<float> out = predict(plants, filters);
        std::vector<double> ref(out.size(), 0.0);
        for (size_t s = 0; s < 3; ++s)
            for (size_t i = 0; i < plants[s].size(); ++i) {
                const double x = plants[s][i];
                if (x == 0.0) continue;
                for (size_t k = 0; k < filters[s].size(); ++k) ref[i + k] += x * filters[s][k];
            }
        double peak = 0, err = 0;
        for (double v : ref) peak = std::max(peak, std::fabs(v));
        for (size_t i = 0; i < out.size(); ++i) err = std::max(err, std::fabs(out[i] - ref[i]));
        CHECK(out.size() == plants[0].size() + taps - 1, "fs %.0f length %zu", fs, out.size());
        CHECK(err <= 1e-6 * peak, "fs %.0f error %.1f dB re peak", fs, 20.0 * std::log10(err / peak));
    }
}

static void testMixedAndArguments() {
    std::vector<std::vector<float>> plants = {{1, 0, 0.5f, 0}, {0, 1, 0, 0, 0.25f}};
    std::vector<std::vector<float>> filters = {{0.0f}, {1, 1}};  // source 0 excluded (single tap 0), source 1 two taps
    const std::vector<float> out = predict(plants, filters);
    const float want[6] = {0, 1, 1, 0, 0.25f, 0.25f};
    CHECK(out.size() == 6, "mixed length %zu", out.size());
    for (size_t i = 0; i < out.size() && i < 6; ++i) CHECK(std::fabs(out[i] - want[i]) < 1e-6, "mixed [%zu] %f", i, out[i]);

    const float one = 1.0f;
    const float *pp[1] = {&one}, *fp[1] = {&one};
    const uint64_t c1[1] = {1}, c0[1] = {0};
    float o[4];
    uint64_t n = 0;
    CHECK(n60_measure_predict_treated_ir(1, pp, c1, fp, c1, o, 4, &n) == 0 && n == 1 && o[0] == 1.0f, "one sample");
    CHECK(n60_measure_predict_treated_ir(0, pp, c1, fp, c1, o, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "no sources");
    CHECK(n60_measure_predict_treated_ir(9, pp, c1, fp, c1, o, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "too many sources");
    CHECK(n60_measure_predict_treated_ir(1, pp, c0, fp, c1, o, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "empty plant");
    CHECK(n60_measure_predict_treated_ir(1, pp, c1, fp, c0, o, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "empty filter");
    const float nan = std::nanf("");
    const float *np[1] = {&nan};
    CHECK(n60_measure_predict_treated_ir(1, np, c1, fp, c1, o, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "non-finite plant");
    const float two[2] = {1, 1};
    const float *fp2[1] = {two};
    const uint64_t c2[1] = {2};
    CHECK(n60_measure_predict_treated_ir(1, pp, c1, fp2, c2, o, 1, &n) == N60_MEASURE_ERR_CAPACITY, "capacity");
    CHECK(n60_measure_predict_treated_ir(1, pp, c1, fp, c1, nullptr, 4, &n) == N60_MEASURE_ERR_ARGUMENT, "null out");
}

static void testModeDecay() {
    // Four modes at exact third-octave centres, an octave apart, with different decay times.
    const double sets[3][4] = {{25.119, 50.119, 100.0, 158.489}, {31.623, 63.096, 125.893, 0.0}, {39.811, 79.433, 0.0, 0.0}};
    const double decays[4] = {1.2, 0.9, 0.6, 0.45};
    for (double fs : kRates) {
        for (int set = 0; set < 3; ++set) {
            n60_measure_multiroom_params room = modalRoom(fs, 1, 3.0);
            for (int m = 0; m < 4; ++m) {
                if (sets[set][m] > 0) setMode(room, m, sets[set][m], decays[m]);
                else room.base.mode_frequencies_hz[m] = 0.0;
            }
            std::vector<std::vector<float>> plants = {plant(room, 0)}, filters = {{1.0f}};
            const std::vector<float> out = predict(plants, filters);
            n60_measure_decay_band bands[32];
            uint32_t count = 0;
            CHECK(n60_measure_decay_analyze(out.data(), out.size(), fs, N60_MEASURE_DECAY_THIRD_OCTAVE, 25.0, 160.0, bands, 32, &count) == 0,
                  "decay analyze");
            for (int m = 0; m < 4; ++m) {
                if (sets[set][m] <= 0) continue;
                const n60_measure_decay_band *band = nullptr;
                for (uint32_t b = 0; b < count; ++b) if (std::fabs(bands[b].centre_hz / sets[set][m] - 1.0) < 0.02) band = &bands[b];
                CHECK(band != nullptr, "fs %.0f no band for %.1f Hz", fs, sets[set][m]);
                if (band == nullptr) continue;
                CHECK(band->t30_seconds > 0 && std::fabs(band->t30_seconds / decays[m] - 1.0) < 0.05,
                      "fs %.0f %.1f Hz T30 %.3f want %.3f", fs, sets[set][m], band->t30_seconds, decays[m]);
            }
        }
    }
}

static void testTwoSourcesCancelAMode() {
    for (double fs : kRates) {
        n60_measure_multiroom_params room = modalRoom(fs, 2, 1.0);
        setMode(room, 0, 52.0, 0.9);
        setMode(room, 1, 87.0, 0.7);
        for (int m = 0; m < 4; ++m) {
            room.source_mode_gain[0][m] = 1.0; room.source_mode_phase_rad[0][m] = 0.0;
            room.source_mode_gain[1][m] = 1.0; room.source_mode_phase_rad[1][m] = 0.0;
        }
        const std::vector<float> filt = {1.0f};
        auto treated = [&](const n60_measure_multiroom_params &r) {
            return predict({plant(r, 0), plant(r, 1)}, {filt, filt});
        };
        const std::vector<float> inPhase = treated(room);
        // Source 1 drives the 52 Hz mode in antiphase (gain 1, phase pi): that mode cancels, the 87 Hz one stays.
        n60_measure_multiroom_params anti = room;
        anti.source_mode_phase_rad[1][0] = kPi;
        const std::vector<float> cancelled = treated(anti);
        // Reference: both sources silent in mode 0 (gain 0) with mode 1 as before.
        n60_measure_multiroom_params off = room;
        off.source_mode_gain[0][0] = 0.0;
        off.source_mode_gain[1][0] = 0.0;
        const std::vector<float> reference = treated(off);
        double peak = 0, err = 0, kept = 0;
        for (size_t i = 0; i < inPhase.size(); ++i) {
            peak = std::max(peak, std::fabs(static_cast<double>(inPhase[i])));
            err = std::max(err, std::fabs(static_cast<double>(cancelled[i]) - reference[i]));
            kept = std::max(kept, std::fabs(static_cast<double>(inPhase[i]) - reference[i]));
        }
        CHECK(kept > 1e-3 * peak, "fs %.0f the mode is audible in phase (%.3g, peak %.3g)", fs, kept, peak);
        CHECK(err < 1e-5 * peak, "fs %.0f antiphase mode residue %.3g (peak %.3g)", fs, err, peak);
        // Gain scales the mode linearly: half gain from source 1 leaves half of one source's mode.
        n60_measure_multiroom_params half = room;
        half.source_mode_gain[0][0] = 0.0;
        half.source_mode_gain[1][0] = 0.5;
        const std::vector<float> halfMode = treated(half);
        n60_measure_multiroom_params full = room;
        full.source_mode_gain[0][0] = 0.0;
        full.source_mode_gain[1][0] = 1.0;
        const std::vector<float> fullMode = treated(full);
        double errHalf = 0;
        for (size_t i = 0; i < halfMode.size(); ++i)
            errHalf = std::max(errHalf, std::fabs(static_cast<double>(halfMode[i]) - 0.5 * fullMode[i] - 0.5 * reference[i]));
        CHECK(errHalf < 1e-5 * peak, "fs %.0f mode gain linear: %.3g", fs, errHalf);
    }
}

int main() {
    CHECK(n60_measure_abi_version() == N60_MEASURE_ABI_VERSION && N60_MEASURE_ABI_VERSION == 4, "abi");
    testIdentity();
    testKnownFilter();
    testMixedAndArguments();
    testModeDecay();
    testTwoSourcesCancelAMode();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("measure predict tests passed");
    return 0;
}
