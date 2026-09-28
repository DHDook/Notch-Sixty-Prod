#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "NotchSixty/Assets.xcassets/AppIcon.appiconset/Contents.json").read_text())
images = manifest["images"]
assert len(images) == 20, f"expected 20 macOS app icon variants, found {len(images)}"
light = [image for image in images if "appearances" not in image]
dark = [image for image in images if image.get("appearances") == [{"appearance": "luminosity", "value": "dark"}]]
assert len(light) == 10 and len(dark) == 10
for image in images:
    path = root / "NotchSixty/Assets.xcassets/AppIcon.appiconset" / image["filename"]
    assert path.exists(), f"missing app icon: {path.name}"
    assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), f"invalid PNG: {path.name}"
for source in ("AppIcon-light.svg", "AppIcon-dark.svg"):
    path = root / "artwork" / source
    assert path.exists() and "<svg" in path.read_text()
ui = (root / "NotchSixty/UI/ProductionRootView.swift").read_text()
assert "import AppKit" in ui
assert "NSApplication.shared.applicationIconImage" in ui
assert "ProductionSidebarBrand()" in ui
assert ".listStyle(.sidebar)" in ui
assert ".tint(Color(red: 0.91, green: 0.58, blue: 0.24))" in ui
assert ui.count(".glassEffect(.regular, in: .rect(cornerRadius: 18))") >= 4
assert 'Text("Notch Sixty")' in ui and ".textCase(.uppercase)" in ui
assert "Color(red: 0.94, green: 0.89, blue: 0.73)" in ui, "signature VU face must remain warm and opaque"
profiles = (root / "NotchSixty/UI/ProductionProfileToolbar.swift").read_text()
assert profiles.count(".buttonStyle(.glass)") >= 3
print("PR39 app identity / Liquid Glass validation passed")
