#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerDesignEngine.swift"
TEST = ROOT / "NotchSixtyTests/SpeakerOptimizerDesignEngineTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR104_SPEAKER_OPTIMIZATION_ENGINE.md"
WORKFLOW = ROOT / ".github/workflows/pr104-speaker-optimization.yml"

for p in (SOURCE, TEST, PROJECT, DOC, WORKFLOW):
    assert p.is_file(), f"missing PR104 file {p}"
source, test, project, doc, workflow = (p.read_text() for p in
    (SOURCE, TEST, PROJECT, DOC, WORKFLOW))
for token in (
    "guard baseline.role == .baseline",
    "guard evidence.optimizerReady",
    "SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline)",
    "struct SpeakerOptimizerDesignEngine",
    "struct SpeakerOptimizerPreviewPlan",
    "var previewOnly: Bool { true }",
    "var isMeasuredVerification: Bool { false }",
    "maximumBoostDB: Double = 0",
    "maximumCutDB: Double = 6",
    "normalizedSeatWeights",
    "logFrequencySmooth",
    "maximumSeatDegradationDB",
    "correction = Array(repeating: 0",
):
    assert token in source, f"missing PR104 safety/design contract: {token}"
for token in (
    "testQualifiedBaselineProducesBoundedCutOnlyPreview",
    "testCandidateOrVerificationCannotBecomeBaseline",
    "testInsufficientRepeatsFailsClosed",
    "testChangedMicrophoneOrRoutingFailsClosed",
    "testMissingOrInvalidSeatWeightsFailClosed",
    "testSafetyOptionsBoundBoostAndCut",
):
    assert token in test, f"missing PR104 test: {token}"
for token in (
    "F10400000000000000000001",
    "F10400000000000000000002",
    "F10400000000000000000011",
    "F10400000000000000000012",
):
    assert project.count(token) >= 2, f"Xcode registration missing: {token}"
for token in ("prediction, not verification", "protected Low/Mid/High", "PR105"):
    assert token in doc, f"missing PR104 design/safety note: {token}"
assert "full XCTest regression" in workflow
peq_source = ROOT / "NotchSixty/Audio/SpeakerOptimizerPEQCandidateDesigner.swift"
peq_tests = ROOT / "NotchSixtyTests/SpeakerOptimizerPEQCandidateTests.swift"
assert peq_source.is_file() and peq_tests.is_file(), "missing Slice 2 PEQ source or tests"
peq = peq_source.read_text()
peq_test = peq_tests.read_text()
for token in (
    "struct SpeakerOptimizerPEQBand",
    "struct SpeakerOptimizerPEQCandidateDesigner",
    "baseline: SpeakerOptimizerMeasurementSet",
    "SpeakerOptimizerDesignEngine().design(",
    "maximumBands = 6",
    "maximumBandGainMagnitudeDB = 6.0",
    "maximumHeadroomDB = 3.5",
    "maximumOutOfBandDeviationDB = 1.0",
    "isMeasuredVerification: Bool { false }",
    "previewOnly: Bool { true }",
    "recommendedHeadroomDB",
    "maximumPositiveGain",
    "passesChecks(",
):
    assert token in peq, f"missing PEQ safety contract: {token}"
for token in (
    "testQualifiedMeasurementProducesConstrainedCutOnlyPEQ",
    "testDigitalPeakingBiquadHasBoundedCorrectCenterGain",
    "testUnqualifiedDataAndRoleFailClosed",
    "testInvalidFilterConstraintsFailClosed",
):
    assert token in peq_test, f"missing PEQ test {token}"
for token in (
    "F10400000000000000000003",
    "F10400000000000000000004",
    "F10400000000000000000013",
    "F10400000000000000000014",
):
    assert project.count(token) >= 2, f"PEQ not registered in Xcode: {token}"
assert "Run PR104 PEQ candidate tests" in workflow
fir_source = ROOT / "NotchSixty/Audio/SpeakerOptimizerFIRCandidateDesigner.swift"
fir_tests = ROOT / "NotchSixtyTests/SpeakerOptimizerFIRCandidateTests.swift"
assert fir_source.is_file() and fir_tests.is_file(), "missing PR104 FIR candidate files"
firt = fir_source.read_text()
fitt = fir_tests.read_text()
for token in (
    "struct SpeakerOptimizerFIRCandidateDesigner",
    "SpeakerOptimizerDesignEngine().design(",
    "tapCount = 2049",
    "maximumGroupDelayMilliseconds = 30.0",
    "var canDeploy: Bool { false }",
    "var isMeasuredVerification: Bool { false }",
    "taps: accepted ? impulse : []",
    "delayFrames",
    "declaredGroupDelayFrames",
    "SpeakerOptimizerFIRTransform",
    "vDSP_DFT_Execute(",
    "minimumModeledImprovementDB",
    "maximumOutOfBandDeviationDB",
):
    assert token in firt, f"missing FIR contract {token}"
for token in (
    "testQualifiedEvidenceBuildsLinearPhaseFIRWithDeclaredDelay",
    "testMissingEvidenceOrVerificationRoleIsRejected",
    "testTapCountAndDelayFailClosed",
    "testStrictResponseGuardNeverExposesUnacceptedTaps",
    "testOneMicTwoPositionsPreserveEvidenceAndRoutingIdentity",
):
    assert token in fitt, f"missing FIR test {token}"
for token in (
    "F10400000000000000000005", "F10400000000000000000006",
    "F10400000000000000000015", "F10400000000000000000016"
):
    assert project.count(token) >= 2, f"missing FIR Xcode registration {token}"
assert "Run PR104 FIR candidate tests" in workflow
print("PR104 offline PEQ/FIR candidate contracts passed")
