#!/usr/bin/env python3
"""Permanent PR61 guard for the opt-in live semantic N-channel render path."""

from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
CORE = REALTIME / "N60LiveNChannelRenderCore.h"
BRIDGE = REALTIME / "N60LiveNChannelBridge.h"
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
    for path in (CORE, BRIDGE, SWIFT_BRIDGE):
        require(path.exists(), f"{path.name} is missing")

    core = CORE.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    swift_bridge = SWIFT_BRIDGE.read_text(encoding="utf-8")

    require("Program LFE and Sub N" in core, "LFE/sub domain separation contract is missing")
    require("N60ProgramLaneProcessFrame" in core, "PR54 lane engine is not in the live composite")
    require("N60MultichannelBassManagementProcessFrame" in core,
            "PR55 bass management is not in the live composite")
    require("N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED" in core,
            "explicit unmapped program-output state is missing")
    require("semantic dequeue -> PR54 lanes -> PR55 bass management -> physical map" in bridge,
            "live callback integration contract is missing")
    require("N60LiveNChannelCaptureIOProc" in bridge, "live capture callback is missing")
    require("N60LiveNChannelOutputIOProc" in bridge, "live output callback is missing")
    require('#import "N60LiveNChannelBridge.h"' in swift_bridge,
            "live N-channel bridge is not exposed to Swift")

    process_body = core.split("static inline bool N60LiveNChannelRenderProcessFrame", 1)[1]
    process_body = process_body.split("#ifdef __cplusplus", 1)[0]
    for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf("):
        require(forbidden not in process_body, f"realtime composite contains {forbidden}")

    output_callback = bridge.split("static inline OSStatus N60LiveNChannelOutputIOProc", 1)[1]
    output_callback = output_callback.split("#ifdef __cplusplus", 1)[0]
    for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf("):
        require(forbidden not in output_callback, f"output callback contains {forbidden}")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    portable = r'''
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include "N60LiveNChannelRenderCore.h"

static void closef(float actual, float expected) {
    assert(fabsf(actual - expected) <= 1.0e-4f);
}

static N60LiveNChannelRenderGraph make_bass_graph(void) {
    const double rate = 48000.0;
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    assert(N60ProgramChannelLayoutIsValid(&layout));

    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    assert(N60ProgramLaneGraphSetGain(&lanes, 0u, 0.5f));
    assert(N60ProgramLaneGraphSetDelayFrames(&lanes, 2u, 1u));
    assert(N60ProgramLaneGraphSetMute(&lanes, 5u, true));
    assert(N60ProgramLaneGraphFinalize(&lanes));

    N60MultichannelBassManagementSnapshot bass =
        N60MultichannelBassManagementSnapshotMake(rate, layout, 2u);
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 0u, 1.0f));
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 1u, 0.5f));
    assert(N60MultichannelBassManagementSnapshotIsValid(&bass));

    const uint32_t programPhysical[6] = {
        0u, 1u, 2u, N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED, 4u, 5u,
    };
    const uint32_t subPhysical[2] = {3u, 6u};
    N60LiveNChannelOutputMap outputMap = {0};
    assert(N60LiveNChannelOutputMapCompile(
        layout, 7u, programPhysical, true, 2u, subPhysical, &outputMap));

    // Bass-managed program LFE can never also map to a physical speaker lane.
    uint32_t invalidProgramPhysical[6] = {0u, 1u, 2u, 3u, 4u, 5u};
    assert(!N60LiveNChannelOutputMapCompile(
        layout, 7u, invalidProgramPhysical, true, 2u, subPhysical, &outputMap));

    // Physical speaker/sub destinations must remain one-to-one.
    const uint32_t duplicateSubs[2] = {3u, 5u};
    assert(!N60LiveNChannelOutputMapCompile(
        layout, 7u, programPhysical, true, 2u, duplicateSubs, &outputMap));

    assert(N60LiveNChannelOutputMapCompile(
        layout, 7u, programPhysical, true, 2u, subPhysical, &outputMap));

    N60LiveNChannelRenderGraph graph = {0};
    assert(N60LiveNChannelRenderGraphMake(
        rate, layout, lanes, true, bass, outputMap, &graph));
    return graph;
}

int main(void) {
    N60LiveNChannelRenderGraph graph = make_bass_graph();
    N60LiveNChannelRenderRuntime *runtime = N60LiveNChannelRenderRuntimeCreate();
    assert(runtime != NULL);
    assert(N60LiveNChannelRenderRuntimePrepare(runtime, &graph));

    N60ProgramTransportFrame first = {0};
    first.channels[0] = 1.0f;
    first.channels[1] = 2.0f;
    first.channels[2] = 3.0f;
    first.channels[3] = 0.4f;
    first.channels[4] = 0.5f;
    first.channels[5] = 0.6f;
    N60LiveNChannelPhysicalFrame physical = {0};
    assert(N60LiveNChannelRenderProcessFrame(runtime, &graph, &first, &physical, NULL));
    assert(physical.physicalChannelCount == 7u);
    closef(physical.values[0], 0.5f); // FL gain from PR54
    closef(physical.values[1], 2.0f);
    closef(physical.values[2], 0.0f); // one-frame center delay
    closef(physical.values[3], 0.4f); // native LFE -> Sub 1
    closef(physical.values[4], 0.5f);
    closef(physical.values[5], 0.0f); // SR mute from PR54
    closef(physical.values[6], 0.2f); // independent LFE -> Sub 2 weight

    N60ProgramTransportFrame second = {0};
    second.channels[0] = 2.0f;
    second.channels[1] = 4.0f;
    second.channels[2] = 6.0f;
    second.channels[3] = 0.8f;
    second.channels[4] = 1.0f;
    second.channels[5] = 1.2f;
    assert(N60LiveNChannelRenderProcessFrame(runtime, &graph, &second, &physical, NULL));
    closef(physical.values[0], 1.0f);
    closef(physical.values[1], 4.0f);
    closef(physical.values[2], 3.0f); // delayed first center sample
    closef(physical.values[3], 0.8f);
    closef(physical.values[4], 1.0f);
    closef(physical.values[5], 0.0f);
    closef(physical.values[6], 0.4f);

    N60LiveNChannelRenderRuntimeDestroy(runtime);

    // Bass-management bypass retains semantic LFE as an ordinary program output.
    N60ProgramChannelLayout bypassLayout =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60ProgramLaneGraphSnapshot bypassLanes =
        N60ProgramLaneGraphSnapshotMakeUnity(48000.0, bypassLayout);
    assert(N60ProgramLaneGraphFinalize(&bypassLanes));
    const uint32_t bypassPhysical[6] = {0u, 1u, 2u, 3u, 4u, 5u};
    N60LiveNChannelOutputMap bypassMap = {0};
    assert(N60LiveNChannelOutputMapCompile(
        bypassLayout, 6u, bypassPhysical, false, 0u, NULL, &bypassMap));
    N60LiveNChannelRenderGraph bypassGraph = {0};
    N60MultichannelBassManagementSnapshot unusedBass = {0};
    assert(N60LiveNChannelRenderGraphMake(
        48000.0, bypassLayout, bypassLanes, false, unusedBass, bypassMap, &bypassGraph));
    runtime = N60LiveNChannelRenderRuntimeCreate();
    assert(runtime != NULL);
    assert(N60LiveNChannelRenderRuntimePrepare(runtime, &bypassGraph));
    N60ProgramTransportFrame bypassInput = {0};
    bypassInput.channels[3] = 0.75f;
    assert(N60LiveNChannelRenderProcessFrame(
        runtime, &bypassGraph, &bypassInput, &physical, NULL));
    closef(physical.values[3], 0.75f);
    N60LiveNChannelRenderRuntimeDestroy(runtime);
    return 0;
}
'''
    compile_and_run(clang, portable, "live_render_core")

    if platform.system() == "Darwin":
        apple = r'''
#include <assert.h>
#include <math.h>
#include <string.h>
#include "N60LiveNChannelBridge.h"

static AudioChannelDescription desc(AudioChannelLabel label) {
    AudioChannelDescription d = {0};
    d.mChannelLabel = label;
    return d;
}

static void closef(float actual, float expected) {
    assert(fabsf(actual - expected) <= 1.0e-4f);
}

int main(void) {
    const double rate = 48000.0;
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    AudioChannelDescription descriptions[6] = {
        desc(kAudioChannelLabel_Left),
        desc(kAudioChannelLabel_Right),
        desc(kAudioChannelLabel_Center),
        desc(kAudioChannelLabel_LFEScreen),
        desc(kAudioChannelLabel_LeftSurround),
        desc(kAudioChannelLabel_RightSurround),
    };
    N60ProgramInputMap inputMap = {0};
    assert(N60ProgramInputMapCompile(descriptions, 6u, layout, &inputMap));

    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    assert(N60ProgramLaneGraphSetGain(&lanes, 0u, 0.5f));
    assert(N60ProgramLaneGraphFinalize(&lanes));
    N60MultichannelBassManagementSnapshot bass =
        N60MultichannelBassManagementSnapshotMake(rate, layout, 2u);
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 0u, 1.0f));
    assert(N60MultichannelBassManagementSetLFERoute(&bass, 1u, 0.5f));

    const uint32_t programPhysical[6] = {
        0u, 1u, 2u, N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED, 4u, 5u,
    };
    const uint32_t subPhysical[2] = {3u, 6u};
    N60LiveNChannelOutputMap outputMap = {0};
    assert(N60LiveNChannelOutputMapCompile(
        layout, 7u, programPhysical, true, 2u, subPhysical, &outputMap));
    N60LiveNChannelRenderGraph graph = {0};
    assert(N60LiveNChannelRenderGraphMake(
        rate, layout, lanes, true, bass, outputMap, &graph));

    N60LiveNChannelBridge *bridge = N60LiveNChannelBridgeCreate(
        8u, inputMap, graph, 2u, 0u);
    assert(bridge != NULL);
    N60LiveNChannelBridgeSetOutputGain(bridge, 0.5f);

    float outputSamples[14];
    for (uint32_t i = 0; i < 14u; ++i) outputSamples[i] = 9.0f;
    AudioBufferList output = {0};
    output.mNumberBuffers = 1u;
    output.mBuffers[0].mNumberChannels = 7u;
    output.mBuffers[0].mDataByteSize = sizeof(outputSamples);
    output.mBuffers[0].mData = outputSamples;

    // Gate fails closed before capture.
    assert(N60LiveNChannelOutputIOProc(0, NULL, NULL, NULL, &output, NULL, bridge) == noErr);
    for (uint32_t i = 0; i < 14u; ++i) closef(outputSamples[i], 0.0f);
    N60LiveNChannelBridgeSnapshot snapshot = N60LiveNChannelBridgeGetSnapshot(bridge);
    assert(snapshot.gatedOutputCallbacks == 1u);
    assert(!snapshot.outputGateOpen);

    float inputSamples[12] = {
        1.0f, 2.0f, 3.0f, 0.4f, 0.5f, 0.6f,
        2.0f, 4.0f, 6.0f, 0.8f, 1.0f, 1.2f,
    };
    AudioBufferList input = {0};
    input.mNumberBuffers = 1u;
    input.mBuffers[0].mNumberChannels = 6u;
    input.mBuffers[0].mDataByteSize = sizeof(inputSamples);
    input.mBuffers[0].mData = inputSamples;
    assert(N60LiveNChannelCaptureIOProc(0, NULL, &input, NULL, NULL, NULL, bridge) == noErr);

    for (uint32_t i = 0; i < 14u; ++i) outputSamples[i] = 9.0f;
    assert(N60LiveNChannelOutputIOProc(0, NULL, NULL, NULL, &output, NULL, bridge) == noErr);

    // Frame 1, master gain 0.5. LFE exists only on explicit sub destinations.
    closef(outputSamples[0], 0.25f);
    closef(outputSamples[1], 1.0f);
    closef(outputSamples[2], 1.5f);
    closef(outputSamples[3], 0.2f);
    closef(outputSamples[4], 0.25f);
    closef(outputSamples[5], 0.3f);
    closef(outputSamples[6], 0.1f);
    // Frame 2.
    closef(outputSamples[7], 0.5f);
    closef(outputSamples[8], 2.0f);
    closef(outputSamples[9], 3.0f);
    closef(outputSamples[10], 0.4f);
    closef(outputSamples[11], 0.5f);
    closef(outputSamples[12], 0.6f);
    closef(outputSamples[13], 0.2f);

    snapshot = N60LiveNChannelBridgeGetSnapshot(bridge);
    assert(snapshot.outputGateOpen);
    assert(snapshot.captureCallbacks == 1u);
    assert(snapshot.outputCallbacks == 2u);
    assert(snapshot.renderedFrames == 2u);
    assert(snapshot.renderFailures == 0u);
    assert(snapshot.outputWriteFailures == 0u);
    assert(snapshot.transport.capturedFrames == 2u);
    assert(snapshot.transport.consumedFrames == 2u);

    N60LiveNChannelBridgeDestroy(bridge);
    return 0;
}
'''
        compile_and_run(clang, apple, "live_coreaudio_bridge")

    print("PR61 live N-channel render validation passed")


if __name__ == "__main__":
    main()
