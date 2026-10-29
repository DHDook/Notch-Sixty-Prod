/*
 * E4 S18a: behavioural harness for the remote adaptive tonal canceller
 * (N60RemoteTonal.h) in the acoustic twin (ci/e4_acoustic_twin.hpp).
 *
 * The harness stands in for the live path: a "kernel" plays fixed complex gains per tone and
 * emits telemetry (host time, phasor, gain playing) every 5 ms, the twin's error microphone is
 * delivered in 250 ms blocks stamped with the host time of the block's first frame, and the
 * worker's next gain record reaches the kernel after an optional delay and a 100 ms crossfade.
 * The microphone clock may drift against the output clock; host time is the common axis.
 *
 * Usage: harness_e4_remote_tonal [--soak]
 * Default: short cases at the eight standard rates (pr.yml). --soak adds one hour of
 * temperature drift (macos-full.yml).
 */
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <vector>

#include "N60RemoteTonal.h"
#include "e4_acoustic_twin.hpp"

using twin::Config;
using twin::Fault;
using twin::Mode;
using twin::Source;
using twin::Twin;
using cd = std::complex<double>;

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kTicks = 1e9;
static const uint64_t kBase = 1000000000ull;
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static double dbr(double ratio) { return 20.0 * std::log10(std::max(ratio, 1e-12)); }
static const double kNoNoise = -std::numeric_limits<double>::infinity();

/* Truth for a scenario, from a static copy of the twin: secondary path S and disturbance D at
 * each tone, both relative to the kernel phasor exp(j 2 pi f k / fs). */
struct Truth {
    std::vector<cd> S, D;
};

static cd demod_phasor(const std::vector<float> &x, double fs, double hz, size_t first) {
    cd acc = 0;
    const size_t n = x.size() - first;
    for (size_t i = first; i < x.size(); ++i) {
        acc += static_cast<double>(x[i]) * std::polar(1.0, -twin::kTau * hz * static_cast<double>(i) / fs);
    }
    return 2.0 * acc / static_cast<double>(n);
}

static Truth calibrate(Config c, const std::vector<double> &hz) {
    c.clockDriftPPM = 0;
    c.temperatureRateCPerS = 0;
    c.micNoiseDBFS = kNoNoise;
    const size_t frames = static_cast<size_t>(3.0 * c.fs);
    Truth t;
    {
        Config quiet = c;
        quiet.sources.clear();
        Twin plant(quiet);
        std::vector<float> e(frames);
        const double amp = 0.05;
        for (size_t i = 0; i < frames; ++i) {
            double y = 0;
            for (double f : hz) y += amp * std::cos(twin::kTau * f * static_cast<double>(i) / c.fs);
            e[i] = plant.step(static_cast<float>(y)).error;
        }
        for (double f : hz) t.S.push_back(demod_phasor(e, c.fs, f, frames / 3) / amp);
    }
    {
        Twin plant(c);
        std::vector<float> e(frames);
        for (size_t i = 0; i < frames; ++i) e[i] = plant.step(0.0f).error;
        for (double f : hz) t.D.push_back(demod_phasor(e, c.fs, f, frames / 3));
    }
    return t;
}

struct Sim {
    Config cfg;
    Twin plant;
    N60RemoteTonal *core = nullptr;
    double fs;
    std::vector<double> hz;
    uint32_t n;
    double applyDelay = 0.0;
    double drift;
    uint64_t k = 0;
    uint64_t blockFrames;
    std::vector<float> block;
    uint64_t blockStart = 0;
    uint64_t teleEvery;
    cd G[4] = {}, start[4] = {}, target[4] = {};
    double fade = 1.0;
    double fadeStep;
    struct Pending {
        uint64_t at;
        cd g[4];
    };
    std::deque<Pending> pending;
    bool adaptEnabled = true;
    /* E4 S19: kernel oscillator with a glide, and the worker's frequency tracking. */
    bool tracking = false;
    std::vector<double> ph, fnow, ftarget, fstep;
    uint64_t tailSqN = 0;
    double tailSq = 0;
    double maxGain = 0;
    uint64_t latchedBlocks = 0;
    // Tail measurement of the error microphone.
    uint64_t tailFrom = ~0ull;
    cd tailAcc[4] = {};
    uint64_t tailN = 0;

