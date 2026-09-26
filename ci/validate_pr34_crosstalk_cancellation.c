#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Spatial.h"

static void fail(const char *message) {
    fprintf(stderr, "PR34 crosstalk cancellation validation failed: %s\n", message);
    exit(1);
}

static void require_close(double actual, double expected, double tolerance, const char *message) {
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) fail(message);
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        N60CrosstalkCancellationSnapshot snapshot;
        if (!N60CrosstalkCancellationDesign(rates[i], 0.5, 700.0, true, &snapshot)) {
            fail("default contract rejected at supported sample rate");
        }
        if (!N60CrosstalkCancellationSnapshotIsValid(snapshot)) fail("default snapshot invalid");
        const double expected = 1.0 - exp(-2.0 * 3.14159265358979323846 * 700.0 / rates[i]);
        require_close(snapshot.headShadowAlpha, expected, 2.0e-7, "head-shadow coefficient changed");
    }

    N60CrosstalkCancellationSnapshot low;
    N60CrosstalkCancellationSnapshot high;
    if (!N60CrosstalkCancellationDesign(48000, 0.5, 200.0, true, &low)) fail("low head-shadow design failed");
    if (!N60CrosstalkCancellationDesign(48000, 0.5, 2000.0, true, &high)) fail("high head-shadow design failed");
    if (!(high.headShadowAlpha > low.headShadowAlpha)) fail("head-shadow control is not monotonic");

    N60CrosstalkCancellationSnapshot disabled;
    if (!N60CrosstalkCancellationDesign(96000, 0.5, 700.0, false, &disabled)) fail("disabled design failed");
    if (disabled.enabled) fail("disabled flag changed");
    require_close(disabled.amount, 0.5, 1.0e-7, "disabled amount was not preserved");
    require_close(disabled.headShadowFrequencyHz, 700.0, 1.0e-7, "disabled head-shadow frequency was not preserved");

    N60CrosstalkCancellationSnapshot invalid;
    if (N60CrosstalkCancellationDesign(48000, -0.001, 700, true, &invalid)) fail("negative amount accepted");
    if (N60CrosstalkCancellationDesign(48000, 1.001, 700, true, &invalid)) fail("amount above one accepted");
    if (N60CrosstalkCancellationDesign(48000, 0.5, 199.9, true, &invalid)) fail("head-shadow frequency below range accepted");
    if (N60CrosstalkCancellationDesign(48000, 0.5, 2000.1, true, &invalid)) fail("head-shadow frequency above range accepted");
    if (N60CrosstalkCancellationDesign(0, 0.5, 700, true, &invalid)) fail("invalid sample rate accepted");
    if (N60CrosstalkCancellationDesign(48000, NAN, 700, true, &invalid)) fail("NaN amount accepted");

    // Independent feed-forward stability bound: one-pole head-shadow state remains
    // bounded by a bounded input, and |out| <= |direct| + amount*|shadow| <= 2.
    N60CrosstalkCancellationSnapshot snapshot;
    if (!N60CrosstalkCancellationDesign(48000, 1.0, 700.0, true, &snapshot)) fail("full amount design failed");
    float shadow = 0.0f;
    for (int n = 0; n < 200000; ++n) {
        float input = (n & 1) ? 1.0f : -1.0f;
        shadow += snapshot.headShadowAlpha * (input - shadow);
        if (!isfinite(shadow) || fabsf(shadow) > 1.00001f) fail("head-shadow filter became unstable");
        float output = input - snapshot.amount * shadow;
        if (!isfinite(output) || fabsf(output) > 2.00001f) fail("feed-forward output exceeded stability bound");
    }

    puts("PR34 crosstalk cancellation validation passed.");
    return 0;
}
