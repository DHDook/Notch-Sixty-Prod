#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCapability.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabCapabilityTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR106_ADVANCED_SPEAKER_MEASUREMENT_LAB.md"
WORKFLOW = ROOT / ".github/workflows/pr106-speaker-measurement-lab.yml"

for path in (SOURCE, TESTS, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR106 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
workflow = WORKFLOW.read_text()

for token in (
    "enum SpeakerMeasurementLabMode",
    "case wholeSpeakerOnAxis",
    "case wholeSpeakerOffAxis",
    "case subwooferNearField",
    "case protectedDriverNearField",
    "case coherentMainsSubTiming",
    "SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount",
    "protectedDriverTransportRequired",
    "authenticatedSharedClockRequired",
    "SpeakerOptimizerMeasurementTransportPlanner",
    "var canDeploy: Bool { false }",
    "var canMutateDSP: Bool { false }",
):
    assert token in source, f"missing PR106 capability contract: {token}"

for token in (
    "testWholeSpeakerOnAxisDelegatesToExistingProtectedPlanner",
    "testOffAxisRequiresActualAngularOffset",
    "testSubwooferNearFieldRequiresSubwooferAndNearFieldDistance",
    "testProtectedDriverNearFieldCannotFallThroughToRawOutput",
    "testCoherentTimingRequiresAuthenticatedSharedClock",
    "testActiveSplitDriverRoutingStillBlocksWholeSpeakerRawTarget",
    "testConfiguredDriverLimiterStillBlocksWholeSpeakerRawTarget",
    "testEveryLabModeRequiresAtLeastThreeRepeats",
):
    assert token in tests, f"missing PR106 capability test: {token}"

for token in (
    "F10600000000000000000001",
    "F10600000000000000000002",
    "F10600000000000000000011",
    "F10600000000000000000012",
):
    assert project.count(token) >= 2, f"missing PR106 Xcode registration: {token}"

for token in (
    "Protected Low/Mid/High driver buses",
    "authenticated shared-clock provenance",
    "canDeploy == false",
    "Near-field subwoofer response",
):
    assert token in doc, f"missing PR106 safety documentation: {token}"

assert "SpeakerMeasurementLabCapabilityTests" in workflow
assert "Run full XCTest regression" in workflow
print("PR106 advanced speaker measurement lab Slice 1 safety contracts passed")
