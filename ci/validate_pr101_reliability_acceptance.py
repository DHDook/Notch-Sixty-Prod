#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAG = ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionAnalysisTests.swift"
NOTCH_TESTS = ROOT / "NotchSixtyTests/NotchSixtyTests.swift"
DOC = ROOT / "docs/PR101_RELIABILITY_ACOUSTIC_ACCEPTANCE.md"
CAMPAIGN = ROOT / "ci/run_pr101_remote_reliability_campaign.py"
RESOURCE_BASELINE = ROOT / "ci/run_pr101_resource_baseline.py"
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

print("PR101 reliability and acoustic acceptance validation passed")


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
