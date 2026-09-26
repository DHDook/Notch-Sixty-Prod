#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Spatial.h"

static void fail(const char *message) {
    fprintf(stderr, "PR34 Symmetry Balance validation failed: %s\n", message);
    exit(1);
}

static void require_close(double actual, double expected, double tolerance, const char *message) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(message);
}

static void validate_position(double position) {
    N60SymmetryBalanceSnapshot snapshot;
    if (!N60SymmetryBalanceDesign(position, true, &snapshot)) fail("design rejected valid position");
    if (!N60SymmetryBalanceSnapshotIsValid(snapshot)) fail("designed snapshot is invalid");

    double power = (double)snapshot.leftGainLinear * snapshot.leftGainLinear
        + (double)snapshot.rightGainLinear * snapshot.rightGainLinear;
    require_close(power, 2.0, 2.0e-5, "constant-power invariant changed");
}

int main(void) {
    N60SymmetryBalanceSnapshot disabled;
    if (!N60SymmetryBalanceDesign(0.75, false, &disabled)) fail("disabled design failed");
    require_close(disabled.leftGainLinear, 1.0, 1.0e-7, "disabled left path is not transparent");
    require_close(disabled.rightGainLinear, 1.0, 1.0e-7, "disabled right path is not transparent");

    N60SymmetryBalanceSnapshot center;
    if (!N60SymmetryBalanceDesign(0.0, true, &center)) fail("center design failed");
    require_close(center.leftGainLinear, 1.0, 2.0e-6, "center left gain is not unity");
    require_close(center.rightGainLinear, 1.0, 2.0e-6, "center right gain is not unity");

    N60SymmetryBalanceSnapshot left;
    N60SymmetryBalanceSnapshot right;
    if (!N60SymmetryBalanceDesign(-1.0, true, &left)) fail("left extreme design failed");
    if (!N60SymmetryBalanceDesign(1.0, true, &right)) fail("right extreme design failed");
    require_close(left.leftGainLinear, sqrt(2.0), 2.0e-6, "left extreme does not preserve constant power");
    require_close(left.rightGainLinear, 0.0, 2.0e-6, "left extreme does not mute right");
    require_close(right.leftGainLinear, 0.0, 2.0e-6, "right extreme does not mute left");
    require_close(right.rightGainLinear, sqrt(2.0), 2.0e-6, "right extreme does not preserve constant power");

    double previousLeft = 2.0;
    double previousRight = -1.0;
    for (int step = 0; step <= 200; ++step) {
        double position = -1.0 + (2.0 * step / 200.0);
        N60SymmetryBalanceSnapshot snapshot;
        if (!N60SymmetryBalanceDesign(position, true, &snapshot)) fail("sweep design failed");
        validate_position(position);
        if ((double)snapshot.leftGainLinear > previousLeft + 1.0e-6) fail("left gain is not monotonic");
        if ((double)snapshot.rightGainLinear < previousRight - 1.0e-6) fail("right gain is not monotonic");
        previousLeft = snapshot.leftGainLinear;
        previousRight = snapshot.rightGainLinear;
    }

    N60SymmetryBalanceSnapshot invalid;
    if (N60SymmetryBalanceDesign(NAN, true, &invalid)) fail("NaN position was accepted");
    if (N60SymmetryBalanceDesign(-1.001, true, &invalid)) fail("position below range was accepted");
    if (N60SymmetryBalanceDesign(1.001, true, &invalid)) fail("position above range was accepted");

    const double supportedRates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0};
    for (size_t index = 0; index < sizeof(supportedRates) / sizeof(supportedRates[0]); ++index) {
        (void)supportedRates[index];
        validate_position(-0.6);
        validate_position(0.0);
        validate_position(0.6);
    }

    puts("PR34 Symmetry Balance validation passed.");
    return 0;
}
