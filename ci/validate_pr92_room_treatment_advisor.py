#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "NotchSixty/Audio/RoomTreatmentAdvisor.swift"
CONTROLLER = ROOT / "NotchSixty/State/RoomTreatmentAdvisorController.swift"
UI = ROOT / "NotchSixty/UI/ProductionRoomTreatmentAdvisorWorkspace.swift"
ROOT_UI = ROOT / "NotchSixty/UI/ProductionRootView.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
TESTS = ROOT / "NotchSixtyTests/RoomTreatmentAdvisorTests.swift"
IA_TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR92_ROOM_TREATMENT_ADVISOR.md"

def require(condition, message):
    if not condition:
        raise SystemExit(f"PR92 validation failed: {message}")

core = CORE.read_text()
controller = CONTROLLER.read_text()
ui = UI.read_text()
root_ui = ROOT_UI.read_text()
app = APP.read_text()
tests = TESTS.read_text()
ia_tests = IA_TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text().lower()

for token in (
    "enum RoomTreatmentAdvisorRemedy",
    "case measureMore",
    "case placement",
    "case passiveTreatment",
    "case dspCorrection",
    "case activeRoomTreatment",
    "case activeQuietZone",
    "struct RoomTreatmentAdvisorFinding",
    "struct RoomTreatmentAdvisorReport",
    "struct RoomTreatmentAdvisorAnalyzer",
    "strongestSpatialBassVariation",
    "deepestBassCancellation",
    "strongestEarlyReflection",
    "t20DerivedDecay",
    "bandpass(",
    "linearRegression(",
    "lowFrequencyRinging",
    "boundaryInterferenceCandidate",
    "prioritizedActions(",
    "RoomTreatmentAdvisorActionPriority",
):
    require(token in core, f"advisor model missing {token}")

for forbidden in (
    "AudioIOEngine",
    "ProductProfileController",
    "replaceStereo",
    "replaceRoomCorrection",
    "stageRoomTreatment",
    "requestArm",
):
    require(
        forbidden not in core,
        f"read-only analyzer must not own/apply playback state: {forbidden}",
    )

for token in (
    "final class RoomTreatmentAdvisorController",
    "let store: RoomCorrectionProjectStore",
    "store.existingProjectIDs()",
    "store.load(id)",
    "selectProject(",
):
    require(token in controller, f"independent project selector missing {token}")

require(
    "ProductProfileController" not in controller,
    "Room Advisor controller must not depend on Playback/System profile state",
)

for token in (
    "case roomAdvisor",
    "static let tools: [ProductionSection]",
    'Section("TOOLS")',
    'return "Room Advisor"',
    "ProductionRoomTreatmentAdvisorWorkspace",
    "selection == .roomAdvisor",
    '"Room Advisor · Read Only"',
):
    require(token in root_ui, f"Room Advisor navigation/toolbar missing {token}")

toolbar_start = root_ui.find("ToolbarItemGroup(placement: .primaryAction)")
toolbar_end = root_ui.find("ToolbarSpacer(.flexible)", toolbar_start)
require(toolbar_start >= 0 and toolbar_end > toolbar_start, "primary toolbar block missing")
toolbar = root_ui[toolbar_start:toolbar_end]
require(
    "if selection == .roomAdvisor" in toolbar
    and "ProductionProfileToolbar(product: product)" in toolbar
    and "} else {" in toolbar,
    "Room Advisor must use a distinct toolbar branch from preset/live controls",
)

for token in (
    'Text("Room Advisor")',
    '"READ-ONLY TOOL"',
    '"Measurement Source"',
    '"Measurement Readiness"',
    '"Diagnosis & Recommendations"',
    '"Recommended Order"',
    "report.actionPriorities",
    "advisor.selectedProjectID",
    "advisor.reloadProjects()",
):
    require(token in ui, f"Room Advisor workspace missing {token}")

for forbidden in (
    "replaceSelectedSystem",
    "selectContentPreset",
    "stageRoomTreatment",
    "requestArm",
    "setEnabled(",
):
    require(
        forbidden not in ui,
        f"Room Advisor UI must remain advisory/read-only: {forbidden}",
    )

for token in (
    "let roomTreatmentAdvisor: RoomTreatmentAdvisorController",
    "RoomTreatmentAdvisorController(",
    "roomTreatmentAdvisor.prepareForUse()",
):
    require(token in app, f"product Room Advisor lifecycle missing {token}")

for token in (
    "testMultiPositionBassVariationPrefersPlacement",
    "testSinglePositionDeepNullRequiresMoreMeasurementBeforeBoost",
    "testStrongEarlyReflectionPrefersPassiveTreatment",
    "testClippedOrLowSNRMeasurementFailsTowardMeasureMore",
    "testLongLowFrequencyDecayPrefersPassiveTreatment",
    "testDeepNullWithNormalDecayBecomesBoundaryInterferenceCandidate",
    "testMeasurementQualityTakesFirstActionPriority",
    "testControllerLoadsProjectsWithoutPlaybackProfileSelection",
):
    require(token in tests, f"Room Advisor test missing {token}")

require(
    "ProductionSection.tools" in ia_tests
    and ".roomAdvisor" in ia_tests,
    "production IA tests do not cover the Tools group",
)

for token in (
    "RoomTreatmentAdvisor.swift in Sources",
    "RoomTreatmentAdvisorController.swift in Sources",
    "ProductionRoomTreatmentAdvisorWorkspace.swift in Sources",
    "RoomTreatmentAdvisorTests.swift in Sources",
):
    require(token in project, f"Xcode target integration missing {token}")

for phrase in (
    "content preset",
    "playback system",
    "tools",
    "one microphone moved between positions",
    "no recommendation is automatically applied",
    "strong early reflection",
    "deep low-frequency cancellation",
    "t20-derived rt60",
    "boundary-interference candidate",
    "recommended order",
):
    require(phrase in doc, f"PR92 contract missing '{phrase}'")

print("PR92 Room Treatment Advisor architecture validation passed")
