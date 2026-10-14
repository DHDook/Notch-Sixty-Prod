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

require("private struct StereoSignatureVUPalette {" in root, "palette absent")
meter = root.split("private struct StereoSignatureVUPalette {", 1)[1].split(
    "private struct ProductionSpeakersView: View {", 1
)[0]
for token in (
    "init(darkAppearance: Bool)",
    r"@Environment(\.colorScheme)",
    "darkAppearance: colorScheme == .dark",
    "Color(red: 0.98, green: 0.955, blue: 0.88)",
    "Color(red: 0.20, green: 0.20, blue: 0.19)",
    "let needle = Color(red: 1.00, green: 0.36, blue: 0.045)",
    "context.stroke(path, with: .color(color), lineWidth: 2.55)",
    "radius: radius * 0.62",
    "radius: radius * 0.985",
    ".glassEffect(.regular, in: .rect(cornerRadius: 22))",
    "hotArc",
    ".accessibilityValue(",
):
    require(token in meter, "missing meter contract: " + token)
require("context.stroke(path, with: .color(.black.opacity(0.24))" not in meter, "old black needle outline remains")
require("0 VU = −18 dBFS" in root, "reference legend missing")
require("height * 1.14" in meter, "meter pivot changed")
require("ProductionVUScale.smoothed(" in root, "meter smoothing removed")
require("ProductionOutputVUMeterDemand.acquire()" in root, "meter demand removed")
require("espresso housing" in icons and "champagne housing" in icons, "PR116 colors missing")
for number in range(117, 127):
    require(f"PR{number} —" in roadmap, f"proposed PR{number} absent")
for token in ("Headphone Correction Experience", "Model-Based Headphone Correction",
              "Personalized Binaural Optimization", "H01–H08", "OPEN/DRAFT/UNMERGED"):
    require(token in roadmap, "roadmap boundary missing: " + token)
print("PR116B dashboard palette + forward roadmap source contracts PASS")
