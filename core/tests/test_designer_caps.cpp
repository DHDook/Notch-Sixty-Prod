// E9 S4: designer single-band caps (n60/correct.h ABI v4, n60/xover.h ABI v5) at the eight standard rates. With the long cap
// (max_single_band_taps 262144, firScheme 1) a design is single band up to 262144 taps and never two-band; a longer one is
// refused with a named reason. With the short cap (0 or 32768) the choice is today's two-band rule, unchanged.
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "n60/correct.h"
#include "n60/xover.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static n60_xover_spec spec(uint32_t family, uint32_t order, double hz) {
    n60_xover_spec s{};
    s.struct_size = sizeof(s);
    s.family = family;
    s.order = order;
    s.corner_hz = hz;
    return s;
}

struct Way {
    n60_xover_fir_report report{};
    std::vector<float> full, low;
    int status = 0;
};

static Way design(double fs, const n60_xover_spec *hp, const n60_xover_spec *lp, uint32_t delay, uint32_t cap) {
    Way w;
    n60_xover_fir_params p{};
    p.struct_size = sizeof(p);
    p.sample_rate = fs;
    p.highpass = hp;
    p.lowpass = lp;
    p.group_delay_frames = delay;
    p.max_single_band_taps = cap;
    n60_xover_fir_report plan{};
    w.status = n60_xover_fir_plan(&p, &plan);
    if (w.status != N60_XOVER_OK) return w;
    w.full.assign(plan.full_tap_count, 0.0f);
    w.low.assign(plan.low_tap_count + 1, 0.0f);
    w.status = n60_xover_fir_synthesize(&p, w.full.data(), w.full.size(), w.low.data(), w.low.size(), &w.report);
    if (w.status == N60_XOVER_OK) {
        CHECK(w.report.full_tap_count == plan.full_tap_count && w.report.two_band == plan.two_band &&
                  w.report.latency_frames == plan.latency_frames, "plan and synthesis agree");
    }
    return w;
}

// dB magnitude of single-band taps at hz with the group delay removed.
static double singleDb(const std::vector<float> &taps, size_t count, double delay, double fs, double hz) {
    const double om = 2.0 * kPi * hz / fs;
    std::complex<double> acc(0, 0);
    for (size_t n = 0; n < count; ++n) acc += static_cast<double>(taps[n]) * std::polar(1.0, -om * (static_cast<double>(n) - delay));
    return 20.0 * std::log10(std::abs(acc) + 1e-12);
}

static double magDb(const Way &w, double fs, double hz) {
    if (w.report.two_band) {
        double mag = 0, ph = 0;
        n60_correct_two_band_response(fs, w.report.decimation, w.report.extra_delay_frames, w.report.group_delay_frames, w.full.data(),
                                      w.report.full_tap_count, w.low.data(), w.report.low_tap_count, &hz, 1, &mag, &ph);
        return mag;
    }
    return singleDb(w.full, w.report.full_tap_count, w.report.group_delay_frames, fs, hz);
}

// Worst deviation of a way from the IIR magnitude of its low-pass over 30 Hz .. 0.45 fs where the target is above -30 dB.
static double worstDeviation(const Way &w, double fs, const n60_xover_spec *lp) {
    n60_xover_cascade c{};
    n60_xover_design(lp, 0, fs, &c);
    double worst = 0;
    for (double hz = 30.0; hz <= std::fmin(20000.0, 0.45 * fs); hz *= std::pow(2.0, 1.0 / 6.0)) {
        double want = 0;
        n60_xover_magnitude_db(&c, fs, hz, &want);
        if (want < -30.0) continue;
        worst = std::fmax(worst, std::fabs(magDb(w, fs, hz) - want));
    }
    return worst;
}

