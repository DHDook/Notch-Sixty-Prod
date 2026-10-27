// E8 S8: near-field driver linearisation (n60_xover_linearise_*) on synthetic drivers at the eight standard rates.
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/xover.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
using Cx = std::complex<double>;

static n60_xover_spec spec(uint32_t family, uint32_t order, double hz) {
    n60_xover_spec s{};
    s.struct_size = sizeof(s);
    s.family = family;
    s.order = order;
    s.corner_hz = hz;
    return s;
}

// Analogue peaking section magnitude in dB (gain at the centre, Q).
static double peakDb(double f, double f0, double gainDb, double q) {
    const double a = std::pow(10.0, gainDb / 40.0);
    const Cx s(0.0, f / f0);
    return 20.0 * std::log10(std::abs((s * s + s * (a / q) + 1.0) / (s * s + s * (1.0 / (a * q)) + 1.0)));
}

static double hp2Db(double f, double f0, double q) {
    const Cx s(0.0, f / f0);
    return 20.0 * std::log10(std::abs(s * s / (s * s + s / q + 1.0)));
}

struct Capture {
    std::vector<double> hz, db;
};

// A driver: resonant 2nd-order roll-off at 90 Hz, a broad bump at 1.2 kHz, a breakup peak at 6 kHz.
static Capture driver(double dipDb = 0.0, double hpHz = 90.0) {
    Capture c;
    for (double f = 20.0; f <= 20000.0; f *= std::pow(2.0, 1.0 / 48.0)) {
        c.hz.push_back(f);
        c.db.push_back(hp2Db(f, hpHz, 0.9) + peakDb(f, 1200.0, 4.0, 1.5) + peakDb(f, 6000.0, 8.0, 3.0) + 88.0 +
                       (dipDb != 0.0 ? peakDb(f, 1000.0, dipDb, 1.0) : 0.0));
    }
    return c;
}

struct Design {
    std::vector<double> grid, corr, pred;
    n60_xover_lin_report report{};
    int status = 0;
};

static Design design(const n60_xover_lin_params &p, const Capture &near, const Capture *far = nullptr) {
    Design d;
    d.grid.resize(N60_XOVER_LIN_MAX_POINTS);
    d.corr.resize(N60_XOVER_LIN_MAX_POINTS);
    d.pred.resize(N60_XOVER_LIN_MAX_POINTS);
    d.status = n60_xover_linearise_design(&p, near.hz.data(), near.db.data(), static_cast<uint32_t>(near.hz.size()),
                                          far ? far->hz.data() : nullptr, far ? far->db.data() : nullptr,
                                          far ? static_cast<uint32_t>(far->hz.size()) : 0, d.grid.data(), d.corr.data(),
                                          d.pred.data(), N60_XOVER_LIN_MAX_POINTS, &d.report);
    d.grid.resize(d.report.point_count);
    d.corr.resize(d.report.point_count);
    d.pred.resize(d.report.point_count);
    return d;
}

static n60_xover_lin_params params(double fs, const n60_xover_spec *hp, const n60_xover_spec *lp, uint32_t linear) {
    n60_xover_lin_params p{};
    p.struct_size = sizeof(p);
    p.sample_rate = fs;
    p.highpass = hp;
    p.lowpass = lp;
    p.linear_phase = linear;
    return p;
}

static void testFlatPassbandAndLimits() {
    const n60_xover_spec hp = spec(2, 4, 300), lp = spec(2, 4, 3000);
    for (double fs : kRates) {
        const Design d = design(params(fs, &hp, &lp, 0), driver());
        CHECK(d.status == N60_XOVER_OK, "fs=%g status %d", fs, d.status);
        CHECK(d.report.ripple_before_db > 2.0, "fs=%g driver should start uneven: %.2f", fs, d.report.ripple_before_db);
        CHECK(d.report.ripple_after_db < 0.5, "fs=%g ripple after %.3f dB", fs, d.report.ripple_after_db);
        CHECK(d.report.max_boost_db <= 6.0 + 1e-9, "fs=%g boost %.3f", fs, d.report.max_boost_db);
        for (size_t i = 0; i < d.grid.size(); ++i) {
            if (d.grid[i] < 300.0) CHECK(d.corr[i] <= 1e-12, "fs=%g boost below the high-pass corner at %g Hz: %.3f", fs, d.grid[i], d.corr[i]);
            CHECK(d.corr[i] >= -24.0 - 1e-9, "cut floor");
        }
        const Design e = design(params(fs, &hp, &lp, 0), driver());
        CHECK(std::memcmp(d.corr.data(), e.corr.data(), d.corr.size() * sizeof(double)) == 0, "fs=%g not deterministic", fs);
    }
}

static void testBoostCap() {
    const n60_xover_spec hp = spec(2, 4, 300), lp = spec(2, 4, 3000);
    const Design d = design(params(48000, &hp, &lp, 0), driver(-30.0));
    CHECK(d.status == N60_XOVER_OK, "status");
    CHECK(d.report.boost_capped == 1, "a 30 dB dip must hit the cap");
    CHECK(d.report.max_boost_db <= 6.0 + 1e-9 && d.report.max_boost_db > 5.9, "boost %.3f", d.report.max_boost_db);
    n60_xover_lin_params p = params(48000, &hp, &lp, 0);
    p.max_boost_db = 3.0;
    const Design e = design(p, driver(-30.0));
    CHECK(e.report.max_boost_db <= 3.0 + 1e-9, "custom cap %.3f", e.report.max_boost_db);
    p.max_boost_db = 9.0;
    CHECK(design(p, driver()).status == N60_XOVER_ERR_ARGUMENT, "a cap above 6 dB is refused");
}

