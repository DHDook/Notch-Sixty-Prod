#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "NotchSixty/Audio/RoomGeometryPlacement.swift"
CONTROLLER = ROOT / "NotchSixty/State/RoomTreatmentAdvisorController.swift"
UI = ROOT / "NotchSixty/UI/ProductionRoomGeometrySection.swift"
ADVISOR_UI = ROOT / "NotchSixty/UI/ProductionRoomTreatmentAdvisorWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/RoomGeometryPlacementTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR93_ROOM_GEOMETRY_PLACEMENT.md"

def require(condition, message):
    if not condition:
        raise SystemExit(f"PR93 validation failed: {message}")

core = CORE.read_text()
controller = CONTROLLER.read_text()
ui = UI.read_text()
advisor_ui = ADVISOR_UI.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text().lower()

for token in (
    "struct RoomGeometryModel",
    "struct RoomGeometryPlacementAnalyzer",
    "struct RoomGeometryStore",
    "func roomModes(",
    "func firstReflections(",
    "func boundaryPredictions(",
    "RoomGeometryEvidenceStatus",
    "case supported",
    "case conflicted",
    "placementCandidates(",
    "modeShape(",
    "imageSource(",
    "reflectionPoint(",
):
    require(token in core, f"geometry engine missing {token}")

for forbidden in (
    "AudioIOEngine",
    "ProductProfileController",
    "replaceStereo",
    "replaceRoomCorrection",
    "stageRoomTreatment",
    "requestArm",
    "setEnabled(",
):
    require(
        forbidden not in core,
        f"geometry engine must remain offline/read-only: {forbidden}",
    )

for token in (
    "let geometryStore: RoomGeometryStore",
    "@Published var geometryDraft",
    "geometryAnalysis",
    "startGeometryTemplate()",
    "saveGeometry()",
    "revertGeometry()",
    "clearGeometry()",
    "geometryStore.load(",
    "geometryStore.save(",
):
    require(token in controller, f"Advisor geometry ownership missing {token}")

require(
    "ProductProfileController" not in controller,
    "Advisor controller must remain independent of profile state",
)

for token in (
    'Text("Geometry & Placement")',
    '"Top-Down Room Plan"',
    '"Geometry × Measurement"',
    '"Placement Experiments"',
    '"Prediction only · verify by re-measuring"',
    "advisor.setGeometryValue",
    "advisor.saveGeometry()",
):
    require(token in ui, f"geometry UI missing {token}")

for forbidden in (
    "selectContentPreset",
    "replaceSelectedSystem",
    "stageRoomTreatment",
    "requestArm",
):
    require(
        forbidden not in ui,
        f"geometry UI must not mutate playback: {forbidden}",
    )

require(
    "ProductionRoomGeometrySection(" in advisor_ui,
    "Room Advisor does not surface Geometry & Placement",
)

for token in (
    "testRectangularRoomAxialModesMatchClosedFormFrequencies",
    "testImageSourceFrontWallReflectionLandsOnFrontSurface",
    "testBoundaryPredictionUsesFirstDestructivePathDifference",
    "testMeasuredRingingSupportsNearbyPredictedMode",
    "testMeasuredRingingConflictsWithDistantRectangularMode",
    "testMeasuredReflectionCanSupportModeledSurfacePath",
    "testBoundaryNullCanSupportModeledSBIRCandidate",
    "testPlacementSearchFindsLowerRiskListenerMoveForLengthMode",
    "testGeometryValidationRejectsPointOutsideRoom",
    "testGeometryStoreIsSeparateFromRoomCorrectionProjectState",
    "testAdvisorGeometrySelectionDoesNotRequireProfileController",
):
    require(token in tests, f"geometry test missing {token}")

for token in (
    "RoomGeometryPlacement.swift in Sources",
    "ProductionRoomGeometrySection.swift in Sources",
    "RoomGeometryPlacementTests.swift in Sources",
):
    require(token in project, f"Xcode integration missing {token}")

for phrase in (
    "geometry predicts",
    "measurement confirms",
    "room modes",
    "first-order reflection",
    "boundary/sbir",
    "placement optimization",
    "prediction — verify with measurement",
    "content preset",
    "playback system",
):
    require(phrase in doc, f"PR93 contract missing '{phrase}'")

print("PR93 Room Geometry & Placement architecture validation passed")
