#!/usr/bin/env python3
"""PR63 guard for 32-channel capacity and physical-system nomenclature."""

from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
BRIDGING = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR63 capacity validation failed: {message}")


def run_c_harness() -> None:
    compiler = shutil.which("clang") or shutil.which("cc")
    require(compiler is not None, "C compiler is required")
    source = r'''
#include <assert.h>
#include <stdint.h>
#include "N60ChannelRouter.h"
#include "N60LinkedDynamics.h"
#include "N60LiveNChannelRenderCore.h"

int main(void) {
    assert(N60_MAX_PROGRAM_CHANNELS == 32u);
    assert(N60_LIVE_MAX_PHYSICAL_CHANNELS >=
        N60_MAX_PROGRAM_CHANNELS + N60_MAX_SUBWOOFER_OUTPUTS);

    N60ProgramChannelLayout base = N60ProgramChannelLayoutMakeStandard(
        N60ProgramLayoutNineOneSix
    );
    assert(base.channelCount == 16u);

    N60ProgramChannelRole roles[N60_MAX_PROGRAM_CHANNELS] = {0};
    for (uint32_t i = 0; i < 16u; ++i) roles[i] = base.channels[i];
    for (uint32_t i = 0; i < 16u; ++i) {
        roles[16u + i] = (N60ProgramChannelRole)(N60ProgramChannelRoleCustom1 + i);
    }
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeCustom(roles, 32u);
    assert(N60ProgramChannelLayoutIsValid(&layout));
    assert(layout.channelCount == 32u);
    assert(N60ProgramChannelRoleIsCustom(layout.channels[31]));

    N60ProgramChannelRole lastRole[] = { N60ProgramChannelRoleCustom16 };
    N60ProgramChannelGroup group = {0};
    assert(N60ProgramChannelGroupMake(&layout, lastRole, 1u, &group));
    assert(group.channelMask == (1u << 31u));
    assert(N60ProgramChannelGroupContains(group, 31u));
    assert(!N60ProgramChannelGroupContains(group, 30u));

    N60LinkedDynamicsGroup linked = {
        .channelMask = (1u << 31u),
        .detectorMode = N60LinkedDynamicsDetectorPeak,
    };
    assert(N60LinkedDynamicsGroupIsValid(linked, 32u));

    N60ChannelRoutingMatrix matrix = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&layout, &layout, &matrix));
    assert(matrix.sourceChannelCount == 32u);
    assert(matrix.destinationChannelCount == 32u);
    assert(N60ChannelRoutingMatrixIsIdentity(&matrix));

    uint32_t programPhysical[N60_MAX_PROGRAM_CHANNELS];
    for (uint32_t i = 0; i < N60_MAX_PROGRAM_CHANNELS; ++i) {
        programPhysical[i] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    uint32_t nextPhysical = 0u;
    for (uint32_t i = 0; i < layout.channelCount; ++i) {
        if (layout.channels[i] == N60ProgramChannelRoleLowFrequencyEffects) continue;
        programPhysical[i] = nextPhysical++;
    }
    assert(nextPhysical == 31u);
    uint32_t subs[N60_MAX_SUBWOOFER_OUTPUTS] = {
        nextPhysical, nextPhysical + 1u, nextPhysical + 2u, nextPhysical + 3u
    };
    N60LiveNChannelOutputMap map = {0};
    assert(N60LiveNChannelOutputMapCompile(
        layout,
        35u,
        programPhysical,
        true,
        N60_MAX_SUBWOOFER_OUTPUTS,
        subs,
        &map
    ));
    assert(map.valid);
    assert(map.physicalChannelCount == 35u);
    assert(map.subwooferCount == 4u);
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr63-capacity-") as directory:
        temp = pathlib.Path(directory)
        src = temp / "capacity.c"
        binary = temp / "capacity"
        src.write_text(source, encoding="utf-8")
        subprocess.run([
            compiler,
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{REALTIME}",
            str(src),
            "-lm",
            "-o",
            str(binary),
        ], check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)


def run_swift_naming_harness() -> None:
    xcrun = shutil.which("xcrun")
    require(xcrun is not None, "xcrun is required on macOS")
    stubs = r'''
