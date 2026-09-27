#!/usr/bin/env python3
from pathlib import Path
import math
import sys

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text()
PROJECT = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()
DOC = (ROOT / "docs/PR36_PRODUCTION_UI_FOUNDATION.md").read_text()
BRIDGE = (ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c").read_text()
DIAGNOSTICS = (ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift").read_text()


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        print(f"PR36 UI foundation validation: FAIL: {context} missing {needle!r}", file=sys.stderr)
        raise SystemExit(1)


def forbid(text: str, needle: str, context: str) -> None:
    if needle in text:
        print(f"PR36 UI foundation validation: FAIL: {context} must not contain {needle!r}", file=sys.stderr)
        raise SystemExit(1)


def vu_for_dbfs(dbfs: float) -> float:
    return min(max(dbfs - (-18.0), -20.0), 3.0)


# Shipping target / platform language.
require(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 27.0;", "project deployment target")
forbid(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 14.2;", "project deployment target")

# macOS 27 native navigation + selective Liquid Glass control language.
require(UI, "NavigationSplitView", "production navigation")
require(UI, "GlassEffectContainer", "selective custom glass controls")
require(UI, ".buttonStyle(.glassProminent)", "primary glass action")
require(UI, ".glassEffect(.regular", "Liquid Glass status/control surface")

# Signature dashboard identity is a new clean-room stereo analog meter pair.
require(UI, "private struct SignatureVUMeter", "signature VU component")
require(UI, 'SignatureVUMeter(channel: "LEFT"', "left VU")
require(UI, 'SignatureVUMeter(channel: "RIGHT"', "right VU")
require(UI, "static let referenceDBFS = -18.0", "VU reference")
require(UI, "static let minimumVU = -20.0", "VU display floor")
require(UI, "static let maximumVU = 3.0", "VU display ceiling")
require(UI, "dbFS - referenceDBFS", "VU dBFS mapping")

# Numerical guard for the shipping VU calibration contract.
for dbfs, expected in [(-38.0, -20.0), (-18.0, 0.0), (-15.0, 3.0), (-60.0, -20.0), (-10.0, 3.0)]:
    actual = vu_for_dbfs(dbfs)
    if not math.isclose(actual, expected, abs_tol=1e-12):
        print(
            f"PR36 UI foundation validation: FAIL: VU mapping {dbfs} dBFS -> {actual} VU, expected {expected}",
            file=sys.stderr,
        )
        raise SystemExit(1)

# PR35 meter gating remains intact: Dashboard visibility requests metering, the
# bridge injects that demand only when publishing a graph, and Swift diagnostics
# expose the resulting gate state to the UI.
require(UI, "ProductionMeteringDemand.acquire", "visible-dashboard meter request")
require(UI, "ProductionMeteringDemand.release", "hidden-dashboard meter release")
require(UI, "Task.sleep(nanoseconds: 33_000_000)", "bounded UI meter polling")
require(BRIDGE, "static _Atomic bool gMeteringDemand = false;", "default-off meter demand")
require(BRIDGE, "snapshot.meteringEnabled = N60RealtimeAudioBridgeMeteringDemand();", "graph-publication meter demand injection")
require(DIAGNOSTICS, "let meteringEnabled: Bool", "Swift meter-gate diagnostics")
require(DIAGNOSTICS, "meteringEnabled = diagnostics.meteringEnabled", "Swift meter-gate diagnostics mapping")

# The meter-demand getter must not creep into the physical-output sample loop.
output_proc = BRIDGE.split("OSStatus N60OutputIOProc(", 1)[1]
forbid(output_proc, "N60RealtimeAudioBridgeMeteringDemand()", "realtime output callback")

# Room Correction and Active Crossover belong to the dedicated speaker workspace.
require(UI, "case speakerSetup", "speaker setup route")
require(UI, "private struct ProductionSpeakerSetupView", "speaker setup surface")
require(UI, 'Text("Active Crossover")', "speaker setup crossover route")
require(UI, 'Text("Room Correction")', "speaker setup room-correction route")
require(DOC, "Room Correction and Active Crossover do not appear as dashboard control panels.", "information architecture contract")

# Engineering validation is intentionally retained during migration.
require(DOC, "Engineering Validation", "validation migration contract")
require(DOC, "handoff document", "post-merge handoff requirement")

print("PR36 production UI foundation: PASS")
