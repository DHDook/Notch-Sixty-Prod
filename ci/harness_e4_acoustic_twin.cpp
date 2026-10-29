/*
 * E4 S13: behavioural harness for the acoustic twin (ci/e4_acoustic_twin.hpp)
 * and the first closed-loop cases that run the real engine cores in it: the
 * adaptive tonal canceller (N60Fxlms.h) and the howl guard (N60AncGuard.h).
 *
 * Usage: harness_e4_acoustic_twin [--soak]
 * Default: short cases at the eight standard rates (pr.yml). --soak runs the
 * long drift and fault sequence (macos-full.yml).
 */
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "N60AncGuard.h"
#include "N60Fxlms.h"
#include "e4_acoustic_twin.hpp"

using twin::Config;
using twin::Fault;
using twin::Frame;
using twin::Mode;
using twin::Source;
using twin::Twin;

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

using cd = std::complex<double>;
static double db(double ratio) { return 10.0 * std::log10(ratio); }
static const double kNoNoise = -std::numeric_limits<double>::infinity();

static Config quiet(double fs) {
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = kNoNoise;
    return c;
}

/* Frame index of the largest |x|. */
static size_t peak_index(const std::vector<float> &x) {
    size_t best = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        if (std::fabs(x[i]) > std::fabs(x[best])) best = i;
    }
    return best;
}

static std::vector<float> impulse_response(Twin &t, size_t frames) {
    std::vector<float> h(frames);
    for (size_t i = 0; i < frames; ++i) h[i] = t.step(i == 0 ? 1.0f : 0.0f).error;
    return h;
}

/* Amplitude and phase of a tone in a block, by demodulation at the given
 * absolute time (seconds) of the first sample. */
static cd demod(const std::vector<float> &x, double fs, double hz, double t0, double clock = 1.0) {
    cd acc = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        const double t = t0 + static_cast<double>(i) / fs;
        acc += static_cast<double>(x[i]) * std::polar(1.0, -twin::kTau * hz * t * clock);
    }
    return 2.0 * acc / static_cast<double>(x.size());
}

/* Steady-state gain of the secondary path at hz, measured with a sine. */
static double path_gain(Twin &t, double hz, double seconds = 1.0) {
    const double fs = t.config().fs;
    const size_t n = static_cast<size_t>(seconds * fs);
    std::vector<float> out(n / 2);
    for (size_t i = 0; i < n; ++i) {
        const float e = t.step(static_cast<float>(0.05 * std::sin(twin::kTau * hz * static_cast<double>(i) / fs))).error;
        if (i >= n / 2) out[i - n / 2] = e;
    }
    return std::abs(demod(out, fs, hz, static_cast<double>(n / 2) / fs));
}

/* Path physics --------------------------------------------------------------- */

static void test_path_delay(double fs) {
    Config c = quiet(fs);
    Twin t(c);
    const std::vector<float> h = impulse_response(t, static_cast<size_t>(0.02 * fs));
    const double want = (1.0 / twin::speedOfSound(20.0) + 0.001) * fs;
    const double got = static_cast<double>(peak_index(h));
    CHECK(std::fabs(got - want) <= 1.0, "%.0f Hz: path peak at %.0f, want %.1f", fs, got, want);
}

static void test_temperature(double fs) {
    double peak[2];
    const double temps[2] = {0.0, 40.0};
    for (int k = 0; k < 2; ++k) {
        Config c = quiet(fs);
        c.temperatureC = temps[k];
        c.listener = {5.0, 0};
        Twin t(c);
        peak[k] = static_cast<double>(peak_index(impulse_response(t, static_cast<size_t>(0.04 * fs))));
    }
    const double want = 5.0 * (1.0 / twin::speedOfSound(0.0) - 1.0 / twin::speedOfSound(40.0)) * fs;
    CHECK(std::fabs((peak[0] - peak[1]) - want) <= 1.5, "%.0f Hz: 0 to 40 C shifts %.1f frames, want %.1f", fs,
          peak[0] - peak[1], want);

    /* Drift: the path delay follows the temperature as the run goes on. */
    Config c = quiet(fs);
    c.listener = {5.0, 0};
    c.temperatureRateCPerS = 10.0;
    Twin t(c);
    const double d0 = t.pathDelaySeconds();
    for (size_t i = 0; i < static_cast<size_t>(2.0 * fs); ++i) t.step(0.0f);
    const double d1 = t.pathDelaySeconds();
    const double want1 = 5.0 / twin::speedOfSound(40.0) + 0.001;
    CHECK(d1 < d0 && std::fabs(d1 - want1) < 2e-6, "%.0f Hz: drifted delay %.6f s, want %.6f", fs, d1, want1);
}

