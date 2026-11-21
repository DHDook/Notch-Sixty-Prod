// E21 S6a and S6b: behavioural harness for the room-correction FIR design maths (n60/correct.h section 7), through the
// C ABI. References are closed forms written here (log-frequency interpolation, a two-tap FIR's cosine response, the
// raised-cosine kernel on a constant response); nothing is shared with the implementation. FIR cases run at the eight
// standard device rates.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "n60/correct.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

static int32_t parse(const std::string &text, std::vector<double> &f, std::vector<double> &g, uint32_t &line) {
    f.assign(64, 0.0);
    g.assign(64, 0.0);
    uint32_t count = 0;
    line = 0;
    const int32_t status = n60_correct_target_parse(text.data(), text.size(), f.data(), g.data(), 64, &count, &line);
    f.resize(count);
    g.resize(count);
    return status;
}

static void testBuiltIns() {
    double f[8], g[8];
    uint32_t n = 0;
    CHECK(n60_correct_builtin_target(0, f, g, 8, &n) == 0 && n == 2 && f[0] == 20 && f[1] == 20000 && g[0] == 0, "flat");
    CHECK(n60_correct_builtin_target(1, f, g, 8, &n) == 0 && n == 3 && g[0] == 1.0 && g[2] == -2.5, "tilt");
    CHECK(n60_correct_builtin_target(2, f, g, 8, &n) == 0 && n == 5 && g[1] == 4.0 && f[2] == 200, "shelf");
    CHECK(n60_correct_builtin_target(3, f, g, 8, &n) == N60_CORRECT_ERR_ARGUMENT, "index");
    CHECK(n60_correct_builtin_target(2, f, g, 4, &n) == N60_CORRECT_ERR_CAPACITY, "capacity");
}

static void testParser() {
    std::vector<double> f, g;
    uint32_t line;
    // Unsorted, duplicates averaged, comments and blank lines skipped, comma and tab separators.
    CHECK(parse("# header\n1000, 2\n\n100\t-3\n; c\n// c\n* c\n1000 4\n20000 0\n", f, g, line) == 0, "ok");
    CHECK(f.size() == 3 && f[0] == 100 && f[1] == 1000 && f[2] == 20000, "sorted unique");
    CHECK(g[0] == -3 && g[1] == 3 && g[2] == 0, "duplicate mean %g", g.size() > 1 ? g[1] : 0.0);
    CHECK(parse("", f, g, line) == N60_CORRECT_ERR_PARSE_EMPTY, "empty");
    CHECK(parse("# only\n; comments\n", f, g, line) == N60_CORRECT_ERR_PARSE_EMPTY, "comments only");
    CHECK(parse("100 1\n", f, g, line) == N60_CORRECT_ERR_TARGET_POINTS, "one point");
    CHECK(parse("100 1\n100 2\n", f, g, line) == N60_CORRECT_ERR_TARGET_POINTS, "one unique point");
    CHECK(parse("100 1\n200 x\n", f, g, line) == N60_CORRECT_ERR_PARSE_LINE && line == 2, "malformed line %u", line);
    CHECK(parse("100 1 5\n", f, g, line) == N60_CORRECT_ERR_PARSE_LINE && line == 1, "three columns");
    CHECK(parse("100\n", f, g, line) == N60_CORRECT_ERR_PARSE_LINE && line == 1, "one column");
    CHECK(parse("0 1\n", f, g, line) == N60_CORRECT_ERR_PARSE_FREQUENCY && line == 1, "zero Hz");
    CHECK(parse("-5 1\n", f, g, line) == N60_CORRECT_ERR_PARSE_FREQUENCY, "negative Hz");
    CHECK(parse("100 1\ninf 1\n", f, g, line) == N60_CORRECT_ERR_PARSE_FREQUENCY && line == 2, "inf Hz");
    CHECK(parse("100 nan\n", f, g, line) == N60_CORRECT_ERR_PARSE_GAIN, "nan gain");
    // CR and LF each break a line, so a CRLF pair counts two line numbers.
    CHECK(parse("100 1\r\n200 oops\r\n", f, g, line) == N60_CORRECT_ERR_PARSE_LINE && line == 3, "crlf line %u", line);
    CHECK(parse("100 1\r200 2", f, g, line) == 0 && f.size() == 2, "cr only");
    // Capacity.
    double sf[2], sg[2];
    uint32_t n = 0, el = 0;
    const char three[] = "1 0\n2 0\n3 0\n";
    CHECK(n60_correct_target_parse(three, sizeof three - 1, sf, sg, 2, &n, &el) == N60_CORRECT_ERR_CAPACITY, "cap");
    // Exponent and sign forms.
    CHECK(parse("1e2 +1.5\n2e3 -0.5e1\n", f, g, line) == 0 && f[0] == 100 && g[0] == 1.5 && g[1] == -5, "numeric forms");
}

