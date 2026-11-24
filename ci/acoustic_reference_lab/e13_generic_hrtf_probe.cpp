// E13 S12 (G29): acoustic reference lab, probe half. Generates the production generic HRTF at each of the eight rates for a
// set of directions and prints, per ear, the response's DC group delay in samples (the centroid of the taps) and its
// magnitude in dB at 500 Hz, 2 kHz and 8 kHz. The Python half checks them against an independent implementation of the
// published rigid-sphere model. Output: "HRTF <rate> <az> <el> <ear> <taps> <centroid> <dB500> <dB2000> <dB8000>".
#include <cmath>
#include <cstdio>
#include <vector>

#include "n60/hrtf.h"

namespace {
const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
const double kDirs[][2] = {{0, 0}, {-30, 0}, {30, 0}, {-90, 0}, {90, 0}, {110, 0}, {-150, 0}, {180, 0}, {45, 45}, {-90, 60}};
constexpr double kPi = 3.14159265358979323846;
}  // namespace

int main() {
    for (double rate : kRates) {
        const uint32_t taps = n60_hrtf_generic_taps(rate);
        std::vector<float> l(taps), r(taps);
        for (const auto &d : kDirs) {
            if (n60_hrtf_generic_ir(rate, d[0], d[1], taps, l.data(), r.data()) != N60_HRTF_OK) return 2;
            const std::vector<float> *ears[2] = {&l, &r};
            for (int e = 0; e < 2; ++e) {
                double sum = 0.0, moment = 0.0;
                for (uint32_t n = 0; n < taps; ++n) { sum += (*ears[e])[n]; moment += double(n) * (*ears[e])[n]; }
                std::printf("HRTF %g %g %g %d %u %.6f", rate, d[0], d[1], e, taps, moment / sum);
                for (double f : {500.0, 2000.0, 8000.0}) {
                    double re = 0.0, im = 0.0;
                    for (uint32_t n = 0; n < taps; ++n) {
                        const double w = 2.0 * kPi * f * n / rate;
                        re += (*ears[e])[n] * std::cos(w);
                        im -= (*ears[e])[n] * std::sin(w);
                    }
                    std::printf(" %.4f", 20.0 * std::log10(std::sqrt(re * re + im * im)));
                }
                std::printf("\n");
            }
        }
    }
    return 0;
}
