#!/usr/bin/env python3
"""Permanent PR66 guard for live head tracking and dual-generation binaural swaps."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
RUNTIME = REALTIME / "N60HeadTrackedBinauralRuntime.h"
BRIDGE = REALTIME / "N60BinauralHeadphoneBridge.h"
ASSET = ROOT / "NotchSixty/Audio/Routing/BinauralProfileAsset.swift"
PROFILE = ROOT / "NotchSixty/Audio/Routing/HeadphoneDeviceProfileConfiguration.swift"
CONTROLLER = ROOT / "NotchSixty/Audio/HeadTrackingController.swift"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
UI = ROOT / "NotchSixty/UI/ProductionHeadphoneWorkspace.swift"
PBX = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
BRIDGING = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR66 validation failed: {message}")


def main() -> None:
    for path in (RUNTIME, BRIDGE, ASSET, PROFILE, CONTROLLER, SESSION, ENGINE, UI, PBX, BRIDGING):
        require(path.exists(), f"{path.name} is missing")

    runtime = RUNTIME.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    asset = ASSET.read_text(encoding="utf-8")
    profile = PROFILE.read_text(encoding="utf-8")
    controller = CONTROLLER.read_text(encoding="utf-8")
    session = SESSION.read_text(encoding="utf-8")
    engine = ENGINE.read_text(encoding="utf-8")
    ui = UI.read_text(encoding="utf-8")
    pbx = PBX.read_text(encoding="utf-8")
    bridging = BRIDGING.read_text(encoding="utf-8")

    require("renderers[2]" in runtime, "dual prepared renderer generations are missing")
    require("N60HeadPoseAtomic poseAtomic" in runtime, "coherent pose publication is missing")
    require("N60HeadTrackedBinauralRuntimePrepareGeneration" in runtime, "off-thread generation preparation is missing")
    require("warmupFramesRemaining" in runtime, "live-history warmup is missing")
    require("N60SpatialCrossfadeProcessStereo" in runtime, "click-free generation crossfade is missing")
    require("N60HeadTrackedBinauralRuntimeBeginBuffer" in bridge, "buffer-boundary generation adoption is missing")
    require("N60HeadTrackedBinauralRuntimeProcessFrame" in bridge, "live bridge is not using the tracked renderer")
    require("N60BinauralHeadphoneBridgePrepareTrackedGeneration" in bridge, "bridge control-plane generation API is missing")
    require("N60BinauralProfileDescriptorApplyHeadPose" in asset, "head-relative HRTF lookup is missing")
    require("headPose: N60HeadPose" in asset, "pose-specific spatial profile preparation is missing")
    require("var headTracking: HeadTrackingConfiguration?" in profile, "backward-compatible optional tracking policy is missing")
    require("headTrackingRequiresVirtualSpeakers" in profile, "tracking mode validation is missing")
    require("CMHeadphoneMotionManager" in controller, "Apple headphone motion provider is missing")
    require("fallbackToStaticSpatial" in controller, "static-spatial fallback policy is missing")
    require("angularUpdateThresholdDegrees" in controller and "maximumUpdateRateHz" in controller,
            "head-pose hysteresis/rate limiting is missing")
    require("prepareHeadTrackedGeneration" in session, "session generation publication API is missing")
    require("headTrackingController: SpatialHeadTrackingController?" in engine, "engine does not retain the tracking controller")
    require("headTrackingRuntimeStatus" in engine, "tracking runtime status is missing")
    require("recenterHeadTracking" in engine, "engine recenter API is missing")
    require("controller.stop()" in engine and engine.index("controller.stop()") < engine.index("session.stop(fadeOut: fadeOut)", engine.index("private func tearDownTransport")),
            "tracking controller must stop before realtime session destruction")
    require("Head Tracking" in ui and "Recenter" in ui, "head-tracking product controls are missing")
    require("INFOPLIST_KEY_NSMotionUsageDescription" in pbx, "motion privacy usage description is missing")
    require("HeadTrackingController.swift in Sources" in pbx, "head-tracking controller is not in the app target")
    require('#import "N60HeadTrackedBinauralRuntime.h"' in bridging, "tracked runtime is not bridged to Swift")

    begin = runtime.split("static inline void N60HeadTrackedBinauralRuntimeBeginBuffer", 1)[1]
    begin = begin.split("static inline bool N60HeadTrackedBinauralRuntimeProcessFrame", 1)[0]
    process = runtime.split("static inline bool N60HeadTrackedBinauralRuntimeProcessFrame", 1)[1]
    process = process.split("static inline uint64_t N60HeadTrackedBinauralRuntimeLatencyFrames", 1)[0]
    for name, body in (("begin-buffer", begin), ("process-frame", process)):
        for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf(", "fopen(", "pthread_mutex", "cos(", "sin(", "atan2(", "asin("):
            require(forbidden not in body, f"{name} performs forbidden realtime work: {forbidden}")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    harness = r'''
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include "N60HeadTrackedBinauralRuntime.h"

static void close_double(double actual, double expected, double tolerance) {
    assert(fabs(actual - expected) <= tolerance);
}

int main(void) {
    N60ProgramChannelLayout stereo =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor descriptor = N60BinauralProfileDescriptorMake(
        48000.0, stereo, N60BinauralProfileKindHRTF, 1u
    );
    float leftIR[2] = {1.0f, 0.2f};
    float rightIR[2] = {0.2f, 1.0f};
    N60HeadTrackedBinauralRuntime *runtime = N60HeadTrackedBinauralRuntimeCreate(
        descriptor, leftIR, rightIR
    );
    assert(runtime != NULL);
    assert(N60HeadTrackedBinauralRuntimePoseIsLockFree(runtime));
    assert(N60HeadTrackedBinauralRuntimeCanPrepareGeneration(runtime));

    float input[2] = {0.5f, -0.25f};
    float left = 0.0f, right = 0.0f;
    assert(N60HeadTrackedBinauralRuntimeProcessFrame(
        runtime, input, 2u, &left, &right
    ));

    N60HeadPose pose = {
        .yawDegrees = 30.0,
        .pitchDegrees = -5.0,
        .rollDegrees = 2.0,
    };
    float nextLeftIR[2] = {0.8f, 0.3f};
    float nextRightIR[2] = {0.3f, 0.8f};
    assert(N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        descriptor,
        nextLeftIR,
        nextRightIR,
        pose,
        2u,
        4u
    ));
    assert(!N60HeadTrackedBinauralRuntimeCanPrepareGeneration(runtime));
    assert(!N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        descriptor,
        nextLeftIR,
        nextRightIR,
        pose,
        0u,
        4u
    ));

    N60HeadTrackedBinauralRuntimeBeginBuffer(runtime);
    for (uint32_t frame = 0; frame < 8u; ++frame) {
        assert(N60HeadTrackedBinauralRuntimeProcessFrame(
            runtime, input, 2u, &left, &right
        ));
    }
    N60HeadTrackedBinauralSnapshot snapshot =
        N60HeadTrackedBinauralRuntimeGetSnapshot(runtime);
    assert(snapshot.acceptedGenerations == 1u);
    assert(snapshot.completedTransitions == 1u);
    assert(snapshot.rejectedGenerations >= 1u);
    assert(!snapshot.transitionBusy);
    assert(snapshot.activeRendererIndex == 1u);
    close_double(snapshot.currentPose.yawDegrees, 30.0, 0.0011);
    close_double(snapshot.currentPose.pitchDegrees, -5.0, 0.0011);
    close_double(snapshot.currentPose.rollDegrees, 2.0, 0.0011);

    N60BinauralProfileDescriptor incompatible = descriptor;
    incompatible.sampleRate = 44100.0;
    assert(!N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        incompatible,
        nextLeftIR,
        nextRightIR,
        pose,
        0u,
        4u
    ));

    N60HeadTrackedBinauralRuntimeDestroy(runtime);
    return 0;
}
'''

    with tempfile.TemporaryDirectory() as directory:
        directory = pathlib.Path(directory)
        source = directory / "pr66.c"
        binary = directory / "pr66"
        source.write_text(harness, encoding="utf-8")
        subprocess.run([
            clang,
            "-std=c11",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{REALTIME}",
            str(source),
            "-lm",
            "-o",
            str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)

    print("PR66 head-tracking validation passed")


if __name__ == "__main__":
    main()
