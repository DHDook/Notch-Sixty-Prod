#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Protection.h"

static float test_sample(uint32_t frame, float phaseOffset) {
    const float a = 0.42f * sinf(0.017f * (float)frame + phaseOffset);
    const float b = 0.19f * sinf(0.071f * (float)frame + 0.31f + phaseOffset);
    return a + b;
}

static int nearly_equal(float a, float b, float tolerance) {
    return fabsf(a - b) <= tolerance;
}

static void dirty_runtime(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot
) {
    N60ProtectionRuntimeBeginBuffer(runtime);
    for (uint32_t frame = 0; frame < 12000u; ++frame) {
        float left = test_sample(frame, 0.0f);
        float right = test_sample(frame, 0.73f);
        N60ProtectionProcessStereoFrame(runtime, snapshot, &left, &right);
    }
}

int main(void) {
    const double sampleRate = 48000.0;
    N60ProtectionSnapshot snapshot = N60ProtectionSnapshotMakeBypassed(sampleRate);
    if (!N60ProtectionSnapshotSetOversamplingFactor(&snapshot, N60OversamplingFactor4x)) {
        fprintf(stderr, "failed to configure 4x oversampling\n");
        return 1;
    }
    if (!N60ProtectionSnapshotSetLimiterAdvanced(
            &snapshot,
            true,
            -1.0f,
            0.1f,
            50.0f,
            20.0f,
            true)) {
        fprintf(stderr, "failed to configure limiter\n");
        return 1;
    }
    if (!N60ProtectionSnapshotSetGainRider(
            &snapshot,
            true,
            3.0f,
            6.0f,
            N60GainRiderSpeedFast)) {
        fprintf(stderr, "failed to configure gain rider\n");
        return 1;
    }

    N60ProtectionRuntime *dirty = N60ProtectionRuntimeCreate();
    N60ProtectionRuntime *fresh = N60ProtectionRuntimeCreate();
    if (dirty == NULL || fresh == NULL) {
        fprintf(stderr, "failed to allocate protection runtimes\n");
        N60ProtectionRuntimeDestroy(dirty);
        N60ProtectionRuntimeDestroy(fresh);
        return 1;
    }

    dirty_runtime(dirty, &snapshot);
    N60ProtectionRuntimeReset(dirty);
    N60ProtectionRuntimeReset(fresh);
    N60ProtectionRuntimeBeginBuffer(dirty);
    N60ProtectionRuntimeBeginBuffer(fresh);

    for (uint32_t frame = 0; frame < 12000u; ++frame) {
        float dirtyLeft = test_sample(frame, 1.11f);
        float dirtyRight = test_sample(frame, 1.89f);
        float freshLeft = dirtyLeft;
        float freshRight = dirtyRight;

        N60ProtectionProcessStereoFrame(dirty, &snapshot, &dirtyLeft, &dirtyRight);
        N60ProtectionProcessStereoFrame(fresh, &snapshot, &freshLeft, &freshRight);

        if (!nearly_equal(dirtyLeft, freshLeft, 1.0e-7f)
            || !nearly_equal(dirtyRight, freshRight, 1.0e-7f)) {
            fprintf(stderr,
                    "reset mismatch at frame %u: dirty=(%.9g, %.9g) fresh=(%.9g, %.9g)\n",
                    frame, dirtyLeft, dirtyRight, freshLeft, freshRight);
            N60ProtectionRuntimeDestroy(dirty);
            N60ProtectionRuntimeDestroy(fresh);
            return 1;
        }
    }

    N60ProtectionTelemetry a = N60ProtectionRuntimeTelemetry(dirty);
    N60ProtectionTelemetry b = N60ProtectionRuntimeTelemetry(fresh);
    if (!nearly_equal(a.inputTruePeakLinear, b.inputTruePeakLinear, 1.0e-7f)
        || !nearly_equal(a.outputTruePeakLinear, b.outputTruePeakLinear, 1.0e-7f)
        || !nearly_equal(a.limiterGainReductionDB, b.limiterGainReductionDB, 1.0e-7f)
        || a.limiterSafetyClampSamples != b.limiterSafetyClampSamples
        || !nearly_equal(a.gainRiderAttenuationDB, b.gainRiderAttenuationDB, 1.0e-7f)
        || !nearly_equal(a.sustainedLimiterGainReductionDB, b.sustainedLimiterGainReductionDB, 1.0e-7f)
        || a.truePeakGuardActive != b.truePeakGuardActive) {
        fprintf(stderr, "telemetry mismatch after dirty reset vs fresh runtime\n");
        N60ProtectionRuntimeDestroy(dirty);
        N60ProtectionRuntimeDestroy(fresh);
        return 1;
    }

    N60ProtectionRuntimeDestroy(dirty);
    N60ProtectionRuntimeDestroy(fresh);
    puts("PR35 protection sparse reset equivalence: PASS");
    return 0;
}
