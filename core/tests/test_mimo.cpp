// E19 S2: MIMO room treatment design core (n60/mimo.h) at the eight standard rates.
// Reference room: 2 mains + 2 subs, 3 seats, modes at 40 and 70 Hz with 0.8 s RT60.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <utility>
#include <vector>

#include "n60/measure.h"
#include "n60/mimo.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr double kLn1000 = 6.907755278982137;
constexpr uint32_t kSources = 4, kSeats = 3;

struct Room {
    double fs = 0;
    std::vector<float> ir[kSources][kSeats];   // device rate
};

static double gModePeak = 3.0;

static Room buildRoom(double fs) {
    n60_measure_multiroom_params p;
    n60_measure_multiroom_defaults(fs, &p);
    p.source_count = kSources;
    p.seat_count = kSeats;
    p.base.ir_seconds = 1.6;
    p.base.diffuse_level_db = -200.0;
    p.reflection_count = 0;
    p.modal_variation = 0.3;
    const double hz[2] = {40.0, 70.0};
    for (int m = 0; m < 4; ++m) p.base.mode_frequencies_hz[m] = 0.0;
    for (int m = 0; m < 2; ++m) {
        const double alpha = kLn1000 / (0.8 * fs);
        p.base.mode_frequencies_hz[m] = hz[m];
        p.base.mode_decay_seconds[m] = 0.8;
        p.base.mode_level_db[m] = 20.0 * std::log10(gModePeak * 2.0 * alpha / p.base.direct_gain);
    }
    // Mains drive the modes weakly; the subs drive them strongly and with different phases.
    const double gain[kSources] = {0.4, 0.4, 1.0, 0.9};
    const double phase[kSources] = {0.0, 0.5, 0.2, 2.0};
    const double delay[kSources] = {0.0, 0.0002, 0.0011, 0.0023};
    for (uint32_t s = 0; s < kSources; ++s) {
        p.source_delay_seconds[s] = delay[s];
        for (int m = 0; m < 4; ++m) { p.source_mode_gain[s][m] = gain[s]; p.source_mode_phase_rad[s][m] = phase[s] * (m + 1); }
    }
    for (uint32_t m = 0; m < kSeats; ++m) p.seat_delay_seconds[m] = 0.0004 * m;
    Room room;
    room.fs = fs;
    uint64_t len = 0;
    CHECK(n60_measure_multiroom_ir_length(&p, &len) == 0, "ir length");
    for (uint32_t s = 0; s < kSources; ++s)
        for (uint32_t m = 0; m < kSeats; ++m) {
            room.ir[s][m].resize(len);
            uint64_t n = 0;
            CHECK(n60_measure_multiroom_ir(&p, s, m, room.ir[s][m].data(), len, &n) == 0 && n == len, "ir");
        }
    return room;
}

// Building the reference room at 384 kHz takes a second, so each (rate, mode level) is built once.
static Room makeRoom(double fs) {
    static std::map<std::pair<double, double>, Room> cache;
    const auto key = std::make_pair(fs, gModePeak);
    auto it = cache.find(key);
    if (it == cache.end()) it = cache.emplace(key, buildRoom(fs)).first;
    return it->second;
}

static void fillProblem(const Room &room, n60_mimo_problem &prob) {
    n60_mimo_defaults(room.fs, kSources, kSeats, &prob);
    for (uint32_t s = 0; s < kSources; ++s) {
        prob.sources[s].support_low_hz = s < 2 ? 30.0 : 20.0;
        prob.sources[s].support_high_hz = s < 2 ? 150.0 : 120.0;
        for (uint32_t m = 0; m < kSeats; ++m) {
            prob.program_plant[s][m] = room.ir[s][m].data();
            prob.program_count[s][m] = room.ir[s][m].size();
        }
    }
}

struct Design {
    int32_t status = 0;
    n60_mimo_info info{};
    std::vector<float> taps;
};

static Design design(const n60_mimo_problem &prob) {
    Design d;
    d.taps.assign(static_cast<size_t>(prob.source_count) * prob.source_count * prob.taps, 0.0f);
    d.status = n60_mimo_design(&prob, d.taps.data(), d.taps.size(), &d.info);
    return d;
}

static std::vector<float> lowPlant(const Room &room, uint32_t s, uint32_t m) {
    std::vector<float> out(room.ir[s][m].size() / 16 + 2);
    uint64_t n = 0;
    CHECK(n60_mimo_decimate(room.fs, room.ir[s][m].data(), room.ir[s][m].size(), out.data(), out.size(), &n) == 0, "decimate");
    out.resize(n);
    return out;
}

