// E19 S3: realisation check of the MIMO design (n60_mimo_design_solved, n60_mimo_realise_check) at eight rates.
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

static Room makeRoom(double fs) { return buildRoom(fs); }

static void fillProblem(const Room &room, n60_mimo_problem &prob) {
    n60_mimo_defaults(room.fs, kSources, kSeats, &prob);
    uint32_t dec = 0;
    double low = 0;
    n60_mimo_low_rate(room.fs, &dec, &low);
    prob.taps = static_cast<uint32_t>(std::lround(1.0 * low));
    // 15 ms is the advised bass time target: with tau 0 the solution holds energy before t = 0 that a causal filter
    // cannot realise (G8), which the next test pins down.
    prob.tau_seconds = 0.015;
    for (uint32_t s = 0; s < kSources; ++s) {
        prob.sources[s].support_low_hz = s < 2 ? 30.0 : 20.0;
        prob.sources[s].support_high_hz = s < 2 ? 150.0 : 120.0;
        for (uint32_t m = 0; m < kSeats; ++m) {
            prob.program_plant[s][m] = room.ir[s][m].data();
            prob.program_count[s][m] = room.ir[s][m].size();
        }
    }
}

struct Result {
    int32_t status = 0;
    n60_mimo_info info{};
    std::vector<float> taps, solved;
};

static Result run(const n60_mimo_problem &prob) {
    Result r;
    r.taps.assign(static_cast<size_t>(prob.source_count) * prob.source_count * prob.taps, 0.0f);
    r.solved.assign(static_cast<size_t>(prob.source_count) * prob.source_count * 1700 * 2, 0.0f);
    r.status = n60_mimo_design_solved(&prob, r.taps.data(), r.taps.size(), r.solved.data(), r.solved.size(), &r.info);
    return r;
}

static void testRate(double fs, bool excludeSecondSub) {
    const Room room = makeRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    if (excludeSecondSub) prob.sources[3].excluded = 1;
    const Result r = run(prob);
    CHECK(r.status == 0, "fs %.0f design status %d", fs, r.status);
    if (r.status != 0) return;
    // Same taps as the plain design call.
    std::vector<float> plain(r.taps.size());
    n60_mimo_info pinfo{};
    CHECK(n60_mimo_design(&prob, plain.data(), plain.size(), &pinfo) == 0, "plain design");
    CHECK(plain == r.taps, "fs %.0f solved variant leaves the taps unchanged", fs);

    n60_mimo_realisation rep;
    CHECK(n60_mimo_realise_check(&prob, r.taps.data(), r.taps.size(), r.solved.data(), r.solved.size(), &r.info, &rep) == 0, "check");
    std::printf("fs %.0f%s: deviation %.3f dB at %.2f Hz, edge %.4f, gain overshoot %.2f %.2f %.2f %.2f\n", fs, excludeSecondSub ? " (excl)" : "",
                rep.max_deviation_db, rep.max_deviation_hz, rep.edge_energy_fraction, rep.gain_overshoot_db[0], rep.gain_overshoot_db[1],
                rep.gain_overshoot_db[2], rep.gain_overshoot_db[3]);
    CHECK(rep.max_deviation_db <= 0.25, "fs %.0f realised response deviates %.3f dB from the solved response", fs, rep.max_deviation_db);
    CHECK(rep.edge_energy_fraction <= 0.12, "fs %.0f edge energy %.4f", fs, rep.edge_energy_fraction);
    for (uint32_t s = 0; s < kSources; ++s) {
        if (excludeSecondSub && s == 3) {
            CHECK(rep.gain_overshoot_db[s] == -400.0, "excluded source reports no overshoot");
            continue;
        }
        CHECK(rep.gain_overshoot_db[s] <= 0.35, "fs %.0f source %u gain overshoot %.3f dB", fs, s, rep.gain_overshoot_db[s]);
        CHECK(rep.effort_overshoot_db[s] <= 0.35, "fs %.0f source %u effort overshoot %.3f dB", fs, s, rep.effort_overshoot_db[s]);
    }
    if (excludeSecondSub) {
        const uint32_t K = r.info.grid_bins;
        bool zero = true;
        for (uint32_t t = 0; t < kSources; ++t)
            for (uint32_t k = 0; k < 2 * K; ++k) {
                zero = zero && r.solved[(static_cast<size_t>(3) * kSources + t) * K * 2 + k] == 0.0f;
                zero = zero && r.solved[(static_cast<size_t>(t) * kSources + 3) * K * 2 + k] == 0.0f;
            }
        CHECK(zero, "excluded source solved row and column are exactly zero");
    }
}

