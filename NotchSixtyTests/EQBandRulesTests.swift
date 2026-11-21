import XCTest
@testable import NotchSixty

/// E32 S1: the one band rule and the surfaced-error paths.
@MainActor
final class EQBandRulesTests: XCTestCase {

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

    func testRenderStateAtEveryRateForBandsAtPoint49AndPoint5Fs() {
        for rate in rates {
            let below = EQBand(type: .peaking, frequencyHz: rate * 0.49, gainDB: 3, q: 1)
            let at = EQBand(type: .peaking, frequencyHz: rate * 0.5, gainDB: 3, q: 1)
            XCTAssertEqual(EQBandRules.renderState(below, sampleRate: rate), .active, "0.49 fs at \(rate)")
            XCTAssertEqual(EQBandRules.renderState(at, sampleRate: rate), .aboveNyquist(limitHz: rate * 0.5), "0.5 fs at \(rate)")
        }
    }

    func testEveryTypeIsActiveInBandAndEditsStayInside() {
        for type in EQFilterType.allCases where type != .fir {
            for rate in rates {
                var band = EQBand(type: type, frequencyHz: 1_000, gainDB: 0, q: 0.707)
                XCTAssertEqual(EQBandRules.renderState(band, sampleRate: rate), .active, "\(type) \(rate)")
                band.frequencyHz = 1e9
                band.q = 1e6
                band.gainDB = 1e3
                let clamped = EQBandRules.sanitized(band, sampleRate: rate)
                XCTAssertEqual(clamped.frequencyHz, rate * 0.49, accuracy: 1e-6, "\(type) \(rate)")
                XCTAssertEqual(clamped.q, 20, "\(type)")
                XCTAssertEqual(clamped.gainDB, EQBandRules.gainRange.upperBound, "\(type)")
                XCTAssertTrue(EQBandRules.renderState(clamped, sampleRate: rate).isActive, "\(type) \(rate)")
            }
        }
    }

    func testFloorsAreUnifiedAt20HzAndPoint1Q() {
        var band = EQBand(type: .peaking, frequencyHz: 1, gainDB: 0, q: 0.001)
        band = EQBandRules.sanitized(band, sampleRate: 48_000)
        XCTAssertEqual(band.frequencyHz, 20)
        XCTAssertEqual(band.q, 0.1)
        XCTAssertEqual(EQNudge.minimumFrequency, EQBandRules.minimumFrequency)
        XCTAssertEqual(EQNudge.qRange, EQBandRules.qRange)
        XCTAssertEqual(EQBandRules.maximumFrequency(sampleRate: 384_000), 384_000 * 0.49, accuracy: 1e-9)
        XCTAssertEqual(EQBandRules.maximumFrequency(sampleRate: 10), 20)
        XCTAssertEqual(EQBandRules.maximumFrequency(sampleRate: .nan), 20)
        // The parser clamps to the same floor.
        let parsed = EQValueParser.value(from: "1 Hz", field: .frequency, band: EQBand(), maximumFrequency: 20_000)
        XCTAssertEqual(parsed, 20)
    }

    func testNotchIsCutOnlyAndNonFiniteValuesFallBack() {
        var notch = EQBand(type: .notch, frequencyHz: 1_000, gainDB: 0, q: 2)
        notch.dynamic.enabled = true
        notch.dynamic.direction = .both
        XCTAssertEqual(EQBandRules.sanitized(notch, sampleRate: 48_000).dynamic.direction, .cutOnly)
        notch.dynamic.direction = .both
        if notch.type.supportsDynamicEQ {
            XCTAssertEqual(EQBandRules.renderState(notch, sampleRate: 48_000), .invalid(reason: "A dynamic notch can only cut"))
        }
        var nan = EQBand(type: .peaking, frequencyHz: .nan, gainDB: .nan, q: .nan)
        nan = EQBandRules.sanitized(nan, sampleRate: 48_000)
        XCTAssertEqual(nan.frequencyHz, 1_000)
        XCTAssertEqual(nan.gainDB, 0)
        XCTAssertEqual(nan.q, 0.707)
        let broken = EQBand(type: .peaking, frequencyHz: -5, gainDB: 0, q: 1)
        if case .invalid = EQBandRules.renderState(broken, sampleRate: 48_000) {} else { XCTFail("negative frequency is invalid") }
    }

