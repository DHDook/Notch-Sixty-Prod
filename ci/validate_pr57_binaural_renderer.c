
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include "N60BinauralRenderer.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

static void process_impulse_until_output(
    N60BinauralRenderer *renderer,
    const float *firstFrame,
    uint32_t channels,
    float *leftOut,
    float *rightOut
) {
    float zeros[N60_MAX_PROGRAM_CHANNELS] = {0};
    float left = 0.0f;
    float right = 0.0f;
    assert(N60BinauralRendererProcessFrame(renderer, firstFrame, channels, &left, &right));
    closef(left, 0.0f, 1.0e-7f);
    closef(right, 0.0f, 1.0e-7f);
    for (uint32_t frame = 1u; frame < N60_BINAURAL_PARTITION_FRAMES; ++frame) {
        assert(N60BinauralRendererProcessFrame(renderer, zeros, channels, &left, &right));
        closef(left, 0.0f, 1.0e-7f);
        closef(right, 0.0f, 1.0e-7f);
    }
    assert(N60BinauralRendererProcessFrame(renderer, zeros, channels, &left, &right));
    *leftOut = left;
    *rightOut = right;
}

int main(void) {
    // Stereo identity-style virtual speaker profile demonstrates exact semantic routing.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor stereoProfile =
        N60BinauralProfileDescriptorMake(48000.0, stereo, N60BinauralProfileKindHRTF, 1u);
    stereoProfile.declaredLatencyFrames = 7u;
    assert(N60BinauralProfileDescriptorIsValid(&stereoProfile, N60_BINAURAL_MAX_TAPS));
    float leftIR[2] = {1.0f, 0.0f};
    float rightIR[2] = {0.0f, 1.0f};
    N60BinauralRenderer *renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    assert(N60BinauralRendererPrepareProfile(renderer, stereoProfile, leftIR, rightIR));
    assert(N60BinauralRendererLatencyFrames(renderer) == N60_BINAURAL_PARTITION_FRAMES + 7u);

    float first[2] = {0.25f, 0.75f};
    float outL = 0.0f;
    float outR = 0.0f;
    process_impulse_until_output(renderer, first, 2u, &outL, &outR);
    closef(outL, 0.25f, 1.0e-5f);
    closef(outR, 0.75f, 1.0e-5f);
    N60BinauralRendererDestroy(renderer);

    // LFE defaults to equal-ear/non-localized rendering even if its supplied IR is asymmetric.
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60BinauralProfileDescriptor fiveOneProfile =
        N60BinauralProfileDescriptorMake(48000.0, fiveOne, N60BinauralProfileKindHRTF, 1u);
    float fiveLeft[6] = {0};
    float fiveRight[6] = {0};
    fiveLeft[3] = 0.2f;
    fiveRight[3] = 0.8f;
    renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    assert(N60BinauralRendererPrepareProfile(renderer, fiveOneProfile, fiveLeft, fiveRight));
    float lfeFrame[6] = {0};
    lfeFrame[3] = 1.0f;
    process_impulse_until_output(renderer, lfeFrame, 6u, &outL, &outR);
    closef(outL, 0.5f, 1.0e-5f);
    closef(outR, 0.5f, 1.0e-5f);
    N60BinauralRendererDestroy(renderer);

    // Normalized SOFA-style measurement view selects the nearest source direction.
    double azimuth[2] = {-30.0, 30.0};
    double elevation[2] = {0.0, 0.0};
    double distance[2] = {1.0, 1.0};
    float sofaLeft[2] = {0.9f, 0.2f};
    float sofaRight[2] = {0.1f, 0.8f};
    N60SOFAHRTFNormalizedView view = {
        .sampleRate = 48000.0,
        .measurementCount = 2u,
        .tapCount = 1u,
        .azimuthDegrees = azimuth,
        .elevationDegrees = elevation,
        .distanceMeters = distance,
        .leftIR = sofaLeft,
        .rightIR = sofaRight,
    };
    assert(N60SOFAHRTFNormalizedViewIsValid(&view, N60_BINAURAL_MAX_TAPS));
    assert(N60SOFAFindNearestMeasurement(&view, stereoProfile.sources[0]) == 0);
    assert(N60SOFAFindNearestMeasurement(&view, stereoProfile.sources[1]) == 1);
    renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    stereoProfile.declaredLatencyFrames = 0u;
    assert(N60BinauralRendererPrepareFromSOFAView(renderer, stereoProfile, &view));
    float leftOnly[2] = {1.0f, 0.0f};
    process_impulse_until_output(renderer, leftOnly, 2u, &outL, &outR);
    closef(outL, 0.9f, 1.0e-5f);
    closef(outR, 0.1f, 1.0e-5f);
    N60BinauralRendererDestroy(renderer);

    // 7.1.4 / two-partition smoke test exercises the shared multichannel FFT history.
    N60ProgramChannelLayout sevenOneFour =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOneFour);
    N60BinauralProfileDescriptor immersive =
        N60BinauralProfileDescriptorMake(96000.0, sevenOneFour, N60BinauralProfileKindBRIR, 256u);
    const size_t immersiveTaps = (size_t)sevenOneFour.channelCount * immersive.tapCount;
    float *immersiveLeft = (float *)calloc(immersiveTaps, sizeof(float));
    float *immersiveRight = (float *)calloc(immersiveTaps, sizeof(float));
    assert(immersiveLeft != NULL && immersiveRight != NULL);
    for (uint32_t channel = 0; channel < sevenOneFour.channelCount; ++channel) {
        immersiveLeft[(size_t)channel * immersive.tapCount] = 0.02f * (float)(channel + 1u);
        immersiveRight[(size_t)channel * immersive.tapCount] = 0.01f * (float)(channel + 1u);
        immersiveLeft[(size_t)channel * immersive.tapCount + 180u] = 0.001f;
        immersiveRight[(size_t)channel * immersive.tapCount + 180u] = -0.001f;
    }
    renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    assert(N60BinauralRendererPrepareProfile(renderer, immersive, immersiveLeft, immersiveRight));
    float immersiveInput[N60_MAX_PROGRAM_CHANNELS] = {0};
    for (uint32_t channel = 0; channel < sevenOneFour.channelCount; ++channel) immersiveInput[channel] = 0.1f;
    for (uint32_t frame = 0; frame < 512u; ++frame) {
        float left = 0.0f, right = 0.0f;
        assert(N60BinauralRendererProcessFrame(
            renderer,
            frame == 0u ? immersiveInput : (float[N60_MAX_PROGRAM_CHANNELS]){0},
            sevenOneFour.channelCount,
            &left,
            &right
        ));
        assert(isfinite(left) && isfinite(right));
    }
    N60BinauralRendererDestroy(renderer);
    free(immersiveRight);
    free(immersiveLeft);

    // Invalid/non-finite profile material is rejected before publication.
    renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    float badLeft[2] = {NAN, 0.0f};
    assert(!N60BinauralRendererPrepareProfile(renderer, stereoProfile, badLeft, rightIR));
    assert(!N60BinauralRendererProcessFrame(renderer, first, 2u, &outL, &outR));
    N60BinauralRendererDestroy(renderer);
    return 0;
}
