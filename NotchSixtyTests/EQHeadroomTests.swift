import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class EQHeadroomTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func peaking(_ frequency: Double = 1_000, gain: Double = 6, q: Double = 1.4) -> EQBand {
        EQBand(type: .peaking, frequencyHz: frequency, gainDB: gain, q: q)
    }

    private func linked(_ bands: [EQBand]) -> StereoEQConfiguration {
        StereoEQConfiguration(channelMode: .linked, editChannel: .linked, linkedBands: bands)
    }

    // MARK: Independent reference

    /// H(e^jw) of a cascade by direct evaluation of the coefficients, in the test's own code.
    private func reference(_ bands: [EQBand], rate: Double, frequency: Double) -> (re: Double, im: Double) {
        let omega = 2 * Double.pi * frequency / rate
        var re = 1.0, im = 0.0
        for band in bands where band.enabled {
            for section in try! band.compiledSections(sampleRate: rate) {
                let c = section.coefficients
                let nr = Double(c.b0) + Double(c.b1) * cos(omega) + Double(c.b2) * cos(2 * omega)
                let ni = -Double(c.b1) * sin(omega) - Double(c.b2) * sin(2 * omega)
                let dr = 1 + Double(c.a1) * cos(omega) + Double(c.a2) * cos(2 * omega)
                let di = -Double(c.a1) * sin(omega) - Double(c.a2) * sin(2 * omega)
                let d = dr * dr + di * di
                let hr = (nr * dr + ni * di) / d
                let hi = (ni * dr - nr * di) / d
                (re, im) = (re * hr - im * hi, re * hi + im * hr)
            }
        }
        return (re, im)
    }

    // MARK: Predictor

    func testSinglePeakingMatchesAnalyticPeakAtEveryRate() {
        for rate in rates {
            let prediction = EQHeadroomPredictor.predict(configuration: linked([peaking()]), sampleRate: rate)
            XCTAssertEqual(prediction.peakGainDB, 6, accuracy: 0.05, "rate \(rate)")
            XCTAssertEqual(prediction.frequencyHz, 1_000, accuracy: 1, "rate \(rate)")
            XCTAssertEqual(prediction.boostDB, prediction.peakGainDB, accuracy: 1e-12)
            XCTAssertFalse(prediction.omitsFIRBands)
        }
    }

    func testStackedBandsAddAtEveryRate() {
        for rate in rates {
            let stacked = linked([peaking(gain: 6), peaking(gain: 6), peaking(gain: 3)])
            let prediction = EQHeadroomPredictor.predict(configuration: stacked, sampleRate: rate)
            XCTAssertEqual(prediction.peakGainDB, 15, accuracy: 0.15, "rate \(rate)")
        }
    }

    func testShelfPeakIsItsPlateau() {
        for rate in rates {
            let shelf = EQBand(type: .highShelf, frequencyHz: 4_000, gainDB: 5, q: 0.707)
            let prediction = EQHeadroomPredictor.predict(configuration: linked([shelf]), sampleRate: rate)
            // The plateau runs to the top of the grid, 0.49 fs; the shelf is still within 0.5 dB of 5 dB.
            XCTAssertEqual(prediction.peakGainDB, 5, accuracy: 0.5, "rate \(rate)")
        }
    }

    func testCutsNeedNoPreamp() {
        let prediction = EQHeadroomPredictor.predict(
            configuration: linked([peaking(gain: -9), peaking(2_000, gain: -3)]),
            sampleRate: 48_000
        )
        XCTAssertLessThan(prediction.peakGainDB, 0.05)
        XCTAssertEqual(prediction.boostDB, max(0, prediction.peakGainDB), accuracy: 1e-12)
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: prediction.boostDB), 0, accuracy: 0.1 + 1e-9)
    }

    func testBypassedAndEmptyPredictNothing() {
        XCTAssertEqual(EQHeadroomPredictor.predict(configuration: StereoEQConfiguration(), sampleRate: 48_000).boostDB, 0)
        var bypassed = linked([peaking(gain: 12)])
        bypassed.bypassed = true
        XCTAssertEqual(EQHeadroomPredictor.predict(configuration: bypassed, sampleRate: 48_000), .none)
        var disabled = peaking(gain: 12)
        disabled.enabled = false
        XCTAssertEqual(EQHeadroomPredictor.predict(configuration: linked([disabled]), sampleRate: 48_000).boostDB, 0, accuracy: 1e-9)
    }

    func testIndependentTakesTheLargerLane() {
        let configuration = StereoEQConfiguration(
            channelMode: .independent, editChannel: .left,
            leftBands: [peaking(500, gain: 4)], rightBands: [peaking(3_000, gain: 9)]
        )
        for rate in rates {
            let prediction = EQHeadroomPredictor.predict(configuration: configuration, sampleRate: rate)
            XCTAssertEqual(prediction.peakGainDB, 9, accuracy: 0.05, "rate \(rate)")
            XCTAssertEqual(prediction.frequencyHz, 3_000, accuracy: 1)
        }
    }

    func testMidSideWorstCaseMatchesTheOutputFormula() {
        // Different centres put the two lanes out of phase between them, where the worst case
        // for an output exceeds the larger lane.
        let mid = [peaking(1_000, gain: 6, q: 4)]
        let side = [peaking(1_200, gain: 6, q: 4)]
        let configuration = StereoEQConfiguration(
            channelMode: .midSide, editChannel: .mid, midBands: mid, sideBands: side
        )
        for rate in rates {
            let prediction = EQHeadroomPredictor.predict(configuration: configuration, sampleRate: rate)
            var expected = 0.0
            for frequency in EQHeadroomPredictor.grid(sampleRate: rate, bandCentres: [1_000, 1_200]) {
                let m = reference(mid, rate: rate, frequency: frequency)
                let s = reference(side, rate: rate, frequency: frequency)
                let sum = hypot(m.re + s.re, m.im + s.im)
                let difference = hypot(m.re - s.re, m.im - s.im)
                expected = max(expected, (sum + difference) / 2)
            }
            XCTAssertEqual(prediction.peakGainDB, 20 * log10(expected), accuracy: 1e-6, "rate \(rate)")
            let larger = max(
                EQHeadroomPredictor.predict(configuration: linked(mid), sampleRate: rate).peakGainDB,
                EQHeadroomPredictor.predict(configuration: linked(side), sampleRate: rate).peakGainDB
            )
            XCTAssertGreaterThanOrEqual(prediction.peakGainDB, larger - 1e-9, "rate \(rate)")
        }
    }

    func testMidSideEqualLanesEqualLinked() {
        let band = [peaking(2_000, gain: 7)]
        let ms = StereoEQConfiguration(channelMode: .midSide, editChannel: .mid, midBands: band, sideBands: band)
        for rate in rates {
            XCTAssertEqual(
                EQHeadroomPredictor.predict(configuration: ms, sampleRate: rate).peakGainDB,
                EQHeadroomPredictor.predict(configuration: linked(band), sampleRate: rate).peakGainDB,
                accuracy: 1e-9
            )
        }
    }

    func testDynamicBandsAreTakenAtTheirUpwardLimit() {
        var dynamic = peaking(gain: 3)
        dynamic.dynamic.enabled = true
        dynamic.dynamic.direction = .cutOnly
        dynamic.dynamic.maxBoostDB = 6
        XCTAssertEqual(EQHeadroomPredictor.predict(configuration: linked([dynamic]), sampleRate: 48_000).peakGainDB, 3, accuracy: 0.05)
        for direction in [DynamicEQDirection.boostOnly, .both] {
            dynamic.dynamic.direction = direction
            for rate in rates {
                XCTAssertEqual(
                    EQHeadroomPredictor.predict(configuration: linked([dynamic]), sampleRate: rate).peakGainDB,
                    9, accuracy: 0.1, "\(direction) at \(rate)"
                )
            }
        }
        dynamic.dynamic.enabled = false
        XCTAssertEqual(EQHeadroomPredictor.predict(configuration: linked([dynamic]), sampleRate: 48_000).peakGainDB, 3, accuracy: 0.05)
    }

    func testFIRBandsAreFlaggedNotCounted() {
        let fir = EQBand(type: .fir, frequencyHz: 1_000, gainDB: 0, q: 1)
        let prediction = EQHeadroomPredictor.predict(configuration: linked([fir, peaking(gain: 4)]), sampleRate: 48_000)
        XCTAssertTrue(prediction.omitsFIRBands)
        XCTAssertEqual(prediction.peakGainDB, 4, accuracy: 0.05)
    }

    /// Time-domain confirmation at the eight rates (the lab case of the plan, without the engine):
    /// a -1 dBFS sine at the predicted frequency through +12 dB of EQ, with and without the
    /// auto preamp's attenuation. The engine-side render is gap G10.
    func testTimeDomainPeakAfterAutoPreampStaysUnderFullScaleAtEveryRate() {
        for rate in rates {
            let configuration = linked([peaking(1_000, gain: 12, q: 1.0)])
            let prediction = EQHeadroomPredictor.predict(configuration: configuration, sampleRate: rate)
            let sections = ProductionEQResponseMath.compile(bands: configuration.linkedBands, sampleRate: rate)
            let amplitude = pow(10, -1.0 / 20)

            let unprotected = steadyStatePeak(sections: sections, rate: rate, frequency: prediction.frequencyHz, amplitude: amplitude)
            XCTAssertGreaterThan(unprotected, 1, "without auto preamp the output clips at \(rate)")

            let preamp = EQAutoPreamp.preampDB(trimDB: 0, boostDB: prediction.boostDB)
            let protected = steadyStatePeak(
                sections: sections, rate: rate, frequency: prediction.frequencyHz,
                amplitude: amplitude * pow(10, preamp / 20)
            )
            XCTAssertLessThan(protected, 1, "with auto preamp the peak stays under 0 dBFS at \(rate)")
            XCTAssertEqual(20 * log10(unprotected / amplitude), prediction.peakGainDB, accuracy: 0.05, "rate \(rate)")
        }
    }

    private func steadyStatePeak(sections: [N60BiquadCoefficients], rate: Double, frequency: Double, amplitude: Double) -> Double {
        var state = [(x1: Double, x2: Double, y1: Double, y2: Double)](repeating: (0, 0, 0, 0), count: sections.count)
        let total = Int(rate * 0.6)
        var peak = 0.0
        for n in 0..<total {
            var value = amplitude * sin(2 * Double.pi * frequency * Double(n) / rate)
            for index in sections.indices {
                let c = sections[index]
                let s = state[index]
                let b0 = Double(c.b0), b1 = Double(c.b1), b2 = Double(c.b2)
                let a1 = Double(c.a1), a2 = Double(c.a2)
                var y = b0 * value
                y += b1 * s.x1
                y += b2 * s.x2
                y -= a1 * s.y1
                y -= a2 * s.y2
                state[index] = (value, s.x1, y, s.y1)
                value = y
            }
            if n > total / 2 { peak = max(peak, abs(value)) }
        }
        return peak
    }

    // MARK: Badge

    func testBadgeStates() {
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 6, preampDB: -6, headroomAttenuationDB: 0, clipTripped: false),
            .covered(boostDB: 6, marginDB: 0)
        )
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 6, preampDB: -4, headroomAttenuationDB: -3, clipTripped: false),
            .covered(boostDB: 6, marginDB: 1)
        )
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 6, preampDB: -2, headroomAttenuationDB: 0, clipTripped: false),
            .uncovered(boostDB: 6, shortfallDB: 4)
        )
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 0, preampDB: 0, headroomAttenuationDB: 0, clipTripped: false),
            .covered(boostDB: 0, marginDB: 0)
        )
        // Within the 0.05 dB tolerance still counts as covered; a clip beats every other state.
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 6.04, preampDB: -6, headroomAttenuationDB: 0, clipTripped: false),
            .covered(boostDB: 6.04, marginDB: 0)
        )
        XCTAssertEqual(
            EQHeadroomBadge.evaluate(boostDB: 0, preampDB: 0, headroomAttenuationDB: 0, clipTripped: true),
            .clipped
        )
    }

    func testClipMonitorWithPerReadCounts() {
        var monitor = EQClipMonitor()
        monitor.ingest(peakLinear: 0.5, overRangeSamples: 0, overRangeIsDelta: true, at: 0)
        XCTAssertFalse(monitor.isTripped(at: 0))
        monitor.ingest(peakLinear: 0.5, overRangeSamples: 3, overRangeIsDelta: true, at: 1)
        XCTAssertTrue(monitor.isTripped(at: 1))
        XCTAssertTrue(monitor.isTripped(at: 3))
        XCTAssertFalse(monitor.isTripped(at: 3.01))
        // A repeated count is a new event under per-read semantics.
        monitor.ingest(peakLinear: 0.5, overRangeSamples: 3, overRangeIsDelta: true, at: 10)
        XCTAssertTrue(monitor.isTripped(at: 11))
    }

    func testClipMonitorWithRunningTotal() {
        var monitor = EQClipMonitor()
        monitor.ingest(peakLinear: 0.1, overRangeSamples: 500, overRangeIsDelta: false, at: 0)
        XCTAssertFalse(monitor.isTripped(at: 0), "the first reading only sets the baseline")
        monitor.ingest(peakLinear: 0.1, overRangeSamples: 500, overRangeIsDelta: false, at: 1)
        XCTAssertFalse(monitor.isTripped(at: 1))
        monitor.ingest(peakLinear: 0.1, overRangeSamples: 501, overRangeIsDelta: false, at: 2)
        XCTAssertTrue(monitor.isTripped(at: 2))
        XCTAssertFalse(monitor.isTripped(at: 4.5))
    }

    func testClipMonitorPeakThresholdAndReset() {
        var monitor = EQClipMonitor()
        let belowThreshold = Float(pow(10, -0.2 / 20))
        let atThreshold = Float(pow(10, -0.05 / 20))
        monitor.ingest(peakLinear: belowThreshold, overRangeSamples: 0, overRangeIsDelta: true, at: 0)
        XCTAssertFalse(monitor.isTripped(at: 0))
        monitor.ingest(peakLinear: atThreshold, overRangeSamples: 0, overRangeIsDelta: true, at: 1)
        XCTAssertTrue(monitor.isTripped(at: 1))
        monitor.reset()
        XCTAssertFalse(monitor.isTripped(at: 1))
    }

    // MARK: Auto preamp rule

    func testAutoPreampRoundsTheBoostUpToTenthsAndKeepsTheTrim() {
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: 6.0), 6.0, accuracy: 1e-9)
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: 6.01), 6.1, accuracy: 1e-9)
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: 6.0000000001), 6.0, accuracy: 1e-9)
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: -3), 0)
        XCTAssertEqual(EQAutoPreamp.attenuationDB(forBoost: .nan), 0)
        XCTAssertEqual(EQAutoPreamp.preampDB(trimDB: -2, boostDB: 6.01), -8.1, accuracy: 1e-9)
        XCTAssertEqual(EQAutoPreamp.preampDB(trimDB: 3, boostDB: 0), 3, accuracy: 1e-9)
        XCTAssertEqual(EQAutoPreamp.preampDB(trimDB: -55, boostDB: 20), DSPGainConfiguration.inputPreampRange.lowerBound)
    }

    // MARK: Controller

    private func controller() -> (AudioIOEngine, EQAutoPreampController) {
        let engine = AudioIOEngine()
        return (engine, EQAutoPreampController(engine: engine))
    }

    func testAutoPreampFollowsEditsKeepsTheTrimAndIsIdempotent() throws {
        let (engine, auto) = controller()
        try engine.setInputPreampDB(-1)
        try auto.setOn(true)
        XCTAssertEqual(auto.trimDB, -1, accuracy: 1e-12, "turning it on adopts the current preamp as the trim")
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -1, accuracy: 1e-9)

        try engine.addEQBand(peaking(1_000, gain: 9, q: 1))
        auto.reconcile()
        let boost = EQHeadroomPredictor.predict(configuration: engine.stereoEQConfiguration, sampleRate: auto.sampleRate).boostDB
        XCTAssertEqual(boost, 9, accuracy: 0.05)
        let expected = -1 - EQAutoPreamp.attenuationDB(forBoost: boost)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, expected, accuracy: 1e-9)

        let before = engine.gainConfiguration
        auto.reconcile()
        auto.reconcile()
        XCTAssertEqual(engine.gainConfiguration, before)

        try auto.setTrim(-3)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3 - EQAutoPreamp.attenuationDB(forBoost: boost), accuracy: 1e-9)

        var band = try XCTUnwrap(engine.stereoEQConfiguration.editableBands.first)
        band.gainDB = 3
        try engine.updateEQBand(band)
        auto.reconcile()
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3 - 3.1, accuracy: 0.11)

        try engine.removeEQBand(id: band.id)
        auto.reconcile()
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3, accuracy: 1e-9, "no boost: preamp is the trim")

        try engine.addEQBand(peaking(1_000, gain: 6, q: 1))
        auto.reconcile()
        try auto.setOn(false)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3, accuracy: 1e-9, "off returns the preamp to the trim")
        try engine.addEQBand(peaking(2_000, gain: 6, q: 1))
        auto.reconcile()
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3, accuracy: 1e-9, "off never writes a gain")
    }

    // MARK: Profile

    func testOldProfilesDecodeAsOffAndZero() throws {
        let state = ContentPresetState(inputPreampDB: -2, autoPreampEnabled: true, preampTrimDB: -1.5)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(ContentPresetState.self, from: data), state)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "autoPreampEnabled")
        object.removeValue(forKey: "preampTrimDB")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ContentPresetState.self, from: old)
        XCTAssertFalse(decoded.autoPreampEnabled)
        XCTAssertEqual(decoded.preampTrimDB, 0)
        XCTAssertEqual(decoded.inputPreampDB, -2)
    }

    func testProfileCapturesAndRestoresToggleAndTrim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        XCTAssertFalse(profiles.captureContentState().autoPreampEnabled)

        let saved = ContentPresetState(inputPreampDB: -4, autoPreampEnabled: true, preampTrimDB: -1)
        try profiles.applyContentStateWithoutAudioUnitRack(saved)
        XCTAssertTrue(profiles.autoPreamp.isOn)
        XCTAssertEqual(profiles.autoPreamp.trimDB, -1)
        let captured = profiles.captureContentState()
        XCTAssertTrue(captured.autoPreampEnabled)
        XCTAssertEqual(captured.preampTrimDB, -1)

        try profiles.applyContentStateWithoutAudioUnitRack(ContentPresetState())
        XCTAssertFalse(profiles.autoPreamp.isOn)
        XCTAssertEqual(profiles.autoPreamp.trimDB, 0)
    }
}
