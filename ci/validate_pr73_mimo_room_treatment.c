#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "N60MIMORoomTreatment.h"

static N60MIMOComplex polar(double magnitude, double degrees) {
    const double radians = degrees * 3.14159265358979323846 / 180.0;
    return (N60MIMOComplex){
        .real = magnitude * cos(radians),
        .imaginary = magnitude * sin(radians),
    };
}

static void install(
    N60MIMOTransferSet *transfer,
    uint32_t frequency,
    uint32_t measurement,
    uint32_t source,
    double magnitude,
    double phaseDegrees
) {
    transfer->measured[
        N60MIMOMeasuredOffset(frequency, measurement, source)
    ] = polar(magnitude, phaseDegrees);
}

static void make_spatially_uneven_fixture(N60MIMOTransferSet *transfer) {
    memset(transfer, 0, sizeof(*transfer));
    transfer->sourceCount = 2u;
    transfer->measurementCount = 2u;
    transfer->frequencyCount = 3u;
    transfer->sampleRate = 48000.0;
    transfer->frequenciesHz[0] = 40.0f;
    transfer->frequenciesHz[1] = 63.0f;
    transfer->frequenciesHz[2] = 100.0f;
    transfer->measurementWeights[0] = 1.0f;
    transfer->measurementWeights[1] = 1.0f;

    // Strongly uneven but well-conditioned low-frequency acoustic field.
    install(transfer, 0u, 0u, 0u, 1.80, 0.0);
    install(transfer, 0u, 0u, 1u, 0.30, 8.0);
    install(transfer, 0u, 1u, 0u, 0.40, -6.0);
    install(transfer, 0u, 1u, 1u, 1.50, 0.0);

    install(transfer, 1u, 0u, 0u, 1.55, 12.0);
    install(transfer, 1u, 0u, 1u, 0.42, -4.0);
    install(transfer, 1u, 1u, 0u, 0.48, 3.0);
    install(transfer, 1u, 1u, 1u, 1.35, -9.0);

    install(transfer, 2u, 0u, 0u, 1.35, -10.0);
    install(transfer, 2u, 0u, 1u, 0.55, 5.0);
    install(transfer, 2u, 1u, 0u, 0.62, 7.0);
    install(transfer, 2u, 1u, 1u, 1.20, -5.0);
}

static void assert_identity_bin(
    const N60MIMORoomTreatmentDesign *design,
    uint32_t frequency
) {
    for (uint32_t target = 0u; target < design->sourceCount; ++target) {
        for (uint32_t source = 0u; source < design->sourceCount; ++source) {
            const N60MIMOComplex value = design->correction.correction[
                N60MIMOCorrectionOffset(frequency, source, target)
            ];
            const double expected = source == target ? 1.0 : 0.0;
            assert(fabs(value.real - expected) < 1.0e-12);
            assert(fabs(value.imaginary) < 1.0e-12);
        }
    }
}

static void test_bounded_spatial_equalization(void) {
    N60MIMOTransferSet transfer;
    make_spatially_uneven_fixture(&transfer);
    assert(N60MIMOTransferSetIsValid(&transfer));

    N60MIMORoomTreatmentSettings settings =
        N60MIMORoomTreatmentSettingsMakeDefault();
    settings.minimumPredictedImprovementDB = 0.5;
    settings.maximumRobustnessDegradationDB = 3.0;
    settings.minimumColumnSafetyScale = 0.05;

    N60MIMORoomTreatmentDesign design = {0};
    assert(N60MIMORoomTreatmentDesignSpatialEqualization(
        &transfer,
        settings,
        &design
    ));
    assert(design.sourceCount == 2u);
    assert(design.measurementCount == 2u);
    assert(design.frequencyCount == 3u);
    assert(design.acceptedFrequencyCount > 0u);

    const double maxColumnPower = pow(
        10.0,
        settings.maximumAggregateSourceGainDB / 10.0
    );
    const double maxCoefficient = pow(
        10.0,
        settings.maximumCoefficientGainDB / 20.0
    );

    for (uint32_t frequency = 0u; frequency < design.frequencyCount; ++frequency) {
        const N60MIMORoomTreatmentFrequencyReport report =
            design.reports[frequency];
        assert(isfinite(report.untreatedResidualPower));
        assert(isfinite(report.candidateResidualPower));
        assert(isfinite(report.candidateImprovementDB));
        assert(isfinite(report.worstCaseRelativeDegradationDB));
        assert(report.maximumCoefficientMagnitude <= maxCoefficient + 1.0e-9);
        assert(report.maximumColumnPower <= maxColumnPower + 1.0e-9);
        assert(report.minimumAppliedSafetyScale > 0.0);
        assert(report.minimumAppliedSafetyScale <= 1.0);

        if (report.accepted) {
            assert(report.candidateImprovementDB >=
                   settings.minimumPredictedImprovementDB - 1.0e-9);
            assert(report.worstCaseRelativeDegradationDB <=
                   settings.maximumRobustnessDegradationDB + 1.0e-9);
        } else {
            assert_identity_bin(&design, frequency);
        }
    }
}

