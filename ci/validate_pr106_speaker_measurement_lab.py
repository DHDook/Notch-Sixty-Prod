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
LEVEL_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabLevelDependence.swift"
LEVEL_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabLevelDependenceTests.swift"
PROTECTED_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabProtectedExcitation.swift"
PROTECTED_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabProtectedExcitationTests.swift"
COHERENT_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCoherentTiming.swift"
COHERENT_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabCoherentTimingTests.swift"
REPORT_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabReport.swift"
REPORT_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabReportTests.swift"
UI_MODEL = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabUIModel.swift"
UI_MODEL_TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabUIModelTests.swift"
LAB_UI = ROOT / "NotchSixty/UI/ProductionSpeakerMeasurementLabWorkspace.swift"
ROOT_UI = ROOT / "NotchSixty/UI/ProductionRootView.swift"
BRIDGE_HEADER = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h"
BRIDGE_SOURCE = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
CONTROLLER_SOURCE = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabController.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR106_ADVANCED_SPEAKER_MEASUREMENT_LAB.md"
WORKFLOW = ROOT / ".github/workflows/pr106-speaker-measurement-lab.yml"

for path in (SOURCE, TESTS, SESSION_SOURCE, SESSION_TESTS, DIRECTIVITY_SOURCE, DIRECTIVITY_TESTS, NEARFIELD_SOURCE, NEARFIELD_TESTS, GATED_SOURCE, GATED_TESTS, LEVEL_SOURCE, LEVEL_TESTS, PROTECTED_SOURCE, PROTECTED_TESTS, COHERENT_SOURCE, COHERENT_TESTS, REPORT_SOURCE, REPORT_TESTS, BRIDGE_HEADER, BRIDGE_SOURCE, CONTROLLER_SOURCE, PROJECT, DOC, WORKFLOW):
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
level_source = LEVEL_SOURCE.read_text()
level_tests = LEVEL_TESTS.read_text()
protected_source = PROTECTED_SOURCE.read_text()
protected_tests = PROTECTED_TESTS.read_text()
coherent_source = COHERENT_SOURCE.read_text()
coherent_tests = COHERENT_TESTS.read_text()
report_source = REPORT_SOURCE.read_text()
report_tests = REPORT_TESTS.read_text()
ui_model = UI_MODEL.read_text()
ui_model_tests = UI_MODEL_TESTS.read_text()
lab_ui = LAB_UI.read_text()
root_ui = ROOT_UI.read_text()
bridge_header = BRIDGE_HEADER.read_text()
bridge_source = BRIDGE_SOURCE.read_text()
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
    "testProtectedDriverNearFieldUnlocksOnlyDedicatedProtectedPath",
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
    "testProtectedDriverProtocolRequiresExplicitConservativeLevel",
    "testProtectedDriverCapturePersistsExactProtectionProvenance",
    "testGuidedStepsFinishAllStationaryRepeatsBeforeNextProtocol",
    "testAnalyzedCaptureBuilderKeepsImpulseButNotRawSweepModel",
    "testAppendEnforcesRepeatSequenceAndCaptureIdentity",
    "testRetryLatestCaptureReturnsProtocolToThatRepeat",
    "testLabSessionPersistenceRoundTripKeepsGeometryAndCompactAnalysis",
    "testDualInputTargetedBridgeCapturesMicAndReferenceOnSameTimeline",
    "testSharedClockReferenceConfigurationRequiresSameADCAndDistinctChannel",
    "testQualifiedSharedClockReferencePersistsWithCapture",
    "testLowSNRReferenceFailsClosedAndCannotAuthenticateTimeOrigin",
    "testSharedReferenceDoesNotYetUnblockCoherentMainsSubProtocol",
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
    "N60TargetedRoomMeasurementBridgeCreateDualInput",
    "N60TargetedRoomMeasurementProcessDualStrided",
    "N60TargetedRoomMeasurementBridgeCopyReferenceCapture",
):
    assert token in (ROOT / "NotchSixty/Audio/Realtime/N60TargetedRoomMeasurementBridge.h").read_text(), f"missing dual-input shared-time bridge contract: {token}"

for token in (
    "SpeakerMeasurementLabSharedClockReferenceConfiguration",
    "SpeakerMeasurementLabSharedClockReferenceEvidence",
    "SpeakerMeasurementLabSharedClockReferenceEvaluator",
    "sharedClockReferenceConfiguration",
    "sharedClockReference",
    "sharedClockReferenceUnqualified",
):
    assert token in session_source, f"missing shared-time reference session contract: {token}"

