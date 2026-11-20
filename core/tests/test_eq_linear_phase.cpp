// E33 S27 (G52): the core's linear-phase EQ design (n60_eq_linear_phase_design) at the eight standard rates and the four
// EQ lengths (about 21 ms, 85, 170 and 340 ms). (a) A narrow bass band: the reported error shrinks as the length grows and
// the 340 ms design is within 0.5 dB of the drawn curve at every rate. (b) The delay is exactly the group delay, the
// peak tap sits there, and the longest design at 384 kHz is 261,121 taps, inside the 262,144-tap limit. (c) The same input
// gives the same taps. (d) At the 21 ms length the design matches the C design it replaces (re-implemented here as a plain
// frequency-sampling design with a Blackman window) to within 0.05 dB on the sampled curve. (e) Bad arguments are refused.
// The design allocates by design (control plane), so the render-path allocation test (test_alloc) does not apply to it.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

namespace {
int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); ++failures; } } while (0)

constexpr double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr double kPi = 3.14159265358979323846;

uint32_t delayFor(double rate, double ms) { return static_cast<uint32_t>(std::llround(rate * ms / 1000.0)); }
// The default length, as the C design chose it: rate / 46.875 frames, between 512 and 8192.
uint32_t defaultDelay(double rate) { return std::min<uint32_t>(8192, std::max<uint32_t>(512, static_cast<uint32_t>(std::llround(rate / 46.875)))); }

// A peaking section from the engine's own designer.
void peak(double rate, double hz, double gainDb, double q, float *out5) {
    double c[5];
    CHECK(n60_eq_design_section(0, rate, hz, gainDb, q, c) == 1, "design section");
    for (int i = 0; i < 5; ++i) out5[i] = static_cast<float>(c[i]);
}

double sectionsDb(const float *s, uint32_t n, double rate, double hz) {
    double mag = 1.0;
    for (uint32_t i = 0; i < n; ++i) {
        double c[5];
        for (int k = 0; k < 5; ++k) c[k] = s[5 * i + k];
        mag *= n60_eq_section_magnitude(c, rate, hz);
    }
    return 20.0 * std::log10(mag);
}

double tapsDb(const std::vector<float> &t, double rate, double hz) {
    const double w = 2.0 * kPi * hz / rate;
    double re = 0.0, im = 0.0;
    for (size_t n = 0; n < t.size(); ++n) { re += t[n] * std::cos(w * n); im -= t[n] * std::sin(w * n); }
    return 20.0 * std::log10(std::sqrt(re * re + im * im));
}

// The replaced design: samples |H| at N/2 + 1 bins of N = nextpow2(2 taps), inverse DFT, shift by L, Blackman window.
std::vector<float> legacy(double rate, uint32_t L, const float *s, uint32_t count) {
    const uint32_t taps = 2 * L + 1;
    uint32_t N = 1;
    while (N < taps * 2) N <<= 1;
    std::vector<double> mag(N / 2 + 1);
    for (uint32_t k = 0; k <= N / 2; ++k) {
        double m = 1.0;
        for (uint32_t i = 0; i < count; ++i) {
            double c[5];
            for (int j = 0; j < 5; ++j) c[j] = s[5 * i + j];
            m *= n60_eq_section_magnitude(c, rate, rate * k / N);
        }
        mag[k] = m;
    }
    std::vector<float> out(taps);
    for (uint32_t i = 0; i < taps; ++i) {
        const int64_t n = static_cast<int64_t>(i) - L;
        double sum = mag[0] + mag[N / 2] * ((n & 1) ? -1.0 : 1.0);
        for (uint32_t k = 1; k < N / 2; ++k) sum += 2.0 * mag[k] * std::cos(2.0 * kPi * k * n / N);
        const double window = 0.42 - 0.5 * std::cos(2.0 * kPi * i / (taps - 1)) + 0.08 * std::cos(4.0 * kPi * i / (taps - 1));
        out[i] = static_cast<float>(sum / N * window);
    }
    return out;
}
}  // namespace

