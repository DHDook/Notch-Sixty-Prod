#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignment.swift"
TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentTests.swift"
COMMISSIONING = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignmentCommissioning.swift"
COMMISSIONING_TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentCommissioningTests.swift"
APPLY = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignmentApplyTransaction.swift"
APPLY_TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentApplyTransactionTests.swift"
VERIFY = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignmentPostApplyVerification.swift"
VERIFY_TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentPostApplyVerificationTests.swift"
DEPLOYMENT = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignmentDeployment.swift"
MULTI = ROOT / "NotchSixty/Audio/CoherentMultiSubwooferAlignment.swift"
MULTI_TESTS = ROOT / "NotchSixtyTests/CoherentMultiSubwooferAlignmentTests.swift"
MULTI_COMMISSIONING = ROOT / "NotchSixty/Audio/CoherentMultiSubwooferAlignmentCommissioning.swift"
MULTI_COMMISSIONING_TESTS = ROOT / "NotchSixtyTests/CoherentMultiSubwooferAlignmentCommissioningTests.swift"
MULTI_DEPLOYMENT = ROOT / "NotchSixty/Audio/CoherentMultiSubwooferAlignmentDeployment.swift"
MULTI_APPLY = ROOT / "NotchSixty/Audio/CoherentMultiSubwooferAlignmentApplyTransaction.swift"
MULTI_APPLY_TESTS = ROOT / "NotchSixtyTests/CoherentMultiSubwooferAlignmentApplyTransactionTests.swift"
MULTI_VERIFY = ROOT / "NotchSixty/Audio/CoherentMultiSubwooferAlignmentPostApplyVerification.swift"
MULTI_VERIFY_TESTS = ROOT / "NotchSixtyTests/CoherentMultiSubwooferAlignmentPostApplyVerificationTests.swift"
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
COHERENT = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCoherentTiming.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR108_COHERENT_SUBWOOFER_ALIGNMENT.md"
WORKFLOW = ROOT / ".github/workflows/pr108-coherent-subwoofer-alignment.yml"
GUIDED = ROOT / "NotchSixty/Audio/CoherentSubwooferAlignmentGuidedWorkflow.swift"
GUIDED_TESTS = ROOT / "NotchSixtyTests/CoherentSubwooferAlignmentGuidedWorkflowTests.swift"
LAB_UI = ROOT / "NotchSixty/UI/ProductionSpeakerMeasurementLabWorkspace.swift"
CLOSURE = ROOT / "docs/PR108_SOFTWARE_CLOSURE.md"
PHYSICAL = ROOT / "docs/PR108_PHYSICAL_ACCEPTANCE.md"
ROADMAP = ROOT / "docs/ROADMAP.md"

for path in (SOURCE, TESTS, COMMISSIONING, COMMISSIONING_TESTS, APPLY, APPLY_TESTS, VERIFY, VERIFY_TESTS, DEPLOYMENT, MULTI, MULTI_TESTS, MULTI_COMMISSIONING, MULTI_COMMISSIONING_TESTS, MULTI_DEPLOYMENT, MULTI_APPLY, MULTI_APPLY_TESTS, MULTI_VERIFY, MULTI_VERIFY_TESTS, PROFILE, COHERENT, CALIBRATION, PROJECT, DOC, WORKFLOW, GUIDED, GUIDED_TESTS, LAB_UI, CLOSURE, PHYSICAL, ROADMAP):
    assert path.is_file(), f"missing PR108 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
commissioning = COMMISSIONING.read_text()
commissioning_tests = COMMISSIONING_TESTS.read_text()
apply_source = APPLY.read_text()
apply_tests = APPLY_TESTS.read_text()
verify_source = VERIFY.read_text()
verify_tests = VERIFY_TESTS.read_text()
deployment = DEPLOYMENT.read_text()
multi = MULTI.read_text()
multi_tests = MULTI_TESTS.read_text()
multi_commissioning = MULTI_COMMISSIONING.read_text()
multi_commissioning_tests = MULTI_COMMISSIONING_TESTS.read_text()
multi_deployment = MULTI_DEPLOYMENT.read_text()
multi_apply = MULTI_APPLY.read_text()
multi_apply_tests = MULTI_APPLY_TESTS.read_text()
multi_verify = MULTI_VERIFY.read_text()
multi_verify_tests = MULTI_VERIFY_TESTS.read_text()
profile_source = PROFILE.read_text()
coherent = COHERENT.read_text()
calibration = CALIBRATION.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
workflow = WORKFLOW.read_text()
guided = GUIDED.read_text()
guided_tests = GUIDED_TESTS.read_text()
lab_ui = LAB_UI.read_text()
closure = CLOSURE.read_text()
physical = PHYSICAL.read_text()
roadmap = ROADMAP.read_text()

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
    "testSingleSubPlannerBlocksMultiSubProfileUntilCoordinated",
):
    assert token in tests, f"missing PR108 proposal test: {token}"