for token in (
    "referenceInputChannelIndex",
    "referenceSamples",
    "N60TargetedRoomMeasurementBridgeCreateDualInput",
):
    assert token in (ROOT / "NotchSixty/Audio/CoreAudio/MultichannelCalibrationTransport.swift").read_text(), f"missing shared-time reference transport contract: {token}"

for token in (
    "SpeakerMeasurementLabProtectedTransportFactory",
    "protectedTransportFactory",
    "protectedExcitationCompiler.compile(",
    "protectedRoutePlanner.plan(",
    "makeAnalysisProgram(",
    "validateProtectedStateImmediatelyBeforeStart",
    "protectedDriverProvenance",
):
    assert token in controller_source or token in session_source, f"missing PR106 protected live path contract: {token}"

for token in (
    "struct SpeakerMeasurementLabLevelDependenceOptions",
    "struct SpeakerMeasurementLabLevelDependenceReport",
    "SpeakerMeasurementLabLevelDependenceAnalyzer",
    "minimumExcitationStepDB: Double = 6.0",
    "maximumExcitationStepDB: Double = 18.0",
    "normalizedTransferDeltaDB",
    "shapeOnlyDeltaDB",
    "isTHDMeasurement: Bool { false }",
    "isIMDMeasurement: Bool { false }",
    "var canDeploy: Bool { false }",
):
    assert token in level_source, f"missing PR106 level-dependence contract: {token}"

for token in (
    "testBoundedTwoLevelTransferDetectsLocalizedCompression",
    "testIdenticalNormalizedTransferIsNearLinearAcrossLevels",
    "testExplicitLevelsAndBoundedStepAreRequired",
    "testGeometryAndSourceMustMatch",
    "testLowSNRClippingAndCaptureLevelMismatchFailClosed",
    "testProtocolLevelIsPersistedAndResolvedForAcquisition",
):
    assert token in level_tests, f"missing PR106 level-dependence test: {token}"

for token in (
    "excitationLevelDBFS: Double? = nil",
    "resolvedExcitationLevelDBFS",
):
    assert token in session_source, f"missing protocol excitation provenance: {token}"

assert "step.labProtocol.resolvedExcitationLevelDBFS" in controller_source
assert "excitationLevelDBFS: program.settings.levelDBFS" in controller_source

for token in (
    "struct SpeakerMeasurementLabProtectedExcitationOptions",
    "struct SpeakerMeasurementLabProtectedExcitation",
    "SpeakerMeasurementLabProtectedExcitationCompiler",
    "maximumInputPeakDBFS: Double = -24",
    "limiterProtected",
    "canStartPhysicalMeasurement: Bool { false }",
    "var canDeploy: Bool { false }",
):
    assert token in protected_source, f"missing protected excitation compiler contract: {token}"

for token in (
    "testBiAmpHighDriverProgramUsesCrossoverAndLimiter",
    "testBiAmpLowDriverRejectsHighFrequencyEnergy",
    "testTriAmpMidBusIsSupportedThroughExactProtectedPath",
    "testProtectedCompilerRequiresExactTargetLimiter",
    "testProtectedCompilerRejectsFullRangeSubAndMainsSub",
    "testProtectedCompilerRejectsHotOrNonFiniteExcitation",
    "testCapabilityPlannerStillBlocksLiveProtectedDriverTransport",
):
    assert token in protected_tests, f"missing protected excitation test: {token}"

assert "N60ProtectedSpeakerBusRenderProgram" in bridge_header
assert "process_speaker_bus_splitter(" in bridge_source
assert "N60SpeakerDriverProcessingRuntimeProcessValues(" in bridge_source
assert "targetDriver->limiterEnabled" in bridge_source

for token in (
    "struct SpeakerMeasurementLabCoherentTimingOptions",
    "struct SpeakerMeasurementLabCoherentTimingReport",
    "SpeakerMeasurementLabCoherentTimingAnalyzer",
    "crossSourceClockProvenanceAuthenticated: Bool { true }",
    "maximumReferenceArrivalSpreadMilliseconds",
    "maximumReferenceMagnitudeRepeatabilityRMSDB",
    "minimumReferencePhaseConsistency",
    "canDeploy: Bool { false }",
    "canMutateDSP: Bool { false }",
):
    assert token in coherent_source, f"missing coherent timing contract: {token}"

for token in (
    "testLinkedMainSubPairWithStableReferenceAuthenticatesTiming",
    "testReferenceArrivalDriftFailsClosed",
    "testReferenceMagnitudeOrPhaseInstabilityFailsClosed",
    "testCoherentSessionRequiresReferenceAndMatchedPairGeometryLevel",
    "testCapabilityStillBlocksCoherentRequestWithoutLinkedReferenceLeg",
):
    assert token in coherent_tests, f"missing coherent timing test: {token}"

