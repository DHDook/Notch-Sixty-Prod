// E11 S2: timing reference and repeat averaging through the C ABI at the eight standard rates.
// Two-channel pass model: a reference chirp on the reference speaker at the start of the pass,
// the sweep on the measured speaker 0.3 s after the chirp ends, one microphone hearing both.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/measure.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kRefDelay = 0.003;    // reference speaker to microphone
static const double kMeasDelay = 0.005;   // measured speaker to microphone

struct Pass {
    double fs = 0;
    std::vector<float> chirp, sweep;      // the two program channels, both progLen long
    std::vector<float> chirpOnly;         // the chirp itself
    uint64_t progLen = 0;
};

static Pass makePass(double fs) {
    Pass pass;
    pass.fs = fs;
    n60_measure_chirp_params cp;
    n60_measure_chirp_defaults(fs, &cp);
    uint64_t chirpN = 0;
    CHECK(n60_measure_chirp_length(&cp, &chirpN) == 0, "chirp length");
    pass.chirpOnly.resize(chirpN);
    CHECK(n60_measure_chirp_generate(&cp, pass.chirpOnly.data(), chirpN, &chirpN) == 0, "chirp");

    n60_measure_ess_params ep{};
    ep.sample_rate = fs;
    ep.start_hz = 20;
    ep.end_hz = std::fmin(20000.0, 0.45 * fs);
    ep.duration_seconds = 1.5;
    ep.level_dbfs = -6;
    ep.fade_seconds = 0.02;
    ep.synchronised = 1;
    n60_measure_ess_info info{};
    CHECK(n60_measure_ess_describe(&ep, &info) == 0, "describe");
    std::vector<float> sweep(info.frame_count);
    CHECK(n60_measure_ess_generate(&ep, sweep.data(), sweep.size(), &info) == 0, "sweep");

    const uint64_t sweepStart = chirpN + static_cast<uint64_t>(0.3 * fs);
    pass.progLen = sweepStart + sweep.size();
    pass.chirp.assign(pass.progLen, 0.0f);
    pass.sweep.assign(pass.progLen, 0.0f);
    std::copy(pass.chirpOnly.begin(), pass.chirpOnly.end(), pass.chirp.begin());
    std::copy(sweep.begin(), sweep.end(), pass.sweep.begin() + static_cast<std::ptrdiff_t>(sweepStart));
    return pass;
}

// The room places the direct impulse on a whole sample.
static double directSeconds(double fs, double seconds) { return std::llround(seconds * fs) / fs; }

static n60_measure_room_params roomFor(double fs, double directDelay, double latency, double driftPpm) {
    n60_measure_room_params room;
    n60_measure_room_defaults(fs, &room);
    room.ir_seconds = 0.6;
    room.direct_delay_seconds = directDelay;
    room.latency_seconds = latency;
    room.drift_ppm = driftPpm;
    // Close microphone: the direct arrival dominates the reflections (a reference chirp is
    // only usable when its direct sound is the strongest correlation peak).
    room.diffuse_level_db = -40.0 - 10.0 * std::log10(fs / 48000.0);  // same in-band tail energy at every rate
    for (int m = 0; m < 4; ++m) room.mode_level_db[m] = -30.0;
    return room;
}

static uint64_t captureLength(const Pass &pass, double latency) {
    n60_measure_room_params room = roomFor(pass.fs, kMeasDelay, latency, 0);
    uint64_t total = 0;
    CHECK(n60_measure_room_capture_length(&room, pass.progLen, &total) == 0, "capture length");
    return total;
}

