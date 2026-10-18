import XCTest
@testable import NotchSixty

/// Factory content presets: stable identity, listening-approved voicing, and the
/// common transparent protection every factory preset carries.
@MainActor
final class FactoryContentPresetTests: XCTestCase {
    private struct Band: Equatable, CustomStringConvertible {
        let type: EQFilterType
        let frequencyHz: Double
        let gainDB: Double
        let q: Double

        init(_ type: EQFilterType, _ frequencyHz: Double, _ gainDB: Double, _ q: Double) {
            self.type = type
            self.frequencyHz = frequencyHz
            self.gainDB = gainDB
            self.q = q
        }

        init(_ band: EQBand) {
            self.init(band.type, band.frequencyHz, band.gainDB, band.q)
        }

        var description: String { "\(type) \(frequencyHz) Hz \(gainDB) dB Q\(q)" }
    }

    private var presets: [ContentPreset] = []
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        presets = profiles.contentPresets.filter { $0.origin == .factory }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func preset(_ name: String) throws -> ContentPreset {
        try XCTUnwrap(presets.first { $0.name == name }, "missing factory preset \(name)")
    }

    func testEightFactoryPresetsWithStableIdentifiers() {
        let expected: [String: String] = [
            "Reference": "000000000001",
            "Rock Arena": "000000000010",
            "Modern Pop": "000000000011",
            "Hip-Hop Club": "000000000012",
            "Cinema": "000000000013",
            "Streaming": "000000000014",
            "Classic Pop/Rock": "000000000015",
            "Vocal Standards": "000000000016",
        ]
        XCTAssertEqual(presets.count, 8)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count, "names are unique")
        for preset in presets {
            let suffix = try? XCTUnwrap(expected[preset.name], "unexpected factory preset \(preset.name)")
            // Persisted selections refer to these IDs, so they must never change.
            XCTAssertEqual(
                preset.id,
                UUID(uuidString: "6A782AB6-492B-46C9-A0A0-\(suffix ?? "")"),
                preset.name
            )
        }
    }

    func testEveryFactoryPresetCarriesTransparentProtection() {
        for preset in presets {
            let dynamics = preset.state.dynamics
            XCTAssertTrue(dynamics.limiter.enabled, preset.name)
            XCTAssertEqual(dynamics.limiter.ceilingDB, -0.5, preset.name)
            XCTAssertTrue(dynamics.limiter.truePeakGuardEnabled, preset.name)
            XCTAssertTrue(dynamics.dcOffsetFilter.enabled, preset.name)
            XCTAssertTrue(dynamics.infrasonicFilter.enabled, preset.name)
            XCTAssertLessThan(preset.state.inputPreampDB, 0, "\(preset.name) leaves headroom")
            XCTAssertLessThan(preset.state.headroomAttenuationDB, 0, "\(preset.name) leaves headroom")
        }
    }

    // Listening-approved revisions: these presets preserve the recording's
    // dynamics and image, so the compressor and widener stay off.
    func testNaturalPresetsKeepCompressorAndWidenerOffWithApprovedVoicing() throws {
        let voicings: [String: [Band]] = [
            "Rock Arena": [
                Band(.lowShelf, 45, 0.8, 0.70),
                Band(.peaking, 82, 1.3, 0.90),
                Band(.peaking, 165, -0.5, 1.00),
                Band(.peaking, 320, 0.8, 1.00),
                Band(.peaking, 700, 1.5, 0.90),
                Band(.peaking, 1_800, 1.2, 1.00),
                Band(.peaking, 3_600, -1.3, 1.20),
                Band(.peaking, 6_500, -0.2, 1.10),
                Band(.highShelf, 12_000, 0.4, 0.70),
            ],
            "Classic Pop/Rock": [
                Band(.lowShelf, 50, 0.6, 0.70),
                Band(.peaking, 220, -0.5, 1.00),
                Band(.peaking, 750, 0.5, 0.90),
                Band(.peaking, 2_000, 0.9, 0.90),
                Band(.peaking, 4_500, -0.4, 1.10),
                Band(.highShelf, 11_000, 0.6, 0.70),
            ],
            "Vocal Standards": [
                Band(.lowShelf, 70, 0.2, 0.70),
                Band(.peaking, 150, 0.5, 0.85),
                Band(.peaking, 350, -0.5, 1.00),
                Band(.peaking, 1_700, 0.9, 0.90),
                Band(.peaking, 4_000, -0.5, 1.10),
                Band(.highShelf, 10_500, 0.3, 0.70),
            ],
        ]
        for (name, bands) in voicings {
            let state = try preset(name).state
            XCTAssertFalse(state.dynamics.compressor.enabled, "\(name) compressor")
            XCTAssertFalse(state.dynamics.stereoWidener.enabled, "\(name) widener")
            XCTAssertEqual(state.stereoEQ.channelMode, .linked, name)
            XCTAssertEqual(state.stereoEQ.linkedBands.map(Band.init), bands, name)
            XCTAssertTrue(state.stereoEQ.linkedBands.allSatisfy(\.enabled), name)
        }
    }

    func testDensityPresetsUseGentleCompressionAndMonoSafeWidening() throws {
        for name in ["Modern Pop", "Hip-Hop Club", "Streaming"] {
            let dynamics = try preset(name).state.dynamics
            XCTAssertTrue(dynamics.compressor.enabled, name)
            XCTAssertLessThanOrEqual(dynamics.compressor.ratio, 1.5, "\(name) stays gentle")
            XCTAssertTrue(dynamics.stereoWidener.enabled, name)
            XCTAssertLessThanOrEqual(dynamics.stereoWidener.midWidth, 1.15, name)
        }
        for name in ["Modern Pop", "Hip-Hop Club"] {
            let widener = try preset(name).state.dynamics.stereoWidener
            XCTAssertTrue(widener.monoLowBand, "\(name) keeps bass mono")
            XCTAssertEqual(widener.lowWidth, 0, name)
        }
    }
}
