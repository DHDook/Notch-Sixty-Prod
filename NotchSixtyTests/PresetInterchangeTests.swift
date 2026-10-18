import Foundation
import XCTest
@testable import NotchSixty

final class PresetInterchangeTests: XCTestCase {
    private func linkedStereo(_ bands: [EQBand]) -> StereoEQConfiguration {
        StereoEQConfiguration(channelMode: .linked, linkedBands: bands)
    }

    private let shelvesAndPeak = [
        EQBand(type: .lowShelf, frequencyHz: 85, gainDB: 4.5, q: 0.71),
        EQBand(type: .peaking, frequencyHz: 1_250, gainDB: -6.25, q: 2.4),
        EQBand(type: .highShelf, frequencyHz: 9_500, gainDB: -3, q: 0.9),
    ]

    private func assertBandsMatch(
        _ actual: [EQBand],
        _ expected: [EQBand],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.type, e.type, file: file, line: line)
            XCTAssertEqual(a.enabled, e.enabled, file: file, line: line)
            XCTAssertEqual(a.frequencyHz, e.frequencyHz, accuracy: 1e-3, file: file, line: line)
            XCTAssertEqual(a.gainDB, e.gainDB, accuracy: 1e-3, file: file, line: line)
            XCTAssertEqual(a.q, e.q, accuracy: 1e-5, file: file, line: line)
        }
    }

    // MARK: REW

    func testREWExportImportRoundTripsShelvesAndPeaking() throws {
        let exported = try PresetInterchange.exportREW(linkedStereo(shelvesAndPeak))
        XCTAssertTrue(exported.warnings.isEmpty, "\(exported.warnings)")

        let imported = try PresetInterchange.importPreset(
            data: exported.data,
            fileName: "Room.txt",
            baseStereo: StereoEQConfiguration()
        )
        XCTAssertEqual(imported.stereoEQ.channelMode, .linked)
        XCTAssertFalse(imported.stereoEQ.bypassed)
        XCTAssertEqual(imported.suggestedName, "Room")
        assertBandsMatch(imported.stereoEQ.linkedBands, shelvesAndPeak)
    }

    func testREWImportWithoutUsableFiltersThrows() {
        let text = """
        # Only comments, a preamp and empty slots
        Preamp: -3 dB
        Filter 1: ON None
        Filter 2: OFF None
        """
        XCTAssertThrowsError(try PresetInterchange.importPreset(
            data: Data(text.utf8),
            fileName: "Empty.txt",
            baseStereo: StereoEQConfiguration()
        ))
    }

    // MARK: EasyEffects

    func testEasyEffectsExportImportRoundTripsAndKeepsOutputGainOutOfContentPreset() throws {
        let exported = try PresetInterchange.exportEasyEffects(linkedStereo(shelvesAndPeak), inputGainDB: -4.5)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
        let output = try XCTUnwrap(root["output"] as? [String: Any])
        let equalizer = try XCTUnwrap(output["equalizer#0"] as? [String: Any])
        XCTAssertEqual(equalizer["output-gain"] as? Double, 0, "output trim belongs to the Playback System")
        XCTAssertEqual(equalizer["input-gain"] as? Double, -4.5)
        XCTAssertEqual(equalizer["split-channels"] as? Bool, false)

        let imported = try PresetInterchange.importPreset(
            data: exported.data,
            fileName: "Room.json",
            baseStereo: StereoEQConfiguration()
        )
        XCTAssertEqual(imported.stereoEQ.channelMode, .linked)
        XCTAssertEqual(try XCTUnwrap(imported.inputPreampDB), -4.5, accuracy: 1e-9)
        assertBandsMatch(imported.stereoEQ.linkedBands, shelvesAndPeak)
    }

    func testEasyEffectsImportNeverAppliesOutputGain() throws {
        let preset: [String: Any] = [
            "output": [
                "equalizer#0": [
                    "input-gain": -2.0,
                    "output-gain": -9.0,
                    "split-channels": false,
                    "left": ["band0": ["type": "Bell", "frequency": 500.0, "gain": -3.0, "q": 1.5]],
                    "right": [:] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: preset)
        let imported = try PresetInterchange.importPreset(
            data: data,
            fileName: "Loud.json",
            baseStereo: StereoEQConfiguration()
        )
        // Only the input preamp is carried; -9 dB output gain must not leak into
        // any Content Preset gain.
        XCTAssertEqual(try XCTUnwrap(imported.inputPreampDB), -2.0, accuracy: 1e-9)
        XCTAssertTrue(imported.warnings.contains { $0.contains("output-gain") && $0.contains("Playback System") },
                      "\(imported.warnings)")
    }

    // MARK: CamillaDSP

    func testCamillaDSPExportHasPipelineForBothChannelsAndWarnsOnOmittedLinkwitz() throws {
        var bands = shelvesAndPeak
        bands.append(EQBand(type: .linkwitzTransform, frequencyHz: 60, q: 0.9))
        let exported = try PresetInterchange.exportCamillaDSP(
            linkedStereo(bands),
            sampleRate: 96_000,
            playbackDeviceName: nil
        )
        let yaml = try XCTUnwrap(String(data: exported.data, encoding: .utf8))

        XCTAssertTrue(yaml.contains("samplerate: 96000"))
        XCTAssertTrue(yaml.contains("pipeline:"))
        XCTAssertTrue(yaml.contains("channels: [0]"))
        XCTAssertTrue(yaml.contains("channels: [1]"))
        XCTAssertTrue(yaml.contains("CHANGE_ME_CAPTURE"))
        XCTAssertTrue(yaml.contains("CHANGE_ME_PLAYBACK"))
        // Three biquads per channel; the Linkwitz Transform is omitted, not approximated.
        XCTAssertEqual(yaml.components(separatedBy: "type: Biquad\n").count - 1, 6)
        XCTAssertFalse(yaml.contains("Free"))
        XCTAssertTrue(exported.warnings.contains { $0.contains("Linkwitz Transform") && $0.contains("omitted") },
                      "\(exported.warnings)")
    }

    // MARK: Legacy native presets

    func testLegacyPresetSwapsPauseGateTimingKeepsBypassTransientAndWarns() throws {
        let legacy: [String: Any] = [
            "version": 2,
            "name": "Old Desk",
            "globalBypass": true,
            "channelMode": "linked",
            "bands": [
                ["filterType": 0, "frequency": 400.0, "gain": -2.0, "q": 1.2],
            ],
            "dynamics": [
                "pauseGate": [
                    "enabled": true,
                    "attackMs": 250.0,
                    "releaseMs": 40.0,
                ] as [String: Any],
            ] as [String: Any],
        ]
        var base = StereoEQConfiguration()
        base.bypassed = true
        let imported = try PresetInterchange.importPreset(
            data: try JSONSerialization.data(withJSONObject: legacy),
            fileName: "Old Desk.eqpreset",
            baseStereo: base
        )

        XCTAssertFalse(imported.stereoEQ.bypassed, "Global Bypass is transient and must not be restored")
        XCTAssertEqual(imported.suggestedName, "Old Desk")
        assertBandsMatch(imported.stereoEQ.linkedBands, [EQBand(type: .peaking, frequencyHz: 400, gainDB: -2, q: 1.2)])

        let gate = try XCTUnwrap(imported.dynamics?.pauseGate)
        XCTAssertTrue(gate.enabled)
        XCTAssertEqual(gate.releaseMs, 250, accuracy: 1e-9, "legacy Attack (open) maps to commercial Release")
        XCTAssertEqual(gate.attackMs, 40, accuracy: 1e-9, "legacy Release (close) maps to commercial Attack")

        XCTAssertTrue(imported.warnings.contains { $0.contains("Global Bypass") })
        XCTAssertTrue(imported.warnings.contains { $0.contains("Pause Gate") })
        XCTAssertTrue(imported.warnings.contains { $0.contains("Constant-Q and Linkwitz") })
    }

    func testLegacyV1PresetMigratesBandwidthAndActiveBandCount() throws {
        let legacy: [String: Any] = [
            "version": 1,
            "activeBandCount": 1,
            "bands": [
                ["filterType": 0, "frequency": 100.0, "gain": 3.0, "bandwidth": 1.0],
                ["filterType": 0, "frequency": 2_000.0, "gain": -3.0, "bandwidth": 1.0],
            ],
        ]
        let imported = try PresetInterchange.importPreset(
            data: try JSONSerialization.data(withJSONObject: legacy),
            fileName: "V1.eqpreset",
            baseStereo: StereoEQConfiguration()
        )
        let bands = imported.stereoEQ.linkedBands
        XCTAssertEqual(bands.count, 2)
        XCTAssertTrue(bands[0].enabled)
        XCTAssertFalse(bands[1].enabled, "bands past activeBandCount stay disabled")
        // One octave: Q = sqrt(2) / (2 - 1).
        XCTAssertEqual(bands[0].q, 2.0.squareRoot(), accuracy: 1e-9)
    }
}
