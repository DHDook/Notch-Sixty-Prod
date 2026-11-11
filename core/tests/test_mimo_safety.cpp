// E19 S5: safety of the MIMO treatment (design note 6) at the eight standard rates. The headroom term of n60/headroom.h
// is checked against the design's own predicted gain and against a rendered, phase-aligned full-scale sweep point through
// the graph stage; the per-source gain budget re-solves or refuses by name; the excursion cap falls 12 dB/octave below the
// source's lower limit. The 10 s thermal window is proved in test_mimo_stage.cpp.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "n60/graph.h"
#include "n60/headroom.h"
#include "n60/measure.h"
#include "n60/mimo.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr double kLn1000 = 6.907755278982137;
constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kSources = 3, kSeats = 2;
using Cx = std::complex<double>;

struct Room {
    double fs = 0;
    std::vector<float> ir[kSources][kSeats];
};

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
        p.base.mode_level_db[m] = 20.0 * std::log10(3.0 * 2.0 * alpha / p.base.direct_gain);
    }
    const double gain[kSources] = {0.4, 1.0, 0.9};
    const double phase[kSources] = {0.0, 0.2, 2.0};
    const double delay[kSources] = {0.0, 0.0011, 0.0023};
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

static void fillProblem(const Room &room, n60_mimo_problem &prob) {
    n60_mimo_defaults(room.fs, kSources, kSeats, &prob);
    uint32_t dec = 0;
    double low = 0;
    n60_mimo_low_rate(room.fs, &dec, &low);
    prob.taps = static_cast<uint32_t>(std::lround(0.5 * low));
    prob.tau_seconds = 0.015;
    for (uint32_t s = 0; s < kSources; ++s) {
        prob.sources[s].support_low_hz = s == 0 ? 30.0 : 20.0;
        prob.sources[s].support_high_hz = s == 0 ? 150.0 : 120.0;
        prob.sources[s].excursion_corner_hz = s == 0 ? 0.0 : 40.0;
        prob.sources[s].effort_limit_db = 0.0;
        for (uint32_t m = 0; m < kSeats; ++m) {
            prob.program_plant[s][m] = room.ir[s][m].data();
            prob.program_count[s][m] = room.ir[s][m].size();
        }
    }
}

struct Result {
    int32_t status = 0;
    n60_mimo_info info{};
    std::vector<float> taps;
};

static Result design(const n60_mimo_problem &prob) {
    Result r;
    r.taps.assign(size_t(prob.source_count) * prob.source_count * prob.taps, 0.0f);
    r.status = n60_mimo_design(&prob, r.taps.data(), r.taps.size(), &r.info);
    return r;
}

// The stage parameter layout of n60/graph.h.
static std::vector<float> stageParams(double fs, const n60_mimo_problem &prob, const std::vector<float> &taps, double arm) {
    uint32_t D = 0;
    double low = 0;
    n60_mimo_low_rate(fs, &D, &low);
    const uint32_t S = prob.source_count, T = prob.taps;
    std::vector<float> p(8 + S + size_t(S) * S * T, 0.0f);
    p[0] = float(D); p[1] = float(T); p[2] = float(S); p[3] = float(std::lround(prob.tau_seconds * fs)); p[4] = float(arm);
    for (uint32_t s = 0; s < S; ++s) p[8 + s] = 10.0f;  // the runtime monitor bound is not under test
    std::memcpy(&p[8 + S], taps.data(), taps.size() * sizeof(float));
    return p;
}

