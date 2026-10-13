#!/usr/bin/env python3
"""PR114 Slice 1 commercial release-baseline reconciliation contract."""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE_SHA = "f10008d8330c2dc29f195163c56cf4723fc16a6c"
SLICE1_CHECKPOINT_SHA = "a4fc2eda5f72e1711f7dee91d308c75dce2950be"

BASELINE = ROOT / "release" / "pr114-release-baseline.json"
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
INFO = ROOT / "NotchSixty" / "Info.plist"
ENTITLEMENTS = ROOT / "NotchSixty" / "NotchSixty.entitlements"
DEPENDENCIES = ROOT / "release" / "production-dependencies.json"
README = ROOT / "README.md"
ROADMAP = ROOT / "docs" / "ROADMAP.md"
DOC = ROOT / "docs" / "PR114_COMMERCIAL_RELEASE_CANDIDATE.md"
ROOT_NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
SHIPPED_NOTICE = ROOT / "NotchSixty" / "ThirdPartyNotices.txt"
PROVENANCE = ROOT / "docs" / "PROVENANCE.md"
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
ROOT_VIEW = ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift"
LEGACY_VIEW = ROOT / "NotchSixty" / "ContentView.swift"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-dmg.yml"
APP_ICON_CATALOG = ROOT / "NotchSixty" / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json"
DOCK_LIGHT = ROOT / "NotchSixty" / "Assets.xcassets" / "DockIconLight.imageset" / "DockIconLight@2x.png"
DOCK_DARK = ROOT / "NotchSixty" / "Assets.xcassets" / "DockIconDark.imageset" / "DockIconDark@2x.png"

ALLOWED_SLICE1_PATHS = {
    "README.md",
    "docs/ROADMAP.md",
    "docs/PR114_COMMERCIAL_RELEASE_CANDIDATE.md",
    "release/pr114-release-baseline.json",
    "ci/validate_pr114_release_baseline.py",
    ".github/workflows/pr114-commercial-release-candidate.yml",
}


def fail(message: str) -> None:
    print(f"PR114 Slice 1 validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (
    BASELINE,
    PROJECT,
    INFO,
    ENTITLEMENTS,
    DEPENDENCIES,
    README,
    ROADMAP,
    DOC,
    ROOT_NOTICES,
    SHIPPED_NOTICE,
    PROVENANCE,
    APP,
    ROOT_VIEW,
    LEGACY_VIEW,
    RELEASE_WORKFLOW,
    APP_ICON_CATALOG,
    DOCK_LIGHT,
    DOCK_DARK,
):
    require(path.is_file(), f"missing required artifact: {path.relative_to(ROOT)}")

baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
deps = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))
project = PROJECT.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
root_notices = ROOT_NOTICES.read_text(encoding="utf-8")
shipped_notice = SHIPPED_NOTICE.read_text(encoding="utf-8")
provenance = PROVENANCE.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
root_view = ROOT_VIEW.read_text(encoding="utf-8")
legacy = LEGACY_VIEW.read_text(encoding="utf-8")
release_workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

with INFO.open("rb") as handle:
    info = plistlib.load(handle)
with ENTITLEMENTS.open("rb") as handle:
    entitlements = plistlib.load(handle)

require(baseline.get("schemaVersion") == 1, "unexpected baseline schema")
require(baseline.get("milestone") == "PR114", "baseline milestone mismatch")

product = baseline.get("product", {})
require(product.get("name") == "Notch Sixty", "product name mismatch")
require(product.get("platform") == "macOS", "platform mismatch")
require(product.get("architecture") == "arm64", "architecture mismatch")
require(
    product.get("bundleIdentifier") == "com.dhdook.NotchSixty",
    "bundle identifier mismatch",
)
require(product.get("marketingVersion") == "1.0.0", "marketing version mismatch")
require(product.get("buildNumber") == "1", "build number mismatch")
require(product.get("minimumMacOS") == "27.0", "deployment target mismatch")
require(product.get("hardenedRuntime") is True, "hardened runtime baseline lost")
require(product.get("appSandbox") is True, "sandbox baseline lost")

stack = baseline.get("stack", {})
require(stack.get("exactPR113BBaseHead") == BASE_SHA, "PR113B base SHA mismatch")
require(stack.get("exactPR113BCloseoutRun") == 38467523568, "PR113B run mismatch")
require(stack.get("mainModifiedByPR114") is False, "PR114 may not claim main changed")