    func testActiveCountDropsBandsAbove44k1NyquistAfterA96kRateChange() {
        let bands = [
            EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1),
            EQBand(type: .peaking, frequencyHz: 30_000, gainDB: 3, q: 1),
            EQBand(enabled: false, type: .peaking, frequencyHz: 40_000, gainDB: 3, q: 1),
        ]
        let config = StereoEQConfiguration(linkedBands: bands)
        XCTAssertEqual(config.activeBandCount(sampleRate: 96_000), 2)
        XCTAssertEqual(config.aboveNyquistBandCount(sampleRate: 96_000), 0)
        XCTAssertEqual(config.activeBandCount(sampleRate: 44_100), 1)
        XCTAssertEqual(config.aboveNyquistBandCount(sampleRate: 44_100), 1)
        XCTAssertEqual(config.enabledBandCount, 2, "the stored count still includes the skipped band")
        XCTAssertEqual(EQBandRules.nyquistText(limitHz: 22_050), "Inactive above Nyquist (22.1 kHz)")
    }

    // MARK: Surfaced errors

    private struct Injected: LocalizedError { var errorDescription: String? { "injected" } }

    func testAutoPreampFailureIsPublishedAndClearsWhenItRecovers() throws {
        let engine = AudioIOEngine()
        let auto = EQAutoPreampController(engine: engine)
        try auto.setOn(true)
        var fail = true
        auto.preampWriter = { value in if fail { throw Injected() } else { try engine.setInputPreampDB(value) } }
        try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 9, q: 1))
        auto.reconcile()
        XCTAssertNotNil(auto.lastError)
        XCTAssertTrue(auto.lastError?.contains("injected") == true)
        fail = false
        auto.reconcile()
        XCTAssertNil(auto.lastError)
    }

    func testABLoudnessMatchFailureIsPublished() throws {
        let engine = AudioIOEngine()
        let auto = EQAutoPreampController(engine: engine)
        let comparison = EQComparisonController(engine: engine, autoPreamp: auto)
        comparison.preampWriter = { _ in throw Injected() }
        comparison.setLoudnessMatch(true)
        try comparison.select(.b, history: nil)
        try engine.replaceStereoEQConfiguration(EQRenderHarness.peakConfiguration(gainDB: 12))
        comparison.liveChanged()
        XCTAssertNotNil(comparison.lastError)
        XCTAssertTrue(comparison.lastError?.contains("injected") == true)
    }

    func testImportRollbackFailureSaysTheProfileMayBePartlyApplied() {
        let engine = AudioIOEngine()
        let bad = EQBand(type: .peaking, frequencyHz: .nan, gainDB: 0, q: 1)
        let imported = PresetInterchangeImport(
            stereoEQ: StereoEQConfiguration(linkedBands: [bad]), inputPreampDB: nil,
            dynamics: nil, suggestedName: "x", warnings: [])
        // The previous EQ is also invalid, so the rollback itself fails.
        XCTAssertThrowsError(try PresetImportApplier.apply(
            imported, to: engine,
            previousStereo: StereoEQConfiguration(linkedBands: [bad]),
            previousGain: engine.gainConfiguration, previousDynamics: engine.dynamicsConfiguration)
        ) { error in
            XCTAssertTrue(error is PresetImportApplier.RollbackError)
            XCTAssertTrue(error.localizedDescription.contains("partly applied"))
        }
        // A clean rollback rethrows the original error.
        XCTAssertThrowsError(try PresetImportApplier.apply(
            imported, to: engine,
            previousStereo: engine.stereoEQConfiguration,
            previousGain: engine.gainConfiguration, previousDynamics: engine.dynamicsConfiguration)
        ) { error in XCTAssertFalse(error is PresetImportApplier.RollbackError) }
    }

    func testAddingBeyondTheBandLimitThrowsSoThePageCanShowIt() throws {
        let engine = AudioIOEngine()
        let bands = (0..<EQConfiguration.maximumBandCount).map {
            EQBand(type: .peaking, frequencyHz: 100 + Double($0), gainDB: 0, q: 1)
        }
        try engine.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: bands))
        XCTAssertThrowsError(try engine.addEQBand(EQBand()))
    }

    // MARK: Cache

    func testCacheCompilesOncePerDistinctConfigurationAndRate() {
        let cache = EQResponseCache()
        let a = [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)]
        var b = a
        b[0].gainDB = 4
        for _ in 0..<5 { _ = cache.program(bands: a, sampleRate: 48_000) }
        XCTAssertEqual(cache.compileCount, 1)
        _ = cache.program(bands: a, sampleRate: 96_000)
        _ = cache.program(bands: b, sampleRate: 48_000)
        XCTAssertEqual(cache.compileCount, 3)
        for _ in 0..<3 { _ = cache.program(bands: b, sampleRate: 48_000) }
        XCTAssertEqual(cache.compileCount, 3)
        XCTAssertEqual(
            cache.program(bands: a, sampleRate: 48_000).count,
            ProductionEQResponseMath.compile(bands: a, sampleRate: 48_000).count)
    }

    func testCacheStartsOverWhenFull() {
        let cache = EQResponseCache(capacity: 2)
        for gain in [1.0, 2, 3] {
            _ = cache.program(bands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1)], sampleRate: 48_000)
        }
        XCTAssertEqual(cache.compileCount, 3)
    }
}