import Foundation

enum MultiOutputSynchronizationMode: String, Codable, Sendable {
    case automatic
    case aggregateDevice
    case softwarePLL
}

struct PhysicalOutputEndpoint: Codable, Equatable, Hashable, Sendable {
    var deviceUID: String
    var channelIndex: UInt32
}

struct AudioOutputDevice: Sendable {
    let uid: String
    let outputChannelCount: UInt32
    let minimumSampleRate: Double
    let maximumSampleRate: Double
    func supports(sampleRate: Double) -> Bool {
        sampleRate >= minimumSampleRate && sampleRate <= maximumSampleRate
    }
}
'''
    main = r'''
import Foundation

func subs(_ count: Int) -> [PhysicalSubwooferOutputAssignment] {
    (0..<count).map {
        PhysicalSubwooferOutputAssignment(
            index: UInt32($0),
            destination: PhysicalOutputEndpoint(deviceUID: "device", channelIndex: UInt32($0))
        )
    }
}

func label(_ layout: OutputProgramLayout, _ subCount: Int) -> String {
    OutputDeviceProfileConfiguration(
        programLayout: layout,
        subwooferAssignments: subs(subCount)
    ).systemDisplayName
}

precondition(label(.stereo, 0) == "2.0")
precondition(label(.stereo, 1) == "2.1")
precondition(label(.stereo, 2) == "2.2")
precondition(label(.fiveOne, 0) == "5.1")
precondition(label(.fiveOne, 2) == "5.2")
precondition(label(.sevenOneFour, 4) == "7.4.4")
precondition(label(.nineOneSix, 0) == "9.1.6")
precondition(label(.nineOneSix, 2) == "9.2.6")
precondition(label(.nineOneSix, 4) == "9.4.6")
print("PR63 physical-system nomenclature harness passed")
'''
    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr63-names-") as directory:
        temp = pathlib.Path(directory)
        stubs_path = temp / "Stubs.swift"
        main_path = temp / "main.swift"
        binary = temp / "nomenclature"
        stubs_path.write_text(stubs, encoding="utf-8")
        main_path.write_text(main, encoding="utf-8")
        subprocess.run([
            xcrun,
            "swiftc",
            "-O",
            "-import-objc-header",
            str(BRIDGING),
            "-Xcc",
            f"-I{REALTIME}",
            str(stubs_path),
            str(PROFILE),
            str(main_path),
            "-framework",
            "CoreAudio",
            "-o",
            str(binary),
        ], check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)


def main() -> None:
    layout = (REALTIME / "N60ProgramLayout.h").read_text(encoding="utf-8")
    lanes = (REALTIME / "N60ProgramLaneEngine.h").read_text(encoding="utf-8")
    live = (REALTIME / "N60LiveNChannelRenderCore.h").read_text(encoding="utf-8")
    profile = PROFILE.read_text(encoding="utf-8")

    require("#define N60_MAX_PROGRAM_CHANNELS 32u" in layout,
            "program-channel ceiling is not 32")
    require("N60ProgramChannelRoleCustom16" in layout,
            "32 unique semantic identities are not available")
    require("uint32_t channelMask" in lanes,
            "program channel groups still use a narrower mask")
    require("#define N60_LIVE_MAX_PHYSICAL_CHANNELS 40u" in live,
            "live physical-output ceiling does not leave multisub headroom")
    require("var systemDisplayName: String" in profile,
            "physical-system display nomenclature is missing")
    require("bedChannelCount" in profile and "heightChannelCount" in profile,
            "layout display dimensions are not explicit")

    run_c_harness()
    if platform.system() == "Darwin":
        run_swift_naming_harness()
    print("PR63 channel capacity and nomenclature validation passed")


if __name__ == "__main__":
    main()
