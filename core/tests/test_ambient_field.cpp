// E21 S10b: behavioural harness for the passive ambient field analysis (n60/anc_design.h v2) through the C ABI at the eight
// standard rates. References are closed forms written here (known tones, known gains, known delays). Parity with the Swift
// analyser is the XCTest AmbientFieldCoreParityTests. Nothing here produces audio or touches a live ANC path.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/anc_design.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

struct Out {
    n60_ambient_result r{};
    std::vector<n60_ambient_band> spectrum, modeled;
    std::vector<n60_ambient_tone> tones;
    std::vector<float> residual;
    int32_t code{0};
};

static Out run(const n60_ambient_config &c, const std::vector<float> &mic, const std::vector<n60_ambient_source> &src, double rate) {
    Out o;
    o.spectrum.resize(N60_AMBIENT_MAX_BANDS);
    o.modeled.resize(N60_AMBIENT_MAX_BANDS);
    o.tones.resize(16);
    o.residual.resize(n60_ambient_window_frames(&c, uint32_t(mic.size())));
    o.code = n60_ambient_analyze(&c, mic.data(), uint32_t(mic.size()), src.empty() ? nullptr : src.data(), uint32_t(src.size()), rate,
                                 &o.r, o.spectrum.data(), o.modeled.data(), o.tones.data(), uint32_t(o.tones.size()),
                                 o.residual.data());
    return o;
}

// Deterministic noise (LCG), no global state.
static std::vector<float> noise(size_t n, double amp, uint32_t seed) {
    std::vector<float> v(n);
    uint32_t s = seed;
    for (auto &x : v) {
        s = s * 1664525u + 1013904223u;
        x = float(amp * (double(s >> 8) / double(1u << 24) * 2.0 - 1.0));
    }
    return v;
}

static void testTone(double rate) {
    n60_ambient_config c;
    n60_ambient_config_default(&c);
    const size_t n = 32768;
    // A 100 Hz tone at amplitude 0.1 plus weak noise: tonal, found within a bin or two, level near -23 dBFS (rms).
    std::vector<float> mic = noise(n, 0.001, 7);
    const double f = 100.0;
    for (size_t i = 0; i < n; ++i) mic[i] += float(0.1 * std::sin(2 * kPi * f * double(i) / rate));
    Out o = run(c, mic, {}, rate);
    CHECK(o.code == N60_ANC_DESIGN_OK, "tone code %d at %.0f", o.code, rate);
    CHECK(o.r.separationMode == N60_AMBIENT_MODE_MICROPHONE_ONLY && o.r.separationConfidence == 1.0, "mic only at %.0f", rate);
    CHECK(std::fabs(o.r.ambientLevelDBFS - (20 * std::log10(0.1 / std::sqrt(2.0)))) < 0.1, "level %.3f at %.0f", o.r.ambientLevelDBFS, rate);
    CHECK(o.r.tonalCount >= 1, "tone found at %.0f", rate);
    if (o.r.tonalCount >= 1) {
        const double bin = rate / 32768.0;
        CHECK(std::fabs(o.tones[0].frequencyHz - f) <= bin * 1.5 + 1e-9, "tone freq %.3f at %.0f", o.tones[0].frequencyHz, rate);
        CHECK(o.tones[0].prominenceDB >= 12, "prominence %.1f", o.tones[0].prominenceDB);
    }
    CHECK(o.r.character == N60_AMBIENT_CHARACTER_TONAL || o.r.character == N60_AMBIENT_CHARACTER_TONAL_PERIODIC, "character %d", o.r.character);
    CHECK(o.r.spectrumCount == 64 && o.spectrum[0].lowerFrequencyHz >= 20.0 && o.spectrum[63].upperFrequencyHz <= 20000.0, "bands");
    CHECK(o.r.stationarityScore > 0.9, "stationary %.3f", o.r.stationarityScore);
    CHECK(o.r.hasPeriodicFrequency == 1 && std::fabs(o.r.periodicFrequencyHz - f) < f * 0.1, "period %.2f", o.r.periodicFrequencyHz);
}

