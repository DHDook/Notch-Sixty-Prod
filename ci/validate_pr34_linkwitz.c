#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Biquad.h"
#include "../NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h"

static void require_true(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "PR34 Linkwitz validation failed: %s\n", message);
        exit(1);
    }
}

static double magnitude(N60BiquadCoefficients c, double sampleRate, double frequencyHz) {
    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double c1 = cos(omega), s1 = sin(omega);
    double c2 = cos(2.0 * omega), s2 = sin(2.0 * omega);
    double nr = c.b0 + c.b1 * c1 + c.b2 * c2;
    double ni = -c.b1 * s1 - c.b2 * s2;
    double dr = 1.0 + c.a1 * c1 + c.a2 * c2;
    double di = -c.a1 * s1 - c.a2 * s2;
    return sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

static int coefficients_differ(N60BiquadCoefficients a, N60BiquadCoefficients b) {
    const double eps = 1.0e-7;
    return fabs(a.b0 - b.b0) > eps || fabs(a.b1 - b.b1) > eps || fabs(a.b2 - b.b2) > eps
        || fabs(a.a1 - b.a1) > eps || fabs(a.a2 - b.a2) > eps;
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0};
    const size_t rateCount = sizeof(rates) / sizeof(rates[0]);

    for (size_t i = 0; i < rateCount; ++i) {
        N60BiquadCoefficients c;
        require_true(N60BiquadDesignLinkwitzTransform(rates[i], 55.0, 1.21, 25.0, 0.5, &c), "design rejected a supported sample rate");
        require_true(N60BiquadCoefficientsAreFinite(c), "non-finite coefficients");
        double hf = magnitude(c, rates[i], fmin(10000.0, rates[i] * 0.2));
        require_true(isfinite(hf) && fabs(20.0 * log10(hf)) < 0.15, "high-frequency gain is not approximately unity");
    }

    N60BiquadCoefficients identity;
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 55.0, 0.707, 55.0, 0.707, &identity), "identity alignment design failed");
    require_true(fabs(identity.b0 - 1.0f) < 1.0e-5 && fabs(identity.b1 - identity.a1) < 1.0e-5
        && fabs(identity.b2 - identity.a2) < 1.0e-5, "matching original/target alignment is not identity");

    N60BiquadCoefficients base;
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 50.0, 0.7, 25.0, 0.5, &base), "base design failed");
    double dc = magnitude(base, 48000.0, 0.001);
    double expectedDC = (50.0 * 50.0) / (25.0 * 25.0);
    require_true(fabs(20.0 * log10(dc / expectedDC)) < 0.05, "DC gain does not match squared resonance ratio");

    N60BiquadCoefficients changed;
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 60.0, 0.7, 25.0, 0.5, &changed) && coefficients_differ(base, changed), "f0 does not affect coefficients");
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 50.0, 0.9, 25.0, 0.5, &changed) && coefficients_differ(base, changed), "Q0 does not affect coefficients");
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 50.0, 0.7, 32.0, 0.5, &changed) && coefficients_differ(base, changed), "fp does not affect coefficients");
    require_true(N60BiquadDesignLinkwitzTransform(48000.0, 50.0, 0.7, 25.0, 0.8, &changed) && coefficients_differ(base, changed), "Qp does not affect coefficients");

    N60LinearPhaseEQBand band = {0};
    band.enabled = true;
    band.type = N60BiquadFilterTypeLinkwitzTransform;
    band.frequencyHz = 50.0;
    band.gainDB = 0.0;
    band.q = 0.7;
    band.usesPreparedCoefficients = true;
    band.preparedCoefficients = base;

    uint32_t tapCount = N60LinearPhaseEQRecommendedTapCount(48000.0);
    float *taps = calloc(tapCount, sizeof(float));
    require_true(taps != NULL, "tap allocation failed");
    N60LinearPhaseEQDesignInfo info = {0};
    require_true(N60LinearPhaseEQDesign(48000.0, &band, 1, taps, tapCount, &info), "Linear-Phase projection rejected prepared Linkwitz coefficients");
    require_true(info.tapCount == tapCount, "unexpected Linear-Phase tap count");
    for (uint32_t i = 0; i < tapCount; ++i) require_true(isfinite(taps[i]), "non-finite Linear-Phase tap");
    free(taps);

    puts("PR34 Linkwitz Transform validation passed.");
    return 0;
}
