#!/usr/bin/env python3
"""PR114 Slice 4 packaging/archive/RC-manifest static contract."""

from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

BASELINE = ROOT / "release" / "pr114-release-baseline.json"
WORKFLOW = ROOT / ".github" / "workflows" / "pr114-commercial-release-candidate.yml"
MANUAL_DMG = ROOT / ".github" / "workflows" / "release-dmg.yml"
BUILDER = ROOT / "ci" / "build_pr114_release_candidate_manifest.py"
DOC = ROOT / "docs" / "PR114_PACKAGING_RELEASE_MANIFEST.md"


def fail(message: str) -> None:
    print(f"PR114 Slice 4 validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (BASELINE, WORKFLOW, MANUAL_DMG, BUILDER, DOC):
    require(path.is_file(), f"missing Slice 4 artifact: {path.relative_to(ROOT)}")

baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
workflow = WORKFLOW.read_text(encoding="utf-8")
manual = MANUAL_DMG.read_text(encoding="utf-8")
builder = BUILDER.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")

expected_packaging = {
    "unsignedGenericArchivePreflightConfigured": True,
    "adhocSandboxRCPackageConfigured": True,
    "exactHeadRCManifestConfigured": True,
    "remoteRCDMGChecksummed": True,
    "remoteRCPackageProductionSigned": False,
    "remoteRCPackageNotarized": False,
    "remoteRCPackagePublicDistributionReady": False,
    "manualReleaseDMGLaneProductionSigned": False,
    "manualReleaseDMGLaneNotarized": False,
}
require(
    baseline.get("packaging") == expected_packaging,
    f"packaging baseline drift: {baseline.get('packaging')!r}",
)

for token in (
    "Archive unsigned Release preflight",
    "-destination 'generic/platform=macOS'",
    "CODE_SIGNING_ALLOWED=NO",
    'ARCHIVE="$RUNNER_TEMP/NotchSixty-PR114.xcarchive"',
    "Build ad-hoc sandboxed remote RC DMG",
    "codesign --force --sign - --timestamp=none",
    "--entitlements NotchSixty/NotchSixty.entitlements",
    "codesign --verify --strict",
    "pr114-effective-entitlements.plist",
    "hdiutil create",
    "shasum -a 256",
    "Build exact-head PR114 RC manifest",
    "build_pr114_release_candidate_manifest.py",
    "pr114-release-candidate.json",
    "Upload PR114 remote RC evidence",
    "pr114-remote-commercial-rc",
):
    require(token in workflow, f"PR114 packaging workflow missing {token!r}")

for forbidden in (
    "xcrun notarytool",
    "notarytool submit",
    "altool --upload-app",
    "xcrun altool",
    "Developer ID Application:",
    "3rd Party Mac Developer Application:",
    "Apple Distribution:",
):
    require(
        forbidden not in workflow,
        f"repository CI gained unreconciled production credential action: {forbidden}",
    )

for token in (
    "workflow_dispatch:",
    "Build Release app",
    "-destination 'platform=macOS,arch=arm64'",
    "codesign",
    "--sign -",
    "hdiutil create",
    "shasum -a 256",
    "not Developer-ID signed or notarized",
):
    require(token in manual, f"manual DMG truthfulness contract missing {token!r}")

for token in (
    "PR114_REMOTE_COMMERCIAL_RELEASE_CANDIDATE",
    '"remoteRCPackageSignature": "ad-hoc"',
    '"remoteRCPackageNotarized": False',
    '"remoteRCPackagePublicDistributionReady": False',
    '"productionAppleSigningComplete": False',
    '"appStoreConnectUploadComplete": False',
    '"publicReleaseAuthorized": False',
    '"mayMergeIntoMain": False',
    "remoteRCDMGSHA256",
    "productionSBOMSHA256",
    "releaseCandidateSHA256",
):
    require(token in builder, f"RC manifest builder missing {token!r}")

for token in (
    "unsigned generic archive",
    "ad-hoc",
    "not notarized",
    "not public-distribution ready",
    "exact source commit",
    "SHA-256",
    "production Apple signing",
):
    require(token in doc, f"Slice 4 documentation missing {token!r}")

print("PR114 Slice 4 packaging/archive/manifest contract: PASS")
