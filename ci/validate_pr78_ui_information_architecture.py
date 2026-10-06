#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
ACOUSTICS = ROOT / "NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift"
PLUGINS = ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR78_UI_INFORMATION_ARCHITECTURE.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR78 validation failed: {message}")


root = ROOT_VIEW.read_text()
acoustics = ACOUSTICS.read_text()
plugins = PLUGINS.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    'case dashboard',
    'case speakers',
    'case activeAcoustics',
    'case plugins',
    'static let playback',
    'static let system',
    'static let extensions',
    'Section("PLAYBACK")',
    'Section("SYSTEM")',
    'Section("EXTENSIONS")',
):
    require(token in root, f"sidebar information architecture missing {token}")

require('case activeCrossover' not in root,
        "legacy Active Crossover navigation case still exists")
require('case .speakers: return "Speakers"' in root,
        "Speakers title is not the public navigation language")
require('Text("Dashboard").font(.largeTitle.bold())' in root,
        "Dashboard is not the standalone page title")
require('ProductionActiveAcousticsWorkspace(engine: engine)' in root,
        "Active Acoustics is not routed from the sidebar")
require('ProductionPluginWorkspace()' in root,
        "Plug-ins is not routed from Extensions")
require('title: "Active Acoustics"' in root,
        "Dashboard does not summarize Active Acoustics")
require('title: "Speakers"' in root,
        "Dashboard does not use Speakers language")

for forbidden in (
    "requestRoomTreatmentArm(",
    "requestRoomTreatmentBypass(",
    "stageRoomTreatmentForNextStart(",
    "clearStagedRoomTreatment(",
    "latchRoomTreatmentFault(",
):
    require(forbidden not in acoustics,
            f"Active Acoustics UI exposes forbidden live treatment control {forbidden}")

for required in (
    "Ambient Analysis",
    "Room Treatment",
    "Continuous room-microphone monitoring is not activated",
    "no Arm, Bypass, or Stage control",
    "productionTransportMeterSnapshot",
):
    require(required in acoustics,
            f"Active Acoustics workspace missing '{required}'")

require('Label("Add Plug-in", systemImage: "plus")' in plugins,
        "Plug-in rack shell is missing Add Plug-in affordance")
require('.disabled(true)' in plugins,
        "Plug-in add control must remain disabled in PR78")
for forbidden in (
    "AVAudioUnit",
    "AudioComponentFindNext",
    "instantiate(",
    "AUAudioUnit",
):
    require(forbidden not in plugins,
            f"PR78 Plug-ins shell unexpectedly implements AU hosting: {forbidden}")

for token in (
    "ProductionActiveAcousticsWorkspace.swift in Sources",
    "ProductionPluginWorkspace.swift in Sources",
    "ProductionInformationArchitectureTests.swift in Sources",
):
    require(token in project, f"Xcode target wiring missing {token}")

for token in (
    "testDashboardIsStandaloneAndNotInAGroup",
    "testPlaybackGroupContainsOnlyContentFacingDailyControls",
    "testSystemGroupContainsHardwareCalibrationAndAcoustics",
    "testExtensionsGroupContainsPluginRackEntryPoint",
):
    require(token in tests, f"navigation XCTest missing {token}")

normalized_doc = doc.lower()
for phrase in (
    "dashboard is intentionally a standalone top-level item",
    "playback",
    "system",
    "extensions",
    "status and readiness only",
    "add plug-in control is visibly disabled",
    "manual visual acceptance",
):
    require(phrase in normalized_doc,
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr77_live_room_treatment.py").exists(),
        "inherited PR77 live-integration validation is missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.c").exists(),
        "inherited PR77 physical-output simulation is missing")

print("PR78 production UI information-architecture validation passed")
