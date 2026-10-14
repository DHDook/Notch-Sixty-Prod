#!/usr/bin/env python3
"""Batch 4: exact-head, remotely scoped SOFTWARE-validation handoff.

All input markers must be created in the SAME macOS Actions job AFTER
individual real commands succeed; no PR112 hardware/signer authority flows
from these markers. Hashes identify files, not cryptographic signatures.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
GATES = (
    "portable_contract",
    "apple_reference",
    "native_sofa_fixture",
    "release_arm64",
    "full_xctest",
    "sbom_provenance",
    "hardware_authority_boundary",
)
FILES = (
    "NotchSixty/Audio/BlindABXValidation.swift",
    "NotchSixty/UI/ProductionBlindListeningWorkspace.swift",
    "NotchSixtyTests/BlindABXValidationTests.swift",
    "NotchSixty/UI/ProductionHeadphoneWorkspace.swift",
    "NotchSixty/Audio/UnifiedAcousticIntelligenceCoordinator.swift",
    "NotchSixty.xcodeproj/project.pbxproj",
    "NotchSixty/NotchSixty.entitlements",
    "THIRD_PARTY_NOTICES.md",
    "docs/PROVENANCE.md",
    "release/production-dependencies.json",
    "docs/BATCH4_FINAL_PRODUCT_HANDOFF.md",
)
ANCESTORS = {
    "batch1AcousticReference": "e687bdd0cda7e7e19c6b4a7b3f33e25b45156534",
    "batch2AcousticIntelligence": "7d10a2340be732b3110fd418e97d865ecce3967f",
    "batch3Headphones": "256ec109aed8f73b59b240f89d9ff4a11076f0ed",
}
FALSE = (
    "physicalAcceptanceComplete",
    "native384kHzDACVerified",
    "headphoneListeningAcceptanceComplete",
    "coherentMultiSubHardwareVerified",
    "liveFeedForwardANCAuthorized",
    "externalLegalIPReviewComplete",
    "productionAppleSigningComplete",
    "appStoreConnectUploadComplete",
    "testFlightAcceptanceComplete",
    "appReviewApproved",
    "developerIDNotarizationComplete",
    "releaseAcceptanceComplete",
    "mayMergeIntoMain",
    "physicalEvidenceSuppliedByCI",
)

def need(ok, reason):
    if not ok:
        raise SystemExit("Batch 4 handoff refused: " + reason)

def git(*cmd):
    return subprocess.check_output(
        ["git", *cmd], cwd=ROOT, text=True
    ).strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--markers-dir", type=pathlib.Path, required=True)
    parser.add_argument("--sbom", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    opts = parser.parse_args()
    head = git("rev-parse", "HEAD")
    need(head == opts.commit, "requested exact commit is not checked-out HEAD")
    need(opts.branch == "feature/batch4-final-product-validation",
         "different feature branch cannot assert batch-four provenance")
    need(len(head) == 40, "expected full commit SHA")
    need(all((opts.markers_dir / (x + ".ok")).is_file() for x in GATES),
         "at least one same-job software check is not attested as complete")
    need(opts.sbom.is_file(), "fresh same-run CycloneDX SBOM missing")
    for name, commit in ANCESTORS.items():
        need(
            subprocess.run(
                ["git", "merge-base", "--is-ancestor", commit, head],
                cwd=ROOT, capture_output=True, check=False
            ).returncode == 0,
            "required tested stacked parent absent: " + name
        )
    manifest = {}
    for name in FILES:
        path = ROOT / name
        need(path.is_file(), "expected product source absent: " + name)
        manifest[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    sbom_digest = hashlib.sha256(opts.sbom.read_bytes()).hexdigest()
    sbom = json.loads(opts.sbom.read_text())
    need(sbom.get("bomFormat") == "CycloneDX",
         "actual CycloneDX format missing")
    report = {
        "schemaVersion": 1,
        "batch": "BATCH4_FINAL_PRODUCT_VALIDATION",
        "headSHA": head,
        "branch": opts.branch,
        "sourceTreeSHA": git("rev-parse", "HEAD^{tree}"),
        "ancestralTestedBatchHeads": ANCESTORS,
        "evidenceAuthority": "remoteSoftware",
        "checks": {name: "same_job_pass" for name in GATES},
        "exactHeadSoftwareIntegrationComplete": True,
        "referenceSampleRatesHz": [
            44100, 48000, 88200, 96000, 176400,
            192000, 352800, 384000
        ],
        "productFileSHA256": manifest,
        "freshCycloneDXSBOMSHA256": sbom_digest,
        "blindABXScope": "exploratory_offline_local_files_only",
        "realHeadphoneMeasurementsImported": False,
        "deviceSpecificAcousticVerificationComplete": False,
        "userHardwareH01ThroughH08": "pending_real_physical_owner_campaign",
        "ownerHandoffChecklist": [
            "Run H01-H08 on a real Mac with device/clock/route identities",
            "Check all supported physical sample rates on the actual DAC",
            "Perform calibrated speaker, subwoofer and driver acoustic verification",
            "Validate real headphone safety and HRTF perceptual comfort",
            "Review manual listening and optional offline ABX without treating it as device safety",
            "Confirm brand/icon, privacy declarations and source rights independently",
            "Complete required Apple signing/notarization/TestFlight/App Store steps",
            "Authorize release and merge only with explicit owner approval",
        ],
        **{flag: False for flag in FALSE},
    }
    need(report["mayMergeIntoMain"] is False
         and report["physicalAcceptanceComplete"] is False,
         "remote evidence may not authorize release")
    opts.output.parent.mkdir(parents=True, exist_ok=True)
    opts.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("Batch 4 exact-head SOFTWARE report PASS:", head)
    print("Full app and review provenance audited; physical/release gates remain FALSE.")

if __name__ == "__main__":
    main()
