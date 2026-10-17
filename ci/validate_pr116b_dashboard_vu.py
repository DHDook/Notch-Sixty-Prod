#!/usr/bin/env python3
"""PR116B VU visual and proposed-roadmap source checks; no physical claims."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
root = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text(encoding="utf-8")
roadmap = (ROOT / "docs/ROADMAP.md").read_text(encoding="utf-8")
icons = (ROOT / "design/app-icons/README.md").read_text(encoding="utf-8")

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit("PR116B validation failed: " + message)

require("struct StereoSignatureVUPalette {" in root, "palette absent")
meter = root.split("struct StereoSignatureVUPalette {", 1)[1].split(
    "private struct ProductionSpeakersView: View {", 1
)[0]
# RC revision: the meter follows the approved icons (DockIconDark: espresso
# body / cream face; DockIconLight: ivory body / black face) with per-channel
# gold-bezel glass windows and the needle pivot hidden by the window clip.
for token in (
    "init(darkAppearance: Bool)",
    r"@Environment(\.colorScheme)",
    "darkAppearance: colorScheme == .dark",
    "Color(red: 0.99, green: 0.97, blue: 0.91)",
    "Color(red: 0.16, green: 0.155, blue: 0.15)",
    "let needle = Color(red: 1.00, green: 0.40, blue: 0.06)",
    "struct StereoSignatureVUWindow",
    "center.y - radius * 0.45",
    ".clipShape(windowShape.path(in: rect))",
    "bezelGold",
    "glassGlare",
    "radius: radius * 0.985",
    "hotArc",
    ".accessibilityValue(",
):
    require(token in meter, "missing meter contract: " + token)
require("context.stroke(path, with: .color(.black.opacity(0.24))" not in meter, "old black needle outline remains")
require("0 VU = −18 dBFS" in root, "reference legend missing")
require("ProductionVUScale.smoothed(" in root, "meter smoothing removed")
require("ProductionOutputVUMeterDemand.acquire()" in root, "meter demand removed")
require("espresso housing" in icons and "champagne housing" in icons, "PR116 colors missing")
for number in range(117, 127):
    require(f"PR{number} —" in roadmap, f"proposed PR{number} absent")
for token in ("Headphone Correction Experience", "Model-Based Headphone Correction",
              "Personalized Binaural Optimization", "H01–H08", "OPEN/DRAFT/UNMERGED"):
    require(token in roadmap, "roadmap boundary missing: " + token)
print("PR116B dashboard palette + forward roadmap source contracts PASS")
