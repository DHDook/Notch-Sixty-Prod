// E33 S21: fit bands to a curve (n60/eqfit.h) at the eight standard rates: synthetic rooms with known peaks are fitted
// within a stated tolerance, the same input gives the same bands, the boost cap holds, bad input is refused.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/eqfit.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

struct Room {
    std::vector<double> hz, measured, target;
};

static double bump(double f, double f0, double db, double widthOct) {
    const double x = std::log2(f / f0) / widthOct;
    return db * std::exp(-0.5 * x * x);
}

// A room with a +9 dB peak at 63 Hz, a +6 dB peak at 140 Hz, a 5 dB dip at 250 Hz and a gentle 3 dB lift below 40 Hz.
static Room makeRoom(double rate) {
    Room r;
    const double top = 0.45 * rate;
    for (double f = 10.0; f < top && f < 20000.0; f *= std::pow(2.0, 1.0 / 24.0)) r.hz.push_back(f);
    for (double f : r.hz) {
        const double lift = f < 40.0 ? 3.0 * (1.0 - std::log2(f / 10.0) / 2.0) : 0.0;
        r.measured.push_back(bump(f, 63, 9, 0.12) + bump(f, 140, 6, 0.15) + bump(f, 250, -5, 0.1) + lift);
        r.target.push_back(0.0);
    }
    return r;
}

struct Fit {
    int rc = 0;
    uint32_t count = 0;
    std::vector<n60_eqfit_band> bands;
    std::vector<double> predicted;
    double before = 0, after = 0;
};

static Fit fit(const Room &room, double rate, uint32_t maxBands, double boost, double cut, double lo = 20, double hi = 500) {
    n60_eqfit_problem p{};
    p.struct_size = sizeof p;
    p.sample_rate = rate;
    p.point_count = static_cast<uint32_t>(room.hz.size());
    p.frequencies_hz = room.hz.data();
    p.measured_db = room.measured.data();
    p.target_db = room.target.data();
    p.low_hz = lo;
    p.high_hz = hi;
    p.max_bands = maxBands;
    p.max_boost_db = boost;
    p.max_cut_db = cut;
    Fit f;
    f.bands.resize(maxBands);
    f.predicted.resize(room.hz.size());
    n60_eqfit_result r{};
    r.struct_size = sizeof r;
    r.bands = f.bands.data();
    r.predicted_db = f.predicted.data();
    f.rc = n60_eqfit_fit(&p, &r);
    f.count = r.band_count;
    f.before = r.rms_before_db;
    f.after = r.rms_after_db;
    return f;
}

static double residualAt(const Room &room, const Fit &f, double hz) {
    size_t best = 0;
    for (size_t i = 0; i < room.hz.size(); ++i) {
        if (std::fabs(std::log(room.hz[i] / hz)) < std::fabs(std::log(room.hz[best] / hz))) best = i;
    }
    return room.target[best] - f.predicted[best];
}

