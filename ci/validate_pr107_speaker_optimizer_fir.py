#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerFIRDeployment.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerFIRDeploymentTests.swift"
LANE = ROOT / "NotchSixty/Audio/Realtime/N60ProgramLaneEngine.h"
CONV = ROOT / "NotchSixty/Audio/Realtime/N60Convolution.h"
COMMISSIONING = ROOT / "NotchSixty/Audio/SpeakerOptimizerCommissioningContract.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR107_SPEAKER_OPTIMIZER_FIR_DEPLOYMENT.md"
WORKFLOW = ROOT / ".github/workflows/pr107-speaker-optimizer-fir.yml"

for path in (SOURCE, TESTS, LANE, CONV, COMMISSIONING, PROJECT, DOC, WORKFLOW):
    assert path.is_file(), f"missing PR107 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
lane = LANE.read_text()
conv = CONV.read_text()
commissioning = COMMISSIONING.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
workflow = WORKFLOW.read_text()

for token in (
    "struct SpeakerOptimizerFIRLatencyPlanner",
    "struct SpeakerOptimizerFIRLatencyPlan",
    "struct SpeakerOptimizerFIRRoleLatencyPlan",
    "UInt32(N60_CONVOLUTION_PARTITION_FRAMES)",
    "UInt32((tapCount - 1) / 2)",
    "coherenceCompensationFrames",
    "userCalibrationDelayFrames",
    "requiresAVSyncCoordination",
    "var canInstallLiveFIR: Bool",
    "false",
):
    assert token in source, f"missing PR107 FIR latency contract: {token}"

for token in (
    "testDefault2049TapCandidateCountsEngineAndGroupDelayExactlyOnce",
    "testUncorrectedProgramLaneGetsExactCoherenceCompensation",
    "testExistingCalibrationDelayRemainsIntentionalAfterCoherenceCompensation",
    "testRejectsWrongGroupDelayEvenIfTapCountOtherwiseValid",
    "testRejectsEvenTapCountDuplicateRolesAndLFE",
    "testFailsClosedWhenFIRCompensationWouldOverflowLaneDelayBuffer",
):
    assert token in tests, f"missing PR107 FIR latency test: {token}"

for token in (
    "upstreamProcessingLatencyFrames",
    "coherenceLatencyFrames",
    "N60ProgramLaneGraphSetUpstreamProcessingLatency",
    "N60ProgramLaneGraphFinalize",
):
    assert token in lane, f"missing inherited program-lane latency hook: {token}"

assert "#define N60_CONVOLUTION_PARTITION_FRAMES 256u" in conv
assert "blockedDedicatedSpeakerOptimizerFIRStageUnavailable" in commissioning

for token in (
    "F10700000000000000000001",
    "F10700000000000000000002",
    "F10700000000000000000011",
    "F10700000000000000000012",
):
    assert project.count(token) >= 2, f"missing PR107 Xcode registration: {token}"

for token in (
    "PR107 — Speaker Optimizer FIR Deployment & Latency Coordination",
    "1280 frames / 26.67 ms",
    "canInstallLiveFIR == false",
    "A/V latency policy",
    "Per-program-role FIR realtime substrate",
):
    assert token in doc, f"missing PR107 Slice 1 documentation: {token}"

assert "SpeakerOptimizerFIRDeploymentTests" in workflow
assert "validate_pr106_speaker_measurement_lab.py" in workflow
assert "Run full XCTest regression" in workflow

print("PR107 Slice 1 FIR latency/deployment boundary passed")
