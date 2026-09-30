#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
ROOT_VIEW = ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift"
LEGACY_VIEW = ROOT / "NotchSixty" / "ContentView.swift"
README = ROOT / "README.md"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-dmg.yml"
DOC = ROOT / "docs" / "PR45_V1_RELEASE_HARDENING.md"
APP_ICON_CATALOG = ROOT / "NotchSixty" / "Assets.xcassets" / "AppIcon.appiconset"
LIGHT_MASTER = ROOT / "artwork" / "AppIcon-light-master.png"
DARK_MASTER = ROOT / "artwork" / "AppIcon-dark-master.png"
LIGHT_FINAL = ROOT / "artwork" / "AppIcon-light-final.png"
DARK_FINAL = ROOT / "artwork" / "AppIcon-dark-final.png"
TRAY_ICON = ROOT / "NotchSixty" / "Assets.xcassets" / "TrayIcon.imageset" / "notch_sixty_tray_icon_final_tightcrop.svg"


def fail(message: str) -> None:
    print(f"PR45 release-hardening validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        fail(f"missing {label}: {token!r}")


def git_blob_sha(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        fail(f"not a valid PNG with IHDR: {path.relative_to(ROOT)}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


for path in [APP, ROOT_VIEW, LEGACY_VIEW, README, RELEASE_WORKFLOW, DOC]:
    if not path.exists():
        fail(f"missing required file {path.relative_to(ROOT)}")

app = APP.read_text(encoding="utf-8")
root_view = ROOT_VIEW.read_text(encoding="utf-8")
legacy = LEGACY_VIEW.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")
release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")

# Engineering validation must be absent from Release compilation while remaining
# available to developers in DEBUG builds.
if not legacy.lstrip().startswith("#if DEBUG"):
    fail("ContentView.swift is not DEBUG-only")
if not legacy.rstrip().endswith("#endif"):
    fail("ContentView.swift lost its closing DEBUG gate")
require(app, "#if DEBUG\nprivate struct PR27ProtectionValidationView", "DEBUG engineering view gate")
require(app, '#if DEBUG\n        Window("Engineering Validation", id: "engineering-validation")', "DEBUG engineering scene gate")
require(root_view, '#if DEBUG\n    @Environment(\\.openWindow)', "DEBUG openWindow gate")
require(root_view, '#if DEBUG\n            Button {\n                openWindow(id: "engineering-validation")', "DEBUG engineering toolbar gate")

# Launch at Login must use the public Apple API, live in the same Settings/app
# preferences UI as Appearance and App Presence, and remain an explicit
# registration action rather than an audio-processing startup side effect.
for token in [
    "import ServiceManagement",
    "SMAppService.mainApp.status",
    "SMAppService.mainApp.register()",
    "SMAppService.mainApp.unregister()",
    'Section("Appearance")',
    'Section("App Presence")',
    'Section("Startup")',
    '"Launch at Login"',
    'get: { preferences.launchAtLoginEnabled }',
    'set: { preferences.setLaunchAtLogin($0) }',
    "does not automatically start audio processing",
    "ProductionMenuBarView(product: product)",
]:
    require(app, token, "Launch at Login contract")

if app.count('"Launch at Login"') != 1:
    fail(f"expected exactly one Launch at Login control in Settings, found {app.count(chr(34) + 'Launch at Login' + chr(34))}")

menu_start = app.index("private struct ProductionMenuBarView")
settings_start = app.index("private struct ProductionSettingsView", menu_start)
menu_block = app[menu_start:settings_start]
if "Launch at Login" in menu_block or "launchAtLogin" in menu_block:
    fail("Launch at Login leaked into the tray/menu-bar dropdown instead of remaining in app Settings")

settings_block = app[settings_start:app.index("@main", settings_start)]
for token in ['Section("Appearance")', 'Section("App Presence")', 'Section("Startup")', '"Launch at Login"']:
    require(settings_block, token, "Settings placement contract")

# Support/privacy affordances.
for token in [
    'Section("Permissions")',
    "Screen & System Audio Recording",
    'Section("Support")',
    'Label("Copy Diagnostics", systemImage: "doc.on.doc")',
    '"Content Preset: \\(product.profiles.selectedContentPresetName)"',
    '"Playback System: \\(product.profiles.selectedSystemProfileName)"',
    '"DSP Latency: \\(latency)"',
    "does not include captured audio or room-measurement samples",
]:
    require(app, token, "permissions/diagnostics contract")

# Final v1 app icon contract. The owner-uploaded PNG masters are pinned by Git
# blob identity; the shipping catalog must contain all 10 light + 10 dark slots
# at their exact macOS pixel dimensions. The owner-controlled legacy tray glyph
# is deliberately unchanged.
for path in [LIGHT_MASTER, DARK_MASTER, LIGHT_FINAL, DARK_FINAL, TRAY_ICON, APP_ICON_CATALOG / "Contents.json"]:
    if not path.exists():
        fail(f"missing final icon asset {path.relative_to(ROOT)}")

if git_blob_sha(LIGHT_MASTER) != "d418e699b2c417c81d79e97ca0e4ae6ba84b2fe7":
    fail("approved light app-icon master changed")
if git_blob_sha(DARK_MASTER) != "141cfc228e7fd71623e149cd9bdc9756b18e34a1":
    fail("approved dark app-icon master changed")
if git_blob_sha(TRAY_ICON) != "759c6f2700c1250b8c697ca0eb480e1a2f11c577":
    fail("legacy tray icon changed")

if png_dimensions(LIGHT_MASTER) != (1254, 1254) or png_dimensions(DARK_MASTER) != (1254, 1254):
    fail("approved app-icon masters must remain 1254×1254")
if png_dimensions(LIGHT_FINAL) != (1024, 1024) or png_dimensions(DARK_FINAL) != (1024, 1024):
    fail("final app-icon previews must remain 1024×1024")

expected_slots = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
    "icon_dark_16x16.png": 16,
    "icon_dark_16x16@2x.png": 32,
    "icon_dark_32x32.png": 32,
    "icon_dark_32x32@2x.png": 64,
    "icon_dark_128x128.png": 128,
    "icon_dark_128x128@2x.png": 256,
    "icon_dark_256x256.png": 256,
    "icon_dark_256x256@2x.png": 512,
    "icon_dark_512x512.png": 512,
    "icon_dark_512x512@2x.png": 1024,
}
icon_manifest = json.loads((APP_ICON_CATALOG / "Contents.json").read_text(encoding="utf-8"))
manifest_files = [entry.get("filename") for entry in icon_manifest["images"] if entry.get("filename")]
if set(manifest_files) != set(expected_slots):
    fail("AppIcon catalog does not contain exactly the expected 20 light/dark slots")
if sum(1 for entry in icon_manifest["images"] if not entry.get("appearances")) != 10:
    fail("AppIcon catalog must contain exactly 10 default/light slots")
if sum(1 for entry in icon_manifest["images"] if entry.get("appearances")) != 10:
    fail("AppIcon catalog must contain exactly 10 dark-appearance slots")
for filename, pixels in expected_slots.items():
    path = APP_ICON_CATALOG / filename
    if not path.exists() or png_dimensions(path) != (pixels, pixels):
        fail(f"incorrect generated AppIcon slot: {filename}")

# Release workflow must remain manually triggerable, arm64, version-aware, and
# checksum its DMG. Signing/notarization is intentionally not fabricated here.
for token in [
    "workflow_dispatch:",
    "expected_version:",
    "Build Release app",
    "-destination 'platform=macOS,arch=arm64'",
    "shasum -a 256",
    "Upload Release DMG",
    "not Developer-ID signed or notarized",
]:
    require(release, token, "manual release-DMG workflow")

# Public product scope/status must not regress to the old bootstrap wording.
require(readme, "v1.0 release-candidate hardening", "README release status")
require(readme, "speaker-integration routing may fan out to 2–8 physical outputs", "README speaker-output boundary")
if "**Commercial bootstrap / architecture foundation.**" in readme:
    fail("README reverted to obsolete bootstrap status")

# One-shot staging machinery and superseded app-icon sources must never survive
# in the candidate tree.
for path in [
    ROOT / ".github" / "workflows" / "pr45-apply-release-hardening.yml",
    ROOT / "ci" / "pr45_apply_release_hardening.py",
    ROOT / ".github" / "workflows" / "pr45-apply-launch-at-login-menu.yml",
    ROOT / "ci" / "pr45_add_launch_at_login_menu.py",
    ROOT / ".github" / "workflows" / "pr45-apply-login-placement.yml",
    ROOT / "ci" / "pr45_remove_login_toggle_from_tray.py",
    ROOT / ".github" / "workflows" / "pr45-apply-final-app-icons.yml",
    ROOT / ".github" / "workflows" / "pr45-export-current-icons.yml",
    ROOT / "icon_payload" / "pr45-light-final.webp",
    ROOT / "icon_payload" / "pr45-dark-final.webp",
    ROOT / "artwork" / "AppIcon-light-master.webp",
    ROOT / "artwork" / "AppIcon-dark-master.webp",
    ROOT / "artwork" / "AppIcon-light.svg",
    ROOT / "artwork" / "AppIcon-dark.svg",
]:
    if path.exists():
        fail(f"one-shot/superseded PR45 file remains: {path.relative_to(ROOT)}")

for token in [
    "Engineering UI is DEBUG-only",
    "Launch at Login",
    "Copy Diagnostics",
    "Final application icons",
    "Remaining physical/manual acceptance",
    "PR40 → PR41 → PR42 → PR43 → PR44 → PR45",
]:
    require(doc, token, "PR45 closure documentation")

print("PR45 v1 release hardening validation passed")
