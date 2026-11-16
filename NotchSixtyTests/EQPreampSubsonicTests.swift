import XCTest
@testable import NotchSixty

/// E33 S3: the one preamp model (design 6) and the 5 Hz floor (design 3).
@MainActor
final class EQPreampModelTests: XCTestCase {
    private func make() -> (AudioIOEngine, EQAutoPreampController) {
        let engine = AudioIOEngine()
        return (engine, EQAutoPreampController(engine: engine))
    }

    private func peaking(_ gain: Double) -> EQBand { EQBand(type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1) }

    func testEveryCombinationOfTermsGivesTheClampedSumAndOneWrite() throws {
        let (engine, auto) = make()
        var writes: [Double] = []
        auto.preampWriter = { value in writes.append(value); try engine.setInputPreampDB(value) }
        let manuals = [-70.0, -3.0, 0, 5, 30]
        let autos = [0.0, -0.1, -9.0, -40]
        let matches = [0.0, -1.5, -20]
        for manual in manuals {
            for autoTrim in autos {
                for match in matches {
                    writes.removeAll()
                    try auto.preamp.setAuto(on: autoTrim != 0, trimDB: autoTrim)
                    try auto.preamp.setMatch(match)
                    try auto.preamp.setManual(manual)
                    let range = DSPGainConfiguration.inputPreampRange
                    let expected = min(max(min(max(manual, range.lowerBound), range.upperBound) + autoTrim + match, range.lowerBound), range.upperBound)
                    XCTAssertEqual(engine.gainConfiguration.inputPreampDB, expected, accuracy: 1e-9,
                                   "\(manual) \(autoTrim) \(match)")
                    XCTAssertEqual(EQPreampModel.total(manualDB: auto.preamp.manualDB, autoTrimDB: auto.preamp.autoTrimDB,
                                                       matchDB: auto.preamp.matchDB), expected, accuracy: 1e-9)
                    XCTAssertLessThanOrEqual(writes.count, 3)
                    writes.removeAll()
                    try auto.preamp.setManual(manual)
                    XCTAssertTrue(writes.isEmpty, "an unchanged total is not published again")
                }
            }
        }
    }

    func testOneChangeIsOnePublish() throws {
        let (engine, auto) = make()
        try engine.addEQBand(peaking(9))
        var writes = 0
        auto.preampWriter = { value in writes += 1; try engine.setInputPreampDB(value) }
        try auto.setOn(true)
        XCTAssertEqual(writes, 1)
        try auto.applyMatch(trimDB: -2)
        XCTAssertEqual(writes, 2)
        try auto.setManual(-3)
        XCTAssertEqual(writes, 3)
        auto.reconcile()
        XCTAssertEqual(writes, 3, "reconcile with nothing changed publishes nothing")
    }

    func testABMatchThenAutoOnAndOffReturnsToTheManualValue() throws {
        let (engine, auto) = make()
        try engine.setInputPreampDB(-2)
        try engine.addEQBand(peaking(6))
        auto.reconcile()
        try auto.applyMatch(trimDB: -1.5)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3.5, accuracy: 1e-9)
        try auto.setOn(true)
        let attenuation = EQAutoPreamp.attenuationDB(forBoost: auto.prediction.boostDB)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -2 - attenuation - 1.5, accuracy: 1e-9)
        XCTAssertEqual(auto.preamp.manualDB, -2, accuracy: 1e-12)
        try auto.setOn(false)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3.5, accuracy: 1e-9)
        try auto.applyMatch(trimDB: 0)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -2, accuracy: 1e-9, "back to the manual value")
        XCTAssertEqual(auto.preamp.manualDB, -2, accuracy: 1e-12)
    }

    func testAnOutsideWriteBecomesTheManualTermWhileAutoIsOff() throws {
        let (engine, auto) = make()
        try auto.applyMatch(trimDB: -1)
        try engine.setInputPreampDB(-6)
        auto.reconcile()
        XCTAssertEqual(auto.preamp.manualDB, -5, accuracy: 1e-9, "the engine value less the match trim")
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -6, accuracy: 1e-9)
    }

    func testOldProfileStoredPreampBecomesTheManualValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ProductProfileController(engine: AudioIOEngine(), storageURL: root.appendingPathComponent("p.json"))
        let decoded = ContentPresetState(inputPreampDB: -4.5)
        XCTAssertFalse(decoded.autoPreampEnabled)
        try profiles.applyContentStateWithoutAudioUnitRack(decoded)
        XCTAssertEqual(profiles.autoPreamp.preamp.manualDB, -4.5, accuracy: 1e-9)
        XCTAssertEqual(profiles.captureContentState().inputPreampDB, -4.5, accuracy: 1e-9)
    }

    func testImportedPreampIsAppliedAsTheManualTerm() throws {
        let (engine, auto) = make()
        try auto.setManual(-6.4)
        XCTAssertEqual(auto.preamp.manualDB, -6.4, accuracy: 1e-12)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -6.4, accuracy: 1e-9)
    }

    func testFailedWriteIsReportedAndRetried() throws {
        let (engine, auto) = make()
        struct Injected: Error {}
        var fail = true
        auto.preampWriter = { value in if fail { throw Injected() } else { try engine.setInputPreampDB(value) } }
        XCTAssertThrowsError(try auto.setManual(-3))
        fail = false
        try auto.setManual(-3)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3, accuracy: 1e-9)
    }
}

