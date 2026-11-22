import XCTest
@testable import NotchSixty

/// E33 S27 (G52, G88): the linear-phase EQ's four lengths, designed by the core off the main actor, stored per EQ,
/// refused by name when they do not fit, and shared by group lists through a cache.
@MainActor
final class EQLinearPhaseLengthTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private var savedFlag: Any?

    override func setUp() {
        super.setUp()
        let key = FeatureFlags.key(for: .eqPageEnhancements)
        savedFlag = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
    }

    override func tearDown() {
        let key = FeatureFlags.key(for: .eqPageEnhancements)
        if let savedFlag { UserDefaults.standard.set(savedFlag, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    private func linear(_ length: EQLinearPhaseLength = .default) -> StereoEQConfiguration {
        var configuration = EQRenderHarness.peakConfiguration(gainDB: 6, frequency: 1_000)
        configuration.phaseMode = .linearPhase
        configuration.linearPhaseLength = length
        return configuration
    }

    func testTapCountsPerLengthAtEveryRate() {
        for rate in Self.rates {
            XCTAssertEqual(EQLinearPhaseLength.default.tapCount(sampleRate: rate) % 2, 1)
            for length in EQLinearPhaseLength.allCases {
                let taps = length.tapCount(sampleRate: rate)
                XCTAssertLessThanOrEqual(taps, Int(N60_EQ_LINEAR_PHASE_MAX_TAPS), "\(length) at \(rate)")
                XCTAssertEqual(Double(taps - 1) / 2 / rate * 1_000, length.nominalMilliseconds, accuracy: length == .ms21 ? 4 : 0.03)
            }
        }
        XCTAssertEqual(EQLinearPhaseLength.ms340.tapCount(sampleRate: 384_000), 261_121)
        XCTAssertEqual(EQLinearPhaseLength.ms21.tapCount(sampleRate: 48_000), 2_049)
    }

    func testDesignedLengthMatchesTheDeclaredDelayAndStaysWithinTolerance() throws {
        for rate in [48_000.0, 96_000.0] {
            for length in EQLinearPhaseLength.allCases {
                let bands = try EQConfiguration(bands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)])
                    .linearPhaseBands(sampleRate: rate)
                let design = try EQLinearPhaseDesigner.design(bands: bands, sampleRate: rate, length: length)
                XCTAssertEqual(Int(design.info.tapCount), length.tapCount(sampleRate: rate))
                XCTAssertEqual(design.info.groupDelayFrames, length.groupDelayFrames(sampleRate: rate))
                XCTAssertLessThan(design.info.maxErrorDB, 0.5, "\(length) at \(rate)")
                XCTAssertTrue(design.taps.allSatisfy(\.isFinite))
            }
        }
    }

    func testLongerLengthFollowsANarrowBassBandMoreClosely() throws {
        let bands = try EQConfiguration(bands: [EQBand(type: .peaking, frequencyHz: 40, gainDB: -9, q: 3)])
            .linearPhaseBands(sampleRate: 48_000)
        var previous = Double.infinity
        for length in EQLinearPhaseLength.allCases {
            let error = try EQLinearPhaseDesigner.design(bands: bands, sampleRate: 48_000, length: length).info.maxErrorDB
            XCTAssertLessThan(error, previous, "\(length)")
            previous = error
        }
        XCTAssertEqual(EQLinearPhaseLength.suggested(narrowestBandwidthHz: 40.0 / 3, sampleRate: 48_000), .ms340)
        XCTAssertEqual(EQLinearPhaseLength.suggested(narrowestBandwidthHz: 1_000, sampleRate: 48_000), .ms21)
        XCTAssertEqual(EQLinearPhaseLength.suggested(narrowestBandwidthHz: nil, sampleRate: 48_000), .default)
    }

    func testOldProfilesLoadAtTheDefaultLengthAndTheDefaultIsNotWritten() throws {
        let configuration = linear()
        let data = try JSONEncoder().encode(configuration)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("linearPhaseLength"))
        XCTAssertEqual(try JSONDecoder().decode(StereoEQConfiguration.self, from: data).linearPhaseLength, .ms21)

        for length in EQLinearPhaseLength.allCases {
            let round = try JSONDecoder().decode(StereoEQConfiguration.self, from: JSONEncoder().encode(linear(length)))
            XCTAssertEqual(round.linearPhaseLength, length)
        }
    }

    func testRefusalNamesTheLengthAndTheReason() {
        XCTAssertNil(EQLinearPhaseLength.ms340.refusal(sampleRate: 384_000, laneCount: 2, firScheme: UnifiedGraphFIRScheme.nonUniform))
        let uniform = EQLinearPhaseLength.ms340.refusal(sampleRate: 96_000, laneCount: 2, firScheme: UnifiedGraphFIRScheme.uniform)
        XCTAssertNotNil(uniform)
        XCTAssertTrue(uniform?.contains("340 ms") ?? false)
        let wide = EQLinearPhaseLength.ms340.refusal(sampleRate: 384_000, laneCount: 6, firScheme: UnifiedGraphFIRScheme.nonUniform)
        XCTAssertTrue(wide?.contains("340 ms") ?? false)
        XCTAssertNil(EQLinearPhaseLength.ms21.refusal(sampleRate: 384_000, laneCount: 6, firScheme: UnifiedGraphFIRScheme.uniform))
    }

    func testDesignUsesTheStoredLengthWithTheFlagOnAndTheDefaultWithItOff() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces the EQ page flag off, so the flag-on half cannot run")
        let long = linear(.ms85)
        let design = try EQFIRDesigner.design(long, sampleRate: 48_000)
        XCTAssertEqual(design.left.count, EQLinearPhaseLength.ms85.tapCount(sampleRate: 48_000))
        XCTAssertEqual(Int(design.designInfo?.groupDelayFrames ?? 0), 4_080)

        UserDefaults.standard.set(false, forKey: FeatureFlags.key(for: .eqPageEnhancements))
        let off = try EQFIRDesigner.design(long, sampleRate: 48_000)
        XCTAssertEqual(off.left.count, EQLinearPhaseLength.ms21.tapCount(sampleRate: 48_000))
    }

    func testOffMainLengthChangeDesignsOnceAndStoresTheLength() async throws {
        let output = AudioOutputDevice(
            deviceID: 9_427, uid: "eq-length", name: "Out", nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "eq-length")
        try engine.replaceStereoEQConfiguration(linear())
        try await engine.setEQLinearPhaseLengthOffMain(.ms170)
        XCTAssertEqual(engine.stereoEQConfiguration.linearPhaseLength, .ms170)
        try await engine.setEQLinearPhaseLengthOffMain(.ms21)
        XCTAssertEqual(engine.stereoEQConfiguration.linearPhaseLength, .ms21)
    }

    func testGroupFIRCacheDesignsOncePerInputs() throws {
        let cache = EQGroupFIRCache()
        let configuration = linear(.ms21)
        _ = try cache.design(configuration, sampleRate: 48_000)
        _ = try cache.design(configuration, sampleRate: 48_000)
        XCTAssertEqual(cache.designCount, 1)
        _ = try cache.design(linear(.ms85), sampleRate: 48_000)
        XCTAssertEqual(cache.designCount, 2)
    }
}