static void testCrossoverCaps() {
    const n60_xover_spec lp = spec(2, 4, 1500);
    for (double fs : kRates) {
        // A 20000-frame group delay is 40001 taps: two-band today, single band under the long cap, at every rate.
        const Way shortW = design(fs, nullptr, &lp, 20000, 0);
        const Way explicitShort = design(fs, nullptr, &lp, 20000, N60_CORRECT_STAGE_TAPS);
        const Way longW = design(fs, nullptr, &lp, 20000, N60_CORRECT_STAGE_TAPS_LONG);
        CHECK(shortW.status == N60_XOVER_OK && shortW.report.two_band == 1, "fs=%g short cap stays two-band", fs);
        CHECK(explicitShort.status == N60_XOVER_OK && explicitShort.report.two_band == 1 && explicitShort.full == shortW.full &&
                  explicitShort.low == shortW.low, "fs=%g cap 0 and 32768 agree", fs);
        CHECK(longW.status == N60_XOVER_OK && longW.report.two_band == 0 && longW.report.full_tap_count == 40001 &&
                  longW.report.low_tap_count == 0 && longW.report.decimation == 1 && longW.report.latency_frames == 256 + 20000,
              "fs=%g long cap is single band", fs);
        if (longW.status != N60_XOVER_OK || shortW.status != N60_XOVER_OK) continue;
        const double longDev = worstDeviation(longW, fs, &lp), shortDev = worstDeviation(shortW, fs, &lp);
        CHECK(longDev <= std::fmax(0.3, shortDev), "fs=%g long deviation %.3f dB vs two-band %.3f dB", fs, longDev, shortDev);

        // Boundaries: 131071 is 262143 taps (single), 131072 is 262145 taps (refused); 16384 is 32769 taps.
        const Way edge = design(fs, nullptr, &lp, 131071, N60_CORRECT_STAGE_TAPS_LONG);
        CHECK(edge.status == N60_XOVER_OK && !edge.report.two_band && edge.report.full_tap_count == 262143, "fs=%g 262143 taps", fs);
        const Way over = design(fs, nullptr, &lp, 131072, N60_CORRECT_STAGE_TAPS_LONG);
        CHECK(over.status == N60_XOVER_ERR_TOO_LONG, "fs=%g 262145 taps refused: %d", fs, over.status);
        const Way justOver = design(fs, nullptr, &lp, 16384, N60_CORRECT_STAGE_TAPS_LONG);
        CHECK(justOver.status == N60_XOVER_OK && !justOver.report.two_band && justOver.report.full_tap_count == 32769, "fs=%g 32769 taps", fs);
        CHECK(design(fs, nullptr, &lp, 16384, 0).report.two_band == 1, "fs=%g 32769 taps two-band with the short cap", fs);
    }
    // Automatic delay is five periods of the lowest corner: 5 Hz at 384 kHz asks for 384000 frames. The long cap shortens it.
    const n60_xover_spec deep = spec(2, 4, 5);
    const Way autoLong = design(384000, nullptr, &deep, 0, N60_CORRECT_STAGE_TAPS_LONG);
    CHECK(autoLong.status == N60_XOVER_OK && !autoLong.report.two_band && autoLong.report.group_delay_frames == 131071 &&
              autoLong.report.full_tap_count == 262143, "automatic delay shortened to fit: %u", autoLong.report.group_delay_frames);
    const Way autoShort = design(384000, nullptr, &deep, 0, 0);
    CHECK(autoShort.status == N60_XOVER_OK && autoShort.report.two_band == 1 && autoShort.report.group_delay_frames == 262144, "short cap unchanged");
    CHECK(design(48000, nullptr, &lp, 100, 16384).status == N60_XOVER_ERR_ARGUMENT, "cap below 32768 refused");
    CHECK(design(48000, nullptr, &lp, 100, 262145).status == N60_XOVER_ERR_ARGUMENT, "cap above 262144 refused");
}

static double shelfAmp(double hz, void *) { return std::pow(10.0, (hz < 200.0 ? 6.0 : 0.0) / 20.0); }

// The capped linear-phase synthesis: the short cap is bit-identical to the banded call, the long cap is single band to 262144 taps.
static void testCappedSynthesis() {
    for (double fs : kRates) {
        for (uint32_t L : {1024u, 20000u}) {
            std::vector<float> a(32768), la(32768), b(32768), lb(32768);
            n60_correct_two_band_report ra{}, rb{};
            const int32_t sa = n60_correct_synthesize_linear_phase_banded(fs, L, shelfAmp, nullptr, nullptr, a.data(), a.size(), la.data(), la.size(), &ra);
            const int32_t sb = n60_correct_synthesize_linear_phase_capped(fs, L, shelfAmp, nullptr, nullptr, N60_CORRECT_STAGE_TAPS, b.data(), b.size(), lb.data(), lb.size(), &rb);
            CHECK(sa == N60_CORRECT_OK && sb == N60_CORRECT_OK, "fs=%g L=%u status %d %d", fs, L, sa, sb);
            CHECK(a == b && la == lb && ra.full_tap_count == rb.full_tap_count && ra.low_tap_count == rb.low_tap_count &&
                      ra.decimation == rb.decimation, "fs=%g L=%u short cap identical to banded", fs, L);
        }
        // Long cap, 65,536-tap-class design (L = 32768): single band, 65537 taps, response tracks the target.
        std::vector<float> taps(262144), low(1);
        n60_correct_two_band_report r{};
        CHECK(n60_correct_synthesize_linear_phase_capped(fs, 32768, shelfAmp, nullptr, nullptr, N60_CORRECT_STAGE_TAPS_LONG, taps.data(),
                                                         taps.size(), low.data(), 0, &r) == N60_CORRECT_OK, "long synth fs=%g", fs);
        CHECK(r.decimation == 1 && r.low_tap_count == 0 && r.full_tap_count == 65537, "fs=%g long report", fs);
        for (double hz : {60.0, 1000.0, 5000.0}) {
            const double want = hz < 200.0 ? 6.0 : 0.0;
            CHECK(std::fabs(singleDb(taps, r.full_tap_count, 32768, fs, hz) - want) < 0.6, "fs=%g %g Hz tracks target", fs, hz);
        }
        CHECK(n60_correct_synthesize_linear_phase_capped(fs, 131072, shelfAmp, nullptr, nullptr, N60_CORRECT_STAGE_TAPS_LONG, taps.data(),
                                                         taps.size(), low.data(), 0, &r) == N60_CORRECT_ERR_TOO_LONG, "fs=%g 262145 refused", fs);
        CHECK(n60_correct_synthesize_linear_phase_capped(fs, 1024, shelfAmp, nullptr, nullptr, 1000, taps.data(), taps.size(), low.data(),
                                                         0, &r) == N60_CORRECT_ERR_ARGUMENT, "bad cap");
    }
}

