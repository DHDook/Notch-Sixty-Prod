#!/usr/bin/env python3
"""PR114 Slice 2 App Store privacy/security contract."""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

SOURCE_ROOT = ROOT / "NotchSixty"
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
INFO = ROOT / "NotchSixty" / "Info.plist"
ENTITLEMENTS = ROOT / "NotchSixty" / "NotchSixty.entitlements"
BASELINE = ROOT / "release" / "pr114-release-baseline.json"
DEPENDENCIES = ROOT / "release" / "production-dependencies.json"
DOC = ROOT / "docs" / "archive" / "PR114_APP_STORE_PRIVACY_SECURITY.md"
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
GUIDE = ROOT / "NotchSixty" / "UI" / "ProductionUserGuideView.swift"

SOURCE_SUFFIXES = {".swift", ".c", ".h", ".m", ".mm", ".cpp", ".hpp"}

FORBIDDEN_PRIVILEGED = (
    "/Library/Audio/Plug-Ins/HAL",
    "AuthorizationExecuteWithPrivileges",
    "SMJobBless",
    "kSMRightBlessPrivilegedHelper",
    "killall coreaudiod",
    "pkill coreaudiod",
    "sudo ",
)

# These tokens represent app-owned networking, tracking/advertising, automatic
# analytics/crash upload, or self-update frameworks. If one is deliberately
# introduced later, this validator must fail until the privacy/security
# contract and release baseline are explicitly reconciled.
FORBIDDEN_APP_OWNED_PRIVACY_TOKENS = (
    "URLSession",
    "NSURLSession",
    "import Network",
    "NWConnection",
    "NWPathMonitor",
    "NWTCPConnection",
    "import AdSupport",
    "ASIdentifierManager",
    "import AppTrackingTransparency",
    "ATTrackingManager",
    "SentrySDK",
    "FirebaseApp",
    "FirebaseAnalytics",
    "Crashlytics",
    "Mixpanel",
    "import Amplitude",
    "AmplitudeSwift",
    "Amplitude.Analytics",
    "TelemetryDeck",
    "PostHog",
    "Datadog",
    "MSACAppCenter",
    "AppCenter",
    "SEGAnalytics",
    "Sparkle",
    "SUUpdater",
    "SPUUpdater",
)


def fail(message: str) -> None:
    print(f"PR114 Slice 2 validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (
    SOURCE_ROOT,
    PROJECT,
    INFO,
    ENTITLEMENTS,
    BASELINE,
    DEPENDENCIES,
    DOC,
    APP,
    GUIDE,
):
    require(path.exists(), f"missing privacy/security artifact: {path.relative_to(ROOT)}")

with INFO.open("rb") as handle:
    info = plistlib.load(handle)
with ENTITLEMENTS.open("rb") as handle:
    entitlements = plistlib.load(handle)

baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
dependencies = json.loads(DEPENDENCIES.read_text(encoding="utf-8"))
project = PROJECT.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
guide = GUIDE.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")

expected_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
}
require(
    entitlements == expected_entitlements,
    f"unexpected entitlement expansion/change: {entitlements!r}",
)
for forbidden_entitlement in (
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.personal-information.location",
    "com.apple.security.personal-information.addressbook",
    "com.apple.security.personal-information.calendars",
    "com.apple.security.device.camera",
    "com.apple.security.device.bluetooth",
    "com.apple.security.automation.apple-events",
):
    require(
        forbidden_entitlement not in entitlements,
        f"unexpected privacy-sensitive entitlement: {forbidden_entitlement}",
    )

expected_audio_purpose = (
    "Notch Sixty captures system audio so it can process and play it through "
    "your selected output device."
)
expected_mic_purpose = (
    "Notch Sixty uses your selected measurement microphone only when you "
    "start a measurement or calibration workflow, so it can measure your "
    "speakers, room, or ambient acoustic field."
)
require(
    info.get("NSAudioCaptureUsageDescription") == expected_audio_purpose,
    "system-audio purpose string drifted",
)
require(
    info.get("NSMicrophoneUsageDescription") == expected_mic_purpose,
    "microphone purpose string does not match finished measurement surface",
)

for token in (
    'Text("Requested only when you start a microphone-based measurement or calibration workflow.")',
    'Text("Measurement Microphone")',
    "does not include captured audio or room-measurement samples",
):
    require(token in app, f"in-app privacy/support copy missing {token!r}")

for token in (
    "Measurement Microphone access is separate and is not required for ordinary listening.",
    "Request it only when you choose to measure or calibrate.",
    "Speaker Calibration, Measurement Lab and Room Correction are optional next steps",
):
    require(token in guide, f"Getting Started privacy guidance missing {token!r}")

# App Store / signing credentials must remain external to the source tree.
require("DEVELOPMENT_TEAM =" not in project, "Apple development team must remain external")
require(
    "PROVISIONING_PROFILE_SPECIFIER =" not in project,
    "provisioning profile must remain external",
)

# Scan the actual PR114 checkout rather than GitHub's default-branch code search.
violations: list[str] = []
for path in SOURCE_ROOT.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    for token in FORBIDDEN_PRIVILEGED + FORBIDDEN_APP_OWNED_PRIVACY_TOKENS:
        if token in text:
            violations.append(f"{path.relative_to(ROOT)}: {token}")
require(
    not violations,
    "unreconciled privileged/network/tracking/analytics/self-update code: "
    + "; ".join(violations),
)

for token in (
    "Network.framework",
    "AdSupport.framework",
    "AppTrackingTransparency.framework",
    "Sparkle.framework",
):
    require(token not in project, f"unreconciled production framework: {token}")

privacy_manifests = sorted(ROOT.rglob("PrivacyInfo.xcprivacy"))
require(
    not privacy_manifests,
    "PrivacyInfo.xcprivacy appeared without reconciling the PR114 privacy-manifest decision: "
    + ", ".join(str(p.relative_to(ROOT)) for p in privacy_manifests),
)

privacy = baseline.get("privacySecurity", {})
expected_false = (
    "tracking",
    "bundledAnalyticsSDK",
    "bundledNetworkClient",
    "appOwnedAutomaticTelemetryUpload",
    "diagnosticsUpload",
    "capturedAudioUpload",
    "measurementDataUpload",
    "privacyManifestPresent",
    "privacyManifestRequiredForCurrentMacTarget",
    "userInstalledAudioUnitsAreBundledDependencies",
    "appStorePrivacyPolicyURLConfigured",
    "appStorePrivacyResponsesComplete",
)
for key in expected_false:
    require(privacy.get(key) is False, f"privacy baseline must keep {key}=false")

components = dependencies.get("thirdPartyComponents", [])
require(len(components) == 1, "unexpected production dependency count")
component = components[0]
require(
    component.get("id") == "libmysofa"
    and component.get("version") == "1.3.4"
    and component.get("realtimeRenderPath") is False,
    "libmysofa production classification drifted",
)
require(
    dependencies.get("policy", {}).get("unclassifiedProductionDependencyAllowed") is False,
    "unclassified production dependency policy must fail closed",
)

for token in (
    "macOS-only",
    "privacyManifestPresent=false",
    "privacyManifestRequiredForCurrentMacTarget=false",
    "appStorePrivacyPolicyURLConfigured=false",
    "appStorePrivacyResponsesComplete=false",
    "user-installed Audio Units",
    "does not silently upload captured audio",
    "no App Store self-updater",
):
    require(token in doc, f"privacy/security documentation missing {token!r}")

print("PR114 Slice 2 App Store privacy/security contract: PASS")
