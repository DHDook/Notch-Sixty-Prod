#!/usr/bin/env python3
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
INFO = ROOT / "NotchSixty" / "Info.plist"
ENTITLEMENTS = ROOT / "NotchSixty" / "NotchSixty.entitlements"
SHIPPED_NOTICE = ROOT / "NotchSixty" / "ThirdPartyNotices.txt"
ROOT_NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
PROVENANCE = ROOT / "docs" / "PROVENANCE.md"
VENDOR_LICENSE = ROOT / "NotchSixty" / "Audio" / "SOFA" / "Vendor" / "libmysofa" / "LICENSE"
VENDOR_README = ROOT / "NotchSixty" / "Audio" / "SOFA" / "Vendor" / "libmysofa" / "README_NOTCH_SIXTY.md"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-dmg.yml"
APP_STORE = ROOT / "docs" / "APP_STORE_REQUIREMENTS.md"
PR102_DOC = ROOT / "docs" / "PR102_INTEGRATION_COMMERCIAL_RELEASE.md"
README = ROOT / "README.md"
ROADMAP = ROOT / "docs" / "ROADMAP.md"
HANDOFF = ROOT / "docs" / "PR102_RELEASE_HANDOFF.md"
SOFTWARE_CLOSURE = ROOT / "docs" / "PR102_SOFTWARE_CLOSURE.md"
PR102_WORKFLOW = ROOT / ".github" / "workflows" / "pr102-integration-commercial-release.yml"
MANIFEST_BUILDER = ROOT / "ci" / "build_pr102_release_candidate_manifest.py"
LICENSE = ROOT / "LICENSE"


def fail(message: str) -> None:
    print(f"PR102 release-readiness validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (
    PROJECT,
    INFO,
    ENTITLEMENTS,
    SHIPPED_NOTICE,
    ROOT_NOTICES,
    PROVENANCE,
    VENDOR_LICENSE,
    VENDOR_README,
    RELEASE_WORKFLOW,
    APP_STORE,
    PR102_DOC,
    README,
    ROADMAP,
    HANDOFF,
    SOFTWARE_CLOSURE,
    PR102_WORKFLOW,
    MANIFEST_BUILDER,
    LICENSE,
):
    require(path.is_file(), f"missing required release artifact: {path.relative_to(ROOT)}")

project = PROJECT.read_text(encoding="utf-8")
root_notices = ROOT_NOTICES.read_text(encoding="utf-8")
shipped_notice = SHIPPED_NOTICE.read_text(encoding="utf-8")
provenance = PROVENANCE.read_text(encoding="utf-8")
vendor_license = VENDOR_LICENSE.read_text(encoding="utf-8")
vendor_readme = VENDOR_README.read_text(encoding="utf-8")
release_workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
app_store = APP_STORE.read_text(encoding="utf-8")
pr102_doc = PR102_DOC.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
handoff = HANDOFF.read_text(encoding="utf-8")
software_closure = SOFTWARE_CLOSURE.read_text(encoding="utf-8")
pr102_workflow = PR102_WORKFLOW.read_text(encoding="utf-8")
manifest_builder = MANIFEST_BUILDER.read_text(encoding="utf-8")
license_text = LICENSE.read_text(encoding="utf-8")

with INFO.open("rb") as handle:
    info = plistlib.load(handle)
with ENTITLEMENTS.open("rb") as handle:
    entitlements = plistlib.load(handle)

# Sandbox and permission contract.
expected_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
}
require(
    entitlements == expected_entitlements,
    f"shipping entitlement set changed: {entitlements!r}",
)
for key in ("NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"):
    value = info.get(key)
    require(isinstance(value, str) and value.strip(), f"missing/non-empty Info.plist key {key}")

# Shipping build settings remain explicit, arm64, sandboxed, and credential-neutral.
for token in (
    "ARCHS = arm64;",
    "SDKROOT = macosx;",
    "ENABLE_HARDENED_RUNTIME = YES;",
    "CODE_SIGN_ENTITLEMENTS = NotchSixty/NotchSixty.entitlements;",
    "PRODUCT_BUNDLE_IDENTIFIER = com.dhdook.NotchSixty;",
):
    require(token in project, f"project missing shipping setting {token!r}")
require("DEVELOPMENT_TEAM =" not in project, "repository must not hard-code a production Apple development team")

def setting_values(name: str) -> list[str]:
    return re.findall(rf"\b{name} = ([^;]+);", project)

for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "MACOSX_DEPLOYMENT_TARGET"):
    values = setting_values(name)
    require(values, f"project missing {name}")
    require(len(set(values)) == 1, f"{name} differs across project configurations: {values}")
    require(all(value.strip() for value in values), f"{name} contains an empty value")

require(
    re.fullmatch(r"\d+(?:\.\d+){1,2}", setting_values("MARKETING_VERSION")[0]) is not None,
    "MARKETING_VERSION is not a release-style numeric version",
)
require(
    re.fullmatch(r"\d+", setting_values("CURRENT_PROJECT_VERSION")[0]) is not None,
    "CURRENT_PROJECT_VERSION is not an integer build number",
)