static void testSubtraction(double rate) {
    n60_ambient_config c;
    n60_ambient_config_default(&c);
    const size_t n = 32768;
    // Band-limited program (the alignment search decimates to about 2 kHz, so it needs a smooth correlation peak): four
    // incommensurate tones between 150 and 460 Hz with a little noise.
    std::vector<float> play = noise(n, 0.005, 11);
    for (size_t i = 0; i < n; ++i) {
        for (double f : {150.0, 233.0, 331.0, 457.0}) play[i] += float(0.05 * std::sin(2 * kPi * f * double(i) / rate + f));
    }
    // Acoustic path: 5 tap delay, gain 0.5. Microphone = path * play plus a 60 Hz ambient tone, shifted by a 37 frame
    // transport offset that the alignment search must find (positive: mic[i] matches prediction[i - 37]).
    std::vector<float> ir(16, 0.0f);
    ir[5] = 0.5f;
    const int lag = 37;
    std::vector<float> mic(n, 0.0f);
    for (size_t i = 0; i < n; ++i) {
        const int64_t j = int64_t(i) - lag - 5;
        const double p = j >= 0 ? 0.5 * play[size_t(j)] : 0.0;
        mic[i] = float(p + 0.01 * std::sin(2 * kPi * 60.0 * double(i) / rate));
    }
    n60_ambient_source s{play.data(), ir.data(), uint32_t(ir.size())};
    Out o = run(c, mic, {s}, rate);
    CHECK(o.code == N60_ANC_DESIGN_OK, "sub code %d", o.code);
    CHECK(o.r.separationMode == N60_AMBIENT_MODE_MODELED_SUBTRACTION, "mode %d at %.0f", o.r.separationMode, rate);
    CHECK(o.r.hasAlignment == 1 && o.r.alignmentLagFrames == lag, "lag %d at %.0f", o.r.alignmentLagFrames, rate);
    CHECK(o.r.hasPredictionGain == 1 && std::fabs(o.r.predictionGain - 1.0) < 0.05, "gain %.3f at %.0f", o.r.predictionGain, rate);
    CHECK(o.r.hasModeledSpectrum == 1, "modeled spectrum");
    // The residual keeps the 60 Hz tone and drops the playback: the residual level is the tone's (-43 dBFS) within 0.5 dB.
    CHECK(std::fabs(o.r.ambientLevelDBFS - 20 * std::log10(0.01 / std::sqrt(2.0))) < 0.5, "residual %.1f vs mic %.1f at %.0f", o.r.ambientLevelDBFS,
          o.r.microphoneLevelDBFS, rate);
    CHECK(o.r.separationConfidence > 0.3, "confidence %.3f", o.r.separationConfidence);
}

static void testRefusals() {
    n60_ambient_config c;
    n60_ambient_config_default(&c);
    std::vector<float> mic = noise(8192, 0.1, 3);
    std::vector<float> play = noise(8192, 0.1, 4);
    // Unmodelled audible playback is never read as ambient.
    n60_ambient_source s{play.data(), nullptr, 0};
    Out o = run(c, mic, {s}, 48000);
    CHECK(o.code == 0 && o.r.separationMode == N60_AMBIENT_MODE_MODEL_UNAVAILABLE && std::fabs(o.r.separationConfidence - 0.15) < 1e-12,
          "model unavailable");
    CHECK(run(c, noise(100, 0.1, 1), {}, 48000).code == N60_AMBIENT_ERR_INSUFFICIENT, "short");
    CHECK(run(c, mic, {}, 0.0).code == N60_AMBIENT_ERR_SAMPLE_RATE, "rate");
    std::vector<float> bad = mic;
    bad[10] = NAN;
    CHECK(run(c, bad, {}, 48000).code == N60_AMBIENT_ERR_NONFINITE_MICROPHONE, "nan mic");
    std::vector<float> badp = play;
    badp[3] = INFINITY;
    n60_ambient_source sb{badp.data(), nullptr, 0};
    CHECK(run(c, mic, {sb}, 48000).code == N60_AMBIENT_ERR_NONFINITE_PLAYBACK, "nan playback");
    std::vector<float> zeros(4, 0.0f);
    n60_ambient_source sz{play.data(), zeros.data(), 4};
    CHECK(run(c, mic, {sz}, 48000).code == N60_AMBIENT_ERR_ACOUSTIC_MODEL, "zero impulse");
    n60_ambient_config cc = c;
    cc.spectrumBandCount = 4;
    CHECK(run(cc, mic, {}, 48000).code == N60_AMBIENT_ERR_CONFIGURATION, "config");
    // Negligible playback is ignored: a -90 dBFS reference with no model is not "model unavailable".
    std::vector<float> faint = noise(8192, 3e-5, 5);
    n60_ambient_source sf{faint.data(), nullptr, 0};
    CHECK(run(c, mic, {sf}, 48000).r.separationMode == N60_AMBIENT_MODE_MICROPHONE_ONLY, "faint ignored");
    // Silence is quiet; results are deterministic across calls.
    std::vector<float> silent(8192, 0.0f);
    CHECK(run(c, silent, {}, 48000).r.character == N60_AMBIENT_CHARACTER_QUIET, "quiet");
    Out a = run(c, mic, {}, 48000), b = run(c, mic, {}, 48000);
    CHECK(a.r.ambientLevelDBFS == b.r.ambientLevelDBFS && a.residual == b.residual, "deterministic");
    CHECK(n60_ambient_window_frames(&c, 100000) == 65536 && n60_ambient_window_frames(&c, 5000) == 5000, "window frames");
}

int main() {
    CHECK(n60_anc_design_abi_version() == N60_ANC_DESIGN_ABI_VERSION, "abi");
    for (double r : kRates) {
        testTone(r);
        testSubtraction(r);
    }
    testRefusals();
    if (failures) {
        std::fprintf(stderr, "%d failures\n", failures);
        return 1;
    }
    std::puts("ambient field ok");
    return 0;
}
