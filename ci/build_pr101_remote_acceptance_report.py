#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any

REMOTE_REQUIREMENTS = (
    "stereoTransport",
    "semanticMultichannel",
    "headphoneSpatialRuntime",
    "audioUnitFaultContainment",
    "roomTreatmentFailClosed",
    "activeAcousticsFailClosed",
    "lifecycleRecoveryModel",
    "dspCorrectnessRegression",
    "resourceStability",
    "dropoutRecoveryStress",
)

HARDWARE_REQUIREMENTS = (
    "physicalDeviceRecovery",
    "sleepWakeRecovery",
    "prolongedThermalRuntime",
    "speakerSafety",
    "acousticAcceptance",
)

DETERMINISTIC_REQUIREMENTS = REMOTE_REQUIREMENTS[:6]


def fail(message: str) -> None:
    raise SystemExit(f"PR101 remote acceptance closure failed: {message}")


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing evidence file: {path}")
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid JSON evidence {path}: {error}")
    if not isinstance(value, dict):
        fail(f"evidence root must be an object: {path}")
    return value


def require_marker(path: Path, label: str) -> None:
    if not path.is_file():
        fail(f"missing successful CI marker for {label}: {path}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--deterministic", type=Path, required=True)
    parser.add_argument("--resource-baseline", type=Path, required=True)
    parser.add_argument("--resource-soak", type=Path, required=True)
    parser.add_argument("--macos-campaign-marker", type=Path, required=True)
    parser.add_argument("--arm64-build-marker", type=Path, required=True)
    parser.add_argument("--release-build-marker", type=Path, required=True)
    parser.add_argument("--targeted-tests-marker", type=Path, required=True)
    parser.add_argument("--full-xctest-marker", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    marker_inputs = (
        (args.macos_campaign_marker, "macOS deterministic campaign"),
        (args.arm64_build_marker, "arm64 application build"),
        (args.release_build_marker, "Release performance build"),
        (args.targeted_tests_marker, "targeted runtime and lifecycle tests"),
        (args.full_xctest_marker, "full XCTest regression"),
    )
    for path, label in marker_inputs:
        require_marker(path, label)

    deterministic = load_json(args.deterministic)
    baseline = load_json(args.resource_baseline)
    soak = load_json(args.resource_soak)

    if deterministic.get("campaign") != "PR101_REMOTE_DETERMINISTIC_RELIABILITY":
        fail("unexpected deterministic campaign identity")
    if deterministic.get("evidenceAuthority") != "deterministicSimulation":
        fail("deterministic campaign authority changed unexpectedly")
    if deterministic.get("failedScenarioCount") != 0:
        fail("deterministic campaign contains a failed scenario")
    scenarios = deterministic.get("scenarios")
    if not isinstance(scenarios, list):
        fail("deterministic scenarios missing")

    scenario_status = {
        item.get("requirementID"): item.get("status")
        for item in scenarios
        if isinstance(item, dict)
    }
    for requirement in DETERMINISTIC_REQUIREMENTS:
        if scenario_status.get(requirement) != "passed":
            fail(f"deterministic requirement did not pass: {requirement}")

    if baseline.get("campaign") != "PR101_CI_RESOURCE_BASELINE":
        fail("unexpected resource baseline identity")
    if baseline.get("evidenceAuthority") != "macOSCI":
        fail("resource baseline must be macOS CI evidence")
    if baseline.get("hardPerformanceThresholdsApplied") is not False:
        fail("resource baseline must not invent hosted-CI hard thresholds")
    if baseline.get("physicalAcceptanceComplete") is not False:
        fail("resource baseline claimed physical acceptance")
    if baseline.get("releaseAcceptanceComplete") is not False:
        fail("resource baseline claimed release acceptance")

    if soak.get("campaign") != "PR101_REALTIME_RESOURCE_DROPOUT_SOAK":
        fail("unexpected resource/dropout soak identity")
    if soak.get("evidenceAuthority") != "macOSCI":
        fail("resource/dropout soak must be macOS CI evidence")
    if soak.get("resourceStabilityAccepted") is not True:
        fail("resource stability soak did not pass")
    if soak.get("dropoutRecoveryStressAccepted") is not True:
        fail("dropout recovery soak did not pass")
    if soak.get("unexpectedDropouts") != 0:
        fail("unexpected realtime dropouts were observed")
    if soak.get("nonFiniteSamples") != 0:
        fail("non-finite realtime samples were observed")
    if soak.get("unrecoveredFaults") != 0:
        fail("a realtime starvation fault did not recover")
    if soak.get("heapRetainedGrowthBytes") != 0:
        fail("retained heap grew during same-process soak")
    if soak.get("maximumCheckpointHeapGrowthBytes") != 0:
        fail("retained heap grew at an intermediate soak checkpoint")
    if soak.get("physicalAcceptanceComplete") is not False:
        fail("resource/dropout soak claimed physical acceptance")
    if soak.get("releaseAcceptanceComplete") is not False:
        fail("resource/dropout soak claimed release acceptance")

    evidence: dict[str, dict[str, Any]] = {}
    for requirement in DETERMINISTIC_REQUIREMENTS:
        evidence[requirement] = {
            "status": "passed",
            "evidenceAuthority": "macOSCI",
            "basis": (
                "deterministic scenario passed inside the same macOS CI "
                "closure job"
            ),
            "sourceAuthority": "deterministicSimulation",
        }

    evidence["lifecycleRecoveryModel"] = {
        "status": "passed",
        "evidenceAuthority": "macOSCI",
        "basis": (
            "targeted PR101 lifecycle/recovery and runtime tests passed "
            "inside the closure job"
        ),
    }
    evidence["dspCorrectnessRegression"] = {
        "status": "passed",
        "evidenceAuthority": "macOSCI",
        "basis": "full application XCTest regression passed inside the closure job",
    }
    evidence["resourceStability"] = {
        "status": "passed",
        "evidenceAuthority": "macOSCI",
        "basis": "same-process realtime resource soak accepted",
        "heapRetainedGrowthBytes": soak["heapRetainedGrowthBytes"],
        "maximumCheckpointHeapGrowthBytes":
            soak["maximumCheckpointHeapGrowthBytes"],
    }
    evidence["dropoutRecoveryStress"] = {
        "status": "passed",
        "evidenceAuthority": "macOSCI",
        "basis": "same-process starvation/recovery soak accepted",
        "injectedFaults": soak["injectedStarvationFaults"],
        "recoveredFaults": soak["recoveredFaults"],
        "unexpectedDropouts": soak["unexpectedDropouts"],
        "unrecoveredFaults": soak["unrecoveredFaults"],
    }

    missing = [
        requirement
        for requirement in REMOTE_REQUIREMENTS
        if evidence.get(requirement, {}).get("status") != "passed"
    ]
    if missing:
        fail("remote requirements missing accepted evidence: " + ", ".join(missing))

    hardware = {
        requirement: {
            "status": "hardwareRequired",
            "accepted": False,
        }
        for requirement in HARDWARE_REQUIREMENTS
    }

    source_files = {
        "deterministicCampaign": {
            "path": str(args.deterministic),
            "sha256": sha256_file(args.deterministic),
        },
        "resourceBaseline": {
            "path": str(args.resource_baseline),
            "sha256": sha256_file(args.resource_baseline),
        },
        "resourceDropoutSoak": {
            "path": str(args.resource_soak),
            "sha256": sha256_file(args.resource_soak),
        },
    }

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "campaign": "PR101_REMOTE_SOFTWARE_ACCEPTANCE_CLOSURE",
        "githubSHA": os.environ.get("GITHUB_SHA"),
        "evidenceAuthority": "macOSCI",
        "remoteRequirementCount": len(REMOTE_REQUIREMENTS),
        "remotePassedCount": len(evidence),
        "remoteRequirements": evidence,
        "remoteSoftwareAccepted": True,
        "hardwareRequirementCount": len(HARDWARE_REQUIREMENTS),
        "hardwareRequirements": hardware,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCOutputAuthorized": False,
        "speakerConnectedFeedForwardOutput": False,
        "sourceEvidence": source_files,
        "integrityOnly": True,
        "integrityNotice": (
            "SHA-256 digests bind this closure report to the CI evidence files; "
            "they do not authenticate physical instruments, reviewers, or "
            "hardware behavior."
        ),
        "doesNotEstablish": [
            "real device unplug/replug recovery",
            "real sleep/wake recovery",
            "prolonged production-Mac thermal/endurance stability",
            "speaker protection or emergency hardware mute",
            "physical acoustic acceptance",
            "live feed-forward ANC authorization",
        ],
    }

    canonical = json.dumps(report, sort_keys=True, separators=(",", ":"))
    report["closureSHA256"] = hashlib.sha256(canonical.encode()).hexdigest()

    if set(evidence) != set(REMOTE_REQUIREMENTS):
        fail("remote evidence set does not exactly match the PR101 catalog")
    if any(item["accepted"] for item in hardware.values()):
        fail("hardware-only requirement was incorrectly accepted")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    args.report.write_text(rendered + "\n")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