// Predicted response of feed `t` at seat `m` (low rate): sum over s of Q_sm * (E_st + delta_st z^-tauSamples).
static std::vector<float> treated(const Room &room, const Design &d, uint32_t t, uint32_t m, bool apply, int tauSamples = 0) {
    std::vector<std::vector<float>> plants, filters;
    const uint32_t taps = d.info.taps;
    for (uint32_t s = 0; s < kSources; ++s) {
        plants.push_back(lowPlant(room, s, m));
        std::vector<float> f(taps + tauSamples, 0.0f);
        if (apply) for (uint32_t i = 0; i < taps; ++i) f[i] = d.taps[(static_cast<size_t>(s) * kSources + t) * taps + i];
        if (s == t) f[tauSamples] += 1.0f;
        if (!apply && s != t) f.assign(1, 0.0f);
        if (!apply && s == t) f.assign(1, 1.0f);
        filters.push_back(f);
    }
    std::vector<const float *> pp, fp;
    std::vector<uint64_t> pc, fc;
    for (uint32_t s = 0; s < kSources; ++s) { pp.push_back(plants[s].data()); pc.push_back(plants[s].size()); fp.push_back(filters[s].data()); fc.push_back(filters[s].size()); }
    uint64_t len = 0;
    CHECK(n60_measure_predict_treated_length(kSources, pc.data(), fc.data(), &len) == 0, "len");
    std::vector<float> out(len);
    uint64_t n = 0;
    CHECK(n60_measure_predict_treated_ir(kSources, pp.data(), pc.data(), fp.data(), fc.data(), out.data(), len, &n) == 0, "predict");
    return out;
}

// T30 of the 40 Hz third octave. The predicted IR is at the low rate (the decay analyser needs 8 kHz or more),
// so it goes back to the device rate through the core's interpolator first.
static double t30At40(const std::vector<float> &lowIr, double fs) {
    std::vector<float> ir(lowIr.size() * 128);
    uint64_t made = 0;
    CHECK(n60_mimo_interpolate(fs, lowIr.data(), lowIr.size(), ir.data(), ir.size(), &made) == 0, "interpolate");
    ir.resize(made);
    n60_measure_decay_band bands[32];
    uint32_t count = 0;
    CHECK(n60_measure_decay_analyze(ir.data(), ir.size(), fs, N60_MEASURE_DECAY_THIRD_OCTAVE, 25.0, 160.0, bands, 32, &count) == 0, "decay");
    for (uint32_t b = 0; b < count; ++b) if (std::fabs(bands[b].centre_hz / 39.811 - 1.0) < 0.02) return bands[b].t30_seconds;
    return 0.0;
}

static double bandEnergyDb(const std::vector<float> &ir, double fsLow) {
    double e = 0;
    for (double f = 20.0; f <= 150.0; f += 0.5) {
        double re, im;
        n60_mimo_tap_response(ir.data(), static_cast<uint32_t>(ir.size()), fsLow, f, &re, &im);
        e += re * re + im * im;
    }
    return 10.0 * std::log10(e);
}

static uint64_t argmax(const std::vector<float> &x) {
    uint64_t b = 0;
    for (uint64_t i = 0; i < x.size(); ++i) if (std::fabs(x[i]) > std::fabs(x[b])) b = i;
    return b;
}

static double rowEffortDb(const Design &d, uint32_t s, double hz, double fsLow) {
    double sum = 0;
    for (uint32_t t = 0; t < kSources; ++t) {
        double re, im;
        n60_mimo_tap_response(&d.taps[(static_cast<size_t>(s) * kSources + t) * d.info.taps], d.info.taps, fsLow, hz, &re, &im);
        sum += re * re + im * im;
    }
    return 10.0 * std::log10(std::max(sum, 1e-40));
}

