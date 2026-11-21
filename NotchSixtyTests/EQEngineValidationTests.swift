import XCTest
@testable import NotchSixty

/// E32 S2: the engine gate is `EQBandRules`; imports clamp to it; a band drag is live parameter
/// posts, not rebuilds; the headroom predictor shares the page's compiled-response cache.
@MainActor
final class EQEngineValidationTests: XCTestCase {

    // E33 S11d: these cases pin today's (flag off) rules: 20 Hz floor, three-band multiband, no detector change. The
    // graduated default is covered by `E33GraduationTests` and the E33 end-to-end classes.
    private let e33Flags = FeatureFlags()
    override func setUp() {
        super.setUp()
        e33Flags.setEnabled(false, for: .eqPageEnhancements)
    }
    override func tearDown() {
        e33Flags.resetOverrides()
        super.tearDown()
    }
    private let rates = EQRenderHarness.rates

    private func dynamicBand(_ type: EQFilterType, gain: Double = 4) -> EQBand {
        var band = EQBand(type: type, frequencyHz: 1_000, gainDB: type == .notch ? 0 : gain, q: 1)
        band.dynamic.enabled = true
        band.dynamic.thresholdDB = 0
        return band
    }

    // MARK: Refusal

    func testEngineRefusesValuesOutsideTheRuleAndAcceptsInsideValues() throws {
        let engine = AudioIOEngine()
        let outside: [(String, EQBand)] = [
            ("low frequency", EQBand(type: .peaking, frequencyHz: 4, gainDB: 0, q: 1)),
            ("high frequency", EQBand(type: .peaking, frequencyHz: 200_000, gainDB: 0, q: 1)),
            ("gain", EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 30, q: 1)),
            ("low Q", EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 0.05)),
            ("high Q", EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 25)),
            ("NaN", EQBand(type: .peaking, frequencyHz: .nan, gainDB: 0, q: 1)),
        ]
        for (label, band) in outside {
            XCTAssertThrowsError(try engine.addEQBand(band), label)
            XCTAssertThrowsError(try engine.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [band])), label)
        }
        XCTAssertNoThrow(try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 5, gainDB: -24, q: 1)))
        XCTAssertNoThrow(try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 20, gainDB: -24, q: 0.1)))
        XCTAssertThrowsError(try engine.addEQBand(EQBand(type: .tilt, frequencyHz: 10, gainDB: 0, q: 0.7)), "tilt keeps 20 Hz")
        XCTAssertNoThrow(try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 192_000, gainDB: 24, q: 20)))
    }

    func testABoostingDynamicNotchIsRefusedAndACuttingOneIsAccepted() throws {
        let engine = AudioIOEngine()
        var notch = dynamicBand(.notch)
        notch.dynamic.direction = .boostOnly
        XCTAssertThrowsError(try engine.addEQBand(notch))
        notch.dynamic.direction = .both
        XCTAssertThrowsError(try engine.addEQBand(notch))
        notch.dynamic.direction = .cutOnly
        XCTAssertNoThrow(try engine.addEQBand(notch))
    }

    func testEveryDynamicTypeAppliesWithDynamicsOnAndRendersItsStaticResponseAtRestAtEveryRate() throws {
        for type in EQFilterType.allCases where type.supportsDynamicEQ {
            let engine = AudioIOEngine()
            XCTAssertNoThrow(try engine.addEQBand(dynamicBand(type)), "\(type) applies")
            for rate in rates {
                let band = dynamicBand(type)
                var staticBand = band
                staticBand.dynamic.enabled = false
                let eq = StereoEQConfiguration(linkedBands: [band])
                let host = try UnifiedGraphHost(spec: EQRenderHarness.spec(eq, rate: rate))
                let amplitude: Float = 1e-3
                let length = 16_384
                var response: [Float] = []
                var position = 0
                while position < length {
                    let chunk = (0..<EQRenderHarness.block).map { position + $0 == 0 ? amplitude : 0 }
                    response += try host.processOffline(input: [chunk, chunk], frames: EQRenderHarness.block)[0]
                    position += EQRenderHarness.block
                }
                let analysis = EQFilterAnalysis(bands: [staticBand], phaseMode: .minimumPhase, sampleRate: rate)
                for frequency in [100.0, 1_000, 5_000] where frequency < rate * 0.4 && !(type == .notch && frequency == 1_000) {
                    let omega = 2 * Double.pi * frequency / rate
                    var re = 0.0, im = 0.0
                    for (n, value) in response.enumerated() {
                        re += Double(value) * cos(omega * Double(n))
                        im -= Double(value) * sin(omega * Double(n))
                    }
                    let measured = 20 * log10(hypot(re, im) / Double(amplitude))
                    XCTAssertEqual(measured, analysis.magnitudeDB(at: frequency), accuracy: 0.05,
                                   "\(type) at \(frequency) Hz, \(rate) Hz")
                }
            }
        }
    }

    // MARK: Import

    func testImportClampsToTheRuleAndReportsWhatItChanged() throws {
        let text = "Filter 1: ON PK Fc 5 Hz Gain 40 dB Q 0.01\nFilter 2: ON PK Fc 1000 Hz Gain 3 dB Q 2\n"
        let imported = try PresetInterchange.importPreset(
            data: Data(text.utf8), fileName: "rew.txt", baseStereo: StereoEQConfiguration())
        let bands = imported.stereoEQ.editableBands
        XCTAssertEqual(bands[0].frequencyHz, 20)
        XCTAssertEqual(bands[0].gainDB, EQBandRules.gainRange.upperBound)
        XCTAssertEqual(bands[0].q, 0.1)
        XCTAssertEqual(bands[1].frequencyHz, 1_000)
        let note = try XCTUnwrap(imported.warnings.first { $0.contains("band 1") })
        XCTAssertTrue(note.contains("frequency"), note)  // the REW parser already clamps gain and Q itself
        XCTAssertFalse(imported.warnings.contains { $0.contains("band 2") })
        XCTAssertNoThrow(try AudioIOEngine().replaceStereoEQConfiguration(imported.stereoEQ))
    }

    // MARK: Drag

    func testAThirtyStepDragIsThirtyLivePostsAndNeverRebuildsOrDipsAtEveryRate() throws {
        for rate in rates {
            let steps = 30
            func eq(_ step: Int) -> StereoEQConfiguration {
                let t = Double(step) / Double(steps)
                let moving = EQBand(type: .peaking, frequencyHz: 6_000 * pow(2, t), gainDB: 6 * t, q: 4)
                let fixed = EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 2, q: 0.707)
                return StereoEQConfiguration(linkedBands: [fixed, moving])
            }
            // Auto preamp rides the same publish: the preamp changes with the gain, in the same spec.
            func spec(_ step: Int) throws -> UnifiedGraphSpec {
                try EQRenderHarness.spec(eq(step), rate: rate, preampDB: -6 * Double(step) / Double(steps))
            }
            let host = try UnifiedGraphHost(spec: spec(0))
            let block = EQRenderHarness.block
            let frequency = 1_000.0
            var position = 0
            var levels: [Double] = []
            func run(frames: Int) throws {
                var window: [Float] = []
                let end = position + (frames / block + 1) * block
                while position < end {
                    let chunk = (0..<block).map { 0.5 * Float(sin(2 * Double.pi * frequency * Double(position + $0) / rate)) }
                    window += try host.processOffline(input: [chunk, chunk], frames: block)[0]
                    position += block
                }
                levels.append(EQRenderHarness.rms(window[(window.count / 2)...]))
            }
            try run(frames: Int(rate * 0.1))
            var posts = 0, rebuilds = 0
            for step in 1...steps {
                switch try host.apply(spec(step), linearFade: true) {
                case .posted: posts += 1
                case .published: rebuilds += 1
                case .unchanged: break
                }
                try run(frames: Int(rate * 0.033))
            }
            XCTAssertEqual(rebuilds, 0, "a parameter-only drag rebuilds nothing at \(rate)")
            XCTAssertEqual(posts, steps, "one live post per step at \(rate)")
            // The preamp is part of the posts, so the tone follows the preamp; the level must move
            // monotonically toward its end (within 0.1 dB), never dip below the running minimum.
            let db = levels.map { 20 * log10($0) }
            for index in 1..<db.count {
                XCTAssertGreaterThanOrEqual(db[index], db[index - 1] - 6.0 / Double(steps) - 0.1,
                                            "step \(index) dips at \(rate)")
            }
        }
    }

    // MARK: Cache sharing

    func testHeadroomPredictorCompilesThroughTheSharedCacheAndMatchesTheUncachedAnswer() {
        let cache = EQResponseCache()
        let bands = [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)]
        let eq = StereoEQConfiguration(linkedBands: bands)
        for rate in rates {
            // The page compiles the lane first; the predictor then reuses that entry.
            _ = cache.program(bands: bands, sampleRate: rate)
            let before = cache.compileCount
            let cached = EQHeadroomPredictor.predict(configuration: eq, sampleRate: rate) { cache.program(bands: $0, sampleRate: $1) }
            XCTAssertEqual(cache.compileCount, before, "no second compile at \(rate)")
            XCTAssertEqual(cached, EQHeadroomPredictor.predict(configuration: eq, sampleRate: rate))
        }
    }
}
