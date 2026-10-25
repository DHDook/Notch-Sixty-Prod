// E11 S1: measurement core through its C ABI at the eight standard rates: synchronised ESS
// harmonic offsets, deconvolution maths against a direct DFT, and reference-room recovery.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "measure/offline_fft.hpp"
#include "n60/measure.h"

using n60::fft::offline::Cplx;
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static n60_measure_ess_params essParams(double fs, double endHz, double seconds, int sync) {
    n60_measure_ess_params p{};
    p.sample_rate = fs;
    p.start_hz = 20;
    p.end_hz = endHz;
    p.duration_seconds = seconds;
    p.level_dbfs = -6;
    p.fade_seconds = 0.02;
    p.synchronised = static_cast<uint32_t>(sync);
    return p;
}

static void testBasics() {
    CHECK(n60_measure_abi_version() == N60_MEASURE_ABI_VERSION, "abi version");
    uint64_t size = 0;
    CHECK(n60_measure_transform_size(1000, &size) == 0 && size == 1024, "size 1000 -> %llu", (unsigned long long)size);
    CHECK(n60_measure_transform_size(1024, &size) == 0 && size == 1024, "size 1024");
    CHECK(n60_measure_transform_size(1025, &size) == 0 && size == 2048, "size 1025");
    CHECK(n60_measure_transform_size(16777217ull, &size) == N60_MEASURE_ERR_SIZE, "oversize");
    CHECK(n60_measure_transform_size(0, &size) == N60_MEASURE_ERR_ARGUMENT, "zero");

    n60_measure_ess_params bad = essParams(48000, 30000, 2, 1);
    n60_measure_ess_info info{};
    CHECK(n60_measure_ess_describe(&bad, &info) == N60_MEASURE_ERR_ARGUMENT, "end above Nyquist rejected");
}

static void testDeconvolveAgainstDirectDft() {
    const uint64_t nx = 100, ny = 200, n = 256;
    std::vector<float> x(nx), y(ny);
    uint64_t s = 99;
    auto r = [&]() { s = s * 6364136223846793005ull + 1442695040888963407ull; return static_cast<double>(s >> 40) / 16777216.0 - 0.5; };
    for (float &v : x) v = static_cast<float>(r());
    for (float &v : y) v = static_cast<float>(r());
    std::vector<float> h(n);
    uint64_t count = 0;
    CHECK(n60_measure_deconvolve(x.data(), nx, y.data(), ny, 1e-10, h.data(), n, &count) == 0 && count == n, "deconvolve");
    // Direct DFT reference.
    std::vector<Cplx> X(n), Y(n), H(n);
    for (uint64_t k = 0; k < n; ++k) {
        double xr = 0, xi = 0, yr = 0, yi = 0;
        for (uint64_t j = 0; j < n; ++j) {
            const double a = -2.0 * M_PI * static_cast<double>(j * k % n) / static_cast<double>(n);
            const double xv = j < nx ? x[j] : 0.0, yv = j < ny ? y[j] : 0.0;
            xr += xv * std::cos(a); xi += xv * std::sin(a);
            yr += yv * std::cos(a); yi += yv * std::sin(a);
        }
        X[k] = {xr, xi}; Y[k] = {yr, yi};
    }
    double maxPower = 0;
    for (auto &c : X) maxPower = std::fmax(maxPower, c.re * c.re + c.im * c.im);
    const double lambda = maxPower * 1e-10;
    for (uint64_t k = 0; k < n; ++k) {
        const double d = X[k].re * X[k].re + X[k].im * X[k].im + lambda;
        H[k] = {(Y[k].re * X[k].re + Y[k].im * X[k].im) / d, (Y[k].im * X[k].re - Y[k].re * X[k].im) / d};
    }
    double worst = 0, peak = 0;
    for (uint64_t j = 0; j < n; ++j) {
        double v = 0;
        for (uint64_t k = 0; k < n; ++k) {
            const double a = 2.0 * M_PI * static_cast<double>(j * k % n) / static_cast<double>(n);
            v += H[k].re * std::cos(a) - H[k].im * std::sin(a);
        }
        v /= static_cast<double>(n);
        worst = std::fmax(worst, std::fabs(v - h[j]));
        peak = std::fmax(peak, std::fabs(v));
    }
    CHECK(worst < 1e-5 * peak, "deconvolution vs direct DFT: error %g, peak %g", worst, peak);

    std::vector<float> zeros(nx, 0.0f);
    CHECK(n60_measure_deconvolve(zeros.data(), nx, y.data(), ny, 1e-10, h.data(), n, &count) == N60_MEASURE_ERR_UNUSABLE_EXCITATION, "silent excitation");
    CHECK(n60_measure_deconvolve(x.data(), nx, y.data(), ny, 1e-10, h.data(), 100, &count) == N60_MEASURE_ERR_CAPACITY, "capacity");
}