static void testBudgetArithmetic() {
    CHECK(std::fabs(n60_headroom_mimo_budget_db(-1.0, 3.0, 2.5) - (-1.0)) < 1e-12, "budget arithmetic");
    CHECK(std::fabs(n60_headroom_mimo_budget_db(0.0, N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB, 0.0) - 2.5) < 1e-12, "default budget 2.5 dB");
    double pk = 0, hz = 0;
    const float one[12] = {16, 1, 1, 0, 0, 0, 0, 0, 10, 0, 0, 0};
    CHECK(n60_headroom_mimo_term(48000.0, one, 12, 0, &pk, &hz) == N60_HEADROOM_ERR_ARGUMENT, "bad layout refused");
    CHECK(n60_headroom_mimo_term(48000.0, nullptr, 12, 0, &pk, &hz) == N60_HEADROOM_ERR_ARGUMENT, "null refused");
    // One source, a single tap of 0.5 and no extra delay: the row is 0.5 + 1 = +3.52 dB at low frequency.
    float p[8 + 1 + 1] = {16, 1, 1, 0, 0, 0, 0, 0, 10.0f, 0.5f};
    CHECK(n60_headroom_mimo_term(48000.0, p, 10, 0, &pk, &hz) == 0, "term");
    CHECK(std::fabs(pk - 20.0 * std::log10(1.5)) < 0.01, "single tap term %.4f dB", pk);
    CHECK(n60_headroom_mimo_term(48000.0, p, 10, 1, &pk, &hz) == N60_HEADROOM_ERR_ARGUMENT, "source out of range");
}

// Rendered full-scale point: every input carries a tone at f with the phase that makes the row add coherently, through the
// graph stage with the design armed; the steady output amplitude of source s is the predicted sum_t |C_st(f)|.
static double renderedGain(double fs, const n60_mimo_problem &prob, const std::vector<float> &taps, uint32_t source, double hz, int only = -1, double armv = 1.0) {
    uint32_t D = 0;
    double low = 0;
    n60_mimo_low_rate(fs, &D, &low);
    const uint32_t S = prob.source_count, T = prob.taps;
    const double tauSeconds = prob.tau_seconds, A = 0.05;
    std::vector<double> phase(S);
    for (uint32_t t = 0; t < S; ++t) {
        double re = 0, im = 0;
        n60_mimo_tap_response(&taps[(size_t(source) * S + t) * T], T, low, hz, &re, &im);
        Cx c(re, im);
        if (t == source) c += std::polar(1.0, -2.0 * kPi * hz * double(std::lround(tauSeconds * fs)) / fs);
        phase[t] = -std::arg(c);
    }
    std::vector<float> params = stageParams(fs, prob, taps, armv);
    n60_stage_desc st;
    std::memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_MIMO;
    st.stageId = 7;
    st.laneMask = (uint64_t(1) << S) - 1;
    st.params = params.data();
    st.paramCount = uint32_t(params.size());
    n60_graph_desc d;
    std::memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = fs;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = S;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) { CHECK(false, "build"); return 0; }
    const uint32_t block = 512;
    const uint64_t total = uint64_t((3.2 + 0.5 * T / low + 1.0) * fs), measureFrom = total - uint64_t(0.3 * fs);
    std::vector<float> ib(size_t(block) * S), ob(size_t(block) * S);
    double sc = 0, ss = 0, cc = 0, ssn = 0, y_c = 0, y_s = 0;
    for (uint64_t pos = 0; pos < total; pos += block) {
        const uint32_t n = uint32_t(std::min<uint64_t>(block, total - pos));
        const float *ip[8];
        float *op[8];
        for (uint32_t t = 0; t < S; ++t) {
            for (uint32_t i = 0; i < n; ++i) ib[size_t(t) * block + i] = (only >= 0 && int(t) != only) ? 0.0f : float(A * std::cos(2.0 * kPi * hz * double(pos + i) / fs + phase[t]));
            ip[t] = &ib[size_t(t) * block];
            op[t] = &ob[size_t(t) * block];
        }
        n60_graph_process(g, ip, op, n);
        for (uint32_t i = 0; i < n; ++i) {
            const uint64_t k = pos + i;
            if (k < measureFrom) continue;
            const double c = std::cos(2.0 * kPi * hz * double(k) / fs), s = std::sin(2.0 * kPi * hz * double(k) / fs);
            const double y = ob[size_t(source) * block + i];
            cc += c * c; ssn += s * s; sc += c * s; y_c += y * c; y_s += y * s;
        }
    }
    (void)ss;
    if (std::getenv("N60_DEBUG")) {
        n60_mimo_readback rb;
        std::memset(&rb, 0, sizeof rb);
        rb.structSize = sizeof rb;
        n60_graph_read_mimo(g, 7, &rb);
        std::printf("  state %u gain %.3f held %u fault %u reason %u L %u\n", rb.state, rb.armGain, rb.held, rb.faultLatched, rb.faultReason, rb.latencyFrames);
    }
    n60_graph_retire(g);
    const double det = cc * ssn - sc * sc;
    const double a = (y_c * ssn - y_s * sc) / det, b = (y_s * cc - y_c * sc) / det;
    if (std::getenv("N60_DEBUG")) {
        Cx pred(0, 0);
        for (uint32_t t = 0; t < S; ++t) {
            double re = 0, im = 0;
            n60_mimo_tap_response(&taps[(size_t(source) * S + t) * T], T, low, hz, &re, &im);
            Cx c(re, im);
            const Cx dir = std::polar(1.0, -2.0 * kPi * hz * double(std::lround(tauSeconds * fs)) / fs);
            if (t == source) c += dir;
            std::printf("  t=%u |E|=%.4f |C|=%.4f arg(C)=%.3f\n", t, std::abs(Cx(re, im)), std::abs(c), std::arg(c));
            pred += c * std::polar(1.0, phase[t]);
        }
        std::printf("  predicted |sum| %.4f arg %.3f; measured %.4f arg %.3f (minus 10D phase %.3f)\n", std::abs(pred), std::arg(pred), std::hypot(a, b) / A, std::arg(Cx(a, -b)), -2.0 * kPi * hz * 10.0 * D / fs);
    }
    return std::hypot(a, b) / A;
}