static void test_room_modes(double fs) {
    Config base = quiet(fs);
    Config withMode = base;
    withMode.modes = {Mode{60.0, 8.0, 12.0}};
    Twin a(base), b(withMode);
    const double ref = path_gain(a, 60.0);
    const double mode = path_gain(b, 60.0);
    const double off = path_gain(b, 150.0) / path_gain(a, 150.0);
    CHECK(std::fabs(20 * std::log10(mode / ref) - 12.0) < 0.6, "%.0f Hz: 60 Hz mode %.2f dB, want 12", fs,
          20 * std::log10(mode / ref));
    CHECK(std::fabs(20 * std::log10(off)) < 1.5, "%.0f Hz: 150 Hz off-mode %.2f dB", fs, 20 * std::log10(off));
}

static void test_noise_and_determinism(double fs) {
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = -60;
    c.seed = 7;
    Twin a(c), b(c);
    const size_t n = static_cast<size_t>(fs);
    double sum = 0;
    bool same = true;
    for (size_t i = 0; i < n; ++i) {
        const Frame fa = a.step(0.0f), fb = b.step(0.0f);
        same = same && fa.error == fb.error && fa.reference == fb.reference;
        sum += static_cast<double>(fa.error) * fa.error;
    }
    CHECK(same, "%.0f Hz: same seed gave different output", fs);
    CHECK(std::fabs(db(sum / static_cast<double>(n)) - (-60.0)) < 0.5, "%.0f Hz: mic noise %.2f dB, want -60", fs,
          db(sum / static_cast<double>(n)));
}

/* Doppler: a listener moving away from a 100 Hz source at 5 m/s hears it
 * lowered by f v / c. */
static void test_moving_listener(double fs) {
    Config c = quiet(fs);
    c.sources = {Source{100.0, 0.1, 0.0, {0, 0}, {0, 0}}};
    c.speaker = {0, 5};
    c.listener = {1, 0};
    c.listenerVelocity = {5.0, 0};
    Twin t(c);
    const size_t n = static_cast<size_t>(fs);
    std::vector<float> e(n);
    for (size_t i = 0; i < n; ++i) e[i] = t.step(0.0f).error;
    auto window = [&](double from) {
        const size_t i0 = static_cast<size_t>(from * fs);
        return std::vector<float>(e.begin() + static_cast<long>(i0), e.begin() + static_cast<long>(i0 + static_cast<size_t>(0.2 * fs)));
    };
    const cd a = demod(window(0.1), fs, 100.0, 0.1);
    const cd b = demod(window(0.35), fs, 100.0, 0.35);
    const double dHz = std::arg(b / a) / twin::kTau / 0.25;
    const double want = -100.0 * 5.0 / twin::speedOfSound(20.0);
    CHECK(std::fabs(dHz - want) < 0.1 * std::fabs(want), "%.0f Hz: Doppler %.3f Hz, want %.3f", fs, dHz, want);
}

/* Microphone clock +500 ppm: a 150 Hz tone reads 150.075 Hz. */
static void test_clock_drift(double fs) {
    Config c = quiet(fs);
    c.sources = {Source{150.0, 0.1, 0.0, {-1, 0}, {0, 0}}};
    c.clockDriftPPM = 500.0;
    Twin t(c);
    const size_t n = static_cast<size_t>(2.0 * fs);
    std::vector<float> e(n);
    for (size_t i = 0; i < n; ++i) e[i] = t.step(0.0f).error;
    auto window = [&](double from) {
        const size_t i0 = static_cast<size_t>(from * fs);
        return std::vector<float>(e.begin() + static_cast<long>(i0), e.begin() + static_cast<long>(i0 + static_cast<size_t>(0.3 * fs)));
    };
    const cd a = demod(window(0.1), fs, 150.0, 0.1);
    const cd b = demod(window(1.5), fs, 150.0, 1.5);
    const double dHz = std::arg(b / a) / twin::kTau / 1.4;
    CHECK(std::fabs(dHz - 0.075) < 0.0075, "%.0f Hz: clock drift read %.4f Hz, want 0.075", fs, dHz);
}

/* Faults ---------------------------------------------------------------------- */

