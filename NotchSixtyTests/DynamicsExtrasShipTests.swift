import XCTest
@testable import NotchSixty

/// E28 S8: the flag graduation and the end-to-end path of every extra, from the Dynamics page row (its
/// `DynamicsParameterSpec`) through `replaceDynamicsConfiguration` and the stereo session's extras
/// (`DynamicsGraphExtras`) to the parameter blocks the production translator publishes to the core, at the eight rates.
@MainActor
final class DynamicsExtrasShipTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Flag

    func testFlagIsGraduatedAvailableAndSwitchableOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.dynamicsExtras), "graduated flags stay in the registry")
        XCTAssertTrue(FeatureFlag.dynamicsExtras.graduated)
        let release = FeatureFlags(policy: .launchArgumentOnly, arguments: [], environment: [:])
        XCTAssertTrue(release.isEnabled(.dynamicsExtras), "on by default in release builds")
        let off = FeatureFlags(policy: .launchArgumentOnly, arguments: ["-NotchSixtyFeatures", "-e28.dynamics-extras"], environment: [:])
        XCTAssertFalse(off.isEnabled(.dynamicsExtras), "a release user can switch it off")
    }

    func testGraduatingTheFlagArmsNothing() {
        // Dynamics extras never touch the live-treatment arm: the arm is its own type and starts disarmed.
        for feature in LiveTreatmentFeature.allCases {
            XCTAssertFalse(LiveTreatmentArm(feature: feature).isArmed)
        }
    }

    // MARK: Harness

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_432, uid: "dynship-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "dynship-out")
        return engine
    }

    /// What the stereo session publishes: the engine's stored configuration, the session's extras built exactly as the
    /// engine builds them, and the production translator.
    private func published(_ engine: AudioIOEngine, rate: Double, flagOn: Bool) throws -> UnifiedGraphConfiguration {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let extras = DynamicsGraphExtras.make(engine.dynamicsConfiguration, sampleRate: rate, flagOn: flagOn)
        return try UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: rate,
            compressorExtras: extras?.compressor, expanderExtras: extras?.expander, multibandExtras: extras?.multiband
        ).get()
    }

    private func setRow(_ spec: DynamicsParameterSpec, _ value: Double, on engine: AudioIOEngine) throws {
        var d = engine.dynamicsConfiguration
        spec.apply(value, to: &d)
        try engine.replaceDynamicsConfiguration(d)
    }

    // MARK: Every numeric row reaches the core block

    /// The block index each extra row lands on, and the value the core receives.
    private struct Landing {
        let spec: DynamicsParameterSpec
        let stage: KeyPath<UnifiedGraphStereoStages, [Float]?>
        let index: Int
        let expected: (Double, Double) -> Float  // (page value, rate)
    }

    private var landings: [Landing] {
        [
            Landing(spec: .compressorMixPercent, stage: \.compressor, index: 10, expected: { v, _ in Float(v) }),
            Landing(spec: .compressorLinkPercent, stage: \.compressor, index: 11, expected: { v, _ in Float(v) }),
            Landing(spec: .compressorRMSWindowMs, stage: \.compressor, index: 13, expected: { v, _ in Float(v) }),
            Landing(spec: .compressorLookaheadMs, stage: \.compressor, index: 14, expected: { v, r in
                Float(CompressorConfiguration.lookaheadFrames(ms: v, sampleRate: r)) }),
            Landing(spec: .expanderHoldMs, stage: \.expander, index: 6, expected: { v, _ in Float(v) }),
            Landing(spec: .expanderKneeDB, stage: \.expander, index: 7, expected: { v, _ in Float(v) }),
            Landing(spec: .expanderRMSWindowMs, stage: \.expander, index: 9, expected: { v, _ in Float(v) }),
            Landing(spec: .expanderSidechainHighPassHz, stage: \.expander, index: 10, expected: { v, _ in Float(v) }),
            Landing(spec: .expanderLinkPercent, stage: \.expander, index: 11, expected: { v, _ in Float(v) }),
            Landing(spec: .multibandRMSWindowMs, stage: \.multiband, index: 41, expected: { v, _ in Float(v) }),
            Landing(spec: .multibandLookaheadMs, stage: \.multiband, index: 42, expected: { v, r in
                Float(CompressorConfiguration.lookaheadFrames(ms: v, sampleRate: r)) }),
        ]
    }

    func testEveryExtraRowReachesTheCoreParametersAtEveryRate() throws {
        XCTAssertEqual(Set(landings.map(\.spec.id)), Set(DynamicsParameterSpec.extras.map(\.id)), "a new extra row needs a landing here")
        for rate in rates {
            for landing in landings {
                let e = try engine(rate: rate)
                var d = e.dynamicsConfiguration
                d.compressor.enabled = true
                d.expander.enabled = true
                d.multibandCompressor.enabled = true
                // The lookahead rows only count while a lookahead is on.
                d.compressor.lookaheadMs = 5
                d.multibandCompressor.lookaheadMs = 5
                try e.replaceDynamicsConfiguration(d)
                // A value inside the slider range that differs from the default.
                let slider = landing.spec.slider
                let value = landing.spec.clamped(slider.lowerBound + (slider.upperBound - slider.lowerBound) * 0.4)
                try setRow(landing.spec, value, on: e)
                let stored = landing.spec.clamped(value)
                let stages = try published(e, rate: rate, flagOn: true).stereoStages
                let block = try XCTUnwrap(stages[keyPath: landing.stage], "\(landing.spec.id) at \(rate)")
                XCTAssertEqual(block[landing.index], landing.expected(stored, rate), accuracy: 1e-4, "\(landing.spec.id) at \(rate)")
            }
        }
    }

    func testToggleExtrasReachTheCoreParametersAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = e.dynamicsConfiguration
            d.compressor.enabled = true
            d.compressor.rmsDetectorOn = true
            d.expander.enabled = true
            d.expander.rmsDetector = true
            d.multibandCompressor.enabled = true
            d.multibandCompressor.autoReleaseBands = [0, 2]
            d.multibandCompressor.bypassedBands = [1]
            d.multibandCompressor.rmsDetectorBands = [0, 2]
            try e.replaceDynamicsConfiguration(d)
            let stages = try published(e, rate: rate, flagOn: true).stereoStages
            let comp = try XCTUnwrap(stages.compressor), exp = try XCTUnwrap(stages.expander), mb = try XCTUnwrap(stages.multiband)
            XCTAssertEqual(comp.count, 16)
            XCTAssertEqual(comp[12], 1, "compressor RMS detector")
            XCTAssertEqual(comp[15], 0, "listen starts off")
            XCTAssertEqual(exp.count, 13)
            XCTAssertEqual(exp[8], 1, "expander RMS detector")
            XCTAssertEqual(exp[12], 0, "listen starts off")
            XCTAssertEqual(mb.count, 44)
            XCTAssertEqual(Array(mb[26..<29]), [1, 0, 1], "auto release")
            XCTAssertEqual(Array(mb[29..<32]), [0, 1, 0], "band bypass")
            XCTAssertEqual(Array(mb[32..<35]), [0, 0, 0], "solo is a live post, off at build")
            XCTAssertEqual(Array(mb[35..<38]), [0, 0, 0], "listen is a live post, off at build")
            XCTAssertEqual(Array(mb[38..<41]), [1, 0, 1], "per-band detector")
            XCTAssertEqual(mb[43], 1, "band-pass split")
        }
    }

    func testFlagOffPublishesTodaysBlocksAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = e.dynamicsConfiguration
            d.compressor.enabled = true
            d.compressor.mixPercent = 50
            d.expander.enabled = true
            d.expander.holdMs = 100
            d.multibandCompressor.enabled = true
            d.multibandCompressor.lookaheadMs = 5
            try e.replaceDynamicsConfiguration(d)
            XCTAssertNil(DynamicsGraphExtras.make(e.dynamicsConfiguration, sampleRate: rate, flagOn: false))
            let stages = try published(e, rate: rate, flagOn: false).stereoStages
            XCTAssertEqual(stages.compressor?.count, 10)
            XCTAssertEqual(stages.expander?.count, 6)
            XCTAssertEqual(stages.multiband?.count, 29)
        }
    }

    /// The stereo session republishes with whatever extras it holds, so a dynamics edit must change them and a refused edit
    /// must leave the live ones (this is the engine's own builder, so the helper cannot drift from the N-channel path).
    func testExtrasFollowTheStoredConfiguration() throws {
        let e = try engine(rate: 48_000)
        var d = e.dynamicsConfiguration
        d.compressor.enabled = true
        d.compressor.mixPercent = 25
        try e.replaceDynamicsConfiguration(d)
        let first = try XCTUnwrap(DynamicsGraphExtras.make(e.dynamicsConfiguration, sampleRate: 48_000, flagOn: true))
        XCTAssertEqual(first.compressor[0], 25)
        var bad = d
        bad.compressor.mixPercent = 250
        XCTAssertThrowsError(try e.replaceDynamicsConfiguration(bad))
        let after = try XCTUnwrap(DynamicsGraphExtras.make(e.dynamicsConfiguration, sampleRate: 48_000, flagOn: true))
        XCTAssertEqual(after, first, "a refused edit leaves the extras as they were")
    }
}
