#!/usr/bin/env python3
"""Permanent PR53 guard for semantic channel mapping and the bounded N×M router."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
ROUTER = REALTIME / "N60ChannelRouter.h"
CORE_AUDIO_MAP = REALTIME / "N60CoreAudioChannelMapping.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR53 validation failed: {message}")


def main() -> None:
    require(ROUTER.exists(), "N60ChannelRouter.h is missing")
    require(CORE_AUDIO_MAP.exists(), "N60CoreAudioChannelMapping.h is missing")
    require(BRIDGE.exists(), "Swift bridging header is missing")

    router = ROUTER.read_text(encoding="utf-8")
    mapper = CORE_AUDIO_MAP.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("N60_CHANNEL_ROUTER_MAX_ROUTES" in router, "fixed matrix bound is missing")
    require("N60ChannelRoutingMatrixCompileSemanticReorder" in router, "semantic reorder compiler is missing")
    require("N60ChannelRoutingMatrixProcessFrame" in router, "bounded frame primitive is missing")
    require("N60ProgramChannelLayoutFromAudioChannelDescriptions" in mapper, "Core Audio description mapper is missing")
    require("kAudioChannelLabel_LFEScreen" in mapper, "LFE label mapping is missing")
    require("kAudioChannelLabel_LeftTopFront" in mapper, "height label mapping is missing")
    require("kAudioChannelLabel_LeftWide" in mapper, "wide label mapping is missing")
    require("kAudioChannelLayoutTag_UseChannelDescriptions" in mapper, "explicit-description policy is missing")
    require('#import "N60ChannelRouter.h"' in bridge, "router is not exposed through the bridging header")
    require('#import "N60CoreAudioChannelMapping.h"' in bridge, "Core Audio mapper is not exposed through the bridging header")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required for the PR53 router ABI test")

    harness = r'''
#include <assert.h>
#include <math.h>
#include "N60ChannelRouter.h"

int main(void) {
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ChannelRoutingMatrix identity = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&stereo, &stereo, &identity));
    assert(N60ChannelRoutingMatrixIsIdentity(&identity));

    const float stereoIn[2] = {0.25f, -0.5f};
    float stereoOut[2] = {0.0f, 0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&identity, stereoIn, stereoOut));
    assert(fabsf(stereoOut[0] - stereoIn[0]) < 1.0e-7f);
    assert(fabsf(stereoOut[1] - stereoIn[1]) < 1.0e-7f);

    N60ProgramChannelRole reversedRoles[2] = {
        N60ProgramChannelRoleFrontRight,
        N60ProgramChannelRoleFrontLeft,
    };
    N60ProgramChannelLayout reversed = N60ProgramChannelLayoutMakeCustom(reversedRoles, 2u);
    assert(N60ProgramChannelLayoutIsValid(&reversed));

    N60ChannelRoutingMatrix reorder = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&reversed, &stereo, &reorder));
    assert(!N60ChannelRoutingMatrixIsIdentity(&reorder));
    const float reversedIn[2] = {-0.75f, 0.125f};
    float canonicalOut[2] = {0.0f, 0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&reorder, reversedIn, canonicalOut));
    assert(fabsf(canonicalOut[0] - 0.125f) < 1.0e-7f);
    assert(fabsf(canonicalOut[1] + 0.75f) < 1.0e-7f);

    N60ChannelRoute mixRoutes[2] = {
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
        { .sourceChannelIndex = 1u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
    };
    N60ChannelRoutingMatrix monoMix = {0};
    assert(N60ChannelRoutingMatrixCompile(2u, 1u, mixRoutes, 2u, &monoMix));
    const float mixIn[2] = {0.8f, 0.2f};
    float mixOut[1] = {0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&monoMix, mixIn, mixOut));
    assert(fabsf(mixOut[0] - 0.5f) < 1.0e-7f);

    N60ChannelRoute duplicateRoutes[2] = {
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 1.0f },
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
    };
    N60ChannelRoutingMatrix rejected = {0};
    assert(!N60ChannelRoutingMatrixCompile(2u, 2u, duplicateRoutes, 2u, &rejected));

    N60ChannelRoute invalidGain = {
        .sourceChannelIndex = 0u,
        .destinationChannelIndex = 0u,
        .gainLinear = NAN,
    };
    assert(!N60ChannelRoutingMatrixCompile(2u, 2u, &invalidGain, 1u, &rejected));

    N60ProgramChannelRole wrongRoles[2] = {
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontCenter,
    };
    N60ProgramChannelLayout wrong = N60ProgramChannelLayoutMakeCustom(wrongRoles, 2u);
    assert(N60ProgramChannelLayoutIsValid(&wrong));
    assert(!N60ChannelRoutingMatrixCompileSemanticReorder(&wrong, &stereo, &rejected));

    N60ProgramChannelLayout sevenOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOne);
    N60ProgramChannelRole sevenOneReorderedRoles[8] = {
        N60ProgramChannelRoleFrontCenter,
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontRight,
        N60ProgramChannelRoleLowFrequencyEffects,
        N60ProgramChannelRoleRearLeft,
        N60ProgramChannelRoleRearRight,
        N60ProgramChannelRoleSideLeft,
        N60ProgramChannelRoleSideRight,
    };
    N60ProgramChannelLayout sevenOneReordered = N60ProgramChannelLayoutMakeCustom(sevenOneReorderedRoles, 8u);
    assert(N60ProgramChannelLayoutIsValid(&sevenOneReordered));
    N60ChannelRoutingMatrix sevenOneMatrix = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&sevenOneReordered, &sevenOne, &sevenOneMatrix));

    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr53-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "channel_router_test.c"
        binary = temp / "channel_router_test"
        source.write_text(harness, encoding="utf-8")
        subprocess.run(
            [
                clang,
                "-std=c11",
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

    print("PR53 semantic channel router validation passed")


if __name__ == "__main__":
    main()
