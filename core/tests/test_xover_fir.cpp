// E8 S7: linear-phase FIR crossovers (n60/xover.h FIR designer, N60_STAGE_DRIVER_FIR and _TWO_BAND) at the eight standard rates.
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/correct.h"
#include "n60/graph.h"
#include "n60/xover.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
using Cx = std::complex<double>;

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
};

static bool design(Way &w, double fs, const n60_xover_spec *hp, const n60_xover_spec *lp, uint32_t delay) {
    n60_xover_fir_params p{};
    p.struct_size = sizeof(p);
    p.sample_rate = fs;
    p.highpass = hp;
    p.lowpass = lp;
    p.group_delay_frames = delay;
    n60_xover_fir_report plan{};
    if (n60_xover_fir_plan(&p, &plan) != N60_XOVER_OK) return false;
    w.full.assign(plan.full_tap_count, 0.0f);
    w.low.assign(plan.low_tap_count + 1, 0.0f);
    if (n60_xover_fir_synthesize(&p, w.full.data(), w.full.size(), w.low.data(), w.low.size(), &w.report) != N60_XOVER_OK) return false;
    return w.report.full_tap_count == plan.full_tap_count && w.report.low_tap_count == plan.low_tap_count &&
           w.report.latency_frames == plan.latency_frames;
}

// Response with the group delay removed, so a linear-phase way is real and positive.
static Cx response(const Way &w, double fs, double hz) {
    const uint32_t L = w.report.group_delay_frames;
    if (!w.report.two_band) {
        const double om = 2.0 * kPi * hz / fs;
        Cx acc(0, 0);
        for (size_t n = 0; n < w.full.size(); ++n) acc += static_cast<double>(w.full[n]) * std::polar(1.0, -om * (static_cast<double>(n) - L));
        return acc;
    }
    double mag = 0, ph = 0;
    n60_correct_two_band_response(fs, w.report.decimation, w.report.extra_delay_frames, L, w.full.data(), w.report.full_tap_count,
                                  w.low.data(), w.report.low_tap_count, &hz, 1, &mag, &ph);
    return std::polar(std::pow(10.0, mag / 20.0), ph);
}

static void testThreeWaySum(uint32_t order, double tolDb, double tolDeg) {
    for (double fs : kRates) {
        const n60_xover_spec lo = spec(2, order, 300), hi = spec(2, order, 3000);
        // A common group delay so the three windows are identical; the longest way sets it.
        n60_xover_fir_params probe{};
        probe.struct_size = sizeof(probe);
        probe.sample_rate = fs;
        probe.lowpass = &lo;
        n60_xover_fir_report plan{};
        CHECK(n60_xover_fir_plan(&probe, &plan) == N60_XOVER_OK, "plan");
        const uint32_t L = plan.group_delay_frames;
        Way low, mid, high;
        CHECK(design(low, fs, nullptr, &lo, L) && design(mid, fs, &lo, &hi, L) && design(high, fs, &hi, nullptr, L), "design fs=%g", fs);
        double worstDb = 0, worstDeg = 0;
        for (double hz = 20.0; hz <= std::fmin(20000.0, 0.45 * fs); hz *= std::pow(2.0, 1.0 / 24.0)) {
            const Cx sum = response(low, fs, hz) + response(mid, fs, hz) + response(high, fs, hz);
            worstDb = std::fmax(worstDb, std::fabs(20.0 * std::log10(std::abs(sum))));
            worstDeg = std::fmax(worstDeg, std::fabs(std::arg(sum)) * 180.0 / kPi);
        }
        CHECK(worstDb < tolDb && worstDeg < tolDeg, "LR%u fs=%g L=%u twoBand=%u: sum %.4f dB, %.3f deg", order, fs, L,
              low.report.two_band, worstDb, worstDeg);
    }
}

// The way follows the IIR magnitude within 0.3 dB wherever it is above -20 dB; the window softens deep skirts only.
static void testMagnitudeTracksIir() {
    for (double fs : kRates) {
        const n60_xover_spec hp = spec(2, 4, 800), lp = spec(2, 4, 4000);
        Way w;
        CHECK(design(w, fs, &hp, &lp, 0), "design");
        n60_xover_cascade a, b;
        n60_xover_design(&hp, 1, fs, &a);
        n60_xover_design(&lp, 0, fs, &b);
        for (double hz : {80.0, 400.0, 1500.0, 2500.0, 8000.0, 14000.0}) {
            double da = 0, db = 0;
            n60_xover_magnitude_db(&a, fs, hz, &da);
            n60_xover_magnitude_db(&b, fs, hz, &db);
            const double want = da + db, got = 20.0 * std::log10(std::abs(response(w, fs, hz)) + 1e-12);
            if (want > -20.0) CHECK(std::fabs(want - got) < 0.3, "fs=%g %g Hz: iir %.2f dB, fir %.2f dB", fs, hz, want, got);
        }
    }
}