static void testSynchronisedSweep() {
    for (double fs : kRates) {
        n60_measure_ess_params p = essParams(fs, 20000, 5.0, 1);
        n60_measure_ess_info info{};
        CHECK(n60_measure_ess_describe(&p, &info) == 0, "describe %g", fs);
        const double cycles = p.start_hz * info.sweep_rate_seconds;
        CHECK(std::fabs(cycles - std::round(cycles)) < 1e-9, "f1*L = %.12f not an integer at %g", cycles, fs);
        CHECK(std::fabs(info.duration_seconds - 5.0) < 1.0 / p.start_hz * std::log(1000.0) * 0.5 + 1e-9, "duration %g", info.duration_seconds);
        n60_measure_ess_params plain = p;
        plain.synchronised = 0;
        n60_measure_ess_info plainInfo{};
        CHECK(n60_measure_ess_describe(&plain, &plainInfo) == 0 &&
              std::fabs(plainInfo.sweep_rate_seconds - 5.0 / std::log(1000.0)) < 1e-12, "plain L");
    }
}

// Harmonic impulses of a nonlinear identity system land at -L ln k, to within one sample.
static void testHarmonicOffsets(double fs) {
    n60_measure_ess_params p = essParams(fs, fs / 12.0, 4.0, 1);
    n60_measure_ess_info info{};
    CHECK(n60_measure_ess_describe(&p, &info) == 0, "describe");
    std::vector<float> sweep(info.frame_count);
    CHECK(n60_measure_ess_generate(&p, sweep.data(), sweep.size(), &info) == 0, "generate");

    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    room.ir_seconds = 0.25;
    room.direct_delay_seconds = 0.0;
    room.diffuse_level_db = -200;
    for (int m = 0; m < 4; ++m) room.mode_frequencies_hz[m] = 0;
    room.harmonic_db[0] = -30; room.harmonic_db[1] = -35; room.harmonic_db[2] = -40; room.harmonic_db[3] = -45;
    const uint64_t latency = 3000;
    room.latency_seconds = static_cast<double>(latency) / fs;
    uint64_t total = 0;
    CHECK(n60_measure_room_capture_length(&room, sweep.size(), &total) == 0, "capture length");
    std::vector<float> capture(total);
    CHECK(n60_measure_room_capture(&room, sweep.data(), sweep.size(), capture.data(), total, &total) == 0, "capture");

    uint64_t n = 0;
    CHECK(n60_measure_transform_size(total, &n) == 0, "transform size");
    std::vector<float> h(n);
    uint64_t count = 0;
    CHECK(n60_measure_deconvolve(sweep.data(), sweep.size(), capture.data(), total, 1e-10, h.data(), n, &count) == 0, "deconvolve");

    // Harmonic content above the sweep's top frequency has no excitation to divide by, so band-limit
    // the response to the swept band (what the analysis stages do) before looking for impulses.
    {
        std::vector<double> full(h.begin(), h.end());
        std::vector<Cplx> spec;
        n60::fft::offline::realForward(full.data(), n, spec);
        for (size_t k = 0; k < spec.size(); ++k) {
            const double f = static_cast<double>(k) * fs / static_cast<double>(n);
            const double edge = p.end_hz * 0.9;
            if (f > edge) {
                const double fall = std::fmax(0.0, 1.0 - (f - edge) / (p.end_hz * 0.1));
                spec[k] = Cplx{spec[k].re * fall, spec[k].im * fall};
            }
        }
        n60::fft::offline::realInverse(spec, n, full);
        for (uint64_t i = 0; i < n; ++i) h[i] = static_cast<float>(full[i]);
    }

    // Harmonic impulses are band-pass pulses, so locate them by the analytic-signal envelope
    // (Hilbert transform over a window), not by the raw maximum.
    const int64_t seg = 8192;
    auto envelopePeak = [&](int64_t centre, double *prominence) {
        std::vector<double> w(seg);
        for (int64_t i = 0; i < seg; ++i) {
            const int64_t idx = ((centre - seg / 2 + i) % static_cast<int64_t>(n) + static_cast<int64_t>(n)) % static_cast<int64_t>(n);
            w[i] = h[idx];
        }
        std::vector<Cplx> spec;
        n60::fft::offline::realForward(w.data(), seg, spec);
        // Analytic signal: double positive bins, drop negative (real transform keeps k <= seg/2).
        std::vector<double> re, im;
        std::vector<Cplx> a1 = spec, a2 = spec;
        for (size_t k = 0; k < a1.size(); ++k) {
            const double gain = (k == 0 || k == a1.size() - 1) ? 1.0 : 2.0;
            a1[k] = Cplx{spec[k].re * gain, spec[k].im * gain};
            a2[k] = Cplx{-a1[k].im, a1[k].re};  // multiply by i: imaginary part of analytic signal
        }
        n60::fft::offline::realInverse(a1, seg, re);
        n60::fft::offline::realInverse(a2, seg, im);
        // The imaginary part of the analytic signal equals the Hilbert transform; with only the
        // real-input half spectrum doubled, re = x and im = H{x} up to the sign convention.
        std::vector<double> env(seg);
        for (int64_t i = 0; i < seg; ++i) env[i] = std::hypot(re[i], im[i]);
        int64_t best = 0;
        for (int64_t i = 1; i < seg; ++i) if (env[i] > env[best]) best = i;
        std::vector<double> sorted = env;
        std::sort(sorted.begin(), sorted.end());
        *prominence = env[best] / sorted[seg / 2];
        return centre - seg / 2 + best;
    };
    double prominence = 0;
    const int64_t linear = envelopePeak(static_cast<int64_t>(latency), &prominence);
    CHECK(std::llabs(linear - static_cast<int64_t>(latency)) <= 1, "linear impulse at %lld, expected %llu", (long long)linear, (unsigned long long)latency);
    for (uint32_t k = 2; k <= 5; ++k) {
        const double lead = n60_measure_ess_harmonic_lead_seconds(&info, k) * fs;
        const int64_t predicted = static_cast<int64_t>(latency) - static_cast<int64_t>(std::llround(lead));
        const int64_t found = envelopePeak(predicted, &prominence);
        CHECK(std::llabs(found - predicted) <= 1, "fs=%g H%u at %lld, predicted %lld", fs, k, (long long)found, (long long)predicted);
        CHECK(prominence > 5.0, "fs=%g H%u envelope prominence %.2f", fs, k, prominence);
    }
}