for token in (
    "enum SpeakerMeasurementLabCoherentLeg",
    "coherentPairID",
    "coherentLeg",
    "coherentPairInvalid",
):
    assert token in session_source, f"missing coherent pair session contract: {token}"

for token in (
    "struct SpeakerMeasurementLabCompactReport",
    "SpeakerMeasurementLabReportBuilder",
    "SpeakerMeasurementLabReportExporter",
    "var measurementOnly: Bool = true",
    "var canDeploy: Bool = false",
    "var containsRawImpulseData: Bool = false",
    "listRecentSessions",
):
    assert token in report_source, f"missing PR106 compact report contract: {token}"

for token in (
    "testCompactReportExcludesRawImpulseAndTransferArrays",
    "testCSVHasCompactProtocolAndAnalysisSections",
    "testRecentSessionListingIsNewestFirstAndIgnoresInvalidJSON",
):
    assert token in report_tests, f"missing PR106 report/export test: {token}"

for token in (
    "struct SpeakerMeasurementLabProtocolDraft",
    "func makeProtocols(",
    "case .protectedDriverNearField",
    "case .coherentMainsSubTiming",
    "coherentPairID: pairID",
    "coherentLeg: .main",
    "coherentLeg: .subwoofer",
):
    assert token in ui_model, f"missing production Lab composer contract: {token}"

for token in (
    "testOnAxisDraftBuildsValidWholeSpeakerProtocol",
    "testSubNearFieldDraftCarriesComponentMetadata",
    "testProtectedDriverDraftAlwaysUsesBoundedExplicitLevel",
    "testCoherentDraftCreatesLinkedMainAndSubLegs",
    "testInvalidGeometryAndRepeatCountFailBeforeSessionStart",
):
    assert token in ui_model_tests, f"missing production Lab composer test: {token}"

for token in (
    "struct ProductionSpeakerMeasurementLabWorkspace",
    "Advanced Speaker Measurement Lab",
    "MEASUREMENT ONLY",
    "Start New Lab Session",
    "Measure Next Repeat",
    "Export JSON",
    "Export CSV",
    "Recent Lab Sessions",
    "SpeakerMeasurementLabReportBuilder",
):
    assert token in lab_ui, f"missing production Lab UI contract: {token}"

assert "case measurementLab" in root_ui
assert "ProductionSpeakerMeasurementLabWorkspace(" in root_ui

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
    "F10600000000000000000009",
    "F1060000000000000000000A",
    "F10600000000000000000019",
    "F1060000000000000000001A",
    "F1060000000000000000000B",
    "F1060000000000000000000C",
    "F1060000000000000000001B",
    "F1060000000000000000001C",
    "F1060000000000000000000D",
    "F1060000000000000000000E",
    "F1060000000000000000001D",
    "F1060000000000000000001E",
    "F1060000000000000000000F",
    "F10600000000000000000010",
    "F1060000000000000000001F",
    "F10600000000000000000020",
    "F10600000000000000000021",
    "F10600000000000000000022",
    "F10600000000000000000031",
    "F10600000000000000000032",
    "F10600000000000000000023",
    "F10600000000000000000024",
    "F10600000000000000000025",
    "F10600000000000000000033",
    "F10600000000000000000034",
    "F10600000000000000000035",
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
assert "SpeakerMeasurementLabLevelDependenceTests" in workflow
assert "SpeakerMeasurementLabProtectedExcitationTests" in workflow
assert "SpeakerMeasurementLabCoherentTimingTests" in workflow
assert "SpeakerMeasurementLabReportTests" in workflow
assert "SpeakerMeasurementLabUIModelTests" in workflow
assert "Run full XCTest regression" in workflow
assert "Slice 2" in doc
assert "Simultaneous shared-time reference capture substrate" in doc
assert "Reference-aligned coherent mains/sub diagnostics" in doc
assert "Compact report and export foundation" in doc
assert "Production Advanced Speaker Measurement Lab UI" in doc
assert "Slice 3" in doc
assert "Repeat-qualified installed-room directivity comparison" in doc
assert "Repeat-qualified near-field LF component diagnostics" in doc
assert "Explicit reflection-window quasi-anechoic estimate" in doc
assert "Bounded two-level transfer level-dependence diagnostic" in doc
assert "Exact protected-driver excitation compiler substrate" in doc
print("PR106 advanced Lab diagnostics + protected/coherent acquisition + production UI contracts passed")