expected_evidence = {
    "remoteSoftware",
    "physicalHardware",
    "releaseCredential",
    "externalReview",
}
require(
    set(baseline.get("evidenceClasses", [])) == expected_evidence,
    "release evidence classes changed",
)

expected_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
}
require(entitlements == expected_entitlements, f"shipping entitlements changed: {entitlements!r}")
require(
    set(baseline.get("shippingEntitlements", [])) == set(expected_entitlements),
    "baseline entitlement inventory does not match entitlements file",
)

for key in ("NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"):
    value = info.get(key)
    require(isinstance(value, str) and value.strip(), f"missing privacy string {key}")
require(
    set(baseline.get("privacyPurposeStrings", []))
    == {"NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"},
    "privacy purpose-string inventory changed",
)


def setting_values(name: str) -> list[str]:
    return [
        match.strip()
        for match in re.findall(rf"\b{name} = ([^;]+);", project)
    ]


def unique_setting(name: str) -> str:
    values = setting_values(name)
    require(values, f"project missing {name}")
    unique = set(values)
    require(len(unique) == 1, f"{name} differs across configurations: {values}")
    return values[0]


require(unique_setting("ARCHS") == "arm64", "shipping architecture is not arm64")
require(unique_setting("MARKETING_VERSION") == product["marketingVersion"], "version drift")
require(unique_setting("CURRENT_PROJECT_VERSION") == product["buildNumber"], "build drift")
require(unique_setting("MACOSX_DEPLOYMENT_TARGET") == product["minimumMacOS"], "deployment drift")
require("PRODUCT_BUNDLE_IDENTIFIER = com.dhdook.NotchSixty;" in project, "app bundle ID missing")
require("ENABLE_HARDENED_RUNTIME = YES;" in project, "hardened runtime missing")
require(
    "CODE_SIGN_ENTITLEMENTS = NotchSixty/NotchSixty.entitlements;" in project,
    "shipping entitlements setting missing",
)
require("DEVELOPMENT_TEAM =" not in project, "Apple development team must remain external")
require(
    "PROVISIONING_PROFILE_SPECIFIER =" not in project,
    "provisioning profile must remain external",
)

release_assets = baseline.get("releaseAssets", {})
require(release_assets.get("shippingIconAssetsPresent") is True,
        "shipping icon assets are not inventoried")
require(release_assets.get("finalAppIconOwnerApproved") is False,
        "PR114 must not self-approve final app artwork")
require(release_assets.get("finalAppIconApprovalRequiredBeforePublicRelease") is True,
        "public release must retain owner icon-approval gate")

authority = baseline.get("releaseAuthority", {})
require(authority.get("remoteSoftwareBaselineReconciled") is True, "remote baseline not marked reconciled")
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
    require(authority.get(key) is False, f"hard release gate must remain false: {key}")

components = deps.get("thirdPartyComponents", [])
require(len(components) == 1, "unexpected classified production dependency count")
lib = components[0]
require(lib.get("id") == "libmysofa", "classified dependency is not libmysofa")
require(lib.get("version") == "1.3.4", "libmysofa version drift")
require(lib.get("license") == "BSD-3-Clause", "libmysofa license drift")
require(deps.get("policy", {}).get("unclassifiedProductionDependencyAllowed") is False,
        "unclassified production dependencies must fail closed")

baseline_deps = baseline.get("productionDependencies", [])
require(
    baseline_deps == [{
        "id": "libmysofa",
        "version": "1.3.4",
        "license": "BSD-3-Clause",
        "shippingNoticeRequired": True,
    }],
    "PR114 dependency baseline does not match classified production dependency",
)

for text, label in (
    (root_notices, "root notices"),
    (shipped_notice, "shipped notice"),
    (provenance, "provenance"),
):
    require("libmysofa" in text and "1.3.4" in text, f"{label} lost libmysofa identity")


# Durable release-hardening rules formerly exercised by PR45, expressed against
# the current PR113B product architecture instead of obsolete source strings or
# historical icon hashes.
require(legacy.lstrip().startswith("#if DEBUG"), "legacy engineering view is not DEBUG-only")
require(legacy.rstrip().endswith("#endif"), "legacy engineering view lost DEBUG closure")
for token in (
    "#if DEBUG\nprivate struct PR27ProtectionValidationView",
    '#if DEBUG\n        Window("Engineering Validation", id: "engineering-validation")',
    "import ServiceManagement",
    "SMAppService.mainApp.status",
    "SMAppService.mainApp.register()",
    "SMAppService.mainApp.unregister()",
    '"Launch at Login"',
    "does not automatically start audio processing",
    'settingsCard(title: "Permissions"',
    'settingsCard(title: "Support"',
    'Label("Copy Diagnostics", systemImage: "doc.on.doc")',
    "func diagnosticsReport(",
    '"Content Preset: \\(profiles.selectedContentPresetName)"',
    '"Playback System: \\(profiles.selectedSystemProfileName)"',
    '"DSP Latency: \\(latency)"',
    "product.diagnosticsReport(",
    "does not include captured audio or room-measurement samples",
):
    require(token in app, f"current release-hardening app contract missing {token!r}")