    Sim(const Config &c, const std::vector<double> &tones, const Truth &truth, double micRatePPM = 0.0)
        : cfg(c), plant(c), fs(c.fs), hz(tones), n(static_cast<uint32_t>(tones.size())),
          drift(1.0 + c.clockDriftPPM * 1e-6) {
        blockFrames = static_cast<uint64_t>(0.25 * fs);
        block.reserve(blockFrames);
        teleEvery = std::max<uint64_t>(1, static_cast<uint64_t>(0.005 * fs));
        fadeStep = 1.0 / (0.1 * fs);
        N60RemoteTonalConfig rc = N60RemoteTonalConfigDefault(fs, kTicks);
        /* The core is told the nominal rate; the stream really runs micRatePPM faster. */
        rc.micSampleRate = fs * (1.0 - micRatePPM * 1e-6);
        rc.hostTicksPerSecond = kTicks;
        rc.toneCount = n;
        for (uint32_t i = 0; i < n; ++i) {
            rc.toneHz[i] = static_cast<float>(hz[i]);
            rc.leftShare[i] = {1.0f, 0.0f};
            rc.rightShare[i] = {0.0f, 0.0f};
            rc.pathSeed[i] = {static_cast<float>(truth.S[i].real()), static_cast<float>(truth.S[i].imag())};
            rc.weightSeed[i] = {0.0f, 0.0f};
        }
        core = N60RemoteTonalCreate(&rc);
        ph.assign(n, 0.0);
        fnow = hz;
        ftarget = hz;
        fstep.assign(n, 0.0);
    }
    ~Sim() { N60RemoteTonalDestroy(core); }

    double seconds() const { return static_cast<double>(k) / fs; }

    void push_telemetry() {
        N60ActiveQuietZoneTelemetryRecord r;
        std::memset(&r, 0, sizeof(r));
        r.hostTime = kBase + static_cast<uint64_t>(seconds() * kTicks);
        r.renderedFrame = k;
        r.toneCount = n;
        for (uint32_t i = 0; i < n; ++i) {
            r.frequencyHz[i] = static_cast<float>(fnow[i]);
            r.phasorCosine[i] = std::cos(ph[i]);
            r.phasorSine[i] = std::sin(ph[i]);
            r.gain[i][0] = static_cast<float>(G[i].real());
            r.gain[i][1] = static_cast<float>(G[i].imag());
        }
        N60RemoteTonalPushTelemetry(core, &r);
    }

    /* A block is handed over 20 ms after its last sample was taken (on the microphone clock), as a
     * poll would, so the microphone clock running ahead of the output clock never delivers
     * samples from the future of the telemetry. */
    struct Block {
        std::vector<float> samples;
        uint64_t hostTicks;
        double readyAt;  /* output-clock seconds */
    };
    std::deque<Block> blocks;

    void close_block() {
        Block b;
        b.samples.swap(block);
        b.hostTicks = kBase + static_cast<uint64_t>(static_cast<double>(blockStart) * drift / fs * kTicks);
        b.readyAt = static_cast<double>(k) * drift / fs + 0.02;
        blocks.push_back(std::move(b));
        block.reserve(blockFrames);
        blockStart = k;
    }

    void service_blocks() {
        while (!blocks.empty() && blocks.front().readyAt <= seconds()) {
            const Block &b = blocks.front();
            N60RemoteTonalProcessMic(core, b.samples.data(), static_cast<uint32_t>(b.samples.size()), b.hostTicks);
            blocks.pop_front();
            hand_over_record();
        }
    }

    void track_frequency() {
        if (!tracking) return;
        const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(core);
        for (uint32_t i = 0; i < n; ++i) {
            if (std::fabs(st.suggestedHz[i] - ftarget[i]) < 1e-4) continue;
            if (!N60RemoteTonalSetToneFrequency(core, i, st.suggestedHz[i], nullptr)) continue;
            ftarget[i] = st.suggestedHz[i];
            fstep[i] = (ftarget[i] - fnow[i]) / (0.1 * fs);
        }
    }

