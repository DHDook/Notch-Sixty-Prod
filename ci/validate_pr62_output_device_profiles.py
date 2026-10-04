#!/usr/bin/env python3
"""Permanent PR62 guard for Output Device Profile semantics and persistence wiring."""

from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
PRODUCT = ROOT / "NotchSixty/State/ProductProfiles.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR62 validation failed: {message}")


def main() -> None:
    for path in (PROFILE, PRODUCT, PROJECT):
        require(path.exists(), f"{path.name} is missing")

    profile = PROFILE.read_text(encoding="utf-8")
    product = PRODUCT.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    require("enum OutputProgramRole" in profile, "semantic program-role model is missing")
    require("enum OutputProgramLayout" in profile, "program-layout model is missing")
    require("case threeOne" in profile, "3.1 custom semantic layout is missing")
    require("2.1/2.2" in profile and "5.2/7.2" in profile,
            "program-layout versus physical-sub distinction is undocumented")
    require("lfeMustBeUnmappedWhenBassManaged" in profile,
            "native LFE / physical subwoofer separation is not enforced")
    require("PhysicalSubwooferOutputAssignment" in profile,
            "explicit Sub N output assignment is missing")
    require("N60LiveNChannelOutputMapCompile" in profile,
            "PR61 realtime output-map compiler is not connected")
    require("makeLivePlan" in profile, "device/profile activation plan compiler is missing")
    require("softwarePLLSuperseded" in profile,
            "Aggregate Device synchronization policy is not preserved")

    require("OutputDeviceProfileConfiguration.swift in Sources" in project,
            "Output Device Profile source is not in the app target")
    require("var outputDeviceProfile: OutputDeviceProfileConfiguration?" in product,
            "PlaybackSystemState does not own Output Device Profile state")
    require("outputDeviceProfile: OutputDeviceProfileConfiguration? = nil" in product,
            "legacy archive-safe optional initializer is missing")
    require("selectedSystemOutputDeviceProfile" in product,
            "selected Playback System does not expose its Output Device Profile")
    require("replaceSelectedSystemOutputDeviceProfile" in product,
            "Playback System cannot persist Output Device Profile changes")
    require("legacyPhysicalRoutingConflict" in product,
            "legacy PR41 routing conflict is not guarded at profile mutation")
    require("outputDeviceProfile: selectedSystemProfile?.state.outputDeviceProfile" in product,
            "profile capture does not preserve Output Device Profile state")

    # PR62 deliberately retains schema v1: adding an Optional Codable field makes
    # pre-PR62 archives decode it as nil rather than discarding existing systems.
    require("struct PlaybackSystemState: Codable" in product, "PlaybackSystemState lost Codable")
    require("static let currentSchemaVersion = 1" in product,
            "PlaybackSystemState schema was bumped instead of using optional migration")

    print("PR62 Output Device Profile validation passed")


if __name__ == "__main__":
    main()
