// E33 S27 (G52): acoustic reference lab, probe half. Designs a narrow bass cut (40 Hz, -9 dB, Q 3) with the production core
// at each EQ linear-phase length and prints, for every rate and length, the FIR's tap count, its delay (the peak tap's
// distance from the start), the core's reported error and the FIR's magnitude in dB at fixed frequencies. The Python half
// checks them against an RBJ peaking model. Output: "LEN <rate> <ms> <taps> <delay> <reportedErrDb> <dB at 8 frequencies>".
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/graph.h"

namespace {
const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
const double kFreqs[8] = {20.0, 30.0, 40.0, 50.0, 70.0, 150.0, 1000.0, 8000.0};
constexpr double kPi = 3.14159265358979323846;
}  // namespace

int main() {
    for (double rate : kRates) {
        double c[5];
        if (n60_eq_design_section(0, rate, 40.0, -9.0, 3.0, c) != 1) return 2;
        float section[5];
        for (int i = 0; i < 5; ++i) section[i] = static_cast<float>(c[i]);
        for (double ms : {21.3333333, 85.0, 170.0, 340.0}) {
            uint32_t delay = static_cast<uint32_t>(std::llround(rate * ms / 1000.0));
            if (ms < 22) delay = std::min<uint32_t>(8192, std::max<uint32_t>(512, static_cast<uint32_t>(std::llround(rate / 46.875))));
            std::vector<float> taps(2ull * delay + 1);
            n60_eq_linear_phase_report r{};
            if (n60_eq_linear_phase_design(rate, delay, section, 1, taps.data(), taps.size(), &r) != 1) return 3;
            size_t peak = 0;
            for (size_t i = 0; i < taps.size(); ++i) if (std::fabs(taps[i]) > std::fabs(taps[peak])) peak = i;
            std::printf("LEN %g %g %u %zu %.4f", rate, ms < 22 ? 21.0 : ms, r.tapCount, peak, r.maxErrorDb);
            for (double f : kFreqs) {
                const double w = 2.0 * kPi * f / rate;
                double re = 0.0, im = 0.0;
                for (size_t n = 0; n < taps.size(); ++n) { re += taps[n] * std::cos(w * n); im -= taps[n] * std::sin(w * n); }
                std::printf(" %.4f", 20.0 * std::log10(std::sqrt(re * re + im * im)));
            }
            std::printf("\n");
        }
    }
    return 0;
}