static void test_faults(double fs) {
    const size_t n = static_cast<size_t>(0.5 * fs);
    {   /* Unplug: floor only, whatever the room does. */
        Config c;
        c.fs = fs;
        c.micNoiseDBFS = -95;
        c.sources = {Source{80.0, 0.2, 0.0, {-1, 0}, {0, 0}}};
        Twin t(c);
        t.inject(Fault::MicUnplug);
        double sum = 0;
        for (size_t i = 0; i < n; ++i) {
            const float e = t.step(0.3f).error;
            sum += static_cast<double>(e) * e;
        }
        CHECK(std::fabs(db(sum / static_cast<double>(n)) - (-95.0)) < 1.0, "%.0f Hz: unplugged floor %.1f dB", fs,
              db(sum / static_cast<double>(n)));
        Twin u(c);
        u.inject(Fault::MicUnplug, 1.0);
        CHECK(std::isnan(u.step(0.0f).error), "%.0f Hz: NaN unplug", fs);
    }
    {   /* Frozen: repeats; Clear releases. */
        Config c;
        c.fs = fs;
        c.sources = {Source{80.0, 0.2, 0.0, {-1, 0}, {0, 0}}};
        Twin t(c);
        for (size_t i = 0; i < 100; ++i) t.step(0.0f);
        t.inject(Fault::MicFrozen);
        const float held = t.step(0.0f).error;
        bool constant = true;
        for (size_t i = 0; i < 1000; ++i) constant = constant && t.step(0.0f).error == held;
        CHECK(constant, "%.0f Hz: frozen mic moved", fs);
        t.inject(Fault::Clear);
        bool moved = false;
        for (size_t i = 0; i < 1000; ++i) moved = moved || t.step(0.0f).error != held;
        CHECK(moved, "%.0f Hz: mic still frozen after Clear", fs);
    }
    {   /* Clipped: the +-1 limit is hit. */
        Config c = quiet(fs);
        c.sources = {Source{80.0, 0.2, 0.0, {-1, 0}, {0, 0}}};
        Twin t(c);
        t.inject(Fault::MicClipped);
        size_t clipped = 0;
        for (size_t i = 0; i < n; ++i) clipped += std::fabs(t.step(0.0f).error) >= 1.0f ? 1u : 0u;
        CHECK(clipped > n / 4, "%.0f Hz: only %zu of %zu samples clipped", fs, clipped, n);
    }
    {   /* Volume change: +6 dB doubles the path gain. */
        Config c = quiet(fs);
        Twin a(c), b(c);
        b.inject(Fault::VolumeChange, 6.0);
        const double r = 20 * std::log10(path_gain(b, 80.0, 0.5) / path_gain(a, 80.0, 0.5));
        CHECK(std::fabs(r - 6.0) < 0.05, "%.0f Hz: volume change %.3f dB, want 6", fs, r);
    }
    {   /* Mic moved by 0.5 m: delay and level change as the geometry says. */
        Config c = quiet(fs);
        Twin t(c);
        const double d0 = t.pathDelaySeconds();
        t.inject(Fault::MicMoved, 0.5);
        const double d1 = t.pathDelaySeconds();
        CHECK(std::fabs((d1 - d0) - 0.5 / twin::speedOfSound(20.0)) < 1e-9, "%.0f Hz: moved delay %.9f", fs, d1 - d0);
        const std::vector<float> h = impulse_response(t, static_cast<size_t>(0.02 * fs));
        CHECK(std::fabs(static_cast<double>(peak_index(h)) - d1 * fs) <= 1.0, "%.0f Hz: moved mic peak %zu, want %.1f", fs,
              peak_index(h), d1 * fs);
    }
    {   /* Device loss: everything goes quiet and the speaker is dropped. */
        Config c = quiet(fs);
        c.sources = {Source{80.0, 0.2, 0.0, {-1, 0}, {0, 0}}};
        Twin t(c);
        t.inject(Fault::DeviceLoss);
        bool zero = true;
        for (size_t i = 0; i < 1000; ++i) {
            const Frame f = t.step(0.5f);
            zero = zero && f.error == 0.0f && f.reference == 0.0f;
        }
        CHECK(zero, "%.0f Hz: device loss still produced signal", fs);
    }
    {   /* Rate change: the same physical path at the new rate. */
        Config c = quiet(fs);
        Twin t(c);
        for (size_t i = 0; i < 1000; ++i) t.step(0.1f);
        const double newFs = fs == 48000.0 ? 96000.0 : 48000.0;
        t.inject(Fault::VolumeChange, -3.0);
        t.changeRate(newFs);
        CHECK(t.rateChanges() == 1 && t.config().fs == newFs, "%.0f Hz: rate change not recorded", fs);
        const std::vector<float> h = impulse_response(t, static_cast<size_t>(0.02 * newFs));
        CHECK(std::fabs(static_cast<double>(peak_index(h)) / newFs - (1.0 / twin::speedOfSound(20.0) + 0.001)) < 1.5 / newFs,
              "%.0f to %.0f Hz: path moved by the rate change", fs, newFs);
    }
}

