#!/usr/bin/env python3
from pathlib import Path

root = Path("NotchSixty/UI/ProductionRootView.swift").read_text()
eq = Path("NotchSixty/UI/ProductionEqualizerView.swift").read_text()
pbx = Path("NotchSixty.xcodeproj/project.pbxproj").read_text()
workflow = Path(".github/workflows/macos.yml").read_text()

required_root = [
    "ProductionEqualizerView(engine: engine)",
]
required_eq = [
    "struct ProductionEqualizerView: View",
    "ProductionEQResponseGraph",
    "EQChannelMode.allCases",
    "EQPhaseMode.allCases",
    "engine.addEQBand",
    "engine.updateEQBand",
    "engine.removeEQBand",
    "Dynamic EQ",
    "DragGesture(minimumDistance: 0)",
    "scheduleCoalescedPublish",
    "33_000_000",
    "StereoEQConfiguration.bandGainRange",
    "DynamicEQBandConfiguration.qRange",
    "band.compiledSections(sampleRate: sampleRate)",
    "Per-band FIR processing remains active",
]

missing = [token for token in required_root if token not in root]
missing += [token for token in required_eq if token not in eq]
if missing:
    raise SystemExit("PR37 production EQ guard failed; missing: " + ", ".join(missing))

if "The production graphical EQ editor follows on this UI foundation." in root:
    raise SystemExit("PR37 production EQ guard failed: Equalizer still routes to the placeholder")

if "ProductionEqualizerView.swift" not in pbx:
    raise SystemExit("PR37 production EQ guard failed: production EQ source is not in the Xcode project")

if "Validate PR37 Production Equalizer" not in workflow:
    raise SystemExit("PR37 production EQ guard failed: macOS CI does not retain the PR37 validator")

print("PR37 production Equalizer guard passed")
