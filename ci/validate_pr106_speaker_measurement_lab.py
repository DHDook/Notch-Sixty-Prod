#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCapability.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabCapabilityTests.swift"
SESSION_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabSession.swift"
SESSION_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabSessionTests.swift"
DIRECTIVITY_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabDirectivity.swift"
DIRECTIVITY_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabDirectivityTests.swift"
NEARFIELD_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabNearFieldLF.swift"
NEARFIELD_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabNearFieldLFTests.swift"
GATED_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabQuasiAnechoic.swift"
GATED_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabQuasiAnechoicTests.swift"
CONTROLLER_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabController.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR106_ADVANCED_SPEAKER_MEASUREMENT_LAB.md"
WORKFLOW = ROOT / ".github/workflows/pr106-speaker-measurement-lab.yml"

for path in (SOURCE, TESTS, SESSION_SOURCE, SESSION_TESTS, DIRECTIVITY_SOURCE, DIRECTIVITY_TESTS, NEARFIELD_SOURCE, NEARFIELD_TESTS, GATED_SOURCE, GATED_TESTS, CONTROLLER_SOURCE, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR106 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
session_source = SESSION_SOURCE.read_text()
session_tests = SESSION_TESTS.read_text()
directivity_source = DIRECTIVITY_SOURCE.read_text()
directivity_tests = DIRECTIVITY_TESTS.read_text()
nearfield_source = NEARFIELD_SOURCE.read_text()
nearfield_tests = NEARFIELD_TESTS.read_text()
gated_source = GATED_SOURCE.read_text()
gated_tests = GATED_TESTS.read_text()
controller_source = CONTROLLER_SOURCE.read_text()
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
    "struct SpeakerMeasurementLabProtocol",
    "struct SpeakerMeasurementLabCapture",
    "struct SpeakerMeasurementLabSession",
    "unsupportedAcquisitionMode",
    "struct SpeakerMeasurementLabSessionOrchestrator",
    "struct SpeakerMeasurementLabCaptureBuilder",
    "struct SpeakerMeasurementLabSessionStore",
    "rawCapture",
):
    if token == "rawCapture":
        assert token not in session_source, "raw sweep data must not be persisted in the lab session capture model"
    else:
        assert token in session_source, f"missing PR106 session contract: {token}"

for token in (
    "testSessionSupportsOnlyCurrentlySafeAcquisitionModes",
    "testGuidedStepsFinishAllStationaryRepeatsBeforeNextProtocol",
    "testAnalyzedCaptureBuilderKeepsImpulseButNotRawSweepModel",
    "testAppendEnforcesRepeatSequenceAndCaptureIdentity",
    "testRetryLatestCaptureReturnsProtocolToThatRepeat",
    "testLabSessionPersistenceRoundTripKeepsGeometryAndCompactAnalysis",
):
    assert token in session_tests, f"missing PR106 session test: {token}"

for token in (
    "final class SpeakerMeasurementLabController",
    "capabilityPlanner.plan(",
    "validateCurrentEnvironment",
    "SpeakerMeasurementLabCaptureBuilder",
):
    assert token in controller_source, f"missing PR106 live controller contract: {token}"

for token in (
    "struct SpeakerMeasurementLabDirectivityOptions",
    "struct SpeakerMeasurementLabDirectivityTrace",
    "struct SpeakerMeasurementLabDirectivityReport",
    "SpeakerOptimizerMeasurementEvidenceEvaluator()",
    "maximumDistanceMismatchFraction",
    "relativeMagnitudeDB",
    "var isAnechoic: Bool { false }",
    "var canDeploy: Bool { false }",
):
    assert token in directivity_source, f"missing PR106 directivity contract: {token}"

for token in (
    "testQualifiedOnAxisAndOffAxisProduceRelativeDirectivityTrace",
    "testMultipleAnglesAreSortedByAngularOffset",
    "testDifferentSpeakerCannotBeComparedAsDirectivity",
    "testDistanceMismatchFailsClosed",
    "testInsufficientRepeatsAndLowSNRFailQualification",
    "testClippedOffAxisRepeatFailsQualification",
    "testIncompatibleFrequencyGridFailsClosed",
):
    assert token in directivity_tests, f"missing PR106 directivity test: {token}"

for token in (
    "enum SpeakerMeasurementLabNearFieldComponentKind",
    "struct SpeakerMeasurementLabNearFieldComponent",
    "struct SpeakerMeasurementLabNearFieldLFAnalyzer",
    "maximumAnalysisFrequencyHz: Double = 500",
    "canSynthesizeFarFieldComposite: false",
    "effectiveRadiatingAreaSquareMeters",
    "relativeMagnitudeDB",
    "wrappedRelativePhaseRadians",
    "var isFarFieldPrediction: Bool { false }",
    "var canDeploy: Bool { false }",
):
    assert token in nearfield_source, f"missing PR106 near-field LF contract: {token}"

for token in (
    "testQualifiedRadiatorAndPortProduceLocalRelativeDiagnostics",
    "testMissingAreaMetadataFailsMergeButStillReturnsDiagnostics",
    "testSingleNearFieldProtocolIsUsefulButNotMergeable",
    "testDifferentSubwooferSourcesCannotBeMerged",
    "testLowSNRAndClippingFailRepeatQualification",
    "testAnalysisStaysInsideConfiguredLowFrequencyBand",
    "testComponentMetadataMustBePhysicallyFinite",
):
    assert token in nearfield_tests, f"missing PR106 near-field LF test: {token}"

for token in (
    "F10600000000000000000001",
    "F10600000000000000000002",
    "F10600000000000000000011",
    "F10600000000000000000012",
    "F10600000000000000000003",
    "F10600000000000000000004",
    "F10600000000000000000013",
    "F10600000000000000000014",
    "F10600000000000000000005",
    "F10600000000000000000006",
    "F10600000000000000000015",
    "F10600000000000000000016",
    "F10600000000000000000007",
    "F10600000000000000000008",
    "F10600000000000000000017",
    "F10600000000000000000018",
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
assert "SpeakerMeasurementLabSessionTests" in workflow
assert "SpeakerMeasurementLabDirectivityTests" in workflow
assert "SpeakerMeasurementLabNearFieldLFTests" in workflow
assert "SpeakerMeasurementLabQuasiAnechoicTests" in workflow
assert "Run full XCTest regression" in workflow
assert "Slice 2" in doc
assert "Slice 3" in doc
assert "Repeat-qualified installed-room directivity comparison" in doc
assert "Repeat-qualified near-field LF component diagnostics" in doc
assert "Explicit reflection-window quasi-anechoic estimate" in doc
print("PR106 lab capability + directivity + near-field LF + gated response contracts passed")
