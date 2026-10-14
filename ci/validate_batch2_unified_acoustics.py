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
DOC = ROOT / "docs/BATCH2_UNIFIED_ACOUSTIC_INTELLIGENCE.md"


def require(condition, message):
    if not condition:
        raise AssertionError("Batch 2 acoustic intelligence: " + message)


source = SOURCE.read_text()
pbx = PROJECT.read_text()
tests = TESTS.read_text()
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