static void testDecayAndLevel() {
    for (double fs : kRates) {
        const Room room = makeRoom(fs);
        n60_mimo_problem prob;
        fillProblem(room, prob);
        const Design d = design(prob);
        CHECK(d.status == 0, "fs %.0f design status %d (source %d) pre %.1f dB", fs, d.status, d.info.bad_source, d.info.pre_energy_db);
        if (d.status != 0) continue;
        const double fsLow = d.info.low_rate_hz;
        // The 40 Hz third-octave analyser filter itself rings for about 0.5 s, so T30 cannot read below that: the
        // floor is the untreated T30 of the same room with the modes switched off, and the fall is judged on the
        // modal excess above it (E19 Log, S2: the plan's 40 percent re 0.8 s RT60 sits at the floor).
        gModePeak = 0.001;
        const Room flat = makeRoom(fs);
        gModePeak = 1.0;
        for (uint32_t t : {0u, 2u}) {
            for (uint32_t m = 0; m < kSeats; ++m) {
                const std::vector<float> before = treated(room, d, t, m, false);
                const std::vector<float> after = treated(room, d, t, m, true);
                const double floorT = t30At40(treated(flat, d, t, m, false), fs);
                const double t0 = t30At40(before, fs), t1 = t30At40(after, fs);
                CHECK(t0 > floorT + 0.1 && t1 > 0, "fs %.0f feed %u seat %u T30 before %.3f after %.3f floor %.3f", fs, t, m, t0, t1, floorT);
                CHECK(t1 - floorT <= 0.6 * (t0 - floorT), "fs %.0f feed %u seat %u T30 %.3f -> %.3f (floor %.3f; excess fall under 40 percent)", fs, t, m, t0, t1, floorT);
                const double dl = bandEnergyDb(after, fsLow) - bandEnergyDb(before, fsLow);
                CHECK(std::fabs(dl) <= 1.5, "fs %.0f feed %u seat %u level shift %.2f dB", fs, t, m, dl);
            }
        }
    }
}

static void testExclusionAndSupport() {
    for (double fs : kRates) {
        const Room room = makeRoom(fs);
        n60_mimo_problem prob;
        fillProblem(room, prob);
        prob.tau_seconds = 0.010;   // at tau 0 the cut at t = 0 leaks the in-band response (see G-numbered gap)
        prob.sources[1].excluded = 1;   // right main plays its own program only
        const Design d = design(prob);
        CHECK(d.status == 0, "fs %.0f excluded design status %d", fs, d.status);
        if (d.status != 0) continue;
        const uint32_t taps = d.info.taps;
        bool rowZero = true, colZero = true, othersLive = false;
        for (uint32_t t = 0; t < kSources; ++t)
            for (uint32_t i = 0; i < taps; ++i) {
                if (d.taps[(static_cast<size_t>(1) * kSources + t) * taps + i] != 0.0f) rowZero = false;
                if (d.taps[(static_cast<size_t>(t) * kSources + 1) * taps + i] != 0.0f) colZero = false;
                if (t != 1 && d.taps[(static_cast<size_t>(2) * kSources + t) * taps + i] != 0.0f) othersLive = true;
            }
        CHECK(rowZero && colZero, "fs %.0f excluded row/column exactly zero", fs);
        CHECK(othersLive, "fs %.0f other sources still treat", fs);
        CHECK(d.info.effort_peak_db[1] <= -300.0, "fs %.0f excluded effort reported", fs);

        const double fsLow = d.info.low_rate_hz;
        for (uint32_t s : {0u, 2u, 3u}) {
            double inBand = -400;
            const double lo = prob.sources[s].support_low_hz, hi = prob.sources[s].support_high_hz;
            for (double f = lo; f <= hi; f += 0.5) inBand = std::max(inBand, rowEffortDb(d, s, f, fsLow));
            // 40 dB down from 1.5 octaves above the range (33 dB below it, where the cut at t = 0 leaks); 30 dB at one octave (the row taper reaches -46 dB
            // there, but the truncated synthesis leaks a little).
            const double outside[][2] = {{lo * 0.5, 30.0}, {hi * 2.0, 30.0}, {lo * 0.35, 33.0}, {hi * 3.0, 40.0}, {500.0, 40.0}};
            for (const auto &o : outside) {
                const double f = o[0];
                if (f < 5.0) continue;
                const double e = rowEffortDb(d, s, f, fsLow);
                CHECK(e <= inBand - o[1], "fs %.0f source %u effort at %.1f Hz is %.1f dB, in band peak %.1f dB (want %.0f down)", fs, s, f, e, inBand, o[1]);
            }
        }
    }
}

