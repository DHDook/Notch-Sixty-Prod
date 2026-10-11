#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAG = ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionAnalysisTests.swift"
NOTCH_TESTS = ROOT / "NotchSixtyTests/NotchSixtyTests.swift"
DOC = ROOT / "docs/PR101_RELIABILITY_ACOUSTIC_ACCEPTANCE.md"
CAMPAIGN = ROOT / "ci/run_pr101_remote_reliability_campaign.py"
RESOURCE_BASELINE = ROOT / "ci/run_pr101_resource_baseline.py"
RESOURCE_SOAK = ROOT / "ci/validate_pr101_realtime_resource_soak.c"
REMOTE_CLOSURE = ROOT / "ci/build_pr101_remote_acceptance_report.py"
WORKFLOW = ROOT / ".github/workflows/pr101-reliability-acoustic-acceptance.yml"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR101 validation failed: {message}")


diag = DIAG.read_text()
tests = TESTS.read_text()
notch_tests = NOTCH_TESTS.read_text()
doc = DOC.read_text().lower()
campaign = CAMPAIGN.read_text()
resource_baseline = RESOURCE_BASELINE.read_text()
resource_soak = RESOURCE_SOAK.read_text()
remote_closure = REMOTE_CLOSURE.read_text()
workflow = WORKFLOW.read_text()

for token in (
    "FullSystemReliabilityEvidenceAuthority",
    "FullSystemReliabilityRequirementCatalog",
    "FullSystemReliabilityObservation",
    "FullSystemReliabilityAcceptanceEvaluator",
    "remoteSoftwareAccepted",
    "physicalAcceptanceComplete",
    "releaseAcceptanceComplete",
    "physicalDeviceRecovery",
    "sleepWakeRecovery",
    "prolongedThermalRuntime",
    "speakerSafety",
    "acousticAcceptance",
    "minimumEvidence: .independentPhysicalReview",
    "FullSystemLifecycleRecoveryCampaign",
    "unsupportedEvidenceAuthority",
    "faultInjectionStates",
):
    require(token in diag, f"acceptance framework missing {token!r}")

for token in (
    "unexpectedDropouts > 0",
    "nonFiniteSamples > 0",
    "unrecoveredFaults > 0",
    "crashes > 0",
    "duplicateRunID",
    "insufficientEvidence",
    "hardwareRequired",
):
    require(token in diag, f"fail-closed reliability rule missing {token!r}")

for token in (
    "testPR101AcceptanceCatalogSeparatesRemoteAndHardwareRequirements",
    "testPR101RemoteSoftwareCanPassWithoutClaimingPhysicalAcceptance",
    "testPR101SyntheticEvidenceCannotSatisfyPhysicalSafetyOrAcoustics",
    "testPR101FailureSignalsFailEvenStrongEvidence",
    "testPR101InjectedFaultsAreAllowedWhenEveryFaultRecovers",
    "testPR101RejectsDuplicateRunIDsAndInvalidResourceTelemetry",
    "testPR101LifecycleRecoveryCampaignSurvivesRepeatedFaultInjection",
    "testPR101LifecycleCampaignCannotSelfPromoteToHardwareEvidence",
    "testPR101RemoteClosureModelPassesTenRemoteRequirementsOnly",
):
    require(token in tests, f"PR101 XCTest missing {token}")

require(
    "testPR101StableUIDDeviceRecoverySoakRemainsSoftwareEvidence"
        in notch_tests,
    "stable-UID recovery soak test missing",
)

for phrase in (
    "full-system reliability",
    "deterministic simulation",
    "macos ci",
    "physical hardware",
    "independent physical review",
    "hardware-only requirements",
    "release acceptance remains false",
    "lifecycle recovery soak",
    "stable-uid",
):
    require(phrase in doc, f"PR101 documentation missing {phrase!r}")

for inherited in (
    ROOT / "ci/validate_pr100_active_acoustics_ux.py",
    ROOT / "ci/validate_pr99_physical_verification.py",
    ROOT / "ci/audit_pr98_disconnected_boundary.py",
    ROOT / "docs/PR100_ACTIVE_ACOUSTICS_UX.md",
):
    require(inherited.exists(), f"inherited acceptance artifact missing {inherited.name}")




for token in (
    '"stereoTransport"',
    '"semanticMultichannel"',
    '"headphoneSpatialRuntime"',
    '"audioUnitFaultContainment"',
    '"roomTreatmentFailClosed"',
    '"activeAcousticsFailClosed"',
    '"evidenceAuthority": "deterministicSimulation"',
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    "validate_pr70_stereo_adaptive_src.py",
    "validate_pr71_nchannel_adaptive_src.py",
    "validate_pr84a_audio_unit_hardening.py",
    "validate_pr77_live_room_treatment.py",
    "audit_pr98_disconnected_boundary.py",
):
    require(token in campaign, f"deterministic campaign missing {token!r}")