/* Closed loop: adaptive tonal canceller in the twin ---------------------------- */

struct Loop {
    Twin plant;
    N60AdaptiveTonal *core;
    uint32_t buffer;
    std::vector<float> out, played, err;
    double fs;

    Loop(const Config &c, const N60AdaptiveTonalConfig &tc, uint32_t buf)
        : plant(c), core(N60AdaptiveTonalCreate(&tc)), buffer(buf), out(buf, 0.0f), played(buf, 0.0f), err(buf, 0.0f), fs(c.fs) {}
    ~Loop() { N60AdaptiveTonalDestroy(core); }

    /* Runs and returns the tone amplitude in the error over the last half
     * second of the run (hz). */
    double run(double seconds, double hz) {
        const auto buffers = static_cast<uint64_t>(std::ceil(seconds * fs / buffer));
        std::vector<float> tail;
        for (uint64_t b = 0; b < buffers; ++b) {
            for (uint32_t n = 0; n < buffer; ++n) {
                err[n] = plant.step(played[n]).error;
                if (static_cast<double>(b * buffer + n) >= seconds * fs - 0.5 * fs) tail.push_back(err[n]);
            }
            N60AdaptiveTonalProcess(core, err.data(), out.data(), buffer);
            N60AdaptiveTonalService(core);
            played.swap(out);
        }
        return std::abs(demod(tail, fs, hz, plant.frame() / fs - static_cast<double>(tail.size()) / fs));
    }
};

static void test_tonal_loop(double fs) {
    const double hz = 80.0;
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = -100;
    c.seed = 3;
    c.sources = {Source{hz, 0.02, 0.4, {-2, 0}, {0, 0}}};
    c.modes = {Mode{60.0, 6.0, 4.0}};
    c.temperatureRateCPerS = 0.05;
    N60AdaptiveTonalConfig tc = N60AdaptiveTonalConfigDefault(fs);
    tc.toneCount = 1;
    tc.toneHz[0] = static_cast<float>(hz);
    tc.probeEnabled = true;
    const double uncancelled = 0.02 / 3.0;
    Loop l(c, tc, 256);
    const double after = l.run(8.0, hz);
    CHECK(20 * std::log10(after / uncancelled) < -15.0, "%.0f Hz: tonal canceller only %.1f dB in the twin", fs,
          20 * std::log10(after / uncancelled));
    printf("  tonal loop %6.0f Hz: %.1f dB\n", fs, 20 * std::log10(after / uncancelled));

    /* The listener moves 0.25 m: the canceller finds the new path and recovers. */
    l.plant.inject(Fault::MicMoved, 0.25);
    const double recovered = l.run(10.0, hz);
    CHECK(20 * std::log10(recovered / uncancelled) < -12.0, "%.0f Hz: no recovery after mic moved: %.1f dB", fs,
          20 * std::log10(recovered / uncancelled));
}

/* Closed loop: howl guard on a feedback path in the twin ----------------------- */

/* The anti-noise is the error microphone fed back through a gain: stable at a
 * low gain, a howl once a volume change lifts the loop gain past one. */
static void test_howl_guard(double fs) {
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = -90;
    c.seed = 5;
    c.sources = {Source{80.0, 0.01, 0.0, {-2, 0}, {0, 0}}};
    Twin plant(c);
    N60AncGuardConfig gc = N60AncGuardConfigDefault(fs);
    N60AncGuard *guard = N60AncGuardCreate(&gc);
    CHECK(guard != nullptr, "%.0f Hz: guard", fs);
    if (!guard) return;
    const uint32_t buffer = 128;
    std::vector<float> anti(buffer, 0.0f), err(buffer, 0.0f), played(buffer, 0.0f);
    const float feedback = 0.2f;
    uint64_t faultFrame = 0;
    bool faulted = false;
    const uint64_t total = static_cast<uint64_t>(1.5 * fs);
    double muteLevel = 0;
    for (uint64_t done = 0; done < total; done += buffer) {
        if (!faulted && done >= static_cast<uint64_t>(0.5 * fs)) {
            plant.inject(Fault::VolumeChange, 26.0);
            faultFrame = done;
            faulted = true;
        }
        for (uint32_t n = 0; n < buffer; ++n) err[n] = plant.step(played[n]).error;
        for (uint32_t n = 0; n < buffer; ++n) anti[n] = feedback * err[n];
        N60AncGuardProcess(guard, anti.data(), nullptr, err.data(), buffer);
        played = anti;
        if (done > total - static_cast<uint64_t>(0.3 * fs)) {
            for (uint32_t n = 0; n < buffer; ++n) muteLevel = std::fmax(muteLevel, std::fabs(anti[n]));
        }
    }
    const N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.tripped && st.trip != N60AncGuardTripNone, "%.0f Hz: howl onset did not trip the guard", fs);
    CHECK(st.tripFrame >= faultFrame - 2 * buffer && st.tripFrame <= faultFrame + static_cast<uint64_t>(0.15 * fs) + 2 * buffer,
          "%.0f Hz: tripped %.1f ms after onset", fs, (static_cast<double>(st.tripFrame) - static_cast<double>(faultFrame)) * 1000.0 / fs);
    CHECK(st.muted && muteLevel < 1e-3, "%.0f Hz: output %.4f after mute", fs, muteLevel);
    N60AncGuardDestroy(guard);
}