static void test_flat_field_is_exact_noop(void) {
    N60MIMOTransferSet transfer = {0};
    transfer.sourceCount = 2u;
    transfer.measurementCount = 2u;
    transfer.frequencyCount = 1u;
    transfer.sampleRate = 48000.0;
    transfer.frequenciesHz[0] = 70.0f;
    transfer.measurementWeights[0] = 1.0f;
    transfer.measurementWeights[1] = 1.0f;

    // Each source has identical response at both seats. The geometric-mean
    // spatial target is already met exactly.
    install(&transfer, 0u, 0u, 0u, 1.0, 0.0);
    install(&transfer, 0u, 1u, 0u, 1.0, 0.0);
    install(&transfer, 0u, 0u, 1u, 0.55, 20.0);
    install(&transfer, 0u, 1u, 1u, 0.55, 20.0);

    N60MIMORoomTreatmentDesign design = {0};
    assert(N60MIMORoomTreatmentDesignSpatialEqualization(
        &transfer,
        N60MIMORoomTreatmentSettingsMakeDefault(),
        &design
    ));
    assert(design.acceptedFrequencyCount == 0u);
    assert(!design.reports[0].accepted);
    assert(design.reports[0].untreatedResidualPower <= 1.0e-18);
    assert_identity_bin(&design, 0u);
}

static void test_strict_gate_returns_identity_not_untrusted_candidate(void) {
    N60MIMOTransferSet transfer;
    make_spatially_uneven_fixture(&transfer);

    N60MIMORoomTreatmentSettings settings =
        N60MIMORoomTreatmentSettingsMakeDefault();
    settings.minimumPredictedImprovementDB = 24.0;
    settings.maximumRobustnessDegradationDB = 0.0;
    settings.minimumColumnSafetyScale = 1.0;

    N60MIMORoomTreatmentDesign design = {0};
    assert(N60MIMORoomTreatmentDesignSpatialEqualization(
        &transfer,
        settings,
        &design
    ));

    for (uint32_t frequency = 0u; frequency < design.frequencyCount; ++frequency) {
        if (!design.reports[frequency].accepted) {
            assert_identity_bin(&design, frequency);
        }
    }
}

static void test_singular_room_remains_finite_and_bounded(void) {
    N60MIMOTransferSet transfer = {0};
    transfer.sourceCount = 2u;
    transfer.measurementCount = 2u;
    transfer.frequencyCount = 1u;
    transfer.sampleRate = 48000.0;
    transfer.frequenciesHz[0] = 55.0f;
    transfer.measurementWeights[0] = 1.0f;
    transfer.measurementWeights[1] = 1.0f;

    // Highly correlated actuator paths.
    install(&transfer, 0u, 0u, 0u, 1.6, 0.0);
    install(&transfer, 0u, 0u, 1u, 1.6, 0.0);
    install(&transfer, 0u, 1u, 0u, 0.45, 0.0);
    install(&transfer, 0u, 1u, 1u, 0.45, 0.0);

    N60MIMORoomTreatmentSettings settings =
        N60MIMORoomTreatmentSettingsMakeDefault();
    settings.regularization = 0.2;

    N60MIMORoomTreatmentDesign design = {0};
    assert(N60MIMORoomTreatmentDesignSpatialEqualization(
        &transfer,
        settings,
        &design
    ));

    const N60MIMORoomTreatmentFrequencyReport report = design.reports[0];
    assert(isfinite(report.candidateResidualPower));
    assert(isfinite(report.maximumCoefficientMagnitude));
    assert(isfinite(report.maximumColumnPower));
    assert(report.maximumCoefficientMagnitude <= 1.000001);
    assert(report.maximumColumnPower <= 1.000001);
}

static void test_invalid_settings_fail_closed(void) {
    N60MIMOTransferSet transfer;
    make_spatially_uneven_fixture(&transfer);
    N60MIMORoomTreatmentSettings settings =
        N60MIMORoomTreatmentSettingsMakeDefault();
    settings.regularization = 0.0;
    N60MIMORoomTreatmentDesign design = {0};
    assert(!N60MIMORoomTreatmentDesignSpatialEqualization(
        &transfer,
        settings,
        &design
    ));
}

int main(void) {
    test_bounded_spatial_equalization();
    test_flat_field_is_exact_noop();
    test_strict_gate_returns_identity_not_untrusted_candidate();
    test_singular_room_remains_finite_and_bounded();
    test_invalid_settings_fail_closed();
    printf("PR73 bounded MIMO room-treatment validation passed\n");
    return 0;
}