for token in (
    "run_pr101_remote_reliability_campaign.py --report",
    "AudioUnitLiveRackRuntimeTests",
    "AudioUnitRackMutationTests",
    "LiveMIMORoomTreatmentIntegrationTests",
    "QuietZoneFeedForwardClockMonitorTests",
    "QuietZoneNativeShadowTimingTransportTests",
    "testPR101StableUIDDeviceRecoverySoakRemainsSoftwareEvidence",
):
    require(token in workflow, f"PR101 workflow missing {token!r}")




for token in (
    '"campaign": "PR101_CI_RESOURCE_BASELINE"',
    '"evidenceAuthority": "macOSCI"',
    '"hardPerformanceThresholdsApplied": False',
    '"resourceStabilityAccepted": False',
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    "benchmark_pr35_render_kernel.c",
    "benchmark_pr35_realtime_bridge.c",
    "statistics.median",
    "maximum resident set size",
    "/usr/bin/time",
):
    require(token in resource_baseline, f"resource baseline missing {token!r}")

for token in (
    "Build Release performance scheme",
    "run_pr101_resource_baseline.py --repeats 5 --report",
    "Upload PR101 resource baseline",
    "pr101-resource-baseline.json",
):
    require(token in workflow, f"resource baseline workflow missing {token!r}")


for token in (
    "PR101_REALTIME_RESOURCE_DROPOUT_SOAK",
    "evidenceAuthority",
    "macOSCI",
    "WARMUP_CALLBACKS 2048u",
    "SOAK_BLOCKS 16u",
    "NORMAL_CALLBACKS_PER_BLOCK 1024u",
    "STARVATION_FAULTS_PER_BLOCK 32u",
    "malloc_zone_statistics",
    "MACH_TASK_BASIC_INFO",
    "maximum_heap_growth == 0u",
    "heap_final <= heap_baseline",
    "counters.underrunFrames == expected_underrun_frames",
    "counters.overrunFrames == 0u",
    "counters.unsupportedBufferLayouts == 0u",
    "recovered_faults == injected_faults",
    "output_is_exact_silence",
    "output_has_signal",
    "dropoutRecoveryStressAccepted",
    "resourceStabilityAccepted",
    "physicalAcceptanceComplete",
    "releaseAcceptanceComplete",
):
    require(token in resource_soak, f"realtime soak missing {token!r}")

for token in (
    "Build same-process PR101 realtime resource/dropout soak",
    "validate_pr101_realtime_resource_soak.c",
    "Run same-process PR101 realtime resource/dropout soak",
    "python3 -m json.tool /tmp/pr101-realtime-resource-soak.json",
    "Upload PR101 realtime resource/dropout soak",
    "pr101-realtime-resource-dropout-soak",
):
    require(token in workflow, f"realtime soak workflow missing {token!r}")

for token in (
    '"PR101_REMOTE_SOFTWARE_ACCEPTANCE_CLOSURE"',
    '"remoteSoftwareAccepted": True',
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    '"liveFeedForwardANCOutputAuthorized": False',
    '"speakerConnectedFeedForwardOutput": False',
    '"integrityOnly": True',
    '"stereoTransport"',
    '"semanticMultichannel"',
    '"headphoneSpatialRuntime"',
    '"audioUnitFaultContainment"',
    '"roomTreatmentFailClosed"',
    '"activeAcousticsFailClosed"',
    '"lifecycleRecoveryModel"',
    '"dspCorrectnessRegression"',
    '"resourceStability"',
    '"dropoutRecoveryStress"',
    '"physicalDeviceRecovery"',
    '"sleepWakeRecovery"',
    '"prolongedThermalRuntime"',
    '"speakerSafety"',
    '"acousticAcceptance"',
    "sha256_file",
    "hardPerformanceThresholdsApplied",
    "maximumCheckpointHeapGrowthBytes",
):
    require(token in remote_closure, f"remote closure missing {token!r}")

for token in (
    "touch /tmp/pr101-macos-deterministic-campaign.passed",
    "touch /tmp/pr101-arm64-build.passed",
    "touch /tmp/pr101-release-build.passed",
    "touch /tmp/pr101-targeted-tests.passed",
    "touch /tmp/pr101-full-xctest.passed",
    "build_pr101_remote_acceptance_report.py",
    "--report /tmp/pr101-remote-acceptance.json",
    "Upload PR101 remote software acceptance closure",
    "pr101-remote-software-acceptance",
):
    require(token in workflow, f"remote closure workflow missing {token!r}")

print("PR101 reliability and acoustic acceptance validation passed")