// One microphone capture of a pass: chirp through the reference path plus sweep through the
// measured path, same latency and clock drift, noise added once.
static std::vector<float> capturePass(const Pass &pass, double latency, double driftPpm, double noiseDbfs,
                                      uint32_t noiseSeed, uint64_t frames) {
    std::vector<float> sum(frames, 0.0f);
    for (int which = 0; which < 2; ++which) {
        n60_measure_room_params room = roomFor(pass.fs, which == 0 ? kRefDelay : kMeasDelay, latency, driftPpm);
        room.noise_dbfs = which == 0 ? noiseDbfs : -200.0;
        room.noise_seed = noiseSeed;
        const std::vector<float> &program = which == 0 ? pass.chirp : pass.sweep;
        uint64_t total = 0;
        CHECK(n60_measure_room_capture_length(&room, program.size(), &total) == 0, "len");
        std::vector<float> one(total);
        CHECK(n60_measure_room_capture(&room, program.data(), program.size(), one.data(), total, &total) == 0, "capture");
        for (uint64_t i = 0; i < frames && i < total; ++i) sum[i] += one[i];
    }
    return sum;
}

static uint64_t lcg = 12345;
static double uniform(double lo, double hi) {
    lcg = lcg * 6364136223846793005ull + 1442695040888963407ull;
    return lo + (hi - lo) * (static_cast<double>(lcg >> 40) / 16777216.0);
}

// The acoustic reference recovers t = 0 and the inter-channel delay for random latency; with
// drift the deconvolved sweep peak moves by about the pass length times the drift, which no
// pre-roll reference can know (design note 4), so that term is added to the tolerance.
static void testTiming(double fs, double driftPpm) {
    const Pass pass = makePass(fs);
    for (int trial = 0; trial < (driftPpm == 0.0 ? 2 : 1); ++trial) {
        const double latency = uniform(0.010, 0.200);
        const uint64_t frames = captureLength(pass, 0.2) + 16;
        std::vector<float> capture = capturePass(pass, latency, driftPpm, -60, 100 + trial, frames);
        n60_measure_arrival arrival{};
        CHECK(n60_measure_find_arrival(pass.chirpOnly.data(), pass.chirpOnly.size(), capture.data(), capture.size(), fs,
                                       20.0, &arrival) == 0,
              "fs=%g reference found (%.1f dB)", fs, arrival.peak_to_neighbourhood_db);
        const double expectedArrival = (latency + directSeconds(fs, kRefDelay)) * fs / (1.0 + driftPpm * 1e-6);
        // A stretched chirp correlates with the nominal one about 0.2 s into its length, so drift
        // biases t0 by up to that much (design note 4: drift is reported, not corrected).
        const double t0Allowance = 2.0 + 0.25 * std::fabs(driftPpm) * 1e-6 * fs;
        CHECK(std::fabs(arrival.arrival_frames - expectedArrival) <= t0Allowance,
              "fs=%g t0 off by %.3f samples", fs, arrival.arrival_frames - expectedArrival);

        uint64_t n = 0;
        CHECK(n60_measure_transform_size(capture.size(), &n) == 0, "size");
        std::vector<float> ir(n);
        uint64_t count = 0;
        CHECK(n60_measure_deconvolve(pass.sweep.data(), pass.sweep.size(), capture.data(), capture.size(), 1e-10,
                                     ir.data(), n, &count) == 0, "deconvolve");
        double peak = 0;
        CHECK(n60_measure_peak_position(ir.data(), count, 0, count / 2, &peak) == 0, "peak");
        const double delay = (peak - arrival.arrival_frames) / fs;
        const double allowance = static_cast<double>(pass.progLen) / fs * std::fabs(driftPpm) * 1e-6;
        CHECK(std::fabs(delay - (directSeconds(fs, kMeasDelay) - directSeconds(fs, kRefDelay))) <= 10e-6 + allowance,
              "fs=%g drift=%g inter-channel delay error %.2f us (allowance %.1f us)", fs, driftPpm,
              (delay - (directSeconds(fs, kMeasDelay) - directSeconds(fs, kRefDelay))) * 1e6, (10e-6 + allowance) * 1e6);
        if (trial == 0) {
            std::printf("fs=%-7g drift=%+4.0f ppm t0 error %+.3f samples, delay error %+.2f us\n", fs, driftPpm,
                        arrival.arrival_frames - expectedArrival, (delay - (directSeconds(fs, kMeasDelay) - directSeconds(fs, kRefDelay))) * 1e6);
        }
    }
}