static void testTau() {
    for (double fs : kRates) {
        const Room room = makeRoom(fs);
        n60_mimo_problem prob;
        fillProblem(room, prob);
        prob.tau_seconds = 0.010;
        const Design d = design(prob);
        CHECK(d.status == 0, "fs %.0f tau design status %d pre %.1f", fs, d.status, d.info.pre_energy_db);
        if (d.status != 0) continue;
        const double fsLow = d.info.low_rate_hz;
        const int tauSamples = static_cast<int>(std::lround(0.010 * fsLow));
        // tau is not a whole low-rate sample: the delta carries the fractional part, so compare arrival only.
        const std::vector<float> before = treated(room, d, 0, 0, false);
        const std::vector<float> after = treated(room, d, 0, 0, true, tauSamples);
        // Remove the integer delay added by the test filter: the designed delta already includes the tau shift
        // of the target, so the arrival of (E + I z^-tauSamples) must land tau after the untreated arrival.
        const int64_t shift = static_cast<int64_t>(argmax(after)) - static_cast<int64_t>(argmax(before));
        CHECK(std::llabs(shift - tauSamples) <= 1, "fs %.0f arrival shift %lld want %d", fs, static_cast<long long>(shift), tauSamples);

        n60_mimo_problem bad = prob;
        bad.tau_seconds = 0.0201;
        CHECK(design(bad).status == N60_MIMO_ERR_TAU, "fs %.0f tau over 20 ms refused", fs);
        bad.tau_seconds = -0.001;
        CHECK(design(bad).status == N60_MIMO_ERR_TAU, "fs %.0f negative tau refused", fs);
    }
}

static void testFamilies() {
    const double pairs[4][2] = {{44100, 48000}, {88200, 96000}, {176400, 192000}, {352800, 384000}};
    for (const auto &pr : pairs) {
        Design ds[2];
        for (int i = 0; i < 2; ++i) {
            const Room room = makeRoom(pr[i]);
            n60_mimo_problem prob;
            fillProblem(room, prob);
            // The same filter duration at both rates (the tap count is a length in low-rate samples), since the
            // truncation of a long filter is part of the design.
            uint32_t dec = 0;
            double low = 0;
            n60_mimo_low_rate(pr[i], &dec, &low);
            prob.taps = static_cast<uint32_t>(std::lround(1.3 * low));
            ds[i] = design(prob);
            CHECK(ds[i].status == 0, "fs %.0f family design status %d", pr[i], ds[i].status);
        }
        if (ds[0].status != 0 || ds[1].status != 0) continue;
        CHECK(ds[0].info.decimation == ds[1].info.decimation, "family shares D");
        // Compare what the filters do, the predicted treated response at each seat for each feed: the filter
        // entries themselves are the min-norm answer of an under-determined problem (4 sources, 3 seats), which
        // magnifies 0.001 dB differences between the two sampled rooms, while the response they produce does not.
        double worst = 0;
        std::vector<std::vector<float>> qs[2];
        for (int i = 0; i < 2; ++i) {
            const Room room = makeRoom(pr[i]);
            for (uint32_t s = 0; s < kSources; ++s)
                for (uint32_t m = 0; m < kSeats; ++m) qs[i].push_back(lowPlant(room, s, m));
        }
        for (uint32_t t = 0; t < kSources; ++t)
            for (uint32_t m = 0; m < kSeats; ++m)
                for (double f = 20.0; f <= 150.0; f += 2.5) {
                    double mag[2];
                    for (int i = 0; i < 2; ++i) {
                        double sr = 0, si = 0;
                        for (uint32_t s = 0; s < kSources; ++s) {
                            const std::vector<float> &q = qs[i][s * kSeats + m];
                            double qr, qi, er, ei;
                            n60_mimo_tap_response(q.data(), static_cast<uint32_t>(q.size()), ds[i].info.low_rate_hz, f, &qr, &qi);
                            n60_mimo_tap_response(&ds[i].taps[(static_cast<size_t>(s) * kSources + t) * ds[i].info.taps], ds[i].info.taps,
                                                  ds[i].info.low_rate_hz, f, &er, &ei);
                            if (s == t) er += 1.0;   // C = E + I (tau 0)
                            sr += qr * er - qi * ei;
                            si += qr * ei + qi * er;
                        }
                        mag[i] = std::sqrt(sr * sr + si * si);
                    }
                    worst = std::max(worst, std::fabs(20.0 * std::log10(mag[0] / mag[1])));
                }
        CHECK(worst <= 0.1, "family %.0f/%.0f designs differ by %.3f dB", pr[0], pr[1], worst);
    }
}

