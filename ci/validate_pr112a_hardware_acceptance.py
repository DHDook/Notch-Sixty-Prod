#!/usr/bin/env python3
"""PR112A remote-only hardware acceptance infrastructure contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Acceptance/HardwareAcceptance.swift"
CONTROLLER = ROOT / "NotchSixty/Acceptance/HardwareAcceptanceController.swift"
ADAPTERS = ROOT / "NotchSixty/Acceptance/HardwareAcceptanceEvidenceAdapters.swift"
PREFLIGHT = ROOT / "NotchSixty/Acceptance/HardwareAcceptancePreflight.swift"
REPORT = ROOT / "NotchSixty/Acceptance/HardwareAcceptanceReport.swift"
ADAPTER_TESTS = ROOT / "NotchSixtyTests/HardwareAcceptanceEvidenceAdapterTests.swift"
PREFLIGHT_TESTS = ROOT / "NotchSixtyTests/HardwareAcceptancePreflightTests.swift"
REPORT_TESTS = ROOT / "NotchSixtyTests/HardwareAcceptanceReportTests.swift"
UI = ROOT / "NotchSixty/UI/ProductionHardwareAcceptanceWorkspace.swift"
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
TESTS = ROOT / "NotchSixtyTests/HardwareAcceptanceTests.swift"
DOC = ROOT / "docs/PR112A_REMOTE_HARDWARE_ACCEPTANCE.md"
WORKFLOW = ROOT / ".github/workflows/pr112a-remote-hardware-acceptance.yml"
MANIFEST = ROOT / "ci/build_pr112a_remote_hardware_readiness.py"
ROADMAP = ROOT / "docs/ROADMAP.md"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"

for path in (
    SOURCE, CONTROLLER, ADAPTERS, ADAPTER_TESTS, PREFLIGHT,
    PREFLIGHT_TESTS, REPORT, REPORT_TESTS, UI, ROOT_VIEW, APP, TESTS, DOC, WORKFLOW,
    MANIFEST, ROADMAP, PROJECT
):
    assert path.is_file(), f"PR112A missing artifact: {path}"

source = SOURCE.read_text(encoding="utf-8")
controller = CONTROLLER.read_text(encoding="utf-8")
adapters = ADAPTERS.read_text(encoding="utf-8")
adapter_tests = ADAPTER_TESTS.read_text(encoding="utf-8")
preflight = PREFLIGHT.read_text(encoding="utf-8")
preflight_tests = PREFLIGHT_TESTS.read_text(encoding="utf-8")
report = REPORT.read_text(encoding="utf-8")
report_tests = REPORT_TESTS.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")
root_view = ROOT_VIEW.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
manifest = MANIFEST.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
project = PROJECT.read_text(encoding="utf-8")

for gate in ("H01", "H02", "H03", "H04", "H05", "H06", "H07", "H08"):
    assert f'"{gate}"' in source or f'= "{gate}"' in source, f"missing gate {gate}"
    assert gate in doc, f"documentation missing gate {gate}"

for token in (
    "enum HardwareAcceptanceEvidenceAuthority:",
    "case remoteSoftware = 0",
    "case physicalHardware = 1",
    "case independentPhysicalReview = 2",
    "struct HardwareAcceptanceCampaign:",
    "struct HardwareAcceptanceObservation:",
    "struct HardwareAcceptanceEnvironment:",
    "struct HardwareAcceptanceCampaignStore: Sendable",
    "scopeDecisions:",
    "supplementalCapabilities:",
    "coveredCapabilities:",
    ".insufficientScope(",
    ".liveFeedForwardANC",
    "physicalAcceptanceComplete",
    "liveFeedForwardANCAuthorized",
    "newest.outcome",
    ".insufficientAuthority(",
    "options: .atomic",
):
    assert token in source, f"PR112A acceptance contract missing {token}"

for forbidden in (
    "AudioIOEngine",
    "replaceSelectedSystem",
    "makeRealtimeSnapshot(",
    "startPhysical",
    "approveAndApply(",
    "func apply(",
):
    assert forbidden not in source, f"PR112A evidence model gained runtime authority: {forbidden}"

for token in (
    "struct HardwareAcceptanceLinkedEvidence:",
    "enum HardwareAcceptanceLinkedEvidenceKind:",
    "var automaticAuthority:",
    "{ .remoteSoftware }",
    "var canEstablishPhysicalAuthority: Bool { false }",
    "var canAuthorizeLiveFeedForwardANC: Bool { false }",
    "func h03Baseline(",
    "func h04PEQVerification(",
    "func h05MeasurementLab(",
    "func h06FIRVerification(",
    "func h07SingleSubVerification(",
    "func h07MultiSubVerification(",
    "SpeakerOptimizerMeasurementEvidenceEvaluator()",
    "SpeakerMeasurementLabReportBuilder()",
):
    assert token in adapters, f"PR112A evidence adapter missing {token}"

for forbidden in (
    "AudioIOEngine",
    "ProductProfileController",
    "replaceSelectedSystem",
    "approveAndApply",
    "func apply(",
    "physicalHardware",
    "independentPhysicalReview",
):
    assert forbidden not in adapters, f"PR112A adapter gained physical/runtime authority: {forbidden}"

for token in (
    "testQualifiedH03BaselineLinksIdsButStaysRemoteAuthority",
    "testUnqualifiedH03BaselineRecommendsFailureNotPhysicalPass",
    "testH05RequiresWholeSpeakerAndCompleteRepeatedSession",
    "testFinalizedH04PEQVerificationLinksExactReceiptIdentity",
    "testFinalizedH07CoherentVerificationStillNeedsPhysicalAuthority",
):
    assert token in adapter_tests, f"PR112A linked-evidence regression missing {token}"

for token in (
    "struct HardwareAcceptancePreflightAnalyzer: Sendable",
    "HardwareAcceptanceRuntimeSnapshot",
    "HardwareAcceptancePreflightAttestations",
    "readyToBeginPhysicalTest",
    "var physicalAcceptanceEstablished: Bool { false }",
    "var canSatisfyHardwareGate: Bool { false }",
    "var canApplyDSP: Bool { false }",
    "var canDeploy: Bool { false }",
    "var canAuthorizeLiveFeedForwardANC: Bool { false }",
    "var mayMergeIntoMain: Bool { false }",
    "runtime.lifecycleState != .idle",
    "campaign.identity.playbackSystemID",
    "ProtectedDriverCommissioningPlanner()",
    ".validateCurrentState(profile, against: draft)",
    "draft.rollbackSnapshotAvailable",
    "draft.stateDriftCheckRequired",
    "draft.requiresPhysicalCombinedDriverCapture",
    ".sameADCReferenceUnconfirmed",
    ".commonOutputClockUnconfirmed",
    ".safeLineLevelReferenceUnconfirmed",
    ".liveFeedForwardANCNotAuthorized",
    "struct HardwareAcceptanceCommissioningDraftLocator: Sendable",
):
    assert token in preflight, f"PR112A preflight contract missing {token}"

for forbidden in (
    "replaceSelectedSystem",
    "makeRealtimeSnapshot(",
    "engine.start",
    "engine.stop",
    "approveAndApply(",
    "func apply(",
    "physicalAcceptanceEstablished: Bool { true }",
    "canApplyDSP: Bool { true }",
    "canDeploy: Bool { true }",
):
    assert forbidden not in preflight, f"PR112A preflight gained runtime/acceptance authority: {forbidden}"

for token in (
    "testH01ReadyRequiresIdleExactSystemAndStableOutput",
    "testIdentityDirtyStateAndNonIdleLifecycleBlockPreflight",
    "testMeasurementGateRequiresRealADCAndMicrophoneIdentity",
    "testProtectedDriverPreflightRequiresExactPR111RollbackState",
    "testProtectedDriverPreflightDoesNotAcceptMissingLimiter",
    "testCoherentSubPreflightRequiresSameADCClockAndSafeReference",
    "testCoherentSubRequiresIndependentSubRoute",
    "testH08StaysHardBlockedEvenWhenCampaignIncludesIt",
    "testLatestCommissioningDraftLocatorIsPlaybackSystemScoped",
):
    assert token in preflight_tests, f"PR112A preflight regression missing {token}"

for token in (
    "struct HardwareAcceptanceReport:",
    "struct HardwareAcceptanceReportBuilder: Sendable",
    "struct HardwareAcceptanceReportExporter: Sendable",
    "artifactManifest:",
    "unresolvedGateIDs:",
    "runbook:",
    "var releaseAcceptanceComplete: Bool = false",
    "var mayMergeIntoMain: Bool = false",
    "var physicalEvidenceSuppliedByCI: Bool = false",
    "Remote CI cannot create physical evidence",
    "Never feed speaker-level output directly into an ADC",
):
    assert token in report, f"PR112A report/runbook boundary missing {token}"

for forbidden in (
    "AudioIOEngine",
    "ProductProfileController",
    "replaceSelectedSystem",
    "makeRealtimeSnapshot(",
    "approveAndApply(",
    "func apply(",
):
    assert forbidden not in report, f"PR112A report gained runtime authority: {forbidden}"

for token in (
    "testRemotePassStaysInsufficientInMachineAndHumanReport",
    "testArtifactManifestAndObservationsPreserveExactEvidenceIDs",
    "testPhysicalCompletionCanNeverCreateReleaseOrMergeAuthority",
    "testRunbookListsEveryGateAndKeepsSafetyBoundaries",
    "testNewestRegressionAppearsInReportInsteadOfStalePass",
):
    assert token in report_tests, f"PR112A report regression missing {token}"

for token in (
    "final class HardwareAcceptanceController: ObservableObject",
    "func createCampaign(",
    "func loadMostRecentCampaign()",
    "func recordObservation(",
    "physicalAttestationConfirmed: Bool",
    "independentReviewAttestationConfirmed: Bool",
    ".physicalAttestationRequired",
    ".independentReviewAttestationRequired",
    ".gateExcludedFromScope",
    ".invalidSupplementalCoverage",
    "try store.append(",
):
    assert token in controller, f"PR112A campaign controller missing {token}"

for forbidden in (
    "AudioIOEngine",
    "ProductProfileController",
    "replaceSelectedSystem",
    "startProcessing",
    "approveAndApply",
    "func apply(",
):
    assert forbidden not in controller, f"PR112A controller gained runtime/DSP authority: {forbidden}"

for token in (
    "struct ProductionHardwareAcceptanceWorkspace: View",
    '"Hardware Acceptance"',
    '"EVIDENCE ONLY"',
    '"Remote CI cannot pass physical gates"',
    '"Append Evidence Observation"',
    '"Create Immutable Campaign"',
    "physicalAttestation",
    "independentReviewAttestation",
    "splitDriverCovered",
    "acceptance.recordObservation(",
    "engine.selectedOutputDevice",
    '"Run Read-Only Preflight"',
    "HardwareAcceptancePreflightAnalyzer()",
    "HardwareAcceptanceCommissioningDraftLocator()",
    "physicalAcceptanceEstablished = false",
    '"Acceptance Packet & Physical Runbook"',
    '"Export JSON Packet"',
    '"Export Markdown Runbook"',
    "HardwareAcceptanceReportBuilder()",
    "HardwareAcceptanceReportExporter()",
):
    assert token in ui, f"PR112A guided acceptance UI missing {token}"

for forbidden in (
    'Button("Apply',
    "engine.start(",
    "engine.stop(",
    "replaceBassManagement",
    "replaceSpeakerDriver",
    "setRoomCorrection",
    "approveAndApply(",
):
    assert forbidden not in ui, f"PR112A UI gained live mutation authority: {forbidden}"

for token in (
    "case hardwareAcceptance",
    ".hardwareAcceptance,",
    'return "Hardware Acceptance"',
    "ProductionHardwareAcceptanceWorkspace(",
):
    assert token in root_view, f"PR112A production navigation missing {token}"

for token in (
    "let hardwareAcceptance: HardwareAcceptanceController",
    "self.hardwareAcceptance = HardwareAcceptanceController()",
    "hardwareAcceptance.prepareForUse()",
):
    assert token in app, f"PR112A ProductController ownership missing {token}"

for token in (
    "testRemoteSoftwarePassCannotSatisfyPhysicalGate",
    "testSplitDriverExclusionDoesNotWaiveMandatoryH05",
    "testIncludedSplitDriverScopeRequiresExplicitH05Coverage",
    "testControllerRequiresPhysicalAndIndependentAttestations",
    "testControllerRejectsEvidenceForExcludedConditionalGate",
    "testControllerLocksSupplementalCoverageToIncludedScope",
    "testControllerPrepareForUseLoadsNewestCampaign",
    "testRequiredPhysicalCampaignCanCompleteWithConditionalFeaturesExcluded",
    "testLiveANCAuthorizationRequiresIncludedH08IndependentReviewAndAllGates",
    "testNewestObservationCanRegressPreviouslyPassedGate",
    "testDuplicateEvidenceIDIsRejected",
    "testCampaignPersistenceRoundTripAndCorruptionFailClosed",
):
    assert token in tests, f"PR112A regression missing {token}"

for key in (
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    '"liveFeedForwardANCAuthorized": False',
    '"mayMergeIntoMain": False',
    '"physicalEvidenceSuppliedByCI": False',
):
    assert key in manifest, f"PR112A readiness manifest authority changed: {key}"

for token in (
    "remoteSoftware",
    "physicalHardware",
    "independentPhysicalReview",
    "append-only",
    "H05 is **not waived**",
    "PR112A remains OPEN, DRAFT and UNMERGED",
):
    assert token in doc, f"PR112A documentation boundary missing {token}"

for token in (
    "HardwareAcceptance.swift in Sources",
    "HardwareAcceptanceController.swift in Sources",
    "ProductionHardwareAcceptanceWorkspace.swift in Sources",
    "HardwareAcceptanceTests.swift in Sources",
    "HardwareAcceptanceEvidenceAdapters.swift in Sources",
    "HardwareAcceptanceEvidenceAdapterTests.swift in Sources",
    "HardwareAcceptancePreflight.swift in Sources",
    "HardwareAcceptancePreflightTests.swift in Sources",
    "HardwareAcceptanceReport.swift in Sources",
    "HardwareAcceptanceReportTests.swift in Sources",
):
    assert token in project, f"PR112A Xcode target missing {token}"

assert "HardwareAcceptanceTests" in workflow
assert "HardwareAcceptanceEvidenceAdapterTests" in workflow
assert "HardwareAcceptancePreflightTests" in workflow
assert "HardwareAcceptanceReportTests" in workflow
assert "build_pr112a_remote_hardware_readiness.py" in workflow
assert "validate_pr111_protected_driver_optimizer.py" in workflow
assert "PR112A" in roadmap

print("PR112A remote acceptance infrastructure safety contract: PASS")
