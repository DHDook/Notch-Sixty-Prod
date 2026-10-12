#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerCharacterizationMeasurement.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCharacterizationMeasurementTests.swift"
EARLY_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerEarlyWindowCharacterization.swift"
EARLY_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerEarlyWindowCharacterizationTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR105_SPEAKER_CHARACTERIZATION_AND_VERIFICATION.md"
WORKFLOW = ROOT / ".github/workflows/pr105-speaker-characterization.yml"

for path in (SOURCE, TESTS, EARLY_SOURCE, EARLY_TESTS, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR105 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
early_source = EARLY_SOURCE.read_text()
early_tests = EARLY_TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
workflow = WORKFLOW.read_text()

for token in (
    "struct SpeakerOptimizerCharacterizationGeometry",
    "preferredDistanceMeters = 1.0",
    "minimumDistanceMeters = 0.75",
    "maximumDistanceMeters = 2.0",
    "speakerRemainedInInstalledPosition",
    "struct SpeakerOptimizerCharacterizationMeasurementSet",
    "linkedListeningMeasurementSetID",
    "SpeakerOptimizerMeasurementEvidenceEvaluator()",
    "struct SpeakerOptimizerCharacterizationSessionOrchestrator",
    "repeatsPerTarget",
    "positionID is deliberately the",
    "case .speaker(let role)",
    "role != .lowFrequencyEffects",
):
    assert token in source, f"missing characterization contract: {token}"

for token in (
    "testWholeSpeakersUseSeparateGeometryBoundCharacterizationTargets",
    "testSubwooferAndLFEAreNotSpeakerCharacterizationTargets",
    "testGeometryFailsClosedOutsideIntegrationRangeOrOffAxis",
    "testCharacterizationCompletesThreeStationaryRepeatsBeforeMovingSpeakerTarget",
    "testCaptureCannotBeMixedBetweenCharacterizationTargets",
    "testStableCharacterizationReusesStrictPR103EvidenceQualification",
    "testListeningCampaignCompatibilityRequiresSameMeasurementIdentity",
    "testCharacterizationPersistenceIsCompactAndDomainSeparated",
):
    assert token in tests, f"missing characterization test: {token}"

for token in (
    "struct SpeakerOptimizerEarlyWindowSettings",
    "postArrivalMilliseconds: Double = 6.0",
    "minimumCyclesForReliableMagnitude: Double = 2.0",
    "magnitudeOnly: Bool = true",
    "isAnechoic: Bool = false",
    "phaseRadians: nil",
    "SpeakerOptimizerCharacterizationCaptureBuilder",
    "microphoneCalibration.gainDB(at: frequency)",
):
    assert token in early_source, f"missing early-window safety contract: {token}"

for token in (
    "testDefaultGateExcludesLateReflectionAndPublishesMagnitudeOnly",
    "testEarlyWindowReappliesTrackedMicrophoneCalibration",
    "testCalibrationFingerprintMismatchFailsClosed",
    "testWindowReliabilityBoundaryMovesUpWhenGateShortens",
    "testBuilderDerivesBeforeCompactionAndEvidencePersistsWithoutImpulse",
    "testInsufficientImpulseAfterArrivalFailsClosed",
):
    assert token in early_tests, f"missing early-window test: {token}"

for token in (
    "F10500000000000000000001",
    "F10500000000000000000002",
    "F10500000000000000000011",
    "F10500000000000000000012",
    "F10500000000000000000003",
    "F10500000000000000000004",
    "F10500000000000000000013",
    "F10500000000000000000014",
):
    assert project.count(token) >= 2, f"missing Xcode registration: {token}"

for token in (
    "SECOND, independently typed evidence domain",
    "not a true",
    "whole-speaker",
    "subwoofers remain listening-position",
    "Protected Low/Mid/High",
):
    assert token.lower() in doc.lower(), f"missing PR105 safety note: {token}"

assert "Run PR105 characterization tests" in workflow
assert "SpeakerOptimizerEarlyWindowCharacterizationTests" in workflow
assert "Run full XCTest regression" in workflow
print("PR105 speaker characterization + bounded early-window contracts passed")
