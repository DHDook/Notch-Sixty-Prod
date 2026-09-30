#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
ROOT_VIEW = ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift"
LEGACY_VIEW = ROOT / "NotchSixty" / "ContentView.swift"
README = ROOT / "README.md"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-dmg.yml"
DOC = ROOT / "docs" / "PR45_V1_RELEASE_HARDENING.md"


def fail(message: str) -> None:
    print(f"PR45 release-hardening validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        fail(f"missing {label}: {token!r}")


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

# One-shot staging machinery must never survive in the candidate tree.
for path in [
    ROOT / ".github" / "workflows" / "pr45-apply-release-hardening.yml",
    ROOT / "ci" / "pr45_apply_release_hardening.py",
    ROOT / ".github" / "workflows" / "pr45-apply-launch-at-login-menu.yml",
    ROOT / "ci" / "pr45_add_launch_at_login_menu.py",
    ROOT / ".github" / "workflows" / "pr45-apply-login-placement.yml",
    ROOT / "ci" / "pr45_remove_login_toggle_from_tray.py",
]:
    if path.exists():
        fail(f"one-shot PR45 staging file remains: {path.relative_to(ROOT)}")

for token in [
    "Engineering UI is DEBUG-only",
    "Launch at Login",
    "Copy Diagnostics",
    "Remaining physical/manual acceptance",
    "PR40 → PR41 → PR42 → PR43 → PR44 → PR45",
]:
    require(doc, token, "PR45 closure documentation")

print("PR45 v1 release hardening validation passed")