static double rmsOf(const std::vector<float> &a, const std::vector<float> &b) {
    double e = 0;
    const size_t n = std::min(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) e += (static_cast<double>(a[i]) - b[i]) * (static_cast<double>(a[i]) - b[i]);
    return std::sqrt(e / static_cast<double>(n));
}

static void testAveraging(double fs) {
    const Pass pass = makePass(fs);
    const uint32_t repeats = 4;
    const uint64_t frames = captureLength(pass, 0.2) + 16;
    std::vector<std::vector<float>> captures(repeats);
    std::vector<double> arrivals(repeats);
    std::vector<double> latencies(repeats);
    for (uint32_t r = 0; r < repeats; ++r) {
        latencies[r] = uniform(0.010, 0.200);
        captures[r] = capturePass(pass, latencies[r], 0, -30, 7 + r, frames);
        n60_measure_arrival arrival{};
        CHECK(n60_measure_find_arrival(pass.chirpOnly.data(), pass.chirpOnly.size(), captures[r].data(), frames, fs, 20.0,
                                       &arrival) == 0, "reference %u", r);
        arrivals[r] = arrival.arrival_frames;
    }
    // Noise-free capture on repeat 0's timeline is the truth the SNR is measured against.
    const std::vector<float> clean = capturePass(pass, latencies[0], 0, -200, 1, frames);

    n60_measure_average_params ap;
    n60_measure_average_defaults(fs, &ap);
    ap.repeat_count = repeats;
    ap.length_frames = frames;
    std::vector<const float *> pointers(repeats);
    for (uint32_t r = 0; r < repeats; ++r) pointers[r] = captures[r].data();
    std::vector<float> averaged(frames);
    n60_measure_average_result result{};
    CHECK(n60_measure_average_repeats(&ap, pointers.data(), arrivals.data(), averaged.data(), frames, &result) == 0,
          "average");
    CHECK(result.accepted_count == repeats && result.rejected_mask == 0, "all clean repeats accepted (mask %x)",
          result.rejected_mask);
    const double gainDb = 20.0 * std::log10(rmsOf(captures[0], clean) / rmsOf(averaged, clean));
    CHECK(std::fabs(gainDb - 6.02) <= 0.5, "fs=%g 4 repeats raise SNR by %.2f dB", fs, gainDb);
    std::printf("fs=%-7g 4-repeat SNR gain %.2f dB\n", fs, gainDb);

    // An injected outlier is rejected: repeat 2 is replaced by a quarter-level copy of itself.
    for (float &v : captures[2]) v *= 0.25f;
    CHECK(n60_measure_average_repeats(&ap, pointers.data(), arrivals.data(), averaged.data(), frames, &result) == 0,
          "average with outlier");
    CHECK(result.rejected_mask == (1u << 2), "level outlier rejected (mask %x)", result.rejected_mask);
    // A decorrelated repeat (the capture time-reversed) is rejected on coherence.
    for (size_t i = 0; i < captures[2].size(); ++i) captures[2][i] = captures[3][captures[3].size() - 1 - i];
    CHECK(n60_measure_average_repeats(&ap, pointers.data(), arrivals.data(), averaged.data(), frames, &result) == 0,
          "average with decorrelated repeat");
    CHECK((result.rejected_mask & (1u << 2)) != 0 && result.accepted_count == 3, "decorrelated repeat rejected (mask %x)",
          result.rejected_mask);
}

