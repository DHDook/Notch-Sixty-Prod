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
crossover_path = ROOT / "NotchSixty/Audio/SpeakerOptimizerCrossoverFeasibility.swift"
crossover_test_path = ROOT / "NotchSixtyTests/SpeakerOptimizerCrossoverFeasibilityTests.swift"
assert crossover_path.is_file() and crossover_test_path.is_file()
crossover = crossover_path.read_text()
crossover_tests = crossover_test_path.read_text()
for token in (
    "struct SpeakerOptimizerCrossoverFeasibilityDesigner",
    "SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline)",
    "case .speaker(let role)",
    "case .subwoofer = subwoofer",
    "phaseRadians",
    "directArrivalSeconds",
    "previewRelativeDelayMs",
    "previewInvertSubPolarity",
    "maximumSeatRegressionDB",
    "maximumModeledSumAboveStrongestSourceDB",
    "var canDeploy: Bool { false }",
    "requiresIndependentHeadroomAndLimiterAudit",
):
    assert token in crossover, f"missing crossover safety check: {token}"
for token in (
    "testQualifiedMainsSubOffersPreviewOnlyPhaseAndTimingHypothesis",
    "testRoleRouteAndSourceMustBeQualifiedAndSeparate",
    "testMissingPhaseOrExcessiveArrivalGapBlocksModel",
    "testWeightsAndUnsupportedCrossoverBandFailClosed",
    "testNoBenefitEmitsNoActionableOffset",
):
    assert token in crossover_tests, f"missing crossover tests: {token}"
for token in ("F10400000000000000000007", "F10400000000000000000008",
              "F10400000000000000000017", "F10400000000000000000018"):
    assert project.count(token) >= 2, f"missing crossover Xcode registration: {token}"
assert "Run PR104 crossover feasibility tests" in workflow
compare_source = ROOT / "NotchSixty/Audio/SpeakerOptimizerCandidateComparison.swift"
compare_tests = ROOT / "NotchSixtyTests/SpeakerOptimizerCandidateComparisonTests.swift"
assert compare_source.is_file() and compare_tests.is_file(), "missing PR104 ranking files"
comparator = compare_source.read_text()
comparison_tests = compare_tests.read_text()
for token in (
    "struct SpeakerOptimizerCandidateComparisonDesigner",
    "SpeakerOptimizerDesignEngine().design(",
    "SpeakerOptimizerPEQCandidateDesigner().design(",
    "SpeakerOptimizerFIRCandidateDesigner().design(",
    "SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(",
    "case bypass",
    "case peq",
    "case fir",
    "weightedRMSEBeforeDB",
    "minimumModeledImprovementDB",
    "maximumRequiredHeadroomDB",
    "maximumFIRDelayMilliseconds",
    "var canSwitchLiveAudio: Bool { false }",
    "var canDeploy: Bool { false }",
    "func visualAB(",
    "func crossoverVisualAB(",
):
    assert token in comparator, f"missing comparison boundary {token}"
for token in (
    "testComparesBypassPEQAndFIRWithSameEvidenceAndNoLiveSwitch",
    "testVisualABIsMagnitudeOnlyAndRejectsIneligibleCandidate",
    "testStrictLatencyHeadroomAndBenefitCanRejectAlternatives",
    "testRejectsIncompleteBaselineAndInvalidTradeoffConstraints",
):
    assert token in comparison_tests, f"missing comparison test {token}"
for token in (
    "F10400000000000000000009", "F1040000000000000000000A",
    "F10400000000000000000019", "F1040000000000000000001A",
):
    assert project.count(token) >= 2, f"comparison file not in Xcode {token}"
assert "Run PR104 candidate comparison tests" in workflow
for token in (
    "struct SpeakerOptimizerPhaseReferenceSensitivityOptions",
    "struct SpeakerOptimizerPhaseReferenceSensitivityReport",
    "auditUnknownClockOffsetSensitivity(",
    "unknownSubClockOffsetMs:",
    "var crossSourceClockProvenanceAuthenticated: Bool { false }",
    "var requiresSynchronizedReferenceCapture: Bool { true }",
    "var canDeploy: Bool { false }",
    "weightedLevel(testLevels, weights)",
):
    assert token in crossover, f"missing clock-offset sensitivity boundary {token}"
for token in (
    "testClockOffsetUncertaintySensitivityIsPreviewOnlyAndUnauthenticated",
    "testWideClockUncertaintyCanRejectOtherwiseAttractiveCrossoverHypothesis",
    "testClockAuditRejectsUnqualifiedDataOrInvalidUncertainty",
    "testClockAuditNeverMutatesBaselineOrAllowsApply",
):
    assert token in crossover_tests, f"missing clock sensitivity test {token}"
assert "Run PR104 crossover feasibility tests" in workflow
CLOSURE = ROOT / "docs/PR104_SOFTWARE_CLOSURE.md"
assert CLOSURE.is_file(), "missing PR104 remote closure handoff"
closure_text = CLOSURE.read_text()
for token in (
    "REMOTE SOFTWARE COMPLETE",
    "PHYSICAL ACCEPTANCE PENDING",
    "absent authenticated common-clock provenance",
    "PR105",
    "rollback",
    "full application XCTest regression",
    "protected Low/Mid/High",
):
    # Allow capitalisation of the provenance discussion but require meaning.
    assert token.lower() in closure_text.lower(), f"missing PR104 closure note {token}"
assert "REMOTE SOFTWARE COMPLETE" in doc
assert "cross-source clock-origin" in doc
print("PR104 source alternatives, phase-reference safety and closure contracts passed")
