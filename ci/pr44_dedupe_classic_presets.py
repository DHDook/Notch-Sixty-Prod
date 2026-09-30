#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/State/ProductProfiles.swift")
text = path.read_text()

classic_id = '    private static let classicPopRockPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000015")!\n'
vocal_id = '    private static let vocalStandardsPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000016")!\n'
streaming_id = '    private static let streamingPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000014")!\n'

# Remove every staged duplicate, then restore exactly one stable-ID pair.
text = text.replace(classic_id, "").replace(vocal_id, "")
if text.count(streaming_id) != 1:
    raise SystemExit("Unexpected Streaming ID anchor count")
text = text.replace(streaming_id, streaming_id + classic_id + vocal_id)

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
'''

if classic_block not in text or vocal_block not in text:
    raise SystemExit("Expected classic preset blocks are missing")

# Collapse all identical copies and insert exactly one in the intended factory order.
text = text.replace(classic_block, "")
text = text.replace(vocal_block, "")
modern_anchor = '''        ContentPreset(
            id: modernPopPresetID,
            name: "Modern Pop",
'''
cinema_anchor = '''        ContentPreset(
            id: cinemaPresetID,
            name: "Cinema",
'''
if text.count(modern_anchor) != 1 or text.count(cinema_anchor) != 1:
    raise SystemExit("Unexpected preset insertion anchor count")
text = text.replace(modern_anchor, classic_block + modern_anchor)
text = text.replace(cinema_anchor, vocal_block + cinema_anchor)

path.write_text(text)
print("Collapsed Classic Pop/Rock and Vocal Standards to one factory entry each")
