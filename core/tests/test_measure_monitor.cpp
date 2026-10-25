// E11 S8: input monitor ring, SPL meter and RTA through the C ABI at the eight standard rates.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

#include "n60/measure.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static std::vector<float> sine(double fs, double hz, double amp, double seconds) {
    std::vector<float> x(static_cast<size_t>(seconds * fs));
    for (size_t i = 0; i < x.size(); ++i) x[i] = static_cast<float>(amp * std::sin(2.0 * kPi * hz * static_cast<double>(i) / fs));
    return x;
}

// Seeded white noise, uniform, variance 1/3 * amp^2 (xorshift32).
static std::vector<float> noise(size_t n, double amp, uint32_t seed) {
    std::vector<float> x(n);
    uint32_t s = seed;
    for (size_t i = 0; i < n; ++i) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        x[i] = static_cast<float>(amp * (static_cast<double>(s) / 2147483648.0 - 1.0));
    }
    return x;
}

// ---- ring ----

static void testRing() {
    n60_monitor_ring *ring = nullptr;
    CHECK(n60_monitor_ring_create(300, &ring) != 0, "non power of two rejected");
    CHECK(n60_monitor_ring_create(512, &ring) == 0 && ring, "create");
    std::vector<float> in(1000);
    for (size_t i = 0; i < in.size(); ++i) in[i] = static_cast<float>(i);
    CHECK(n60_monitor_ring_push(ring, in.data(), 1, 300) == 300, "first push accepted");
    CHECK(n60_monitor_ring_push(ring, in.data(), 1, 300) == 212, "second push partly accepted");
    CHECK(n60_monitor_ring_overrun_frames(ring) == 88, "overrun frames counted: %llu", (unsigned long long)n60_monitor_ring_overrun_frames(ring));
    CHECK(n60_monitor_ring_available(ring) == 512, "full");
    std::vector<float> out(600);
    CHECK(n60_monitor_ring_pop(ring, out.data(), 600) == 512, "pop all");
    CHECK(out[0] == 0 && out[299] == 299 && out[300] == 0 && out[511] == 211, "order kept");
    // Stride and non-finite handling.
    const float inter[8] = {1, 100, 2, 100, NAN, 100, INFINITY, 100};
    CHECK(n60_monitor_ring_push(ring, inter, 2, 4) == 4, "strided push");
    CHECK(n60_monitor_ring_pop(ring, out.data(), 4) == 4 && out[0] == 1 && out[1] == 2 && out[2] == 0 && out[3] == 0, "stride and sanitise");
    n60_monitor_ring_reset(ring);
    CHECK(n60_monitor_ring_overrun_frames(ring) == 0 && n60_monitor_ring_available(ring) == 0, "reset");
    n60_monitor_ring_destroy(ring);

    // Two threads: the consumer sees an in-order subsequence and accepted + dropped == pushed.
    CHECK(n60_monitor_ring_create(1024, &ring) == 0, "create 2");
    const uint32_t chunk = 100, chunks = 20000;
    std::atomic<bool> done{false};
    uint64_t accepted = 0;
    std::thread producer([&] {
        std::vector<float> buf(chunk);
        uint64_t counter = 0;
        for (uint32_t c = 0; c < chunks; ++c) {
            for (uint32_t i = 0; i < chunk; ++i) buf[i] = static_cast<float>((counter + i) % 16777216u);
            const uint32_t took = n60_monitor_ring_push(ring, buf.data(), 1, chunk);
            accepted += took;
            counter += chunk;  // frames dropped at the tail leave a gap, never a reorder
        }
        done = true;
    });
    uint64_t popped = 0;
    double last = -1;
    bool ordered = true;
    std::vector<float> tmp(256);
    while (!done.load() || n60_monitor_ring_available(ring) > 0) {
        const uint32_t n = n60_monitor_ring_pop(ring, tmp.data(), 256);
        for (uint32_t i = 0; i < n; ++i) { if (tmp[i] <= last && last < 16777215) ordered = false; last = tmp[i]; }
        popped += n;
    }
    producer.join();
    CHECK(ordered, "consumer saw samples in order");
    CHECK(popped == accepted, "popped %llu accepted %llu", (unsigned long long)popped, (unsigned long long)accepted);
    CHECK(accepted + n60_monitor_ring_overrun_frames(ring) == static_cast<uint64_t>(chunk) * chunks, "accepted + overruns == pushed");
    n60_monitor_ring_destroy(ring);
}

