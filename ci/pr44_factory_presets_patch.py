#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/State/ProductProfiles.swift")
text = path.read_text()

old = '''    private static let referencePresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000001")!
    private static let defaultSystemID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000002")!

    private static let factoryContentPresets: [ContentPreset] = [
        ContentPreset(
            id: referencePresetID,
            name: "Reference",
            origin: .factory,
            state: ContentPresetState()
        ),
    ]
'''

new = '''    private static let referencePresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000001")!
    private static let defaultSystemID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000002")!
    private static let rockArenaPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000010")!
    private static let modernPopPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000011")!
    private static let hipHopClubPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000012")!
    private static let cinemaPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000013")!
    private static let streamingPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000014")!

    private static func factoryBand(
        _ type: EQFilterType,
        _ frequencyHz: Double,
        _ gainDB: Double,
        _ q: Double
    ) -> EQBand {
        EQBand(
            enabled: true,
            type: type,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            q: q,
            slope: .db12
        )
    }

    private static func factoryEQ(_ bands: [EQBand]) -> StereoEQConfiguration {
        StereoEQConfiguration(
            channelMode: .linked,
            editChannel: .linked,
            phaseMode: .minimumPhase,
            bypassed: false,
            linkedBands: bands
        )
    }

    private static func factoryBaseDynamics(
        limiterLookAheadMs: Double = 1.5,
        limiterReleaseMs: Double = 80.0
    ) -> DynamicsConfiguration {
        var dynamics = DynamicsConfiguration()
        dynamics.dcOffsetFilter.enabled = true
        dynamics.infrasonicFilter.enabled = true
        dynamics.infrasonicFilter.cutoffHz = 18.0
        dynamics.infrasonicFilter.slope = .db48
        dynamics.limiter.enabled = true
        dynamics.limiter.ceilingDB = -0.5
        dynamics.limiter.attackMs = 0.1
        dynamics.limiter.lookAheadMs = limiterLookAheadMs
        dynamics.limiter.releaseMs = limiterReleaseMs
        dynamics.limiter.truePeakGuardEnabled = true
        return dynamics
    }

    private static func modernPopDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics()
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -18.0
        dynamics.compressor.ratio = 1.4
        dynamics.compressor.attackMs = 20.0
        dynamics.compressor.releaseMs = 120.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 0.7
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = true
        dynamics.stereoWidener.lowWidth = 0.0
        dynamics.stereoWidener.midWidth = 1.15
        dynamics.stereoWidener.highWidth = 1.12
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func hipHopClubDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics(limiterLookAheadMs: 2.0, limiterReleaseMs: 100.0)
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -20.0
        dynamics.compressor.ratio = 1.5
        dynamics.compressor.attackMs = 25.0
        dynamics.compressor.releaseMs = 150.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 1.0
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = true
        dynamics.stereoWidener.lowWidth = 0.0
        dynamics.stereoWidener.midWidth = 1.08
        dynamics.stereoWidener.highWidth = 1.05
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func streamingDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics()
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -20.0
        dynamics.compressor.ratio = 1.35
        dynamics.compressor.attackMs = 15.0
        dynamics.compressor.releaseMs = 100.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 0.5
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = false
        dynamics.stereoWidener.lowWidth = 1.0
        dynamics.stereoWidener.midWidth = 1.05
        dynamics.stereoWidener.highWidth = 1.05
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func factoryState(
        bands: [EQBand],
        inputPreampDB: Double,
        headroomAttenuationDB: Double,
        dynamics: DynamicsConfiguration
    ) -> ContentPresetState {
        ContentPresetState(
            stereoEQ: factoryEQ(bands),
            inputPreampDB: inputPreampDB,
            headroomAttenuationDB: headroomAttenuationDB,
            dynamics: dynamics
        )
    }

    private static let factoryContentPresets: [ContentPreset] = [
        ContentPreset(
            id: referencePresetID,
            name: "Reference",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 42, 0.4, 0.65),
                    factoryBand(.peaking, 78, 0.5, 0.90),
                    factoryBand(.peaking, 165, -0.5, 1.00),
                    factoryBand(.peaking, 320, -0.4, 1.20),
                    factoryBand(.peaking, 680, 0.2, 1.00),
                    factoryBand(.peaking, 2_100, 0.4, 0.90),
                    factoryBand(.peaking, 3_600, -0.7, 1.20),
                    factoryBand(.peaking, 6_800, -0.2, 1.10),
                    factoryBand(.highShelf, 11_500, 0.8, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.7,
                dynamics: factoryBaseDynamics()
            )
        ),
        ContentPreset(
            id: rockArenaPresetID,
            name: "Rock Arena",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.8, 0.70),
                    factoryBand(.peaking, 82, 1.3, 0.90),
                    factoryBand(.peaking, 165, -0.5, 1.00),
                    factoryBand(.peaking, 320, 0.8, 1.00),
                    factoryBand(.peaking, 700, 1.5, 0.90),
                    factoryBand(.peaking, 1_800, 1.2, 1.00),
                    factoryBand(.peaking, 3_600, -1.3, 1.20),
                    factoryBand(.peaking, 6_500, -0.2, 1.10),
                    factoryBand(.highShelf, 12_000, 0.4, 0.70),
                ],
                inputPreampDB: -2.0,
                headroomAttenuationDB: -1.0,
                // Final listening revision: compressor and widener intentionally remain off.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 90.0)
            )
        ),
        ContentPreset(
            id: modernPopPresetID,
            name: "Modern Pop",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.4, 0.70),
                    factoryBand(.peaking, 70, 0.8, 0.90),
                    factoryBand(.peaking, 180, -0.5, 1.00),
                    factoryBand(.peaking, 900, 0.3, 1.00),
                    factoryBand(.peaking, 2_500, 0.6, 0.90),
                    factoryBand(.peaking, 5_500, 0.4, 1.00),
                    factoryBand(.highShelf, 12_000, 1.2, 0.70),
                ],
                inputPreampDB: -2.0,
                headroomAttenuationDB: -1.0,
                dynamics: modernPopDynamics()
            )
        ),
        ContentPreset(
            id: hipHopClubPresetID,
            name: "Hip-Hop Club",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 38, 1.4, 0.70),
                    factoryBand(.peaking, 60, 1.3, 0.90),
                    factoryBand(.peaking, 90, 0.6, 1.00),
                    factoryBand(.peaking, 220, -1.0, 1.10),
                    factoryBand(.peaking, 1_800, 0.4, 1.00),
                    factoryBand(.peaking, 4_000, -0.5, 1.10),
                    factoryBand(.highShelf, 10_000, 0.6, 0.70),
                ],
                inputPreampDB: -2.5,
                headroomAttenuationDB: -1.2,
                dynamics: hipHopClubDynamics()
            )
        ),
        ContentPreset(
            id: cinemaPresetID,
            name: "Cinema",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.4, 0.70),
                    factoryBand(.peaking, 120, -0.6, 1.00),
                    factoryBand(.peaking, 300, -0.7, 1.10),
                    factoryBand(.peaking, 2_000, 1.1, 0.90),
                    factoryBand(.peaking, 3_500, 0.4, 1.10),
                    factoryBand(.peaking, 7_000, -0.3, 1.00),
                    factoryBand(.highShelf, 12_000, 0.5, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.7,
                dynamics: factoryBaseDynamics()
            )
        ),
        ContentPreset(
            id: streamingPresetID,
            name: "Streaming",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 60, 0.3, 0.70),
                    factoryBand(.peaking, 180, -0.5, 1.00),
                    factoryBand(.peaking, 500, -0.4, 1.00),
                    factoryBand(.peaking, 2_200, 0.8, 0.90),
                    factoryBand(.peaking, 4_500, -0.6, 1.10),
                    factoryBand(.highShelf, 10_000, 0.8, 0.70),
                ],
                inputPreampDB: -1.8,
                headroomAttenuationDB: -0.8,
                dynamics: streamingDynamics()
            )
        ),
    ]
'''

count = text.count(old)
if count != 1:
    raise SystemExit(f"Expected exactly one factory preset seed block, found {count}")

path.write_text(text.replace(old, new))
print("Applied PR44 factory preset pack")
