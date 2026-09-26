#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Biquad.h"
#include "../NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h"

static void require_condition(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "Constant-Q validation failed: %s\n", message);
        exit(1);
    }
}

static double magnitude_db_at(
    N60BiquadCoefficients c,
    double sampleRate,
    double frequencyHz
) {
    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double complex z1 = cexp(-I * omega);
    double complex z2 = cexp(-I * 2.0 * omega);
    double complex numerator = (double)c.b0 + (double)c.b1 * z1 + (double)c.b2 * z2;
    double complex denominator = 1.0 + (double)c.a1 * z1 + (double)c.a2 * z2;
    double magnitude = cabs(numerator / denominator);
    return 20.0 * log10(fmax(magnitude, 1.0e-30));
}

static bool coefficients_nearly_equal(
    N60BiquadCoefficients lhs,
    N60BiquadCoefficients rhs,
    double tolerance
) {
    return fabs((double)lhs.b0 - (double)rhs.b0) <= tolerance
        && fabs((double)lhs.b1 - (double)rhs.b1) <= tolerance
        && fabs((double)lhs.b2 - (double)rhs.b2) <= tolerance
        && fabs((double)lhs.a1 - (double)rhs.a1) <= tolerance
        && fabs((double)lhs.a2 - (double)rhs.a2) <= tolerance;
}

static void validate_at_rate(double sampleRate) {
    const double centerHz = 1000.0;
    const double userQ = 2.0;

    for (size_t index = 0; index < 2; ++index) {
        double gainDB = index == 0 ? 6.0 : -6.0;
        N60BiquadCoefficients proportional = {0};
        N60BiquadCoefficients constantQ = {0};
        N60BiquadCoefficients mappedCookbook = {0};

        require_condition(
            N60BiquadDesign(
                N60BiquadFilterTypePeaking,
                sampleRate,
                centerHz,
                gainDB,
                userQ,
                &proportional
            ),
            "default peaking design failed"
        );
        require_condition(
            N60BiquadDesign(
                N60BiquadFilterTypePeakingConstantQ,
                sampleRate,
                centerHz,
                gainDB,
                userQ,
                &constantQ
            ),
            "constant-Q peaking design failed"
        );
        require_condition(
            N60BiquadCoefficientsAreFinite(constantQ),
            "constant-Q produced non-finite coefficients"
        );
        require_condition(
            fabs(magnitude_db_at(constantQ, sampleRate, centerHz) - gainDB) < 0.02,
            "constant-Q center gain does not match requested gain"
        );
        require_condition(
            !coefficients_nearly_equal(proportional, constantQ, 1.0e-7),
            "constant-Q is indistinguishable from the default proportional-Q bell"
        );

        // W3C Audio EQ Cookbook: for peakingEQ, A * Qcookbook is the
        // classic electrical Q. Holding classic Q at userQ therefore means
        // Qcookbook = userQ / A.
        double A = pow(10.0, gainDB / 40.0);
        require_condition(
            N60BiquadDesign(
                N60BiquadFilterTypePeaking,
                sampleRate,
                centerHz,
                gainDB,
                userQ / A,
                &mappedCookbook
            ),
            "mapped cookbook design failed"
        );
        require_condition(
            coefficients_nearly_equal(constantQ, mappedCookbook, 2.0e-7),
            "constant-Q does not preserve the documented classic-Q mapping"
        );
    }

    N60BiquadCoefficients flat = {0};
    require_condition(
        N60BiquadDesign(
            N60BiquadFilterTypePeakingConstantQ,
            sampleRate,
            centerHz,
            0.0,
            userQ,
            &flat
        ),
        "0 dB constant-Q design failed"
    );
    require_condition(
        fabs(magnitude_db_at(flat, sampleRate, 200.0)) < 1.0e-4
            && fabs(magnitude_db_at(flat, sampleRate, centerHz)) < 1.0e-4
            && fabs(magnitude_db_at(flat, sampleRate, fmin(8000.0, sampleRate * 0.20))) < 1.0e-4,
        "0 dB constant-Q band is not transparent"
    );
}

static void validate_linear_phase(double sampleRate) {
    uint32_t capacity = N60LinearPhaseEQRecommendedTapCount(sampleRate);
    require_condition(capacity > 0, "invalid linear-phase tap recommendation");
    float *taps = calloc(capacity, sizeof(float));
    require_condition(taps != NULL, "unable to allocate FIR validation buffer");

    N60LinearPhaseEQBand band = {
        .enabled = true,
        .type = N60BiquadFilterTypePeakingConstantQ,
        .frequencyHz = 1000.0,
        .gainDB = 6.0,
        .q = 2.0,
    };
    N60LinearPhaseEQDesignInfo info = {0};
    require_condition(
        N60LinearPhaseEQDesign(sampleRate, &band, 1, taps, capacity, &info),
        "linear-phase designer rejected constant-Q peaking"
    );

    double energy = 0.0;
    for (uint32_t index = 0; index < info.tapCount; ++index) {
        require_condition(isfinite(taps[index]), "non-finite linear-phase tap");
        energy += (double)taps[index] * (double)taps[index];
    }
    require_condition(isfinite(energy) && energy > 1.0e-12, "constant-Q linear-phase FIR is empty");
    free(taps);
}

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
        validate_at_rate(sampleRates[index]);
    }
    validate_linear_phase(48000.0);
    validate_linear_phase(384000.0);

    puts("PR34 Constant-Q validation passed.");
    return 0;
}
