#!/usr/bin/env python3
"""PR114 Slice 5/6: fail-closed owner metadata and integrated exact-head RC gate."""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PENDING = {
    "ownerApprovals": ("listingCopyApproved", "categoryPricingAgeRatingConfirmed",
        "localizationsApproved", "finalIconApproved", "realBuildScreenshotsApproved",
        "hardwareClaimsVerified", "contentRightsAttested", "exportComplianceReviewed"),
    "publicEndpoints": ("supportContactPublished", "privacyPolicyPublished"),
    "appStoreConnect": ("appRecordPrepared", "privacyQuestionnaireSubmitted",
        "reviewContactConfigured", "productionBuildUploaded", "testFlightAccepted",
        "appReviewApproved"),
    "authority": ("physicalAcceptanceComplete", "releaseCredentialsAccepted",
        "externalLegalReviewComplete", "liveFeedForwardANCAuthorized",
        "publicReleaseAuthorized", "mayMergeIntoMain"),
}
HARD_FALSE = (
    "physicalAcceptanceComplete", "releaseCredentialAcceptanceComplete",
    "productionAppleSigningComplete", "appStoreConnectUploadComplete",
    "testFlightAcceptanceComplete", "appReviewApproved",
    "developerIDNotarizationComplete", "publicReleaseAuthorized",
    "liveFeedForwardANCAuthorized", "mayMergeIntoMain",
    "physicalEvidenceSuppliedByCI",
)
REQUIRED = (
    "releaseBaselineValidation", "privacySecurityValidation",
    "provenanceSBOMValidation", "pr113bProductFinishInheritance",
    "commercialMetadataValidation", "debugArm64Build",
    "targetedProductTests", "releaseArm64Build", "unsignedArchivePreflight",
    "adhocSandboxPackagePreflight", "fullXCTestRegression",
)

def check(condition, message):
    if not condition:
        raise ValueError(message)

