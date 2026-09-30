#!/usr/bin/env python3
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
TRAY = ROOT / "NotchSixty" / "Assets.xcassets" / "TrayIcon.imageset"
MATRIX = ROOT / "docs" / "PR42_FINAL_PARITY_MATRIX.md"
PROVENANCE = ROOT / "docs" / "PROVENANCE.md"

def fail(message: str) -> None:
    print(f"PR42 app-shell validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

source = APP.read_text(encoding="utf-8")
required = [
    "MenuBarExtra(",
    'image: "TrayIcon"',
    "isInserted: trayInserted",
    "ProductionMenuBarView",
    "profiles.selectContentPreset(id)",
    "try engine.start()",
    "engine.stop()",
    "Settings {",
    "ProductionSettingsView",
    'CFBundleShortVersionString',
    'CFBundleVersion',
    "ApplicationAppearanceMode",
    "case system",
    "case light",
    "case dark",
    "ApplicationPresenceMode",
    "case dock",
    "case tray",
    "case both",
    "setActivationPolicy",
    ".accessory",
    ".regular",
]
for token in required:
    if token not in source:
        fail(f"missing app-shell contract token: {token}")

contents_path = TRAY / "Contents.json"
svg_path = TRAY / "notch_sixty_tray_icon_final_tightcrop.svg"
if not contents_path.exists() or not svg_path.exists():
    fail("owner-controlled TrayIcon asset is missing")
payload = json.loads(contents_path.read_text(encoding="utf-8"))
props = payload.get("properties", {})
if props.get("template-rendering") is not True:
    fail("TrayIcon must remain a template-rendered menu-bar asset")
if props.get("preserves-vector-representation") is not True:
    fail("TrayIcon must preserve vector representation")

matrix = MATRIX.read_text(encoding="utf-8")
if "Menu bar preset / processing / quit controls" not in matrix:
    fail("final parity matrix does not record menu-bar behavior")
if "Legacy owner-controlled tray icon artwork" not in matrix:
    fail("final parity matrix does not record tray icon provenance")

provenance = PROVENANCE.read_text(encoding="utf-8")
if "TrayIcon" not in provenance or "owner-controlled" not in provenance:
    fail("provenance ledger does not record the tray artwork")

print("PR42 menu-bar / settings app-shell guard: PASS")
