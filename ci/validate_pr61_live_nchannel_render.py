#!/usr/bin/env python3
"""Permanent PR61 guard for the live-capable semantic N-channel DSP/render bridge."""

from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
PIPELINE = REALTIME / "N60NChannelDSPPipeline.h"
BRIDGE_HEADER = REALTIME / "N60NChannelRenderBridge.h"
SWIFT_BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR61 validation failed: {message}")


def compile_and_run(clang: str, source_text: str, name: str) -> None:
    with tempfile.TemporaryDirectory(prefix=f"notch-sixty-pr61-{name}-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / f"{name}.c"
        binary = temp / name
        source.write_text(source_text, encoding="utf-8")
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


def main() -> None:
    for path in (PIPELINE, BRIDGE_HEADER, SWIFT_BRIDGE):
        require(path.exists(), f"{path.name} is missing")
    pipeline = PIPELINE.read_text(encoding="utf-8")
    bridge = BRIDGE_HEADER.read_text(encoding="utf-8")
    swift_bridge = SWIFT_BRIDGE.read_text(encoding="utf-8")

    require("semantic LFE lane must never be emitted" in pipeline, "LFE/sub distinction guard is missing")
    require("N60ProgramLaneProcessFrame" in pipeline, "PR54 lane engine is not integrated")
    require("N60MultichannelBassManagementProcessFrame" in pipeline, "PR55 bass management is not integrated")
    require("freezes DSP state" in bridge, "underrun DSP-state policy is missing")
    require("N60NChannelCaptureIOProc" in bridge and "N60NChannelOutputIOProc" in bridge,
            "live Core Audio callbacks are missing")
    require("route.role == N60ProgramChannelRoleLowFrequencyEffects" in bridge,
            "physical output map does not reject semantic LFE speaker routes")
    require('#import "N60NChannelDSPPipeline.h"' in swift_bridge, "pipeline ABI is not exposed to Swift")
    require('#import "N60NChannelRenderBridge.h"' in swift_bridge, "render bridge ABI is not exposed to Swift")

    process = pipeline.split("static inline bool N60NChannelDSPPipelineProcessFrame", 1)[1]
    process = process.split("static inline N60ProgramLaneMeterReading", 1)[0]
    require("malloc(" not in process and "calloc(" not in process and "free(" not in process,
            "DSP frame processing allocates")
    output_process = bridge.split("static inline bool N60NChannelRenderBridgeProcessOutputBuffer", 1)[1]
    output_process = output_process.split("static inline N60NChannelRenderBridgeSnapshot", 1)[0]
    require("malloc(" not in output_process and "calloc(" not in output_process and "free(" not in output_process,
            "Core Audio output processing allocates")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    portable = r'''
#include <assert.h>
#include <math.h>
#include "N60NChannelDSPPipeline.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

int main(void) {
    // Stereo uses the generalized lanes with no bass-management stage.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot stereoLanes = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphSetGain(&stereoLanes, 0u, 0.5f));
    assert(N60ProgramLaneGraphFinalize(&stereoLanes));
    N60NChannelDSPPipelineSnapshot stereoPipeline = {
        .sampleRate = 48000.0,
        .layout = stereo,
        .laneGraph = stereoLanes,
        .bassManagementEnabled = false,
    };
    assert(N60NChannelDSPPipelineSnapshotIsValid(&stereoPipeline));
    N60NChannelDSPPipelineRuntime *runtime = N60NChannelDSPPipelineRuntimeCreate();
    assert(runtime != NULL);
    assert(N60NChannelDSPPipelineRuntimePrepare(runtime, &stereoPipeline));
    float stereoInput[2] = {1.0f, 1.0f};
    N60AcousticOutputFrame stereoOutput = {0};
    assert(N60NChannelDSPPipelineProcessFrame(runtime, &stereoPipeline, stereoInput, &stereoOutput));
    closef(stereoOutput.programSpeakers[0], 0.5f, 1.0e-7f);
    closef(stereoOutput.programSpeakers[1], 1.0f, 1.0e-7f);
    assert(stereoOutput.subwooferCount == 0u);
    N60ProgramLaneMeterReading meter = N60NChannelDSPPipelineMeterReading(runtime);
    assert(meter.channelCount == 2u && meter.peak[0] >= 0.5f && meter.peak[1] >= 1.0f);
    N60NChannelDSPPipelineRuntimeDestroy(runtime);

    // A layout containing native LFE is invalid unless PR55 consumes it into physical Sub N.
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60ProgramLaneGraphSnapshot fiveOneLanes = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, fiveOne);
    assert(N60ProgramLaneGraphFinalize(&fiveOneLanes));
    N60NChannelDSPPipelineSnapshot invalid = {
        .sampleRate = 48000.0,
        .layout = fiveOne,
        .laneGraph = fiveOneLanes,
        .bassManagementEnabled = false,
    };
    assert(!N60NChannelDSPPipelineSnapshotIsValid(&invalid));

    N60MultichannelBassManagementSnapshot bass =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 1u);
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 0u, 1.0f));
    N60NChannelDSPPipelineSnapshot surround = {
        .sampleRate = 48000.0,
        .layout = fiveOne,
        .laneGraph = fiveOneLanes,
        .bassManagementEnabled = true,
        .bassManagement = bass,
    };
    assert(N60NChannelDSPPipelineSnapshotIsValid(&surround));
    runtime = N60NChannelDSPPipelineRuntimeCreate();
    assert(runtime != NULL);
    assert(N60NChannelDSPPipelineRuntimePrepare(runtime, &surround));
    float surroundInput[6] = {0};
    surroundInput[3] = 1.0f; // semantic native LFE
    N60AcousticOutputFrame surroundOutput = {0};
    assert(N60NChannelDSPPipelineProcessFrame(runtime, &surround, surroundInput, &surroundOutput));
    closef(surroundOutput.programSpeakers[3], 0.0f, 1.0e-7f);
    assert(surroundOutput.subwooferCount == 1u);
    closef(surroundOutput.subwoofers[0], 1.0f, 1.0e-7f);
    N60NChannelDSPPipelineRuntimeDestroy(runtime);
    return 0;
}
'''
    compile_and_run(clang, portable, "nchannel_pipeline")

    if platform.system() == "Darwin":
        apple = r'''
#include <assert.h>
#include <math.h>
#include <string.h>
#include "N60NChannelRenderBridge.h"

static void closef(float actual, float expected) {
    assert(fabsf(actual - expected) <= 1.0e-7f);
}

int main(void) {
    // Stereo live render: semantic L/R deliberately map to reversed physical channels.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramTransport *transport = N60ProgramTransportCreate(4u, stereo);
    assert(transport != NULL);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphFinalize(&lanes));
    N60NChannelDSPPipelineSnapshot pipeline = {
        .sampleRate = 48000.0,
        .layout = stereo,
        .laneGraph = lanes,
        .bassManagementEnabled = false,
    };
    N60AcousticOutputRoute stereoRoutes[2] = {
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleFrontLeft, UINT32_MAX, 1u},
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleFrontRight, UINT32_MAX, 0u},
    };
    N60AcousticOutputMap stereoMap = {0};
    assert(N60AcousticOutputMapCompile(stereo, 0u, 2u, stereoRoutes, 2u, &stereoMap));
    N60NChannelRenderBridge *render = N60NChannelRenderBridgeCreate(transport, pipeline, stereoMap);
    assert(render != NULL);

    N60ProgramTransportFrame frame = {0};
    frame.channels[0] = 0.25f;
    frame.channels[1] = 0.75f;
    assert(N60ProgramTransportEnqueueFrame(transport, &frame));
    float stereoHardware[4] = {9,9,9,9};
    AudioBufferList stereoABL = {0};
    stereoABL.mNumberBuffers = 1u;
    stereoABL.mBuffers[0].mNumberChannels = 2u;
    stereoABL.mBuffers[0].mDataByteSize = sizeof(stereoHardware);
    stereoABL.mBuffers[0].mData = stereoHardware;
    assert(N60NChannelRenderBridgeProcessOutputBuffer(render, &stereoABL));
    closef(stereoHardware[0], 0.75f);
    closef(stereoHardware[1], 0.25f);
    closef(stereoHardware[2], 0.0f); // underrun frame is silent
    closef(stereoHardware[3], 0.0f);
    N60NChannelRenderBridgeSnapshot renderSnapshot = N60NChannelRenderBridgeGetSnapshot(render);
    assert(renderSnapshot.processedFrames == 1u);
    assert(renderSnapshot.silentUnderrunFrames == 1u);
    N60ProgramTransportSnapshot transportSnapshot = N60ProgramTransportGetSnapshot(transport);
    assert(transportSnapshot.underrunFrames == 1u);
    N60NChannelRenderBridgeDestroy(render);
    N60ProgramTransportDestroy(transport);

    // 5.1 live render: semantic LFE is consumed into a physical sub route, never a speaker route.
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    transport = N60ProgramTransportCreate(2u, fiveOne);
    assert(transport != NULL);
    lanes = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, fiveOne);
    assert(N60ProgramLaneGraphFinalize(&lanes));
    N60MultichannelBassManagementSnapshot bass =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 1u);
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 0u, 1.0f));
    pipeline = (N60NChannelDSPPipelineSnapshot){
        .sampleRate = 48000.0,
        .layout = fiveOne,
        .laneGraph = lanes,
        .bassManagementEnabled = true,
        .bassManagement = bass,
    };
    N60AcousticOutputRoute routes[6] = {
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleFrontLeft, UINT32_MAX, 0u},
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleFrontRight, UINT32_MAX, 1u},
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleFrontCenter, UINT32_MAX, 2u},
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleSideLeft, UINT32_MAX, 3u},
        {N60AcousticOutputRouteProgramSpeaker, N60ProgramChannelRoleSideRight, UINT32_MAX, 4u},
        {N60AcousticOutputRouteSubwoofer, N60ProgramChannelRoleUnused, 0u, 5u},
    };
    N60AcousticOutputMap map = {0};
    assert(N60AcousticOutputMapCompile(fiveOne, 1u, 6u, routes, 6u, &map));
    N60AcousticOutputRoute illegal[6];
    memcpy(illegal, routes, sizeof(illegal));
    illegal[2].role = N60ProgramChannelRoleLowFrequencyEffects;
    assert(!N60AcousticOutputMapCompile(fiveOne, 1u, 6u, illegal, 6u, &map));
    assert(N60AcousticOutputMapCompile(fiveOne, 1u, 6u, routes, 6u, &map));
    render = N60NChannelRenderBridgeCreate(transport, pipeline, map);
    assert(render != NULL);
    frame = (N60ProgramTransportFrame){0};
    frame.channels[3] = 1.0f;
    assert(N60ProgramTransportEnqueueFrame(transport, &frame));
    float surroundHardware[6] = {9,9,9,9,9,9};
    AudioBufferList surroundABL = {0};
    surroundABL.mNumberBuffers = 1u;
    surroundABL.mBuffers[0].mNumberChannels = 6u;
    surroundABL.mBuffers[0].mDataByteSize = sizeof(surroundHardware);
    surroundABL.mBuffers[0].mData = surroundHardware;
    assert(N60NChannelRenderBridgeProcessOutputBuffer(render, &surroundABL));
    for (uint32_t channel = 0; channel < 5u; ++channel) closef(surroundHardware[channel], 0.0f);
    closef(surroundHardware[5], 1.0f);
    N60NChannelRenderBridgeDestroy(render);
    N60ProgramTransportDestroy(transport);
    return 0;
}
'''
        compile_and_run(clang, apple, "nchannel_render_bridge")

    print("PR61 live N-channel render validation passed")


if __name__ == "__main__":
    main()
