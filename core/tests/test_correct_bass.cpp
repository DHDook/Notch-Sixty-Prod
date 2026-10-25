// E10 S6: joint mains-and-subwoofer bass optimiser through its C ABI at the eight standard rates.
//
// Reference room: 2 mains and 2 subwoofers at 6 seats (the E10 S1 multi-source room, with
// source-by-seat modal gains added so every channel disagrees about the seats). The joint result is
// compared with a subs-only alignment (delay, gain and polarity of the subs by grid search, mains
// untouched: the degrees of freedom of the coherent multi-subwoofer planner) on the same data,
// evaluated independently from the synthesised taps.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "measure/offline_fft.hpp"
#include "n60/correct.h"
#include "n60/measure.h"

using Complex = std::complex<double>;
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static bool verbose = false;

namespace {

constexpr uint32_t kMains = 2, kSubs = 2, kChannels = kMains + kSubs, kSeats = 6;
constexpr uint32_t kGrid = N60_CORRECT_GRID_POINTS;

struct Lcg {
    uint64_t s;
    double next() {  // [-1, 1)
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<double>(s >> 11) / 4503599627370496.0 - 1.0;
    }
};

struct Room {
    double fs = 0;
    n60_measure_multiroom_params params{};
    std::vector<std::vector<float>> irs;  // channel-major
    std::vector<n60_correct_seat_ir> seats;
    n60_correct_problem problem{};
};

static void buildRoom(Room &room, double fs) {
    room.fs = fs;
    n60_measure_multiroom_defaults(fs, &room.params);
    room.params.base.ir_seconds = 0.6;
    room.params.source_count = kChannels;
    room.params.seat_count = kSeats;
    // Mains arrive first; the subs are 3 and 4.5 ms later (further away), so alignment matters.
    const double sourceDelay[kChannels] = {0.0, 0.0004, 0.0031, 0.0046};
    for (uint32_t c = 0; c < kChannels; ++c) room.params.source_delay_seconds[c] = sourceDelay[c];
    for (uint32_t k = 0; k < kSeats; ++k) room.params.seat_delay_seconds[k] = 0.00035 * k;
    room.params.modal_variation = 0.25;
    uint64_t frames = 0;
    n60_measure_multiroom_ir_length(&room.params, &frames);
    room.irs.assign(static_cast<size_t>(kChannels) * kSeats, std::vector<float>(frames, 0.0f));
    // Separable modal gains: every mode has one gain per seat and one per source (a source near a node
    // barely excites it), so each mode's seat pattern is shared by the sources and the joint design can
    // cancel it by weighting the sources, while the seats still disagree strongly.
    const double modes[] = {31.0, 44.0, 58.0, 73.0, 96.0, 112.0};
    constexpr int kModes = 6;
    double seatGain[kSeats][kModes], sourceGain[kChannels][kModes];
    Lcg rng{0x9E3779B97F4A7C15ull};
    for (uint32_t k = 0; k < kSeats; ++k) for (int q = 0; q < kModes; ++q) seatGain[k][q] = rng.next();
    for (uint32_t c = 0; c < kChannels; ++c) for (int q = 0; q < kModes; ++q) sourceGain[c][q] = 0.35 + 0.65 * std::fabs(rng.next()) * (rng.next() < 0 ? -1.0 : 1.0);
    for (uint32_t c = 0; c < kChannels; ++c) {
        for (uint32_t k = 0; k < kSeats; ++k) {
            std::vector<float> &ir = room.irs[static_cast<size_t>(c) * kSeats + k];
            uint64_t count = 0;
            CHECK(n60_measure_multiroom_ir(&room.params, c, k, ir.data(), frames, &count) == 0, "room ir");
            const double arrival = n60_measure_multiroom_arrival_frames(&room.params, c, k);
            for (int q = 0; q < kModes; ++q) {
                const double amp = 0.012 * (48000.0 / fs) * seatGain[k][q] * sourceGain[c][q];
                const double tau = 0.12 / std::log(1000.0);
                for (uint64_t i = static_cast<uint64_t>(arrival) + 1; i < frames; ++i) {
                    const double t = (static_cast<double>(i) - arrival) / fs;
                    if (t > 6.0 * tau) break;
                    ir[i] += static_cast<float>(amp * std::exp(-t / tau) * std::sin(2.0 * kPi * modes[q] * t));
                }
            }
        }
    }
    for (uint32_t c = 0; c < kChannels; ++c) {
        for (uint32_t k = 0; k < kSeats; ++k) {
            n60_correct_seat_ir s{};
            s.ir = room.irs[static_cast<size_t>(c) * kSeats + k].data();
            s.frames = frames;
            s.arrival_frames = n60_measure_multiroom_arrival_frames(&room.params, c, k);
            s.weight = 1.0;
            room.seats.push_back(s);
        }
    }
    room.problem.struct_size = sizeof(n60_correct_problem);
    room.problem.sample_rate = fs;
    room.problem.channel_count = kChannels;
    room.problem.seat_count = kSeats;
    room.problem.main_seat = 0;
    room.problem.irs = room.seats.data();
}

struct Grids {
    std::vector<double> db[kChannels], phase[kChannels];
    n60_correct_design_grid grid[kChannels];
    Grids() {
        for (uint32_t n = 0; n < kChannels; ++n) {
            db[n].assign(kGrid, 0.0);
            phase[n].assign(kGrid, 0.0);
            grid[n] = n60_correct_design_grid{};
            grid[n].correction_db = db[n].data();
            grid[n].correction_phase_rad = phase[n].data();
        }
    }
};

static std::vector<double> gridFrequencies() {
    std::vector<double> f(kGrid);
    CHECK(n60_correct_grid_frequencies(f.data(), kGrid) == 0, "grid frequencies");
    return f;
}

// Measured response of every (channel, seat) at the grid points in [lo, hi], by the same 4x padded FFT
// and interpolation the optimiser uses (the IR is the shared input, the maths below is the test's own).
struct Measured {
    std::vector<double> f;                  // grid frequencies in the band
    std::vector<uint32_t> index;            // their grid indices
    std::vector<Complex> h;                 // [g][channel][seat]
    Complex at(size_t g, uint32_t c, uint32_t k) const { return h[(g * kChannels + c) * kSeats + k]; }
};

static Measured measure(const Room &room, double lo, double hi) {
    Measured m;
    const std::vector<double> all = gridFrequencies();
    for (uint32_t g = 0; g < kGrid; ++g) {
        if (all[g] >= lo && all[g] <= hi) { m.f.push_back(all[g]); m.index.push_back(g); }
    }
    m.h.assign(m.f.size() * kChannels * kSeats, Complex(0, 0));
    for (uint32_t c = 0; c < kChannels; ++c) {
        for (uint32_t k = 0; k < kSeats; ++k) {
            const std::vector<float> &ir = room.irs[static_cast<size_t>(c) * kSeats + k];
            uint64_t n = 2;
            while (n < ir.size() * 4) n <<= 1;
            std::vector<double> x(n, 0.0);
            for (size_t i = 0; i < ir.size(); ++i) x[i] = ir[i];
            std::vector<n60::fft::offline::Cplx> spectrum;
            CHECK(n60::fft::offline::realForward(x.data(), n, spectrum), "fft");
            for (size_t g = 0; g < m.f.size(); ++g) {
                const double pos = m.f[g] * static_cast<double>(n) / room.fs;
                const size_t b = static_cast<size_t>(pos);
                const double fr = pos - static_cast<double>(b);
                m.h[(g * kChannels + c) * kSeats + k] =
                    Complex(spectrum[b].re + fr * (spectrum[b + 1].re - spectrum[b].re), spectrum[b].im + fr * (spectrum[b + 1].im - spectrum[b].im));
            }
        }
    }
    return m;
}

static Complex lr4(bool highPass, double hz, double fc) {
    const Complex s(0.0, hz / fc);
    const Complex d = s * s + std::sqrt(2.0) * s + 1.0;
    const Complex sec = (highPass ? s * s : Complex(1, 0)) / d;
    return sec * sec;
}

struct Chain {
    double delaySeconds[kChannels] = {};
    double gainDb[kChannels] = {};
    bool invert[kChannels] = {};
    const std::vector<Complex> *filter[kChannels] = {};  // optional, per measured grid point
};

// Mean over the band of the seat-to-seat standard deviation of the level in dB (the E10 S6 criterion).
static double seatStd(const Measured &m, const Chain &c) {
    double total = 0;
    for (size_t g = 0; g < m.f.size(); ++g) {
        double level[kSeats];
        for (uint32_t k = 0; k < kSeats; ++k) {
            Complex e(0, 0);
            for (uint32_t n = 0; n < kChannels; ++n) {
                const double ph = -2.0 * kPi * m.f[g] * c.delaySeconds[n];
                Complex term = lr4(n < kMains, m.f[g], 80.0) * ((c.invert[n] ? -1.0 : 1.0) * std::pow(10.0, c.gainDb[n] / 20.0)) * std::polar(1.0, ph) * m.at(g, n, k);
                if (c.filter[n] != nullptr) term *= (*c.filter[n])[g];
                e += term;
            }
            level[k] = 20.0 * std::log10(std::max(std::abs(e), 1e-12));
        }
        double mean = 0;
        for (double v : level) mean += v / kSeats;
        double var = 0;
        for (double v : level) var += (v - mean) * (v - mean) / kSeats;
        total += std::sqrt(var);
    }
    return total / static_cast<double>(m.f.size());
}

// Subs-only alignment: delay, gain and polarity of the subs on a grid, coordinate descent from two starts.
static double subsOnlyStd(const Measured &m, const Room &room) {
    double best = 1e9;
    for (int start = 0; start < 2; ++start) {
        Chain c;
        if (start == 1) {
            double latest = 0;
            double arrival[kChannels];
            for (uint32_t n = 0; n < kChannels; ++n) {
                arrival[n] = n60_measure_multiroom_arrival_frames(&room.params, n, 0) / room.fs;
                latest = std::max(latest, arrival[n]);
            }
            for (uint32_t n = kMains; n < kChannels; ++n) c.delaySeconds[n] = latest - arrival[n];
        }
        for (int sweep = 0; sweep < 3; ++sweep) {
            for (uint32_t n = kMains; n < kChannels; ++n) {
                double bestCost = seatStd(m, c);
                Chain bestChain = c;
                for (int inv = 0; inv < 2; ++inv) {
                    for (int i = 0; i <= 80; ++i) {
                        Chain t = c;
                        t.invert[n] = inv == 1;
                        t.delaySeconds[n] = 0.00025 * i;
                        const double v = seatStd(m, t);
                        if (v < bestCost) { bestCost = v; bestChain = t; }
                    }
                }
                c = bestChain;
                for (int g = -12; g <= 6; ++g) {
                    Chain t = c;
                    t.gainDb[n] = g;
                    const double v = seatStd(m, t);
                    if (v < bestCost) { bestCost = v; bestChain = t; }
                }
                c = bestChain;
            }
        }
        best = std::min(best, seatStd(m, c));
    }
    return best;
}

static void channelDefaults(n60_correct_bass_channel *ch) {
    for (uint32_t n = 0; n < kChannels; ++n) n60_correct_bass_channel_defaults(n < kMains ? N60_CORRECT_BASS_ROLE_MAIN : N60_CORRECT_BASS_ROLE_SUB, &ch[n]);
}

// Response of the synthesised taps at the band's grid points (direct DFT of the double-sum of the taps).
static std::vector<Complex> tapsResponse(const std::vector<float> &taps, const std::vector<double> &f, double fs) {
    std::vector<Complex> r(f.size());
    for (size_t g = 0; g < f.size(); ++g) {
        const double w = 2.0 * kPi * f[g] / fs;
        const Complex step(std::cos(w), -std::sin(w));
        Complex rotor(1, 0), acc(0, 0);
        for (size_t i = 0; i < taps.size(); ++i) {
            if ((i & 1023) == 0) rotor = Complex(std::cos(w * static_cast<double>(i)), -std::sin(w * static_cast<double>(i)));
            acc += static_cast<double>(taps[i]) * rotor;
            rotor *= step;
        }
        r[g] = acc;
    }
    return r;
}

struct Run {
    int32_t status = 0;
    n60_correct_bass_report report{};
    Grids grids;
    n60_correct_bass_channel channels[kChannels];
    n60_correct_bass_params params{};
    std::vector<double> before, after;
};

static void runOptimiser(const Room &room, Run &run) {
    channelDefaults(run.channels);
    n60_correct_bass_defaults(run.channels, &run.params);
    run.params.timing_tier = N60_CORRECT_TIMING_ACOUSTIC;
    run.before.assign(static_cast<size_t>(kSeats) * kGrid, 0.0);
    run.after.assign(static_cast<size_t>(kSeats) * kGrid, 0.0);
    run.status = n60_correct_bass_optimise(&room.problem, &run.params, run.grids.grid, &run.report, run.before.data(), run.after.data());
}

static void testRate(double fs) {
    Room room;
    buildRoom(room, fs);
    Run run;
    runOptimiser(room, run);
    CHECK(run.status == 0, "%g: optimise status %d", fs, run.status);
    if (run.status != 0) return;
    const n60_correct_bass_report &rep = run.report;
    CHECK(rep.channel_count == kChannels && rep.seat_count == kSeats, "%g: report counts", fs);

    // Channel results: ranges, frames, the earliest channel at zero, mains untouched except for delay.
    uint32_t minFrames = 0xFFFFFFFFu;
    for (uint32_t n = 0; n < kChannels; ++n) {
        const n60_correct_bass_channel_result &c = rep.channels[n];
        minFrames = std::min(minFrames, c.delay_frames);
        CHECK(c.delay_seconds >= 0.0 && c.delay_seconds <= run.params.max_delay_seconds + 1.0 / fs, "%g: delay range ch%u %g", fs, n, c.delay_seconds);
        CHECK(std::fabs(c.delay_seconds - static_cast<double>(c.delay_frames) / fs) < 1e-12, "%g: delay frames ch%u", fs, n);
        if (n < kMains) {
            CHECK(c.gain_db == 0.0 && c.polarity_invert == 0, "%g: main ch%u gain/polarity fixed", fs, n);
        } else {
            CHECK(c.gain_db >= -12.0 - 1e-9 && c.gain_db <= 6.0 + 1e-9, "%g: sub gain range ch%u %g", fs, n, c.gain_db);
        }
        // Boost cap and headroom.
        double peak = -1e9, peakGain = -1e9;
        for (uint32_t g = 0; g < kGrid; ++g) {
            peak = std::max(peak, run.grids.db[n][g]);
            peakGain = std::max(peakGain, run.grids.db[n][g] + c.gain_db);
            CHECK(run.grids.db[n][g] <= 6.0 + 1e-9, "%g: boost cap ch%u grid %u: %g dB", fs, n, g, run.grids.db[n][g]);
            CHECK(std::isfinite(run.grids.phase[n][g]), "%g: phase finite", fs);
        }
        CHECK(std::fabs(peak - c.peak_boost_db) < 1e-9 && peak <= 6.0 + 1e-9, "%g: peak boost ch%u %g vs %g", fs, n, peak, c.peak_boost_db);
        CHECK(std::fabs(c.headroom_db - std::max(0.0, peakGain)) < 1e-9, "%g: headroom ch%u", fs, n);
        CHECK(c.headroom_db <= rep.headroom_db + 1e-12, "%g: headroom max", fs);
    }
    CHECK(minFrames == 0, "%g: earliest channel at zero delay (%u)", fs, minFrames);

    // Independent evaluation from the synthesised taps (music mode, 100 ms budget).
    const Measured m = measure(room, 20.0, 120.0);
    Chain before, after;
    std::vector<std::vector<Complex>> filters(kChannels);
    const uint32_t tapCount = n60_correct_latency_mode_tap_count(N60_CORRECT_LATENCY_MUSIC_100MS, fs);
    for (uint32_t n = 0; n < kChannels; ++n) {
        std::vector<float> taps(tapCount);
        n60_correct_synth_params sp;
        n60_correct_synth_defaults(N60_CORRECT_MODE_MIXED_PHASE, fs, tapCount, 0.1, &sp);
        n60_correct_synth_report sr{};
        CHECK(n60_correct_synthesize(&sp, &run.grids.grid[n], taps.data(), taps.size(), &sr) == 0, "%g: synth ch%u", fs, n);
        std::vector<Complex> r = tapsResponse(taps, m.f, fs);
        const double latency = static_cast<double>(sr.declared_latency_frames) / fs;
        for (size_t g = 0; g < r.size(); ++g) r[g] *= std::polar(1.0, 2.0 * kPi * m.f[g] * latency);  // remove the common latency
        filters[n] = r;
        after.filter[n] = &filters[n];
        after.delaySeconds[n] = rep.channels[n].delay_seconds;
        after.gainDb[n] = rep.channels[n].gain_db;
        after.invert[n] = rep.channels[n].polarity_invert != 0;
    }
    const double stdBefore = seatStd(m, before);
    const double stdAfter = seatStd(m, after);
    const double stdSubs = subsOnlyStd(m, room);
    if (verbose) {
        std::printf("rate %g: rms before %.2f (core %.2f) subs-only %.2f joint %.2f (core %.2f) dB, seat std %.2f->%.2f->%.2f, headroom %.2f dB, limited bins %u\n",
                    fs, stdBefore, rep.target_rms_before_db, stdSubs, stdAfter, rep.target_rms_after_db, rep.seat_std_before_db, rep.seat_std_aligned_db, rep.seat_std_after_db, rep.headroom_db, rep.boost_limited_bins);
        for (uint32_t n = 0; n < kChannels; ++n) {
            std::printf("  ch%u delay %.2f ms gain %.1f dB inv %u boost %.2f\n", n, rep.channels[n].delay_seconds * 1e3, rep.channels[n].gain_db,
                        rep.channels[n].polarity_invert, rep.channels[n].peak_boost_db);
        }
    }
    CHECK(std::fabs(stdBefore - rep.seat_std_before_db) < 0.05, "%g: before std %g vs core %g", fs, stdBefore, rep.seat_std_before_db);
    CHECK(std::fabs(stdAfter - rep.seat_std_after_db) < 0.75, "%g: after std from taps %g vs core %g", fs, stdAfter, rep.seat_std_after_db);
    // "3 dB lower" is the ratio of the standard deviations: 20 log10(subs-only / joint) >= 3.
    CHECK(20.0 * std::log10(stdSubs / stdAfter) >= 3.0, "%g: joint std %g dB not 3 dB (ratio) under subs-only %g dB", fs, stdAfter, stdSubs);
    CHECK(20.0 * std::log10(rep.seat_std_before_db / rep.seat_std_after_db) >= 3.0, "%g: seat std reduced by 3 dB (ratio) (%g to %g)", fs, rep.seat_std_before_db, rep.seat_std_after_db);

    // The predicted seat responses in the report agree with the independent evaluation (before exactly).
    for (size_t g = 0; g < m.f.size(); ++g) {
        for (uint32_t k = 0; k < kSeats; ++k) {
            Complex e(0, 0);
            for (uint32_t n = 0; n < kChannels; ++n) e += lr4(n < kMains, m.f[g], 80.0) * m.at(g, n, k);
            const double db = 20.0 * std::log10(std::abs(e));
            CHECK(std::fabs(db - run.before[static_cast<size_t>(k) * kGrid + m.index[g]]) < 0.02, "%g: predicted before seat %u f %.1f: %g vs %g", fs, k, m.f[g], db,
                  run.before[static_cast<size_t>(k) * kGrid + m.index[g]]);
        }
    }
}

static void testDeterminism(double fs) {
    Room room;
    buildRoom(room, fs);
    Run a, b;
    runOptimiser(room, a);
    runOptimiser(room, b);
    CHECK(a.status == 0 && b.status == 0, "determinism status");
    CHECK(std::memcmp(&a.report, &b.report, sizeof a.report) == 0, "%g: report bit-identical", fs);
    for (uint32_t n = 0; n < kChannels; ++n) {
        CHECK(std::memcmp(a.grids.db[n].data(), b.grids.db[n].data(), kGrid * sizeof(double)) == 0, "%g: db bit-identical ch%u", fs, n);
        CHECK(std::memcmp(a.grids.phase[n].data(), b.grids.phase[n].data(), kGrid * sizeof(double)) == 0, "%g: phase bit-identical ch%u", fs, n);
    }
    CHECK(std::memcmp(a.after.data(), b.after.data(), a.after.size() * sizeof(double)) == 0, "%g: predictions bit-identical", fs);
}

static void testBlocking(double fs) {
    Room room;
    buildRoom(room, fs);
    Run run;
    runOptimiser(room, run);
    n60_correct_bass_params p = run.params;
    // Missing timing tier blocks the design.
    p.timing_tier = N60_CORRECT_TIMING_NONE;
    CHECK(n60_correct_bass_optimise(&room.problem, &p, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_TIMING, "tier none blocks");
    n60_correct_bass_params d;
    n60_correct_bass_defaults(run.channels, &d);
    CHECK(d.timing_tier == N60_CORRECT_TIMING_NONE, "defaults are blocked until the caller sets the tier");
    CHECK(n60_correct_bass_optimise(&room.problem, &d, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_TIMING, "defaults block");
    p.timing_tier = 99;
    CHECK(n60_correct_bass_optimise(&room.problem, &p, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "bad tier");
    p.timing_tier = N60_CORRECT_TIMING_LOOPBACK;
    CHECK(n60_correct_bass_optimise(&room.problem, &p, run.grids.grid, &run.report, nullptr, nullptr) == 0, "loopback tier allowed");
    // Argument checks.
    CHECK(n60_correct_bass_optimise(nullptr, &p, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "null problem");
    CHECK(n60_correct_bass_optimise(&room.problem, &p, nullptr, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "null grids");
    n60_correct_bass_params bad = p;
    bad.crossover_hz = 5.0;
    CHECK(n60_correct_bass_optimise(&room.problem, &bad, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "bad crossover");
    bad = p;
    bad.max_boost_db = -1.0;
    CHECK(n60_correct_bass_optimise(&room.problem, &bad, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "bad boost");
    n60_correct_bass_channel badChannels[kChannels];
    channelDefaults(badChannels);
    badChannels[2].min_gain_db = 10.0;
    bad = p;
    bad.channels = badChannels;
    CHECK(n60_correct_bass_optimise(&room.problem, &bad, run.grids.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "bad gain range");
    Grids missing;
    missing.grid[1].correction_phase_rad = nullptr;
    CHECK(n60_correct_bass_optimise(&room.problem, &p, missing.grid, &run.report, nullptr, nullptr) == N60_CORRECT_ERR_ARGUMENT, "missing phase array");
}

// A tighter boost cap is respected (and the cap is reported as active) and a tilted target changes the filters.
static void testCapAndTarget(double fs) {
    Room room;
    buildRoom(room, fs);
    Run run;
    runOptimiser(room, run);
    n60_correct_bass_params p = run.params;
    p.timing_tier = N60_CORRECT_TIMING_ACOUSTIC;
    p.max_boost_db = 2.0;
    Grids tight;
    n60_correct_bass_report tightReport{};
    CHECK(n60_correct_bass_optimise(&room.problem, &p, tight.grid, &tightReport, nullptr, nullptr) == 0, "tight cap");
    for (uint32_t n = 0; n < kChannels; ++n) {
        for (uint32_t g = 0; g < kGrid; ++g) CHECK(tight.db[n][g] <= 2.0 + 1e-9, "%g: 2 dB cap ch%u grid %u %g", fs, n, g, tight.db[n][g]);
        CHECK(tightReport.channels[n].peak_boost_db <= 2.0 + 1e-9, "%g: reported peak under the 2 dB cap", fs);
    }
    CHECK(tightReport.boost_limited_bins >= run.report.boost_limited_bins, "%g: tighter cap limits at least as many bins", fs);

    // A -6 dB shelf target below 40 Hz lowers the filters there against flat.
    const double tf[] = {20.0, 40.0, 41.0, 300.0};
    const double tg[] = {-6.0, -6.0, 0.0, 0.0};
    p.max_boost_db = 6.0;
    p.target_frequencies_hz = tf;
    p.target_gain_db = tg;
    p.target_points = 4;
    Grids shaped;
    n60_correct_bass_report shapedReport{};
    CHECK(n60_correct_bass_optimise(&room.problem, &p, shaped.grid, &shapedReport, nullptr, nullptr) == 0, "shaped target");
    const std::vector<double> f = gridFrequencies();
    double flatMean = 0, shapedMean = 0;
    int count = 0;
    for (uint32_t g = 0; g < kGrid; ++g) {
        if (f[g] < 22.0 || f[g] > 36.0) continue;
        for (uint32_t n = 0; n < kChannels; ++n) { flatMean += run.grids.db[n][g]; shapedMean += shaped.db[n][g]; }
        count++;
    }
    CHECK(shapedMean / count < flatMean / count - 1.0, "%g: shelf target lowers the low-frequency filters (%g vs %g dB)", fs, shapedMean / count, flatMean / count);
    CHECK(std::fabs(shapedReport.reference_level_db - run.report.reference_level_db) < 6.5, "%g: reference level moves with the target by less than the shelf", fs);
}

}  // namespace

int main(int argc, char **argv) {
    verbose = argc > 1 && std::strcmp(argv[1], "-v") == 0;
    for (double fs : kRates) {
        const auto t0 = std::chrono::steady_clock::now();
        testRate(fs);
        if (fs == 48000.0 || fs == 384000.0) {
            testDeterminism(fs);
            testBlocking(fs);
            testCapAndTarget(fs);
        }
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (verbose) std::printf("rate %g done in %.2f s\n", fs, s);
    }
    if (failures == 0) std::printf("test_correct_bass: OK\n");
    return failures == 0 ? 0 : 1;
}
