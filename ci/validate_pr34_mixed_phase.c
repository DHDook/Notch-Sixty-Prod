#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../NotchSixty/Audio/Realtime/N60MixedPhase.h"

static double correction_magnitude(
    const N60MixedPhaseDesignInfo *info,
    double sampleRate,
    double frequencyHz
) {
    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    N60MixedComplex response = {.real = 1.0, .imag = 0.0};
    for (uint32_t index = 0; index < info->sectionCount; ++index) {
        N60BiquadBandSnapshot section = N60MixedPhaseDesignSectionAt(info, index);
        assert(section.enabled);
        assert(section.type == N60BiquadFilterTypeAllPass);
        assert(N60BiquadCoefficientsAreFinite(section.coefficients));
        response = N60MixedComplexMultiply(
            response,
            N60MixedPhaseSectionResponse(section.coefficients, omega)
        );
    }
    return hypot(response.real, response.imag);
}

static void validate_rate(double sampleRate) {
    N60BiquadBandSnapshot source[3] = {0};
    assert(N60BiquadBandSnapshotMake(
        N60BiquadFilterTypeLowShelf, sampleRate, 120.0, 5.0, 0.707,
        true, &source[0]
    ));
    assert(N60BiquadBandSnapshotMake(
        N60BiquadFilterTypePeaking, sampleRate, 1100.0, 8.0, 2.0,
        true, &source[1]
    ));
    assert(N60BiquadBandSnapshotMake(
        N60BiquadFilterTypeHighShelf, sampleRate, 7000.0, -4.0, 0.707,
        true, &source[2]
    ));

    N60MixedPhaseDesignInfo info = {0};
    assert(N60MixedPhaseDesign(sampleRate, source, 3, &info));
    assert(info.sectionCount > 0u);
    assert(info.sectionCount <= N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE);
    assert(isfinite(info.inputPhaseResidualRadiansRMS));
    assert(isfinite(info.outputPhaseResidualRadiansRMS));
    assert(isfinite(info.fittedDelaySamples));
    assert(info.outputPhaseResidualRadiansRMS < info.inputPhaseResidualRadiansRMS * 0.995);

    const double frequencies[] = {30.0, 80.0, 250.0, 1000.0, 4000.0, 10000.0, 18000.0};
    for (uint32_t index = 0; index < (uint32_t)(sizeof(frequencies) / sizeof(frequencies[0])); ++index) {
        if (frequencies[index] >= sampleRate * 0.45) continue;
        double magnitude = correction_magnitude(&info, sampleRate, frequencies[index]);
        assert(isfinite(magnitude));
        assert(fabs(20.0 * log10(magnitude)) < 0.001);
    }
}

int main(void) {
    // A flat chain must not invent phase correction.
    N60MixedPhaseDesignInfo empty = {0};
    assert(N60MixedPhaseDesign(48000.0, NULL, 0, &empty));
    assert(empty.sectionCount == 0u);
    assert(empty.inputPhaseResidualRadiansRMS == 0.0);
    assert(empty.outputPhaseResidualRadiansRMS == 0.0);

    const double rates[] = {
        44100.0, 48000.0, 88200.0, 96000.0,
        176400.0, 192000.0, 352800.0, 384000.0,
    };
    for (uint32_t index = 0; index < (uint32_t)(sizeof(rates) / sizeof(rates[0])); ++index) {
        validate_rate(rates[index]);
    }

    puts("PR34 Mixed Phase validator passed through 384 kHz.");
    return 0;
}
