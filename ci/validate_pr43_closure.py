#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
root_view = (root / "NotchSixty/UI/ProductionRootView.swift").read_text(encoding="utf-8")
route = (root / "NotchSixty/Audio/Routing/AudioRouteConfiguration.swift").read_text(encoding="utf-8")
bridge = (root / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c").read_text(encoding="utf-8")
diagnostics = (root / "NotchSixty/Audio/RoomCorrectionMeasurementAnalyzer.swift").read_text(encoding="utf-8")
workspace = (root / "NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift").read_text(encoding="utf-8")
closure = (root / "docs/PR43_CLOSURE.md").read_text(encoding="utf-8")

def require(value, message):
    if not value:
        raise SystemExit(message)

for token in [
    "Per-Driver Processing",
    "driverBusEditor",
    "replaceSelectedSystemSpeakerDriverProcessing",
    "Limiter Threshold",
    "Driver EQ",
]:
    require(token in root_view, f"missing production per-driver UI contract: {token}")

for token in [
    "SpeakerDriverBusProcessingConfiguration",
    "maximumEQBandCount = 8",
    "delayRangeMilliseconds = 0.0 ... 50.0",
    "supportedEQTypes",
]:
    require(token in route, f"missing bounded driver model contract: {token}")

require(
    bridge.find("process_speaker_bus_splitter") < bridge.find("N60SpeakerDriverProcessingRuntimeProcessValues"),
    "driver processing must remain downstream of mandatory speaker-bus splitting",
)

for token in [
    "RoomCorrectionAcousticDiagnosticsAnalyzer",
    "energyDecayDB",
    "groupDelayMilliseconds",
]:
    require(token in diagnostics, f"missing advanced acoustic diagnostics: {token}")
require("RoomCorrectionAcousticDiagnosticsPanel" in workspace, "advanced diagnostics must be reachable in production UI")

for token in [
    "isolated Low/Mid/High/Sub logical-bus acoustic captures",
    "automatic crossover-frequency optimization",
    "automatic measurement-derived excess-phase inversion",
    "automatic low-latency IIR Room Correction fitting",
    "per-driver realtime meter UI",
    "richer portable CamillaDSP physical speaker-matrix export",
    "Headphone-specific workflows",
    "REAL-MAC ACOUSTIC ACCEPTANCE PENDING",
]:
    require(token in closure, f"PR43 closure must document measurement/product boundary: {token}")

require("does **not** currently provide" in closure, "measurement limitation must be explicit")
print("PR43 closure surface validation passed")
