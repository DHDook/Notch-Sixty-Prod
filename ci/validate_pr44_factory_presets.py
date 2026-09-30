#!/usr/bin/env python3
from pathlib import Path

source = Path("NotchSixty/State/ProductProfiles.swift").read_text()

required_names = [
    'name: "Reference"',
    'name: "Rock Arena"',
    'name: "Classic Pop/Rock"',
    'name: "Modern Pop"',
    'name: "Hip-Hop Club"',
    'name: "Vocal Standards"',
    'name: "Cinema"',
    'name: "Streaming"',
]
for token in required_names:
    if token not in source:
        raise SystemExit(f"Missing factory content preset: {token}")

if source.count("origin: .factory") < 8:
    raise SystemExit("Expected eight factory content presets")

# Stable IDs keep persisted factory selections valid across releases.
for suffix in [
    "000000000001",
    "000000000010",
    "000000000011",
    "000000000012",
    "000000000013",
    "000000000014",
    "000000000015",
    "000000000016",
]:
    if suffix not in source:
        raise SystemExit(f"Missing stable factory preset UUID suffix {suffix}")

# Final listening-approved Rock Arena revision.
rock_contract = [
    "factoryBand(.lowShelf, 45, 0.8, 0.70)",
    "factoryBand(.peaking, 82, 1.3, 0.90)",
    "factoryBand(.peaking, 700, 1.5, 0.90)",
    "factoryBand(.peaking, 1_800, 1.2, 1.00)",
    "factoryBand(.peaking, 3_600, -1.3, 1.20)",
    "factoryBand(.highShelf, 12_000, 0.4, 0.70)",
    "Final listening revision: compressor and widener intentionally remain off.",
]
for token in rock_contract:
    if token not in source:
        raise SystemExit(f"Rock Arena final contract missing: {token}")

classic_contract = [
    'name: "Classic Pop/Rock"',
    "factoryBand(.lowShelf, 50, 0.6, 0.70)",
    "factoryBand(.peaking, 220, -0.5, 1.00)",
    "factoryBand(.peaking, 750, 0.5, 0.90)",
    "factoryBand(.peaking, 2_000, 0.9, 0.90)",
    "factoryBand(.peaking, 4_500, -0.4, 1.10)",
    "factoryBand(.highShelf, 11_000, 0.6, 0.70)",
    "Preserve vintage dynamics and image; no content compressor or widener.",
]
for token in classic_contract:
    if token not in source:
        raise SystemExit(f"Classic Pop/Rock contract missing: {token}")

vocal_contract = [
    'name: "Vocal Standards"',
    "factoryBand(.lowShelf, 70, 0.2, 0.70)",
    "factoryBand(.peaking, 150, 0.5, 0.85)",
    "factoryBand(.peaking, 350, -0.5, 1.00)",
    "factoryBand(.peaking, 1_700, 0.9, 0.90)",
    "factoryBand(.peaking, 4_000, -0.5, 1.10)",
    "factoryBand(.highShelf, 10_500, 0.3, 0.70)",
    "Keep mono/hard-panned-era recordings natural; no compressor or widener.",
]
for token in vocal_contract:
    if token not in source:
        raise SystemExit(f"Vocal Standards contract missing: {token}")

# Preset safety/voicing state must remain content-owned. Physical crossover/output
# association stays in Playback System Profiles and must not be seeded here.
factory_start = source.index("private static let factoryContentPresets")
factory_end = source.index("\n\n    let engine:", factory_start)
factory_block = source[factory_start:factory_end]
for forbidden in ["BassManagementConfiguration", "outputGainDB", "associatedOutputUID", "outputRouting"]:
    if forbidden in factory_block:
        raise SystemExit(f"Factory content presets must not own Playback System field: {forbidden}")

# The production content-owned gain translation is explicit.
for token in [
    "inputPreampDB: -1.5",
    "headroomAttenuationDB: -0.7",
    "inputPreampDB: -2.5",
    "headroomAttenuationDB: -1.2",
    "inputPreampDB: -1.3",
]:
    if token not in factory_block:
        raise SystemExit(f"Expected content gain/headroom translation missing: {token}")

# Common transparent protection is explicit; no hidden default limiter assumption.
for token in [
    "dynamics.limiter.enabled = true",
    "dynamics.limiter.ceilingDB = -0.5",
    "dynamics.limiter.truePeakGuardEnabled = true",
    "dynamics.dcOffsetFilter.enabled = true",
    "dynamics.infrasonicFilter.enabled = true",
]:
    if token not in source:
        raise SystemExit(f"Factory dynamics safety contract missing: {token}")

print("PR44 factory preset validation passed")