// ---- weighting ----

static double analyticA(double f) {
    const double f2 = f * f;
    return 20 * std::log10(12194.0 * 12194.0 * f2 * f2 / ((f2 + 20.6 * 20.6) * std::sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12194.0 * 12194.0)));
}
static double analyticC(double f) {
    const double f2 = f * f;
    return 20 * std::log10(12194.0 * 12194.0 * f2 / ((f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0)));
}

struct Limit { double hz, plus, minus; };
// Class 1 acceptance limits on the deviation from the nominal weighting (IEC 61672-1 Table 2 as
// transcribed here; 99 means unbounded). Verify against the standard text before quoting a claim.
static const Limit kClass1[] = {
    {10, 3.0, 99}, {12.5, 2.5, 99}, {16, 2.0, 4.0}, {20, 2.0, 2.0}, {25, 2.0, 1.5}, {31.5, 1.5, 1.5}, {40, 1.5, 1.5},
    {50, 1.5, 1.5}, {63, 1.5, 1.5}, {80, 1.5, 1.5}, {100, 1.5, 1.5}, {125, 1.5, 1.5}, {160, 1.5, 1.5}, {200, 1.5, 1.5},
    {250, 1.4, 1.4}, {315, 1.4, 1.4}, {400, 1.4, 1.4}, {500, 1.4, 1.4}, {630, 1.4, 1.4}, {800, 1.4, 1.4}, {1000, 1.1, 1.1},
    {1250, 1.4, 1.4}, {1600, 1.6, 1.6}, {2000, 1.6, 1.6}, {2500, 1.6, 1.6}, {3150, 1.6, 1.6}, {4000, 1.6, 1.6},
    {5000, 2.1, 2.1}, {6300, 2.1, 2.6}, {8000, 2.1, 3.1}, {10000, 2.6, 3.6}, {12500, 3.0, 6.0}, {16000, 3.5, 17.0},
    {20000, 4.0, 99}};

static void testWeighting() {
    for (double fs : kRates) {
        for (uint32_t w : {(uint32_t)N60_SPL_WEIGHT_A, (uint32_t)N60_SPL_WEIGHT_C}) {
            const double ref1k = w == N60_SPL_WEIGHT_A ? analyticA(1000) : analyticC(1000);
            double at1k = 1;
            CHECK(n60_spl_weighting_response_db(fs, w, 1000, &at1k) == 0 && std::fabs(at1k) < 1e-9, "0 dB at 1 kHz (%.3g)", at1k);
            double worstMid = 0;
            for (const Limit &l : kClass1) {
                double g = 0;
                if (n60_spl_weighting_response_db(fs, w, l.hz, &g) != 0) { CHECK(false, "response failed"); continue; }
                const double nominal = (w == N60_SPL_WEIGHT_A ? analyticA(l.hz) : analyticC(l.hz)) - ref1k;
                const double dev = g - nominal;
                CHECK(dev <= l.plus && dev >= -l.minus, "fs %.0f w %u %.1f Hz dev %.2f dB outside +%.1f/-%.1f", fs, w, l.hz, dev, l.plus, l.minus);
                if (l.hz >= 31.5 && l.hz <= 5000) worstMid = std::max(worstMid, std::fabs(dev));
            }
            CHECK(worstMid < 0.3, "fs %.0f w %u mid band deviation %.3f dB", fs, w, worstMid);
        }
    }
    // Time domain agrees with the response: a 63 Hz and an 8 kHz tone through A.
    for (double fs : {48000.0, 384000.0}) {
        for (double hz : {63.0, 8000.0}) {
            n60_spl_meter *m = nullptr;
            CHECK(n60_spl_create(fs, N60_SPL_WEIGHT_A, &m) == 0, "create");
            const std::vector<float> settle = sine(fs, hz, 0.5, 1.0);
            n60_spl_process(m, settle.data(), settle.size());
            n60_spl_reset(m);  // clears the integrators too, so re-prime the filters and measure
            const std::vector<float> x = sine(fs, hz, 0.5, 4.0);
            n60_spl_process(m, x.data(), x.size());
            n60_spl_reading r;
            n60_spl_read(m, &r);
            double g = 0;
            n60_spl_weighting_response_db(fs, N60_SPL_WEIGHT_A, hz, &g);
            CHECK(std::fabs(r.leq_db - (-9.0309 + g)) < 0.05, "fs %.0f %.0f Hz leq %.3f vs %.3f", fs, hz, r.leq_db, -9.0309 + g);
            n60_spl_destroy(m);
        }
    }
}

