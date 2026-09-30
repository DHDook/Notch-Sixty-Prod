#!/usr/bin/env python3
from pathlib import Path

ROOT = Path("NotchSixty/UI/ProductionRootView.swift")
ROOM = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift")


def replace_exact(text: str, old: str, new: str, expected: int, label: str) -> str:
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} occurrence(s), found {count}")
    return text.replace(old, new)


def panel_surface(indent: str = "        ") -> str:
    return (
        f"{indent}.background(.regularMaterial, in: .rect(cornerRadius: 22))\n"
        f"{indent}.overlay {{\n"
        f"{indent}    RoundedRectangle(cornerRadius: 22, style: .continuous)\n"
        f"{indent}        .stroke(.quaternary, lineWidth: 0.5)\n"
        f"{indent}}}"
    )


root = ROOT.read_text()
start_marker = "private struct ProductionActiveCrossoverView: View {"
end_marker = "\nprivate struct ProductionRoomCorrectionView: View {"
if start_marker not in root or end_marker not in root:
    raise SystemExit("Active Crossover section markers not found")

prefix, remainder = root.split(start_marker, 1)
active_body, suffix = remainder.split(end_marker, 1)
active = start_marker + active_body

active = replace_exact(
    active,
    "        .glassEffect(.regular, in: .rect(cornerRadius: 16))",
    panel_surface(),
    1,
    "Playback System card glass",
)
active = replace_exact(
    active,
    "        .glassEffect(.regular, in: .rect(cornerRadius: 18))",
    panel_surface(),
    5,
    "Active Crossover content-card glass",
)
active = replace_exact(
    active,
    "        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))",
    "        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))",
    1,
    "route-row background",
)
active = replace_exact(
    active,
    "        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))",
    "        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 14))",
    1,
    "driver-bus background",
)
active = replace_exact(
    active,
    "        .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))",
    "        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))",
    1,
    "driver-EQ background",
)
active = replace_exact(
    active,
    '''                Button {
                    addRoute()
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .disabled(physicalRoutingLocked || routing.routes.count >= MultiOutputRoutingConfiguration.maximumRouteCount || engine.outputDevices.isEmpty)''',
    '''                Button {
                    addRoute()
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(physicalRoutingLocked || routing.routes.count >= MultiOutputRoutingConfiguration.maximumRouteCount || engine.outputDevices.isEmpty)''',
    1,
    "Add Route glass button",
)

root = prefix + active + end_marker + suffix
ROOT.write_text(root)

room = ROOM.read_text()
room = replace_exact(
    room,
    "        .glassEffect(.regular, in: .rect(cornerRadius: 18))",
    panel_surface(),
    6,
    "Room Correction content-card glass",
)
room = replace_exact(
    room,
    "                .buttonStyle(.borderedProminent)",
    "                .buttonStyle(.glassProminent)",
    4,
    "Room Correction primary actions",
)
room = replace_exact(
    room,
    "            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))",
    "            .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))",
    1,
    "measurement-position row background",
)
room = replace_exact(
    room,
    "            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))",
    "            .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))",
    1,
    "diagnostic chart background",
)
ROOM.write_text(room)

print("Applied PR43 current-macOS UI polish")
