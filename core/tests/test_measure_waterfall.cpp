// E11 S4: waterfall (CSD) and spectrogram through the C ABI at the eight standard rates.
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
static const double kPi = 3.14159265358979323846;

// h(t) = exp(-t / tau) sin(2 pi f0 t), starting at `lead` frames.
static std::vector<float> resonance(double fs, double f0, double tau, double seconds, uint64_t lead) {
    std::vector<float> h(lead + static_cast<uint64_t>(seconds * fs), 0.0f);
    for (uint64_t i = lead; i < h.size(); ++i) {
        const double t = static_cast<double>(i - lead) / fs;
        h[i] = static_cast<float>(std::exp(-t / tau) * std::sin(2.0 * kPi * f0 * t));
    }
    return h;
}

static void testWaterfallDecayRate(double fs, uint32_t room, double f0, double tau, double irSeconds) {
    const uint64_t lead = 200;
    const std::vector<float> ir = resonance(fs, f0, tau, irSeconds, lead);
    n60_measure_waterfall_params p;
    n60_measure_waterfall_defaults(fs, room, &p);
    p.arrival_index = lead;
    n60_measure_waterfall_info info{};
    CHECK(n60_measure_waterfall_describe(&p, &info) == 0, "describe");
    std::vector<double> f(info.point_count), db(static_cast<size_t>(info.point_count) * info.slice_count);
    const int status = n60_measure_waterfall_analyze(&p, ir.data(), ir.size(), f.data(), db.data(), db.size(), &info);
    CHECK(status == 0, "fs %.0f room %u status %d", fs, room, status);
    if (status != 0) return;
    uint32_t centre = 0;
    for (uint32_t k = 0; k < info.point_count; ++k) {
        if (std::fabs(std::log2(f[k] / f0)) < std::fabs(std::log2(f[centre] / f0))) centre = k;
    }
    double peak = -1e9;
    for (uint32_t k = 0; k < info.point_count; ++k) peak = std::max(peak, db[k]);
    CHECK(std::fabs(db[centre] - peak) < 1.5, "fs %.0f slice 0 peaks near the resonance (%.2f vs %.2f)", fs, db[centre], peak);
    const double perSlice = -8.685889638 * p.step_seconds / tau;
    double worst = 0;
    for (uint32_t s = 1; s < info.slice_count; ++s) {
        const double got = db[static_cast<size_t>(s) * info.point_count + centre] - db[centre];
        worst = std::max(worst, std::fabs(got - perSlice * s));
    }
    CHECK(worst < 0.4, "fs %.0f room %u decay error %.3f dB (rate %.3f dB/slice)", fs, room, worst, perSlice);
}

static void testWaterfall() {
    for (double fs : kRates) testWaterfallDecayRate(fs, 0, 1000.0, 0.003, 0.1);
    testWaterfallDecayRate(48000, 1, 1000.0, 0.1, 1.5);
    testWaterfallDecayRate(96000, 1, 250.0, 0.1, 1.5);
}

static void testWaterfallArguments() {
    const double fs = 48000;
    const std::vector<float> ir = resonance(fs, 1000.0, 0.003, 0.1, 200);
    n60_measure_waterfall_params p;
    n60_measure_waterfall_defaults(fs, 0, &p);
    n60_measure_waterfall_info info{};
    CHECK(n60_measure_waterfall_describe(&p, &info) == 0, "describe");
    std::vector<double> f(info.point_count), db(static_cast<size_t>(info.point_count) * info.slice_count);
    CHECK(n60_measure_waterfall_analyze(&p, ir.data(), ir.size(), f.data(), db.data(), db.size() - 1, &info) ==
              N60_MEASURE_ERR_CAPACITY, "capacity");
    CHECK(n60_measure_waterfall_analyze(&p, nullptr, 0, f.data(), db.data(), db.size(), &info) == N60_MEASURE_ERR_ARGUMENT,
          "null ir");
    n60_measure_waterfall_params bad = p;
    bad.max_hz = fs;
    CHECK(n60_measure_waterfall_describe(&bad, &info) == N60_MEASURE_ERR_ARGUMENT, "max above nyquist");
    // The default arrival is the largest sample; slices beyond the response read no data.
    std::vector<float> shortIr(ir.begin(), ir.begin() + 300);
    CHECK(n60_measure_waterfall_analyze(&p, shortIr.data(), shortIr.size(), f.data(), db.data(), db.size(), &info) == 0,
          "short response analyses");
    CHECK(db[static_cast<size_t>(info.slice_count - 1) * info.point_count] == N60_MEASURE_NO_DATA_DB, "late slice has no data");
}

