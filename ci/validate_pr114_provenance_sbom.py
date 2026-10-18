#!/usr/bin/env python3
"""PR114 Slice 3 licensing, provenance and deterministic SBOM contract."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
DEPENDENCIES = ROOT / "release" / "production-dependencies.json"
BASELINE = ROOT / "release" / "pr114-release-baseline.json"
PROVENANCE = ROOT / "docs" / "PROVENANCE.md"
ROOT_LICENSE = ROOT / "LICENSE"
ROOT_NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
SHIPPED_NOTICE = ROOT / "NotchSixty" / "ThirdPartyNotices.txt"
BUILDER = ROOT / "ci" / "build_pr114_sbom.py"
DOC = ROOT / "docs" / "archive" / "PR114_PROVENANCE_SBOM.md"

PACKAGE_BASENAMES = {
    "Package.swift",
    "Package.resolved",
    "Podfile",
    "Podfile.lock",
    "Cartfile",
    "Cartfile.resolved",
}
BINARY_SUFFIXES = {".framework", ".xcframework", ".dylib", ".a"}


def fail(message: str) -> None:
    print(f"PR114 Slice 3 validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (
    PROJECT,
    DEPENDENCIES,
    BASELINE,
    PROVENANCE,
    ROOT_LICENSE,
    ROOT_NOTICES,
    SHIPPED_NOTICE,
    BUILDER,
    DOC,
):
    require(path.is_file(), f"missing Slice 3 artifact: {path.relative_to(ROOT)}")

project = PROJECT.read_text(encoding="utf-8")
dependencies = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))
baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
provenance = PROVENANCE.read_text(encoding="utf-8")
license_text = ROOT_LICENSE.read_text(encoding="utf-8")
root_notices = ROOT_NOTICES.read_text(encoding="utf-8")
shipped_notice = SHIPPED_NOTICE.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")

require("proprietary and confidential" in license_text.lower(),
        "root proprietary license contract changed")

supply = baseline.get("provenanceSupplyChain", {})
expected_supply = {
    "productionDependencyManifestReconciled": True,
    "postPR42ProvenanceReconciled": True,
    "bundledThirdPartyComponentCount": 1,
    "vendorRootCount": 1,
    "swiftPackageDependencyCount": 0,
    "cocoaPodsDependencyCount": 0,
    "packagedBinaryDependencyCount": 0,
    "sbomFormat": "CycloneDX 1.5",
    "deterministicSBOMGeneratedByCI": True,
    "externalLegalIPReviewComplete": False,
}
require(supply == expected_supply, f"supply-chain baseline drift: {supply!r}")

for token in (
    "XCRemoteSwiftPackageReference",
    "XCLocalSwiftPackageReference",
    "XCSwiftPackageProductDependency",
):
    require(token not in project, f"unclassified Swift package reference: {token}")

package_files: list[str] = []
unexpected_binaries: list[str] = []
for path in ROOT.rglob("*"):
    if path.name in PACKAGE_BASENAMES and path.is_file():
        package_files.append(str(path.relative_to(ROOT)))
    if path.is_dir() and path.suffix.lower() in {".framework", ".xcframework"}:
        unexpected_binaries.append(str(path.relative_to(ROOT)))
    elif path.is_file() and path.suffix.lower() in {".dylib", ".a"}:
        unexpected_binaries.append(str(path.relative_to(ROOT)))

require(not package_files, f"unclassified package-manager files: {package_files}")
require(not unexpected_binaries, f"unclassified packaged binaries: {unexpected_binaries}")

policy = dependencies.get("policy", {})
require(policy.get("productionSourceLicense") == "Proprietary",
        "production source license classification changed")
require(policy.get("unclassifiedProductionDependencyAllowed") is False,
        "unclassified dependencies must fail closed")
for family in ("GPL", "AGPL"):
    require(family in policy.get("forbiddenDependencyLicenseFamilies", []),
            f"forbidden dependency family lost: {family}")

components = dependencies.get("thirdPartyComponents", [])
require(len(components) == 1, "expected exactly one bundled third-party component")
lib = components[0]
require(lib.get("id") == "libmysofa", "bundled component is not libmysofa")
require(lib.get("version") == "1.3.4", "libmysofa version drift")
require(lib.get("license") == "BSD-3-Clause", "libmysofa license drift")
require(lib.get("realtimeRenderPath") is False,
        "libmysofa parsing must remain off realtime render path")

declared_vendor_root = lib.get("vendoredRoot")
require(declared_vendor_root == "NotchSixty/Audio/SOFA/Vendor/libmysofa",
        "libmysofa vendor root drift")

actual_vendor_roots: list[str] = []
for vendor in (ROOT / "NotchSixty").rglob("Vendor"):
    if not vendor.is_dir():
        continue
    for child in vendor.iterdir():
        if child.is_dir():
            actual_vendor_roots.append(str(child.relative_to(ROOT)))
require(
    sorted(actual_vendor_roots) == [declared_vendor_root],
    f"unclassified vendor tree: {actual_vendor_roots}",
)

for source in lib.get("productionSourceFiles", []):
    path = ROOT / source
    require(path.is_file(), f"classified libmysofa source missing: {source}")
    require(path.name in project, f"classified libmysofa source not compiled: {source}")

for token in (
    "libmysofa v1.3.4",
    "BSD 3-Clause",
):
    require(token in root_notices, f"root notices missing {token!r}")
    require(token in shipped_notice, f"shipped notices missing {token!r}")

for token in (
    "PR43–PR45 advanced speaker optimization",
    "PR52–PR64 semantic N-channel and multichannel platform",
    "PR56–PR66 headphone, binaural, virtual-speaker and head-tracking platform",
    "PR69–PR71 adaptive sample-rate / clock transport",
    "PR72–PR77 ambient analysis and MIMO active room treatment",
    "PR79–PR84 Audio Unit hosting",
    "PR90–PR100 Active Acoustics / Quiet Zone / feed-forward foundations",
    "PR103–PR111 Speaker Optimizer and Advanced Measurement Lab",
    "PR112A hardware-acceptance infrastructure",
    "PR113 Production UX / User Guide / DSP Reference",
    "PR113B A/B, backup/recovery, measurement export and Headroom Assistant",
):
    require(token in provenance, f"post-PR42 provenance missing {token!r}")

for forbidden in ("GPL production dependency", "AGPL production dependency"):
    require(forbidden not in doc, f"Slice 3 documentation contains unresolved {forbidden}")

head = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()

with tempfile.TemporaryDirectory() as temp:
    first = Path(temp) / "sbom-1.json"
    second = Path(temp) / "sbom-2.json"
    for output in (first, second):
        subprocess.run(
            [sys.executable, str(BUILDER), "--output", str(output)],
            cwd=ROOT,
            check=True,
        )

    first_bytes = first.read_bytes()
    second_bytes = second.read_bytes()
    require(first_bytes == second_bytes, "SBOM builder is not deterministic")

    sbom = json.loads(first_bytes)
    require(sbom.get("bomFormat") == "CycloneDX", "SBOM is not CycloneDX")
    require(sbom.get("specVersion") == "1.5", "unexpected CycloneDX version")
    require(sbom.get("version") == 1, "unexpected SBOM document version")

    app = sbom.get("metadata", {}).get("component", {})
    require(app.get("type") == "application", "SBOM root component is not app")
    require(app.get("name") == "Notch Sixty", "SBOM product name drift")
    require(app.get("version") == "1.0.0", "SBOM app version drift")

    properties = {
        item["name"]: item["value"]
        for item in app.get("properties", [])
    }
    require(properties.get("notchsixty:sourceCommit") == head,
            "SBOM source commit does not match checked-out head")
    require(properties.get("notchsixty:productionSourceLicense") == "Proprietary",
            "SBOM source-license classification drift")

    sbom_components = sbom.get("components", [])
    require(len(sbom_components) == 1, "SBOM third-party component count drift")
    sbom_lib = sbom_components[0]
    require(sbom_lib.get("name") == "libmysofa", "SBOM dependency name drift")
    require(sbom_lib.get("version") == "1.3.4", "SBOM dependency version drift")

    lib_props = {
        item["name"]: item["value"]
        for item in sbom_lib.get("properties", [])
    }
    require(len(lib_props.get("notchsixty:licenseFileSHA256", "")) == 64,
            "SBOM license hash missing")
    require(len(lib_props.get("notchsixty:shippingNoticeSHA256", "")) == 64,
            "SBOM notice hash missing")
    require(len(lib_props.get("notchsixty:productionSourceSetSHA256", "")) == 64,
            "SBOM source-set hash missing")

    dependencies_graph = sbom.get("dependencies", [])
    root_ref = app.get("bom-ref")
    root_edges = [item for item in dependencies_graph if item.get("ref") == root_ref]
    require(len(root_edges) == 1 and len(root_edges[0].get("dependsOn", [])) == 1,
            "SBOM dependency graph does not show exactly one bundled dependency")

    digest = hashlib.sha256(first_bytes).hexdigest()
    require(len(digest) == 64, "SBOM document hash failed")

for token in (
    "CycloneDX 1.5",
    "libmysofa v1.3.4",
    "no Swift package",
    "no CocoaPods",
    "no packaged binary framework",
    "user-installed Audio Units",
    "interoperability",
):
    require(token in doc, f"Slice 3 documentation missing {token!r}")

print("PR114 Slice 3 licensing/provenance/SBOM contract: PASS")
