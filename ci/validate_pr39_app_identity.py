#!/usr/bin/env python3
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
APPICON = ROOT / "NotchSixty" / "Assets.xcassets" / "AppIcon.appiconset"
CONTENTS = APPICON / "Contents.json"
GENERATOR = ROOT / "ci" / "generate_app_icons.swift"
STATUS = ROOT / "docs" / "PR39_APP_IDENTITY_STATUS.md"


def fail(message: str) -> None:
    print(f"PR39 identity validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


if not CONTENTS.exists():
    fail("missing AppIcon Contents.json")

payload = json.loads(CONTENTS.read_text(encoding="utf-8"))
images = payload.get("images", [])
if len(images) != 20:
    fail(f"expected 20 macOS light/dark icon slots, found {len(images)}")

filenames = []
dark_count = 0
for item in images:
    name = item.get("filename")
    if not name:
        fail("app icon slot without filename")
    filenames.append(name)
    if item.get("appearances") == [{"appearance": "luminosity", "value": "dark"}]:
        dark_count += 1
    if not (APPICON / name).exists():
        fail(f"missing committed app icon raster: {name}")

if dark_count != 10:
    fail(f"expected 10 luminosity-dark icon slots, found {dark_count}")
if len(set(filenames)) != 20:
    fail("duplicate app-icon filenames in Contents.json")

for master in ["AppIcon-light-final.png", "AppIcon-dark-final.png"]:
    if not (ROOT / "artwork" / master).exists():
        fail(f"missing approved final artwork: {master}")

source = GENERATOR.read_text(encoding="utf-8")
for forbidden in ["bodyX", "bodyYFromBottom", "addClip()", "sourceCanvas"]:
    if forbidden in source:
        fail(f"icon generator still contains historical crop/mask token: {forbidden}")
for required in ["does not redraw, mask, crop, or reinterpret", "source.draw("]:
    if required not in source:
        fail(f"icon generator lost raster-preserving contract: {required}")

status = STATUS.read_text(encoding="utf-8")
if "does not crop, mask, redraw, or reinterpret" not in status:
    fail("identity status does not document the raster-preserving icon contract")

print("PR39 app identity / raster-preserving icon validation passed")
