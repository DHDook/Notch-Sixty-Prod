import XCTest
@testable import NotchSixty

/// The one rate list every E7 matrix test uses: the eight standard rates, plus the two smoke rates below them.
enum RateMatrix {
    /// 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz.
    static let standard: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    /// Rates below the standard list that must still build and run (a plug-in or interface can sit there).
    static let smoke: [Double] = [32_000, 64_000]
    static let all: [Double] = smoke + standard
}

/// E7 S5 (design note 8): the rate matrix, through the production wiring. Each feature family is built the way the
/// app builds it (engine configuration to the translator to the graph, or the translator's own entry point) and
/// rendered offline at every rate; the assertion is the feature's behaviour (a level, an arrival frame, a split), not
/// that something built. Families already covered at the eight rates by their own suites are named where they are
/// run here: the plug-in rack (`AudioUnitRateRefusalTests`), the full setup wizard (`SystemSetupEndToEndTests`).
@MainActor
final class RateMatrixTests: XCTestCase {
    private let block = 512

    // MARK: helpers

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    private func db(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

    private func engine(rate: Double) throws -> AudioIOEngine {
        let uid = "matrix-out"
        let output = AudioOutputDevice(
            deviceID: 9_700, uid: uid, name: "Matrix Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 8_000, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: uid)
        return engine
    }

    private func productionSpec(_ engine: AudioIOEngine, rate: Double) throws -> UnifiedGraphSpec {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        return try configuration.makeSpec()
    }

    /// Renders a sine on every input lane and returns each output lane's last `tailSeconds` of samples.
    private func renderTone(
        _ spec: UnifiedGraphSpec, rate: Double, frequency: Double = 1_000, amplitude: Double = 0.1,
        seconds: Double = 1.0, tailSeconds: Double = 0.25, toneLanes: Set<Int>? = nil
    ) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        let inputs = Int(spec.inputChannels)
        let total = (Int(rate * seconds) / block + 1) * block
        var out = [[Float]](repeating: [], count: Int(spec.outputChannels))
        var done = 0
        while done < total {
            let tone = (0..<block).map { Float(amplitude * sin(2 * Double.pi * frequency * Double(done + $0) / rate)) }
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: inputs)
            for lane in 0..<inputs where toneLanes?.contains(lane) ?? true { input[lane] = tone }
            let rendered = try host.processOffline(input: input, frames: block)
            for lane in 0..<out.count { out[lane] += rendered[lane] }
            done += block
        }
        let tail = Int(rate * tailSeconds)
        return out.map { Array($0.suffix(tail)) }
    }