def digest(path):
    check(path.is_file() and path.stat().st_size > 0, f"missing file: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()

def validate_handoff(h, base):
    check(h.get("schemaVersion") == 1 and h.get("milestone") == "PR114",
          "handoff schema incorrect")
    check(h.get("status") == "DRAFT_NOT_SUBMITTED" and
          h.get("evidenceAuthority") == "remoteSoftware", "handoff claiming approval")
    for key in ("name", "platform", "architecture", "bundleIdentifier",
                "marketingVersion", "buildNumber", "minimumMacOS"):
        check(h.get("product", {}).get(key) == base["product"][key],
              f"handoff identity drift: {key}")
    for section, flags in PENDING.items():
        for key in flags:
            check(h.get(section, {}).get(key) is False,
                  f"unproven authority promoted: {section}.{key}")
    for key in ("supportURL", "privacyPolicyURL", "marketingURL"):
        check(h.get("publicEndpoints", {}).get(key) is None,
              f"unverified owner URL published: {key}")
    for key in HARD_FALSE:
        check(base["releaseAuthority"].get(key) is False,
              f"baseline release gate promoted: {key}")
    check(base["releaseAssets"].get("finalAppIconOwnerApproved") is False,
          "owner has not approved app icon")
    for key in ("appStorePrivacyPolicyURLConfigured", "appStorePrivacyResponsesComplete"):
        check(base["privacySecurity"].get(key) is False, f"store privacy gate promoted: {key}")
    for key in ("subtitleDraft", "promotionalTextDraft", "descriptionDraft"):
        check(len(h.get("copy", {}).get(key, "").strip()) > 15, f"no {key}")

def validate_rc(m, h, base, dmg, sbom, sha, run):
    check(re.fullmatch(r"[0-9a-f]{40}", sha) is not None, "invalid source SHA")
    check(run.isdigit(), "missing numeric Actions run ID")
    check(m.get("campaign") == "PR114_REMOTE_COMMERCIAL_RELEASE_CANDIDATE",
          "wrong release campaign")
    check(m.get("sourceCommitSHA") == sha and str(m.get("githubRunID")) == run,
          "manifest does not bind exact commit and run")
    check(m.get("evidenceAuthority") == "remoteSoftware" and
          m.get("remoteCommercialRCSoftwareComplete") is True, "false RC software claim")
    for key in ("name", "bundleIdentifier", "marketingVersion", "buildNumber",
                "minimumMacOS"):
        check(m.get("product", {}).get(key) == h["product"][key], f"RC identity drift: {key}")
    check(m.get("product", {}).get("architectures") == ["arm64"], "not arm64 only")
    remote = m.get("remoteRequirements", {})
    check(set(remote) == set(REQUIRED) and
          m.get("remotePassedCount") == len(REQUIRED) and
          m.get("remoteRequirementCount") == len(REQUIRED),
          "remote requirements not complete")
    for key in REQUIRED:
        check(remote[key].get("status") == "passed" and
              remote[key].get("evidenceAuthority") == "remoteSoftware",
              f"not remote-software accepted: {key}")
    for key in HARD_FALSE + ("finalAppIconOwnerApproved",
            "appStorePrivacyPolicyURLConfigured", "appStorePrivacyResponsesComplete"):
        check(m.get("releaseAuthority", {}).get(key) is False,
              f"external authority promoted by RC: {key}")
    p = m.get("packaging", {})
    check(p.get("remoteRCPackageSignature") == "ad-hoc" and
          p.get("remoteRCPackageNotarized") is False and
          p.get("remoteRCPackagePublicDistributionReady") is False,
          "package incorrectly described as distributable")
    hashes = m.get("artifacts", {})
    for key, path in (
        ("remoteRCDMGSHA256", dmg),
        ("productionSBOMSHA256", sbom),
        ("commercialMetadataSHA256", ROOT / "release/pr114-commercial-metadata.json"),
        ("commercialHandoffDocSHA256", ROOT / "docs/PR114_COMMERCIAL_METADATA_SUPPORT.md"),
        ("releaseHandoffDocSHA256", ROOT / "docs/PR114_RELEASE_HANDOFF.md"),
    ):
        check(hashes.get(key) == digest(path), f"artifact SHA-256 mismatch: {key}")
    s = json.loads(sbom.read_text(encoding="utf-8"))
    check(s.get("bomFormat") == "CycloneDX" and s.get("specVersion") == "1.5",
          "incorrect SBOM format")
    props = {p["name"]: p["value"] for p in s["metadata"]["component"]["properties"]}
    check(props.get("notchsixty:sourceCommit") == sha, "SBOM source commit mismatch")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--rc-manifest", type=Path)
    p.add_argument("--rc-dmg", type=Path)
    p.add_argument("--sbom", type=Path)
    a = p.parse_args()
    baseline = json.loads((ROOT / "release/pr114-release-baseline.json").read_text())
    h = json.loads((ROOT / "release/pr114-commercial-metadata.json").read_text())
    validate_handoff(h, baseline)
    docs = (ROOT / "docs/PR114_COMMERCIAL_METADATA_SUPPORT.md").read_text()
    closeout = (ROOT / "docs/PR114_RELEASE_HANDOFF.md").read_text()
    for phrase in ("privacy", "User Guide", "Audio Unit", "TestFlight", "App Review"):
        check(phrase.lower() in docs.lower(), f"commercial documentation missing {phrase}")
    for phrase in ("PR112", "H01", "H08", "physicalHardware", "releaseCredential",
                   "externalReview", "NOT AUTHORIZED"):
        check(phrase in closeout, f"handoff missing {phrase}")
    workflow = (ROOT / ".github/workflows/pr114-commercial-release-candidate.yml").read_text()
    for phrase in ("PR114 integrated RC gate", "validate_pr114_commercial_handoff.py",
                   "--rc-manifest", "--rc-dmg", "--sbom"):
        check(phrase in workflow, f"CI gate missing {phrase}")
    if a.self_test:
        for section, flags in PENDING.items():
            for key in flags:
                mutant = copy.deepcopy(h)
                mutant[section][key] = True
                try:
                    validate_handoff(mutant, baseline)
                except ValueError:
                    continue
                raise ValueError(f"negative test failed for {section}.{key}")
    if a.rc_manifest is not None:
        check(a.rc_dmg is not None and a.sbom is not None, "DMG and SBOM required")
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"],
                                      cwd=ROOT, text=True).strip()
        check(os.environ.get("GITHUB_SHA") == sha, "checkout not current Actions SHA")
        manifest = json.loads(a.rc_manifest.read_text())
        validate_rc(manifest, h, baseline, a.rc_dmg, a.sbom,
                    sha, os.environ.get("GITHUB_RUN_ID", ""))
    else:
        check(a.rc_dmg is None and a.sbom is None,
              "cannot bypass manifest to verify artifacts")
    print("PR114 commercial owner handoff and exact-head RC gate: PASS")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as ex:
        print(f"PR114 commercial gate FAIL: {ex}", file=sys.stderr)
        raise SystemExit(1)