static void testDriftAndFailure(double fs) {
    const Pass pass = makePass(fs);
    const uint64_t frames = captureLength(pass, 0.2) + 16;
    const double ppm = 35.0;
    const uint32_t repeats = 4;
    std::vector<std::vector<float>> captures(repeats);
    std::vector<double> arrivals(repeats);
    for (uint32_t r = 0; r < repeats; ++r) {
        // The capture clock walks against playback by `ppm` across repeats.
        const double latency = 0.05 + static_cast<double>(r) * static_cast<double>(frames) * ppm * 1e-6 / fs;
        captures[r] = capturePass(pass, latency, 0, -50, 21 + r, frames);
        n60_measure_arrival arrival{};
        CHECK(n60_measure_find_arrival(pass.chirpOnly.data(), pass.chirpOnly.size(), captures[r].data(), frames, fs, 20.0,
                                       &arrival) == 0, "reference %u", r);
        arrivals[r] = arrival.arrival_frames;
    }
    n60_measure_average_params ap;
    n60_measure_average_defaults(fs, &ap);
    ap.repeat_count = repeats;
    ap.length_frames = frames;
    ap.repeat_period_frames = frames;
    std::vector<const float *> pointers(repeats);
    for (uint32_t r = 0; r < repeats; ++r) pointers[r] = captures[r].data();
    std::vector<float> averaged(frames);
    n60_measure_average_result result{};
    CHECK(n60_measure_average_repeats(&ap, pointers.data(), arrivals.data(), averaged.data(), frames, &result) == 0, "average");
    CHECK(std::fabs(result.drift_ppm - ppm) <= 2.0, "fs=%g drift reported %.2f ppm, expected %.0f", fs, result.drift_ppm, ppm);
    CHECK(result.drift_warning == 1, "drift above 20 ppm warns");

    // A capture without the reference fails loudly rather than falling back.
    std::vector<float> silent(frames, 0.0f);
    n60_measure_arrival arrival{};
    CHECK(n60_measure_find_arrival(pass.chirpOnly.data(), pass.chirpOnly.size(), silent.data(), frames, fs, 20.0, &arrival) ==
              N60_MEASURE_ERR_TIMING_REFERENCE, "silent capture fails the reference");
    uint64_t s = 99;
    std::vector<float> noise(frames);
    for (float &v : noise) {
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        v = static_cast<float>(static_cast<double>(s >> 40) / 16777216.0 - 0.5);
    }
    CHECK(n60_measure_find_arrival(pass.chirpOnly.data(), pass.chirpOnly.size(), noise.data(), frames, fs, 20.0, &arrival) ==
              N60_MEASURE_ERR_TIMING_REFERENCE, "noise-only capture fails the reference (%.1f dB)", arrival.peak_to_neighbourhood_db);
}

static void testBasics() {
    n60_measure_chirp_params cp;
    n60_measure_chirp_defaults(44100, &cp);
    uint64_t n = 0;
    CHECK(n60_measure_chirp_length(&cp, &n) == 0 && n == 11025, "chirp length %llu", (unsigned long long)n);
    cp.end_hz = 30000;
    CHECK(n60_measure_chirp_length(&cp, &n) == N60_MEASURE_ERR_ARGUMENT, "end above Nyquist rejected");
    n60_measure_average_params ap;
    n60_measure_average_defaults(48000, &ap);
    CHECK(ap.repeat_count == 2 && ap.min_coherence == 0.9 && ap.max_level_diff_db == 1.0 && ap.drift_warning_ppm == 20.0,
          "defaults");
    // One repeat passes through unchanged.
    std::vector<float> x(1000);
    for (size_t i = 0; i < x.size(); ++i) x[i] = std::sin(0.01f * static_cast<float>(i));
    const float *p = x.data();
    double arrival = 3.5;
    std::vector<float> y(x.size());
    n60_measure_average_result result{};
    ap.repeat_count = 1;
    ap.length_frames = x.size();
    CHECK(n60_measure_average_repeats(&ap, &p, &arrival, y.data(), y.size(), &result) == 0 && rmsOf(x, y) < 1e-6, "single repeat");
}

int main() {
    testBasics();
    for (double fs : kRates) {
        testTiming(fs, 0.0);
        testTiming(fs, 50.0);
        testTiming(fs, -50.0);
        testAveraging(fs);
        testDriftAndFailure(fs);
    }
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("measure timing OK");
    return 0;
}