static void testInterpolate() {
    const double f[] = {20, 80, 1000, 20000};
    const double g[] = {4, 4, 0, -2.5};
    const double q[] = {10, 20, 40, 80, 300, 1000, 5000, 20000, 40000};
    double out[9];
    CHECK(n60_correct_target_interpolate(f, g, 4, q, 9, out) == 0, "interp ok");
    for (int i = 0; i < 9; ++i) {
        double want;
        if (q[i] <= 20) want = 4;
        else if (q[i] >= 20000) want = -2.5;
        else {
            int k = 0;
            while (q[i] > f[k + 1]) ++k;
            const double t = (std::log(q[i]) - std::log(f[k])) / (std::log(f[k + 1]) - std::log(f[k]));
            want = g[k] + t * (g[k + 1] - g[k]);
        }
        CHECK(std::fabs(out[i] - want) < 1e-12, "interp %d: %g vs %g", i, out[i], want);
    }
    const double bad[] = {20, 20, 100};
    CHECK(n60_correct_target_interpolate(bad, g, 3, q, 1, out) == N60_CORRECT_ERR_TARGET_CURVE, "non-increasing");
    CHECK(n60_correct_target_interpolate(f, g, 1, q, 1, out) == N60_CORRECT_ERR_TARGET_POINTS, "one point");
    const double zero[] = {0.0};
    CHECK(n60_correct_target_interpolate(f, g, 4, zero, 1, out) == N60_CORRECT_ERR_TARGET_CURVE, "zero query");
}

static std::vector<double> logGrid(double lo, double hi, int n) {
    std::vector<double> f(n);
    for (int i = 0; i < n; ++i) f[i] = lo * std::pow(hi / lo, static_cast<double>(i) / (n - 1));
    return f;
}

static void testSmooth() {
    const std::vector<double> f = logGrid(20, 20000, 200);
    std::vector<double> flat(200, 3.5), out(200), ramp(200);
    CHECK(n60_correct_magnitude_smooth(f.data(), flat.data(), 200, 1.0 / 3.0, out.data()) == 0, "smooth ok");
    for (int i = 0; i < 200; ++i) CHECK(std::fabs(out[i] - 3.5) < 1e-12, "constant preserved %d", i);
    for (int i = 0; i < 200; ++i) ramp[i] = std::sin(i * 0.7);
    CHECK(n60_correct_magnitude_smooth(f.data(), ramp.data(), 200, 0.0, out.data()) == 0 && out == ramp, "zero copies");
    // A single spike is lowered and spread symmetrically about it; mean-bounded.
    std::vector<double> spike(200, 0.0);
    spike[100] = 12.0;
    CHECK(n60_correct_magnitude_smooth(f.data(), spike.data(), 200, 0.5, out.data()) == 0, "spike");
    CHECK(out[100] < 12.0 && out[100] > 0.0 && out[101] > 0.0 && out[99] > 0.0, "spike spread");
    CHECK(n60_correct_magnitude_smooth(f.data(), flat.data(), 200, -1.0, out.data()) == N60_CORRECT_ERR_SMOOTHING, "neg");
    CHECK(n60_correct_magnitude_smooth(f.data(), flat.data(), 0, 1.0, out.data()) == N60_CORRECT_ERR_RESPONSE, "empty");
}

