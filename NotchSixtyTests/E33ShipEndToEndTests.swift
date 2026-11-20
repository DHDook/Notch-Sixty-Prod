import XCTest
@testable import NotchSixty

/// E33 S11b: end-to-end tests through production wiring at the eight rates, with `e33.page-enhancements` on. Each test
/// starts from what the page edits (a `DynamicsConfiguration`, an Equalizer APO file, the preamp controller), goes
/// through the engine's own publish path (`DynamicsGraphExtras`, `stereoTransportStartGraph`, the translator) and renders
/// in the real core through `UnifiedGraphHost`.
@MainActor
final class E33ShipEndToEndTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let flags = FeatureFlags()

    override func setUp() {
        super.setUp()
        flags.setEnabled(true, for: .eqPageEnhancements)
        flags.setEnabled(true, for: .dynamicsExtras)
    }

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    // MARK: Harness

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "e33ship-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "e33ship-out")
        return engine
    }

    /// The stereo configuration the engine publishes for what the page set, with the extras it passes (flag on).
    private func published(_ engine: AudioIOEngine, rate: Double, flagOn: Bool = true) throws -> UnifiedGraphConfiguration {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let extras = DynamicsGraphExtras.make(engine.dynamicsConfiguration, sampleRate: rate, flagOn: flagOn)
        return try UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: rate,
            compressorExtras: extras?.compressor, expanderExtras: extras?.expander, multibandExtras: extras?.multiband
        ).get()
    }

    private func run(_ host: UnifiedGraphHost, input: [Float], block: Int = 512) throws -> [Float] {
        var out: [Float] = []
        var position = 0
        while position < input.count {
            let count = min(block, input.count - position)
            let chunk = Array(input[position..<position + count])
            out += try host.processOffline(input: [chunk, chunk], frames: count)[0]
            position += count
        }
        return out
    }

    private func tone(_ hz: Double, amplitude: Double, rate: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
    }

    // MARK: Dynamics page to core blocks (S5a, S5b)

    /// G14: expander lookahead from the page model, through the engine's extras and the translator, at the eight rates:
    /// the impulse is late by the lookahead, the reported latency counts it, and the lookahead leaves the static law alone
    /// (a tone settles to the same gain with and without it; the gain itself is the expander's, see G103).
    func testExpanderLookaheadLabCaseAtEveryRate() throws {
        for rate in rates {
            var delays: [Int] = [], reported: [Int] = [], toneGains: [Double] = []
            for lookaheadMs in [0.0, 5.0] {
                let e = try engine(rate: rate)
                var d = DynamicsConfiguration()
                d.expander.enabled = true
                d.expander.thresholdDB = -60
                d.expander.lookaheadMs = lookaheadMs
                try e.replaceDynamicsConfiguration(d)
                let config = try published(e, rate: rate)
                let block = try XCTUnwrap(config.stereoStages.expander)
                XCTAssertEqual(block.count, 14 + (FeatureFlags.isEnabledProcessWide(.dynamicsSound) ? 1 : 0), "lookahead block at \(rate)")
                XCTAssertEqual(Int(block[13]), CompressorConfiguration.lookaheadFrames(ms: lookaheadMs, sampleRate: rate))
                let host = try UnifiedGraphHost(spec: try config.makeSpec())
                var impulse = [Float](repeating: 0, count: 4_096 + Int(rate * 0.02))
                impulse[100] = 0.3
                let out = try run(host, input: impulse)
                let index = try XCTUnwrap(out.indices.max { abs(out[$0]) < abs(out[$1]) })
                delays.append(index - 100)
                reported.append(Int(host.latencyFrames))
                host.release()
                let steady = try UnifiedGraphHost(spec: try config.makeSpec())
                defer { steady.release() }
                let n = Int(rate * 0.4)
                let input = tone(1_000, amplitude: 0.1, rate: rate, frames: n)
                let toneOut = try run(steady, input: input)
                let tail = (n - Int(rate * 0.1))..<n
                toneGains.append(20 * log10(rms(toneOut[tail]) / rms(input[tail])))
            }
            let frames = CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate)
            XCTAssertEqual(delays[1] - delays[0], frames, "impulse delay at \(rate)")
            XCTAssertEqual(reported[1] - reported[0], frames, "reported latency at \(rate)")
            XCTAssertEqual(toneGains[1], toneGains[0], accuracy: 0.05, "lookahead leaves the settled gain alone at \(rate)")
        }
    }

    /// Five bands: the page's Bands picker value reaches the core as the 73-value block, and the five-band split
    /// reconstructs a tone below every threshold at unity at the eight rates.
    func testFiveBandCompressorReachesTheCoreAndReconstructsAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.multibandCompressor.enabled = true
            d.multibandCompressor.setBandCount(5)
            XCTAssertEqual(d.multibandCompressor.bandCountValue, 5)
            try e.replaceDynamicsConfiguration(d)
            let block = try XCTUnwrap(try published(e, rate: rate).stereoStages.multiband)
            XCTAssertEqual(block.count, UnifiedGraphConfiguration.multibandBandsParamCount, "at \(rate)")
            XCTAssertEqual(block[44], 5)
            let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
            defer { host.release() }
            let n = Int(rate * 0.5)
            for hz in [100.0, 1_000, 8_000] {
                let input = tone(hz, amplitude: 0.01, rate: rate, frames: n)
                let out = try run(host, input: input)
                let tail = (n - Int(rate * 0.1))..<n
                let gain = 20 * log10(rms(out[tail]) / rms(input[tail]))
                XCTAssertEqual(gain, 0, accuracy: 0.6, "\(hz) Hz through five bands at \(rate): \(gain) dB")
            }
        }
    }

    /// Flag off: the engine publishes today's 10, 6 and 29 value blocks and no extras (G1, behaviour half).
    func testFlagsOffPublishesTheOldBlocks() throws {
        flags.setEnabled(false, for: .eqPageEnhancements)
        flags.setEnabled(false, for: .dynamicsExtras)
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            d.expander.enabled = true
            d.expander.lookaheadMs = 5
            d.multibandCompressor.enabled = true
            try e.replaceDynamicsConfiguration(d)
            let stages = try published(e, rate: rate, flagOn: false).stereoStages
            XCTAssertEqual(stages.compressor?.count, 10)
            XCTAssertEqual(stages.expander?.count, 6)
            XCTAssertEqual(stages.multiband?.count, 29)
        }
    }

    // MARK: Equalizer page to the published graph (S2, S3)

    /// An Equalizer APO file imported through the page's own steps (parse, `EQBandTransfer`, `replaceStereoEQConfiguration`)
    /// and a manual preamp set through the preamp controller: a tone at the peak's centre leaves with the band's gain plus
    /// the preamp, at the eight rates, through the engine's published graph (the GAIN stage carries the preamp).
    func testImportedBandAndPreampReachTheGraphAtEveryRate() throws {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 6 dB Q 0.7\n"
        let parsed = EqualizerAPOCodec.parse(text)
        XCTAssertTrue(parsed.issues.isEmpty)
        for rate in rates {
            let e = try engine(rate: rate)
            let outcome = try EQBandTransfer.importing(parsed, into: e.stereoEQConfiguration, mode: .replace)
            try e.replaceStereoEQConfiguration(outcome.configuration)
            let controller = EQAutoPreampController(engine: e)
            try controller.setManual(-6)
            XCTAssertEqual(e.gainConfiguration.inputPreampDB, -6, accuracy: 1e-9)
            let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
            defer { host.release() }
            let n = Int(rate * 0.4)
            let input = tone(1_000, amplitude: 0.05, rate: rate, frames: n)
            let out = try run(host, input: input)
            let tail = (n - Int(rate * 0.1))..<n
            let gain = 20 * log10(rms(out[tail]) / rms(input[tail]))
            XCTAssertEqual(gain, 0, accuracy: 0.15, "+6 dB band and -6 dB preamp at \(rate): \(gain) dB")
        }
    }

    /// The flag-on page keeps the preamp's three terms in one published total.
    func testPreampTotalIsThePublishedInputPreamp() throws {
        let e = try engine(rate: 48_000)
        let controller = EQAutoPreampController(engine: e)
        try controller.preamp.setMatch(-1.5)
        try controller.setManual(-2)
        XCTAssertEqual(e.gainConfiguration.inputPreampDB, -3.5, accuracy: 1e-9)
    }

    // MARK: Levels card (S10)

    /// With the flag on the translator adds the detector parameters, so the card has something to read at every rate.
    func testTranslatorBuiltGraphCarriesTheInputOverDetectorAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
            defer { host.release() }
            XCTAssertNotNil(host.inputOvers(lanes: 2), "detector present at \(rate)")
            XCTAssertTrue(host.setInputOverDetect(true))
            let factor = InputOversReading.factor(sampleRate: rate)
            let n = Int(rate * 0.2) / 512 * 512
            let amp = pow(10, 1.5 / 20.0)
            let input: [Float] = (0..<n).map { i in
                factor > 1 ? Float(amp * sin(0.5 * .pi * Double(i) + 0.25 * .pi)) : Float(amp * sin(2 * .pi * 1_000 * Double(i) / rate))
            }
            _ = try run(host, input: input)
            XCTAssertGreaterThan(host.inputOvers(lanes: 2)?.first ?? 0, 0, "a +1.5 dBTP tone is counted at \(rate)")
        }
    }
}
