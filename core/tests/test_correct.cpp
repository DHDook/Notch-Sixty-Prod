// E10 S1: room-correction design core through its C ABI at the eight standard rates: minimum-phase
// synthesis, multi-seat FDW design, excess-phase extraction, declared latency and the pre-ringing audit.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "measure/offline_fft.hpp"
#include "n60/correct.h"
#include "n60/measure.h"

using n60::fft::offline::Cplx;
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static bool verbose = false;

namespace {

struct Room {
    double fs = 0;
    n60_measure_multiroom_params params{};
    std::vector<std::vector<float>> irs;  // channel-major: channel * seats + seat
    std::vector<n60_correct_seat_ir> seats;
    n60_correct_problem problem{};
    uint32_t channels = 0;
};

// Two allpass sections give the known excess phase; modes and reflections shape the magnitude.
static void buildRoom(Room &room, double fs, uint32_t seatCount, uint32_t channels = 1) {
    room.fs = fs;
    n60_measure_multiroom_defaults(fs, &room.params);
    room.params.base.ir_seconds = 0.6;
    room.params.source_count = channels;
    room.params.seat_count = seatCount;
    for (uint32_t s = 0; s < channels; ++s) room.params.source_delay_seconds[s] = 0.0004 * s;
    for (uint32_t k = 0; k < seatCount; ++k) room.params.seat_delay_seconds[k] = 0.00035 * k;
    room.params.modal_variation = 0.25;
    room.params.allpass_count = 2;
    room.params.allpass_f0_hz[0] = 60.0;
    room.params.allpass_q[0] = 1.5;
    room.params.allpass_f0_hz[1] = 120.0;
    room.params.allpass_q[1] = 2.0;
    room.channels = channels;
    room.irs.clear();
    room.seats.clear();
    uint64_t frames = 0;
    n60_measure_multiroom_ir_length(&room.params, &frames);
    room.irs.resize(static_cast<size_t>(channels) * seatCount);
    for (uint32_t c = 0; c < channels; ++c) {
        for (uint32_t k = 0; k < seatCount; ++k) {
            std::vector<float> &ir = room.irs[static_cast<size_t>(c) * seatCount + k];
            ir.assign(frames, 0.0f);
            uint64_t count = 0;
            CHECK(n60_measure_multiroom_ir(&room.params, c, k, ir.data(), frames, &count) == 0, "room ir");
        }
    }
    for (uint32_t c = 0; c < channels; ++c) {
        for (uint32_t k = 0; k < seatCount; ++k) {
            n60_correct_seat_ir s{};
            s.ir = room.irs[static_cast<size_t>(c) * seatCount + k].data();
            s.frames = frames;
            s.arrival_frames = n60_measure_multiroom_arrival_frames(&room.params, c, k);
            s.weight = 1.0;
            room.seats.push_back(s);
        }
    }
    room.problem.struct_size = sizeof(n60_correct_problem);
    room.problem.sample_rate = fs;
    room.problem.channel_count = channels;
    room.problem.seat_count = seatCount;
    room.problem.main_seat = 0;
    room.problem.irs = room.seats.data();
}

struct GridBuffers {
    std::vector<double> db, phase, coherence, measured, spread, boost;
    n60_correct_design_grid grid{};
    GridBuffers() : db(N60_CORRECT_GRID_POINTS), phase(N60_CORRECT_GRID_POINTS), coherence(N60_CORRECT_GRID_POINTS),
                    measured(N60_CORRECT_GRID_POINTS), spread(N60_CORRECT_GRID_POINTS), boost(N60_CORRECT_GRID_POINTS) {
        grid.correction_db = db.data();
        grid.correction_phase_rad = phase.data();
        grid.coherence = coherence.data();
        grid.measured_db = measured.data();
        grid.seat_spread_db = spread.data();
        grid.boost_limit_db = boost.data();
    }
};

static std::vector<double> gridFrequencies() {
    std::vector<double> f(N60_CORRECT_GRID_POINTS);
    CHECK(n60_correct_grid_frequencies(f.data(), N60_CORRECT_GRID_POINTS) == 0, "grid frequencies");
    return f;
}

// Magnitude (dB) of the taps at a frequency by direct DFT.
static double tapsDb(const std::vector<float> &taps, double hz, double fs) {
    double re = 0, im = 0;
    const double w = 2.0 * kPi * hz / fs;
    for (size_t n = 0; n < taps.size(); ++n) {
        re += taps[n] * std::cos(w * static_cast<double>(n));
        im -= taps[n] * std::sin(w * static_cast<double>(n));
    }
    return 20.0 * std::log10(std::max(1e-12, std::hypot(re, im)));
}

// Group delay (seconds) of a phase curve on the log grid, by central difference in angular frequency.
static std::vector<double> groupDelay(const std::vector<double> &f, const std::vector<double> &phase) {
    std::vector<double> gd(f.size(), 0.0);
    for (size_t i = 1; i + 1 < f.size(); ++i) {
        double d = phase[i + 1] - phase[i - 1];  // the phase is smooth: remove any 2 pi wrap
        d -= 2.0 * kPi * std::round(d / (2.0 * kPi));
        gd[i] = -d / (2.0 * kPi * (f[i + 1] - f[i - 1]));
    }
    return gd;
}

static void testBasics() {
    CHECK(n60_correct_abi_version() == N60_CORRECT_ABI_VERSION, "abi version");
    CHECK(n60_correct_grid_size() == N60_CORRECT_GRID_POINTS, "grid size");
    const std::vector<double> f = gridFrequencies();
    CHECK(std::fabs(f.front() - 20.0) < 1e-9, "grid start %g", f.front());
    CHECK(f.back() > 19800.0 && f.back() < 20000.0, "grid end %g", f.back());
    CHECK(std::fabs(f[48] / f[0] - 2.0) < 1e-9, "48 points per octave");
    n60_correct_synth_params sp{};
    n60_correct_synth_defaults(N60_CORRECT_MODE_MIN_PHASE, 48000, 4096, 0.0, &sp);
    CHECK(sp.struct_size == sizeof(sp) && sp.tail_taper_fraction == 0.10, "synth defaults");
    float taps[16] = {};
    CHECK(n60_correct_synthesize(nullptr, nullptr, taps, 16, nullptr) == N60_CORRECT_ERR_ARGUMENT, "null args");
    GridBuffers g;
    CHECK(n60_correct_synthesize(&sp, &g.grid, taps, 16, nullptr) == N60_CORRECT_ERR_CAPACITY, "capacity");
}

// The minimum-phase synthesis follows its curve and is causal and compact at every rate.
static void testMinimumPhase(double fs) {
    n60_correct_minphase_params p{};
    const uint32_t tapCount = static_cast<uint32_t>(std::llround(8192.0 * fs / 48000.0));  // same time span
    n60_correct_minphase_defaults(fs, tapCount, &p);
    const double freqs[] = {20, 60, 100, 200, 1000, 4000, 12000, 20000};
    const double gains[] = {0, 4, 6, -3, -6, 2, 0, 0};
    std::vector<float> taps(tapCount);
    CHECK(n60_correct_minphase_synthesize(&p, freqs, gains, 8, taps.data(), taps.size()) == 0, "minphase synth %g", fs);
    // The curve is interpolated linearly in log frequency; compare at the nodes that are clear of
    // the band edges.
    for (int i = 2; i <= 5; ++i) {
        const double got = tapsDb(taps, freqs[i], fs);
        CHECK(std::fabs(got - gains[i]) < 0.15, "minphase %g Hz at %g: got %g want %g", freqs[i], fs, got, gains[i]);
    }
    double head = 0, total = 0;
    for (size_t n = 0; n < taps.size(); ++n) {
        const double e = static_cast<double>(taps[n]) * taps[n];
        total += e;
        if (n < taps.size() / 4) head += e;
    }
    CHECK(head > 0.99 * total, "minimum phase is compact at %g: %g", fs, head / total);
}

// One seat with a known excess phase: the design reduces the 30..300 Hz excess group delay.
static void testMixedPhase(double fs, uint32_t seats) {
    Room room;
    buildRoom(room, fs, seats);
    n60_correct_design_params dp{};
    n60_correct_design_defaults(N60_CORRECT_MODE_MIXED_PHASE, &dp);
    GridBuffers g;
    const int32_t status = n60_correct_design_channel(&room.problem, 0, &dp, &g.grid);
    CHECK(status == 0, "design %g: %d", fs, status);
    if (status != 0) return;
    const std::vector<double> f = gridFrequencies();

    std::vector<double> excess(N60_CORRECT_GRID_POINTS);
    CHECK(n60_correct_seat_excess_phase(&room.problem, 0, 0, &dp, excess.data(), N60_CORRECT_GRID_POINTS) == 0, "excess phase");
    std::vector<double> residual(N60_CORRECT_GRID_POINTS);
    for (size_t i = 0; i < residual.size(); ++i) residual[i] = excess[i] + g.phase[i];
    const std::vector<double> before = groupDelay(f, excess);
    const std::vector<double> after = groupDelay(f, residual);
    double sumBefore = 0, sumAfter = 0;
    int count = 0;
    for (size_t i = 0; i < f.size(); ++i) {
        if (f[i] < 30.0 || f[i] > 300.0) continue;
        sumBefore += before[i] * before[i];
        sumAfter += after[i] * after[i];
        ++count;
    }
    const double rmsBefore = std::sqrt(sumBefore / count), rmsAfter = std::sqrt(sumAfter / count);
    if (verbose) std::printf("  %g: excess gd rms %.3f ms -> %.3f ms\n", fs, rmsBefore * 1e3, rmsAfter * 1e3);
    CHECK(rmsBefore > 0.004, "test room has excess group delay at %g: %g", fs, rmsBefore);
    CHECK(rmsAfter < 0.30 * rmsBefore, "excess group delay falls >= 70%% at %g: %g -> %g ms", fs, rmsBefore * 1e3, rmsAfter * 1e3);

    // Magnitude: the correction on the grid brings the design response to the (flat) target. The
    // level reference is the 500 Hz to 2 kHz mean, which the design leaves at the measured level.
    double reference = 0;
    int referenceCount = 0;
    for (size_t i = 0; i < f.size(); ++i) {
        if (f[i] >= 500.0 && f[i] <= 2000.0) { reference += g.measured[i] + g.db[i]; ++referenceCount; }
    }
    reference /= referenceCount;
    int checked = 0;
    double worst = 0, worstHz = 0;
    for (size_t i = 0; i < f.size(); ++i) {
        if (f[i] < 30.0 || f[i] > 10000.0) continue;
        const bool clamped = g.db[i] >= g.boost[i] - 1e-9 || g.db[i] <= -dp.max_cut_db + 1e-9;
        if (clamped) continue;
        const double residualDb = g.measured[i] + g.db[i] - reference;
        if (std::fabs(residualDb) > worst) { worst = std::fabs(residualDb); worstHz = f[i]; }
        ++checked;
    }
    if (verbose) std::printf("  %g: worst magnitude error %.3f dB at %g Hz\n", fs, worst, worstHz);
    CHECK(worst < 0.5, "magnitude within 0.5 dB at %g: worst %g dB at %g Hz", fs, worst, worstHz);
    CHECK(checked > 100, "enough unclamped points: %d", checked);
}

static void testSynthesisAndAudit(double fs) {
    Room room;
    buildRoom(room, fs, 3);
    n60_correct_design_params dp{};
    n60_correct_design_defaults(N60_CORRECT_MODE_MIXED_PHASE, &dp);
    const double latency = 0.05;
    const uint32_t tapCount = static_cast<uint32_t>(fs * 0.25);
    n60_correct_synth_params sp{};
    n60_correct_synth_defaults(N60_CORRECT_MODE_MIXED_PHASE, fs, tapCount, latency, &sp);
    std::vector<float> taps(tapCount);
    n60_correct_channel_report report{};
    const int32_t status = n60_correct_design_channel_taps(&room.problem, 0, &dp, &sp, taps.data(), taps.size(), &report);
    CHECK(status == 0, "channel taps %g: %d (failed bands %u)", fs, status, report.prering.failed_count);
    CHECK(report.synth.declared_latency_frames == static_cast<uint32_t>(std::llround(latency * fs)),
          "declared latency %u", report.synth.declared_latency_frames);
    CHECK(report.prering.band_count > 15, "audit evaluated bands: %u", report.prering.band_count);
    if (verbose) {
        for (uint32_t b = 0; b < report.prering.band_count; ++b) {
            const n60_correct_prering_band &band = report.prering.bands[b];
            if (band.failed) std::printf("    band %.0f Hz level %.1f dB margin %.1f dB window %.1f ms\n", band.centre_hz, band.level_db, band.margin_db, band.window_seconds * 1e3);
        }
        std::printf("  %g: peak gain %.2f dB, audit bands %u failed %u\n", fs, report.synth.peak_gain_db, report.prering.band_count, report.prering.failed_count);
    }

    // Repeat runs are bit-identical.
    std::vector<float> again(tapCount);
    n60_correct_channel_report report2{};
    CHECK(n60_correct_design_channel_taps(&room.problem, 0, &dp, &sp, again.data(), again.size(), &report2) == 0, "repeat");
    CHECK(std::memcmp(taps.data(), again.data(), taps.size() * sizeof(float)) == 0, "bit-identical taps at %g", fs);

    // The main peak of the filter sits at L (the delayed excess-phase-corrected response).
    size_t peak = 0;
    for (size_t n = 1; n < taps.size(); ++n) if (std::fabs(taps[n]) > std::fabs(taps[peak])) peak = n;
    CHECK(peak >= static_cast<size_t>(report.synth.declared_latency_frames) / 2 && peak < tapCount / 2, "peak position %zu at %g", peak, fs);

    // A deliberately over-long design: the main response at L plus a strong copy 20 ms earlier is
    // pre-ringing in every band, and the audit must fail them.
    {
        std::vector<float> bad(tapCount, 0.0f);
        const size_t at = static_cast<size_t>(std::llround(0.05 * fs));
        bad[at] = 1.0f;
        bad[at - static_cast<size_t>(std::llround(0.02 * fs))] = 0.5f;
        n60_correct_prering_report audit{};
        CHECK(n60_correct_audit_prering(&room.seats[0], fs, bad.data(), tapCount, 20.0, 20000.0, &audit) == 0, "audit call");
        CHECK(audit.failed_count >= 15,
              "pre-echo fails the audit in most bands at %g: %u of %u", fs, audit.failed_count, audit.band_count);
        // Bands whose period is far longer than 20 ms (below 50 Hz) cannot see it as pre-ringing.
        std::vector<float> clean(tapCount, 0.0f);
        clean[at] = 1.0f;
        CHECK(n60_correct_audit_prering(&room.seats[0], fs, clean.data(), tapCount, 20.0, 20000.0, &audit) == 0, "audit call");
        CHECK(audit.failed_count == 0 && audit.band_count > 15, "a clean delayed impulse passes at %g: %u failed", fs, audit.failed_count);
    }

    // A budget far shorter than the excess-phase response needs. The taper
    // that fits it to the budget leaves pre-ringing, and the audit must say so.
    n60_correct_synth_params shortSp = sp;
    shortSp.latency_seconds = 0.004;
    n60_correct_channel_report bad{};
    std::vector<float> shortTaps(tapCount);
    const int32_t blocked = n60_correct_design_channel_taps(&room.problem, 0, &dp, &shortSp, shortTaps.data(), shortTaps.size(), &bad);
    if (verbose) std::printf("  %g: short budget status %d failed %u\n", fs, blocked, bad.prering.failed_count);
    CHECK(blocked == N60_CORRECT_ERR_PRERINGING, "audit fires on over-long design at %g: %d", fs, blocked);
    CHECK(bad.prering.failed_count > 0 && bad.prering.first_failed_band >= 0, "failed band reported");
    CHECK(bad.synth.declared_latency_frames == static_cast<uint32_t>(std::llround(0.004 * fs)), "declared latency (short)");
}

static void testReferenceRoom(double fs) {
    Room room;
    buildRoom(room, fs, 3, 2);
    // Allpass phase and group delay agree: group delay is minus the phase slope.
    const double f0 = 120.0, h = 0.01;
    const double numeric = -(n60_measure_multiroom_allpass_phase(&room.params, f0 + h) -
                             n60_measure_multiroom_allpass_phase(&room.params, f0 - h)) / (2.0 * kPi * 2.0 * h);
    const double analytic = n60_measure_multiroom_allpass_group_delay(&room.params, f0);
    CHECK(std::fabs(numeric - analytic) < 1e-4 * analytic + 1e-7, "allpass group delay %g vs %g", numeric, analytic);
    const std::vector<float> &a = room.irs[0], &b = room.irs[1];
    double diff = 0, energy = 0;
    for (size_t i = 0; i < a.size(); ++i) { diff += (a[i] - b[i]) * (a[i] - b[i]); energy += a[i] * a[i]; }
    CHECK(diff > 1e-4 * energy, "seats differ at %g", fs);
    // Seeded and repeatable; the channels (sources) differ in delay.
    std::vector<float> again(a.size());
    uint64_t count = 0;
    CHECK(n60_measure_multiroom_ir(&room.params, 0, 0, again.data(), again.size(), &count) == 0 &&
          std::memcmp(again.data(), a.data(), a.size() * sizeof(float)) == 0, "room is repeatable at %g", fs);
    CHECK(n60_measure_multiroom_arrival_frames(&room.params, 1, 0) > n60_measure_multiroom_arrival_frames(&room.params, 0, 0), "source delay");
    // Two channels design independently, deterministically.
    GridBuffers g0, g1;
    n60_correct_design_params dp;
    n60_correct_design_defaults(N60_CORRECT_MODE_MIXED_PHASE, &dp);
    CHECK(n60_correct_design_channel(&room.problem, 0, &dp, &g0.grid) == 0 && n60_correct_design_channel(&room.problem, 1, &dp, &g1.grid) == 0, "two channels");
    CHECK(n60_correct_design_channel(&room.problem, 2, &dp, &g1.grid) == N60_CORRECT_ERR_ARGUMENT, "channel out of range");
}

static void testMinimumPhaseMode(double fs) {
    Room room;
    buildRoom(room, fs, 2);
    n60_correct_design_params dp{};
    n60_correct_design_defaults(N60_CORRECT_MODE_MIN_PHASE, &dp);
    GridBuffers g;
    CHECK(n60_correct_design_channel(&room.problem, 0, &dp, &g.grid) == 0, "min-phase design");
    for (double v : g.phase) CHECK(v == 0.0, "no phase correction in minimum-phase mode");
    n60_correct_synth_params sp{};
    n60_correct_synth_defaults(N60_CORRECT_MODE_MIN_PHASE, fs, 8192, 0.0, &sp);
    std::vector<float> taps(8192);
    n60_correct_channel_report report{};
    CHECK(n60_correct_design_channel_taps(&room.problem, 0, &dp, &sp, taps.data(), taps.size(), &report) == 0, "min-phase taps");
    CHECK(report.synth.declared_latency_frames == 0, "minimum-phase latency is zero");
    CHECK(report.prering.band_count == 0, "audit skipped in minimum-phase mode");
}

}  // namespace

int main(int argc, char **argv) {
    verbose = argc > 1 && std::strcmp(argv[1], "-v") == 0;
    testBasics();
    for (double fs : kRates) {
        const auto t0 = std::chrono::steady_clock::now();
        testMinimumPhase(fs);
        testMinimumPhaseMode(fs);
        testMixedPhase(fs, 1);
        testMixedPhase(fs, 3);
        testReferenceRoom(fs);
        testSynthesisAndAudit(fs);
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (verbose) std::printf("rate %g done in %.2f s\n", fs, s);
    }
    if (failures == 0) std::printf("test_correct: OK\n");
    return failures == 0 ? 0 : 1;
}