// The recovered IR matches the reference room within 0.1 dB per third-octave band.
static void testRoomRecovery(double fs) {
    const double endHz = 20000;
    n60_measure_ess_params p = essParams(fs, endHz, 3.0, 1);
    n60_measure_ess_info info{};
    CHECK(n60_measure_ess_describe(&p, &info) == 0, "describe");
    std::vector<float> sweep(info.frame_count);
    CHECK(n60_measure_ess_generate(&p, sweep.data(), sweep.size(), &info) == 0, "generate");

    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    const uint64_t latency = static_cast<uint64_t>(0.0373 * fs);
    room.latency_seconds = static_cast<double>(latency) / fs;
    uint64_t irLen = 0;
    CHECK(n60_measure_room_ir_length(&room, &irLen) == 0, "ir length");
    std::vector<float> ir(irLen);
    CHECK(n60_measure_room_ir(&room, ir.data(), ir.size(), &irLen) == 0, "ir");
    uint64_t total = 0;
    CHECK(n60_measure_room_capture_length(&room, sweep.size(), &total) == 0, "capture length");
    std::vector<float> capture(total);
    CHECK(n60_measure_room_capture(&room, sweep.data(), sweep.size(), capture.data(), total, &total) == 0, "capture");
    std::vector<float> again(total);
    uint64_t total2 = 0;
    CHECK(n60_measure_room_capture(&room, sweep.data(), sweep.size(), again.data(), total, &total2) == 0, "capture again");
    CHECK(std::memcmp(capture.data(), again.data(), total * sizeof(float)) == 0, "reference room is deterministic");

    uint64_t n = 0;
    CHECK(n60_measure_transform_size(total, &n) == 0, "transform size");
    std::vector<float> h(n);
    uint64_t count = 0;
    const auto t0 = std::chrono::steady_clock::now();
    CHECK(n60_measure_deconvolve(sweep.data(), sweep.size(), capture.data(), total, 1e-10, h.data(), n, &count) == 0, "deconvolve");
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    uint64_t m = 2;
    while (m < irLen) m <<= 1;
    std::vector<double> a(m, 0.0), b(m, 0.0);
    for (uint64_t i = 0; i < irLen; ++i) {
        a[i] = ir[i];
        b[i] = h[latency + i];
    }
    std::vector<Cplx> A, B;
    CHECK(n60::fft::offline::realForward(a.data(), m, A) && n60::fft::offline::realForward(b.data(), m, B), "fft");
    double worst = 0;
    int bands = 0;
    for (double centre = 63.0; centre <= 12500.0; centre *= std::pow(2.0, 1.0 / 3.0)) {
        const double lo = centre / std::pow(2.0, 1.0 / 6.0), hi = centre * std::pow(2.0, 1.0 / 6.0);
        double ea = 0, eb = 0;
        for (uint64_t k = 1; k < m / 2; ++k) {
            const double f = static_cast<double>(k) * fs / static_cast<double>(m);
            if (f < lo || f >= hi) continue;
            ea += A[k].re * A[k].re + A[k].im * A[k].im;
            eb += B[k].re * B[k].re + B[k].im * B[k].im;
        }
        if (ea <= 0) continue;
        worst = std::fmax(worst, std::fabs(10.0 * std::log10(eb / ea)));
        ++bands;
    }
    CHECK(bands > 20, "bands compared: %d", bands);
    CHECK(worst < 0.1, "fs=%g worst third-octave error %.4f dB", fs, worst);
    std::printf("fs=%-7g room recovery worst band error %.5f dB (deconvolve %.2f s, N=%llu)\n", fs, worst, seconds, (unsigned long long)n);
}

