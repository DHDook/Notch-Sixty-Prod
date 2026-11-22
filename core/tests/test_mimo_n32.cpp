// E21 S8 (closes ledger G4): the MIMO designer at the source-count limit (N60_MIMO_MAX_SOURCES = 32) at the eight
// standard rates. Synthetic plants (two decaying modes at 40 and 70 Hz, per-source gain, phase and delay) keep the
// case deterministic and cheap; the 4-source reference room is test_mimo.cpp.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/mimo.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr uint32_t kN = N60_MIMO_MAX_SOURCES, kSeats = 2;

static std::vector<float> plant(double fs, uint32_t s, uint32_t m) {
    const uint64_t len = static_cast<uint64_t>(1.2 * fs);
    std::vector<float> ir(len, 0.0f);
    const uint64_t arrival = static_cast<uint64_t>((0.004 + 0.00013 * s + 0.0002 * m) * fs);
    ir[arrival] = 1.0f;
    const double hz[2] = {40.0, 70.0};
    for (int k = 0; k < 2; ++k) {
        const double alpha = 6.907755278982137 / (0.8 * fs);
        const double gain = 0.01 * (0.6 + 0.4 * std::sin(1.7 * s + 0.9 * m + k));
        const double phase = 0.31 * s + 0.7 * k + 0.4 * m;
        for (uint64_t i = arrival; i < len; ++i) {
            const double t = static_cast<double>(i - arrival);
            ir[i] += static_cast<float>(gain * std::exp(-alpha * t) * std::cos(2.0 * 3.14159265358979 * hz[k] * t / fs + phase));
        }
    }
    return ir;
}

static void testRate(double fs) {
    std::vector<std::vector<float>> ir(static_cast<size_t>(kN) * kSeats);
    n60_mimo_problem prob;
    n60_mimo_defaults(fs, kN, kSeats, &prob);
    prob.tau_seconds = 0.015;
    prob.taps = 256;
    for (uint32_t s = 0; s < kN; ++s) {
        prob.sources[s].support_low_hz = 30.0;
        prob.sources[s].gain_limit_db = 30.0;   // 32 sources of similar modal content sum their rows; the limit is not the case under test
        prob.sources[s].effort_limit_db = 30.0;
        prob.sources[s].support_high_hz = 80.0;
        for (uint32_t m = 0; m < kSeats; ++m) {
            ir[s * kSeats + m] = plant(fs, s, m);
            prob.program_plant[s][m] = ir[s * kSeats + m].data();
            prob.program_count[s][m] = ir[s * kSeats + m].size();
        }
    }
    prob.sources[31].excluded = 1;
    prob.sources[7].excluded = 1;
    std::vector<float> taps(static_cast<size_t>(kN) * kN * prob.taps), again(taps.size());
    n60_mimo_info info;
    const int32_t st = n60_mimo_design(&prob, taps.data(), taps.size(), &info);
    CHECK(st == N60_MIMO_OK, "N=32 design failed (%d) at %.0f, bad source %d", st, fs, info.bad_source);
    if (st != N60_MIMO_OK) return;
    CHECK(info.decimation >= 16, "decimation at %.0f", fs);
    bool finite = true, excludedZero = true, activeNonzero = false;
    for (uint32_t s = 0; s < kN; ++s)
        for (uint32_t t = 0; t < kN; ++t)
            for (uint32_t k = 0; k < prob.taps; ++k) {
                const float v = taps[(static_cast<size_t>(s) * kN + t) * prob.taps + k];
                finite &= std::isfinite(v);
                if (s == 7 || s == 31 || t == 7 || t == 31) excludedZero &= v == 0.0f;
                else if (v != 0.0f) activeNonzero = true;
            }
    CHECK(finite, "non-finite taps at %.0f", fs);
    CHECK(excludedZero, "excluded rows and columns are not exactly zero at %.0f", fs);
    CHECK(activeNonzero, "active block is empty at %.0f", fs);
    for (uint32_t s = 0; s < kN; ++s) {
        if (s == 7 || s == 31) continue;
        CHECK(info.peak_gain_db[s] <= prob.sources[s].gain_limit_db + 1e-6, "gain peak %.2f dB source %u at %.0f", info.peak_gain_db[s], s, fs);
        CHECK(info.effort_peak_db[s] <= prob.sources[s].effort_limit_db + 1e-6, "effort peak %.2f dB source %u at %.0f", info.effort_peak_db[s], s, fs);
    }
    if (fs != 48000.0) return;   // the rerun doubles the cost; one rate shows determinism
    const int32_t st2 = n60_mimo_design(&prob, again.data(), again.size(), nullptr);
    CHECK(st2 == N60_MIMO_OK && taps == again, "N=32 design is not bit-identical between runs at %.0f", fs);
}

static void testBeyondLimit() {
    n60_mimo_problem prob;
    n60_mimo_defaults(48000.0, kN, kSeats, &prob);
    prob.source_count = kN + 1;
    std::vector<float> out(16);
    CHECK(n60_mimo_design(&prob, out.data(), out.size(), nullptr) == N60_MIMO_ERR_ARGUMENT, "33 sources must be refused");
}

int main() {
    for (double fs : kRates) testRate(fs);
    testBeyondLimit();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("mimo n32 tests passed");
    return 0;
}