struct Preview {
    std::vector<double> t, sl, sr, cl, cr;
    n60_correct_preview_out out;
    explicit Preview(size_t n) : t(n), sl(n), sr(n), cl(n), cr(n) {
        std::memset(&out, 0, sizeof out);
        out.target_db = t.data();
        out.smoothed_left_db = sl.data();
        out.smoothed_right_db = sr.data();
        out.left_correction_db = cl.data();
        out.right_correction_db = cr.data();
    }
};

static n60_correct_preview_params baseParams() {
    n60_correct_preview_params p;
    std::memset(&p, 0, sizeof p);
    p.struct_size = sizeof p;
    p.tap_count = 8192;
    p.tap_limit = 262144;
    p.correction_low_hz = 30;
    p.correction_high_hz = 10000;
    p.smoothing_octaves = 0.0;
    p.maximum_boost_db = 6;
    p.maximum_cut_db = 12;
    return p;
}

static void testPreview() {
    const int n = 300;
    const std::vector<double> f = logGrid(20, 20000, n);
    const double tf[] = {20, 20000};
    const double tg[] = {0, 0};
    std::vector<double> left(n), right(n);
    for (int i = 0; i < n; ++i) {
        left[i] = (f[i] > 200 && f[i] < 400) ? 5.0 : 0.0;   // a 5 dB peak: cut by 5
        right[i] = (f[i] > 200 && f[i] < 400) ? -20.0 : 0.0;  // a deep dip: boost limited
    }
    n60_correct_preview_params p = baseParams();
    Preview r(n);
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == 0, "preview ok");
    CHECK(r.out.effective_low_hz == 30 && r.out.effective_high_hz == 10000, "effective range");
    int midIndex = 0;
    for (int i = 0; i < n; ++i) if (std::fabs(f[i] - 300) < std::fabs(f[midIndex] - 300)) midIndex = i;
    CHECK(std::fabs(r.cl[midIndex] + 5.0) < 1e-9, "left cut %g", r.cl[midIndex]);
    CHECK(std::fabs(r.cr[midIndex] - 6.0) < 1e-9 || r.cr[midIndex] <= 6.0, "right boost limited %g", r.cr[midIndex]);
    // No correction outside the range, zero at and beyond the edges, bounded everywhere.
    for (int i = 0; i < n; ++i) {
        if (f[i] < 30 || f[i] > 10000) CHECK(r.cl[i] == 0.0 && r.cr[i] == 0.0, "outside range %d", i);
        CHECK(r.cl[i] >= -12.0 - 1e-12 && r.cl[i] <= 6.0 + 1e-12, "bounds");
        CHECK(r.t[i] == 0.0, "flat target");
    }
    CHECK(r.out.maximum_positive_db >= 0.0 && r.out.maximum_positive_db <= 6.0 + 1e-12, "max positive");
    CHECK(r.out.estimated_headroom_db == n60_correct_recommended_headroom_db(r.out.maximum_positive_db), "headroom");
    // Narrow-null protection: smoothing 1 octave over a deep one-bin dip reduces the permitted boost.
    std::vector<double> dip(n, 0.0);
    dip[150] = -20.0;
    p.smoothing_octaves = 1.0;
    Preview q(n);
    CHECK(n60_correct_preview(&p, f.data(), n, dip.data(), f.data(), dip.data(), tf, tg, 2, &q.out) == 0, "dip preview");
    CHECK(q.cl[150] < 6.0 * 0.5, "null protected %g", q.cl[150]);
    // Errors, in the order the designer checks them.
    p = baseParams();
    std::vector<double> bad = left;
    bad[5] = NAN;
    CHECK(n60_correct_preview(&p, f.data(), n, bad.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_RESPONSE, "resp");
    const double tbad[] = {20, 10};
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tbad, tg, 2, &r.out) == N60_CORRECT_ERR_TARGET_CURVE, "tgt");
    p.correction_high_hz = 20;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_RANGE, "range");
    p = baseParams(); p.smoothing_octaves = -1;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_SMOOTHING, "smooth");
    p = baseParams(); p.maximum_boost_db = -1;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_BOOST, "boost");
    p = baseParams(); p.maximum_cut_db = NAN;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_CUT, "cut");
    p = baseParams(); p.tap_count = p.tap_limit + 1;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_TAP_COUNT, "taps");
    p = baseParams(); p.has_usable_low = 1; p.usable_low_hz = 500; p.has_usable_high = 1; p.usable_high_hz = 400;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_USABLE, "usable");
    p = baseParams(); p.has_usable_low = 1; p.usable_low_hz = 15000; p.has_usable_high = 1; p.usable_high_hz = 19000;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_NO_RANGE, "no range");
    // Usable range clamps the effective range.
    p = baseParams(); p.has_usable_low = 1; p.usable_low_hz = 60; p.has_usable_high = 1; p.usable_high_hz = 5000;
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f.data(), right.data(), tf, tg, 2, &r.out) == 0 &&
          r.out.effective_low_hz == 60 && r.out.effective_high_hz == 5000, "usable clamps");
    // Mismatched left and right grids.
    std::vector<double> f2 = f;
    f2[10] *= 1.001;
    p = baseParams();
    CHECK(n60_correct_preview(&p, f.data(), n, left.data(), f2.data(), right.data(), tf, tg, 2, &r.out) == N60_CORRECT_ERR_GRID, "grid");
}

