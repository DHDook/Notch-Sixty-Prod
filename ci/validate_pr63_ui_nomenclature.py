#!/usr/bin/env python3
"""Permanent PR63 guard that the derived physical-system name reaches shipping UI."""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
TOOLBAR = ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR63 UI nomenclature validation failed: {message}")


def main() -> None:
    profile = PROFILE.read_text(encoding="utf-8")
    toolbar = TOOLBAR.read_text(encoding="utf-8")

    require("var systemDisplayName: String" in profile,
            "Output Device Profile does not derive physical-system nomenclature")
    require("programLayout.bedChannelCount" in profile,
            "system naming does not preserve bed-channel count")
    require("displayedSubwooferCount" in profile,
            "system naming does not derive the physical subwoofer count")
    require("programLayout.heightChannelCount" in profile,
            "system naming does not preserve height-channel count")

    require("Text(displayName(for: system))" in toolbar,
            "Playback System menu does not show the derived system label")
    require("Text(\"System: \\(selectedSystemDisplayName)" in toolbar,
            "selected Playback System control does not show the derived system label")
    require("outputProfile.systemDisplayName" in toolbar,
            "toolbar is not using the canonical Output Device Profile label")
    require("return \"\\(system.name) · \\(outputProfile.systemDisplayName)\"" in toolbar,
            "user system name and physical layout are not presented together")
    require("guard let outputProfile = system.state.outputDeviceProfile, outputProfile.enabled" in toolbar,
            "legacy/no-profile systems do not retain their original display name")

    print("PR63 visible multisub system nomenclature validation passed")


if __name__ == "__main__":
    main()
