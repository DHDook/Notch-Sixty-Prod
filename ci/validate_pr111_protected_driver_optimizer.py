#!/usr/bin/env python3
"""PR111 protected, recommendation-only per-driver optimizer contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabProtectedExcitation.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerMeasurementLabProtectedExcitationTests.swift"
ROUTE = ROOT / "NotchSixty/Audio/Routing/AudioRouteConfiguration.swift"
WORKFLOW = ROOT / ".github/workflows/pr111-protected-driver-optimizer.yml"
DOCUMENT = ROOT / "docs/PR111_PER_DRIVER_SPEAKER_OPTIMIZATION.md"
ROADMAP = ROOT / "docs/ROADMAP.md"
REPORT = ROOT / "NotchSixty/Audio/SpeakerMeasurementLabReport.swift"
UI = ROOT / "NotchSixty/UI/ProductionSpeakerMeasurementLabWorkspace.swift"
for path in (AUDIO, TESTS, ROUTE, WORKFLOW, DOCUMENT, ROADMAP, REPORT, UI):
    assert path.is_file(), f"PR111 missing artifact: {path}"

audio = AUDIO.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
route = ROUTE.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
doc = DOCUMENT.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
report = REPORT.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")
section = audio.split("// MARK: - PR111 Slice 1:", 1)
assert len(section) == 2, "PR111 engine must stay reviewable as its own slice"
source = section[1]

for token in (
    "struct ProtectedDriverPEQRecommendationAnalyzer: Sendable",
    "struct ProtectedDriverPEQRecommendation: Equatable, Sendable",
    "struct ProtectedDriverPEQCut: Equatable, Sendable",
    "try session.validateStructure()",
    "protocolItem.request.mode == .protectedDriverNearField",
    "SpeakerMeasurementLabProtectedDriverRoutePlanner",
    ".isProtectedSplitBus(bus)",
    "provenance.validatesProtectedPath(for: bus)",
    "captures.count == protocolItem.request.repeatCount",
    "minimumRepeats = 3",
    "minimumSNRDB = 35.0",
    "maximumRepeatSpreadDB = 0.85",
    "maximumCutDB = 2.5",
    "maximumSuggestedBands = 3",
    "maximumBandQ = 1.4",
    "max(low, measuredLow)",
    "min(high, measuredHigh)",
    "physicalMode.supports(bus: bus)",
    "high > low * 1.7",
    "capture",
    "var measurementOnly: Bool { true }",
    "var canDeploy: Bool { false }",
    "var canChangeDelayOrPolarity: Bool { false }",
    "var canAlterCrossoverOrLimiter: Bool { false }",
    "var requiresNewMeasuredVerification: Bool { true }",
):
    assert token in source, f"PR111 protected optimization contract missing {token}"
for unsafe in ("makeRealtimeSnapshot(", "startPhysical", "apply(", "driverProcessing.replace(",
               "setSpeakerDriverProcessing", "AudioIOEngine", "ProductProfileController"):
    assert unsafe not in source, f"PR111 recommendation gained live authority: {unsafe}"

for token in (
    "final class ProtectedDriverPEQRecommendationTests",
    "testBroadRepeatStablePeakProducesBoundedCutOnlyReview",
    "testSmoothResponseDoesNotInventPEQ",
    "testClippedLowSNRMissingRepeatsAndBadGridReject",
    "testMandatoryCrossoverAndLimiterAreNeverBypassed",
    "testWrongProtocolOrAlteredRouteCannotBecomeRecommendation",
    "testUnstableRepeatsDoNotAuthorizeCuts",
):
    assert token in tests, f"PR111 safety regression missing {token}"
# Slice 2 — qualified protected driver diagnostics within existing Lab
# report/export/UI. Missing or unqualified driver evidence must remain visible.
for token in (
    "case protectedDriverOptimization",
    "private func protectedDriverOptimizationSummary(",
    "ProtectedDriverPEQRecommendationAnalyzer()",
    "session.protocols where",
    "labProtocol.request.mode == .protectedDriverNearField",
    'metric("Driver", candidate.targetBus.displayName)',
    'metric("Suggested cuts", "\\(candidate.cuts.count)")',
    'metric("Deployment", "Never · review only")',
    "candidate.protectedConfiguration.limiterEnabled",
    "return unavailable(",
    "near field",
    "no live Apply",
):
    assert token in report, f"PR111 protected Lab report missing {token}"

for token in (
    "analysis.kind == .protectedDriverOptimization",
    '"REVIEW ONLY"',
    "LazyVGrid(",
    "GridItem(.adaptive(minimum: 180)",
    "ForEach(analysis.warnings, id: \\.self)",
):
    assert token in ui, f"PR111 driver diagnostic UX missing {token}"

for token in (
    "testLabReportPublishesDriverCutReviewWithoutDSPDeployment",
    "testLabReportSurfacesInconclusiveDriverOnMissingRepeats",
    "testLabReportSurfacedProtectedDriverWithoutFabricatingBands",
    "testReportRejectsUnprotectedLimiterCaptureEvenIfGridLooksGood",
):
    assert token in tests, f"PR111 Lab report regression missing {token}"
# Slice 3 — adjacent protected-driver timing/polarity hypotheses require
# simultaneous shared-clock reference evidence and actual crossover topology.
for token in (
    "struct ProtectedDriverTimingRecommendationAnalyzer: Sendable",
    "ProtectedDriverTimingRecommendation",
    "session.sharedClockReferenceConfiguration != nil",
    "sharedClockReference?.sharedTimeOriginQualified == true",
    "sharedTimeOriginQualified == true",
    "maximumReferenceArrivalSpreadMilliseconds = 0.25",
    "maximumReferenceMagnitudeRepeatabilityRMSDB = 0.50",
    "minimumReferencePhaseConsistency = 0.98",
    "maximumAdditionalDelayMilliseconds = 2.0",
    "minimumMeaningfulDelayMilliseconds = 0.05",
    "sameSpeakerSide(firstBus, secondBus)",
    "adjacent(firstBus, secondBus, mode: mode)",
    "mode == .biAmp || mode == .triAmp",
    "sameProtectedRoutingTopology(",
    "lhs.resolvedReferenceDeviceUID",
    "rhs.resolvedReferenceDeviceUID",
    "lhs.enabledRoutes.map",
    "rhs.enabledRoutes.map",
    "firstProvenance.bassManagementConfiguration",
    "== secondProvenance.bassManagementConfiguration",
    "correctedArrival(first)",
    "correctedArrival(second)",
    "correctedPhase(",
    "var measurementOnly: Bool { true }",
    "var canDeploy: Bool { false }",
    "var canChangeCrossoverOrLimiter: Bool { false }",
    "var requiresCombinedDriverVerification: Bool { true }",
):
    assert token in source, f"PR111 protected timing guard missing {token}"

for forbidden in (
    "polarityInverted =",
    "delayMilliseconds =",
    "setSpeakerDriverProcessing",
    "makeRealtimeSnapshot(",
):
    timing = source.split("// MARK: - PR111 Slice 3:", 1)[1]
    assert forbidden not in timing, f"PR111 timing analysis gained Apply authority: {forbidden}"

for token in (
    "case protectedDriverTiming",
    "private func protectedDriverTimingSummaries(",
    "ProtectedDriverTimingRecommendationAnalyzer()",
    '"Delay hypothesis"',
    '"Polarity hypothesis"',
    '"Never · review only"',
):
    assert token in report, f"PR111 timing report missing {token}"

assert "analysis.kind == .protectedDriverOptimization" in ui
assert "analysis.kind == .protectedDriverTiming" in ui

for token in (
    "testSharedReferenceTimingSuggestsBoundedDelayForEarlierDriver",
    "testResidualPiPhaseProducesOnlyPolarityHypothesis",
    "testMissingOrUnstableSharedReferenceFailsClosed",
    "testLargeArrivalMismatchDoesNotInventSafeDelayAdjustment",
    "testCrossSpeakerOrUnprotectedPairCannotProduceTimingAdvice",
    "testLabReportPublishesProtectedTimingAsReviewOnly",
    "testLabReportShowsUnqualifiedTimingWhenReferenceIsUnstable",
    "testTriAmpCannotTreatLowAndHighAsAdjacentTimingPair",
):
    assert token in tests, f"PR111 timing regression missing {token}"
# Slice 4 — complex protected crossover-sum model. This is explicitly
# MODEL ONLY and can never substitute for a real combined-driver capture.
for token in (
    "struct ProtectedDriverCrossoverSumModelAnalyzer: Sendable",
    "ProtectedDriverCrossoverSumModel",
    "enum ProtectedDriverCrossoverSumHypothesis",
    "currentMeanCoherenceDeficitDB",
    "candidateMeanCoherenceDeficitDB",
    "modeledDeficitReductionDB",
    "minimumModeledImprovementDB = 0.25",
    "ProtectedDriverTimingRecommendationAnalyzer()",
    "referenceAlignedMean(",
    "meanCoherenceDeficit(",
    "var measurementOnly: Bool { true }",
    "var modelOnly: Bool { true }",
    "var canDeploy: Bool { false }",
    "var combinedDriverCaptureVerified: Bool { false }",
    "var requiresPhysicalCombinedDriverCapture: Bool { true }",
    "MODEL ONLY:",
    "combined-driver crossover capture",
):
    assert token in source, f"PR111 crossover-sum model contract missing {token}"

sum_model = source.split("// MARK: - PR111 Slice 4:", 1)[1]
for forbidden in (
    "delayMilliseconds =",
    "polarityInverted =",
    "setSpeakerDriverProcessing",
    "driverProcessing.replace(",
    "makeRealtimeSnapshot(",
    "startPhysical",
):
    assert forbidden not in sum_model, f"PR111 crossover model gained live authority: {forbidden}"

for token in (
    "case protectedDriverCrossoverSum",
    "private func protectedDriverCrossoverSumSummaries(",
    "ProtectedDriverCrossoverSumModelAnalyzer()",
    'metric("Best hypothesis", hypothesis)',
    '"REQUIRED · not yet verified"',
    '"Never · model only"',
):
    assert token in report, f"PR111 crossover-sum report missing {token}"

assert "analysis.kind == .protectedDriverCrossoverSum" in ui

for token in (
    "testCrossoverSumModelSelectsBoundedDelayWhenItReducesCancellation",
    "testCrossoverSumModelCanCompareCombinedDelayAndPolarityHypothesis",
    "testCrossoverSumModelWithoutQualifiedReferenceFailsClosed",
    "testLargeTimingMismatchDoesNotBecomeModeledSafeAdjustment",
    "testCrossoverSumModelRejectsMismatchedComplexGrid",
    "testLabReportPublishesCrossoverSumModelAsModelOnly",
    "testLabReportCrossoverSumIsUnavailableWithoutTimingEvidence",
):
    assert token in tests, f"PR111 crossover-sum regression missing {token}"
# Slice 5 — remote commissioning draft only. It captures exact rollback and
# drift state but is structurally incapable of Apply/Deploy before PR112.
for token in (
    "struct ProtectedDriverCommissioningDraft:",
    "struct ProtectedDriverCommissioningPlanner: Sendable",
    "struct ProtectedDriverCommissioningDraftStore: Sendable",
    "rollbackPlaybackSystemState: PlaybackSystemState",
    "previewDriverProcessing: SpeakerDriverProcessingConfiguration",
    "var readyForApproval: Bool { false }",
    "var canApply: Bool { false }",
    "var canDeploy: Bool { false }",
    "var rollbackSnapshotAvailable: Bool { true }",
    "var stateDriftCheckRequired: Bool { true }",
    "var requiresPhysicalCombinedDriverCapture: Bool { true }",
    "profile.state == draft.rollbackPlaybackSystemState",
    "ProtectedDriverPEQRecommendationAnalyzer()",
    "ProtectedDriverCrossoverSumModelAnalyzer()",
    "options: .atomic",
    "PR111 Commissioning Drafts",
):
    assert token in source, f"PR111 blocked commissioning contract missing {token}"

commissioning = source.split("// MARK: - PR111 Slice 5:", 1)[1]
for forbidden in (
    "replaceSelectedSystemSpeakerDriverProcessing(",
    "replaceSpeakerDriverProcessingConfiguration(",
    "AudioIOEngine",
    "makeRealtimeSnapshot(",
    "approveAndApply(",
    "func apply(",
    "canApply: Bool { true }",
    "canDeploy: Bool { true }",
):
    assert forbidden not in commissioning, f"PR111 remote commissioning gained Apply authority: {forbidden}"

for token in (
    "Per-Driver Commissioning Preview",
    "Prepare Commissioning Draft",
    "Check Current State",
    '"HARDWARE BLOCKED"',
    'status("Apply", "BLOCKED")',
    "No Apply control exists in PR111 remote closeout",
    "driverCommissioningStore.save(prepared)",
    "validateCurrentState(",
):
    assert token in ui, f"PR111 blocked commissioning UX missing {token}"

for token in (
    "testCommissioningDraftCompilesCutPreviewButCannotApply",
    "testCommissioningDraftRetainsModelOnlyTimingReviews",
    "testCommissioningExactStateDriftAndIdentityFailClosed",
    "testCommissioningRejectsProtectedRouteOrDriverStateDrift",
    "testCommissioningFailsWhenMeasuredBusHasNoEQCapacity",
    "testCommissioningDraftStoreRoundTripAndSchemaGate",
):
    assert token in tests, f"PR111 commissioning regression missing {token}"
assert "SpeakerMeasurementLabReportTests" in workflow
assert "SpeakerDriverBusProcessingConfiguration" in route
assert "ProtectedDriverPEQRecommendationTests" in workflow
assert "PR111" in roadmap
assert "REMOTE SOFTWARE ONLY" in doc
assert "no live Apply" in doc
print("PR111 repeat-qualified cut-only recommendations: structural safety PASS")
