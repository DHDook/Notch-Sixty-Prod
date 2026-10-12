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
for f in (SOURCE, TEST, PREDECESSOR, DOCUMENT, WORKFLOW, ROADMAP):
    assert f.is_file(), f"missing PR110 file: {f}"

source = SOURCE.read_text(encoding="utf-8")
test = TEST.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
document = DOCUMENT.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")

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

assert "Read-only hypotheses" in document
assert "REMOTE SCOPE ONLY" in document
assert "Current execution status — PR110" in roadmap
assert "RoomGeometryPlacementTests" in workflow
assert "AdvancedRoomPlacementExperimentsTests" in workflow
assert "macos" in workflow
assert "portable" in workflow
print("PR110 bounded placement hypothesis and no-DSP-authority contracts passed")