static void testSpectrogram() {
    for (double fs : kRates) {
        const double f0 = 1000.0, t0 = 0.05, t1 = 0.07;
        std::vector<float> ir(static_cast<size_t>(0.2 * fs), 0.0f);
        for (size_t i = static_cast<size_t>(t0 * fs); i < static_cast<size_t>(t1 * fs); ++i) {
            ir[i] = static_cast<float>(std::sin(2.0 * kPi * f0 * static_cast<double>(i) / fs));
        }
        n60_measure_spectrogram_params p;
        n60_measure_spectrogram_defaults(fs, &p);
        n60_measure_spectrogram_info info{};
        CHECK(n60_measure_spectrogram_describe(&p, ir.size(), &info) == 0, "describe");
        CHECK(info.hop_frames * 4 == info.window_frames, "75 percent overlap");
        std::vector<double> db(static_cast<size_t>(info.frame_count) * info.bin_count);
        const int status = n60_measure_spectrogram_analyze(&p, ir.data(), ir.size(), db.data(), db.size(), &info);
        CHECK(status == 0, "fs %.0f status %d", fs, status);
        if (status != 0) continue;
        size_t best = 0;
        for (size_t c = 0; c < db.size(); ++c) if (db[c] > db[best]) best = c;
        const double frame = static_cast<double>(best / info.bin_count), bin = static_cast<double>(best % info.bin_count);
        const double centreSeconds = (frame * info.hop_frames + info.window_frames / 2.0) / fs;
        CHECK(std::fabs(db[best]) < 1e-9, "peak is 0 dB");
        // A Hann frame is full strength anywhere its window lies inside the 20 ms burst: centres 55..65 ms.
        CHECK(centreSeconds >= 0.055 - 1e-9 && centreSeconds <= 0.065 + 1e-9, "fs %.0f burst frame centre %.4f s", fs, centreSeconds);
        CHECK(std::fabs(bin * info.hz_per_bin - f0) <= info.hz_per_bin, "fs %.0f burst bin %.1f Hz", fs, bin * info.hz_per_bin);
        // A frame well after the burst is silent; a bin far from the tone is down in the burst frame.
        const size_t lateFrame = info.frame_count - 1;
        CHECK(db[lateFrame * info.bin_count + static_cast<size_t>(bin)] < -100.0, "late frame is quiet");
        const size_t far = static_cast<size_t>(std::min<double>(info.bin_count - 1, 8000.0 / info.hz_per_bin));
        CHECK(db[static_cast<size_t>(frame) * info.bin_count + far] < -35.0, "fs %.0f far bin down in the burst frame", fs);
        CHECK(info.bin_count > 1 && (info.bin_count - 1) * info.hz_per_bin <= 0.45 * fs + info.hz_per_bin, "bins stay under 0.45 fs");
    }
    n60_measure_spectrogram_params bad;
    n60_measure_spectrogram_defaults(48000, &bad);
    bad.window_seconds = 0.0;
    n60_measure_spectrogram_info info{};
    CHECK(n60_measure_spectrogram_describe(&bad, 1000, &info) == N60_MEASURE_ERR_ARGUMENT, "zero window");
}

int main() {
    testWaterfall();
    testWaterfallArguments();
    testSpectrogram();
    if (failures != 0) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("measure waterfall tests passed");
    return 0;
}