static void testHeadroomAndTransform() {
    CHECK(n60_correct_recommended_headroom_db(0.0) == 0.0 && n60_correct_recommended_headroom_db(-3.0) == 0.0, "none");
    CHECK(n60_correct_recommended_headroom_db(0.1) == 0.5, "0.1 -> 0.5");
    CHECK(n60_correct_recommended_headroom_db(0.25) == 0.5, "0.25 -> 0.5");
    CHECK(n60_correct_recommended_headroom_db(0.3) == 1.0, "0.3 -> 1.0");
    CHECK(n60_correct_recommended_headroom_db(6.0) == 6.5, "6 -> 6.5");
    uint32_t size = 0;
    CHECK(n60_correct_fir_transform_size(1024, 262144, &size) == 0 && size == 16384, "small %u", size);
    CHECK(n60_correct_fir_transform_size(8192, 262144, &size) == 0 && size == 65536, "8192 -> %u", size);
    CHECK(n60_correct_fir_transform_size(65536, 262144, &size) == 0 && size == 524288, "65536 -> %u", size);
    CHECK(n60_correct_fir_transform_size(262144, 262144, &size) == 0 && size == 1048576, "max taps -> %u", size);
    CHECK(n60_correct_fir_transform_size(0, 262144, &size) == N60_CORRECT_ERR_TAP_COUNT, "zero");
    CHECK(n60_correct_fir_transform_size(262145, 262144, &size) == N60_CORRECT_ERR_TAP_COUNT, "too many");
    const float taps[3] = {1.0f, -0.5f, 0.25f};
    float out[3];
    CHECK(n60_correct_scale_taps(taps, 3, 6.0, out) == 0, "scale");
    const double s = std::pow(10.0, -6.0 / 20.0);
    for (int i = 0; i < 3; ++i) CHECK(out[i] == static_cast<float>(static_cast<double>(taps[i]) * s), "scaled %d", i);
    CHECK(n60_correct_scale_taps(taps, 3, 0.0, out) == 0 && out[0] == 1.0f, "unity");
    CHECK(n60_correct_scale_taps(taps, 3, -1.0, out) == N60_CORRECT_ERR_HEADROOM, "negative headroom");
    CHECK(n60_correct_scale_taps(taps, 3, NAN, out) == N60_CORRECT_ERR_HEADROOM, "nan headroom");
}

