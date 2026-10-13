#!/usr/bin/env python3
"""Build PR114 exact-head remote commercial RC manifest."""

from __future__ import annotations

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
    "releaseBaselineValidation",
    "privacySecurityValidation",
    "provenanceSBOMValidation",
    "pr113bProductFinishInheritance",
    "commercialMetadataValidation",
    "debugArm64Build",
    "targetedProductTests",
    "releaseArm64Build",
    "unsignedArchivePreflight",
    "adhocSandboxPackagePreflight",
    "fullXCTestRegression",
)

HARD_FALSE_GATES = (
    "physicalAcceptanceComplete",
    "releaseCredentialAcceptanceComplete",
    "productionAppleSigningComplete",
    "appStoreConnectUploadComplete",
    "testFlightAcceptanceComplete",
    "appReviewApproved",
    "developerIDNotarizationComplete",
    "publicReleaseAuthorized",
    "liveFeedForwardANCAuthorized",
    "mayMergeIntoMain",
    "physicalEvidenceSuppliedByCI",
    "finalAppIconOwnerApproved",
    "appStorePrivacyPolicyURLConfigured",
    "appStorePrivacyResponsesComplete",
)


def fail(message: str) -> None:
    print(f"PR114 RC manifest failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def sha256_file(path: Path) -> str:
    require(path.is_file(), f"missing artifact: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_plist(path: Path) -> dict[str, Any]:
    require(path.is_file(), f"missing plist: {path}")
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    require(isinstance(value, dict), f"plist root is not dictionary: {path}")
    return value


def executable_archs(path: Path) -> list[str]:
    result = subprocess.run(
        ["lipo", "-archs", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip().split()
    return result


def marker(path: Path, name: str) -> None:
    require(path.is_file(), f"missing same-run success marker: {name} ({path})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--rc-app", type=Path, required=True)
    parser.add_argument("--rc-dmg", type=Path, required=True)
    parser.add_argument("--effective-entitlements", type=Path, required=True)
    parser.add_argument("--sbom", type=Path, required=True)
    parser.add_argument("--validators-marker", type=Path, required=True)
    parser.add_argument("--debug-build-marker", type=Path, required=True)
    parser.add_argument("--targeted-tests-marker", type=Path, required=True)
    parser.add_argument("--release-build-marker", type=Path, required=True)
    parser.add_argument("--archive-marker", type=Path, required=True)
    parser.add_argument("--package-marker", type=Path, required=True)
    parser.add_argument("--xctest-marker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    markers = {
        "releaseBaselineValidation": args.validators_marker,
        "debugArm64Build": args.debug_build_marker,
        "targetedProductTests": args.targeted_tests_marker,
        "releaseArm64Build": args.release_build_marker,
        "unsignedArchivePreflight": args.archive_marker,
        "adhocSandboxPackagePreflight": args.package_marker,
        "fullXCTestRegression": args.xctest_marker,
    }
    for name, path in markers.items():
        marker(path, name)

    source_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    require(len(source_sha) == 40, "full source SHA required")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    require(run_id.isdigit(), "numeric GITHUB_RUN_ID required")

    baseline_path = ROOT / "release" / "pr114-release-baseline.json"
    dependencies_path = ROOT / "release" / "production-dependencies.json"
    entitlements_path = ROOT / "NotchSixty" / "NotchSixty.entitlements"
    root_notices_path = ROOT / "THIRD_PARTY_NOTICES.md"
    provenance_path = ROOT / "docs" / "PROVENANCE.md"
    privacy_doc_path = ROOT / "docs" / "PR114_APP_STORE_PRIVACY_SECURITY.md"
    provenance_doc_path = ROOT / "docs" / "PR114_PROVENANCE_SBOM.md"

    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    authority = baseline["releaseAuthority"]
    release_assets = baseline["releaseAssets"]
    privacy = baseline["privacySecurity"]

    release_app = args.release_app
    archive_app = (
        args.archive
        / "Products"
        / "Applications"
        / "Notch Sixty.app"
    )
    rc_app = args.rc_app

    for label, app in (
        ("Release", release_app),
        ("archive", archive_app),
        ("RC", rc_app),
    ):
        require(app.is_dir(), f"{label} app missing: {app}")

    release_info = load_plist(release_app / "Contents" / "Info.plist")
    archive_info = load_plist(archive_app / "Contents" / "Info.plist")
    rc_info = load_plist(rc_app / "Contents" / "Info.plist")

    metadata_keys = (
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion",
        "NSAudioCaptureUsageDescription",
        "NSMicrophoneUsageDescription",
    )
    for key in metadata_keys:
        value = release_info.get(key)
        require(value == archive_info.get(key) == rc_info.get(key),
                f"Release/archive/RC metadata mismatch for {key}")

    product = baseline["product"]
    require(release_info["CFBundleIdentifier"] == product["bundleIdentifier"],
            "bundle identifier drift")
    require(release_info["CFBundleShortVersionString"] == product["marketingVersion"],
            "marketing version drift")
    require(release_info["CFBundleVersion"] == product["buildNumber"],
            "build number drift")
    require(release_info["LSMinimumSystemVersion"] == product["minimumMacOS"],
            "minimum macOS drift")

    executable_paths = {
        "release": release_app / "Contents" / "MacOS" / "Notch Sixty",
        "archive": archive_app / "Contents" / "MacOS" / "Notch Sixty",
        "rc": rc_app / "Contents" / "MacOS" / "Notch Sixty",
    }
    for label, path in executable_paths.items():
        require(path.is_file(), f"{label} executable missing")
        require(executable_archs(path) == ["arm64"],
                f"{label} executable architecture is not arm64")

    for app in (release_app, archive_app, rc_app):
        require(
            (app / "Contents" / "Resources" / "ThirdPartyNotices.txt").is_file(),
            f"shipped third-party notice missing from {app}",
        )

    source_entitlements = load_plist(entitlements_path)
    effective_entitlements = load_plist(args.effective_entitlements)
    require(
        effective_entitlements == source_entitlements,
        "ad-hoc RC effective entitlements differ from shipping entitlements",
    )

    subprocess.run(
        ["codesign", "--verify", "--strict", "--verbose=2", str(rc_app)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    require(args.rc_dmg.is_file() and args.rc_dmg.stat().st_size > 0,
            "remote RC DMG missing/empty")
    require(args.sbom.is_file() and args.sbom.stat().st_size > 0,
            "production SBOM missing/empty")

    sbom = json.loads(args.sbom.read_text(encoding="utf-8"))
    require(sbom.get("bomFormat") == "CycloneDX", "RC SBOM is not CycloneDX")
    sbom_app_props = {
        item["name"]: item["value"]
        for item in sbom["metadata"]["component"]["properties"]
    }
    require(sbom_app_props.get("notchsixty:sourceCommit") == source_sha,
            "SBOM source commit does not match RC source")

    for key in HARD_FALSE_GATES:
        if key in authority:
            require(authority[key] is False, f"release authority gate promoted: {key}")
        elif key in release_assets:
            require(release_assets[key] is False, f"release asset gate promoted: {key}")
        elif key in privacy:
            require(privacy[key] is False, f"privacy metadata gate promoted: {key}")
        else:
            fail(f"hard gate missing from baseline: {key}")

    remote = {
        name: {
            "status": "passed",
            "evidenceAuthority": "remoteSoftware",
        }
        for name in REMOTE_REQUIREMENTS
    }
    # These validators execute in the same macOS job before the marker is
    # written; represent them explicitly even though they share the one marker.
    remote["privacySecurityValidation"]["basis"] = (
        "ci/validate_pr114_privacy_security.py"
    )
    remote["provenanceSBOMValidation"]["basis"] = (
        "ci/validate_pr114_provenance_sbom.py"
    )
    remote["pr113bProductFinishInheritance"]["basis"] = (
        "ci/validate_pr113b_ab_foundation.py"
    )
    remote["commercialMetadataValidation"]["basis"] = (
        "ci/validate_pr114_commercial_handoff.py"
    )

    artifact_hashes = {
        "releaseExecutableSHA256": sha256_file(executable_paths["release"]),
        "archiveExecutableSHA256": sha256_file(executable_paths["archive"]),
        "adhocRCExecutableSHA256": sha256_file(executable_paths["rc"]),
        "remoteRCDMGSHA256": sha256_file(args.rc_dmg),
        "productionSBOMSHA256": sha256_file(args.sbom),
        "releaseBaselineSHA256": sha256_file(baseline_path),
        "productionDependencyManifestSHA256": sha256_file(dependencies_path),
        "shippingEntitlementsSHA256": sha256_file(entitlements_path),
        "rootThirdPartyNoticesSHA256": sha256_file(root_notices_path),
        "provenanceSHA256": sha256_file(provenance_path),
        "privacySecurityDocSHA256": sha256_file(privacy_doc_path),
        "provenanceSBOMDocSHA256": sha256_file(provenance_doc_path),
        "commercialMetadataSHA256": sha256_file(ROOT / "release/pr114-commercial-metadata.json"),
        "commercialHandoffDocSHA256": sha256_file(ROOT / "docs/PR114_COMMERCIAL_METADATA_SUPPORT.md"),
        "releaseHandoffDocSHA256": sha256_file(ROOT / "docs/PR114_RELEASE_HANDOFF.md"),
    }

    report: dict[str, Any] = {
        "schemaVersion": 1,
        "campaign": "PR114_REMOTE_COMMERCIAL_RELEASE_CANDIDATE",
        "evidenceAuthority": "remoteSoftware",
        "sourceCommitSHA": source_sha,
        "githubRunID": run_id,
        "product": {
            "name": product["name"],
            "bundleIdentifier": product["bundleIdentifier"],
            "marketingVersion": product["marketingVersion"],
            "buildNumber": product["buildNumber"],
            "minimumMacOS": product["minimumMacOS"],
            "architectures": ["arm64"],
        },
        "packaging": {
            "unsignedArchivePreflight": True,
            "remoteRCPackageSignature": "ad-hoc",
            "remoteRCPackageNotarized": False,
            "remoteRCPackagePublicDistributionReady": False,
            "manualReleaseDMGLaneProductionSigned": False,
            "manualReleaseDMGLaneNotarized": False,
        },
        "remoteRequirementCount": len(REMOTE_REQUIREMENTS),
        "remotePassedCount": len(remote),
        "remoteRequirements": remote,
        "remoteCommercialRCSoftwareComplete": True,
        "releaseAuthority": {
            "physicalAcceptanceComplete": False,
            "releaseCredentialAcceptanceComplete": False,
            "productionAppleSigningComplete": False,
            "appStoreConnectUploadComplete": False,
            "testFlightAcceptanceComplete": False,
            "appReviewApproved": False,
            "developerIDNotarizationComplete": False,
            "finalAppIconOwnerApproved": False,
            "appStorePrivacyPolicyURLConfigured": False,
            "appStorePrivacyResponsesComplete": False,
            "publicReleaseAuthorized": False,
            "liveFeedForwardANCAuthorized": False,
            "mayMergeIntoMain": False,
            "physicalEvidenceSuppliedByCI": False,
        },
        "artifacts": artifact_hashes,
        "doesNotEstablish": [
            "PR112 H01-H08 physical acceptance",
            "real device/sleep-wake/endurance/speaker-safety acceptance",
            "speaker-connected feed-forward ANC authorization",
            "production Apple signing",
            "App Store Connect upload",
            "TestFlight acceptance",
            "App Review approval",
            "Developer-ID signing/notarization",
            "final app-icon owner approval",
            "App Store privacy-policy URL configuration",
            "App Privacy questionnaire completion",
            "public release authorization",
            "merge authority",
        ],
    }

    require(set(remote) == set(REMOTE_REQUIREMENTS),
            "remote requirement set mismatch")
    require(len(remote) == len(REMOTE_REQUIREMENTS),
            "remote requirement count mismatch")

    canonical = json.dumps(report, sort_keys=True, separators=(",", ":"))
    report["releaseCandidateSHA256"] = hashlib.sha256(
        canonical.encode("utf-8")
    ).hexdigest()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print("PR114 remote commercial RC manifest: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
