#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "NotchSixty" / "Audio" / "RoomCorrectionMeasurementAnalyzer.swift"
UI = ROOT / "NotchSixty" / "UI" / "ProductionRoomCorrectionWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests" / "RoomCorrectionMeasurementAnalyzerTests.swift"
REALTIME = ROOT / "NotchSixty" / "Audio" / "Realtime"


def fail(message: str) -> None:
    print(f"PR43 acoustic diagnostics validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

analyzer = ANALYZER.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")

for token in [
    "RoomCorrectionAcousticDiagnosticsAnalyzer",
    "energyTimeCurveDB",
    "energyDecayDB",
    "groupDelayMilliseconds",
    "reverseEnergy",
    "Offline-only derivation",
]:
    if token not in analyzer:
        fail(f"missing analyzer contract token: {token}")

for token in [
    "Advanced Acoustic Diagnostics",
    "RoomCorrectionDiagnosticLineChart",
    "Task.detached(priority: .utility)",
    "case impulse",
    "case step",
    "case energyTime",
    "case energyDecay",
    "case groupDelay",
]:
    if token not in ui:
        fail(f"missing UI contract token: {token}")

for token in [
    "testPR43AcousticDiagnosticsDeriveStepDecayAndGroupDelay",
    "testPR43AcousticDiagnosticsFailClosedOnInvalidInputs",
]:
    if token not in tests:
        fail(f"missing deterministic test: {token}")

for path in REALTIME.glob("*"):
    if path.suffix in {".c", ".h"} and "RoomCorrectionAcousticDiagnostics" in path.read_text(encoding="utf-8"):
        fail(f"offline diagnostics leaked into realtime source: {path.name}")

print("PR43 advanced acoustic diagnostics guard: PASS")