// ---- time weighting, Leq, calibration, peak ----

static void testMeter() {
    for (double fs : kRates) {
        n60_spl_meter *m = nullptr;
        CHECK(n60_spl_create(fs, N60_SPL_WEIGHT_Z, &m) == 0, "create");
        // Sine of peak 1: mean square 0.5. After one time constant the integrator is at 1 - 1/e of it.
        const double finalDB = 10 * std::log10(0.5);
        const std::vector<float> x = sine(fs, 1000.0, 1.0, 1.0);
        n60_spl_reading r;
        const size_t fastTau = static_cast<size_t>(0.125 * fs);
        n60_spl_process(m, x.data(), fastTau);
        n60_spl_read(m, &r);
        const double expectFast = finalDB + 10 * std::log10(1 - std::exp(-1.0));
        CHECK(std::fabs(r.fast_db - expectFast) < 0.2, "fs %.0f Fast after tau %.3f vs %.3f", fs, r.fast_db, expectFast);  // 5 % of power is 0.21 dB
        n60_spl_process(m, x.data() + fastTau, x.size() - fastTau);
        n60_spl_read(m, &r);
        const double expectSlow = finalDB + 10 * std::log10(1 - std::exp(-1.0));
        CHECK(std::fabs(r.slow_db - expectSlow) < 0.2, "fs %.0f Slow after tau %.3f vs %.3f", fs, r.slow_db, expectSlow);
        CHECK(std::fabs(r.fast_db - finalDB) < 0.05, "fs %.0f Fast settled %.3f", fs, r.fast_db);
        n60_spl_destroy(m);

        // Leq of a known signal, with a calibrator offset: 94 dB SPL reads for a sine of RMS 0.1.
        CHECK(n60_spl_create(fs, N60_SPL_WEIGHT_A, &m) == 0, "create A");
        const double rms = 0.1;
        const std::vector<float> cal = sine(fs, 1000.0, rms * std::sqrt(2.0), 2.0);
        n60_spl_process(m, cal.data(), cal.size());
        n60_spl_read(m, &r);
        const double dbfs = 20 * std::log10(rms);
        CHECK(std::fabs(r.leq_db - dbfs) < 0.1, "fs %.0f Leq %.3f vs %.3f dBFS", fs, r.leq_db, dbfs);
        CHECK(std::fabs(r.elapsed_seconds - 2.0) < 1e-6, "elapsed");
        CHECK(n60_spl_set_calibration_db(m, 94.0 - r.leq_db) == 0, "set calibration");
        n60_spl_read(m, &r);
        CHECK(std::fabs(r.leq_db - 94.0) < 1e-9, "calibrator reads 94 dB: %.6f", r.leq_db);
        // C-peak of a 1 kHz sine of peak 0.5 is 20 log10(0.5) plus the offset.
        CHECK(std::fabs(r.c_peak_db - (20 * std::log10(rms * std::sqrt(2.0)) + 94.0 - dbfs)) < 0.5, "c peak %.3f", r.c_peak_db);
        n60_spl_reset(m);
        n60_spl_read(m, &r);
        CHECK(r.leq_db < -100 + 94.0 && r.elapsed_seconds == 0, "reset clears (%.1f)", r.leq_db);
        n60_spl_destroy(m);
    }
    n60_spl_meter *m = nullptr;
    CHECK(n60_spl_create(48000, 7, &m) != 0, "bad weighting rejected");
    CHECK(n60_spl_create(100, 0, &m) != 0, "bad rate rejected");
}

