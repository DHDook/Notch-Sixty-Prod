#!/usr/bin/env python3
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "NotchSixty" / "NotchSixty.entitlements"
INFO = ROOT / "NotchSixty" / "Info.plist"
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
DOC = ROOT / "docs" / "PR102_APP_STORE_DISTRIBUTION_PREFLIGHT.md"

FORBIDDEN_PRODUCTION_TOKENS = (
    "/Library/Audio/Plug-Ins/HAL",
    "AuthorizationExecuteWithPrivileges",
    "SMJobBless",
    "kSMRightBlessPrivilegedHelper",
    "killall coreaudiod",
    "pkill coreaudiod",
    "sudo ",
)

SOURCE_SUFFIXES = {".swift", ".c", ".h", ".m", ".mm", ".cpp", ".hpp"}


def fail(message: str) -> None:
    print(f"PR102 App Store boundary validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (ENTITLEMENTS, INFO, PROJECT, DOC):
    require(path.is_file(), f"missing required file {path.relative_to(ROOT)}")

with ENTITLEMENTS.open("rb") as handle:
    entitlements = plistlib.load(handle)
with INFO.open("rb") as handle:
    info = plistlib.load(handle)

expected_entitlements = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-write": True,
}
require(
    entitlements == expected_entitlements,
    f"unexpected entitlement expansion/change: {entitlements!r}",
)

for key in ("NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"):
    value = info.get(key)
    require(isinstance(value, str) and value.strip(), f"missing privacy string {key}")

project = PROJECT.read_text(encoding="utf-8")
for token in (
    "ENABLE_HARDENED_RUNTIME = YES;",
    "ARCHS = arm64;",
    "CODE_SIGN_ENTITLEMENTS = NotchSixty/NotchSixty.entitlements;",
    "PRODUCT_BUNDLE_IDENTIFIER = com.dhdook.NotchSixty;",
):
    require(token in project, f"project lost App Store/release setting {token!r}")

# Credentials remain external to source control.
require("DEVELOPMENT_TEAM =" not in project, "production development team must not be hard-coded")
require("PROVISIONING_PROFILE_SPECIFIER =" not in project, "production provisioning profile must not be hard-coded")

violations: list[str] = []
source_root = ROOT / "NotchSixty"
for path in source_root.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    for token in FORBIDDEN_PRODUCTION_TOKENS:
        if token in text:
            violations.append(f"{path.relative_to(ROOT)}: {token}")

require(
    not violations,
    "forbidden privileged/driver architecture entered production source: "
    + "; ".join(violations),
)

doc = DOC.read_text(encoding="utf-8")
for token in (
    "CI Release build",
    "CI archive preflight",
    "Production distribution",
    "CODE_SIGNING_ALLOWED=NO",
    "releaseCredential",
    "App Store Connect",
    "TestFlight",
    "Developer-ID signing/notarization",
):
    require(token in doc, f"distribution preflight documentation missing {token!r}")

print("PR102 App Store boundary validation passed")
