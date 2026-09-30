#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/State/ProductProfiles.swift")
text = path.read_text()

id_old = '''    private static let streamingPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000014")!
'''
id_new = '''    private static let streamingPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000014")!
    private static let classicPopRockPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000015")!
    private static let vocalStandardsPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000016")!
'''
if text.count(id_old) != 1:
    raise SystemExit("Could not locate factory preset ID insertion point")
text = text.replace(id_old, id_new)

classic_marker = '''        ContentPreset(
            id: modernPopPresetID,
            name: "Modern Pop",
'''
classic_block = '''        ContentPreset(
            id: classicPopRockPresetID,
            name: "Classic Pop/Rock",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 50, 0.6, 0.70),
                    factoryBand(.peaking, 220, -0.5, 1.00),
                    factoryBand(.peaking, 750, 0.5, 0.90),
                    factoryBand(.peaking, 2_000, 0.9, 0.90),
                    factoryBand(.peaking, 4_500, -0.4, 1.10),
                    factoryBand(.highShelf, 11_000, 0.6, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.8,
                // Preserve vintage dynamics and image; no content compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 90.0)
            )
        ),
''' + classic_marker
if text.count(classic_marker) != 1:
    raise SystemExit("Could not locate Modern Pop insertion point")
text = text.replace(classic_marker, classic_block)

vocal_marker = '''        ContentPreset(
            id: cinemaPresetID,
            name: "Cinema",
'''
vocal_block = '''        ContentPreset(
            id: vocalStandardsPresetID,
            name: "Vocal Standards",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 70, 0.2, 0.70),
                    factoryBand(.peaking, 150, 0.5, 0.85),
                    factoryBand(.peaking, 350, -0.5, 1.00),
                    factoryBand(.peaking, 1_700, 0.9, 0.90),
                    factoryBand(.peaking, 4_000, -0.5, 1.10),
                    factoryBand(.highShelf, 10_500, 0.3, 0.70),
                ],
                inputPreampDB: -1.3,
                headroomAttenuationDB: -0.7,
                // Keep mono/hard-panned-era recordings natural; no compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 100.0)
            )
        ),
''' + vocal_marker
if text.count(vocal_marker) != 1:
    raise SystemExit("Could not locate Cinema insertion point")
text = text.replace(vocal_marker, vocal_block)

path.write_text(text)
print("Added Classic Pop/Rock and Vocal Standards factory presets")
