import XCTest
@testable import NotchSixty

/// E33 S11c part 3: band edits and group lists design their linear-phase FIRs off the main actor (G97, G98), and "Bypass
/// rack" is session-only (G84, owner decision 20 Nov 2026).
@MainActor
final class E33ShipC3Tests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "e33-c3", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "e33-c3")
        return engine
    }

    private func linear(bands: [EQBand]) -> StereoEQConfiguration {
        var configuration = StereoEQConfiguration(linkedBands: bands)
        configuration.phaseMode = .linearPhase
        return configuration
    }

    func testBandEditAtLinearPhaseDesignsOffMainAndLands() async throws {
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 2, q: 1)
            try engine.replaceStereoEQConfiguration(linear(bands: [band]))
            XCTAssertTrue(engine.eqEditDesignsOffMain)
            var edited = band
            edited.gainDB = -3
            try await engine.updateEQBandOffMain(edited)
            XCTAssertEqual(engine.stereoEQConfiguration.editableBands.first?.gainDB, -3, "\(rate)")
            // With no running session there is no rate to design for, so the edit applies without a design (a session's
            // cache hit is covered by `EQLinearPhaseHardeningTests` and the group-list case below).
            XCTAssertNil(engine.eqOffMain.pending)
        }
    }

    func testTwoQuickEditsToDifferentBandsBothLand() async throws {
        let engine = try engine(rate: 48_000)
        let a = EQBand(type: .peaking, frequencyHz: 500, gainDB: 1, q: 1)
        let b = EQBand(type: .peaking, frequencyHz: 4_000, gainDB: 1, q: 1)
        try engine.replaceStereoEQConfiguration(linear(bands: [a, b]))
        var editedA = a; editedA.gainDB = -4
        var editedB = b; editedB.gainDB = 5
        let a2 = editedA, b2 = editedB
        async let first: Void = engine.updateEQBandOffMain(a2)
        async let second: Void = engine.updateEQBandOffMain(b2)
        _ = try await (first, second)
        let gains = Dictionary(uniqueKeysWithValues: engine.stereoEQConfiguration.editableBands.map { ($0.id, $0.gainDB) })
        XCTAssertEqual(gains[a.id], -4)
        XCTAssertEqual(gains[b.id], 5)
    }

    func testEditWithoutLinearPhaseIsTheSynchronousPath() throws {
        let engine = try engine(rate: 48_000)
        try engine.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [EQBand()]))
        XCTAssertFalse(engine.eqEditDesignsOffMain)
    }

    func testGroupListsDesignOnceOffMainThenTheGraphBuildHitsTheCache() async throws {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        for rate in Self.rates {
            var eq = linear(bands: [EQBand(type: .peaking, frequencyHz: 900, gainDB: 1.5 + rate / 1e6, q: 1)])
            eq.setGroupBands([EQBand(type: .peaking, frequencyHz: 200, gainDB: -4, q: 1)], for: .centre, roleCodes: shape.roleCodes)
            let configuration = eq
            let before = EQGroupFIRCache.shared.designCount
            try await Task.detached { _ = try configuration.groupCurves(shape: shape, sampleRate: rate) }.value
            let designed = EQGroupFIRCache.shared.designCount
            XCTAssertGreaterThan(designed, before, "\(rate)")
            let curves = try configuration.groupCurves(shape: shape, sampleRate: rate)
            XCTAssertEqual(EQGroupFIRCache.shared.designCount, designed, "the rebuild designs nothing at \(rate)")
            XCTAssertFalse(curves.isEmpty)
        }
    }

    // MARK: G84

    private func rack(bypassed: [Bool]) -> AudioUnitRackConfiguration {
        var configuration = AudioUnitRackConfiguration()
        configuration.slots = bypassed.enumerated().map { index, flag in
            AudioUnitRackSlotState(
                component: AudioUnitComponentIdentity(
                    componentType: 0x61756678, componentSubType: UInt32(index + 1), componentManufacturer: 0x6e363073),
                displayName: "P\(index)", bypassed: flag, lastKnownLatencyFrames: 0)
        }
        return configuration
    }

    func testBypassRackIsSavedAsTheRackWasBeforeBypass() throws {
        let original = rack(bypassed: [false, true])
        let host = AudioUnitHostController(rackConfiguration: original)
        XCTAssertEqual(host.presetRackConfiguration, original)
        let result = AudioUnitRackBypass.bypassing(original)
        try host.replaceRackConfiguration(result.configuration)
        host.rememberRackBypass(saved: result.saved)
        XCTAssertTrue(AudioUnitRackBypass.isBypassed(host.rackConfiguration))
        XCTAssertEqual(host.presetRackConfiguration, original, "the Content Preset does not store the session bypass")
        // Switching a slot back on by hand ends the session bypass; the preset then saves the rack as it is.
        var partial = result.configuration
        partial.slots[0].bypassed = false
        try host.replaceRackConfiguration(partial)
        XCTAssertTrue(host.rackBypassSaved.isEmpty)
        XCTAssertEqual(host.presetRackConfiguration, partial)
    }

    func testRackBypassedByHandIsSavedBypassed() throws {
        let hand = rack(bypassed: [true, true])
        let host = AudioUnitHostController(rackConfiguration: hand)
        XCTAssertEqual(host.presetRackConfiguration, hand)
    }
}