static void testPredictedPeaks(double fs) {
    const Room room = buildRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    for (uint32_t s = 0; s < kSources; ++s) prob.sources[s].gain_limit_db = 30.0;
    Result r;
    r.taps.assign(size_t(kSources) * kSources * prob.taps, 0.0f);
    std::vector<float> solved(size_t(kSources) * kSources * 1700 * 2, 0.0f);
    r.status = n60_mimo_design_solved(&prob, r.taps.data(), r.taps.size(), solved.data(), solved.size(), &r.info);
    CHECK(r.status == 0, "fs %.0f design status %d", fs, r.status);
    if (r.status != 0) return;
    n60_mimo_realisation rep;
    CHECK(n60_mimo_realise_check(&prob, r.taps.data(), r.taps.size(), solved.data(), solved.size(), &r.info, &rep) == 0, "check");
    const std::vector<float> params = stageParams(fs, prob, r.taps, 0.0);
    for (uint32_t s = 0; s < kSources; ++s) {
        double pk = 0, hz = 0;
        CHECK(n60_headroom_mimo_term(fs, params.data(), uint32_t(params.size()), s, &pk, &hz) == 0, "term");
        CHECK(std::fabs(pk - rep.gain_peak_db[s]) < 0.05, "fs %.0f source %u: headroom term %.3f dB vs the dense realised check %.3f dB", fs, s, pk, rep.gain_peak_db[s]);
        if (s != 1) continue;  // one sub is rendered per rate; the rate loop and the term cover the others
        if (std::getenv("N60_DEBUG")) {
            std::printf("--- direct only (arm 0): %.4f; only own input armed: %.4f; only input 2 armed %.4f\n", renderedGain(fs, prob, r.taps, s, hz, -1, 0.0), renderedGain(fs, prob, r.taps, s, hz, int(s), 1.0), renderedGain(fs, prob, r.taps, s, hz, 2, 1.0));
        }
        const double rendered = 20.0 * std::log10(std::max(renderedGain(fs, prob, r.taps, s, hz), 1e-9));
        std::printf("fs %.0f source %u: peak %.3f dB at %.2f Hz, rendered %.3f dB\n", fs, s, pk, hz, rendered);
        CHECK(std::fabs(rendered - pk) <= 0.1, "fs %.0f source %u: rendered %.3f dB vs predicted %.3f dB at %.2f Hz", fs, s, rendered, pk, hz);
    }
}

