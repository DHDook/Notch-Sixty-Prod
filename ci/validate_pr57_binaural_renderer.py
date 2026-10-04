#!/usr/bin/env python3
"""Permanent PR57 guard for the multichannel binaural renderer and SOFA boundary."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
PROFILE = REALTIME / "N60BinauralProfile.h"
RENDERER = REALTIME / "N60BinauralRenderer.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR57 validation failed: {message}")


def main() -> None:
    require(PROFILE.exists(), "N60BinauralProfile.h is missing")
    require(RENDERER.exists(), "N60BinauralRenderer.h is missing")
    profile = PROFILE.read_text(encoding="utf-8")
    renderer = RENDERER.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("N60SOFAHRTFNormalizedView" in profile, "SOFA-normalized HRIR boundary is missing")
    require("N60SOFAFindNearestMeasurement" in profile, "SOFA direction selection is missing")
    require("N60BinauralLFEModeEqualEar" in profile, "non-localized LFE policy is missing")
    require("N60_BINAURAL_MAX_TAPS 8192u" in renderer, "binaural tap budget changed")
    require("N60BinauralRendererPrepareFromSOFAView" in renderer, "SOFA-view preparation is missing")
    require("N60BinauralRendererProcessFrame" in renderer, "realtime binaural processor is missing")
    require("same input spectrum is shared" in renderer, "shared-input FFT architecture note is missing")
    require('#import "N60BinauralRenderer.h"' in bridge, "binaural renderer ABI is not exposed to Swift")

    process_tail = renderer.split("static inline bool N60BinauralRendererProcessFrame", 1)[1]
    require("calloc(" not in process_tail.split("#ifdef __cplusplus", 1)[0], "realtime ProcessFrame allocates")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    harness = r'''
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
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr57-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "binaural_renderer_test.c"
        binary = temp / "binaural_renderer_test"
        source.write_text(harness, encoding="utf-8")
        subprocess.run([
            clang, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{REALTIME}", str(source), "-lm", "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True)

    print("PR57 binaural renderer validation passed")


if __name__ == "__main__":
    main()