    void hand_over_record() {
        track_frequency();
        N60ActiveQuietZoneGainRecord rec;
        if (adaptEnabled && N60RemoteTonalNextRecord(core, 1, 0.0f, &rec)) {
            Pending p;
            p.at = k + static_cast<uint64_t>(applyDelay * fs);
            for (uint32_t i = 0; i < n; ++i) p.g[i] = cd{rec.gain[i][0], rec.gain[i][1]};
            pending.push_back(p);
        }
    }

    void run(double secs) {
        const uint64_t end = k + static_cast<uint64_t>(secs * fs);
        while (k < end) {
            if (k % teleEvery == 0) push_telemetry();
            while (!pending.empty() && pending.front().at <= k) {
                for (uint32_t i = 0; i < n; ++i) {
                    start[i] = G[i];
                    target[i] = pending.front().g[i];
                }
                fade = 0.0;
                pending.pop_front();
            }
            if (fade < 1.0) {
                fade = std::min(1.0, fade + fadeStep);
                for (uint32_t i = 0; i < n; ++i) G[i] = start[i] + (target[i] - start[i]) * fade;
            }
            double y = 0;
            for (uint32_t i = 0; i < n; ++i) {
                y += G[i].real() * std::cos(ph[i]) - G[i].imag() * std::sin(ph[i]);
                maxGain = std::max(maxGain, std::abs(G[i]));
                ph[i] += twin::kTau * fnow[i] / fs;
                if (ph[i] >= twin::kTau) ph[i] -= twin::kTau;
                if (fnow[i] != ftarget[i]) {
                    fnow[i] += fstep[i];
                    if (std::fabs(ftarget[i] - fnow[i]) <= std::fabs(fstep[i])) fnow[i] = ftarget[i];
                }
            }
            const float e = plant.step(static_cast<float>(y)).error;
            block.push_back(e);
            if (k >= tailFrom) {
                tailSq += static_cast<double>(e) * e;
                ++tailSqN;
            }
            if (k >= tailFrom) {
                const double t = static_cast<double>(k) * drift / fs;
                for (uint32_t i = 0; i < n; ++i) tailAcc[i] += static_cast<double>(e) * std::polar(1.0, -twin::kTau * hz[i] * t);
                ++tailN;
            }
            ++k;
            if (block.size() >= blockFrames) close_block();
            service_blocks();
        }
    }

    /* Runs secs and returns the error-mic tone amplitude over the last second. */
    void run_measured(double secs) {
        tailFrom = k + static_cast<uint64_t>(std::max(0.0, secs - 1.0) * fs);
        for (cd &a : tailAcc) a = 0;
        tailN = 0;
        tailSq = 0;
        tailSqN = 0;
        run(secs);
        tailFrom = ~0ull;
    }
    double tail_rms() const { return std::sqrt(tailSq / static_cast<double>(std::max<uint64_t>(tailSqN, 1))); }
    double tail_amp(uint32_t i) const { return std::abs(2.0 * tailAcc[i] / static_cast<double>(std::max<uint64_t>(tailN, 1))); }
};

static Config scenario(double fs, std::vector<double> hz, uint64_t seed = 3) {
    Config c;
    c.fs = fs;
    c.micNoiseDBFS = -100;
    c.seed = seed;
    c.modes = {Mode{60.0, 6.0, 4.0}};
    double phase = 0.4;
    for (double f : hz) {
        c.sources.push_back(Source{f, 0.02, phase, {-2, 0}, {0, 0}});
        phase += 0.9;
    }
    return c;
}

/* Cases ------------------------------------------------------------------------ */

static void test_converge(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    c.temperatureRateCPerS = 0.05;
    const Truth truth = calibrate(c, hz);
    const double a0 = std::abs(truth.D[0]);

    /* Oracle: the exact weight -D/S with the same dither. */
    Sim oracle(c, hz, truth);
    const N60AncComplex w = {static_cast<float>((-truth.D[0] / truth.S[0]).real()), static_cast<float>((-truth.D[0] / truth.S[0]).imag())};
    N60RemoteTonalSetWeights(oracle.core, &w, 1);
    N60RemoteTonalSetHold(oracle.core, true);
    oracle.run_measured(6.0);
    const double ref = oracle.tail_amp(0);

    Sim sim(c, hz, truth);
    sim.run_measured(10.0);
    const double after = sim.tail_amp(0);
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
    CHECK(dbr(after / a0) < -20.0, "%.0f Hz: only %.1f dB below the uncancelled tone", fs, dbr(after / a0));
    CHECK(dbr(after / ref) < 1.0, "%.0f Hz: %.2f dB worse than the oracle in 10 s", fs, dbr(after / ref));
    CHECK(st.uncoveredBlocks == 0 && st.modelResets == 0 && !st.micMoved, "%.0f Hz: uncovered %llu resets %llu moved %d", fs,
          static_cast<unsigned long long>(st.uncoveredBlocks), static_cast<unsigned long long>(st.modelResets), st.micMoved);
    printf("  converge  %6.0f Hz: %.1f dB (oracle %.1f dB)\n", fs, dbr(after / a0), dbr(ref / a0));
}

