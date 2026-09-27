#include "N60SpectralDenoiser.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static N60SpectralDenoiserSnapshot make_snapshot(double sampleRate, N60DenoiserQuality quality) {
    N60SpectralDenoiserSnapshot snapshot = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);
    if (!N60SpectralDenoiserSnapshotConfigure(
            &snapshot,
            sampleRate,
            true,
            N60DenoiserTuningStandard,
            quality,
            0.65f,
            -30.0f,
            false,
            0.0f,
            150.0f,
            0u,
            N60DenoiserProfileCommandNone)) {
        fprintf(stderr, "snapshot configure failed\n");
        exit(2);
    }
    return snapshot;
}

static float signal(uint64_t index, float scale, double divisor) {
    return scale * (float)(sin((double)index / divisor) + 0.37 * cos((double)index / (divisor * 0.61)));
}

static void process_one(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    uint64_t index,
    float scale,
    float *left,
    float *right
) {
    float inLeft = signal(index, scale, 17.0);
    float inRight = signal(index + 37u, scale * 0.83f, 23.0);
    N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, snapshot.sampleRate, inLeft, inRight, left, right);
}

static void require_close(float lhs, float rhs, const char *label, uint64_t index) {
    float tolerance = 2.0e-6f + 2.0e-6f * fmaxf(fabsf(lhs), fabsf(rhs));
    if (!isfinite(lhs) || !isfinite(rhs) || fabsf(lhs - rhs) > tolerance) {
        fprintf(stderr, "%s mismatch at %llu: %.9g vs %.9g\n", label, (unsigned long long)index, lhs, rhs);
        exit(3);
    }
}

static void compare_after_public_reset(double sampleRate) {
    N60SpectralDenoiserRuntime *dirty = N60SpectralDenoiserCreate();
    N60SpectralDenoiserRuntime *fresh = N60SpectralDenoiserCreate();
    if (!dirty || !fresh) exit(4);

    N60SpectralDenoiserSnapshot high = make_snapshot(sampleRate, N60DenoiserQualityHigh);
    for (uint64_t i = 0; i < 14000u; ++i) {
        float l = 0.0f, r = 0.0f;
        process_one(dirty, high, i, 0.25f, &l, &r);
    }
    N60SpectralDenoiserReset(dirty);

    for (uint64_t i = 0; i < 150000u; ++i) {
        float dirtyL = 0.0f, dirtyR = 0.0f, freshL = 0.0f, freshR = 0.0f;
        process_one(dirty, high, i + 200000u, 0.001f, &dirtyL, &dirtyR);
        process_one(fresh, high, i + 200000u, 0.001f, &freshL, &freshR);
        require_close(dirtyL, freshL, "reset left", i);
        require_close(dirtyR, freshR, "reset right", i);
    }

    N60SpectralDenoiserTelemetry dirtyTelemetry = N60SpectralDenoiserRuntimeTelemetry(dirty);
    N60SpectralDenoiserTelemetry freshTelemetry = N60SpectralDenoiserRuntimeTelemetry(fresh);
    if (dirtyTelemetry.profileReady != freshTelemetry.profileReady
        || dirtyTelemetry.capturedProfile != freshTelemetry.capturedProfile
        || dirtyTelemetry.spectralFramesProcessed != freshTelemetry.spectralFramesProcessed) {
        fprintf(stderr, "public reset telemetry diverged\n");
        exit(5);
    }

    N60SpectralDenoiserDestroy(dirty);
    N60SpectralDenoiserDestroy(fresh);
}

static void compare_after_quality_change(double sampleRate) {
    N60SpectralDenoiserRuntime *dirty = N60SpectralDenoiserCreate();
    N60SpectralDenoiserRuntime *fresh = N60SpectralDenoiserCreate();
    if (!dirty || !fresh) exit(6);

    N60SpectralDenoiserSnapshot high = make_snapshot(sampleRate, N60DenoiserQualityHigh);
    N60SpectralDenoiserSnapshot ultra = make_snapshot(sampleRate, N60DenoiserQualityUltra);

    for (uint64_t i = 0; i < 18000u; ++i) {
        float l = 0.0f, r = 0.0f;
        process_one(dirty, high, i, 0.32f, &l, &r);
    }

    for (uint64_t i = 0; i < 170000u; ++i) {
        float dirtyL = 0.0f, dirtyR = 0.0f, freshL = 0.0f, freshR = 0.0f;
        process_one(dirty, ultra, i + 400000u, 0.0012f, &dirtyL, &dirtyR);
        process_one(fresh, ultra, i + 400000u, 0.0012f, &freshL, &freshR);
        require_close(dirtyL, freshL, "quality left", i);
        require_close(dirtyR, freshR, "quality right", i);
    }

    N60SpectralDenoiserTelemetry dirtyTelemetry = N60SpectralDenoiserRuntimeTelemetry(dirty);
    N60SpectralDenoiserTelemetry freshTelemetry = N60SpectralDenoiserRuntimeTelemetry(fresh);
    if (dirtyTelemetry.fftSize != 4096u || freshTelemetry.fftSize != 4096u
        || dirtyTelemetry.profileReady != freshTelemetry.profileReady
        || dirtyTelemetry.spectralFramesProcessed != freshTelemetry.spectralFramesProcessed) {
        fprintf(stderr, "quality transition telemetry diverged\n");
        exit(7);
    }

    N60SpectralDenoiserDestroy(dirty);
    N60SpectralDenoiserDestroy(fresh);
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        compare_after_public_reset(rates[i]);
        compare_after_quality_change(rates[i]);
    }
    puts("PR35 denoiser bounded reset equivalence: PASS");
    return 0;
}