static void testBudget(double fs) {
    const Room room = buildRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    for (uint32_t s = 0; s < kSources; ++s) prob.sources[s].gain_limit_db = 30.0;
    const Result free = design(prob);
    CHECK(free.status == 0, "fs %.0f free design %d", fs, free.status);
    if (free.status != 0) return;
    uint32_t big = 0;
    for (uint32_t s = 1; s < kSources; ++s) if (free.info.peak_gain_db[s] > free.info.peak_gain_db[big]) big = s;
    // A budget 2 dB under what the free design needs: re-solved under it, or refused by name.
    const double need = free.info.peak_gain_db[big];
    prob.sources[big].gain_limit_db = need - 2.0;
    const Result tight = design(prob);
    if (tight.status == 0) {
        CHECK(tight.info.peak_gain_db[big] <= need - 2.0 + 1e-9, "fs %.0f re-solved peak %.3f dB over budget %.3f", fs, tight.info.peak_gain_db[big], need - 2.0);
        CHECK(tight.info.regularisation_steps > 0, "fs %.0f budget met with no re-solve", fs);
    } else {
        CHECK(tight.status == N60_MIMO_ERR_HEADROOM && tight.info.bad_source == int32_t(big), "fs %.0f status %d bad source %d", fs, tight.status, tight.info.bad_source);
    }
    // A budget no treatment can meet (the untreated path is 0 dB): refused by name.
    prob.sources[big].gain_limit_db = -1.0;
    const Result none = design(prob);
    CHECK(none.status == N60_MIMO_ERR_HEADROOM && none.info.bad_source == int32_t(big), "fs %.0f impossible budget: status %d bad source %d", fs, none.status, none.info.bad_source);
    std::printf("fs %.0f: free peak %.2f dB, budget %.2f dB -> %s (steps %u)\n", fs, need, need - 2.0, tight.status == 0 ? "re-solved" : "refused", tight.info.regularisation_steps);
}

// Effort cap: below the corner the row effort sqrt(sum_t |E_st|^2) stays under limit * (f / corner)^2 (12 dB/octave).
static void testExcursionCap(double fs) {
    const Room room = buildRoom(fs);
    n60_mimo_problem prob;
    fillProblem(room, prob);
    for (uint32_t s = 0; s < kSources; ++s) prob.sources[s].gain_limit_db = 30.0;
    const Result r = design(prob);
    CHECK(r.status == 0, "fs %.0f design %d", fs, r.status);
    if (r.status != 0) return;
    uint32_t D = 0;
    double low = 0;
    n60_mimo_low_rate(fs, &D, &low);
    const uint32_t S = kSources, T = prob.taps;
    const double corner = 40.0, limit = 1.0;
    auto effort = [&](uint32_t s, double hz) {
        double e2 = 0;
        for (uint32_t t = 0; t < S; ++t) {
            double re, im;
            n60_mimo_tap_response(&r.taps[(size_t(s) * S + t) * T], T, low, hz, &re, &im);
            e2 += re * re + im * im;
        }
        return std::sqrt(e2);
    };
    const double atCorner = effort(1, corner);
    for (double hz : {20.0, 10.0, 5.0}) {
        const double cap = limit * (hz / corner) * (hz / corner) * std::pow(10.0, 0.35 / 20.0);
        CHECK(effort(1, hz) <= cap, "fs %.0f effort at %.0f Hz is %.4f, above the 12 dB/octave cap %.4f", fs, hz, effort(1, hz), cap);
    }
    CHECK(effort(1, 10.0) <= effort(1, 20.0) * std::pow(10.0, -11.0 / 20.0) || effort(1, 10.0) < 1e-3,
          "fs %.0f effort falls less than 11 dB from 20 to 10 Hz (%.4f -> %.4f)", fs, effort(1, 20.0), effort(1, 10.0));
    CHECK(atCorner <= limit * std::pow(10.0, 0.35 / 20.0), "fs %.0f effort at the corner %.4f over the limit", fs, atCorner);
}

int main() {
    CHECK(n60_headroom_abi_version() == N60_HEADROOM_ABI_VERSION && N60_HEADROOM_ABI_VERSION == 2, "abi");
    testBudgetArithmetic();
    for (double fs : kRates) {
        testPredictedPeaks(fs);
        testBudget(fs);
        testExcursionCap(fs);
    }
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("mimo safety tests passed");
    return 0;
}