static void test_guard_nonfinite_mic(double fs) {
    Config c;
    c.fs = fs;
    Twin plant(c);
    N60AncGuardConfig gc = N60AncGuardConfigDefault(fs);
    gc.hasErrorBaseline = true;
    for (float &b : gc.errorBaselineDB) b = -40.0f;
    N60AncGuard *guard = N60AncGuardCreate(&gc);
    if (!guard) {
        CHECK(false, "%.0f Hz: guard", fs);
        return;
    }
    const uint32_t buffer = 128;
    std::vector<float> anti(buffer, 0.01f), err(buffer);
    for (int b = 0; b < 100; ++b) {
        for (uint32_t n = 0; n < buffer; ++n) err[n] = plant.step(0.0f).error;
        N60AncGuardProcess(guard, anti.data(), nullptr, err.data(), buffer);
    }
    CHECK(N60AncGuardReadStatus(guard).trip == N60AncGuardTripNone, "%.0f Hz: healthy loop tripped", fs);
    plant.inject(Fault::MicUnplug, 1.0);
    for (uint32_t n = 0; n < buffer; ++n) err[n] = plant.step(0.0f).error;
    anti.assign(buffer, 0.01f);
    N60AncGuardProcess(guard, anti.data(), nullptr, err.data(), buffer);
    CHECK(N60AncGuardReadStatus(guard).trip == N60AncGuardTripNonFinite, "%.0f Hz: NaN mic did not trip the guard", fs);
    N60AncGuardDestroy(guard);
}

/* Soak: drift, a moving listener and a fault sequence over a long run. */
static void test_soak(double fs) {
    const double hz = 80.0;
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = -100;
    c.clockDriftPPM = 20.0;
    c.sources = {Source{hz, 0.02, 0.4, {-2, 0}, {0.002, 0}}};
    c.listenerVelocity = {0.002, 0};
    c.temperatureRateCPerS = 0.02;
    c.modes = {Mode{60.0, 6.0, 4.0}};
    N60AdaptiveTonalConfig tc = N60AdaptiveTonalConfigDefault(fs);
    tc.toneCount = 1;
    tc.toneHz[0] = static_cast<float>(hz);
    tc.probeEnabled = true;
    Loop l(c, tc, 256);
    const double base = 0.02 / 3.0;
    double worst = -1e9;
    l.run(10.0, hz);
    for (int minute = 0; minute < 30; ++minute) {
        const double a = l.run(10.0, hz);
        worst = std::fmax(worst, 20 * std::log10(a / base));
        if (minute == 10) l.plant.inject(Fault::VolumeChange, -4.0);
        if (minute == 20) l.plant.inject(Fault::MicMoved, -0.3);
    }
    CHECK(worst < -10.0, "%.0f Hz: soak held only %.1f dB through drift and faults", fs, -worst);
    printf("  soak %6.0f Hz: worst-case %.1f dB\n", fs, worst);
}

int main(int argc, char **argv) {
    const bool soak = argc > 1 && std::strcmp(argv[1], "--soak") == 0;
    if (soak) {
        test_soak(48000);
        test_soak(384000);
    } else {
        for (const double fs : kRates) {
            test_path_delay(fs);
            test_temperature(fs);
            test_room_modes(fs);
            test_noise_and_determinism(fs);
            test_moving_listener(fs);
            test_clock_drift(fs);
            test_faults(fs);
            test_tonal_loop(fs);
            test_howl_guard(fs);
            test_guard_nonfinite_mic(fs);
        }
    }
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("e4_acoustic_twin: ok");
    return 0;
}