final class EQSubsonicRuleTests: XCTestCase {
    func testFloorIsFiveHertzForPEQTypesOnlyWhenSubsonicAndTwentyOtherwise() {
        for type in EQFilterType.allCases {
            XCTAssertEqual(EQBandRules.minimumFrequency(for: type, subsonic: false), 20)
        }
        for type in [EQFilterType.peaking, .lowShelf, .highShelf, .lowPass, .highPass, .notch, .allPass, .bandPass] {
            XCTAssertEqual(EQBandRules.minimumFrequency(for: type, subsonic: true), 5, "\(type)")
        }
        for type in [EQFilterType.linkwitzTransform, .tilt, .fir] {
            XCTAssertEqual(EQBandRules.minimumFrequency(for: type, subsonic: true), 20, "\(type)")
        }
    }

    func testSanitizedClampsToTheChosenFloorAndDynamicBandsKeepTwentyHertz() {
        let low = EQBand(type: .peaking, frequencyHz: 2, gainDB: 3, q: 1)
        XCTAssertEqual(EQBandRules.sanitized(low, sampleRate: 48_000, subsonic: true).frequencyHz, 5)
        XCTAssertEqual(EQBandRules.sanitized(low, sampleRate: 48_000, subsonic: false).frequencyHz, 20)
        var dynamic = low
        dynamic.dynamic.enabled = true
        XCTAssertEqual(EQBandRules.sanitized(dynamic, sampleRate: 48_000, subsonic: true).frequencyHz,
                       DynamicEQBandConfiguration.frequencyRange.lowerBound)
        let tilt = EQBand(type: .tilt, frequencyHz: 8, gainDB: 3, q: 1)
        XCTAssertEqual(EQBandRules.sanitized(tilt, sampleRate: 48_000, subsonic: true).frequencyHz, 20)
    }

    func testEngineRuleAcceptsFiveHertzForPEQTypesButNotBelow() {
        XCTAssertNil(EQBandRules.invalidReason(EQBand(type: .highPass, frequencyHz: 5, gainDB: 0, q: 0.707)))
        XCTAssertNotNil(EQBandRules.invalidReason(EQBand(type: .highPass, frequencyHz: 4.9, gainDB: 0, q: 0.707)))
        XCTAssertNotNil(EQBandRules.invalidReason(EQBand(type: .tilt, frequencyHz: 10, gainDB: 0, q: 0.707)))
    }

    func testSubsonicNote() {
        var band = EQBand(type: .peaking, frequencyHz: 10, gainDB: 3, q: 1)
        XCTAssertEqual(EQSubsonicNote.note(for: band), "Subsonic. \(EQSubsonicNote.boostWarning)")
        band.gainDB = -3
        XCTAssertEqual(EQSubsonicNote.note(for: band), "Subsonic")
        band.frequencyHz = 20
        XCTAssertNil(EQSubsonicNote.note(for: band))
    }

    func testSubsonicZoomStartsAtFiveHertz() {
        let geometry = EQGraphGeometry(sampleRate: 48_000, zoom: .subsonic)
        XCTAssertEqual(geometry.minimumFrequency, 5)
        XCTAssertEqual(geometry.x(frequency: 5, width: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(EQGraphGeometry(sampleRate: 48_000, zoom: .full).minimumFrequency, 20)
    }

    /// The textbook peaking response (Audio EQ Cookbook, bilinear transform) in double precision.
    private static func idealPeakingDB(_ f: Double, centre: Double, gainDB: Double, q: Double, rate: Double) -> Double {
        let a = pow(10, gainDB / 40), w0 = 2 * Double.pi * centre / rate, alpha = sin(w0) / (2 * q)
        let b = [1 + alpha * a, -2 * cos(w0), 1 - alpha * a], d = [1 + alpha / a, -2 * cos(w0), 1 - alpha / a]
        let w = 2 * Double.pi * f / rate
        func mag(_ c: [Double]) -> Double {
            let re = c[0] + c[1] * cos(w) + c[2] * cos(2 * w), im = -(c[1] * sin(w) + c[2] * sin(2 * w))
            return hypot(re, im)
        }
        return 20 * log10(mag(b) / mag(d))
    }

    /// A 5 Hz peaking band through the published graph matches the ideal response at the eight rates.
    /// (E33 G12: the drawn curve, `EQFilterAnalysis`, does not match it at 2 to 10 Hz; see the epic's gaps.)
    func testFiveHertzPeakingBandRendersLikeTheCurveAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            for gain in [12.0, -12.0] {
                let band = EQBand(type: .peaking, frequencyHz: 5, gainDB: gain, q: 1)
                let spec = try EQRenderHarness.spec(StereoEQConfiguration(linkedBands: [band]), rate: rate)
                let host = try UnifiedGraphHost(spec: spec)
                let warmup = Int(rate * 0.1)
                let length = warmup + Int(rate * 3.5)
                // A quiet impulse: a full-scale one trips the output protection and skews the measurement.
                var response: [Float] = []
                response.reserveCapacity(length)
                var position = 0
                while position < length {
                    let chunk = (0..<EQRenderHarness.block).map { Float($0 + position == warmup ? 0.05 : 0) }
                    response += try host.processOffline(input: [chunk, chunk], frames: EQRenderHarness.block)[0]
                    position += EQRenderHarness.block
                }
                let h = Array(response[warmup...])
                for frequency in [2.0, 5, 10, 20, 100] {
                    var re = 0.0, im = 0.0
                    let w = 2 * Double.pi * frequency / rate
                    for (n, value) in h.enumerated() {
                        re += Double(value) * 20 * cos(w * Double(n))
                        im -= Double(value) * 20 * sin(w * Double(n))
                    }
                    XCTAssertEqual(20 * log10(hypot(re, im)), Self.idealPeakingDB(frequency, centre: 5, gainDB: gain, q: 1, rate: rate), accuracy: 0.1,
                                   "\(frequency) Hz, \(gain) dB at \(rate)")
                }
            }
        }
    }
}
