#include "N60SpectralDenoiser.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static float test_signal(uint64_t index, float scale, double divisor) {
    return scale * (float)(sin((double)index / divisor) + 0.31 * cos((double)index / (divisor * 0.73)));
}

static N60SpectralDenoiserSnapshot make_snapshot(double rate, bool enabled, uint32_t revision) {
    N60SpectralDenoiserSnapshot snapshot = N60SpectralDenoiserSnapshotMakeBypassed(rate);
    if (!N60SpectralDenoiserSnapshotConfigure(
            &snapshot, rate, enabled, N60DenoiserTuningStandard, N60DenoiserQualityQuality,
            0.7f, -48.0f, true, 0.0f, 180.0f,
            revision, revision == 1u ? N60DenoiserProfileCommandCapture : N60DenoiserProfileCommandNone)) {
        fprintf(stderr, "configure failed\n");
        exit(2);
    }
    return snapshot;
}

static void require_close(float a, float b, const char *label, uint64_t frame) {
    float tolerance = 2.0e-6f + 2.0e-6f * fmaxf(fabsf(a), fabsf(b));
    if (!isfinite(a) || !isfinite(b) || fabsf(a - b) > tolerance) {
        fprintf(stderr, "%s mismatch at %llu: %.9g vs %.9g\n", label, (unsigned long long)frame, a, b);
        exit(3);
    }
}

static void compare_paths(double rate, bool enabled) {
    N60SpectralDenoiserRuntime *safe = N60SpectralDenoiserCreate();
    N60SpectralDenoiserRuntime *fast = N60SpectralDenoiserCreate();
    if (!safe || !fast) exit(4);

    N60SpectralDenoiserSnapshot snapshot = make_snapshot(rate, enabled, 1u);
    for (uint64_t frame = 0; frame < 90000u; ++frame) {
        float inputL = test_signal(frame, 0.035f, 19.0);
        float inputR = test_signal(frame + 53u, 0.021f, 27.0);
        float safeL = 0.0f, safeR = 0.0f, fastL = 0.0f, fastR = 0.0f;
        N60SpectralDenoiserProcessStereoFrame(safe, snapshot, rate, inputL, inputR, &safeL, &safeR);
        N60SpectralDenoiserProcessStereoFrameValidated(fast, &snapshot, rate, inputL, inputR, &fastL, &fastR);
        require_close(safeL, fastL, "left", frame);
        require_close(safeR, fastR, "right", frame);
    }

    N60SpectralDenoiserTelemetry a = N60SpectralDenoiserRuntimeTelemetry(safe);
    N60SpectralDenoiserTelemetry b = N60SpectralDenoiserRuntimeTelemetry(fast);
    if (a.profileReady != b.profileReady
        || a.capturedProfile != b.capturedProfile
        || a.captureActive != b.captureActive
        || a.spectralFramesProcessed != b.spectralFramesProcessed
        || fabsf(a.meanSuppressionDB - b.meanSuppressionDB) > 1.0e-6f
        || fabsf(a.maxSuppressionDB - b.maxSuppressionDB) > 1.0e-6f) {
        fprintf(stderr, "telemetry mismatch at %.0f Hz enabled=%d\n", rate, enabled ? 1 : 0);
        exit(5);
    }

    N60SpectralDenoiserDestroy(safe);
    N60SpectralDenoiserDestroy(fast);
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        compare_paths(rates[i], false);
        compare_paths(rates[i], true);
    }
    puts("PR35 denoiser validated fast path equivalence: PASS");
    return 0;
}
