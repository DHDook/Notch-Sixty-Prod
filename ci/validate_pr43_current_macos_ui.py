#!/usr/bin/env python3
from pathlib import Path

root = Path("NotchSixty/UI/ProductionRootView.swift").read_text()
room = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift").read_text()

start = "private struct ProductionActiveCrossoverView: View {"
end = "\nprivate struct ProductionRoomCorrectionView: View {"
assert start in root and end in root, "Active Crossover source section not found"
active = start + root.split(start, 1)[1].split(end, 1)[0]

panel = ".background(.regularMaterial, in: .rect(cornerRadius: 22))"
stroke = ".stroke(.quaternary, lineWidth: 0.5)"

assert active.count(panel) == 6, f"Active Crossover should have 6 material content panels; found {active.count(panel)}"
assert active.count(stroke) == 6, f"Active Crossover should have 6 subtle panel strokes; found {active.count(stroke)}"
assert ".glassEffect(.regular, in: .rect" not in active, "Passive Active Crossover content must not use Liquid Glass backgrounds"
assert 'Label("Add Route", systemImage: "plus")' in active and ".buttonStyle(.glass)" in active, "Add Route should use the native glass button style"
assert "LabeledContent(\"Physical Speaker Mode\")" in active, "Active Crossover must retain semantic LabeledContent layout"
assert "Mandatory crossover filtering always runs first." in active, "Per-driver crossover safety copy must remain present"
assert "cannot restore full-range signal to a protected split-driver bus" in active, "Global-bypass driver-safety copy must remain present"
assert ".background(.secondary.opacity(0.06)" not in active, "Legacy custom row surfaces should be removed from Active Crossover"
assert ".background(.background.opacity(0.42)" not in active, "Legacy nested driver-EQ surface should be removed"

assert room.count(panel) == 6, f"Room Correction should have 6 material content panels; found {room.count(panel)}"
assert room.count(stroke) == 6, f"Room Correction should have 6 subtle panel strokes; found {room.count(stroke)}"
assert ".glassEffect(.regular, in: .rect" not in room, "Passive Room Correction content must not use Liquid Glass backgrounds"
assert room.count(".buttonStyle(.glassProminent)") == 4, "Room Correction should expose exactly four primary glass actions"
assert "LabeledContent(\"Microphone Permission\")" in room, "Room Correction must retain semantic LabeledContent layout"
assert "RoomCorrectionAcousticDiagnosticsPanel(analysis: analysis)" in room, "PR43 acoustic diagnostics must remain reachable"
assert "Advanced Acoustic Diagnostics" in room, "Advanced diagnostics disclosure must remain present"
assert ".background(.quaternary.opacity(0.45)" not in room, "Measurement position rows should use the softened surface"
assert ".background(.quaternary.opacity(0.16)" not in room, "Diagnostic chart should use the softened surface"

print("PR43 current-macOS UI style guard passed")