# libmysofa v1.3.4 is a real compiled production dependency and its BSD notice
# must accompany binary redistribution.
for token in (
    "libmysofa v1.3.4",
    "BSD 3-Clause",
    "NotchSixty/ThirdPartyNotices.txt",
):
    require(token in root_notices, f"root notices missing libmysofa contract {token!r}")

for token in (
    "libmysofa v1.3.4",
    "BSD 3-Clause",
    "Copyright (c) 2016-2017, Symonics GmbH, Christian Hoene",
    "Redistributions in binary form must reproduce",
):
    # Upstream spelling says "Redistribution" singular; accept exact legal
    # sentence via the shorter stable phrase below instead of normalizing it.
    if token == "Redistributions in binary form must reproduce":
        continue
    require(token in shipped_notice, f"shipped notice missing {token!r}")
require(
    "Redistributions in binary form" in shipped_notice
    or "Redistribution in binary form" in shipped_notice,
    "shipped notice lost the binary-redistribution condition",
)
for token in (
    "Copyright (c) 2016-2017, Symonics GmbH, Christian Hoene",
    "Redistribution and use in source and binary forms",
    "THIS SOFTWARE IS PROVIDED BY THE AUTHOR",
):
    require(token in vendor_license, f"vendored libmysofa license missing {token!r}")
for token in ("libmysofa v1.3.4", "BSD 3-Clause"):
    require(token in vendor_readme, f"vendor provenance README missing {token!r}")

for token in (
    "F10200000000000000000001 /* ThirdPartyNotices.txt in Resources */",
    "F10200000000000000000011 /* ThirdPartyNotices.txt */",
    "F85000000000000000000003 /* libmysofa reader.c in Sources */",
    "F8500000000000000000000B /* libmysofa gcol.c in Sources */",
):
    require(token in project, f"project integration missing {token!r}")

for token in (
    "PR102 libmysofa reconciliation",
    "libmysofa v1.3.4",
    "BSD 3-Clause",
    "Binary redistribution notice",
):
    require(token in provenance, f"provenance missing {token!r}")

# Existing distribution lane must remain truthful about its current authority.
for token in (
    "workflow_dispatch:",
    "Build Release app",
    "Ad-hoc sign Release app",
    "Validate Release app metadata",
    "Create versioned Release DMG",
    "shasum -a 256",
    "not Developer-ID signed or notarized",
):
    require(token in release_workflow, f"Release-DMG workflow missing {token!r}")

for token in (
    "App Sandbox enabled",
    "no privileged installer",
    "no root operations",
    "no self-updater in the App Store build",
):
    require(token in app_store, f"App Store requirements missing {token!r}")

for token in (
    "remoteSoftware",
    "physicalHardware",
    "releaseCredential",
    "externalReview",
    "PR103 — Optimizer Measurement Foundation",
    "PR106 — Advanced Speaker Measurement Lab",
):
    require(token in pr102_doc, f"PR102 plan missing {token!r}")

for token in (
    "PR102 integration and commercial-release preparation",
    "semantic N-channel",
    "headphone profiles",
    "Audio Unit hosting",
    "speaker-connected feed-forward ANC remains hardware-gated",
    "App Sandbox",
):
    require(token in readme, f"README product boundary missing {token!r}")
for stale in (
    "two-channel loudspeaker playback",
    "headphone-only features are out of scope",
    "stereo program material only",
):
    require(stale not in readme, f"README retained stale product-boundary text {stale!r}")

for token in (
    "Current execution status — PR102",
    "PR103 — Speaker Optimizer Measurement Foundation",
    "PR104 — Measurement-Driven Speaker Optimization Engine",
    "PR105 — Guided Speaker Optimizer & Acoustic Verification",
    "PR106 — Advanced Speaker Measurement Lab",
    "Historical stage — PR #22",
):
    require(token in roadmap, f"roadmap reconciliation missing {token!r}")

for token in (
    "Physical Mac / audio-hardware acceptance",
    "Production Apple release credentials",
    "Legal/IP release review",
    "Public-release authorization rule",
    "remoteReleasePreparationAccepted = true",
):
    require(token in handoff, f"release handoff missing {token!r}")

for token in (
    "PENDING EXACT-HEAD CI",
    "PR102_REMOTE_RELEASE_CANDIDATE",
    "remoteReleasePreparationAccepted = true",
    "physicalAcceptanceComplete = false",
    "releaseCredentialAcceptanceComplete = false",
    "publicReleaseAuthorized = false",
    "liveFeedForwardANCOutputAuthorized = false",
    "speakerConnectedFeedForwardOutput = false",
):
    require(token in software_closure, f"software closure contract missing {token!r}")

for token in (
    "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
    "PR102_EXPECTED_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}",
):
    require(token in pr102_workflow, f"PR102 workflow lost exact-source identity contract {token!r}")
for token in (
    'source_commit_sha = subprocess.run(',
    '["git", "rev-parse", "HEAD"]',
    'source_commit_sha == expected_head_sha',
    '"githubSHA": source_commit_sha',
    '"githubWorkflowTriggerSHA": workflow_trigger_sha',
):
    require(token in manifest_builder, f"release-candidate manifest lost source identity check {token!r}")

require("proprietary and confidential" in license_text, "root proprietary license contract changed")

print("PR102 release-readiness validation passed")
