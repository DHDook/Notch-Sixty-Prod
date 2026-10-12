#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerCharacterizationMeasurement.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCharacterizationMeasurementTests.swift"
EARLY_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerEarlyWindowCharacterization.swift"
EARLY_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerEarlyWindowCharacterizationTests.swift"
CLASSIFIER_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerCrossDomainClassifier.swift"
CLASSIFIER_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCrossDomainClassifierTests.swift"
AWARE_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerClassificationAwareCandidates.swift"
AWARE_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerClassificationAwareCandidateTests.swift"
GUIDED_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerCharacterizationController.swift"
GUIDED_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCharacterizationControllerTests.swift"
UI_SOURCE = ROOT / "NotchSixty/UI/ProductionMultichannelCalibrationWorkspace.swift"
COMMISSION_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerCommissioningContract.swift"
COMMISSION_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCommissioningContractTests.swift"
DEPLOY_SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerPEQDeployment.swift"
DEPLOY_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerPEQDeploymentTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR105_SPEAKER_CHARACTERIZATION_AND_VERIFICATION.md"
WORKFLOW = ROOT / ".github/workflows/pr105-speaker-characterization.yml"

for path in (SOURCE, TESTS, EARLY_SOURCE, EARLY_TESTS, CLASSIFIER_SOURCE, CLASSIFIER_TESTS, AWARE_SOURCE, AWARE_TESTS, GUIDED_SOURCE, GUIDED_TESTS, UI_SOURCE, COMMISSION_SOURCE, COMMISSION_TESTS, DEPLOY_SOURCE, DEPLOY_TESTS, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR105 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
early_source = EARLY_SOURCE.read_text()
early_tests = EARLY_TESTS.read_text()
classifier_source = CLASSIFIER_SOURCE.read_text()
classifier_tests = CLASSIFIER_TESTS.read_text()
aware_source = AWARE_SOURCE.read_text()
aware_tests = AWARE_TESTS.read_text()
guided_source = GUIDED_SOURCE.read_text()
guided_tests = GUIDED_TESTS.read_text()
ui_source = UI_SOURCE.read_text()
commission_source = COMMISSION_SOURCE.read_text()
commission_tests = COMMISSION_TESTS.read_text()
deploy_source = DEPLOY_SOURCE.read_text()
deploy_tests = DEPLOY_TESTS.read_text()
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
    "enum SpeakerOptimizerDeviationClassification",
    "case speakerPersistent",
    "case roomSeatDependent",
    "case ambiguous",
    "case noMaterialDeviation",
    "supportsSpeakerCorrection",
    "var canDeploy: Bool { false }",
    "localResidual(",
):
    assert token in classifier_source, f"missing cross-domain classifier contract: {token}"

for token in (
    "testMatchingSpeakerAndSeatFeatureClassifiesSpeakerPersistent",
    "testSeatSpecificNullWithFlatCharacterizationClassifiesRoomDependent",
    "testDomainDisagreementRemainsAmbiguous",
    "testFlatDomainsDoNotManufactureSpeakerDefect",
    "testAbsoluteMeasurementLevelDifferenceDoesNotDriveClassification",
    "testMissingEarlyWindowRepeatsFailClosed",
):
    assert token in classifier_tests, f"missing cross-domain classifier test: {token}"

for token in (
    "struct SpeakerOptimizerCorrectionEvidenceMask",
    "authorizedForSpeakerCorrection",
    "maximumProtectedLeakageDB: Double = 0.5",
    "SpeakerOptimizerClassificationAwareCandidateDesigner",
    "designPEQ(",
    "designFIR(",
    "classification == .speakerPersistent",
    "var canDeploy: Bool { false }",
):
    assert token in aware_source, f"missing classification-aware candidate contract: {token}"

for token in (
    "testMaskAuthorizesOnlySpeakerPersistentPointsAndProtectsUnknownBand",
    "testGuidedPEQCorrectsPersistentFeatureButProtectsRoomFeature",
    "testGuidedFIRNeverLeaksMaterialCorrectionIntoRoomDependentFeature",
    "testGuidedPathRecomputesClassificationAndFailsOnDomainIdentityDrift",
):
    assert token in aware_tests, f"missing classification-aware candidate test: {token}"

for token in (
    "final class SpeakerOptimizerCharacterizationController",
    "startOrResumeSession(",
    "SpeakerOptimizerCharacterizationCaptureBuilder",
    "attachingEarlyWindowEvidence",
    "earlyWindowEvidenceComplete",
    "characterizationReady",
    "struct SpeakerOptimizerCrossDomainSummary",
):
    assert token in guided_source, f"missing guided characterization controller contract: {token}"