int main() {
    const double lengthsMs[4] = {0, 85, 170, 340};  // 0: the default 21 ms rule
    for (double rate : kRates) {
        float section[5];
        peak(rate, 40.0, -9.0, 3.0, section);  // a narrow bass cut (about 13 Hz wide)
        double previous = 1e9;
        for (int li = 0; li < 4; ++li) {
            const uint32_t L = lengthsMs[li] == 0 ? defaultDelay(rate) : delayFor(rate, lengthsMs[li]);
            std::vector<float> taps(2ull * L + 1);
            n60_eq_linear_phase_report r{};
            CHECK(n60_eq_linear_phase_design(rate, L, section, 1, taps.data(), taps.size(), &r) == 1, "design %.0f L=%u", rate, L);
            CHECK(r.tapCount == 2 * L + 1 && r.groupDelayFrames == L, "report %.0f", rate);
            CHECK(r.tapCount <= N60_EQ_LINEAR_PHASE_MAX_TAPS, "tap limit %.0f L=%u", rate, L);
            CHECK(r.maxErrorDb <= previous + 0.05, "error grows with length: %.0f %.3f after %.3f", rate, r.maxErrorDb, previous);
            previous = r.maxErrorDb;
            // Linear phase: symmetric taps, so the delay is exactly L.
            double asym = 0.0;
            for (uint32_t i = 0; i < L; ++i) asym = std::max(asym, std::fabs(static_cast<double>(taps[i]) - taps[2 * L - i]));
            CHECK(asym < 1e-5, "symmetric %.0f L=%u asym %g", rate, L, asym);
            if (li == 3) {
                CHECK(r.maxErrorDb <= 0.5, "340 ms within 0.5 dB at %.0f: %.3f", rate, r.maxErrorDb);
                if (rate == 384000) CHECK(r.tapCount == 261121, "384 kHz 340 ms is 261121 taps, got %u", r.tapCount);
                // The reported figure is the real one: spot check the FIR against the section at the band centre.
                if (rate <= 96000) CHECK(std::fabs(tapsDb(taps, rate, 40.0) - sectionsDb(section, 1, rate, 40.0)) <= r.maxErrorDb + 0.05,
                                         "spot check %.0f", rate);
            }
            if (li == 0) CHECK(r.maxErrorDb > 1.0, "the default length cannot resolve a 13 Hz band: %.0f %.3f", rate, r.maxErrorDb);
            // Determinism.
            std::vector<float> again(taps.size());
            CHECK(n60_eq_linear_phase_design(rate, L, section, 1, again.data(), again.size(), nullptr) == 1 &&
                      std::memcmp(taps.data(), again.data(), taps.size() * sizeof(float)) == 0, "deterministic %.0f L=%u", rate, L);
        }
    }
    // (d) The default length matches the replaced design.
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        float sections[10];
        peak(rate, 1000.0, 6.0, 1.0, sections);
        peak(rate, 120.0, -4.0, 0.7, sections + 5);
        const uint32_t L = defaultDelay(rate);
        std::vector<float> taps(2ull * L + 1);
        CHECK(n60_eq_linear_phase_design(rate, L, sections, 2, taps.data(), taps.size(), nullptr) == 1, "design");
        const std::vector<float> old = legacy(rate, L, sections, 2);
        double worst = 0.0;
        for (double hz : {30.0, 60.0, 120.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0})
            worst = std::max(worst, std::fabs(tapsDb(taps, rate, hz) - tapsDb(old, rate, hz)));
        CHECK(worst <= 0.05, "21 ms matches the replaced design at %.0f: %.4f dB", rate, worst);
    }
    // An empty cascade is a pure delay of unity gain.
    {
        std::vector<float> taps(1025);
        n60_eq_linear_phase_report r{};
        CHECK(n60_eq_linear_phase_design(48000, 512, nullptr, 0, taps.data(), taps.size(), &r) == 1 && r.maxErrorDb < 0.05, "flat");
        CHECK(std::fabs(taps[512] - 1.0f) < 1e-3f, "flat centre tap %g", taps[512]);
    }
    // (e) Refusals.
    {
        float s[5] = {1, 0, 0, 0, 0};
        std::vector<float> taps(1025);
        CHECK(n60_eq_linear_phase_design(48000, 512, s, 1, nullptr, 1025, nullptr) == 0, "null taps");
        CHECK(n60_eq_linear_phase_design(48000, 512, s, 1, taps.data(), 1024, nullptr) == 0, "capacity");
        CHECK(n60_eq_linear_phase_design(48000, 0, s, 1, taps.data(), 1025, nullptr) == 0, "zero delay");
        CHECK(n60_eq_linear_phase_design(48000, 131072, s, 1, taps.data(), 1025, nullptr) == 0, "past the tap limit");
        CHECK(n60_eq_linear_phase_design(48000, 512, nullptr, 1, taps.data(), 1025, nullptr) == 0, "null sections");
        s[0] = NAN;
        CHECK(n60_eq_linear_phase_design(48000, 512, s, 1, taps.data(), 1025, nullptr) == 0, "non-finite coefficient");
    }
    if (failures == 0) std::puts("eq linear phase: ok");
    return failures == 0 ? 0 : 1;
}
