#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignment.swift"
TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentTests.swift"
COHERENT = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCoherentTiming.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR108_COHERENT_SUBWOOFER_ALIGNMENT.md"
WORKFLOW = ROOT / ".github/workflows/pr108-coherent-subwoofer-alignment.yml"

for path in (SOURCE, TESTS, COHERENT, CALIBRATION, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR108 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
coherent = COHERENT.read_text()
calibration = CALIBRATION.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
workflow = WORKFLOW.read_text()

for token in (
    "struct CoherentSubwooferAlignmentPlanner",
    "struct CoherentSubwooferAlignmentCandidate",
    "signedRelativeDelayAdjustmentMilliseconds",
    "speakerCommonDelayAdjustmentMilliseconds",
    "subwooferDelayAdjustmentMilliseconds",
    "toggleSubwooferPolarity",
    "predictedCoherenceBeforeDB",
    "predictedCoherenceAfterDB",
    "var canDeploy: Bool { false }",
):
    assert token in source, f"missing PR108 proposal contract: {token}"

for token in (
    "report.wrappedRelativePhaseRadians[index]",
    "- 2 * Double.pi * frequency * delaySeconds",
    "togglePolarity ? Double.pi : 0",
):
    assert token in source, f"missing PR108 coherent phase model: {token}"

assert "arrivalSeconds + delaySeconds" not in source, (
    "PR108 must not double-count coherent relative arrival"
)

for token in (
    "testLateSubBecomesCommonSpeakerDelayInsteadOfNegativeSubDelay",
    "testEarlySubGetsPositiveSubDelay",
    "testPolarityReversalIsFoundWithoutInventingDelay",
    "testTwoMainsProduceOneRobustCompromiseForSamePhysicalSub",
    "testAlreadyCoherentPairReturnsReviewBlockedNoOp",
    "testEvidenceIdentityAndBassManagementFailClosed",
):
    assert token in tests, f"missing PR108 proposal test: {token}"

for token in (
    "wrappedRelativePhaseRadians",
    "relativeArrivalMilliseconds",
    "crossSourceClockProvenanceAuthenticated",
    "measurementOnly",
):
    assert token in coherent, f"missing inherited PR106 coherent evidence: {token}"

for token in (
    "struct PhysicalSubwooferCalibration",
    "delayMilliseconds",
    "polarityInverted",
    "N60_SUBWOOFER_MAX_DELAY_FRAMES",
):
    assert token in calibration, f"missing inherited physical Sub calibration contract: {token}"

for token in (
    "F10800000000000000000001",
    "F10800000000000000000002",
    "F10800000000000000000011",
    "F10800000000000000000012",
):
    assert project.count(token) >= 2, f"missing PR108 Xcode registration: {token}"

for token in (
    "PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization",
    "Slice 1 — Coherent delay/polarity proposal",
    "does **not** subtract relativeArrivalMilliseconds again",
    "previewOnly == true",
    "canDeploy == false",
    "Transactional Apply / rollback",
    "Fresh coherent verification",
):
    assert token in doc, f"missing PR108 Slice 1 documentation: {token}"

assert "validate_pr107_speaker_optimizer_fir.py" in workflow
assert "CoherentSubwooferAlignmentTests" in workflow
assert "Run full XCTest regression" in workflow

print("PR108 Slice 1 coherent subwoofer alignment proposal boundary passed")