// ---- bands ----

static void testBands() {
    static const double nominalThird[] = {20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                                          1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000};
    static const double nominalOctave[] = {31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    const double g = std::pow(10.0, 0.3);
    for (uint32_t n : {1u, 3u, 6u, 12u, 24u, 48u}) {
        std::vector<double> c(2000), lo(2000), hi(2000);
        uint32_t count = 0;
        CHECK(n60_rta_band_layout(n, 96000, 20, 20000, c.data(), lo.data(), hi.data(), 2000, &count) == 0, "layout %u", n);
        CHECK(count > 0, "bands");
        for (uint32_t i = 0; i < count; ++i) {
            CHECK(std::fabs(hi[i] / lo[i] - std::pow(g, 1.0 / n)) < 1e-12, "1/%u band width ratio", n);
            CHECK(std::fabs(std::sqrt(lo[i] * hi[i]) / c[i] - 1) < 1e-12, "geometric centre");
            if (i > 0) CHECK(std::fabs(lo[i] / hi[i - 1] - 1) < 1e-12, "1/%u bands abut", n);
        }
        if (n == 3 || n == 1) {
            const double *nom = n == 3 ? nominalThird : nominalOctave;
            const uint32_t nc = n == 3 ? 31 : 10;
            CHECK(count == nc, "1/%u count %u", n, count);
            for (uint32_t i = 0; i < std::min(count, nc); ++i) CHECK(std::fabs(c[i] / nom[i] - 1) < 0.015, "1/%u centre %.2f vs nominal %.1f", n, c[i], nom[i]);
        }
    }
    uint32_t count = 0;
    double c[200];
    CHECK(n60_rta_band_layout(3, 44100, 20, 20000, c, nullptr, nullptr, 200, &count) == 0 && c[count - 1] < 16001, "upper edge under Nyquist at 44.1 kHz (last %.0f)", c[count - 1]);
    CHECK(n60_rta_band_layout(3, 48000, 20, 20000, c, nullptr, nullptr, 3, &count) == N60_MEASURE_ERR_CAPACITY, "capacity checked");
    uint32_t size = 0;
    CHECK(n60_rta_default_fft_size(48000, 3, &size) == 0 && size == 32768, "default size 1/3 at 48k: %u", size);
    CHECK(n60_rta_default_fft_size(384000, 48, &size) == 0 && size == (1u << 20), "default size 1/48 at 384k capped: %u", size);
}

// ---- RTA ----

static n60_rta *makeRta(double fs, uint32_t n, uint32_t size, uint32_t averaging, double tau, double cal) {
    n60_rta_params p{};
    p.sample_rate = fs; p.fft_size = size; p.bands_per_octave = n; p.averaging = averaging;
    p.time_constant_seconds = tau; p.calibration_db = cal;
    n60_rta *r = nullptr;
    CHECK(n60_rta_create(&p, &r) == 0 && r, "rta create");
    return r;
}

static void testRta() {
    for (double fs : kRates) {
        // A sine of peak 0.5 puts mean square 0.125 (-9.03 dB) into its band, whatever the bin alignment.
        for (double hz : {1000.0, 1234.567}) {
            n60_rta *r = makeRta(fs, 3, 32768, N60_RTA_AVERAGE_INFINITE, 0, 0);
            const std::vector<float> x = sine(fs, hz, 0.5, 1.5);
            n60_rta_process(r, x.data(), x.size());
            CHECK(n60_rta_frames_analysed(r) > 2, "frames analysed");
            std::vector<double> c(64), l(64);
            uint32_t count = 0;
            CHECK(n60_rta_read(r, c.data(), l.data(), 64, &count) == 0, "read");
            double total = 0, peak = -1e9;
            for (uint32_t i = 0; i < count; ++i) { total += std::pow(10.0, l[i] / 10); peak = std::max(peak, l[i]); }
            CHECK(std::fabs(10 * std::log10(total) - (-9.0309)) < 0.1, "fs %.0f %.1f Hz total %.3f dB", fs, hz, 10 * std::log10(total));
            uint32_t pk = 0;
            for (uint32_t i = 0; i < count; ++i) if (l[i] == peak) pk = i;
            CHECK(std::fabs(c[pk] / hz - 1) < 0.13, "fs %.0f peak band %.1f for %.1f Hz", fs, c[pk], hz);
            n60_rta_destroy(r);
        }
        // White noise: band power proportional to bandwidth (variance a^2/3 spread to fs / 2).
        n60_rta *r = makeRta(fs, 3, 32768, N60_RTA_AVERAGE_INFINITE, 0, 0);
        const std::vector<float> x = noise(static_cast<size_t>(fs * 12), 1.0, 12345u);
        n60_rta_process(r, x.data(), x.size());
        std::vector<double> c(64), l(64), lo(64), hi(64);
        uint32_t count = 0, count2 = 0;
        n60_rta_read(r, c.data(), l.data(), 64, &count);
        n60_rta_band_layout(3, fs, 20, 20000, nullptr, lo.data(), hi.data(), 64, &count2);
        double worst = 0;
        for (uint32_t i = 0; i < count; ++i) {
            if (c[i] < 400) continue;  // narrower bands need longer averages for 0.4 dB
            const double expect = 10 * std::log10((1.0 / 3.0) * (hi[i] - lo[i]) / (fs / 2));
            worst = std::max(worst, std::fabs(l[i] - expect));
        }
        CHECK(worst < 0.4, "fs %.0f white noise band error %.3f dB", fs, worst);
        n60_rta_destroy(r);
    }
    // Calibration offset is added; exponential averaging follows a level step; none shows the last frame.
    {
        n60_rta *a = makeRta(48000, 3, 16384, N60_RTA_AVERAGE_NONE, 0, 0), *b = makeRta(48000, 3, 16384, N60_RTA_AVERAGE_NONE, 0, 94.0);
        const std::vector<float> x = sine(48000, 1000, 0.5, 1.0);
        n60_rta_process(a, x.data(), x.size());
        n60_rta_process(b, x.data(), x.size());
        double la[64], lb[64], c[64];
        uint32_t n = 0;
        n60_rta_read(a, c, la, 64, &n);
        n60_rta_read(b, c, lb, 64, &n);
        for (uint32_t i = 0; i < n; ++i) if (la[i] > -100) CHECK(std::fabs(lb[i] - la[i] - 94.0) < 1e-9, "calibration offset");
        n60_rta_destroy(a);
        n60_rta_destroy(b);
    }
    {
        n60_rta *r = makeRta(48000, 1, 8192, N60_RTA_AVERAGE_EXPONENTIAL, 0.5, 0);
        const std::vector<float> loud = sine(48000, 1000, 0.5, 3.0), quiet = sine(48000, 1000, 0.05, 8.0);
        n60_rta_process(r, loud.data(), loud.size());
        n60_rta_process(r, quiet.data(), quiet.size());
        double c[16], l[16];
        uint32_t n = 0;
        n60_rta_read(r, c, l, 16, &n);
        uint32_t k = 0;
        for (uint32_t i = 0; i < n; ++i) if (std::fabs(c[i] - 1000) < 100) k = i;
        CHECK(std::fabs(l[k] - (-29.03)) < 0.3, "exponential average settles to the new level: %.2f", l[k]);
        n60_rta_reset(r);
        CHECK(n60_rta_frames_analysed(r) == 0, "reset");
        n60_rta_destroy(r);
    }
    n60_rta_params bad{};
    n60_rta *r = nullptr;
    CHECK(n60_rta_create(&bad, &r) != 0, "empty params rejected");
}

int main() {
    CHECK(n60_measure_abi_version() == 3, "abi 3");
    testRing();
    testWeighting();
    testMeter();
    testBands();
    testRta();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("measure monitor tests passed");
    return 0;
}