static void test_path_step(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    const Truth t0 = calibrate(c, hz);
    Sim sim(c, hz, t0);
    sim.run(8.0);
    /* 0.36 m closer to the far wall: the path turns about 30 degrees at 80 Hz. */
    sim.plant.inject(Fault::MicMoved, 0.36);
    Config moved = c;
    moved.listener.x += 0.36;
    const Truth t1 = calibrate(moved, hz);
    const double deg = std::arg(t1.S[0] / t0.S[0]) * 57.29578;
    CHECK(std::fabs(deg) > 25.0 && std::fabs(deg) < 36.0, "%.0f Hz: scenario path step %.1f degrees", fs, deg);
    sim.run_measured(5.0);
    const double after = sim.tail_amp(0);
    CHECK(dbr(after / std::abs(t1.D[0])) < -15.0, "%.0f Hz: %.1f dB 5 s after a %.0f degree path step", fs,
          dbr(after / std::abs(t1.D[0])), deg);
    printf("  path step %6.0f Hz: %.0f deg, %.1f dB after 5 s\n", fs, deg, dbr(after / std::abs(t1.D[0])));
}

/* Two tones. A path change the loop can see (the speaker's level to the microphone changes
   while the disturbance does not) is flagged within about 2 s. A microphone move along the
   disturbance's own axis rotates the disturbance and the path together: the cancelling weight
   is unchanged, so the loop stays cancelled and nothing is flagged for it (the move is harmless
   to the canceller and invisible to a cancelled loop). A tiny move never latches. */
static void test_mic_moved(double fs) {
    const std::vector<double> hz = {80.0, 110.0};
    Config c = scenario(fs, hz);
    const Truth truth = calibrate(c, hz);
    {
        Sim sim(c, hz, truth);
        sim.run(8.0);
        N60RemoteTonalCaptureReference(sim.core);
        sim.plant.inject(Fault::MicMoved, 0.02);
        sim.run(8.0);
        const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
        CHECK(!st.micMoved, "%.0f Hz: 0.02 m move latched mic-moved (kind %u)", fs, st.micMovedKind);
    }
    {
        Sim sim(c, hz, truth);
        sim.run(8.0);
        N60RemoteTonalCaptureReference(sim.core);
        sim.plant.inject(Fault::MicMoved, 0.3);
        sim.run(8.0);
        const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
        const double resid = sim.tail_amp(0);
        CHECK(dbr(resid / std::abs(truth.D[0])) < -15.0, "%.0f Hz: %.1f dB after a 0.3 m move", fs, dbr(resid / std::abs(truth.D[0])));
        (void)st;
    }
    {
        Sim sim(c, hz, truth);
        sim.run(8.0);
        N60RemoteTonalCaptureReference(sim.core);
        const double moveAt = sim.seconds();
        sim.plant.inject(Fault::VolumeChange, 5.0);
        sim.run(3.0);
        const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
        CHECK(st.micMoved, "%.0f Hz: a 5 dB path change was not flagged in 3 s", fs);
        if (st.micMoved) {
            CHECK(st.micMovedAtSeconds - moveAt <= 2.0 + 0.25, "%.0f Hz: flagged %.2f s after the change", fs, st.micMovedAtSeconds - moveAt);
            printf("  path moved %6.0f Hz: flagged %.2f s after a 5 dB change (kind %u)\n", fs, st.micMovedAtSeconds - moveAt, st.micMovedKind);
        }
    }
}