static void testDeterminismAndLimits() {
    const Room room = makeRoom(48000);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    const Design a = design(prob), b = design(prob);
    CHECK(a.status == 0 && a.taps == b.taps, "two runs are bit identical");
    n60_mimo_problem bad = prob;
    bad.thermal_limit_db = std::nan("");
    CHECK(design(bad).status == N60_MIMO_ERR_ARGUMENT, "NaN thermal limit refused");
    bad = prob;
    bad.causality_limit_db = std::nan("");
    CHECK(design(bad).status == N60_MIMO_ERR_ARGUMENT, "NaN causality limit refused");
    float in[4] = {1, 0, 0, 0}, out[1];
    uint64_t n = 0;
    CHECK(n60_mimo_decimate(48000, in, 4, out, 0, &n) == N60_MIMO_ERR_CAPACITY, "decimate capacity");
    CHECK(n60_mimo_interpolate(48000, in, 4, out, 1, &n) == N60_MIMO_ERR_CAPACITY, "interpolate capacity");
}

static void testErrors() {
    const Room room = makeRoom(48000);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    {
        n60_mimo_problem p = prob;
        p.program_plant[2][1] = nullptr;
        const Design d = design(p);
        CHECK(d.status == N60_MIMO_ERR_MISSING_PLANT && d.info.bad_source == 2 && d.info.bad_seat == 1, "missing plant named (%d, %d, %d)",
              d.status, d.info.bad_source, d.info.bad_seat);
        p.seats[1].included = 0;   // the seat is no longer included, so the missing plant does not matter
        CHECK(design(p).status == 0, "a seat that is not included needs no plant");
    }
    {
        n60_mimo_problem p = prob;
        for (uint32_t s = 0; s < kSources; ++s) p.sources[s].excluded = 1;
        CHECK(design(p).status == N60_MIMO_ERR_SUPPORT, "nothing active");
        p = prob;
        p.sources[0].support_low_hz = 200.0;
        CHECK(design(p).status == N60_MIMO_ERR_SUPPORT, "bad support range");
        p = prob;
        p.sample_rate = 22050.0;
        CHECK(design(p).status == N60_MIMO_ERR_RATE, "rate refused");
        p = prob;
        p.primary_seat = 5;
        CHECK(design(p).status == N60_MIMO_ERR_ARGUMENT, "primary seat");
        p = prob;
        float small[8];
        CHECK(n60_mimo_design(&p, small, 8, nullptr) == N60_MIMO_ERR_CAPACITY, "capacity");
        p.sources[2].gain_limit_db = -20.0;   // an impossible budget: the design is refused naming the source
        const Design d = design(p);
        CHECK(d.status == N60_MIMO_ERR_HEADROOM && d.info.bad_source >= 0 && d.info.regularisation_steps == 4, "headroom refusal (%d, source %d, steps %u)",
              d.status, d.info.bad_source, d.info.regularisation_steps);
    }
    {
        // More regularisation lowers the effort: the headroom loop can only help.
        n60_mimo_problem p = prob;
        const Design a = design(p);
        p.regularisation = 1e-1;
        const Design b = design(p);
        // Effort moves between sources as the weight changes, so compare the largest peak over the sources.
        double pa = -400, pb = -400;
        for (uint32_t s = 0; s < kSources; ++s) { pa = std::max(pa, a.info.effort_peak_db[s]); pb = std::max(pb, b.info.effort_peak_db[s]); }
        CHECK(a.status == 0 && b.status == 0 && pb < pa, "regularisation reduces the largest effort peak (%.1f vs %.1f dB)", pb, pa);
    }
    {
        // Single source, single seat is a valid problem.
        n60_mimo_problem p;
        n60_mimo_defaults(48000, 1, 1, &p);
        p.program_plant[0][0] = room.ir[2][0].data();
        p.program_count[0][0] = room.ir[2][0].size();
        std::vector<float> taps(p.taps);
        n60_mimo_info info;
        CHECK(n60_mimo_design(&p, taps.data(), taps.size(), &info) == 0, "single source");
    }
}

int main() {
    CHECK(n60_mimo_abi_version() == N60_MIMO_ABI_VERSION, "abi");
    testErrors();
    testDeterminismAndLimits();
    testDecayAndLevel();
    testExclusionAndSupport();
    testTau();
    testFamilies();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("mimo tests passed");
    return 0;
}
