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
for path in (AUDIO, TESTS, ROUTE, WORKFLOW, DOCUMENT, ROADMAP):
    assert path.is_file(), f"PR111 missing artifact: {path}"

audio = AUDIO.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
route = ROUTE.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
doc = DOCUMENT.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
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
assert "SpeakerDriverBusProcessingConfiguration" in route
assert "ProtectedDriverPEQRecommendationTests" in workflow
assert "PR111" in roadmap
assert "REMOTE SOFTWARE ONLY" in doc
assert "no live Apply" in doc
print("PR111 repeat-qualified cut-only recommendations: structural safety PASS")