static void testDriftAndNoise() {
    const double fs = 48000;
    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    room.ir_seconds = 0.1;
    room.direct_delay_seconds = 0.001;
    room.diffuse_level_db = -200;
    for (int m = 0; m < 4; ++m) room.mode_frequencies_hz[m] = 0;
    room.latency_seconds = 1000.0 / fs;
    room.drift_ppm = 50.0;
    std::vector<float> x(200000, 0.0f);
    x[100000] = 1.0f;
    uint64_t total = 0;
    CHECK(n60_measure_room_capture_length(&room, x.size(), &total) == 0, "len");
    std::vector<float> y(total);
    CHECK(n60_measure_room_capture(&room, x.data(), x.size(), y.data(), total, &total) == 0, "capture");
    uint64_t best = 0;
    for (uint64_t i = 0; i < total; ++i) if (std::fabs(y[i]) > std::fabs(y[best])) best = i;
    const double expected = (100000.0 + 48.0 + 1000.0) / (1.0 + 50e-6);
    CHECK(std::fabs(static_cast<double>(best) - expected) <= 1.0, "drifted arrival at %llu, expected %.2f", (unsigned long long)best, expected);

    room.drift_ppm = 0;
    room.noise_dbfs = -60;
    std::vector<float> silence(100000, 0.0f);
    CHECK(n60_measure_room_capture_length(&room, silence.size(), &total) == 0, "len");
    std::vector<float> noise(total);
    CHECK(n60_measure_room_capture(&room, silence.data(), silence.size(), noise.data(), total, &total) == 0, "noise capture");
    double e = 0;
    for (uint64_t i = 0; i < total; ++i) e += static_cast<double>(noise[i]) * noise[i];
    const double rmsDb = 10.0 * std::log10(e / static_cast<double>(total));
    CHECK(std::fabs(rmsDb + 60.0) < 0.1, "noise RMS %.3f dBFS", rmsDb);
}

int main() {
    testBasics();
    testDeconvolveAgainstDirectDft();
    testSynchronisedSweep();
    testDriftAndNoise();
    for (double fs : kRates) {
        testHarmonicOffsets(fs);
        testRoomRecovery(fs);
    }
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("measure core OK");
    return 0;
}