/* The speaker is wired out of phase: positive feedback. Adaptation must not run away. */
/* E4 S18b: the supervised re-solve sequence the controller drives after the microphone moved:
   re-identify the path with the raised dither, adopt it as the reference, acknowledge the move,
   then adapt. The tone must end cancelled again, the latch must be clear and the gain must stay
   inside a bounded multiple of the converged gain throughout. */
static void test_resolve(double fs) {
    const std::vector<double> hz = {80.0, 110.0};
    Config c = scenario(fs, hz);
    const Truth t0 = calibrate(c, hz);
    Sim sim(c, hz, t0);
    sim.run(8.0);
    const double convergedGain = std::max(sim.maxGain, 1e-6);
    sim.plant.inject(Fault::MicMoved, 0.36);
    Config moved = c;
    moved.listener.x += 0.36;
    const Truth t1 = calibrate(moved, hz);
    sim.run(2.0);
    N60RemoteTonalBeginReidentify(sim.core);
    sim.run(3.0);
    N60RemoteTonalEndReidentify(sim.core);
    N60RemoteTonalCaptureReference(sim.core);
    N60RemoteTonalAcknowledgeMove(sim.core);
    sim.run_measured(8.0);
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
    for (uint32_t i = 0; i < 2; ++i) {
        const double after = sim.tail_amp(i);
        CHECK(dbr(after / std::abs(t1.D[i])) < -12.0, "%.0f Hz: tone %u only %.1f dB down after the re-solve", fs, i,
              dbr(after / std::abs(t1.D[i])));
    }
    CHECK(!st.micMoved, "%.0f Hz: mic-moved still latched after the acknowledged re-solve", fs);
    CHECK(sim.maxGain < convergedGain * 8.0 + 1e-3, "%.0f Hz: gain %.4f exceeded a bounded multiple of %.4f", fs, sim.maxGain,
          convergedGain);
    printf("  re-solve  %6.0f Hz: tones %.1f / %.1f dB after, moved=%d\n", fs, dbr(sim.tail_amp(0) / std::abs(t1.D[0])),
           dbr(sim.tail_amp(1) / std::abs(t1.D[1])), st.micMoved);
}

static void test_path_invert(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    const Truth truth = calibrate(c, hz);
    Sim sim(c, hz, truth);
    sim.run(8.0);
    sim.maxGain = 0;
    const double at = sim.seconds();
    sim.plant.inject(Fault::PathInvert);
    sim.run(4.0);
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
    CHECK(st.micMoved, "%.0f Hz: inverted path not flagged within 4 s", fs);
    CHECK(sim.maxGain <= std::pow(10.0, -24.0 / 20.0) * 1.01 + 1e-6, "%.0f Hz: gain reached %.4f (%.1f dBFS) after the inversion", fs,
          sim.maxGain, dbr(sim.maxGain));
    if (st.micMoved) printf("  invert    %6.0f Hz: flagged %.2f s after, peak gain %.1f dBFS\n", fs, st.micMovedAtSeconds - at, dbr(sim.maxGain));
}

/* 100 ppm microphone clock and a 250 ms update delay on top of the 250 ms block. */
static void test_drift_delay(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    c.clockDriftPPM = 100.0;
    c.temperatureRateCPerS = 0.05;
    const Truth truth = calibrate(c, hz);
    Sim sim(c, hz, truth);
    sim.applyDelay = 0.25;
    sim.run_measured(12.0);
    const double a = dbr(sim.tail_amp(0) / std::abs(truth.D[0]));
    CHECK(a < -15.0, "%.0f Hz: %.1f dB with 100 ppm drift and a 250 ms update delay", fs, a);
    CHECK(!N60RemoteTonalReadStatus(sim.core).micMoved, "%.0f Hz: drift latched mic-moved", fs);
    printf("  drift+lag %6.0f Hz: %.1f dB\n", fs, a);
}

