#!/usr/bin/env python3
"""PR55 guard for dedicated per-sub conditioning controls."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
HEADER = REALTIME / "N60SubwooferTuning.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR55 subwoofer tuning validation failed: {message}")


def main() -> None:
    require(HEADER.exists(), "N60SubwooferTuning.h is missing")
    header = HEADER.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    require("N60SubwooferOutputSetEnabled" in header, "explicit per-sub enable is missing")
    require("N60SubwooferOutputSetSubsonicHighPass" in header, "subsonic HPF is missing")
    require("N60SubwooferOutputSetPhaseAlignment" in header, "phase alignment is missing")
    require("N60SubwooferOutputSetUserEQBand" in header, "disjoint user PEQ API is missing")
    require('#import "N60SubwooferTuning.h"' in bridge, "tuning ABI is not exposed to Swift")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    harness = r'''
#include <assert.h>
#include <math.h>
#include "N60SubwooferTuning.h"

int main(void) {
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60MultichannelBassManagementSnapshot snapshot =
        N60MultichannelBassManagementSnapshotMake(48000.0, layout, 2u);

    assert(N60SubwooferOutputSetEnabled(&snapshot, 1u, false));
    assert(!snapshot.subwoofers[1].enabled);

    assert(N60SubwooferOutputSetSubsonicHighPass(&snapshot, 0u, 20.0, 0.70710678, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].type == N60BiquadFilterTypeHighPass);

    assert(N60SubwooferOutputSetPhaseAlignment(&snapshot, 0u, 80.0, 0.7, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].type == N60BiquadFilterTypeAllPass);

    assert(N60SubwooferOutputSetUserEQBand(
        &snapshot, 0u, 0u, N60BiquadFilterTypePeaking, 50.0, -3.0, 1.0, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_USER_EQ_FIRST_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].type == N60BiquadFilterTypeHighPass);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].type == N60BiquadFilterTypeAllPass);
    assert(!N60SubwooferOutputSetUserEQBand(
        &snapshot, 0u, N60_SUBWOOFER_USER_EQ_SECTIONS,
        N60BiquadFilterTypePeaking, 60.0, 1.0, 1.0, true));

    assert(!N60SubwooferOutputSetSubsonicHighPass(&snapshot, 0u, 0.0, 0.707, true));
    assert(!N60SubwooferOutputSetPhaseAlignment(&snapshot, 0u, 24000.0, 0.7, true));
    assert(N60MultichannelBassManagementSnapshotIsValid(&snapshot));

    N60MultichannelBassManagementRuntime *runtime =
        N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementSetLFERoute(&snapshot, 0u, 1.0f));
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &snapshot));

    float in[6] = {0};
    float speakers[6] = {0};
    float subs[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    in[3] = 1.0f;
    for (uint32_t frame = 0; frame < 2048u; ++frame) {
        assert(N60MultichannelBassManagementProcessFrame(runtime, &snapshot, in, speakers, subs));
        assert(isfinite(subs[0]));
        assert(subs[1] == 0.0f);
        in[3] = 0.0f;
    }
    N60MultichannelBassManagementRuntimeDestroy(runtime);
    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr55-tuning-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "subwoofer_tuning_test.c"
        binary = temp / "subwoofer_tuning_test"
        source.write_text(harness, encoding="utf-8")
        subprocess.run([
            clang, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{REALTIME}", str(source), "-lm", "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True)

    print("PR55 subwoofer tuning validation passed")


if __name__ == "__main__":
    main()
