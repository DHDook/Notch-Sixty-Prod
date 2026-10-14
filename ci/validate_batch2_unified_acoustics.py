#!/usr/bin/env python3
"""Batch 2 focused, portable source/ownership and safety contract.

This is deliberately a cheap per-commit check, NOT a substitute for Swift
type checking, full Apple Silicon XCTest or real acoustic measurement.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/UnifiedAcousticIntelligenceCoordinator.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
TESTS = ROOT / "NotchSixtyTests/RoomTreatmentAdvisorTests.swift"
WORKSPACE = ROOT / "NotchSixty/UI/ProductionRoomTreatmentAdvisorWorkspace.swift"
CONTROLLER = ROOT / "NotchSixty/State/RoomTreatmentAdvisorController.swift"
COMPARISON_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerCandidateComparisonTests.swift"
DOC = ROOT / "docs/BATCH2_UNIFIED_ACOUSTIC_INTELLIGENCE.md"


def require(condition, message):
    if not condition:
        raise AssertionError("Batch 2 acoustic intelligence: " + message)


source = SOURCE.read_text()
pbx = PROJECT.read_text()
tests = TESTS.read_text()
workspace = WORKSPACE.read_text()
controller = CONTROLLER.read_text()
comparison_tests = COMPARISON_TESTS.read_text()
doc = DOC.read_text()
for token in (
    "struct UnifiedAcousticIntelligenceCoordinator",
    "RoomTreatmentAdvisorReport",
    "SpeakerOptimizerComparisonPlan",
    "CoherentMultiSubwooferAlignmentCandidate",
    "projectID == identity.projectID",
    "baselineMeasurementSetID == speaker.baselineMeasurementSetID",
    "speaker.routingSignature",
    "multiSub.routingSignature",
    "candidate.worstSeatRegressionDB",
    "candidate.requiredHeadroomDB",
    "includedMeasurementCount >= 2",
    "room.qualityWarnings",
    "speakerPlacement",
    "passiveTreatment",
    "canApply: Bool { false }",
    "canDeploy: Bool { false }",
    "hardwareVerified: Bool { false }",
    "UnifiedAcousticRobustnessEvaluator",
    "worstCaseWeightedSquaredErrorImprovementDB2",
    "worstSeatTargetErrorRegressionDB",
    "coherentClockAuthenticated",
    "maximumFixedLatencyMilliseconds",
    "maximumAdditionalHeadroomDB",
    "minimumRobustImprovementDB2",
    "baselineTargetErrorDB",
    "candidateTargetErrorDB",
    "absoluteMeasurementUncertaintyDB",
    "heldOutSeatIndices",
    "heldOutSeatWorstRegressionDB",
    "UnifiedAcousticBassTradeoffEvaluator",
    "paretoFrontier",
    "physicalSub: RoomAdvancedSubPlacementComparison?",
    "candidate.kind == .bypass",
    "candidate.kind == .bypass",
):
    require(token in source, "missing read-only arbitration contract: " + token)

for filename in (
    "UnifiedAcousticIntelligenceCoordinator.swift in Sources",
    "UnifiedAcousticIntelligenceCoordinator.swift",
):
    require(filename in pbx, "shipping source not in Xcode project: " + filename)

for test in (
    "testUnifiedAcousticCoordinatorPrioritizesPhysicalRemediesAndNeverDeploys",
    "testUnifiedAcousticCoordinatorRejectsForeignProject",
    "testUnifiedAcousticCoordinatorSingleSeatBlocksDSPReview",
):
    require(test in tests, "missing Swift regression: " + test)

for method in (
    "testUnifiedAcousticRobustnessRejectsDeceptiveMeanSeatWin",
    "testUnifiedAcousticRobustnessRejectsMarginalNoiseSensitiveChange",
    "testUnifiedAcousticRobustnessAcceptsWellSeparatedBoundedHypothesis",
    "testUnifiedAcousticRobustnessChecksPhysicalSubClockAnd384kHzLatency",
    "testUnifiedAcousticRobustnessRejectsMalformedSeatAndSampleRate",
    "testUnifiedAcousticRobustnessProtectsHeldOutSeatFromOverfitting",
):
    require(method in tests, "missing bounded uncertainty regression: " + method)

require("testUnifiedCoordinatorOnlyAcceptsMatchingSpeakerEvidenceContext"
        in comparison_tests, "missing real speaker proposal source identity test")

for token in (
    "refreshUnifiedSpeakerBaselines()",
    "reviewUnifiedSpeakerBaseline()",
    "clearUnifiedSpeakerComparison()",
    "role == .baseline",
    "playbackSystemID == project.playbackSystemID",
    "SpeakerOptimizerMeasurementEvidenceEvaluator()",
    "SpeakerOptimizerCandidateComparisonDesigner()",
):
    require(token in controller, "source-owner read-only controller missing: " + token)
for token in (
    "Find baselines",
    "Review selected baseline",
    "physicalSub: advisor.physicalSubComparison",
    "speaker: advisor.unifiedSpeakerComparison",
    "selected?.routingSignature",
    "selected?.playbackSystemID",
    "comparison.sources.indices",
    "alternatives.indices",
    "alternative.predictedWeightedRMSEAfterDB",
    "alternative.worstSeatRegressionDB",
    "alternative.requiredHeadroomDB",
    "sub.baselineInterseatSpreadRMSDB",
    "sub.candidateInterseatSpreadRMSDB",
    "headroom unavailable",
):
    require(token in workspace, "authenticated Room Advisor UI missing: " + token)
for testName in (
    "testBatch2MultiObjectiveBassKeepsParetoChoicesWithoutRankingDifferentObjectives",
    "testBatch2BassScenariosRejectForeignRouteOrSampleRateAndRequirePhysicalOutputs",
    "testBatch2MeasuredPhysicalSubComparisonPreservesLimitedObjective",
):
    require(testName in tests, "multi-objective bass Swift regression missing: " + testName)

require("unifiedAcousticIntelligenceCard(report)" in workspace
        and "UnifiedAcousticIntelligenceCoordinator().summarize(" in workspace,
        "Room Advisor UI does not present the unified report")
require("playbackSystemID: selected?.playbackSystemID" in workspace
        and "routingSignature: selected?.routingSignature" in workspace
        and "baselineMeasurementSetID: selected?.id" in workspace
        and "advisor.unifiedSpeakerBaselines.first" in workspace,
        "UI must use exact user-selected source identity, never fabricate a Playback System or route")
require("No EQ, room correction, speaker delays" in workspace,
        "read-only UI warning omitted")

for kind in ("PR118", "PR119", "PR121", "OPEN/DRAFT/UNMERGED"):
    require(kind in doc, "batch scope or safety policy incomplete: " + kind)

for prohibited in (
    "N60RealtimeAudioBridgeConfigure",
    "N60RenderKernelConfigure",
    "ApplyTransaction(",
    "DeploymentExecutor(",
    "mysofa_load(",
    "AudioObjectSetPropertyData(",
    "AudioUnitRender(",
):
    require(prohibited not in source,
            "read-only evidence coordinator may not call realtime/hardware writer: "
            + prohibited)

print("Batch 2 acoustic intelligence: read-only project/route/seat ownership PASS")
