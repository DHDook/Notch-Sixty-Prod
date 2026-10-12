#!/usr/bin/env python3
"""PR110 advanced placement slice-1 boundary: proposals only, never live DSP."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/RoomGeometryPlacement.swift"
TEST = ROOT / "NotchSixtyTests/RoomGeometryPlacementTests.swift"
PREDECESSOR = ROOT / "ci/validate_pr109_cross_feature_contracts.py"
DOCUMENT = ROOT / "docs/PR110_ADVANCED_PLACEMENT.md"
WORKFLOW = ROOT / ".github/workflows/pr110-advanced-placement.yml"
ROADMAP = ROOT / "docs/ROADMAP.md"
CONTROLLER = ROOT / "NotchSixty/State/RoomTreatmentAdvisorController.swift"
UI = ROOT / "NotchSixty/UI/ProductionRoomGeometrySection.swift"
for f in (SOURCE, TEST, PREDECESSOR, DOCUMENT, WORKFLOW, ROADMAP, CONTROLLER, UI):
    assert f.is_file(), f"missing PR110 file: {f}"

source = SOURCE.read_text(encoding="utf-8")
test = TEST.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
document = DOCUMENT.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
controller = CONTROLLER.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")

assert "struct RoomAdvancedPlacementState" in source
assert "struct RoomAdvancedPlacementExperiment" in source
assert "struct RoomAdvancedPlacementExplorer" in source
assert "enum RoomAdvancedPlacementMove" in source
assert "RoomGeometryModel" in source
assert "secondarySeats: [RoomGeometryPoint3D]" in source
assert "subwooferPositions: [RoomGeometryPoint3D]" in source

advanced = source.split("// MARK: - PR110: read-only advanced placement experiments", 1)
assert len(advanced) == 2, "PR110 placement engine must be separately reviewable"
advanced = advanced[1]
for token in (
    "try room.validated()",
    "secondarySeats.count <= 7",
    "subwooferPositions.count <= 4",
    "leftToeInDegrees.isFinite",
    "rightToeInDegrees.isFinite",
    "abs(leftToeInDegrees) <= 80",
    "abs(rightToeInDegrees) <= 80",
    "case leftSpeaker",
    "case rightSpeaker",
    "case leftToeIn",
    "case rightToeIn",
    "case leftHeight",
    "case rightHeight",
    "case subwoofer",
    "maximumSeatPathImbalanceMeters",
    "Geometry hypothesis — measurement required",
    "var requiresMeasuredVerification: Bool { true }",
    "guard (try? trial.validated()) != nil",
    "trial != state",
    "return results",
):
    assert token in advanced, f"missing bounded placement contract: {token}"

for forbidden in (
    "AudioIOEngine", "PlaybackSystem", "ContentPreset", "RenderKernel",
    "AudioDeviceStart", "CoreAudio", "setEnabled(", "apply(",
    "predictedSPL", "guaranteedDB", "acousticImprovementDB",
):
    assert forbidden not in advanced, f"PR110 offline proposal has live/audio authority: {forbidden}"

for name in (
    "testIndependentLeftMoveDoesNotChangeRightOrSub",
    "testSubMoveOnlyChangesSelectedSubPosition",
    "testToeInChangesOrientationWithoutMovingSpeakers",
    "testHeightChangesOnlySelectedSpeaker",
    "testInvalidOutOfRoomTrialsAreOmitted",
    "testNoSubProducesNoInventedSubwooferTrials",
    "testInvalidGeometryAndAnglesFailClosed",
    "testCandidateEnumerationIsDeterministicAndDoesNotMutateState",
    "testMultiSeatPathMetricIsGeometryOnlyAndNonNegative",
):
    assert name in test, f"missing PR110 protection test {name}"

# Slice 2: a genuinely separate Room Advisor project sidecar, no migration
# or mutation of Playback System / Content Preset and no auto Apply.
for token in (
    "struct RoomAdvancedPlacementSettings: Codable, Equatable, Sendable",
    "schemaVersion: Int = currentSchemaVersion",
    "struct RoomAdvancedPlacementStore: Sendable",
    "advisor-advanced-placement-v1.json",
    "projectStore.projectDirectory(for: projectID)",
    "try decoded.state(for: room)",
    "options: .atomic",
    "func delete(projectID: UUID) throws",
    "throw RoomAdvancedPlacementError.corruptSettings",
):
    assert token in source, f"PR110 project-only persistence missing {token}"

for token in (
    "advancedPlacementStore =",
    "RoomAdvancedPlacementStore(projectStore: store)",
    "@Published private(set) var advancedPlacementDraft:",
    "@Published private(set) var savedAdvancedPlacement:",
    "loadAdvancedPlacement(for: project.id)",
    "func saveAdvancedPlacement()",
    "room == savedGeometry",
    "try advancedPlacementStore.save(settings, room: room)",
    "func previewAdvancedExperiment(",
    "selectedAdvancedExperiment = proposal",
    "advancedPlacementExperiments.contains(proposal)",
    "func revertAdvancedPlacement()",
    "try advancedPlacementStore.delete(projectID: projectID)",
):
    assert token in controller, f"PR110 Room Advisor isolation missing {token}"

preview = controller.split("func previewAdvancedExperiment(", 1)[1].split(
    "func saveAdvancedPlacement()", 1
)[0]
for forbidden in ("geometryDraft =", "savedGeometry =", "advancedPlacementDraft =",
                  "savedAdvancedPlacement =", "apply(", "save(",
                  "ProductProfileController", "AudioIOEngine"):
    assert forbidden not in preview, f"inspect-only preview gained mutation: {forbidden}"

for token in (
    "advancedPlacementSection",
    "Advanced Speaker & Subwoofer Placement",
    "Save Advanced Placement",
    "advisor.saveAdvancedPlacement()",
    "advisor.previewAdvancedExperiment(proposal)",
    "advisor.geometryHasUnsavedChanges",
    "Text(proposal.evidenceLabel)",
    "advisor.addAdvancedSeat()",
    "advisor.addAdvancedSubwoofer()",
):
    assert token in ui, f"PR110 advanced placement UI missing {token}"

for token in (
    "final class AdvancedPlacementSidecarTests",
    "testProjectSidecarRoundTripDoesNotChangeLegacyGeometryOrProject",
    "testMissingSidecarLeavesExistingRoomUntouched",
    "testCorruptedSidecarCannotSilentlyResetOrDamageLegacyRoom",
    "testCrossProjectAndUnsupportedVersionSettingsRejected",
    "testControllerDraftSaveReloadAndPureProposalPreview",
    "testAdvancedSaveBlockedWhileBaseGeometryIsUnsaved",
    "testAdvancedDraftRevertDoesNotTouchSavedGeometry",
    "testClearingGeometryRemovesOnlyCorrespondingAdvancedSidecar",
):
    assert token in test, f"PR110 project sidecar test missing {token}"

assert "AdvancedPlacementSidecarTests" in workflow

assert "Read-only hypotheses" in document
assert "REMOTE SCOPE ONLY" in document
assert "Current execution status — PR110" in roadmap
assert "RoomGeometryPlacementTests" in workflow
assert "AdvancedRoomPlacementExperimentsTests" in workflow
assert "macos" in workflow
assert "portable" in workflow
print("PR110 bounded placement hypothesis and no-DSP-authority contracts passed")
