
#include <assert.h>
#include <math.h>
#include "N60HeadphoneDSP.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

static void run_sine_crossfeed(double frequencyHz, float *rightRMSOut) {
    N60HeadphoneDSPSnapshot snapshot = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(N60HeadphoneDSPSetCrossfeed(&snapshot, 1.0f, 30.0, 0.0875, 700.0, true));
    assert(snapshot.crossfeed.contralateralDelayFrames > 0u);
    N60HeadphoneDSPRuntime *runtime = N60HeadphoneDSPRuntimeCreate();
    assert(runtime != NULL);
    assert(N60HeadphoneDSPRuntimePrepare(runtime, &snapshot));
    double square = 0.0;
    uint32_t count = 0u;
    for (uint32_t frame = 0; frame < 8192u; ++frame) {
        float left = sinf((float)(2.0 * 3.14159265358979323846 * frequencyHz * frame / 48000.0));
        float outL = 0.0f;
        float outR = 0.0f;
        assert(N60HeadphoneDSPProcessStereoFrame(runtime, &snapshot, left, 0.0f, &outL, &outR));
        assert(isfinite(outL) && isfinite(outR));
        if (frame >= 2048u) {
            square += (double)outR * (double)outR;
            count += 1u;
        }
    }
    *rightRMSOut = (float)sqrt(square / (double)count);
    N60HeadphoneDSPRuntimeDestroy(runtime);
}

int main(void) {
    // Bypassed unity must be bit-transparent for finite samples.
    N60HeadphoneDSPSnapshot unity = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(N60HeadphoneDSPSnapshotIsValid(&unity));
    N60HeadphoneDSPRuntime *runtime = N60HeadphoneDSPRuntimeCreate();
    assert(runtime != NULL);
    assert(N60HeadphoneDSPRuntimePrepare(runtime, &unity));
    for (uint32_t frame = 0; frame < 1024u; ++frame) {
        float left = (float)frame / 1024.0f - 0.5f;
        float right = 0.25f - (float)frame / 4096.0f;
        float outL = 0.0f;
        float outR = 0.0f;
        assert(N60HeadphoneDSPProcessStereoFrame(runtime, &unity, left, right, &outL, &outR));
        assert(outL == left);
        assert(outR == right);
    }
    N60HeadphoneDSPRuntimeDestroy(runtime);

    // Device correction is independent per channel.
    N60HeadphoneDSPSnapshot correction = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(N60HeadphoneDSPSetChannelGain(&correction, 0u, 0.5f));
    assert(N60HeadphoneDSPSetChannelEQBand(
        &correction, 0u, 0u, N60BiquadFilterTypePeaking, 1000.0, 6.0, 1.0, true));
    assert(N60HeadphoneDSPSetTargetCurveKind(&correction, N60HeadphoneTargetCurveCustom));
    runtime = N60HeadphoneDSPRuntimeCreate();
    assert(runtime != NULL);
    assert(N60HeadphoneDSPRuntimePrepare(runtime, &correction));
    float outL = 0.0f;
    float outR = 0.0f;
    assert(N60HeadphoneDSPProcessStereoFrame(runtime, &correction, 1.0f, 1.0f, &outL, &outR));
    assert(isfinite(outL));
    closef(outR, 1.0f, 1.0e-7f);
    assert(fabsf(outL - outR) > 1.0e-5f);
    N60HeadphoneDSPRuntimeDestroy(runtime);

    // Independent channel delay provides channel-matching time alignment.
    N60HeadphoneDSPSnapshot delayed = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(N60HeadphoneDSPSetChannelDelayFrames(&delayed, 1u, 2u));
    runtime = N60HeadphoneDSPRuntimeCreate();
    assert(runtime != NULL);
    assert(N60HeadphoneDSPRuntimePrepare(runtime, &delayed));
    assert(N60HeadphoneDSPProcessStereoFrame(runtime, &delayed, 0.0f, 1.0f, &outL, &outR));
    closef(outR, 0.0f, 1.0e-7f);
    assert(N60HeadphoneDSPProcessStereoFrame(runtime, &delayed, 0.0f, 0.0f, &outL, &outR));
    closef(outR, 0.0f, 1.0e-7f);
    assert(N60HeadphoneDSPProcessStereoFrame(runtime, &delayed, 0.0f, 0.0f, &outL, &outR));
    closef(outR, 1.0f, 1.0e-7f);
    N60HeadphoneDSPRuntimeDestroy(runtime);

    // Headroom is explicit device/profile state and is applied before spatial mixing.
    N60HeadphoneDSPSnapshot headroom = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(N60HeadphoneDSPSetHeadroomAttenuationDB(&headroom, 6.020599913279624));
    runtime = N60HeadphoneDSPRuntimeCreate();
    assert(runtime != NULL);
    assert(N60HeadphoneDSPRuntimePrepare(runtime, &headroom));
    assert(N60HeadphoneDSPProcessStereoFrame(runtime, &headroom, 1.0f, -1.0f, &outL, &outR));
    closef(outL, 0.5f, 1.0e-5f);
    closef(outR, -0.5f, 1.0e-5f);
    N60HeadphoneDSPRuntimeDestroy(runtime);

    // Crossfeed must be frequency dependent rather than a dumb L/R mix.
    float lowRMS = 0.0f;
    float highRMS = 0.0f;
    run_sine_crossfeed(80.0, &lowRMS);
    run_sine_crossfeed(10000.0, &highRMS);
    assert(lowRMS > 0.05f);
    assert(lowRMS > highRMS * 3.0f);

    // Input validation / safety bounds.
    N60HeadphoneDSPSnapshot invalid = N60HeadphoneDSPSnapshotMakeUnity(48000.0);
    assert(!N60HeadphoneDSPSetCrossfeed(&invalid, 1.1f, 30.0, 0.0875, 700.0, true));
    assert(!N60HeadphoneDSPSetCrossfeed(&invalid, 0.5f, 5.0, 0.0875, 700.0, true));
    assert(!N60HeadphoneDSPSetChannelDelayFrames(&invalid, 0u, N60_HEADPHONE_DELAY_CAPACITY_FRAMES));
    assert(!N60HeadphoneDSPSetHeadroomAttenuationDB(&invalid, -1.0));
    return 0;
}