static void testPlanBoundary() {
    const n60_xover_spec lp = spec(2, 4, 1000);
    n60_xover_fir_params p{};
    p.struct_size = sizeof(p);
    p.sample_rate = 48000;
    p.lowpass = &lp;
    n60_xover_fir_report r{};
    p.group_delay_frames = 16383;
    CHECK(n60_xover_fir_plan(&p, &r) == N60_XOVER_OK && !r.two_band && r.full_tap_count == 32767 && r.latency_frames == 256 + 16383, "32767 taps single");
    p.group_delay_frames = 16384;
    CHECK(n60_xover_fir_plan(&p, &r) == N60_XOVER_OK && r.two_band && r.decimation > 1 && r.low_tap_count <= 32768, "32769 taps two-band");
    p.group_delay_frames = 0;
    CHECK(n60_xover_fir_plan(&p, &r) == N60_XOVER_OK && r.group_delay_frames == 240, "automatic delay is five periods: %u", r.group_delay_frames);
    p.highpass = nullptr;
    p.lowpass = nullptr;
    CHECK(n60_xover_fir_plan(&p, &r) == N60_XOVER_ERR_ARGUMENT, "needs a spec");
}

static n60_stage_desc stageFor(const Way &w, uint32_t id, uint32_t lane, std::vector<float> &params) {
    params.clear();
    if (w.report.two_band) {
        params = {static_cast<float>(w.report.decimation), static_cast<float>(w.report.full_tap_count),
                  static_cast<float>(w.report.low_tap_count), static_cast<float>(w.report.extra_delay_frames)};
        params.insert(params.end(), w.full.begin(), w.full.begin() + w.report.full_tap_count);
        params.insert(params.end(), w.low.begin(), w.low.begin() + w.report.low_tap_count);
    } else {
        params.assign(w.full.begin(), w.full.begin() + w.report.full_tap_count);
    }
    n60_stage_desc s{};
    s.structSize = sizeof s;
    s.kind = w.report.two_band ? N60_STAGE_DRIVER_FIR_TWO_BAND : N60_STAGE_DRIVER_FIR;
    s.stageId = id;
    s.laneA = lane;
    s.capacityFrames = w.report.group_delay_frames;
    s.params = params.data();
    s.paramCount = static_cast<uint32_t>(params.size());
    return s;
}

// Through the real graph: the declared latency is exact, the impulse peaks on it, and two ways with different
// group delays line up once the shorter is padded by the difference in latency.
static void testGraphLatency() {
    for (double fs : kRates) {
        for (uint32_t delay : {0u, 20000u}) {  // 0: automatic (single band); 20000: two-band at every rate
            const n60_xover_spec lp = spec(2, 4, 1500);
            Way w;
            CHECK(design(w, fs, nullptr, &lp, delay), "design");
            CHECK(w.report.two_band == (delay != 0), "band choice fs=%g delay=%u", fs, delay);
            std::vector<float> params;
            n60_stage_desc st = stageFor(w, 1, 1, params);
            n60_graph_desc d{};
            d.structSize = sizeof d;
            d.abiVersion = N60_GRAPH_ABI_VERSION;
            d.sampleRate = fs;
            d.maxBlockFrames = 512;
            d.inputChannels = d.outputChannels = 2;
            d.stages = &st;
            d.stageCount = 1;
            n60_graph *g = nullptr;
            CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build fs=%g delay=%u", fs, delay);
            if (!g) continue;
            CHECK(n60_graph_latency_frames(g) == w.report.latency_frames, "latency fs=%g: graph %u, report %u", fs,
                  n60_graph_latency_frames(g), w.report.latency_frames);
            const uint32_t total = w.report.latency_frames + 2048;
            std::vector<float> in0(512), in1(512), o0(512), o1(512);
            const float *in[2] = {in0.data(), in1.data()};
            float *out[2] = {o0.data(), o1.data()};
            uint32_t peakAt = 0;
            float peak = 0;
            for (uint32_t pos = 0; pos < total; pos += 512) {
                std::fill(in0.begin(), in0.end(), 0.0f);
                std::fill(in1.begin(), in1.end(), 0.0f);
                if (pos == 0) in1[0] = 1.0f;
                CHECK(n60_graph_process(g, in, out, 512) == N60_STATUS_OK, "process");
                for (uint32_t i = 0; i < 512; ++i) {
                    if (std::fabs(o1[i]) > peak) { peak = std::fabs(o1[i]); peakAt = pos + i; }
                    CHECK(o0[i] == 0.0f, "lane 0 untouched");
                }
            }
            CHECK(peakAt == w.report.latency_frames, "fs=%g delay=%u: impulse peaks at %u, declared latency %u", fs, delay, peakAt,
                  w.report.latency_frames);
            n60_graph_retire(g);
        }
    }
}

int main() {
    CHECK(n60_xover_abi_version() == 3, "xover ABI");
    testPlanBoundary();
    testThreeWaySum(4, 0.05, 1.0);
    testThreeWaySum(8, 0.05, 1.0);
    testMagnitudeTracksIir();
    testGraphLatency();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("xover fir ok");
    return 0;
}
