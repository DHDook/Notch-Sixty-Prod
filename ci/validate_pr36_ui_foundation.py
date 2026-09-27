#!/usr/bin/env python3
from pathlib import Path
import math
import sys

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text()
APP = (ROOT / "NotchSixty/NotchSixtyApp.swift").read_text()
PROJECT = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()
DOC = (ROOT / "docs/PR36_PRODUCTION_UI_FOUNDATION.md").read_text()
BRIDGE = (ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c").read_text()
BRIDGE_HEADER = (ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h").read_text()
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
    return min(max(dbfs - (-18.0), -30.0), 3.0)


# Shipping target / platform language.
require(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 27.0;", "project deployment target")
forbid(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 14.2;", "project deployment target")

# macOS 27 native navigation + selective Liquid Glass control language.
require(UI, "NavigationSplitView", "production navigation")
require(UI, "GlassEffectContainer", "selective custom glass controls")
require(UI, ".buttonStyle(.glassProminent)", "primary glass action")
require(UI, ".glassEffect(.regular", "Liquid Glass status/control surface")

# The shipping launch scene is production. Engineering validation remains a
# separately addressable window that reuses the same ProductController/engine.
require(APP, "ProductionRootView(product: product)", "primary production scene")
require(APP, 'Window("Engineering Validation", id: "engineering-validation")', "engineering validation scene")
require(APP, "EngineeringValidationView(engine: product.audioEngine)", "shared-engine validation scene")
require(UI, 'openWindow(id: "engineering-validation")', "engineering validation toolbar affordance")
if APP.index("ProductionRootView(product: product)") > APP.index('Window("Engineering Validation"'):
    print("PR36 UI foundation validation: FAIL: production scene must be declared before engineering validation", file=sys.stderr)
    raise SystemExit(1)
for validation_surface in [
    "ContentView(engine: engine)",
    "PR27ProtectionValidationView(engine: engine)",
    "PR28AdvancedDynamicsValidationView(engine: engine)",
    "PR30PhaseTimeValidationView(engine: engine)",
    "PR31NoiseHumValidationView(engine: engine)",
]:
    require(APP, validation_surface, "retained engineering validation")

# Signature dashboard identity is one clean-room stereo analog instrument with
# two independently driven needles and one centered brand mark.
require(UI, "private struct StereoSignatureVUMeterPanel", "isolated VU update surface")
require(UI, "private struct StereoSignatureVUMeter", "stereo signature VU component")
require(UI, "private struct StereoSignatureVUScaleFace", "static stereo VU face component")
require(UI, "StereoSignatureVUMeter(leftVU: leftVU, rightVU: rightVU)", "stereo VU deck")
require(UI, "static let referenceDBFS = -18.0", "VU reference")
require(UI, "static let minimumVU = -30.0", "extended VU display floor")
require(UI, "static let maximumVU = 3.0", "VU display ceiling")
require(UI, "dbFS - referenceDBFS", "VU dBFS mapping")
require(UI, "startAngle: .degrees(205)", "upper-arc 1970s VU scale")
require(UI, "endAngle: .degrees(335)", "upper-arc 1970s VU scale")
require(UI, "205 + normalizedPosition(forVU: vu) * 130", "VU needle sweep")
require(UI, ".equatable()", "static VU face redraw suppression")
require(UI, 'Text("NOTCH SIXTY")', "single centered product mark")
if UI.count('Text("NOTCH SIXTY")') != 1:
    print("PR36 UI foundation validation: FAIL: stereo VU deck must contain exactly one NOTCH SIXTY mark", file=sys.stderr)
    raise SystemExit(1)
forbid(UI, "peakDBFS", "signature VU numeric peak readout")
forbid(UI, 'Text("PEAK ', "signature VU numeric peak readout")

# Numerical guard for the shipping VU calibration contract. Extending the low
# end gives useful motion at ordinary/quiet playback levels without changing 0 VU.
for dbfs, expected in [(-48.0, -30.0), (-38.0, -20.0), (-18.0, 0.0), (-15.0, 3.0), (-60.0, -30.0), (-10.0, 3.0)]:
    actual = vu_for_dbfs(dbfs)
    if not math.isclose(actual, expected, abs_tol=1e-12):
        print(
            f"PR36 UI foundation validation: FAIL: VU mapping {dbfs} dBFS -> {actual} VU, expected {expected}",
            file=sys.stderr,
        )
        raise SystemExit(1)

# Live VU state is isolated from the Dashboard hierarchy so 20 Hz needle updates
# do not invalidate all Dashboard controls/cards.
dashboard_body = UI.split("private struct ProductionDashboardView", 1)[1].split(
    "private struct StereoSignatureVUMeterPanel", 1
)[0]
forbid(dashboard_body, "@State private var leftVU", "Dashboard-wide VU state")
forbid(dashboard_body, ".task(id:", "Dashboard-wide VU polling task")
require(UI, "@State private var leftVU", "isolated left VU state")
require(UI, "@State private var rightVU", "isolated right VU state")

# Meter pipelines are independent. Dashboard owns a lightweight output-only VU
# pipeline and must not enable the render-kernel input/post-EQ/output meter stack.
require(UI, 'Toggle("VU Meters", isOn: $vuMetersEnabled)', "explicit VU meter toggle")
require(UI, "engine.lifecycleState == .running, vuMetersEnabled", "meter-loop enable guard")
require(UI, "ProductionOutputVUMeterDemand.acquire", "visible-dashboard output VU request")
require(UI, "ProductionOutputVUMeterDemand.release", "hidden/disabled-dashboard output VU release")
require(UI, "Task.sleep(nanoseconds: 50_000_000)", "20 Hz VU UI polling")
forbid(UI, "ProductionMeteringDemand.acquire", "Dashboard full-meter request")
forbid(UI, "N60RealtimeAudioBridgeSetMeteringDemand", "Dashboard full-meter API")

require(BRIDGE, "static _Atomic bool gMeteringDemand = false;", "default-off full meter demand")
require(BRIDGE, "static _Atomic bool gOutputVUMeterDemand = false;", "default-off output VU demand")
require(BRIDGE_HEADER, "N60RealtimeAudioBridgeSetOutputVUMeterDemand", "output VU demand API")
require(BRIDGE_HEADER, "N60OutputVUMeterSnapshot", "output VU snapshot API")
require(BRIDGE, "bool outputVUMeterEnabled = N60RealtimeAudioBridgeOutputVUMeterDemand();", "callback-bounded VU demand latch")
require(BRIDGE, "publish_output_vu_meter(", "output-only VU publication")
require(BRIDGE, "diagnostics.outputMeter.rmsLeft = vu.rmsLeft;", "VU diagnostics bridge")
require(BRIDGE, "snapshot.meteringEnabled = N60RealtimeAudioBridgeMeteringDemand();", "independent full-meter graph demand")
require(DIAGNOSTICS, "let meteringEnabled: Bool", "Swift full-meter diagnostics")

# Demand is read once before the sample loop; no atomic demand lookup may occur
# inside the rendered-frame loop itself.
output_proc = BRIDGE.split("OSStatus N60OutputIOProc(", 1)[1]
loop = output_proc.split("for (UInt32 frameIndex = 0; frameIndex < framesToRead; ++frameIndex)", 1)[1]
loop = loop.split("N60RenderKernelEndRender", 1)[0]
forbid(loop, "N60RealtimeAudioBridgeOutputVUMeterDemand()", "per-sample VU path")
forbid(output_proc, "N60RealtimeAudioBridgeMeteringDemand()", "realtime output callback full-meter demand")

# Side navigation is authoritative. Detailed metering gets its own future workspace;
# the minimal Audio route is removed and its useful routing control lives on Dashboard.
require(UI, "case meters", "meters route")
forbid(UI, "case audio", "obsolete audio route")
require(UI, 'Text("Output Device")', "dashboard output selector")
require(UI, 'Label("Refresh Outputs", systemImage: "arrow.clockwise")', "dashboard output refresh")
forbid(UI, 'Button("Open")', "redundant dashboard jump buttons")
forbid(UI, "private struct ProductionAudioView", "obsolete audio page")

# Active Crossover and Room Correction now have separate first-class sidebar
# workspaces rather than sharing a segmented Speaker Setup page.
require(UI, "case activeCrossover", "active crossover route")
require(UI, "case roomCorrection", "room correction route")
forbid(UI, "case speakerSetup", "combined speaker setup route")
require(UI, "private struct ProductionActiveCrossoverView", "active crossover surface")
require(UI, "private struct ProductionRoomCorrectionView", "room correction surface")
forbid(UI, "private struct ProductionSpeakerSetupView", "combined speaker setup surface")
require(DOC, "Active Crossover and Room Correction are separate sidebar workspaces.", "information architecture contract")
require(DOC, "independent meter pipelines", "meter pipeline architecture contract")

# Engineering validation is intentionally retained during migration.
require(DOC, "Engineering Validation", "validation migration contract")
require(DOC, "handoff document", "post-merge handoff requirement")

print("PR36 production UI foundation: PASS")
