#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/SpeakerOptimizerFIRDeployment.swift"
TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerFIRDeploymentTests.swift"
APPLY = ROOT / "NotchSixty/Audio/SpeakerOptimizerFIRApplyTransaction.swift"
APPLY_TESTS = ROOT / "NotchSixtyTests/SpeakerOptimizerFIRApplyTransactionTests.swift"
LANE = ROOT / "NotchSixty/Audio/Realtime/N60ProgramLaneEngine.h"
CONV = ROOT / "NotchSixty/Audio/Realtime/N60Convolution.h"
COMMISSIONING = ROOT / "NotchSixty/Audio/SpeakerOptimizerCommissioningContract.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR107_SPEAKER_OPTIMIZER_FIR_DEPLOYMENT.md"
PROGRAM_FIR = ROOT / "NotchSixty/Audio/Realtime/N60ProgramFIRRuntime.h"
PROGRAM_FIR_HARNESS = ROOT / "ci/validate_pr107_program_fir_runtime.c"
LIVE_RENDER = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"
LIVE_RENDER_HARNESS = ROOT / "ci/validate_pr107_live_fir_render.c"
WORKFLOW = ROOT / ".github/workflows/pr107-speaker-optimizer-fir.yml"

for path in (SOURCE, TESTS, APPLY, APPLY_TESTS, LANE, CONV, COMMISSIONING, PROJECT, DOC, PROGRAM_FIR, PROGRAM_FIR_HARNESS, LIVE_RENDER, LIVE_RENDER_HARNESS, WORKFLOW):
    assert path.is_file(), f"missing PR107 Slice 1 file: {path}"

source = SOURCE.read_text()
tests = TESTS.read_text()
apply_source = APPLY.read_text()
apply_tests = APPLY_TESTS.read_text()
lane = LANE.read_text()
conv = CONV.read_text()
commissioning = COMMISSIONING.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
program_fir = PROGRAM_FIR.read_text()
program_fir_harness = PROGRAM_FIR_HARNESS.read_text()
live_render = LIVE_RENDER.read_text()
live_render_harness = LIVE_RENDER_HARNESS.read_text()
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


for token in (
    "N60ProgramFIRProgramCreate",
    "N60ProgramFIRRuntimeCreate",
    "N60ProgramFIRRuntimeProcessFrame",
    "activeChannelMask",
    "activeOrdinalForChannel",
    "N60_CONVOLUTION_PARTITION_FRAMES",
    "N60_PROGRAM_FIR_INACTIVE_ORDINAL",
):
    assert token in program_fir, f"missing PR107 sparse FIR runtime contract: {token}"

for token in (
    "test_sparse_single_channel_impulse_and_passthrough",
    "test_multiple_sparse_channels_use_independent_kernels",
    "test_reset_clears_active_history",
    "test_nonfinite_input_is_sanitized",
    "test_invalid_programs_fail_closed",
    "test_memory_scales_with_active_channels_not_layout_width",
):
    assert token in program_fir_harness, f"missing PR107 sparse FIR runtime test: {token}"

for token in (
    "programFIREnabled",
    "N60LiveNChannelRenderGraphSetProgramFIRInfo",
    "N60LiveNChannelRenderRuntimeConfigureProgramFIR",
    "N60ProgramFIRRuntimeProcessFrame",
    "upstreamProcessingLatencyFrames",
):
    assert token in live_render, f"missing PR107 live FIR render contract: {token}"

for token in (
    "test_graph_latency_counts_upstream_fir_when_all_lanes_active",
    "test_sparse_fir_and_lane_compensation_realign_outputs",
    "test_graph_rejects_fir_on_semantic_lfe",
    "test_runtime_requires_exact_graph_program_identity",
):
    assert token in live_render_harness, f"missing PR107 live FIR render test: {token}"

for token in (
    "SpeakerOptimizerFIRDeploymentConfiguration",
    "SpeakerOptimizerFIRSourceDeployment",
    "requiredHeadroomDB",
    "makeRuntimePreparation",
    "profile.speakerOptimizerPEQ == nil",
):
    assert token in source, f"missing persistent FIR/headroom contract: {token}"

for token in (
    "availableDedicatedSpeakerOptimizerFIRStage",
    "blockedFIRCandidateNotRepresentable",
    "makeFIRDeploymentConfiguration",
    "firStageStatus",
):
    assert token in commissioning, f"missing FIR commissioning activation contract: {token}"

for token in (
    "struct SpeakerOptimizerFIRApplyTransaction",
    "struct SpeakerOptimizerFIRApplyReceipt",
    "rollbackStateDrift",
    "requiresMeasuredVerification",
):
    assert token in apply_source, f"missing FIR Apply transaction contract: {token}"

for token in (
    "testApplyInstallsOnlyDedicatedFIRAndRollbackRestoresExactSnapshot",
    "testApplyRequiresIdleEngineAndExactCommissioningSnapshot",
    "testApplyRejectsStaleApprovalBeforeMutation",
    "testMutationFailureLeavesOriginalSnapshotAndReturnsNoReceipt",
    "testRollbackRefusesToOverwriteUnrelatedPostApplyEdit",
):
    assert token in apply_tests, f"missing FIR Apply transaction test: {token}"

assert "#define N60_CONVOLUTION_PARTITION_FRAMES 256u" in conv
assert "blockedDedicatedSpeakerOptimizerFIRStageUnavailable" in commissioning

for token in (
    "F10700000000000000000001",
    "F10700000000000000000002",
    "F10700000000000000000003",
    "F10700000000000000000004",
    "F10700000000000000000011",
    "F10700000000000000000012",
    "F10700000000000000000013",
    "F10700000000000000000014",
):
    assert project.count(token) >= 2, f"missing PR107 Xcode registration: {token}"

for token in (
    "PR107 — Speaker Optimizer FIR Deployment & Latency Coordination",
    "1280 frames / 26.67 ms",
    "canInstallLiveFIR == false",
    "A/V latency policy",
    "Sparse per-program-channel FIR realtime substrate",
):
    assert token in doc, f"missing PR107 Slice 1 documentation: {token}"

assert "SpeakerOptimizerFIRDeploymentTests" in workflow
assert "SpeakerOptimizerFIRApplyTransactionTests" in workflow
assert "SpeakerOptimizerCommissioningContractTests" in workflow
assert "validate_pr107_program_fir_runtime.c" in workflow
assert "validate_pr107_live_fir_render.c" in workflow
assert "validate_pr106_speaker_measurement_lab.py" in workflow
assert "Run full XCTest regression" in workflow

print("PR107 FIR latency + runtime + persistence + Apply boundary passed")