static void testFirResponse() {
    for (const double rate : kRates) {
        // Two-tap FIR [1, 1]: |H| = 2 |cos(pi f / rate)|. Frequencies on transform bins are exact; others are linear
        // in bin magnitude, so check the bins exactly and a mid-bin frequency by the interpolation rule.
        const uint32_t size = 16384;
        std::vector<float> taps(1024, 0.0f);
        taps[0] = 1.0f;
        taps[1] = 1.0f;
        std::vector<double> freqs, want;
        for (uint32_t k : {8u, 100u, 1000u, 4000u, 8000u}) {
            freqs.push_back(k * rate / size);
            want.push_back(20.0 * std::log10(std::max(2.0 * std::fabs(std::cos(kPi * k / size)), 1e-12)));
        }
        std::vector<double> db(freqs.size());
        double maxPos = -1;
        CHECK(n60_correct_fir_response(taps.data(), 1024, rate, size, freqs.data(), static_cast<uint32_t>(freqs.size()),
                                       db.data(), &maxPos) == 0, "fir ok %.0f", rate);
        for (size_t i = 0; i < db.size(); ++i) {
            CHECK(std::fabs(db[i] - want[i]) < 1e-9, "rate %.0f bin %zu: %g vs %g", rate, i, db[i], want[i]);
        }
        CHECK(std::fabs(maxPos - 20.0 * std::log10(2.0)) < 1e-9, "max positive %g", maxPos);
        // Mid-bin: linear in magnitude between neighbours.
        const double mid = (1000.5) * rate / size;
        double dbMid;
        double mp;
        CHECK(n60_correct_fir_response(taps.data(), 1024, rate, size, &mid, 1, &dbMid, &mp) == 0, "mid");
        const double m0 = 2.0 * std::fabs(std::cos(kPi * 1000.0 / size));
        const double m1 = 2.0 * std::fabs(std::cos(kPi * 1001.0 / size));
        CHECK(std::fabs(dbMid - 20.0 * std::log10(0.5 * (m0 + m1))) < 1e-9, "mid-bin interpolation %g", dbMid);
        // An attenuating FIR has no positive gain; a pure delay is flat 0 dB.
        std::vector<float> half(256, 0.0f), delay(256, 0.0f);
        half[3] = 0.5f;
        delay[40] = 1.0f;
        const double probe = 1000.0 * rate / size;
        CHECK(n60_correct_fir_response(half.data(), 256, rate, size, &probe, 1, &dbMid, &mp) == 0 &&
              std::fabs(dbMid + 20.0 * std::log10(2.0)) < 1e-9 && mp == 0.0, "half gain mp=%g", mp);
        CHECK(n60_correct_fir_response(delay.data(), 256, rate, size, &probe, 1, &dbMid, &mp) == 0 &&
              std::fabs(dbMid) < 1e-9 && std::fabs(mp) < 1e-9, "delay flat");
        // Frequencies above Nyquist clamp to the last bin rather than reading past it.
        const double above = rate * 0.75;
        CHECK(n60_correct_fir_response(delay.data(), 256, rate, size, &above, 1, &dbMid, &mp) == 0, "above nyquist");
    }
    std::vector<float> nan(8, 0.0f);
    nan[2] = NAN;
    double db, mp;
    const double fq = 1000;
    CHECK(n60_correct_fir_response(nan.data(), 8, 48000, 16384, &fq, 1, &db, &mp) == N60_CORRECT_ERR_NONFINITE, "nan taps");
    CHECK(n60_correct_fir_response(nan.data(), 8, 48000, 1000, &fq, 1, &db, &mp) == N60_CORRECT_ERR_ARGUMENT, "not pow2");
}

int main() {
    testBuiltIns();
    testParser();
    testInterpolate();
    testSmooth();
    testPreview();
    testHeadroomAndTransform();
    testFirResponse();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("room design: ok");
    return 0;
}