/* Non-covered, late and bad blocks are skipped and counted, never adapted on. */
static void test_robustness(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    const Truth truth = calibrate(c, hz);
    Sim sim(c, hz, truth);
    sim.run(4.0);
    const N60RemoteTonalStatus before = N60RemoteTonalReadStatus(sim.core);
    std::vector<float> junk(static_cast<size_t>(0.25 * fs), 0.1f);
    CHECK(!N60RemoteTonalProcessMic(sim.core, junk.data(), static_cast<uint32_t>(junk.size()), 0), "%.0f Hz: unstamped block adapted", fs);
    CHECK(!N60RemoteTonalProcessMic(sim.core, junk.data(), static_cast<uint32_t>(junk.size()), kBase + 900000000000ull),
          "%.0f Hz: block beyond telemetry adapted", fs);
    junk[100] = std::numeric_limits<float>::quiet_NaN();
    const uint64_t stamp = kBase + static_cast<uint64_t>((sim.seconds() - 0.5) * kTicks);
    N60RemoteTonalProcessMic(sim.core, junk.data(), static_cast<uint32_t>(junk.size()), stamp);
    const N60RemoteTonalStatus after = N60RemoteTonalReadStatus(sim.core);
    CHECK(after.uncoveredBlocks >= before.uncoveredBlocks + 2, "%.0f Hz: skipped blocks not counted", fs);
    CHECK(after.nonFiniteSamples >= 1, "%.0f Hz: NaN sample not counted", fs);
    CHECK(std::isfinite(after.weight[0].re) && std::isfinite(after.weight[0].im), "%.0f Hz: weight not finite", fs);
    N60RemoteTonalMarkDiscontinuity(sim.core);
    CHECK(N60RemoteTonalReadStatus(sim.core).gaps == 1, "%.0f Hz: gap not counted", fs);
}

static void test_config_validation() {
    N60RemoteTonalConfig c = N60RemoteTonalConfigDefault(48000.0, kTicks);
    CHECK(!N60RemoteTonalConfigIsValid(&c), "zero tones valid");
    c.toneCount = 1;
    c.toneHz[0] = 80.0f;
    CHECK(N60RemoteTonalConfigIsValid(&c), "default one-tone config invalid");
    N60RemoteTonalConfig d = c;
    d.toneHz[0] = 400.0f;
    CHECK(!N60RemoteTonalConfigIsValid(&d), "400 Hz tone valid");
    d = c;
    d.pathSeed[0] = {0.0f, 0.0f};
    CHECK(!N60RemoteTonalConfigIsValid(&d), "zero path seed valid");
    d = c;
    d.micSampleRate = 1000.0;
    CHECK(!N60RemoteTonalConfigIsValid(&d), "1 kHz microphone valid");
    d = c;
    d.convergenceSeconds = 0.01;
    CHECK(!N60RemoteTonalConfigIsValid(&d), "10 ms convergence valid");
    CHECK(N60RemoteTonalCreate(&d) == nullptr, "invalid config created a core");
}

/* One hour of slow temperature drift: nothing latches and the cancellation holds. */
static void test_soak(double fs, double hours) {
    const std::vector<double> hz = {70.0, 100.0};
    Config c = scenario(fs, hz);
    c.temperatureRateCPerS = 0.002;
    /* The twin's own clock drift would put the microphone ahead of the speaker by more than the
     * path delay after a few minutes (acausal), so the drift is applied to the rate the core is
     * told instead: 30 ppm of nominal-rate error, re-anchored by every block's host time. */
    const Truth truth = calibrate(c, hz);
    Sim sim(c, hz, truth, 30.0);
    sim.run(10.0);
    double worst = -1e9;
    const int chunks = static_cast<int>(hours * 360.0);
    for (int i = 0; i < chunks; ++i) {
        sim.run_measured(10.0);
        for (uint32_t t = 0; t < 2; ++t) worst = std::max(worst, dbr(sim.tail_amp(t) / std::abs(truth.D[t])));
        if (N60RemoteTonalReadStatus(sim.core).micMoved) {
            CHECK(false, "%.0f Hz: mic-moved latched at %.0f s under temperature drift", fs, sim.seconds());
            break;
        }
    }
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
    CHECK(worst < -12.0, "%.0f Hz: worst %.1f dB during %.1f h of drift", fs, worst, hours);
    CHECK(st.modelResets == 0 && st.uncoveredBlocks == 0, "%.0f Hz: resets %llu uncovered %llu", fs,
          static_cast<unsigned long long>(st.modelResets), static_cast<unsigned long long>(st.uncoveredBlocks));
    printf("  soak %6.0f Hz: worst %.1f dB over %.1f h\n", fs, worst, hours);
}