static void testPlanStage() {
    n60_correct_stage_plan p{};
    const uint32_t shortCap = N60_CORRECT_STAGE_TAPS, longCap = N60_CORRECT_STAGE_TAPS_LONG;
    CHECK(n60_correct_plan_stage(32768, shortCap, &p) == N60_CORRECT_OK && !p.two_band && p.tap_count == 32768, "short 32768");
    CHECK(n60_correct_plan_stage(32769, shortCap, &p) == N60_CORRECT_OK && p.two_band == 1, "short 32769 is two-band");
    CHECK(n60_correct_plan_stage(262144, shortCap, &p) == N60_CORRECT_OK && p.two_band == 1, "short 262144 is two-band");
    CHECK(n60_correct_plan_stage(262145, shortCap, &p) == N60_CORRECT_ERR_TOO_LONG, "short 262145 refused");
    CHECK(n60_correct_plan_stage(32769, longCap, &p) == N60_CORRECT_OK && !p.two_band && p.tap_count == 32769, "long 32769 single");
    CHECK(n60_correct_plan_stage(262144, longCap, &p) == N60_CORRECT_OK && !p.two_band, "long 262144 single");
    CHECK(n60_correct_plan_stage(262145, longCap, &p) == N60_CORRECT_ERR_TOO_LONG, "long 262145 refused");
    // 1 s at 384 kHz.
    CHECK(n60_correct_plan_stage(384000, longCap, &p) == N60_CORRECT_ERR_TOO_LONG, "1 s at 384 kHz refused");
    for (double fs : kRates) {
        const uint64_t second = static_cast<uint64_t>(fs);
        const int32_t s = n60_correct_plan_stage(second, longCap, &p);
        CHECK((second <= longCap) == (s == N60_CORRECT_OK && !p.two_band), "fs=%g 1 s span", fs);
        CHECK(second <= longCap || s == N60_CORRECT_ERR_TOO_LONG, "fs=%g 1 s span reason", fs);
    }
    CHECK(n60_correct_plan_stage(0, longCap, &p) == N60_CORRECT_ERR_ARGUMENT, "zero span");
    CHECK(n60_correct_plan_stage(100, 1000, &p) == N60_CORRECT_ERR_ARGUMENT, "cap too small");
    CHECK(n60_correct_plan_stage(100, longCap, nullptr) == N60_CORRECT_ERR_ARGUMENT, "null plan");
    const std::string reason = n60_correct_status_name(N60_CORRECT_ERR_TOO_LONG);
    CHECK(reason.find("262144") != std::string::npos, "named reason: %s", reason.c_str());
    CHECK(std::string(n60_correct_status_name(-999)) == "unknown status", "unknown status");
}