for token in (
    "struct CoherentSubwooferAlignmentCommissioningPlanner",
    "struct CoherentSubwooferAlignmentCommissioningProposal",
    "CoherentSubwooferAlignmentRollbackSnapshot",
    "fingerprintReports",
    "fingerprintCandidate",
    "makeExplicitApproval",
    "var canApply: Bool { readyForApproval }",
    "var canDeploy: Bool { canApply }",
):
    assert token in commissioning, f"missing PR108 commissioning contract: {token}"

for token in (
    "testProposalBindsExactEvidenceCandidateAndPlaybackSnapshot",
    "testCommissioningRecomputesCandidateAndRejectsDrift",
    "testCrossoverChangeInvalidatesCommissioning",
    "testExplicitApprovalIsRequiredAndFingerprintBound",
    "testEvidenceFingerprintChangesWhenMeasuredPhaseChanges",
):
    assert token in commissioning_tests, f"missing PR108 commissioning test: {token}"


for token in (
    "struct CoherentSubwooferAlignmentApplyTransaction",
    "struct CoherentSubwooferAlignmentApplyReceipt",
    "speakerCommonDelayAdjustmentMilliseconds",
    "subwooferDelayAdjustmentMilliseconds",
    "resultingSubwooferPolarityInverted",
    "currentStateDrift",
    "rollbackStateDrift",
    "requiresMeasuredVerification",
):
    assert token in apply_source, f"missing PR108 Apply transaction contract: {token}"

for token in (
    "testLateSubApplyAddsCommonSpeakerDelayAndRollbackRestoresSnapshot",
    "testEarlySubApplyAddsOnlyPhysicalSubDelay",
    "testPolarityCandidateMutatesOnlyPhysicalSubPolarity",
    "testApplyRequiresIdleAndExactCommissioningSnapshot",
    "testStaleApprovalAndPostApplyStateDriftFailClosed",
):
    assert token in apply_tests, f"missing PR108 Apply test: {token}"


for token in (
    "struct CoherentSubwooferAlignmentPostApplyVerifier",
    "struct CoherentSubwooferAlignmentVerificationReport",
    "verificationSession.validateStructure",
    "capturedAt > receipt.appliedAt",
    "maximumPhaseTrackingRMSRadians",
    "maximumMagnitudeTrackingRMSDB",
    "minimumMeasuredImprovementDB",
    "shouldRollback",
):
    assert token in verify_source, f"missing PR108 fresh verification contract: {token}"

for token in (
    "testFreshSessionAcceptsMeasuredAppliedTimingShift",
    "testFreshSessionThatDoesNotTrackAppliedDelayIsRejected",
    "testVerificationCapturesMustAllBeAfterApply",
    "testVerificationRejectsCurrentStateAndBaselineDrift",
):
    assert token in verify_tests, f"missing PR108 fresh verification test: {token}"


for token in (
    "struct CoherentSubwooferAlignmentDeploymentRecord",
    "struct CoherentSubwooferAlignmentVerificationRecord",
    "expectedSpeakerDelays",
    "expectedSubwooferDelayMilliseconds",
    "provisional",
    "verified",
    "verification",
):
    assert token in deployment, f"missing PR108 persistent provenance contract: {token}"

for token in (
    "finalizeVerified",
    "CoherentSubwooferAlignmentVerificationFinalizationReceipt",
    "rollbackSourceStateMatches",
    "coherentSubwooferAlignment",
):
    assert token in apply_source, f"missing PR108 verification finalization contract: {token}"

for token in (
    "testProvenanceInvalidatesIfLiveCalibrationDrifts",
    "testLegacyOutputProfileWithoutPR108ProvenanceDecodes",
):
    assert token in apply_tests, f"missing PR108 provenance persistence test: {token}"

assert "finalizeVerified" in verify_tests
assert "deployment.verified" in verify_tests


for token in (
    "struct CoherentMultiSubwooferAlignmentPlanner",
    "struct CoherentMultiSubwooferAlignmentCandidate",
    "speakerCommonDelayAdjustmentMilliseconds",
    "subwooferDelayAdjustmentMilliseconds",
    "coordinatedMultiSubwooferMode: true",
    "duplicateSubwoofer",
    "mainRoleSetMismatch",
    "var canDeploy: Bool { false }",
):
    assert token in multi, f"missing PR108 coordinated multi-Sub contract: {token}"

for token in (
    "testCoordinatedSolveUsesMinimumLatencyCommonSpeakerDelay",
    "testCoordinatedSolveCarriesIndependentPolarityPerSub",
    "testDuplicateAndIncompleteEvidenceFailClosed",
    "testEverySubMustUseSameMainRoleSet",
    "testCoordinatedSolveRespectsRemainingSpeakerDelayCapacity",
):
    assert token in multi_tests, f"missing PR108 coordinated multi-Sub test: {token}"


