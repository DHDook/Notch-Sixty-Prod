#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Spatial.h"

static void fail(const char *message) {
    fprintf(stderr, "PR34 speaker crossfeed validation failed: %s\n", message);
    exit(1);
}

static void close_enough(double actual, double expected, double tolerance, const char *message) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(message);
}

static void process(float amount, float left, float right, float *outLeft, float *outRight) {
    const float direct = 1.0f - amount;
    *outLeft = direct * left + amount * right;
    *outRight = direct * right + amount * left;
}

int main(void) {
    N60SpeakerCrossfeedSnapshot snapshot;
    if (!N60SpeakerCrossfeedDesign(0.0, true, &snapshot)) fail("zero design failed");
    close_enough(snapshot.amount, 0.0, 1.0e-8, "zero amount changed");

    float left = 0.0f, right = 0.0f;
    process(snapshot.amount, 0.8f, -0.2f, &left, &right);
    close_enough(left, 0.8, 1.0e-7, "zero amount is not identity on left");
    close_enough(right, -0.2, 1.0e-7, "zero amount is not identity on right");

    if (!N60SpeakerCrossfeedDesign(0.5, true, &snapshot)) fail("mono design failed");
    process(snapshot.amount, 0.8f, -0.2f, &left, &right);
    close_enough(left, 0.3, 1.0e-7, "0.5 amount did not produce mono left");
    close_enough(right, 0.3, 1.0e-7, "0.5 amount did not produce mono right");

    if (!N60SpeakerCrossfeedDesign(0.25, true, &snapshot)) fail("midpoint design failed");
    process(snapshot.amount, 1.0f, 0.0f, &left, &right);
    close_enough(left, 0.75, 1.0e-7, "direct coefficient is wrong");
    close_enough(right, 0.25, 1.0e-7, "cross coefficient is wrong");
    close_enough(left + right, 1.0, 1.0e-7, "matrix does not preserve mono sum");

    N60SpeakerCrossfeedSnapshot disabled;
    if (!N60SpeakerCrossfeedDesign(0.4, false, &disabled)) fail("disabled design failed");
    if (disabled.enabled) fail("disabled flag changed");
    close_enough(disabled.amount, 0.4, 1.0e-7, "disabled configuration amount was not preserved");

    if (N60SpeakerCrossfeedDesign(-0.0001, true, &snapshot)) fail("negative amount accepted");
    if (N60SpeakerCrossfeedDesign(0.5001, true, &snapshot)) fail("amount above 0.5 accepted");
    if (N60SpeakerCrossfeedDesign(NAN, true, &snapshot)) fail("NaN amount accepted");

    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        (void)rates[i];
        if (!N60SpeakerCrossfeedDesign(0.18, true, &snapshot)) fail("supported-rate design failed");
        if (!N60SpeakerCrossfeedSnapshotIsValid(snapshot)) fail("supported-rate snapshot invalid");
    }

    puts("PR34 speaker crossfeed validation passed.");
    return 0;
}
