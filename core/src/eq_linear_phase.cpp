// E33 S27 (G52, E23 G11 EQ half): the linear-phase EQ design, in the portable core. The EQ's prepared biquad sections
// (b0, b1, b2, a1, a2; a0 = 1, from n60_eq_design_section or the cookbook) give a zero-phase magnitude that
// n60_correct_synthesize_linear_phase_capped turns into one single-band FIR of 2 L + 1 taps, delayed by exactly L frames
// and windowed with the Blackman window of the crossover designer (the window the C design in N60LinearPhaseEQ.h used).
// Derivation: a linear-phase FIR is the inverse DFT of the sampled magnitude, shifted by L and windowed (Oppenheim and
// Schafer, Discrete-Time Signal Processing, window design method). Control plane only: it allocates (the FFT work
// vectors), throws nothing (the core builds without exceptions; an allocation failure aborts), is single-threaded and deterministic (fixed summation order).
// Latency: L frames. Sample rates: 8 to 768 kHz. Channels: one filter; the caller applies it to every lane it selects.
#include <algorithm>
#include <cmath>
#include <cstdint>

#include "n60/correct.h"
#include "n60/graph.h"

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kMaxSections = 512;  // the EQ's band limit times its compiled sections per band is far below this

struct Cascade {
    double fs;
    const float *sections;
    uint32_t count;
};

// |H| of the cascade at hz: the product of each section's magnitude (float coefficients widened, as the engine runs them).
double cascadeMagnitude(const Cascade &c, double hz) {
    const double w = 2.0 * kPi * hz / c.fs;
    const double c1 = std::cos(w), s1 = std::sin(w), c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
    double magnitude = 1.0;
    for (uint32_t i = 0; i < c.count; ++i) {
        const double b0 = c.sections[5 * i], b1 = c.sections[5 * i + 1], b2 = c.sections[5 * i + 2];
        const double a1 = c.sections[5 * i + 3], a2 = c.sections[5 * i + 4];
        const double nr = b0 + b1 * c1 + b2 * c2, ni = -b1 * s1 - b2 * s2;
        const double dr = 1.0 + a1 * c1 + a2 * c2, di = -a1 * s1 - a2 * s2;
        const double np = nr * nr + ni * ni, dp = dr * dr + di * di;
        if (!std::isfinite(np) || !std::isfinite(dp) || dp <= 1.0e-30) continue;  // an undefined section is transparent
        const double m = std::sqrt(np / dp);
        if (std::isfinite(m)) magnitude *= m;
    }
    return magnitude;
}

double amplitudeCallback(double hz, void *user) { return cascadeMagnitude(*static_cast<const Cascade *>(user), hz); }

// |sum taps[n] e^{-j w n}| at hz (direct sum; the rotation is re-seeded every 1024 taps so rounding cannot drift).
double tapMagnitude(const float *taps, uint32_t count, double fs, double hz) {
    const double w = 2.0 * kPi * hz / fs;
    const double stepRe = std::cos(w), stepIm = -std::sin(w);
    double re = 0.0, im = 0.0, pr = 1.0, pi = 0.0;
    for (uint32_t n = 0; n < count; ++n) {
        if ((n & 1023u) == 0) {
            pr = std::cos(w * static_cast<double>(n));
            pi = -std::sin(w * static_cast<double>(n));
        }
        re += taps[n] * pr;
        im += taps[n] * pi;
        const double nr = pr * stepRe - pi * stepIm;
        pi = pr * stepIm + pi * stepRe;
        pr = nr;
    }
    return std::sqrt(re * re + im * im);
}

}  // namespace

extern "C" {

int32_t n60_eq_linear_phase_design(double sampleRate, uint32_t groupDelayFrames, const float *sections, uint32_t sectionCount,
                                   float *taps, uint64_t tapCapacity, n60_eq_linear_phase_report *report) {
    if (taps == nullptr || (sectionCount > 0 && sections == nullptr) || sectionCount > kMaxSections ||
        !std::isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 768000.0 || groupDelayFrames < 1 || groupDelayFrames > (N60_EQ_LINEAR_PHASE_MAX_TAPS - 1) / 2) {
        return 0;
    }
    for (uint32_t i = 0; i < sectionCount * 5; ++i) {
        if (!std::isfinite(sections[i])) return 0;
    }
    const uint64_t tapCount = 2ull * groupDelayFrames + 1;
    if (tapCount > tapCapacity) return 0;
    Cascade cascade{sampleRate, sections, sectionCount};
    n60_correct_two_band_report two{};
    // The long single-band cap: a design of up to 262,144 taps is one band, never two-band (the FIR stage carries it).
    if (n60_correct_synthesize_linear_phase_capped(sampleRate, groupDelayFrames, amplitudeCallback, &cascade, nullptr,
                                                   N60_CORRECT_STAGE_TAPS_LONG, taps, tapCapacity, nullptr, 0, &two) !=
        N60_CORRECT_OK) {
        return 0;
    }
    if (report != nullptr) {
        *report = n60_eq_linear_phase_report{};
        report->structSize = sizeof(n60_eq_linear_phase_report);
        report->tapCount = static_cast<uint32_t>(tapCount);
        report->groupDelayFrames = groupDelayFrames;
        // Largest |dB difference| between the FIR and the drawn magnitude, 20 Hz to min(20 kHz, 0.45 fs), one point per
        // 1/48 octave in log frequency (the narrowest EQ band is a few Hz wide, so a coarse grid could step over it).
        // Both are floored at -80 dB so a deep stop band is not a huge error.
        const double top = std::min(20000.0, 0.45 * sampleRate);
        double worst = 0.0;
        const int kPoints = static_cast<int>(std::ceil(std::log2(top / 20.0) * 48.0)) + 1;
        for (int i = 0; i < kPoints; ++i) {
            const double hz = 20.0 * std::pow(top / 20.0, static_cast<double>(i) / (kPoints - 1));
            const double want = std::max(cascadeMagnitude(cascade, hz), 1.0e-4);
            const double got = std::max(tapMagnitude(taps, static_cast<uint32_t>(tapCount), sampleRate, hz), 1.0e-4);
            const double e = std::fabs(20.0 * std::log10(got / want));
            if (!std::isfinite(e)) return 0;
            worst = std::max(worst, e);
        }
        report->maxErrorDb = worst;
    }
    return 1;
}

}  // extern "C"