for token in (
    "struct CoherentMultiSubwooferAlignmentCommissioningPlanner",
    "struct CoherentMultiSubwooferAlignmentCommissioningProposal",
    "fingerprintEvidenceGroups",
    "fingerprintCandidate",
    "makeExplicitApproval",
    "var canApply: Bool { readyForApproval }",
    "var canDeploy: Bool { canApply }",
):
    assert token in multi_commissioning, f"missing PR108 coordinated multi-Sub commissioning contract: {token}"

for token in (
    "testProposalBindsAllSubEvidenceAndPlaybackSnapshot",
    "testEvidenceGroupOrderDoesNotChangeFingerprint",
    "testCommissioningRegeneratesAndRejectsCandidateDrift",
    "testEvidenceMutationChangesAtomicFingerprint",
    "testExplicitApprovalIsFingerprintBound",
):
    assert token in multi_commissioning_tests, f"missing PR108 coordinated multi-Sub commissioning test: {token}"


for token in (
    "struct CoherentMultiSubwooferAlignmentDeploymentRecord",
    "CoherentMultiSubwooferAlignmentSubDeploymentRecord",
    "speakerCommonDelayAdjustmentMilliseconds",
    "expectedSpeakerDelays",
    "expectedSubwooferDelayMilliseconds",
    "provisional",
    "CoherentMultiSubwooferAlignmentVerificationRecord",
    "verification",
    "verified",
):
    assert token in multi_deployment, f"missing PR108 coordinated multi-Sub provenance contract: {token}"

for token in (
    "struct CoherentMultiSubwooferAlignmentApplyTransaction",
    "struct CoherentMultiSubwooferAlignmentApplyReceipt",
    "coherentMultiSubwooferAlignment",
    "currentStateDrift",
    "rollbackStateDrift",
    "requiresMeasuredVerification",
    "finalizeVerified",
    "CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt",
    "rollbackSourceStateMatches",
):
    assert token in multi_apply, f"missing PR108 coordinated multi-Sub Apply contract: {token}"

for token in (
    "testApplyMaterializesSharedDelayOnceAndEverySubAtomically",
    "testApplyCarriesIndependentSubPolarity",
    "testApplyRequiresIdleExactSnapshotAndFreshApproval",
    "testRollbackRefusesUnrelatedPostApplyEdit",
):
    assert token in multi_apply_tests, f"missing PR108 coordinated multi-Sub Apply test: {token}"

assert "coherentMultiSubwooferAlignment" in profile_source
assert "coherentSubwooferAlignment != nil" in profile_source
assert "coherentMultiSubwooferAlignment != nil" in profile_source


for token in (
    "struct CoherentMultiSubwooferAlignmentPostApplyVerifier",
    "struct CoherentMultiSubwooferAlignmentVerificationReport",
    "verificationPairIDsBySubwoofer",
    "capturedAt > receipt.appliedAt",
    "maximumPhaseTrackingRMSRadians",
    "maximumMagnitudeTrackingRMSDB",
    "minimumMeasuredImprovementDB",
    "shouldRollback",
):
    assert token in multi_verify, f"missing PR108 coordinated fresh verification contract: {token}"

for token in (
    "testFreshCoordinatedSessionAcceptsEveryAppliedSubSignature",
    "testOneUncorrectedSubRejectsWholeCoordinatedVerification",
    "testPairSetAndFreshnessMustCoverEverySub",
    "testBaselineAndCurrentStateDriftFailClosed",
    "finalizeVerified",
    "deployment.verified",
):
    assert token in multi_verify_tests, f"missing PR108 coordinated fresh verification test: {token}"


for token in (
    "final class CoherentSubwooferAlignmentGuidedController",
    "func prepareReview(",
    "func approveAndApply(",
    "func verify(",
    "func rollback(",
    "func resetAfterRollback()",
    "case singleSubwoofer",
    "case coordinatedMultiSubwoofer",
):
    assert token in guided, f"missing PR108 guided commissioning contract: {token}"

for token in (
    "testSingleSubGuidedReviewApplyAndRollback",
    "testMultiSubGuidedReviewUsesAtomicCoordinatedPath",
    "testAcceptedSingleVerificationFinalizesAndCanRollback",
    "testRejectedMultiVerificationAutomaticallyRollsBack",
    "testReviewRequiresExactAssignedSubEvidence",
):
    assert token in guided_tests, f"missing PR108 guided commissioning test: {token}"

