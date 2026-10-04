#!/usr/bin/env python3
"""Permanent PR52 guard for the semantic N-channel program-layout foundation."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HEADER = ROOT / "NotchSixty/Audio/Realtime/N60ProgramLayout.h"
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
AGENTS = ROOT / "AGENTS.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR52 validation failed: {message}")


def main() -> None:
    require(HEADER.exists(), "N60ProgramLayout.h is missing")
    require(BRIDGE.exists(), "Swift bridging header is missing")

    header = HEADER.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    agents = AGENTS.read_text(encoding="utf-8")

    require('#import "N60ProgramLayout.h"' in bridge, "program layout ABI is not exposed to Swift")
    require("#define N60_MAX_PROGRAM_CHANNELS 16u" in header, "fixed 16-channel realtime bound changed")
    require("N60ProgramLayoutNineOneSix" in header, "9.1.6 canonical layout is missing")
    require("N60ProgramChannelRoleLowFrequencyEffects" in header, "LFE must remain a semantic program role")
    require("N60ProgramChannelLayoutIsStereoCompatible" in header, "stereo compatibility gate is missing")
    require("Post-v1 explicitly approved expansion" in agents, "repository scope does not record the approved expansion")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required for the PR52 ABI test")

    harness = r'''
#include <assert.h>
#include <stdint.h>
#include "N60ProgramLayout.h"

int main(void) {
    const N60ProgramLayoutIdentifier identifiers[] = {
        N60ProgramLayoutStereo,
        N60ProgramLayoutFiveOne,
        N60ProgramLayoutSevenOne,
        N60ProgramLayoutFiveOneTwo,
        N60ProgramLayoutFiveOneFour,
        N60ProgramLayoutSevenOneFour,
        N60ProgramLayoutNineOneSix,
    };
    const uint32_t expectedCounts[] = {2u, 6u, 8u, 8u, 10u, 12u, 16u};

    for (uint32_t index = 0; index < 7u; ++index) {
        N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(identifiers[index]);
        assert(layout.channelCount == expectedCounts[index]);
        assert(N60ProgramChannelLayoutIsValid(&layout));
    }

    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    assert(N60ProgramChannelLayoutIsStereoCompatible(&stereo));
    assert(N60ProgramChannelLayoutIndexOfRole(&stereo, N60ProgramChannelRoleFrontLeft) == 0);
    assert(N60ProgramChannelLayoutIndexOfRole(&stereo, N60ProgramChannelRoleFrontRight) == 1);
    assert(N60ProgramChannelLayoutIndexOfRole(&stereo, N60ProgramChannelRoleFrontCenter) == -1);

    N60ProgramChannelLayout nineOneSix = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutNineOneSix);
    assert(N60ProgramChannelLayoutIndexOfRole(&nineOneSix, N60ProgramChannelRoleWideLeft) == 8);
    assert(N60ProgramChannelLayoutIndexOfRole(&nineOneSix, N60ProgramChannelRoleTopRearRight) == 15);

    N60ProgramChannelRole duplicateRoles[] = {
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontLeft,
    };
    N60ProgramChannelLayout duplicate = N60ProgramChannelLayoutMakeCustom(duplicateRoles, 2u);
    assert(!N60ProgramChannelLayoutIsValid(&duplicate));

    N60ProgramChannelRole customRoles[] = {
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontRight,
        N60ProgramChannelRoleFrontCenter,
    };
    N60ProgramChannelLayout custom = N60ProgramChannelLayoutMakeCustom(customRoles, 3u);
    assert(N60ProgramChannelLayoutIsValid(&custom));
    assert(!N60ProgramChannelLayoutIsStereoCompatible(&custom));

    N60ProgramChannelLayout mutated = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    mutated.channels[4] = N60ProgramChannelRoleRearLeft;
    assert(!N60ProgramChannelLayoutIsValid(&mutated));

    N60ProgramChannelLayout overflow = N60ProgramChannelLayoutMakeCustom(customRoles, N60_MAX_PROGRAM_CHANNELS + 1u);
    assert(overflow.channelCount == 0u);
    assert(!N60ProgramChannelLayoutIsValid(&overflow));

    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr52-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "program_layout_test.c"
        binary = temp / "program_layout_test"
        source.write_text(harness, encoding="utf-8")
        subprocess.run(
            [
                clang,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                f"-I{HEADER.parent}",
                str(source),
                "-o",
                str(binary),
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True)

    print("PR52 N-channel program-layout foundation validation passed")


if __name__ == "__main__":
    main()
