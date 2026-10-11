#!/usr/bin/env python3
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "release" / "production-dependencies.json"
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"


def fail(message: str) -> None:
    print(f"PR102 dependency-manifest validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


require(MANIFEST.is_file(), "missing release/production-dependencies.json")
require(PROJECT.is_file(), "missing Xcode project")

data = json.loads(MANIFEST.read_text(encoding="utf-8"))
require(data.get("schemaVersion") == 1, "unexpected manifest schema version")
policy = data.get("policy")
require(isinstance(policy, dict), "dependency policy missing")
require(policy.get("unclassifiedProductionDependencyAllowed") is False, "unclassified dependency policy must fail closed")
for forbidden in ("GPL", "AGPL"):
    require(forbidden in policy.get("forbiddenDependencyLicenseFamilies", []), f"missing forbidden family {forbidden}")

components = data.get("thirdPartyComponents")
require(isinstance(components, list) and components, "third-party component catalog is empty")
ids = [component.get("id") for component in components if isinstance(component, dict)]
require(len(ids) == len(components), "malformed component entry")
require(len(set(ids)) == len(ids), "duplicate component IDs")

declared_vendor_roots = set()
declared_production_sources = set()
project = PROJECT.read_text(encoding="utf-8")

for component in components:
    for field in (
        "id",
        "name",
        "version",
        "license",
        "upstream",
        "vendoredRoot",
        "licenseFile",
        "shippingNoticeFile",
        "purpose",
    ):
        value = component.get(field)
        require(isinstance(value, str) and value.strip(), f"{component.get('id')} missing {field}")

    license_name = component["license"].upper()
    require("GPL" not in license_name and "AGPL" not in license_name, f"forbidden license in production component {component['id']}")

    vendor_root = component["vendoredRoot"]
    declared_vendor_roots.add(vendor_root)
    root_path = ROOT / vendor_root
    require(root_path.is_dir(), f"declared vendor root missing: {vendor_root}")
    require((ROOT / component["licenseFile"]).is_file(), f"license file missing for {component['id']}")
    require((ROOT / component["shippingNoticeFile"]).is_file(), f"shipping notice missing for {component['id']}")
    require(component.get("realtimeRenderPath") is False, f"{component['id']} must not run on realtime render path")

    sources = component.get("productionSourceFiles")
    require(isinstance(sources, list) and sources, f"{component['id']} production source list missing")
    require(len(set(sources)) == len(sources), f"{component['id']} source list contains duplicates")
    for source in sources:
        require(isinstance(source, str) and source.strip(), f"{component['id']} has malformed source path")
        path = ROOT / source
        require(path.is_file(), f"declared production source missing: {source}")
        declared_production_sources.add(source)
        require(path.name in project, f"declared vendor source is not referenced by the Xcode project: {source}")

# Every top-level Vendor/<component> directory in production source must be
# classified. This prevents a new vendored dependency from entering silently.
actual_vendor_roots = set()
notch = ROOT / "NotchSixty"
for path in notch.rglob("Vendor"):
    if not path.is_dir():
        continue
    for child in path.iterdir():
        if child.is_dir():
            actual_vendor_roots.add(str(child.relative_to(ROOT)))

require(
    actual_vendor_roots == declared_vendor_roots,
    f"vendor-root catalog mismatch: actual={sorted(actual_vendor_roots)} declared={sorted(declared_vendor_roots)}",
)

# Every C/C++/ObjC production source below a declared vendor root must appear in
# the explicit production-source list if the project compiles it.
for vendor_root in actual_vendor_roots:
    root_path = ROOT / vendor_root
    for path in root_path.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".c", ".cc", ".cpp", ".m", ".mm"}:
            continue
        relative = str(path.relative_to(ROOT))
        if path.name in project:
            require(relative in declared_production_sources, f"compiled vendored source is unclassified: {relative}")

# Catch packaged binary dependencies and Swift package dependency files. Apple
# SDK frameworks are referenced by the SDK/project and are not vendored files.
binary_suffixes = {".framework", ".xcframework", ".dylib", ".a"}
unexpected_binaries = []
for path in ROOT.rglob("*"):
    if not path.exists():
        continue
    if path.is_dir() and path.suffix.lower() in {".framework", ".xcframework"}:
        unexpected_binaries.append(str(path.relative_to(ROOT)))
    elif path.is_file() and path.suffix.lower() in {".dylib", ".a"}:
        unexpected_binaries.append(str(path.relative_to(ROOT)))
require(not unexpected_binaries, f"unclassified packaged binary dependency found: {unexpected_binaries}")

for package_file in ("Package.swift", "Package.resolved"):
    require(not (ROOT / package_file).exists(), f"Swift package dependency file requires PR102 classification: {package_file}")

interop = data.get("interoperabilityOnly")
require(isinstance(interop, list), "interoperability-only catalog missing")
for item in interop:
    require(item.get("codeBundledOrLinked") is False, f"interoperability item unexpectedly bundles code: {item}")

print("PR102 production dependency manifest validation passed")
