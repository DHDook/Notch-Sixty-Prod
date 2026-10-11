#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

REMOTE_REQUIREMENTS = (
    "releaseContractValidation",
    "productBoundaryReconciliation",
    "dependencyAndProvenanceReconciliation",
    "appStoreStaticBoundary",
    "pr101SafetyInheritance",
    "debugArm64Build",
    "releaseArm64Build",
    "unsignedArchivePreflight",
    "fullXCTestRegression",
)

HARDWARE_REQUIREMENTS = (
    "physicalDeviceRecovery",
    "sleepWakeRecovery",
    "prolongedThermalRuntime",
    "speakerEmergencyMuteSafety",
    "finalAcousticAcceptance",
    "physicalActiveAcousticsQualification",
)

CREDENTIAL_REQUIREMENTS = (
    "productionAppleSigning",
    "appStoreConnectRecordAndUpload",
    "testFlightAcceptance",
    "appReviewAcceptance",
)


def fail(message: str) -> None:
    print(f"PR102 release-candidate manifest failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_plist(path: Path) -> dict[str, Any]:
    require(path.is_file(), f"missing plist: {path}")
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    require(isinstance(value, dict), f"plist root is not a dictionary: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--validators-marker", type=Path, required=True)
    parser.add_argument("--debug-build-marker", type=Path, required=True)
    parser.add_argument("--release-build-marker", type=Path, required=True)
    parser.add_argument("--archive-marker", type=Path, required=True)
    parser.add_argument("--xctest-marker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    markers = {
        "releaseContractValidation": args.validators_marker,
        "debugArm64Build": args.debug_build_marker,
        "releaseArm64Build": args.release_build_marker,
        "unsignedArchivePreflight": args.archive_marker,
        "fullXCTestRegression": args.xctest_marker,
    }
    for label, path in markers.items():
        require(path.is_file(), f"missing same-run success marker: {label} ({path})")

    github_sha = os.environ.get("GITHUB_SHA")
    github_run_id = os.environ.get("GITHUB_RUN_ID")
    require(github_sha is not None and len(github_sha) == 40, "full GITHUB_SHA is required")
    require(github_run_id is not None and github_run_id.isdigit(), "numeric GITHUB_RUN_ID is required")

    app = args.release_app
    require(app.is_dir(), f"Release app missing: {app}")
    info_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "Notch Sixty"
    shipped_notice = app / "Contents" / "Resources" / "ThirdPartyNotices.txt"
    require(executable.is_file(), "Release executable missing")
    require(shipped_notice.is_file(), "shipped third-party notice missing")

    archive_app = args.archive / "Products" / "Applications" / "Notch Sixty.app"
    require(archive_app.is_dir(), "archived application missing")
    archive_info_path = archive_app / "Contents" / "Info.plist"
    archive_executable = archive_app / "Contents" / "MacOS" / "Notch Sixty"
    archive_notice = archive_app / "Contents" / "Resources" / "ThirdPartyNotices.txt"
    require(archive_executable.is_file(), "archived executable missing")
    require(archive_notice.is_file(), "archived third-party notice missing")

    info = load_plist(info_path)
    archive_info = load_plist(archive_info_path)

    metadata_keys = (
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion",
        "NSAudioCaptureUsageDescription",
        "NSMicrophoneUsageDescription",
    )
    for key in metadata_keys:
        require(info.get(key) == archive_info.get(key), f"Release/archive metadata differs for {key}")

    require(info.get("CFBundleIdentifier") == "com.dhdook.NotchSixty", "unexpected bundle identifier")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        value = info.get(key)
        require(isinstance(value, str) and value.strip(), f"missing product metadata {key}")

    archs = subprocess.run(
        ["lipo", "-archs", str(executable)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    archive_archs = subprocess.run(
        ["lipo", "-archs", str(archive_executable)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    require(archs == "arm64", f"Release executable architecture changed: {archs}")
    require(archive_archs == "arm64", f"archive executable architecture changed: {archive_archs}")

    dependencies = ROOT / "release" / "production-dependencies.json"
    entitlements = ROOT / "NotchSixty" / "NotchSixty.entitlements"
    root_notices = ROOT / "THIRD_PARTY_NOTICES.md"
    provenance = ROOT / "docs" / "PROVENANCE.md"
    for path in (dependencies, entitlements, root_notices, provenance):
        require(path.is_file(), f"release source artifact missing: {path.relative_to(ROOT)}")

    remote = {
        requirement: {
            "status": "passed",
            "evidenceAuthority": "remoteSoftware",
        }
        for requirement in REMOTE_REQUIREMENTS
    }
    remote["productBoundaryReconciliation"]["basis"] = "README and roadmap PR102 reconciliation validator"
    remote["dependencyAndProvenanceReconciliation"]["basis"] = "classified production dependency manifest and shipped notice"
    remote["appStoreStaticBoundary"]["basis"] = "sandbox/privacy/forbidden-architecture validator"
    remote["pr101SafetyInheritance"]["basis"] = "PR101 acceptance validator plus disconnected feed-forward audit"

    hardware = {
        requirement: {
            "status": "hardwareRequired",
            "accepted": False,
        }
        for requirement in HARDWARE_REQUIREMENTS
    }
    credentials = {
        requirement: {
            "status": "releaseCredentialRequired",
            "accepted": False,
        }
        for requirement in CREDENTIAL_REQUIREMENTS
    }

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "campaign": "PR102_REMOTE_RELEASE_CANDIDATE",
        "evidenceAuthority": "remoteSoftware",
        "githubSHA": github_sha,
        "githubRunID": github_run_id,
        "product": {
            "name": "Notch Sixty",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "marketingVersion": info["CFBundleShortVersionString"],
            "buildNumber": info["CFBundleVersion"],
            "minimumMacOS": info["LSMinimumSystemVersion"],
            "architectures": [archs],
        },
        "remoteRequirementCount": len(REMOTE_REQUIREMENTS),
        "remotePassedCount": len(remote),
        "remoteRequirements": remote,
        "remoteReleasePreparationAccepted": True,
        "hardwareRequirementCount": len(HARDWARE_REQUIREMENTS),
        "hardwareRequirements": hardware,
        "releaseCredentialRequirementCount": len(CREDENTIAL_REQUIREMENTS),
        "releaseCredentialRequirements": credentials,
        "externalReview": {
            "targetedOpenSourceIPCounselReview": {
                "status": "externalReviewOptional",
                "accepted": False,
            }
        },
        "physicalAcceptanceComplete": False,
        "releaseCredentialAcceptanceComplete": False,
        "publicReleaseAuthorized": False,
        "liveFeedForwardANCOutputAuthorized": False,
        "speakerConnectedFeedForwardOutput": False,
        "artifacts": {
            "releaseExecutableSHA256": sha256_file(executable),
            "archiveExecutableSHA256": sha256_file(archive_executable),
            "shippedThirdPartyNoticeSHA256": sha256_file(shipped_notice),
            "archiveThirdPartyNoticeSHA256": sha256_file(archive_notice),
            "productionDependencyManifestSHA256": sha256_file(dependencies),
            "entitlementsSHA256": sha256_file(entitlements),
            "rootThirdPartyNoticesSHA256": sha256_file(root_notices),
            "provenanceSHA256": sha256_file(provenance),
        },
        "doesNotEstablish": [
            "real device unplug/replug recovery",
            "real sleep/wake recovery",
            "prolonged production-Mac thermal/endurance stability",
            "speaker/emergency-mute safety",
            "physical acoustic acceptance",
            "physical feed-forward ANC qualification",
            "production Apple signing",
            "App Store Connect upload",
            "TestFlight acceptance",
            "App Review acceptance",
        ],
    }

    require(set(remote) == set(REMOTE_REQUIREMENTS), "remote requirement set mismatch")
    require(all(item["accepted"] is False for item in hardware.values()), "hardware gate was incorrectly accepted")
    require(all(item["accepted"] is False for item in credentials.values()), "credential gate was incorrectly accepted")

    canonical = json.dumps(report, sort_keys=True, separators=(",", ":"))
    report["releaseCandidateSHA256"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
