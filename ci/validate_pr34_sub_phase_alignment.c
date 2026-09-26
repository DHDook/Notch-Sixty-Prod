#include <complex.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Crossover.h"

static void fail(const char *message) {
    fprintf(stderr, "PR34 sub-bass phase alignment validation failed: %s\n", message);
    exit(1);
}

static double complex response(N60BiquadCoefficients c, double sampleRate, double frequencyHz) {
    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double complex z1 = cexp(-I * omega);
    double complex z2 = z1 * z1;
    return (c.b0 + c.b1 * z1 + c.b2 * z2) / (1.0 + c.a1 * z1 + c.a2 * z2);
}

static void require_close(double actual, double expected, double tolerance, const char *message) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(message);
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const double probes[] = {20, 40, 80, 120, 250, 1000, 5000};

    for (size_t r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r) {
        N60CrossoverSnapshot snapshot;
        if (!N60CrossoverSnapshotMake(
                rates[r], 80.0, N60CrossoverTopologyLinkwitzRiley24,
                N60CrossoverMonitorModeRecombined, 1.0f, false, true, &snapshot)) {
            fail("crossover design failed at supported rate");
        }
        if (!N60CrossoverSnapshotSetSubPhaseAlignment(rates[r], 80.0, 0.7, true, &snapshot)) {
            fail("phase-alignment design failed at supported rate");
        }
        if (!snapshot.subPhaseAlignmentEnabled) fail("enabled phase alignment was not retained");
        if (!N60BiquadCoefficientsAreFinite(snapshot.subPhaseAlignmentAllPass)) fail("non-finite all-pass coefficients");

        for (size_t p = 0; p < sizeof(probes) / sizeof(probes[0]); ++p) {
            double probe = probes[p];
            if (probe >= rates[r] * 0.49) continue;
            double magnitude = cabs(response(snapshot.subPhaseAlignmentAllPass, rates[r], probe));
            require_close(magnitude, 1.0, 3.0e-5, "all-pass magnitude is not transparent");
        }

        double centerPhase = carg(response(snapshot.subPhaseAlignmentAllPass, rates[r], 80.0));
        if (!isfinite(centerPhase) || fabs(centerPhase) < 0.25) fail("all-pass does not rotate phase near center");
    }

    N60CrossoverSnapshot qLow;
    N60CrossoverSnapshot qHigh;
    if (!N60CrossoverSnapshotMake(96000, 80, N60CrossoverTopologyLinkwitzRiley24,
            N60CrossoverMonitorModeRecombined, 1, false, true, &qLow)) fail("Q test base design failed");
    qHigh = qLow;
    if (!N60CrossoverSnapshotSetSubPhaseAlignment(96000, 80, 0.4, true, &qLow)) fail("low-Q design failed");
    if (!N60CrossoverSnapshotSetSubPhaseAlignment(96000, 80, 2.0, true, &qHigh)) fail("high-Q design failed");
    double phaseLow = carg(response(qLow.subPhaseAlignmentAllPass, 96000, 50));
    double phaseHigh = carg(response(qHigh.subPhaseAlignmentAllPass, 96000, 50));
    if (fabs(phaseLow - phaseHigh) < 0.05) fail("Q does not influence phase shape");

    N60CrossoverSnapshot fLow = qLow;
    N60CrossoverSnapshot fHigh = qLow;
    if (!N60CrossoverSnapshotSetSubPhaseAlignment(96000, 55, 0.7, true, &fLow)) fail("low-frequency design failed");
    if (!N60CrossoverSnapshotSetSubPhaseAlignment(96000, 120, 0.7, true, &fHigh)) fail("high-frequency design failed");
    double phaseF1 = carg(response(fLow.subPhaseAlignmentAllPass, 96000, 80));
    double phaseF2 = carg(response(fHigh.subPhaseAlignmentAllPass, 96000, 80));
    if (fabs(phaseF1 - phaseF2) < 0.05) fail("alignment frequency does not influence phase shape");

    N60CrossoverSnapshot disabled = qLow;
    if (!N60CrossoverSnapshotSetSubPhaseAlignment(96000, 80, 0.7, false, &disabled)) fail("disabled design failed");
    if (disabled.subPhaseAlignmentEnabled) fail("disabled state changed");
    require_close(disabled.subPhaseAlignmentAllPass.b0, 1.0, 1.0e-7, "disabled path is not identity");
    require_close(disabled.subPhaseAlignmentAllPass.b1, 0.0, 1.0e-7, "disabled path is not identity");
    require_close(disabled.subPhaseAlignmentAllPass.b2, 0.0, 1.0e-7, "disabled path is not identity");

    N60CrossoverSnapshot invalid = qLow;
    if (N60CrossoverSnapshotSetSubPhaseAlignment(96000, 0, 0.7, true, &invalid)) fail("zero frequency accepted");
    if (N60CrossoverSnapshotSetSubPhaseAlignment(96000, 80, 0, true, &invalid)) fail("zero Q accepted");
    if (N60CrossoverSnapshotSetSubPhaseAlignment(96000, NAN, 0.7, true, &invalid)) fail("NaN frequency accepted");
    if (N60CrossoverSnapshotSetSubPhaseAlignment(96000, 80, NAN, true, &invalid)) fail("NaN Q accepted");

    puts("PR34 sub-bass phase alignment validation passed.");
    return 0;
}
