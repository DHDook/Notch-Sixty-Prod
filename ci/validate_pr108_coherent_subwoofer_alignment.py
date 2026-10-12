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
COHERENT = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabCoherentTiming.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR108_COHERENT_SUBWOOFER_ALIGNMENT.md"
WORKFLOW = ROOT / ".github/workflows/pr108-coherent-subwoofer-alignment.yml"

for path in (SOURCE, TESTS, COMMISSIONING, COMMISSIONING_TESTS, APPLY, APPLY_TESTS, VERIFY, VERIFY_TESTS, DEPLOYMENT, MULTI, MULTI_TESTS, COHERENT, CALIBRATION, PROJECT, DOC, WORKFLOW):
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
    "testCommonSpeakerDelayCapacityFailsClosed",
):
    assert token in multi_tests, f"missing PR108 coordinated multi-Sub test: {token}"

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
    "does **not** subtract relativeArrivalMilliseconds again",
    "previewOnly == true",
    "canDeploy == false",
    "multiSubCoordinationRequired",
    "Slice 5 — Persistent provisional/verified provenance + finalization",
    "Fresh coherent post-Apply verification",
):
    assert token in doc, f"missing PR108 Slice 1 documentation: {token}"

assert "validate_pr107_speaker_optimizer_fir.py" in workflow
assert "CoherentSubwooferAlignmentTests" in workflow
assert "CoherentSubwooferAlignmentCommissioningTests" in workflow
assert "CoherentSubwooferAlignmentApplyTransactionTests" in workflow
assert "CoherentSubwooferAlignmentPostApplyVerificationTests" in workflow
assert "CoherentMultiSubwooferAlignmentTests" in workflow
assert "Run full XCTest regression" in workflow

print("PR108 Slice 1-6 single-Sub verified path + coordinated multi-Sub proposal boundary passed")