// Room correction: a grid design synthesised single band at a span that today is two-band tracks the target at least as well.
static void testRoomSingleBand() {
    for (double fs : kRates) {
        std::vector<double> db(N60_CORRECT_GRID_POINTS, 0.0), phase(N60_CORRECT_GRID_POINTS, 0.0);
        for (uint32_t i = 0; i < N60_CORRECT_GRID_POINTS; ++i) {
            const double hz = N60_CORRECT_GRID_START_HZ * std::pow(2.0, i / 48.0);
            db[i] = -4.0 * std::exp(-0.5 * std::pow(std::log2(hz / 70.0) / 0.4, 2.0)) + 2.0 * std::exp(-0.5 * std::pow(std::log2(hz / 1000.0) / 0.5, 2.0));
        }
        const uint32_t span = 120000;
        n60_correct_synth_params params{};
        n60_correct_synth_defaults(N60_CORRECT_MODE_MIXED_PHASE, fs, span, 0.05, &params);
        n60_correct_design_grid grid{db.data(), phase.data(), nullptr, nullptr, nullptr, nullptr};
        std::vector<float> taps(span), full(32768), low(32768);
        n60_correct_synth_report rep{};
        n60_correct_two_band_report two{};
        CHECK(n60_correct_synthesize(&params, &grid, taps.data(), taps.size(), &rep) == N60_CORRECT_OK, "single synth fs=%g", fs);
        CHECK(n60_correct_synthesize_two_band(&params, &grid, full.data(), full.size(), low.data(), low.size(), &two) == N60_CORRECT_OK, "two-band synth fs=%g", fs);
        double worstSingle = 0, worstTwo = 0;
        for (uint32_t i = 0; i < N60_CORRECT_GRID_POINTS; i += 8) {
            const double hz = N60_CORRECT_GRID_START_HZ * std::pow(2.0, i / 48.0);
            if (hz < 25.0 || hz > 0.45 * fs) continue;
            // A mixed-phase design is linear phase about the declared latency; magnitude is read with that delay removed.
            const double single = singleDb(taps, span, rep.declared_latency_frames, fs, hz);
            double mag = 0, ph = 0, f = hz;
            n60_correct_two_band_response(fs, two.decimation, two.extra_delay_frames, two.declared_latency_frames, full.data(), two.full_tap_count,
                                          low.data(), two.low_tap_count, &f, 1, &mag, &ph);
            worstSingle = std::fmax(worstSingle, std::fabs(single - db[i]));
            worstTwo = std::fmax(worstTwo, std::fabs(mag - db[i]));
        }
        CHECK(worstSingle <= std::fmax(0.5, worstTwo), "fs=%g single %.3f dB vs two-band %.3f dB", fs, worstSingle, worstTwo);
        // Above the designer's limit the reason is named.
        n60_correct_synth_params big = params;
        big.tap_count = 384000;
        std::vector<float> none(1);
        CHECK(n60_correct_synthesize(&big, &grid, none.data(), none.size(), &rep) == N60_CORRECT_ERR_TOO_LONG, "fs=%g 1 s refused", fs);
        CHECK(n60_correct_synthesize_two_band(&big, &grid, none.data(), 1, none.data(), 1, &two) == N60_CORRECT_ERR_TOO_LONG, "fs=%g two-band 1 s refused", fs);
    }
}

// Minimum-phase driver linearisation: the long cap lifts the 32768-tap cap on the correction filter.
static void testLinearMinPhaseCap() {
    const n60_xover_spec hp = spec(2, 4, 40);
    const double fs = 384000;
    std::vector<double> nearHz, nearDb;
    for (int i = 0; i < 60; ++i) {
        const double hz = 20.0 * std::pow(2.0, i / 6.0);
        if (hz > 20000.0) break;
        nearHz.push_back(hz);
        nearDb.push_back(hz < 60.0 ? -6.0 : 0.0);
    }
    for (uint32_t cap : {0u, N60_CORRECT_STAGE_TAPS_LONG}) {
        n60_xover_lin_params p{};
        p.struct_size = sizeof(p);
        p.sample_rate = fs;
        p.highpass = &hp;
        p.linear_phase = 0;
        p.max_single_band_taps = cap;
        std::vector<double> grid(N60_XOVER_LIN_MAX_POINTS), corr(N60_XOVER_LIN_MAX_POINTS), pred(N60_XOVER_LIN_MAX_POINTS);
        n60_xover_lin_report lr{};
        CHECK(n60_xover_linearise_design(&p, nearHz.data(), nearDb.data(), static_cast<uint32_t>(nearHz.size()), nullptr, nullptr, 0,
                                         grid.data(), corr.data(), pred.data(), N60_XOVER_LIN_MAX_POINTS, &lr) == N60_XOVER_OK, "design");
        std::vector<float> full(262144), low(1);
        n60_xover_fir_report rep{};
        CHECK(n60_xover_linearise_synthesize(&p, grid.data(), corr.data(), lr.point_count, 0, full.data(), full.size(), low.data(), 0, &rep) ==
                  N60_XOVER_OK, "synth cap=%u", cap);
        if (cap == 0) CHECK(rep.full_tap_count == 32768, "short cap keeps 32768, got %u", rep.full_tap_count);
        else CHECK(rep.full_tap_count > 32768 && rep.full_tap_count <= 262144 && !rep.two_band, "long cap taps %u", rep.full_tap_count);
    }
}

int main() {
    CHECK(n60_xover_abi_version() == N60_XOVER_ABI_VERSION, "xover ABI");
    CHECK(n60_correct_abi_version() == N60_CORRECT_ABI_VERSION, "correct ABI");
    testPlanStage();
    testCrossoverCaps();
    testCappedSynthesis();
    testRoomSingleBand();
    testLinearMinPhaseCap();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("designer caps ok");
    return 0;
}