static void testDetectsDamage() {
    const double fs = 96000;
    const Room room = makeRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    Result r = run(prob);
    CHECK(r.status == 0, "design");
    if (r.status != 0) return;
    // Filters at half amplitude (a wrong realisation) show as a deviation.
    std::vector<float> bad = r.taps;
    for (float &v : bad) v *= 0.5f;
    n60_mimo_realisation rep;
    CHECK(n60_mimo_realise_check(&prob, bad.data(), bad.size(), r.solved.data(), r.solved.size(), &r.info, &rep) == 0, "check");
    CHECK(rep.max_deviation_db > 0.25, "halved filters are caught (%.3f dB)", rep.max_deviation_db);
    // Hard edge: a tap at the very end raises the edge fraction.
    std::vector<float> edgy = r.taps;
    for (size_t p = 0; p < static_cast<size_t>(kSources) * kSources; ++p) edgy[p * prob.taps + prob.taps - 1] = 1.0f;
    CHECK(n60_mimo_realise_check(&prob, edgy.data(), edgy.size(), r.solved.data(), r.solved.size(), &r.info, &rep) == 0, "check");
    CHECK(rep.edge_energy_fraction > 0.12, "edge energy is caught (%.3f)", rep.edge_energy_fraction);
    // Argument and capacity errors.
    CHECK(n60_mimo_realise_check(&prob, nullptr, 0, r.solved.data(), r.solved.size(), &r.info, &rep) == N60_MIMO_ERR_ARGUMENT, "null taps");
    CHECK(n60_mimo_realise_check(&prob, r.taps.data(), 10, r.solved.data(), r.solved.size(), &r.info, &rep) == N60_MIMO_ERR_CAPACITY, "short taps");
    std::vector<float> small(8);
    CHECK(n60_mimo_design_solved(&prob, r.taps.data(), r.taps.size(), small.data(), small.size(), nullptr) == N60_MIMO_ERR_CAPACITY, "short solved");
    CHECK(n60_mimo_design_solved(&prob, r.taps.data(), r.taps.size(), nullptr, 0, nullptr) == N60_MIMO_ERR_ARGUMENT, "null solved");
}

// tau 0: the solution holds energy before t = 0 (G8); the realised response then deviates more, and the design says so
// through pre_energy_db so the UI can advise a larger tau.
static void testTauZero() {
    const double fs = 96000;
    const Room room = makeRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    prob.tau_seconds = 0.0;
    const Result r = run(prob);
    CHECK(r.status == 0, "tau 0 design status %d", r.status);
    if (r.status != 0) return;
    n60_mimo_realisation rep;
    CHECK(n60_mimo_realise_check(&prob, r.taps.data(), r.taps.size(), r.solved.data(), r.solved.size(), &r.info, &rep) == 0, "check");
    CHECK(r.info.pre_energy_db > -30.0, "tau 0 leaves energy before t = 0 (%.1f dB)", r.info.pre_energy_db);
    CHECK(rep.max_deviation_db < 0.5, "tau 0 deviation stays bounded (%.3f dB)", rep.max_deviation_db);
    n60_mimo_problem later = prob;
    later.tau_seconds = 0.015;
    const Result r2 = run(later);
    CHECK(r2.status == 0, "tau 15 ms design status %d", r2.status);
    if (r2.status == 0) CHECK(r2.info.pre_energy_db < r.info.pre_energy_db - 3.0, "raising tau lowers the energy before t = 0 (%.1f vs %.1f dB)", r2.info.pre_energy_db, r.info.pre_energy_db);
}

int main() {
    CHECK(n60_mimo_abi_version() == N60_MIMO_ABI_VERSION && N60_MIMO_ABI_VERSION == 2, "abi");
    for (double fs : kRates) testRate(fs, fs == 96000 || fs == 352800);
    testDetectsDamage();
    testTauZero();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("mimo realise tests passed");
    return 0;
}
