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
print("PR104 safe offline preview contracts passed")