engineering_call = 'openWindow(id: "engineering-validation")'
engineering_index = root_view.find(engineering_call)
require(engineering_index >= 0, "Engineering Validation toolbar action is missing")
debug_index = root_view.rfind("#if DEBUG", 0, engineering_index)
endif_index = root_view.find("#endif", engineering_index)
require(debug_index >= 0 and endif_index >= 0,
        "Engineering Validation toolbar action is not DEBUG-gated")

for token in (
    "workflow_dispatch:",
    "Build Release app",
    "-destination 'platform=macOS,arch=arm64'",
    "Ad-hoc sign Release app",
    "shasum -a 256",
    "Upload Release DMG",
    "not Developer-ID signed or notarized",
):
    require(token in release_workflow, f"manual Release-DMG contract missing {token!r}")

# Current icon files must remain technically present, but owner approval of the
# final commercial artwork deliberately remains unresolved.
icon_manifest = json.loads(APP_ICON_CATALOG.read_text(encoding="utf-8"))
icon_files = [entry.get("filename") for entry in icon_manifest.get("images", []) if entry.get("filename")]
require(len(icon_files) == 20 and len(set(icon_files)) == 20,
        "AppIcon catalog must contain 20 unique light/dark slots")
require(DOCK_LIGHT.stat().st_size > 0 and DOCK_DARK.stat().st_size > 0,
        "runtime Dock icon assets are empty")

for relative in (
    ".github/workflows/pr45-apply-release-hardening.yml",
    "ci/pr45_apply_release_hardening.py",
    ".github/workflows/pr45-apply-launch-at-login-menu.yml",
    "ci/pr45_add_launch_at_login_menu.py",
    ".github/workflows/pr45-apply-login-placement.yml",
    "ci/pr45_remove_login_toggle_from_tray.py",
    ".github/workflows/pr45-apply-final-app-icons.yml",
    ".github/workflows/pr45-export-current-icons.yml",
):
    require(not (ROOT / relative).exists(), f"one-shot release staging file remains: {relative}")

for token in (
    "PR114 — Commercial Release Candidate",
    "f10008d8330c2dc29f195163c56cf4723fc16a6c",
    "38467523568",
    "remoteSoftware",
    "physicalHardware",
    "releaseCredential",
    "externalReview",
    "physicalAcceptanceComplete=false",
    "releaseCredentialAcceptanceComplete=false",
    "publicReleaseAuthorized=false",
    "mayMergeIntoMain=false",
):
    require(token in doc, f"PR114 contract missing {token!r}")

for token in (
    "PR114 — Commercial Release Candidate",
    "PR113B — World-Class Product Finish",
    "f10008d8330c2dc29f195163c56cf4723fc16a6c",
    "PR112 physical H01–H08 acceptance",
    "Apple signing",
    "App Store Connect",
):
    require(token in readme, f"README release status missing {token!r}")

for token in (
    "Current execution status — PR114",
    "f10008d8330c2dc29f195163c56cf4723fc16a6c",
    "Slice 1 — release baseline reconciliation",
    "Slice 6 — integrated RC gate",
):
    require(token in roadmap, f"roadmap PR114 status missing {token!r}")

# Slice 1 remains independently auditable even after later PR114 slices move
# HEAD forward. The pinned checkpoint itself must contain release-contract-only
# changes relative to the exact PR113B base.
try:
    subprocess.run(
        ["git", "merge-base", "--is-ancestor", BASE_SHA, SLICE1_CHECKPOINT_SHA],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    changed = subprocess.run(
        ["git", "diff", "--name-only", f"{BASE_SHA}..{SLICE1_CHECKPOINT_SHA}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
except subprocess.CalledProcessError as exc:
    fail(f"unable to audit pinned Slice 1 checkpoint: {exc}")

unexpected = sorted(set(changed) - ALLOWED_SLICE1_PATHS)
require(
    not unexpected,
    "Pinned Slice 1 checkpoint contains non-baseline changes: "
    + ", ".join(unexpected),
)

print("PR114 Slice 1 commercial release baseline: PASS")