/* E4 S19: a tone drifting at 0.05 Hz/s. The kernel follows it through the PLL and the reduction
 * holds. Faster drift is beyond what the closed loop tracks (see the E4 Log). */
static void test_glide(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    c.temperatureRateCPerS = 0.0;
    const Truth truth = calibrate(c, hz);

    Sim steady(c, hz, truth);
    steady.tracking = true;
    steady.run_measured(18.0);
    Config off = c;
    Sim silent(off, hz, truth);
    silent.adaptEnabled = false;
    silent.run_measured(18.0);
    const double steadyDB = dbr(steady.tail_rms() / silent.tail_rms());

    Config d = c;
    d.sources[0].hzRate = 0.05;
    d.sources[0].hzRateStart = 6.0;
    const Truth truthD = calibrate(c, hz);  /* path and starting disturbance are those of the armed tone */
    Sim moving(d, hz, truthD);
    moving.tracking = true;
    moving.run_measured(18.0);
    Sim movingSilent(d, hz, truthD);
    movingSilent.adaptEnabled = false;
    movingSilent.run_measured(18.0);
    const double movingDB = dbr(moving.tail_rms() / movingSilent.tail_rms());
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(moving.core);
    const double sourceHz = 80.0 + 0.05 * 12.0;
    CHECK(movingDB < -8.0, "%.0f Hz: drifting %.1f dB vs steady %.1f dB", fs, movingDB, steadyDB);
    CHECK(!st.trackingLost && st.locked[0], "%.0f Hz: tracking lost %d locked %d", fs, st.trackingLost, st.locked[0]);
    CHECK(std::fabs(moving.fnow[0] - sourceHz) < 0.3, "%.0f Hz: kernel at %.2f Hz, source at %.2f Hz", fs, moving.fnow[0], sourceHz);
    /* micMoved may latch on a drifting tone (the fit is no longer a fixed path); that is the safe
     * response and the worker disarms. Only silent model resets are excluded. */
    CHECK(st.modelResets == 0, "%.0f Hz: resets %llu", fs, static_cast<unsigned long long>(st.modelResets));
    printf("  glide     %6.0f Hz: %.1f dB drifting (steady %.1f dB), kernel %.2f Hz\n", fs, movingDB, steadyDB, moving.fnow[0]);
}

/* A tone that runs away at 1.5 Hz/s, far faster than the slew limit and past the range: the
 * latched loss of tracking is the signal to disarm. */
static void test_glide_lost(double fs) {
    const std::vector<double> hz = {80.0};
    Config c = scenario(fs, hz);
    const Truth truth = calibrate(c, hz);
    c.sources[0].hzRate = 1.5;
    c.sources[0].hzRateStart = 6.0;
    Sim sim(c, hz, truth);
    sim.tracking = true;
    sim.run(26.0);
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(sim.core);
    CHECK(st.trackingLost, "%.0f Hz: a runaway tone did not latch tracking lost", fs);
    CHECK(sim.fnow[0] <= 80.0 * 1.1 + 0.02, "%.0f Hz: kernel left the range (%.2f Hz)", fs, sim.fnow[0]);
    CHECK(!N60RemoteTonalSetToneFrequency(sim.core, 0, 80.0 * 1.15, nullptr), "%.0f Hz: a 15 %% retune was accepted", fs);
    CHECK(N60RemoteTonalSetToneFrequency(sim.core, 0, 80.0 * 1.05, nullptr), "%.0f Hz: a 5 %% retune was refused", fs);
    printf("  glide lost %5.0f Hz: latched, kernel held at %.2f Hz\n", fs, sim.fnow[0]);
}

int main(int argc, char **argv) {
    const bool soak = argc > 1 && std::strcmp(argv[1], "--soak") == 0;
    if (soak) {
        test_soak(48000, 1.0);
        test_soak(192000, 0.1);
    } else {
        test_config_validation();
        for (const double fs : kRates) {
            test_converge(fs);
            test_path_step(fs);
            test_mic_moved(fs);
            test_resolve(fs);
            test_path_invert(fs);
            test_drift_delay(fs);
            test_robustness(fs);
            test_glide(fs);
            test_glide_lost(fs);
        }
    }
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("e4_remote_tonal: ok");
    return 0;
}
