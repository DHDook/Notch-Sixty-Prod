#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "n60/biquad.h"

static double magnitude_at(
    N60BiquadCoefficients c,
    double sampleRate,
    double frequencyHz
) {
    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double complex z1 = cexp(-I * omega);
    double complex z2 = cexp(-I * 2.0 * omega);
    double complex numerator = (double)c.b0 + (double)c.b1 * z1 + (double)c.b2 * z2;
    double complex denominator = 1.0 + (double)c.a1 * z1 + (double)c.a2 * z2;
    return cabs(numerator / denominator);
}

static void require_condition(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "Band Pass validation failed: %s\n", message);
        exit(1);
    }
}

static void validate_biquad_at_rate(double sampleRate) {
    const double centerHz = 1000.0;
    N60BiquadCoefficients wide = {0};
    N60BiquadCoefficients narrow = {0};
    N60BiquadCoefficients gainIgnored = {0};

    require_condition(
        N60BiquadDesign(
            N60BiquadFilterTypeBandPass,
            sampleRate,
            centerHz,
            0.0,
            0.707,
            &wide
        ),
        "coefficient design rejected a supported sample rate"
    );
    require_condition(N60BiquadCoefficientsAreFinite(wide), "non-finite coefficients");

    double centerMagnitude = magnitude_at(wide, sampleRate, centerHz);
    require_condition(isfinite(centerMagnitude), "non-finite center magnitude");
    require_condition(fabs(centerMagnitude - 1.0) < 2.0e-4, "center is not approximately 0 dB");

    double lowMagnitude = magnitude_at(wide, sampleRate, 250.0);
    double highMagnitude = magnitude_at(wide, sampleRate, 4000.0);
    require_condition(lowMagnitude < 0.5, "low-side stop band is not attenuated");
    require_condition(highMagnitude < 0.5, "high-side stop band is not attenuated");

    require_condition(
        N60BiquadDesign(
            N60BiquadFilterTypeBandPass,
            sampleRate,
            centerHz,
            0.0,
            4.0,
            &narrow
        ),
        "high-Q coefficient design failed"
    );
    double wide800 = magnitude_at(wide, sampleRate, 800.0);
    double narrow800 = magnitude_at(narrow, sampleRate, 800.0);
    require_condition(narrow800 < wide800, "higher Q did not narrow the pass band");

    require_condition(
        N60BiquadDesign(
            N60BiquadFilterTypeBandPass,
            sampleRate,
            centerHz,
            18.0,
            0.707,
            &gainIgnored
        ),
        "Band Pass rejected an otherwise valid model gain"
    );
    require_condition(
        fabs((double)gainIgnored.b0 - (double)wide.b0) < 1.0e-7
            && fabs((double)gainIgnored.b1 - (double)wide.b1) < 1.0e-7
            && fabs((double)gainIgnored.b2 - (double)wide.b2) < 1.0e-7
            && fabs((double)gainIgnored.a1 - (double)wide.a1) < 1.0e-7
            && fabs((double)gainIgnored.a2 - (double)wide.a2) < 1.0e-7,
        "Band Pass gain parameter changed the constant-0-dB-peak filter"
    );
}

/* The linear-phase design moved to the core (E33 S27); core/tests/test_eq_linear_phase.cpp covers it at the eight rates. */

int main(void) {
    const double sampleRates[] = {
        44100.0,
        48000.0,
        88200.0,
        96000.0,
        176400.0,
        192000.0,
        352800.0,
        384000.0,
    };

    for (size_t index = 0; index < sizeof(sampleRates) / sizeof(sampleRates[0]); ++index) {
        validate_biquad_at_rate(sampleRates[index]);
    }


    puts("PR34 Band Pass validation passed.");
    return 0;
}
