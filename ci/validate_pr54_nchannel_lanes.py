#!/usr/bin/env python3
"""Permanent PR54 guard for the generalized N-channel lane engine."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
LANES = REALTIME / "N60ProgramLaneEngine.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR54 validation failed: {message}")


def main() -> None:
    require(LANES.exists(), "N60ProgramLaneEngine.h is missing")
    require(BRIDGE.exists(), "Swift bridging header is missing")

    lanes = LANES.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("N60_PROGRAM_LANE_MAX_EQ_SECTIONS 16u" in lanes, "per-lane EQ bound changed")
    require("N60ProgramLaneGraphSetDelayMs" in lanes, "per-lane delay API is missing")
    require("N60ProgramChannelGroupMake" in lanes, "channel-group API is missing")
    require("upstreamProcessingLatencyFrames" in lanes, "latency-coherence metadata is missing")
    require("N60ProgramLaneMeterAccumulatorReading" in lanes, "multichannel meter foundation is missing")
    require("N60ProgramLaneRuntimeCreate" in lanes and "calloc" in lanes, "control-plane runtime allocation contract is missing")
    require('#import "N60ProgramLaneEngine.h"' in bridge, "lane engine is not exposed through the bridging header")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required for the PR54 lane-engine ABI test")

    harness = r'''
#include <assert.h>
#include <math.h>
#include "N60ProgramLaneEngine.h"

static void assert_close(float actual, float expected) {
    assert(fabsf(actual - expected) < 1.0e-5f);
}

int main(void) {
    N60ProgramChannelLayout sevenOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOne);
    N60ProgramLaneGraphSnapshot graph = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, sevenOne);
    assert(N60ProgramLaneGraphFinalize(&graph));
    assert(N60ProgramLaneGraphIsValid(&graph));
    assert(graph.coherenceLatencyFrames == 0u);

    N60ProgramChannelRole fronts[2] = {
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontRight,
    };
    N60ProgramChannelGroup frontGroup = {0};
    assert(N60ProgramChannelGroupMake(&sevenOne, fronts, 2u, &frontGroup));
    assert(N60ProgramChannelGroupContains(frontGroup, 0u));
    assert(N60ProgramChannelGroupContains(frontGroup, 1u));
    assert(!N60ProgramChannelGroupContains(frontGroup, 2u));
    assert(N60ProgramLaneGraphSetGroupGain(&graph, frontGroup, 0.5f));
    assert(N60ProgramLaneGraphSetPolarityInverted(&graph, 2u, true));
    assert(N60ProgramLaneGraphSetMute(&graph, 3u, true));
    assert(N60ProgramLaneGraphFinalize(&graph));

    N60ProgramLaneRuntime *runtime = N60ProgramLaneRuntimeCreate();
    assert(runtime != NULL);
    assert(N60ProgramLaneRuntimePrepare(runtime, &graph));

    float input[8] = {1.0f, 0.5f, 0.25f, 0.8f, 0.1f, -0.1f, 0.2f, -0.2f};
    float output[8] = {0};
    N60ProgramLaneMeterAccumulator meter = {0};
    N60ProgramLaneMeterAccumulatorReset(&meter, 8u);
    assert(N60ProgramLaneProcessFrame(runtime, &graph, input, output, &meter));
    assert_close(output[0], 0.5f);
    assert_close(output[1], 0.25f);
    assert_close(output[2], -0.25f);
    assert_close(output[3], 0.0f);
    assert_close(output[4], 0.1f);
    assert_close(output[5], -0.1f);
    assert_close(output[6], 0.2f);
    assert_close(output[7], -0.2f);

    N60ProgramLaneMeterReading reading = N60ProgramLaneMeterAccumulatorReading(&meter);
    assert(reading.channelCount == 8u);
    assert_close(reading.peak[0], 0.5f);
    assert_close(reading.rms[0], 0.5f);
    assert(reading.overRangeSamples[0] == 0u);

    N60ProgramLaneRuntimeDestroy(runtime);

    // User delay is exact and state remains warm while muted.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot delayed = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphSetDelayFrames(&delayed, 0u, 2u));
    assert(N60ProgramLaneGraphFinalize(&delayed));
    runtime = N60ProgramLaneRuntimeCreate();
    assert(runtime != NULL);
    assert(N60ProgramLaneRuntimePrepare(runtime, &delayed));
    float impulse[2] = {1.0f, 0.0f};
    float silence[2] = {0.0f, 0.0f};
    float frameOut[2] = {0.0f, 0.0f};
    assert(N60ProgramLaneProcessFrame(runtime, &delayed, impulse, frameOut, NULL));
    assert_close(frameOut[0], 0.0f);
    assert(N60ProgramLaneProcessFrame(runtime, &delayed, silence, frameOut, NULL));
    assert_close(frameOut[0], 0.0f);
    assert(N60ProgramLaneProcessFrame(runtime, &delayed, silence, frameOut, NULL));
    assert_close(frameOut[0], 1.0f);
    N60ProgramLaneRuntimeDestroy(runtime);

    // Coherence compensation aligns channels that arrive with unequal upstream
    // processing latency. Here L is declared 2 frames slower than R; feed the
    // L impulse 2 frames later and the lane engine delays R by 2 frames.
    N60ProgramLaneGraphSnapshot coherent = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphSetUpstreamProcessingLatency(&coherent, 0u, 2u));
    assert(N60ProgramLaneGraphSetUpstreamProcessingLatency(&coherent, 1u, 0u));
    assert(N60ProgramLaneGraphFinalize(&coherent));
    assert(coherent.coherenceLatencyFrames == 2u);
    assert(N60ProgramLaneGraphEffectiveDelayFrames(&coherent, 0u) == 0u);
    assert(N60ProgramLaneGraphEffectiveDelayFrames(&coherent, 1u) == 2u);
    runtime = N60ProgramLaneRuntimeCreate();
    assert(runtime != NULL);
    assert(N60ProgramLaneRuntimePrepare(runtime, &coherent));

    float rImpulse[2] = {0.0f, 1.0f};
    assert(N60ProgramLaneProcessFrame(runtime, &coherent, rImpulse, frameOut, NULL));
    assert_close(frameOut[0], 0.0f);
    assert_close(frameOut[1], 0.0f);
    assert(N60ProgramLaneProcessFrame(runtime, &coherent, silence, frameOut, NULL));
    assert_close(frameOut[0], 0.0f);
    assert_close(frameOut[1], 0.0f);
    float delayedLImpulse[2] = {1.0f, 0.0f};
    assert(N60ProgramLaneProcessFrame(runtime, &coherent, delayedLImpulse, frameOut, NULL));
    assert_close(frameOut[0], 1.0f);
    assert_close(frameOut[1], 1.0f);
    N60ProgramLaneRuntimeDestroy(runtime);

    // Per-channel EQ uses the existing independently derived biquad primitive.
    N60ProgramLaneGraphSnapshot eqGraph = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphSetEQBand(
        &eqGraph,
        0u,
        0u,
        N60BiquadFilterTypePeaking,
        1000.0,
        3.0,
        0.707,
        true
    ));
    assert(N60ProgramLaneGraphFinalize(&eqGraph));
    runtime = N60ProgramLaneRuntimeCreate();
    assert(runtime != NULL);
    assert(N60ProgramLaneRuntimePrepare(runtime, &eqGraph));
    float eqIn[2] = {0.5f, 0.5f};
    assert(N60ProgramLaneProcessFrame(runtime, &eqGraph, eqIn, frameOut, NULL));
    assert(isfinite(frameOut[0]));
    assert_close(frameOut[1], 0.5f);
    N60ProgramLaneRuntimeDestroy(runtime);

    // Delay plus latency compensation may not overflow the fixed realtime ring.
    N60ProgramLaneGraphSnapshot overflow = N60ProgramLaneGraphSnapshotMakeUnity(48000.0, stereo);
    assert(N60ProgramLaneGraphSetDelayFrames(&overflow, 0u, N60_PROGRAM_LANE_MAX_DELAY_FRAMES));
    assert(N60ProgramLaneGraphSetUpstreamProcessingLatency(&overflow, 1u, 1u));
    assert(!N60ProgramLaneGraphFinalize(&overflow));

    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr54-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "nchannel_lanes_test.c"
        binary = temp / "nchannel_lanes_test"
        source.write_text(harness, encoding="utf-8")
        subprocess.run(
            [
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
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True)

    print("PR54 N-channel DSP lane validation passed")


if __name__ == "__main__":
    main()