for token in (
    "coherentAlignmentCard",
    "Generate Alignment Proposal",
    "Approve & Apply Provisionally",
    "Start Fresh Verification Session",
    "Verify Current Lab Session",
    "persistedAlignmentStatus",
    "Persisted PR108 alignment · VERIFIED",
    "coherentMultiSubwooferAlignment",
    "coherentSubwooferAlignment",
):
    assert token in lab_ui, f"missing PR108 production commissioning UI: {token}"

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
    "F10800000000000000000003",
    "F10800000000000000000004",
    "F10800000000000000000005",
    "F10800000000000000000006",
    "F10800000000000000000007",
    "F10800000000000000000008",
    "F10800000000000000000009",
    "F1080000000000000000000A",
    "F1080000000000000000000B",
    "F1080000000000000000000C",
    "F1080000000000000000000D",
    "F1080000000000000000000E",
    "F1080000000000000000000F",
    "F10800000000000000000010",
    "F10800000000000000000011",
    "F10800000000000000000012",
    "F10800000000000000000013",
    "F10800000000000000000014",
    "F10800000000000000000015",
    "F10800000000000000000016",
    "F10800000000000000000017",
    "F10800000000000000000018",
    "F10800000000000000000019",
    "F1080000000000000000001A",
    "F1080000000000000000001B",
    "F1080000000000000000001C",
    "F1080000000000000000001D",
    "F1080000000000000000001E",
    "F1080000000000000000001F",
    "F10800000000000000000020",
    "F10810000000000000000001",
    "F10810000000000000000002",
    "F10810000000000000000011",
    "F10810000000000000000012",
    "F10820000000000000000001",
    "F10820000000000000000002",
    "F10820000000000000000011",
    "F10820000000000000000012",
):
    assert project.count(token) >= 2, f"missing PR108 Xcode registration: {token}"

for token in (
    "PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization",
    "Slice 1 — Coherent delay/polarity proposal",
    "Slice 2 — Commissioning identity and explicit approval",
    "Slice 3 — Transactional Apply and exact rollback",
    "Slice 4 — Fresh coherent post-Apply verification",
    "Slice 5 — Persistent provisional/verified provenance + finalization",
    "Slice 6 — Coordinated multi-Sub proposal",
    "Slice 7 — Coordinated multi-Sub commissioning identity",
    "Slice 8 — Atomic coordinated multi-Sub Apply + provenance",
    "Slice 9 — Coordinated fresh coherent verification",
    "Slice 10 — Verified coordinated provenance + finalization",
    "Slice 11 — Guided production commissioning workflow/UI",
    "does **not** subtract relativeArrivalMilliseconds again",
    "previewOnly == true",
    "canDeploy == false",
    "Slice 5 — Persistent provisional/verified provenance + finalization",
    "Fresh coherent post-Apply verification",
):
    assert token in doc, f"missing PR108 Slice 1 documentation: {token}"


for token in (
    "REMOTE SOFTWARE COMPLETE — PHYSICAL COHERENT ALIGNMENT ACCEPTANCE PENDING",
    "7d93e453c2a54a1651e7678bad42d64f66ac8f15",
    "38263562739",
    "38263566501",
    "46 tests, 0 failures",
    "PR108_PHYSICAL_ACCEPTANCE.md",
):
    assert token in closure, f"missing PR108 software closure evidence: {token}"

for token in (
    "no physical acceptance is claimed",
    "same physical ADC",
    "Never connect amplifier speaker terminals",
    "A0",
    "A9",
    "D_i - C = s_i",
):
    assert token in physical, f"missing PR108 physical handoff contract: {token}"

for token in (
    "Current execution status — PR108",
    "PR107 — Speaker Optimizer FIR Deployment & Latency Coordination",
    "PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization",
):
    assert token in roadmap, f"missing PR108 roadmap closure state: {token}"

assert "REMOTE SOFTWARE COMPLETE — PHYSICAL COHERENT ALIGNMENT ACCEPTANCE PENDING" in doc

assert "validate_pr107_speaker_optimizer_fir.py" in workflow
assert "CoherentSubwooferAlignmentTests" in workflow
assert "CoherentSubwooferAlignmentCommissioningTests" in workflow
assert "CoherentSubwooferAlignmentApplyTransactionTests" in workflow
assert "CoherentSubwooferAlignmentPostApplyVerificationTests" in workflow
assert "CoherentMultiSubwooferAlignmentTests" in workflow
assert "CoherentMultiSubwooferAlignmentCommissioningTests" in workflow
assert "CoherentMultiSubwooferAlignmentApplyTransactionTests" in workflow
assert "CoherentMultiSubwooferAlignmentPostApplyVerificationTests" in workflow
assert "CoherentSubwooferAlignmentGuidedWorkflowTests" in workflow
assert "Run full XCTest regression" in workflow

print("PR108 remote software closure + physical handoff boundary passed")