    /// Feeds a unit impulse on `inLane`; returns the arrival frame of the largest sample on `outLane`.
    private func impulseArrival(_ spec: UnifiedGraphSpec, inLane: Int = 0, outLane: Int = 0, frames: Int) throws -> (arrival: Int, latency: Int) {
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        var peak: Float = 0
        var best = -1
        var done = 0
        let step = 4_096
        while done < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: step), count: Int(spec.inputChannels))
            if done == 0 { input[inLane][0] = 1 }
            let out = try host.processOffline(input: input, frames: step)
            for i in 0..<step where abs(out[outLane][i]) > peak {
                peak = abs(out[outLane][i]); best = done + i
            }
            done += step
        }
        return (best, Int(host.latencyFrames))
    }

    // MARK: EQ

    func testPeakingBandHasItsGainAtEveryRate() throws {
        for rate in RateMatrix.all {
            let engine = try engine(rate: rate)
            try engine.replaceStereoEQConfiguration(StereoEQConfiguration(
                linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)]))
            let out = try renderTone(try productionSpec(engine, rate: rate), rate: rate)
            XCTAssertEqual(db(rms(out[0][...]) / (0.1 / 2.0.squareRoot())), 6, accuracy: 0.3, "EQ at \(rate)")
        }
    }

    // MARK: dynamics

    func testCompressorReducesAHotToneAtEveryRate() throws {
        for rate in RateMatrix.all {
            let engine = try engine(rate: rate)
            var dynamics = DynamicsConfiguration()
            dynamics.compressor.enabled = true
            dynamics.compressor.thresholdDB = -30
            dynamics.compressor.ratio = 4
            dynamics.compressor.kneeWidthDB = 0
            dynamics.compressor.attackMs = 1
            dynamics.compressor.releaseMs = 100
            try engine.replaceDynamicsConfiguration(dynamics)
            let out = try renderTone(try productionSpec(engine, rate: rate), rate: rate, seconds: 1.5)
            // A -20 dBFS tone is 10 dB over the threshold: 4:1 takes off 7.5 dB. The detector's own settling is
            // within a dB, equal at every rate.
            let reduction = -db(rms(out[0][...]) / (0.1 / 2.0.squareRoot()))
            XCTAssertEqual(reduction, 7.5, accuracy: 1.5, "compressor at \(rate)")
        }
    }

    // MARK: protection

    func testLimiterHoldsItsCeilingWithTwentyMillisecondLookAheadAtEveryRate() throws {
        for rate in RateMatrix.all {
            let engine = try engine(rate: rate)
            var dynamics = DynamicsConfiguration()
            dynamics.limiter.enabled = true
            dynamics.limiter.ceilingDB = -6
            dynamics.limiter.lookAheadMs = 20
            try engine.replaceDynamicsConfiguration(dynamics)
            let out = try renderTone(try productionSpec(engine, rate: rate), rate: rate, amplitude: 0.9, seconds: 1.0)
            let peak = out[0].reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertLessThanOrEqual(Double(peak), pow(10, -6.0 / 20) * 1.02, "ceiling at \(rate)")
            XCTAssertGreaterThan(Double(peak), 0.3, "still plays at \(rate)")
        }
    }

    /// E7 G2: with the 20 ms look-ahead at 4x oversampling an impulse below the ceiling arrives at the latency the
    /// graph reports, at every rate.
    func testLookAheadImpulseArrivesAtTheReportedLatencyAtEveryRate() throws {
        for rate in RateMatrix.all {
            var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            configuration.protection = UnifiedGraphProtection(
                ceilingDB: -1, attackMilliseconds: 0.5, releaseMilliseconds: 90,
                lookAheadMilliseconds: RateCapacity.protectionLookAheadMaximumSeconds * 1_000,
                truePeakGuard: true, oversampling: 4)
            let spec = try configuration.makeSpec()
            let frames = Int(RateCapacity.frames(seconds: 0.08, sampleRate: rate)) + 8_192
            let result = try impulseArrival(spec, frames: frames)
            XCTAssertGreaterThanOrEqual(result.latency, Int(RateCapacity.frames(seconds: 0.020, sampleRate: rate)), "\(rate)")
            XCTAssertEqual(Double(result.arrival), Double(result.latency), accuracy: 2, "arrival at \(rate)")
        }
    }

    // MARK: room correction and speaker impulse responses

    /// A room-correction filter installed on the stereo path delays an impulse by exactly its taps' lead at every rate.
    func testRoomCorrectionFilterInstallsAndDelaysByItsTapsAtEveryRate() throws {
        for rate in RateMatrix.all {
            var taps = [Float](repeating: 0, count: 2_048)
            taps[200] = 1
            var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            configuration.stereoStages.roomFIR = UnifiedGraphFIRProgram(
                generation: 1, left: taps, right: nil, declaredLatencyFrames: 0)
            let spec = try configuration.makeSpec()
            let result = try impulseArrival(spec, frames: 8_192)
            XCTAssertEqual(Double(result.arrival), 200 + Double(result.latency), accuracy: 2, "room filter at \(rate)")
        }
    }

    // MARK: routing and crossovers

    func testTwoWayCrossoverSplitsAtEveryRate() throws {
        let ep = { (i: UInt32) in PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
        for rate in RateMatrix.all {
            let routing = try XCTUnwrap(SpeakerRoutingTemplate.twoWay.build(
                mains: [0, 1].map { lane in
                    SpeakerRoutingTemplate.Main(lane: lane, name: "M\(lane)", endpoints: [ep(UInt32(lane * 2)), ep(UInt32(lane * 2 + 1))])
                },
                subs: [], crossoverHz: [2_000]))
            let base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            var config = try SpeakerRoutingCompiler.compile(routing, onto: base)
            config.orderPolicy = .canonical
            let spec = try config.makeSpec()
            let low = try renderTone(spec, rate: rate, frequency: 200, amplitude: 0.2, toneLanes: [0])
            let high = try renderTone(spec, rate: rate, frequency: min(8_000, rate * 0.2), amplitude: 0.2, toneLanes: [0])
            let lowLevels = low.map { rms($0[...]) }, highLevels = high.map { rms($0[...]) }
            let lowWay = lowLevels.indices.max { lowLevels[$0] < lowLevels[$1] } ?? 0
            XCTAssertGreaterThan(lowLevels[lowWay], 0.05, "a low tone plays at \(rate)")
            XCTAssertGreaterThan(highLevels.max() ?? 0, 0.05, "a high tone plays at \(rate)")
            XCTAssertGreaterThan(db(lowLevels[lowWay] / max(highLevels[lowWay], 1e-9)), 20, "the low way blocks highs at \(rate)")
        }
    }

    // MARK: subs

    func testSubwooferSplitSendsBassToTheSubAtEveryRate() throws {
        for rate in RateMatrix.all {
            var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: 80, redirectDB: UnifiedGraphBassManagement.twoMainMeanRedirectDB, subwoofers: [UnifiedGraphSubwoofer()])
            let spec = try configuration.makeSpec()
            XCTAssertEqual(spec.outputChannels, 3)
            let bass = try renderTone(spec, rate: rate, frequency: 40, amplitude: 0.2, seconds: 1.5)
            let treble = try renderTone(spec, rate: rate, frequency: 2_000, amplitude: 0.2, seconds: 1.5)
            XCTAssertGreaterThan(rms(bass[2][...]), 0.05, "sub plays 40 Hz at \(rate)")
            XCTAssertLessThan(db(rms(treble[2][...]) / max(rms(bass[2][...]), 1e-9)), -40, "sub blocks 2 kHz at \(rate)")
            XCTAssertGreaterThan(rms(treble[0][...]), 0.1, "mains keep 2 kHz at \(rate)")
        }
    }

    // MARK: headphone

    func testTwentyMillisecondHeadphoneEarDelayArrivesOnTimeAtEveryRate() throws {
        for rate in RateMatrix.all {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.spatialMode = .stereo
            profile.left.delayMilliseconds = 20
            let base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            let spec = try UnifiedGraphTranslator.stereoApplyHeadphone(spec: try base.makeSpec(), profile: profile).get().spec
            let frames = Int(RateCapacity.frames(seconds: 0.02, sampleRate: rate)) + 8_192
            let result = try impulseArrival(spec, frames: frames)
            XCTAssertEqual(Double(result.arrival), Double(RateCapacity.frames(seconds: 0.02, sampleRate: rate)), accuracy: 2, "ear delay at \(rate)")
        }
    }

    // MARK: binaural

    func testBinauralVirtualSpeakersRenderBothEarsAtEveryRate() throws {
        for rate in RateMatrix.all {
            var asset = BinauralProfileAsset.validationStereo(sampleRate: 48_000)
            if rate != 48_000 { asset = try asset.resampled(to: rate) }
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.programLayout = .fiveOne
            let spec = try UnifiedGraphTranslator.binauralSpec(
                asset: asset, layout: .fiveOne, profile: profile, outputChannels: 2, sampleRate: rate, headTracking: false).get()
            let out = try renderTone(spec, rate: rate, amplitude: 0.25, seconds: 0.4, toneLanes: [0])
            XCTAssertGreaterThan(rms(out[0][...]), 1e-3, "left ear at \(rate)")
            XCTAssertGreaterThan(rms(out[1][...]), 1e-3, "right ear at \(rate)")
        }
    }

    // MARK: plug-in rack and imported assets

    /// The rack's slice size is the worst case of the plug-in block at the rate, so it never runs out at 384 kHz.
    func testPlugInRackSliceCoversTheLargestDeviceBufferAtEveryRate() {
        for rate in RateMatrix.all {
            let slice = AudioUnitRackProcessingFormat.recommendedMaximumFramesPerSlice(sampleRate: rate)
            XCTAssertGreaterThan(slice, 0, "\(rate)")
            XCTAssertLessThanOrEqual(UInt32(slice), RateCapacity.largestDeviceBufferFrames, "\(rate)")
        }
    }

    func testResampledAssetKeepsItsLengthAndGainAtEveryRate() throws {
        var impulse = [Float](repeating: 0, count: 480)
        impulse[48] = 1
        for rate in RateMatrix.all where rate != 48_000 {
            let converted = try XCTUnwrap(AssetResampler.resample([impulse], from: 48_000, to: rate, quality: .precise))
            XCTAssertEqual(converted[0].count, AssetResampler.outputCount(480, from: 48_000, to: rate))
            let peak = converted[0].indices.max { abs(converted[0][$0]) < abs(converted[0][$1]) } ?? 0
            XCTAssertEqual(Double(peak), 48 * rate / 48_000, accuracy: 1, "onset at \(rate)")
            // An impulse response keeps its frequency response: going up its peak scales by source over target; going
            // down the band limit takes back what the rate ratio adds, so the peak stays near 1 (not above).
            XCTAssertEqual(Double(abs(converted[0][peak])), min(1, 48_000 / rate), accuracy: 0.07, "gain at \(rate)")
        }
    }

    // MARK: transport refusals

    /// E7 G3: a tap or input device above the ceiling is refused by name, like the output.
    func testATapRateAboveTheCeilingIsRefusedByName() throws {
        for rate in RateMatrix.all { XCTAssertNoThrow(try RateCapacity.requireSupportedTapRate(rate)) }
        XCTAssertThrowsError(try RateCapacity.requireSupportedTapRate(705_600)) { error in
            XCTAssertEqual(
                error as? CoreAudioTransportError,
                CoreAudioTransportError.sampleRateAboveSupportedMaximum(rate: 705_600, maximum: 384_000))
        }
    }

    // MARK: routed-path delay (E7 G4)

    /// A 500.3 ms way delay on the routed path arrives at 500.3 ms, not just builds, at every rate.
    func testFiveHundredMillisecondWayDelayArrivesOnTheRoutedPath() throws {
        let ep = { (i: UInt32) in PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
        for rate in RateMatrix.standard {
            var routing = try XCTUnwrap(SpeakerRoutingTemplate.twoWay.build(
                mains: [0, 1].map { lane in
                    SpeakerRoutingTemplate.Main(lane: lane, name: "M\(lane)", endpoints: [ep(UInt32(lane * 2)), ep(UInt32(lane * 2 + 1))])
                },
                subs: [], crossoverHz: [2_000]))
            for speaker in routing.speakers.indices {
                for way in routing.speakers[speaker].ways.indices {
                    routing.speakers[speaker].ways[way].delayMilliseconds = 500.3
                }
            }
            let base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            var config = try SpeakerRoutingCompiler.compile(routing, onto: base)
            config.orderPolicy = .canonical
            let spec = try config.makeSpec()
            let expected = 0.5003 * rate
            let frames = Int(expected) + 16_384
            // The crossover shapes the impulse, so find the way output with the earliest strong energy: nothing may
            // arrive before the delay, and something must arrive within the crossover's own group delay after it.
            var earliest = Int.max
            for outLane in 0..<Int(spec.outputChannels) {
                let result = try impulseArrival(spec, inLane: 0, outLane: outLane, frames: frames)
                if result.arrival >= 0 { earliest = min(earliest, result.arrival) }
            }
            XCTAssertGreaterThanOrEqual(Double(earliest), expected - 2, "nothing arrives early at \(rate)")
            XCTAssertLessThan(Double(earliest), expected + 0.01 * rate, "the delayed impulse arrives at \(rate)")
        }
    }
}