int main() {
    CHECK(n60_eqfit_abi_version() == N60_EQFIT_ABI_VERSION, "version");
    for (double rate : kRates) {
        const Room room = makeRoom(rate);
        const Fit f = fit(room, rate, 8, 6.0, 12.0);
        CHECK(f.rc == N60_EQFIT_OK, "fit at %.0f: %d", rate, f.rc);
        CHECK(f.count >= 2 && f.count <= 8, "band count %u at %.0f", f.count, rate);
        CHECK(f.after < 0.5 * f.before, "rms %.2f -> %.2f at %.0f", f.before, f.after, rate);
        // Tolerance: the known peaks end within 2.5 dB of the target (they start at 9 and 6 dB).
        CHECK(std::fabs(residualAt(room, f, 63)) < 2.5, "63 Hz residual %.2f at %.0f", residualAt(room, f, 63), rate);
        CHECK(std::fabs(residualAt(room, f, 140)) < 2.5, "140 Hz residual %.2f at %.0f", residualAt(room, f, 140), rate);
        for (uint32_t i = 0; i < f.count; ++i) {
            CHECK(f.bands[i].gain_db <= 6.0 + 1e-9 && f.bands[i].gain_db >= -12.0 - 1e-9, "gain %.2f in cap", f.bands[i].gain_db);
            CHECK(f.bands[i].frequency_hz >= 20.0 && f.bands[i].frequency_hz <= 500.0 + 1e-6, "band inside range");
            if (i > 0) CHECK(f.bands[i].frequency_hz >= f.bands[i - 1].frequency_hz, "bands rise in frequency");
        }
        // Outside the fitted range the bands only reach as far as a shelf or a skirt: the curve stays finite.
        for (double v : f.predicted) CHECK(std::isfinite(v), "predicted finite");

        // Determinism: the same input gives the same bands, bit for bit.
        const Fit g = fit(room, rate, 8, 6.0, 12.0);
        bool same = g.count == f.count && g.predicted == f.predicted;
        for (uint32_t i = 0; same && i < f.count; ++i) {
            same = g.bands[i].type == f.bands[i].type && g.bands[i].frequency_hz == f.bands[i].frequency_hz &&
                   g.bands[i].gain_db == f.bands[i].gain_db && g.bands[i].q == f.bands[i].q;
        }
        CHECK(same, "same input, same bands at %.0f", rate);

        // The boost cap holds: with no boost allowed no band boosts, with a 2 dB cap none exceeds it.
        const Fit none = fit(room, rate, 8, 0.0, 12.0);
        CHECK(none.rc == N60_EQFIT_OK, "no-boost fit");
        for (uint32_t i = 0; i < none.count; ++i) CHECK(none.bands[i].gain_db < 0.0, "boost %.2f with cap 0", none.bands[i].gain_db);
        const Fit two = fit(room, rate, 8, 2.0, 12.0);
        for (uint32_t i = 0; i < two.count; ++i) CHECK(two.bands[i].gain_db <= 2.0 + 1e-9, "boost %.2f over cap 2", two.bands[i].gain_db);
        // A tighter cut cap holds too.
        const Fit cut3 = fit(room, rate, 8, 6.0, 3.0);
        for (uint32_t i = 0; i < cut3.count; ++i) CHECK(cut3.bands[i].gain_db >= -3.0 - 1e-9, "cut %.2f over cap 3", cut3.bands[i].gain_db);

        // The band count limit holds.
        const Fit one = fit(room, rate, 1, 6.0, 12.0);
        CHECK(one.rc == N60_EQFIT_OK && one.count <= 1, "max one band");

        // A curve that already meets the target needs no band.
        Room flat = room;
        for (double &v : flat.measured) v = 1.5;  // a flat level offset is not a band's job
        const Fit z = fit(flat, rate, 8, 6.0, 12.0);
        CHECK(z.rc == N60_EQFIT_OK && z.count == 0, "flat curve: %u bands", z.count);

        // The range is honoured: a range that holds only the 63 Hz peak never places a band above it.
        const Fit narrow = fit(room, rate, 4, 6.0, 12.0, 30, 100);
        CHECK(narrow.rc == N60_EQFIT_OK && narrow.count >= 1, "narrow range fit");
        for (uint32_t i = 0; i < narrow.count; ++i) CHECK(narrow.bands[i].frequency_hz <= 100.0 + 1e-6, "narrow band at %.1f", narrow.bands[i].frequency_hz);
    }

    // Refusals.
    {
        Room room = makeRoom(48000);
        Room bad = room;
        bad.measured[10] = NAN;
        CHECK(fit(bad, 48000, 4, 6, 12).rc == N60_EQFIT_ERR_DATA, "non-finite refused");
        bad = room;
        bad.hz[5] = bad.hz[4];
        CHECK(fit(bad, 48000, 4, 6, 12).rc == N60_EQFIT_ERR_DATA, "non-rising refused");
        CHECK(fit(room, 48000, 0, 6, 12).rc == N60_EQFIT_ERR_ARGUMENT, "zero bands refused");
        CHECK(fit(room, 48000, 4, 40, 12).rc == N60_EQFIT_ERR_ARGUMENT, "boost over 24 refused");
        CHECK(fit(room, 48000, 4, 6, 12, 400, 410).rc == N60_EQFIT_ERR_DATA, "tiny range refused");
        CHECK(fit(room, 1000, 4, 6, 12).rc == N60_EQFIT_ERR_ARGUMENT, "bad rate refused");
        n60_eqfit_result r{};
        CHECK(n60_eqfit_fit(nullptr, &r) == N60_EQFIT_ERR_ARGUMENT, "null problem");
    }
    if (failures == 0) std::printf("eqfit ok\n");
    return failures ? 1 : 0;
}
