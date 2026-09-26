#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Biquad.h"
#include "../NotchSixty/Audio/Realtime/N60RenderKernel.h"

static void require_true(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "PR34 compiled-EQ validation failed: %s\n", message);
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

static double butterworth_magnitude(
    N60BiquadFilterType type,
    double sampleRate,
    double cutoff,
    uint32_t order,
    double tone
) {
    uint32_t count = N60BiquadButterworthSectionCount(order);
    double result = 1.0;
    for (uint32_t i = 0; i < count; ++i) {
        N60BiquadCoefficients c;
        require_true(N60BiquadDesignButterworthSection(type, sampleRate, cutoff, order, i, &c), "Butterworth section design failed");
        require_true(N60BiquadCoefficientsAreFinite(c), "Butterworth section is non-finite");
        result *= magnitude(c, sampleRate, tone);
    }
    return result;
}

int main(void) {
    require_true(N60_MAX_EQ_BANDS == 64, "user-band product limit changed");
    require_true(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND == 8, "unexpected per-band compiled-section limit");
    require_true(N60_MAX_EQ_RENDER_SLOTS >= 1024, "independent 64-band/96 dB capacity is insufficient");

    const uint32_t orders[] = {1, 2, 3, 4, 6, 8, 10, 12, 14, 16};
    const double rates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    for (size_t r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r) {
        for (size_t o = 0; o < sizeof(orders) / sizeof(orders[0]); ++o) {
            uint32_t order = orders[o];
            require_true(N60BiquadButterworthSectionCount(order) == (order + 1u) / 2u, "wrong Butterworth section count");
            double lpFc = butterworth_magnitude(N60BiquadFilterTypeLowPass, rates[r], 1000.0, order, 1000.0);
            double hpFc = butterworth_magnitude(N60BiquadFilterTypeHighPass, rates[r], 1000.0, order, 1000.0);
            require_true(fabs(20.0 * log10(lpFc) + 3.0103) < 0.08, "LP cutoff is not Butterworth -3.01 dB");
            require_true(fabs(20.0 * log10(hpFc) + 3.0103) < 0.08, "HP cutoff is not Butterworth -3.01 dB");
        }
    }

    double lp12 = butterworth_magnitude(N60BiquadFilterTypeLowPass, 48000.0, 1000.0, 2, 2000.0);
    double lp96 = butterworth_magnitude(N60BiquadFilterTypeLowPass, 48000.0, 1000.0, 16, 2000.0);
    require_true(lp96 < lp12 * 0.001, "96 dB/oct LP is not substantially steeper than 12 dB/oct");
    require_true(20.0 * log10(lp96) < -80.0, "96 dB/oct LP lacks expected octave attenuation");

    N60BiquadCoefficients lowShelf;
    N60BiquadCoefficients highShelf;
    require_true(N60BiquadDesignFirstOrderShelf(N60BiquadFilterTypeLowShelf, 48000.0, 1000.0, 6.0, &lowShelf), "first-order low shelf failed");
    require_true(N60BiquadDesignFirstOrderShelf(N60BiquadFilterTypeHighShelf, 48000.0, 1000.0, 6.0, &highShelf), "first-order high shelf failed");
    require_true(20.0 * log10(magnitude(lowShelf, 48000.0, 20.0)) > 5.8, "low shelf low-frequency endpoint wrong");
    require_true(fabs(20.0 * log10(magnitude(lowShelf, 48000.0, 18000.0))) < 0.2, "low shelf high-frequency endpoint wrong");
    require_true(fabs(20.0 * log10(magnitude(highShelf, 48000.0, 20.0))) < 0.2, "high shelf low-frequency endpoint wrong");
    require_true(20.0 * log10(magnitude(highShelf, 48000.0, 18000.0)) > 5.8, "high shelf high-frequency endpoint wrong");

    puts("PR34 compiled EQ / slope validation passed.");
    return 0;
}