for token in (
    "testCurrentCharacterizationStoreRoundTripAndDelete",
    "testCrossDomainSummaryCountsEveryClassificationWithoutGrantingApply",
):
    assert token in guided_tests, f"missing guided characterization test: {token}"

for token in (
    "Speaker Optimizer · Speaker Characterization",
    "Step 2 · Characterize each whole speaker",
    "Step 3 · Compare speaker vs room evidence",
    "Only speaker-persistent regions may drive",
):
    assert token in ui_source, f"missing guided Speaker Calibration UI contract: {token}"

for token in (
    "struct SpeakerOptimizerCommissioningProposal",
    "struct SpeakerOptimizerRollbackSnapshot",
    "struct SpeakerOptimizerApplyApproval",
    "userInitiated: Bool",
    "blockedDedicatedSpeakerOptimizerPEQStageUnavailable",
    "blockedDedicatedSpeakerOptimizerFIRStageUnavailable",
    "var canApply: Bool",
    "aggregateCandidateFingerprint",
    "deploymentStageUnavailable",
):
    assert token in commission_source, f"missing commissioning safety contract: {token}"

for token in (
    "testPEQProposalCapturesRollbackStateAndBlocksExistingCalibrationStageReuse",
    "testFIRProposalFailsClosedBecauseNoDedicatedPerSpeakerFIRStageExists",
    "testExplicitApprovalIsBoundToExactCandidateFingerprintButStillCannotApply",
    "testApprovalCannotBeReusedAfterCandidateChanges",
    "testProfileOrClassificationIdentityDriftFailsClosed",
):
    assert token in commission_tests, f"missing commissioning contract test: {token}"

for token in (
    "struct SpeakerOptimizerPEQDeploymentConfiguration",
    "SpeakerOptimizerDeployedPEQBand",
    "gainRangeDB = -12.0...0.0",
    "maximumBandsPerSource = 10",
    "N60_PROGRAM_LANE_MAX_EQ_SECTIONS",
    "aggregateCandidateFingerprint",
):
    assert token in deploy_source, f"missing dedicated PEQ deployment contract: {token}"

for token in (
    "testOptimizerPEQIsSeparateFromSpeakerCalibrationAndCompilesAfterIt",
    "testAggregateLaneCapacityFailsClosedBeforeRuntimeCompilation",
    "testOptimizerDeploymentRejectsBoostAndLFE",
    "testOptimizerMetadataDoesNotChangeMeasurementRoutingSignature",
):
    assert token in deploy_tests, f"missing dedicated PEQ deployment test: {token}"

for token in (
    "F10500000000000000000001",
    "F10500000000000000000002",
    "F10500000000000000000011",
    "F10500000000000000000012",
    "F10500000000000000000003",
    "F10500000000000000000004",
    "F10500000000000000000013",
    "F10500000000000000000014",
    "F10500000000000000000005",
    "F10500000000000000000006",
    "F10500000000000000000015",
    "F10500000000000000000016",
    "F10500000000000000000007",
    "F10500000000000000000008",
    "F10500000000000000000017",
    "F10500000000000000000018",
    "F10500000000000000000009",
    "F1050000000000000000000A",
    "F10500000000000000000019",
    "F1050000000000000000001A",
    "F1050000000000000000000B",
    "F1050000000000000000000C",
    "F1050000000000000000001B",
    "F1050000000000000000001C",
    "F1050000000000000000000D",
    "F1050000000000000000000E",
    "F1050000000000000000001D",
    "F1050000000000000000001E",
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
assert "SpeakerOptimizerCrossDomainClassifierTests" in workflow
assert "SpeakerOptimizerClassificationAwareCandidateTests" in workflow
assert "SpeakerOptimizerCharacterizationControllerTests" in workflow
assert "SpeakerOptimizerCommissioningContractTests" in workflow
assert "SpeakerOptimizerPEQDeploymentTests" in workflow
assert "Run full XCTest regression" in workflow
assert "Cross-domain speaker-vs-room classification" in doc
assert "Classification-aware PEQ/FIR correction authority" in doc
assert "Guided Speaker Calibration workflow" in doc
assert "Commissioning contract, explicit approval & rollback snapshot" in doc
assert "Separately owned live PEQ deployment substrate" in doc
print("PR105 guided optimizer + commissioning + dedicated PEQ deployment contracts passed")