// A driver that rolls off through the way's own high-pass corner is never boosted below it.
static void testNoBoostBelowHighPass() {
    const n60_xover_spec hp = spec(2, 4, 1000), lp = spec(2, 4, 5000);
    for (double fs : kRates) {
        const Design d = design(params(fs, &hp, &lp, 0), driver(0.0, 700.0));
        CHECK(d.status == N60_XOVER_OK, "status");
        for (size_t i = 0; i < d.grid.size(); ++i) {
            if (d.grid[i] < 1000.0) CHECK(d.corr[i] <= 1e-12, "fs=%g boost %.3f at %g Hz below the corner", fs, d.corr[i], d.grid[i]);
        }
        CHECK(d.report.ripple_after_db < 1.0, "fs=%g ripple %.3f", fs, d.report.ripple_after_db);
    }
}

// A near-field capture that is wrong above the merge (a rising artefact) is replaced by the level-matched far field.
static void testFarFieldMerge() {
    const n60_xover_spec hp = spec(2, 4, 300), lp = spec(2, 4, 3000);
    Capture nearField, farField;
    for (double f = 20.0; f <= 20000.0; f *= std::pow(2.0, 1.0 / 48.0)) {
        const double truth = hp2Db(f, 90.0, 0.9) + 88.0;
        nearField.hz.push_back(f);
        nearField.db.push_back(truth + (f > 800.0 ? 10.0 * std::log2(f / 800.0) : 0.0));
        farField.hz.push_back(f);
        farField.db.push_back(truth - 12.0);
    }
    n60_xover_lin_params p = params(96000, &hp, &lp, 0);
    const Design without = design(p, nearField);
    p.merge_hz = 700.0;
    const Design with = design(p, nearField, &farField);
    CHECK(with.status == N60_XOVER_OK, "status");
    CHECK(with.report.ripple_after_db < 0.5, "merged ripple %.3f", with.report.ripple_after_db);
    CHECK(without.report.ripple_before_db > 5.0, "the artefact must be visible without the merge");
}

static void testSynthesis() {
    const n60_xover_spec hp = spec(2, 4, 300), lp = spec(2, 4, 3000);
    for (double fs : kRates) {
        for (uint32_t linear = 0; linear < 2; ++linear) {
            const n60_xover_lin_params p = params(fs, &hp, &lp, linear);
            const Design d = design(p, driver());
            std::vector<float> full(32768), low(32768);
            n60_xover_fir_report report{};
            const int s = n60_xover_linearise_synthesize(&p, d.grid.data(), d.corr.data(), static_cast<uint32_t>(d.grid.size()), 0,
                                                         full.data(), full.size(), low.data(), low.size(), &report);
            CHECK(s == N60_XOVER_OK, "fs=%g linear=%u synth %d", fs, linear, s);
            if (s != N60_XOVER_OK) continue;
            n60_xover_cascade h, l;
            n60_xover_design(&hp, 1, fs, &h);
            n60_xover_design(&lp, 0, fs, &l);
            double worst = 0.0;
            for (double hz : {400.0, 700.0, 1200.0, 2000.0, 2800.0}) {
                double got = 0.0, a = 0.0, b = 0.0;
                CHECK(n60_xover_fir_magnitude_db(fs, &report, full.data(), low.data(), &hz, 1, &got) == N60_XOVER_OK, "magnitude");
                double want = 0.0;
                for (size_t i = 0; i + 1 < d.grid.size(); ++i) {
                    if (d.grid[i + 1] >= hz) {
                        const double t = std::log(hz / d.grid[i]) / std::log(d.grid[i + 1] / d.grid[i]);
                        want = d.corr[i] + t * (d.corr[i + 1] - d.corr[i]);
                        break;
                    }
                }
                if (linear) {
                    n60_xover_magnitude_db(&h, fs, hz, &a);
                    n60_xover_magnitude_db(&l, fs, hz, &b);
                    want += a + b;
                }
                worst = std::fmax(worst, std::fabs(got - want));
            }
            CHECK(worst < 0.3, "fs=%g linear=%u FIR magnitude is %.3f dB from the design", fs, linear, worst);
            if (linear) CHECK(report.group_delay_frames >= 32 && report.latency_frames >= report.group_delay_frames, "linear latency");
            else CHECK(report.group_delay_frames < report.full_tap_count / 2, "min-phase peak early: %u of %u", report.group_delay_frames, report.full_tap_count);
        }
    }
}

static void testArguments() {
    const n60_xover_spec hp = spec(2, 4, 300);
    n60_xover_lin_params p = params(48000, nullptr, nullptr, 0);
    Capture c = driver();
    Design d = design(p, c);
    CHECK(d.status == N60_XOVER_ERR_ARGUMENT, "no corners");
    p = params(48000, &hp, nullptr, 0);
    c.hz[5] = c.hz[4];
    d = design(p, c);
    CHECK(d.status == N60_XOVER_ERR_ARGUMENT, "non-ascending capture");
}

int main() {
    CHECK(n60_xover_abi_version() == 4, "abi");
    testFlatPassbandAndLimits();
    testBoostCap();
    testNoBoostBelowHighPass();
    testFarFieldMerge();
    testSynthesis();
    testArguments();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("xover linearise OK");
    return 0;
}
