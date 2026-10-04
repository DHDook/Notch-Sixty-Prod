#!/usr/bin/env python3
"""Permanent PR55 guard for semantic multichannel bass management."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
HEADER = REALTIME / "N60MultichannelBassManagement.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR55 validation failed: {message}")


def main() -> None:
    require(HEADER.exists(), "N60MultichannelBassManagement.h is missing")
    require(BRIDGE.exists(), "Swift bridging header is missing")
    header = HEADER.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("N60_MAX_SUBWOOFER_OUTPUTS 4u" in header, "four-sub bound changed")
    require("redirectedBassToSub" in header, "redirected-bass routing matrix is missing")
    require("lfeToSub" in header, "native LFE routing matrix is missing")
    require("N60ProgramChannelRoleLowFrequencyEffects" in header, "semantic LFE distinction is missing")
    require("N60SubwooferOutputSetEQBand" in header, "per-sub EQ contract is missing")
    require("N60SubwooferOutputSetDelayMs" in header, "per-sub delay contract is missing")
    require("N60SubwooferOutputSetProtection" in header, "per-sub protection contract is missing")
    require('#import "N60MultichannelBassManagement.h"' in bridge, "bass-management ABI is not exposed to Swift")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required for the PR55 ABI test")

    harness = r'''
#include <assert.h>
#include <math.h>
#include "N60MultichannelBassManagement.h"

static void assert_close(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

int main(void) {
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    assert(N60ProgramChannelLayoutIsValid(&fiveOne));
    assert(N60ProgramChannelLayoutIndexOfRole(&fiveOne, N60ProgramChannelRoleLowFrequencyEffects) == 3);

    // Native LFE is a semantic program lane, not a physical sub output.
    N60MultichannelBassManagementSnapshot lfe =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 2u);
    assert(N60MultichannelBassManagementSetLFERoute(&lfe, 0u, 1.0f));
    assert(N60MultichannelBassManagementSetLFERoute(&lfe, 1u, 0.5f));
    assert(N60MultichannelBassManagementSnapshotIsValid(&lfe));
    assert(!N60MultichannelBassManagementSetSourceCrossover(
        &lfe, 3u, 80.0, N60CrossoverTopologyLinkwitzRiley24, true));

    N60MultichannelBassManagementRuntime *runtime =
        N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &lfe));

    float program[6] = {0};
    float speakers[6] = {0};
    float subs[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    program[3] = 1.0f;
    assert(N60MultichannelBassManagementProcessFrame(runtime, &lfe, program, speakers, subs));
    assert_close(speakers[3], 0.0f, 1.0e-7f);
    assert_close(subs[0], 1.0f, 1.0e-7f);
    assert_close(subs[1], 0.5f, 1.0e-7f);
    for (uint32_t channel = 0; channel < 6u; ++channel) {
        if (channel != 3u) assert_close(speakers[channel], 0.0f, 1.0e-7f);
    }
    N60MultichannelBassManagementRuntimeDestroy(runtime);

    // Per-sub trim, polarity and delay remain independent after LFE routing.
    N60MultichannelBassManagementSnapshot delayed =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 1u);
    assert(N60MultichannelBassManagementSetLFERoute(&delayed, 0u, 1.0f));
    assert(N60SubwooferOutputSetGain(&delayed, 0u, 0.5f));
    assert(N60SubwooferOutputSetPolarityInverted(&delayed, 0u, true));
    assert(N60SubwooferOutputSetDelayFrames(&delayed, 0u, 2u));
    assert(N60MultichannelBassManagementSnapshotIsValid(&delayed));
    runtime = N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &delayed));

    for (uint32_t channel = 0; channel < 6u; ++channel) program[channel] = 0.0f;
    program[3] = 1.0f;
    assert(N60MultichannelBassManagementProcessFrame(runtime, &delayed, program, speakers, subs));
    assert_close(subs[0], 0.0f, 1.0e-7f);
    program[3] = 0.0f;
    assert(N60MultichannelBassManagementProcessFrame(runtime, &delayed, program, speakers, subs));
    assert_close(subs[0], 0.0f, 1.0e-7f);
    assert(N60MultichannelBassManagementProcessFrame(runtime, &delayed, program, speakers, subs));
    assert_close(subs[0], -0.5f, 1.0e-7f);
    N60MultichannelBassManagementRuntimeDestroy(runtime);

    // Bass from a bandwidth-limited main is redirected independently from LFE.
    N60MultichannelBassManagementSnapshot redirected =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 1u);
    assert(N60MultichannelBassManagementSetSourceCrossover(
        &redirected, 0u, 80.0, N60CrossoverTopologyLinkwitzRiley24, true));
    assert(N60MultichannelBassManagementSetRedirectedBassRoute(&redirected, 0u, 0u, 1.0f));
    assert(N60MultichannelBassManagementSnapshotIsValid(&redirected));
    runtime = N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &redirected));

    for (uint32_t frame = 0; frame < 8192u; ++frame) {
        for (uint32_t channel = 0; channel < 6u; ++channel) program[channel] = 0.0f;
        program[0] = 1.0f;      // DC exercises low/high-pass settling.
        program[1] = 0.25f;     // Unmanaged channel must pass through exactly.
        assert(N60MultichannelBassManagementProcessFrame(runtime, &redirected, program, speakers, subs));
    }
    assert(fabsf(speakers[0]) < 0.01f);
    assert_close(speakers[1], 0.25f, 1.0e-7f);
    assert_close(subs[0], 1.0f, 0.01f);
    N60MultichannelBassManagementRuntimeDestroy(runtime);

    // Subwoofer EQ is isolated per physical output.
    N60MultichannelBassManagementSnapshot subEQ =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 2u);
    assert(N60MultichannelBassManagementSetLFERoute(&subEQ, 0u, 1.0f));
    assert(N60MultichannelBassManagementSetLFERoute(&subEQ, 1u, 1.0f));
    assert(N60SubwooferOutputSetEQBand(
        &subEQ, 0u, 0u, N60BiquadFilterTypePeaking, 80.0, 6.0, 1.0, true));
    assert(N60MultichannelBassManagementSnapshotIsValid(&subEQ));
    runtime = N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &subEQ));
    for (uint32_t channel = 0; channel < 6u; ++channel) program[channel] = 0.0f;
    program[3] = 1.0f;
    assert(N60MultichannelBassManagementProcessFrame(runtime, &subEQ, program, speakers, subs));
    assert(isfinite(subs[0]));
    assert_close(subs[1], 1.0f, 1.0e-7f);
    assert(fabsf(subs[0] - subs[1]) > 1.0e-5f);
    N60MultichannelBassManagementRuntimeDestroy(runtime);

    // Per-sub emergency protection is explicit and independently observable.
    N60MultichannelBassManagementSnapshot protected =
        N60MultichannelBassManagementSnapshotMake(48000.0, fiveOne, 1u);
    assert(N60MultichannelBassManagementSetLFERoute(&protected, 0u, 2.0f));
    assert(N60SubwooferOutputSetProtection(&protected, 0u, 0.5f, true));
    assert(N60MultichannelBassManagementSnapshotIsValid(&protected));
    runtime = N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &protected));
    for (uint32_t channel = 0; channel < 6u; ++channel) program[channel] = 0.0f;
    program[3] = 1.0f;
    assert(N60MultichannelBassManagementProcessFrame(runtime, &protected, program, speakers, subs));
    assert_close(subs[0], 0.5f, 1.0e-7f);
    assert(runtime->protectionClampSamples[0] == 1u);
    N60MultichannelBassManagementRuntimeDestroy(runtime);

    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr55-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "multichannel_bass_management_test.c"
        binary = temp / "multichannel_bass_management_test"
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

    print("PR55 multichannel bass-management validation passed")


if __name__ == "__main__":
    main()
