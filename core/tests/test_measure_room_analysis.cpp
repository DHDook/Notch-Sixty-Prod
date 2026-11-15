// E21 S5: arrival search, analysis window, log-grid response and stereo band spectrum, at the
// eight standard rates, against closed-form answers.
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

static void testRoom(double fs) {
    uint64_t size = 0;
    CHECK(n60_measure_transform_size(static_cast<uint64_t>(fs * 1.5), &size) == 0, "size");
    const uint64_t delay = static_cast<uint64_t>(fs * 0.0123);
    std::vector<float> ir(size, 0.0f);
    ir[delay] = 0.5f;
    ir[delay + static_cast<uint64_t>(fs * 0.02)] = 0.1f;   // a later reflection, not the arrival
    ir[size - 40] = 0.4f;                                    // a wrapped harmonic impulse: outside the search half
    uint64_t arrival = 0;
    CHECK(n60_measure_direct_arrival(ir.data(), size, fs, 0, &arrival) == 0, "arrival");
    CHECK(arrival == delay, "fs %.0f arrival %llu want %llu", fs, (unsigned long long)arrival, (unsigned long long)delay);

    std::vector<float> win(size);
    CHECK(n60_measure_window_impulse(ir.data(), size, arrival, fs, win.data(), win.size()) == 0, "window");
    CHECK(win[delay] == 0.5f, "arrival tap kept");
    CHECK(win[size - 40] == 0.0f, "wrapped harmonic removed");
    CHECK(win[delay + static_cast<uint64_t>(fs * 0.02)] == 0.1f, "reflection inside the flat part");

    // Delta only: flat 20 log10(0.5) dB and zero phase once the arrival delay is removed.
    std::fill(ir.begin(), ir.end(), 0.0f);
    ir[delay] = 0.5f;
    CHECK(n60_measure_window_impulse(ir.data(), size, delay, fs, win.data(), win.size()) == 0, "window2");
    n60_measure_response_params rp{};
    rp.sample_rate = fs; rp.start_hz = 20; rp.end_hz = 20000; rp.point_count = 512; rp.arrival_frames = static_cast<double>(delay);
    std::vector<double> f(512), m(512), ph(512);
    CHECK(n60_measure_response_grid(&rp, win.data(), size, f.data(), m.data(), ph.data()) == 0, "grid");
    double worstMag = 0, worstPhase = 0;
    for (int i = 0; i < 512; ++i) {
        worstMag = std::max(worstMag, std::fabs(m[i] - 20.0 * std::log10(0.5)));
        worstPhase = std::max(worstPhase, std::fabs(ph[i]));
    }
    CHECK(worstMag < 1e-6, "fs %.0f flat magnitude error %g dB", fs, worstMag);
    CHECK(worstPhase < 1e-6, "fs %.0f phase error %g rad", fs, worstPhase);
    CHECK(f[0] >= 20.0 - 1e-9 && f[511] <= fs * 0.5 * 0.98 + 1e-9, "grid range");
    for (int i = 1; i < 512; ++i) CHECK(f[i] > f[i - 1], "grid monotonic");
}

static void testBands(double fs) {
    const uint32_t n = fs > 288000 ? 32768 : fs > 144000 ? 16384 : fs > 72000 ? 8192 : 4096;
    // A bin-centred 1 kHz-ish tone (exact bin), peak 0.5, identical on both channels.
    const uint32_t bin = static_cast<uint32_t>(std::lround(1000.0 * n / fs));
    const double tone = bin * fs / n;
    std::vector<float> l(n), r(n);
    for (uint32_t i = 0; i < n; ++i) l[i] = r[i] = static_cast<float>(0.5 * std::cos(2.0 * M_PI * tone * i / fs));
    n60_measure_stereo_bands_params p{fs, n, 288, 20.0, std::min(20000.0, fs * 0.5 * 0.98)};
    std::vector<double> f(288), a(288);
    CHECK(n60_measure_stereo_band_amplitude(&p, l.data(), r.data(), f.data(), a.data()) == 0, "bands");
    size_t top = std::max_element(a.begin(), a.end()) - a.begin();
    CHECK(std::fabs(f[top] - tone) / tone < 0.05, "fs %.0f peak band %.1f Hz vs tone %.1f", fs, f[top], tone);
    // Hann main lobe reads amplitude within ~1.5 dB (a symmetric N-1 window leaves tiny leakage).
    CHECK(std::fabs(20.0 * std::log10(a[top] / 0.5)) < 0.1, "fs %.0f amplitude %g", fs, a[top]);
    // Anti-phase stereo does not cancel (energy combination).
    std::vector<float> rn(n);
    for (uint32_t i = 0; i < n; ++i) rn[i] = -l[i];
    std::vector<double> a2(288);
    CHECK(n60_measure_stereo_band_amplitude(&p, l.data(), rn.data(), f.data(), a2.data()) == 0, "bands2");
    CHECK(std::fabs(a2[top] - a[top]) < 1e-9, "anti-phase equal");
}

int main() {
    CHECK(n60_measure_abi_version() == N60_MEASURE_ABI_VERSION, "abi");
    for (double fs : kRates) { testRoom(fs); testBands(fs); }

    // Errors and edge cases.
    std::vector<float> silent(8192, 0.0f);
    uint64_t arrival = 0;
    CHECK(n60_measure_direct_arrival(silent.data(), silent.size(), 48000, 0, &arrival) == N60_MEASURE_ERR_NO_ARRIVAL, "silent");
    CHECK(n60_measure_direct_arrival(nullptr, 8192, 48000, 0, &arrival) == N60_MEASURE_ERR_ARGUMENT, "null");
    CHECK(n60_measure_direct_arrival(silent.data(), silent.size(), 1.0, 0, &arrival) == N60_MEASURE_ERR_ARGUMENT, "rate");
    float out[4];
    CHECK(n60_measure_window_impulse(silent.data(), silent.size(), 0, 48000, out, 4) == N60_MEASURE_ERR_CAPACITY, "capacity");
    n60_measure_response_params rp{48000, 20, 20000, 512, 0};
    std::vector<double> f(512), m(512), ph(512);
    CHECK(n60_measure_response_grid(&rp, silent.data(), 8190, f.data(), m.data(), ph.data()) == N60_MEASURE_ERR_SIZE, "non pow2");
    rp.start_hz = 30000;
    CHECK(n60_measure_response_grid(&rp, silent.data(), 8192, f.data(), m.data(), ph.data()) == N60_MEASURE_ERR_ARGUMENT, "band");
    rp.start_hz = 20;
    CHECK(n60_measure_response_grid(&rp, silent.data(), 8192, f.data(), m.data(), ph.data()) == 0, "silent ok");
    CHECK(m[0] == -240.0 && m[511] == -240.0, "floor");

    if (failures == 0) std::printf("measure room analysis OK\n");
    return failures == 0 ? 0 : 1;
}
