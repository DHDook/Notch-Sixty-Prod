// E21 S10a: behavioural harness for the ANC design maths (n60/anc_design.h) through the C ABI: virtual seat designer, rank-one
// bass conditioning, causal FIR compiler, HAL clock analysis, upstream lead estimator and assessment, at the eight standard
// rates. References are closed forms written here; nothing is shared with the implementation. Parity with the Swift maths is the
// XCTest QuietZoneDesignCoreParityTests. Nothing here arms or enables a live ANC path.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/anc_design.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static n60_anc_complex z(double re, double im = 0) { return n60_anc_complex{re, im}; }

static n60_anc_seat_band band(double f, double h = 0.02, double leak = 0.2, double coherence = 0.98) {
    n60_anc_seat_band b{};
    b.frequencyHz = f;
    b.sourceToReference = z(1);
    b.sourceToListener = z(h);
    b.leftSecondaryAtListener = z(1);
    b.rightSecondaryAtListener = z(1);
    b.leftLeakageAtReference = z(leak);
    b.rightLeakageAtReference = z(leak);
    b.measuredCoherence = coherence;
    return b;
}

static n60_anc_seat_options options() {
    n60_anc_seat_options o{};
    o.structSize = sizeof o;
    o.reserveSeconds = 0.006;
    o.minimumFrequencyHz = 25;
    o.maximumFrequencyHz = 150;
    o.maximumPerSourceTonePeakDBFS = -24;
    o.maximumAggregateSourcePeakDBFS = -18;
    o.bassConditioning = 0;
    o.pathChangeToleranceDB = 6;
    return o;
}

static void testLimitsAndBass() {
    n60_anc_seat_limits lim{};
    n60_anc_seat_limits_get(&lim);
    CHECK(lim.minimumCoherence == 0.85 && lim.maximumLeakageFraction == 0.10 && lim.minimumModeledReductionDB == 0.25, "limits");
    CHECK(lim.firMinimumSampleRate == 1000 && lim.firMaximumSampleRate == 768000, "fir rate range");
    CHECK(std::fabs(lim.firPeakGainLimit - std::pow(10.0, -24.0 / 20)) < 1e-12, "fir gain limit is -24 dB");
    n60_anc_clock_limits cl{};
    n60_anc_clock_limits_get(&cl);
    CHECK(cl.minimumObservations == 8 && cl.minimumObservationDuration == 2.0 && cl.maximumRelativeDriftPPM == 100.0, "clock limits");
    CHECK(n60_anc_design_abi_version() == N60_ANC_DESIGN_ABI_VERSION, "abi");

    // Identity plant: 0 dB, free. Rank one: infinite, common mode. Closed form for a diagonal plant diag(1, 0.1): 20 dB.
    double scale = 0;
    double id = n60_anc_bass_condition_db(z(1), z(0), z(0), z(1));
    CHECK(std::fabs(id) < 1e-9 && n60_anc_bass_mode(id, &scale) == N60_ANC_BASS_FREE && scale == 1.0, "identity plant is free");
    double rank1 = n60_anc_bass_condition_db(z(1), z(0.5), z(0.2), z(0.1));
    CHECK(std::isinf(rank1) && n60_anc_bass_mode(rank1, &scale) == N60_ANC_BASS_COMMON, "rank one is common mode");
    double diag = n60_anc_bass_condition_db(z(1), z(0), z(0), z(0.1));
    CHECK(std::fabs(diag - 20.0) < 1e-9, "diag(1, 0.1) is 20 dB, got %g", diag);
    CHECK(n60_anc_bass_mode(15.0, &scale) == N60_ANC_BASS_TIKHONOV && std::fabs(scale - 5.5) < 1e-12, "15 dB -> lambda scale 5.5");
    CHECK(n60_anc_bass_mode(10.0, &scale) == N60_ANC_BASS_FREE, "10 dB is free");
    CHECK(n60_anc_bass_mode(NAN, &scale) == N60_ANC_BASS_COMMON && n60_anc_bass_mode(-1, &scale) == N60_ANC_BASS_COMMON,
          "non-finite and negative read as rank one");
}

