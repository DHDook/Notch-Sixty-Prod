import XCTest
@testable import NotchSixty

/// E32 S6: end-to-end tests of `e32.dynamics-sound` at the eight rates, flag on and off. Each test starts from what the
/// Dynamics page edits (a `DynamicsConfiguration`), goes through the engine's own publish path (`DynamicsGraphExtras`,
/// `stereoTransportStartGraph`, the translator) and renders in the real core through `UnifiedGraphHost`.
@MainActor
final class E32ShipEndToEndTests: XCTestCase {
    let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_432, uid: "e32ship-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "e32ship-out")
        return engine
    }

    /// The stereo configuration the engine publishes for what the page set.
    func published(_ engine: AudioIOEngine, rate: Double) throws -> UnifiedGraphConfiguration {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let extras = DynamicsGraphExtras.make(engine.dynamicsConfiguration, sampleRate: rate, flagOn: true)
        return try UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: rate,
            compressorExtras: extras?.compressor, expanderExtras: extras?.expander, multibandExtras: extras?.multiband
        ).get()
    }

    func run(_ host: UnifiedGraphHost, input: [Float], block: Int = 512) throws -> [Float] {
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

    /// What the Dynamics page sets: limiter (-1 dB ceiling, 20 ms attack, 2 ms look-ahead, guard on) and an expander.
    func pageModel() -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.limiter.enabled = true
        d.limiter.ceilingDB = -1
        d.limiter.attackMs = 20
        d.limiter.lookAheadMs = 2
        d.limiter.truePeakGuardEnabled = true
        d.expander.enabled = true
        d.expander.thresholdDB = -50
        return d
    }

    func protectionParams(_ config: UnifiedGraphConfiguration) throws -> [Float] {
        let spec = try config.makeSpec()
        let stage = try XCTUnwrap(spec.stages.last { $0.stageId == N60_LSTAGE_PROTECTION })
        return stage.params
    }

    func testSoundFixesReachTheCoreParametersAtEveryRate() throws {
        for flagOn in [true, false] {
            flags.setEnabled(flagOn, for: .dynamicsSound)
            XCTAssertEqual(DynamicsSoundFixes.isEnabled, flagOn)
            for rate in rates {
                let e = try engine(rate: rate)
                try e.replaceDynamicsConfiguration(pageModel())
                let config = try published(e, rate: rate)
                let params = try protectionParams(config)
                XCTAssertEqual(params.count, flagOn ? 8 : 7, "protection block at \(rate), flag \(flagOn)")
                if flagOn {
                    XCTAssertEqual(params.last.map { Int($0) & Int(DynamicsSoundFixes.protectionWord) },
                                   Int(DynamicsSoundFixes.protectionWord), "sound-fixes word at \(rate)")
                }
                let expander = try XCTUnwrap(config.stereoStages.expander)
                if flagOn {
                    XCTAssertEqual(expander.last, 1, "expander Attack opens at \(rate)")
                } else {
                    XCTAssertNotEqual(expander.count, 0)
                    XCTAssertNotEqual(expander.last, 1, "expander timing unchanged at \(rate)")
                }
            }
        }
    }

    /// The reported latency follows the rate's factor with the flag on, is the fixed 4x figure off, and equals the
    /// measured delay of an impulse under the ceiling; the guard reads active at every rate (G10).
    func testLatencyMatchesMeasuredDelayAndGuardReadsActiveAtEveryRate() throws {
        for flagOn in [true, false] {
            flags.setEnabled(flagOn, for: .dynamicsSound)
            for rate in rates {
                let e = try engine(rate: rate)
                try e.replaceDynamicsConfiguration(pageModel())
                let config = try published(e, rate: rate)
                let host = try UnifiedGraphHost(spec: try config.makeSpec())
                defer { host.release() }
                var impulse = [Float](repeating: 0, count: 4_096 + Int(rate * 0.03))
                impulse[100] = 0.1
                let out = try run(host, input: impulse)
                let index = try XCTUnwrap(out.indices.max { abs(out[$0]) < abs(out[$1]) })
                XCTAssertEqual(Double(index - 100), Double(host.latencyFrames), accuracy: 1, "measured delay at \(rate), flag \(flagOn)")
                let factor: UInt32 = flagOn ? DynamicsSoundFixes.truePeakFactor(sampleRate: rate) : 4
                let limiterLatency = DynamicsSoundFixes.limiterLatencyFrames(
                    factor: factor, lookAheadMilliseconds: 2, limiterEnabled: true, sampleRate: rate)
                XCTAssertGreaterThanOrEqual(host.latencyFrames, limiterLatency, "latency counts the guard at \(rate)")
                // Drive past the ceiling so the readback is meaningful, then read it back.
                let burst = (0..<Int(rate * 0.05)).map { Float($0 & 1 == 0 ? 1 : -1) }
                _ = try run(host, input: burst)
                let reading = try XCTUnwrap(host.dynamicsReadings(), "readings at \(rate)")
                XCTAssertTrue(reading.truePeakGuardActive, "guard reads active at \(rate), flag \(flagOn)")
            }
        }
    }

    /// A 0 dBFS burst with the attack above the look-ahead stays under the ceiling with the sound fixes on at every rate.
    func testBurstStaysUnderTheCeilingWithTheFixesOn() throws {
        flags.setEnabled(true, for: .dynamicsSound)
        for rate in rates {
            let e = try engine(rate: rate)
            try e.replaceDynamicsConfiguration(pageModel())
            let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
            defer { host.release() }
            var input = [Float](repeating: 0, count: Int(rate * 0.3))
            let start = Int(rate * 0.1)
            for i in start..<(start + Int(rate * 0.05)) { input[i] = (i & 1 == 0) ? 1 : -1 }
            let out = try run(host, input: input)
            let peak = out.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(Double(peak), pow(10, -1.0 / 20) * 1.02, "ceiling holds at \(rate)")
        }
    }
}
