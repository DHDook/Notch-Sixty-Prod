#!/usr/bin/env python3
"""PR114 Slice 4 packaging / archive / release-manifest contract."""

from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
PR114_WORKFLOW = ROOT / ".github" / "workflows" / "pr114-commercial-release-candidate.yml"
MANUAL_DMG = ROOT / ".github" / "workflows" / "release-dmg.yml"
RC_BUILDER = ROOT / "ci" / "build_pr114_release_candidate_manifest.py"
BASELINE = ROOT / "release" / "pr114-release-baseline.json"
DOC = ROOT / "docs" / "PR114_COMMERCIAL_RELEASE_CANDIDATE.md"
ROADMAP = ROOT / "docs" / "ROADMAP.md"


def fail(message: str) -> None:
    print(f"PR114 packaging validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (PR114_WORKFLOW, MANUAL_DMG, RC_BUILDER, BASELINE, DOC, ROADMAP):
    require(path.is_file(), f"missing Slice 4 artifact: {path.relative_to(ROOT)}")

workflow = PR114_WORKFLOW.read_text(encoding="utf-8")
manual = MANUAL_DMG.read_text(encoding="utf-8")
builder = RC_BUILDER.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
baseline = json.loads(BASELINE.read_text(encoding="utf-8"))

for token in (
    "Validate PR114 packaging and release manifest",
    "Build deterministic PR114 production SBOM",
    "Build unsigned arm64 Debug app",
    "Run product-finish targeted tests",
    "Build unsigned arm64 Release app",
    "Archive unsigned Release preflight",
    "Verify unsigned archive preflight",
    "Create ad-hoc sandbox RC copy",
    "Verify ad-hoc RC effective entitlements",
    "Create remote RC DMG",
    "Build PR114 remote commercial RC manifest",
    "Upload PR114 remote RC evidence",
    "Run cumulative XCTest regression",
):
    require(token in workflow, f"PR114 workflow missing {token!r}")

for token in (
    "xcodebuild archive",
    "generic/platform=macOS",
    "CODE_SIGNING_ALLOWED=NO",
    "codesign --force --sign -",
    "NotchSixty/NotchSixty.entitlements",
    "codesign -d --entitlements :-",
    "hdiutil create",
    "shasum -a 256",
    "ci/build_pr114_release_candidate_manifest.py",
    "pr114-remote-commercial-rc",
):
    require(token in workflow, f"PR114 packaging workflow lost {token!r}")

# Manual DMG remains explicitly credential-neutral and machine-auditable.
for token in (
    "Ad-hoc sign Release app",
    "not Developer-ID signed or notarized",
    "Create machine-readable package manifest",
    "release-package-manifest.json",
    '"signature": "ad-hoc"',
    '"notarized": false',
    '"publicDistributionReady": false',
    "sourceCommitSHA",
    "dmgSHA256",
):
    require(token in manual, f"manual DMG lane missing {token!r}")

for token in (
    "REMOTE_REQUIREMENTS",
    "unsignedArchivePreflight",
    "adhocSandboxPackagePreflight",
    "releaseCandidateSHA256",
    "remoteRCDMGSHA256",
    "effective_entitlements == source_entitlements",
    '"remoteRCPackageSignature": "ad-hoc"',
    '"remoteRCPackageNotarized": False',
    '"remoteRCPackagePublicDistributionReady": False',
):
    require(token in builder, f"PR114 RC manifest builder missing {token!r}")

authority = baseline["releaseAuthority"]
for key in (
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
):
    require(authority.get(key) is False, f"hard release gate promoted: {key}")

packaging = baseline.get("packaging")
require(isinstance(packaging, dict), "baseline missing packaging contract")
for key in (
    "unsignedArchivePreflightRequired",
    "adhocSandboxPackagePreflightRequired",
    "exactArtifactHashesRequired",
    "manualReleaseDMGLaneAdHocOnly",
):
    require(packaging.get(key) is True, f"packaging contract missing/false: {key}")
require(
    packaging.get("remoteRCPackagePublicDistributionReady") is False,
    "remote RC package must not be public-distribution ready",
)

for token in (
    "Slice 4 implementation — packaging, archive & release-manifest hardening",
    "ad-hoc",
    "unsigned archive",
    "exact-commit",
    "not notarized",
):
    require(token in doc, f"PR114 Slice 4 docs missing {token!r}")

for token in (
    "Slices 1–4 are implemented remotely",
    "packaging",
    "archive",
    "release-manifest",
):
    require(token in roadmap, f"PR114 roadmap missing Slice 4 token {token!r}")

print("PR114 Slice 4 packaging/release-manifest contract: PASS")