static void testSeat() {
    // One band: h = 0.02, Sl = Sr = 1. Authority 2, lambda 0.07: each weight is -h / 2.07; the residual is h + 2 w.
    n60_anc_seat_band b = band(65);
    n60_anc_seat_options o = options();
    n60_anc_seat_band_result r{};
    double worst = 0, coherence = 0;
    CHECK(n60_anc_virtual_seat_design(&b, 1, &o, &r, &worst, &coherence) == 0, "design ok");
    const double w = -0.02 / 2.07;
    CHECK(std::fabs(r.leftFilter.re - w) < 1e-15 && std::fabs(r.rightFilter.re - w) < 1e-15 && r.leftFilter.im == 0, "weights");
    const double residual = 0.02 + 2 * w;
    CHECK(std::fabs(r.predictedResidual.re - residual) < 1e-15, "residual");
    CHECK(std::fabs(r.modeledReductionDB - 20 * std::log10(0.02 / residual)) < 1e-9, "reduction dB");
    CHECK(std::fabs(r.predictedReferenceLeakageFraction - std::fabs(0.2 * 2 * w)) < 1e-15, "leakage fraction");
    CHECK(worst == r.modeledReductionDB && coherence == 0.98, "summary");

    // The joint cap: a large disturbance is scaled to the per-source peak (-24 dBFS) across the grid.
    n60_anc_seat_band big = band(65, 0.5);
    CHECK(n60_anc_virtual_seat_design(&big, 1, &o, &r, &worst, &coherence) == 0, "cap design ok");
    CHECK(std::fabs(std::hypot(r.leftFilter.re, r.leftFilter.im) - std::pow(10.0, -24.0 / 20)) < 1e-12, "capped at -24 dBFS");

    // Refusals.
    n60_anc_seat_band bad = band(65, 0.02, 0.2, 0.5);
    CHECK(n60_anc_virtual_seat_design(&bad, 1, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_COHERENCE, "coherence");
    bad = band(65, 0.02, 0.2, NAN);
    CHECK(n60_anc_virtual_seat_design(&bad, 1, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_MODEL, "nan coherence is a model error");
    bad = band(10);
    CHECK(n60_anc_virtual_seat_design(&bad, 1, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_MODEL, "below the band");
    bad = band(65);
    bad.leftSecondaryAtListener = z(0);
    bad.rightSecondaryAtListener = z(0);
    CHECK(n60_anc_virtual_seat_design(&bad, 1, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_AUTHORITY, "authority");
    bad = band(65, 0.02, 10.0);
    CHECK(n60_anc_virtual_seat_design(&bad, 1, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_LEAKAGE, "leakage");
    n60_anc_seat_options quiet = o;
    quiet.maximumPerSourceTonePeakDBFS = -48;
    quiet.maximumAggregateSourcePeakDBFS = -36;
    CHECK(n60_anc_virtual_seat_design(&big, 1, &quiet, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_BENEFIT, "benefit below 0.25 dB");
    n60_anc_seat_options noBudget = o;
    noBudget.reserveSeconds = NAN;
    CHECK(n60_anc_virtual_seat_design(&b, 1, &noBudget, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_BUDGET, "budget nan");
    noBudget.reserveSeconds = 0.0019;
    CHECK(n60_anc_virtual_seat_design(&b, 1, &noBudget, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_BUDGET, "budget under 2 ms");
    CHECK(n60_anc_virtual_seat_design(&b, 0, &o, &r, nullptr, nullptr) == N60_ANC_SEAT_ERR_MEASUREMENTS, "empty");
    std::vector<n60_anc_seat_band> many(65);
    std::vector<n60_anc_seat_band_result> manyOut(65);
    for (size_t i = 0; i < many.size(); ++i) many[i] = band(25 + i * 1.9);
    CHECK(n60_anc_virtual_seat_design(many.data(), 65, &o, manyOut.data(), nullptr, nullptr) == N60_ANC_SEAT_ERR_MEASUREMENTS, "65 bands");
    CHECK(n60_anc_virtual_seat_design(many.data(), 64, &o, manyOut.data(), nullptr, nullptr) == 0, "64 bands");
    n60_anc_seat_band dup[2] = {band(65), band(65.005)};
    CHECK(n60_anc_virtual_seat_design(dup, 2, &o, manyOut.data(), nullptr, nullptr) == N60_ANC_SEAT_ERR_MODEL, "duplicate frequency");

    // Unordered input comes back ascending.
    n60_anc_seat_band two[2] = {band(100), band(40)};
    n60_anc_seat_band_result two_out[2];
    CHECK(n60_anc_virtual_seat_design(two, 2, &o, two_out, nullptr, nullptr) == 0 && two_out[0].frequencyHz == 40 &&
              two_out[1].frequencyHz == 100,
          "ascending output");
}

static n60_anc_seat_band rankOneBand(double f) {
    n60_anc_seat_band b = band(f);
    b.rightSecondaryAtListener = z(0.5);
    b.leftLeakageAtReference = z(0.2);
    b.rightLeakageAtReference = z(0.1);  // rows proportional: rank one (a shared sub)
    return b;
}

static void testBassConditioning() {
    n60_anc_seat_band b = rankOneBand(65);
    n60_anc_seat_options o = options();
    n60_anc_seat_band_result r{};
    CHECK(n60_anc_virtual_seat_design(&b, 1, &o, &r, nullptr, nullptr) == 0, "free design");
    CHECK(std::fabs(r.leftFilter.re - r.rightFilter.re) > 1e-6, "free solve drives L and R differently");
    o.bassConditioning = 1;
    CHECK(n60_anc_virtual_seat_design(&b, 1, &o, &r, nullptr, nullptr) == 0, "conditioned design");
    CHECK(r.leftFilter.re == r.rightFilter.re && r.leftFilter.im == r.rightFilter.im, "rank one plant: common mode");
    // Closed form: weight = -(conj(Sl + Sr) h) / (P + max(0.035 P, 1e-9)), P = |Sl + Sr|^2 = 2.25.
    const double expected = -(1.5 * 0.02) / (2.25 + 0.035 * 2.25);
    CHECK(std::fabs(r.leftFilter.re - expected) < 1e-15, "common-mode weight");
    // A well-conditioned plant is untouched by the switch.
    n60_anc_seat_band g = band(65);
    g.rightSecondaryAtListener = z(0.5, 0.3);
    g.leftLeakageAtReference = z(0.1);
    g.rightLeakageAtReference = z(0.15, -0.1);
    n60_anc_seat_band_result a{}, c{};
    o.bassConditioning = 0;
    CHECK(n60_anc_virtual_seat_design(&g, 1, &o, &a, nullptr, nullptr) == 0, "unconditioned");
    o.bassConditioning = 1;
    CHECK(n60_anc_virtual_seat_design(&g, 1, &o, &c, nullptr, nullptr) == 0, "conditioned");
    const double db = n60_anc_bass_condition_db(g.leftSecondaryAtListener, g.rightSecondaryAtListener, g.leftLeakageAtReference,
                                                g.rightLeakageAtReference);
    double scale;
    if (n60_anc_bass_mode(db, &scale) == N60_ANC_BASS_FREE)
        CHECK(a.leftFilter.re == c.leftFilter.re && a.rightFilter.im == c.rightFilter.im, "free band bit-identical");
}

static double firResponseMag(const float *taps, int n, double f, double rate, double *im) {
    double re = 0, i2 = 0;
    for (int k = 0; k < n; ++k) {
        re += taps[k] * std::cos(2 * 3.14159265358979323846 * f * k / rate);
        i2 -= taps[k] * std::sin(2 * 3.14159265358979323846 * f * k / rate);
    }
    if (im) *im = i2;
    return re;
}

static void testFir() {
    n60_anc_seat_band b[3] = {band(40), band(65), band(100)};
    n60_anc_seat_options o = options();
    n60_anc_seat_band_result res[3];
    CHECK(n60_anc_virtual_seat_design(b, 3, &o, res, nullptr, nullptr) == 0, "design for fir");
    for (double rate : kRates) {
        n60_anc_fir_options fo{};
        fo.structSize = sizeof fo;
        fo.reserveSeconds = 0.006;
        fo.sampleRate = rate;
        fo.tapCount = 32;
        fo.pathChangeToleranceDB = 6;
        n60_anc_fir_result fr{};
        int32_t e = n60_anc_causal_fir_compile(b, res, 3, &fo, &fr);
        CHECK(e == 0, "fir compile at %g: %d", rate, e);
        if (e != 0) continue;
        CHECK(fr.tapCount == 32 && fr.maximumRelativeFitError <= 0.18, "fit error %g", fr.maximumRelativeFitError);
        CHECK(fr.worstPredictedReductionDB >= 0.25, "reduction %g", fr.worstPredictedReductionDB);
        // Independent evaluation: the taps' response sits near the designed complex weight.
        for (int i = 0; i < 3; ++i) {
            double im;
            double re = firResponseMag(fr.leftTaps, 32, b[i].frequencyHz, rate, &im);
            CHECK(std::hypot(re - res[i].leftFilter.re, im - res[i].leftFilter.im) <= 0.18 * 2 * std::fabs(res[i].leftFilter.re),
                  "response at %g Hz, %g", b[i].frequencyHz, rate);
        }
        double sum = 0;
        for (int k = 0; k < 32; ++k) sum += std::fabs(fr.leftTaps[k]);
        CHECK(sum <= 0.0631, "gain bound %g", sum);
    }

    // Refusals and ranges.
    n60_anc_fir_options fo{};
    fo.structSize = sizeof fo;
    fo.reserveSeconds = 0.006;
    fo.sampleRate = 48000;
    fo.tapCount = 32;
    fo.pathChangeToleranceDB = 6;
    n60_anc_fir_result fr{};
    n60_anc_fir_options bad = fo;
    bad.sampleRate = 999;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == N60_ANC_FIR_ERR_CLOCK, "rate below 1 kHz");
    bad = fo; bad.sampleRate = 768001;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == N60_ANC_FIR_ERR_CLOCK, "rate above 768 kHz");
    bad = fo; bad.tapCount = 0;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == N60_ANC_FIR_ERR_CLOCK, "zero taps");
    bad = fo; bad.tapCount = 65;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == N60_ANC_FIR_ERR_CLOCK, "65 taps");
    bad = fo; bad.reserveSeconds = 0.001;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == N60_ANC_FIR_ERR_CLOCK, "reserve");
    n60_anc_seat_band_result skew[3] = {res[0], res[1], res[2]};
    skew[1].frequencyHz = 66;
    CHECK(n60_anc_causal_fir_compile(b, skew, 3, &fo, &fr) == N60_ANC_FIR_ERR_MODEL, "frequency mismatch");
    // A 4 kHz refit (the shadow's adaptation rate) works.
    bad = fo; bad.sampleRate = 4000;
    CHECK(n60_anc_causal_fir_compile(b, res, 3, &bad, &fr) == 0, "4 kHz refit");

    // Rank-one band with conditioning: the compiled pair is tied (L and R within 5 percent).
    n60_anc_seat_band s[2] = {rankOneBand(50), rankOneBand(80)};
    n60_anc_seat_options oc = options();
    oc.bassConditioning = 1;
    n60_anc_seat_band_result sr[2];
    CHECK(n60_anc_virtual_seat_design(s, 2, &oc, sr, nullptr, nullptr) == 0, "design rank one");
    for (double rate : kRates) {
        n60_anc_fir_options fc = fo;
        fc.sampleRate = rate;
        fc.bassConditioning = 1;
        int32_t e = n60_anc_causal_fir_compile(s, sr, 2, &fc, &fr);
        CHECK(e == 0, "tied compile at %g: %d", rate, e);
        if (e != 0) continue;
        for (int i = 0; i < 2; ++i) {
            double imL, imR;
            double reL = firResponseMag(fr.leftTaps, 32, s[i].frequencyHz, rate, &imL);
            double reR = firResponseMag(fr.rightTaps, 32, s[i].frequencyHz, rate, &imR);
            CHECK(std::hypot(reL - reR, imL - imR) <= 0.05 * (std::hypot(reL, imL) + std::hypot(reR, imR)), "tied L=R at %g", rate);
        }
    }
}

static std::vector<n60_anc_clock_observation> trace(double rate, double ppm, double seconds, double jitterSeconds = 0, double start = 10.0) {
    std::vector<n60_anc_clock_observation> v;
    const double actual = rate * (1 + ppm * 1e-6);
    const int n = 200;
    for (int i = 0; i < n; ++i) {
        const double t = seconds * i / (n - 1);
        const double jitter = (i % 2 ? 1 : -1) * jitterSeconds;
        v.push_back({start + t + jitter, 1000.0 + actual * t});
    }
    return v;
}

static void testClock() {
    for (double rate : kRates) {
        auto in = trace(rate, 20, 4), out = trace(rate, -30, 4);
        n60_anc_clock_health h{};
        int32_t e = n60_anc_hal_clock_analyze(rate, in.data(), (uint32_t)in.size(), out.data(), (uint32_t)out.size(), &h);
        CHECK(e == 0, "clock ok at %g: %d", rate, e);
        if (e != 0) continue;
        CHECK(std::fabs(h.measuredInputRateHz - rate * (1 + 20e-6)) < rate * 1e-9, "input rate");
        CHECK(std::fabs(h.relativeDriftPPM - 50.0) < 1e-3, "relative drift %g", h.relativeDriftPPM);
        CHECK(std::fabs(h.observationDurationSeconds - 4.0) < 1e-9, "duration");
        CHECK(h.worstInputResidualSeconds < 1e-9, "no residual on an exact line");
        auto fast = trace(rate, 150, 4);
        CHECK(n60_anc_hal_clock_analyze(rate, fast.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_DRIFT, "drift 180 ppm");
        auto jit = trace(rate, 0, 4, 0.001);
        CHECK(n60_anc_hal_clock_analyze(rate, jit.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_JITTER, "jitter");
        auto offset = trace(rate, 250, 4);
        auto offset2 = trace(rate, 250, 4);
        CHECK(n60_anc_hal_clock_analyze(rate, offset.data(), 200, offset2.data(), 200, &h) == N60_ANC_CLOCK_ERR_DRIFT,
              "250 ppm off nominal");
    }
    n60_anc_clock_health h{};
    auto in = trace(48000, 0, 4), out = trace(48000, 0, 4);
    CHECK(n60_anc_hal_clock_analyze(5000, in.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_TIMEBASE, "nominal range");
    CHECK(n60_anc_hal_clock_analyze(48000, in.data(), 7, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_INSUFFICIENT, "seven observations");
    auto brief = trace(48000, 0, 1.5);
    CHECK(n60_anc_hal_clock_analyze(48000, brief.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_INSUFFICIENT, "short capture");
    auto back = in;
    back[100].sampleFrame = back[99].sampleFrame;
    CHECK(n60_anc_hal_clock_analyze(48000, back.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_DISCONTINUITY, "stalled clock");
    auto neg = in;
    neg[3].hostTimeSeconds = NAN;
    CHECK(n60_anc_hal_clock_analyze(48000, neg.data(), 200, out.data(), 200, &h) == N60_ANC_CLOCK_ERR_TIMEBASE, "nan time");
    auto later = trace(48000, 0, 4, 0, 30.0);
    CHECK(n60_anc_hal_clock_analyze(48000, in.data(), 200, later.data(), 200, &h) == N60_ANC_CLOCK_ERR_TIMEBASE, "no overlap");
}

static void testUpstream() {
    for (double rate : kRates) {
        n60_anc_upstream_lead_estimator *e = n60_anc_upstream_lead_create(rate);
        CHECK(e != nullptr, "create at %g", rate);
        if (!e) continue;
        const uint32_t dec = n60_anc_upstream_lead_decimation(e);
        CHECK(dec == (uint32_t)std::lround(rate / 4000.0), "decimation %u", dec);
        const double leadSeconds = 0.02;
        const size_t delay = (size_t)std::llround(leadSeconds * rate);
        const size_t frames = (size_t)(rate * 6);
        std::vector<float> ref(frames), err(frames, 0.0f);
        uint64_t s = 0x2545F4914F6CDD1DULL;
        for (size_t i = 0; i < frames; ++i) {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
            ref[i] = (float)((double)(s >> 11) / 9007199254740992.0 - 0.5);
        }
        for (size_t i = delay; i < frames; ++i) err[i] = ref[i - delay];
        CHECK(n60_anc_upstream_lead_estimate(e, nullptr) == 0, "null out");
        const size_t chunk = 4096;
        for (size_t i = 0; i < frames; i += chunk)
            CHECK(n60_anc_upstream_lead_ingest(e, ref.data() + i, err.data() + i, (uint32_t)std::min(chunk, frames - i)) == 0, "ingest");
        const uint32_t count = n60_anc_upstream_lead_decimated_count(e);
        CHECK(count == frames / dec, "decimated count %u vs %zu", count, frames / dec);
        n60_anc_upstream_estimate est{};
        CHECK(n60_anc_upstream_lead_estimate(e, &est) == 1, "estimate at %g", rate);
        const double decimatedRate = rate / dec;
        CHECK(std::fabs(est.leadSeconds - leadSeconds) <= 1.5 / decimatedRate, "lead %g at %g", est.leadSeconds, rate);
        CHECK(est.peakCorrelation > 0.5 && est.peakCorrelation <= 1.0, "correlation %g", est.peakCorrelation);
        CHECK(std::fabs(est.resolutionSeconds - 0.5 / decimatedRate) < 1e-15, "resolution");
        std::vector<float> dr(count), de(count);
        CHECK(n60_anc_upstream_lead_decimated(e, dr.data(), de.data(), count) == count, "copy out");
        n60_anc_upstream_lead_mark_discontinuity(e);
        n60_anc_upstream_lead_destroy(e);
    }
    CHECK(n60_anc_upstream_lead_create(NAN) == nullptr && n60_anc_upstream_lead_create(500) == nullptr, "bad rates");
    // Under 2 s of signal, or silence: no estimate.
    n60_anc_upstream_lead_estimator *e = n60_anc_upstream_lead_create(48000);
    std::vector<float> zeros(48000 * 3, 0.0f);
    n60_anc_upstream_lead_ingest(e, zeros.data(), zeros.data(), (uint32_t)zeros.size());
    n60_anc_upstream_estimate est{};
    CHECK(n60_anc_upstream_lead_estimate(e, &est) == 0, "silence has no energy");
    n60_anc_upstream_lead_destroy(e);
}

static void testAssess() {
    CHECK(std::fabs(n60_anc_upstream_reduction_bound_db(0.9) - 10.0) < 1e-12, "0.9 -> 10 dB");
    CHECK(n60_anc_upstream_reduction_bound_db(1.0) == 30.0 && n60_anc_upstream_reduction_bound_db(0.9999999) == 30.0, "cap 30 dB");
    CHECK(n60_anc_upstream_reduction_bound_db(-1) == 0.0 && n60_anc_upstream_reduction_bound_db(2) == 30.0, "clamped");
    n60_anc_upstream_survey_band survey[4] = {{20, 0.99}, {40, 0.9}, {100, 0.95}, {200, 0.99}};
    n60_anc_upstream_survey_band bands[4];
    double bounds[4];
    n60_anc_upstream_assessment a{};
    // Budget 0.010 + 0.005 + 0.001; lead 0.05 s with 0.5 ms resolution beats it: suitable, mean of the two in-band bounds.
    n60_anc_upstream_estimate good{0.05, 0.8, 0.000125};
    n60_anc_upstream_assess(&good, survey, 4, 0.010, 0.005, 0, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_SUITABLE && a.bandCount == 2, "suitable, %d rows", (int)a.bandCount);
    CHECK(std::fabs(a.budgetSeconds - 0.016) < 1e-15 && std::fabs(a.meanCoherence - 0.925) < 1e-12, "budget and coherence");
    CHECK(a.hasPrediction, "prediction");
    CHECK(std::fabs(a.predictedReductionDB - (bounds[0] + bounds[1]) / 2) < 1e-12, "mean of in-band bounds");
    n60_anc_upstream_estimate soon{0.010, 0.8, 0.000125};
    n60_anc_upstream_assess(&soon, survey, 4, 0.010, 0.005, 0, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_MOVE_FURTHER_OUT && !a.hasPrediction, "too soon");
    n60_anc_upstream_assess(&good, survey, 4, 0.010, 0.005, 0.040, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_MOVE_FURTHER_OUT, "clock offset error eats the margin");
    n60_anc_upstream_survey_band weak[2] = {{40, 0.5}, {100, 0.6}};
    n60_anc_upstream_assess(&good, weak, 2, 0.010, 0.005, 0, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_LOW_COHERENCE, "low coherence");
    n60_anc_upstream_estimate flat{0.05, 0.1, 0.000125};
    n60_anc_upstream_assess(&flat, survey, 4, 0.010, 0.005, 0, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_NO_COMMON_NOISE, "no common noise");
    n60_anc_upstream_assess(nullptr, survey, 4, 0.010, 0.005, 0, bands, bounds, &a);
    CHECK(a.verdict == N60_ANC_UPSTREAM_NO_COMMON_NOISE && a.leadSeconds == 0, "no estimate");
}

int main() {
    testLimitsAndBass();
    testSeat();
    testBassConditioning();
    testFir();
    testClock();
    testUpstream();
    testAssess();
    if (failures == 0) std::printf("anc design ok\n");
    return failures ? 1 : 0;
}
