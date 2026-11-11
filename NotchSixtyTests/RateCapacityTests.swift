import XCTest
@testable import NotchSixty

/// E7 S1: capacities are times. Behavioural, through the production translators and the graph host, at the eight
/// standard rates: a 20 ms headphone ear delay, a 500 ms fractional delay on every path that builds one, the fixed
/// 65,536-frame rings against the largest buffer and transform at 384 kHz, the 20 ms look-ahead at 4x, and the
/// refusal above 384 kHz.
final class RateCapacityTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 4_096

    /// Feeds a unit impulse on `lane` of `inputs` lanes and returns the arrival frame of the largest sample on `outLane`.
    private func arrival(_ spec: UnifiedGraphSpec, inLane: Int, outLane: Int, frames: Int) throws -> Int {
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        var peak: Float = 0
        var best = -1
        var done = 0
        while done < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(spec.inputChannels))
            if done == 0 { input[inLane][0] = 1 }
            let out = try host.processOffline(input: input, frames: block)
            for i in 0..<block where abs(out[outLane][i]) > peak {
                peak = abs(out[outLane][i]); best = done + i
            }
            done += block
        }
        return best
    }

    private func total(_ seconds: Double, _ rate: Double) -> Int { Int(RateCapacity.frames(seconds: seconds, sampleRate: rate)) }

    // MARK: helpers

    func testFramesIsCeilingOfTimeAndSaturates() {
        for rate in Self.rates {
            XCTAssertEqual(RateCapacity.frames(seconds: 0.020, sampleRate: rate), UInt32((0.020 * rate).rounded(.up)))
        }
        XCTAssertEqual(RateCapacity.frames(seconds: -1, sampleRate: 48_000), 0)
        XCTAssertEqual(RateCapacity.frames(seconds: .nan, sampleRate: 48_000), 0)
        XCTAssertEqual(RateCapacity.frames(seconds: 1e12, sampleRate: 48_000), .max)
    }

    func testFractionalSplitKeepsShortDelaysAsOneStageAndSplitsLongOnes() throws {
        let short = try XCTUnwrap(RateCapacity.splitFractionalDelay(totalFrames: 4_000.25))
        XCTAssertEqual(short, .init(wholeFrames: 0, stageWhole: 4_000, fraction: 0.25))
        let long = try XCTUnwrap(RateCapacity.splitFractionalDelay(totalFrames: 192_000.5))
        XCTAssertEqual(long.wholeFrames, 191_984)
        XCTAssertEqual(long.stageWhole, 16)
        XCTAssertEqual(Double(long.wholeFrames) + long.stageWhole + long.fraction, 192_000.5, accuracy: 1e-9)
        XCTAssertNil(RateCapacity.splitFractionalDelay(totalFrames: -1))
        XCTAssertNil(RateCapacity.splitFractionalDelay(totalFrames: .infinity))
        XCTAssertNil(RateCapacity.splitFractionalDelay(totalFrames: Double(N60_GRAPH_MAX_DELAY_FRAMES) + 1))
    }

    // MARK: headphone ear delay, 0 to 20 ms at every rate

    func testTwentyMillisecondHeadphoneDelayAttachesAndMeasuresAtEveryRate() throws {
        for rate in Self.rates {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.spatialMode = .stereo
            profile.left.delayMilliseconds = 20
            profile.right.delayMilliseconds = 12.5
            XCTAssertNoThrow(try profile.left.validate(sampleRate: rate), "model validation at \(rate)")
            XCTAssertTrue(UnifiedGraphTranslator.headphoneStagesEligible(profile: profile, sampleRate: rate), "\(rate)")
            let configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            let applied = try UnifiedGraphTranslator.stereoApplyHeadphone(spec: try configuration.makeSpec(), profile: profile).get()
            XCTAssertEqual(applied.earDelayFrames[0], UInt32((rate * 0.020).rounded()), "left ear frames at \(rate)")
            let delays = applied.spec.stages.filter { $0.stageId >= 2_400 && $0.stageId < 2_402 }
            XCTAssertEqual(delays.map(\.capacityFrames), [UInt32(total(0.020, rate)), UInt32(total(0.020, rate))])
            let left = try arrival(applied.spec, inLane: 0, outLane: 0, frames: total(0.020, rate) + 2 * block)
            XCTAssertEqual(left, Int((rate * 0.020).rounded()), accuracy: 1, "20 ms left ear at \(rate)")
            let right = try arrival(applied.spec, inLane: 1, outLane: 1, frames: total(0.020, rate) + 2 * block)
            XCTAssertEqual(right, Int((rate * 0.0125).rounded()), accuracy: 1, "12.5 ms right ear at \(rate)")
        }
    }

    func testHeadphoneDelayAboveTwentyMillisecondsIsStillRefused() {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.spatialMode = .stereo
        profile.left.delayMilliseconds = 20.5
        XCTAssertThrowsError(try profile.left.validate(sampleRate: 48_000))
        XCTAssertFalse(UnifiedGraphTranslator.headphoneStagesEligible(profile: profile, sampleRate: 48_000))
    }

    func testKernelSnapshotClampsAndSaysSoWhenTheDelayExceedsItsCapacity() throws {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.spatialMode = .stereo
        profile.left.delayMilliseconds = 20
        XCTAssertFalse(profile.kernelRendersDelays(sampleRate: 352_800))
        XCTAssertTrue(profile.kernelRendersDelays(sampleRate: 192_000))
        XCTAssertTrue(profile.kernelRendersDelays(sampleRate: 48_000))
        let snapshot = try profile.makeRealtimeSnapshot(sampleRate: 384_000)
        XCTAssertEqual(snapshot.channels.0.delayFrames, UInt32(N60_HEADPHONE_MAX_DELAY_FRAMES))
    }

    // MARK: fractional delay, 500 ms at every rate

    func testFiveHundredMillisecondLaneFractionalDelayOnTheConfigurationPath() throws {
        for rate in Self.rates {
            let frames = Double(total(0.5, rate)) + 0.0
            var lane = UnifiedGraphLane()
            lane.fractionalDelayFrames = frames
            let configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, UnifiedGraphLane()])
            let spec = try configuration.makeSpec()
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_FRAC_DELAY.rawValue }.count, 1)
            let host = try UnifiedGraphHost(spec: spec)
            XCTAssertEqual(Double(host.latencyFrames), frames, accuracy: 1, "latency at \(rate)")
            host.release()
            let at = try arrival(spec, inLane: 0, outLane: 0, frames: Int(frames) + 2 * block)
            XCTAssertEqual(Double(at), frames, accuracy: 1, "500 ms at \(rate)")
        }
    }

    func testFiveHundredMillisecondFractionalDelayOnTheProgramPath() throws {
        for rate in Self.rates {
            let frames = Double(total(0.5, rate)) + 0.0
            var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            base.lanes[0].fractionalDelayFrames = frames
            base.lanes[1].fractionalDelayFrames = frames
            base.stereoStages = UnifiedGraphStereoStages()
            let dsp = UnifiedGraphProgramDSP(
                stereo: base, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight])), eqMode: .linked)
            var configuration = UnifiedGraphTranslator.multichannelConfiguration(
                sampleRate: rate, programChannels: 2, subwoofers: [])
            configuration.orderPolicy = .canonical
            configuration.programDSP = dsp
            let spec = try configuration.makeSpec()
            let at = try arrival(spec, inLane: 0, outLane: 0, frames: Int(frames) + 2 * block)
            XCTAssertEqual(Double(at), frames, accuracy: 1, "500 ms program path at \(rate)")
        }
    }

    func testFiveHundredMillisecondWayDelayOnTheRoutedPath() throws {
        let ep = { (i: UInt32) in PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
        for rate in Self.rates {
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
            XCTAssertTrue(spec.stages.contains { $0.kind == N60_STAGE_FRAC_DELAY.rawValue }, "fraction kept at \(rate)")
            _ = try UnifiedGraphHost(spec: spec).release()
        }
    }

    // MARK: fixed rings and look-ahead

    func testFixedRingsHoldTheLargestBufferAndTransformAtTheHighestRate() {
        let ring = RateCapacity.fixedRingFrames
        XCTAssertGreaterThanOrEqual(ring, 2 * RateCapacity.largestDeviceBufferFrames)
        XCTAssertGreaterThanOrEqual(ring, 2 * RateCapacity.largestAnalysisTransformFrames)
        XCTAssertEqual(UnifiedGraphAnalyserTaps.capacityFrames, ring)
        XCTAssertEqual(UnifiedGraphConfiguration(sampleRate: 384_000, lanes: []).maxBlockFrames, ring)
        XCTAssertEqual(CoreAudioTransportSession.bridgeCapacityFrames, ring)
        XCTAssertEqual(CoreAudioNChannelTransportSession.bridgeCapacityFrames, ring)
        XCTAssertEqual(CoreAudioBinauralHeadphoneTransportSession.bridgeCapacityFrames, ring)
        XCTAssertEqual(CoreAudioNChannelTransportSession.graphMaxBlockFrames, RateCapacity.largestDeviceBufferFrames)
        // The N-channel and binaural bridges accept a device buffer up to the largest one at 384 kHz (about 85 ms).
        XCTAssertLessThan(Double(RateCapacity.largestDeviceBufferFrames) / 384_000, Double(ring) / 384_000)
    }

    func testTwentyMillisecondLookAheadAtFourTimesOversamplingBuildsAtEveryRate() throws {
        for rate in Self.rates {
            var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            configuration.protection = UnifiedGraphProtection(
                ceilingDB: -1, attackMilliseconds: 0.5, releaseMilliseconds: 90,
                lookAheadMilliseconds: RateCapacity.protectionLookAheadMaximumSeconds * 1_000, truePeakGuard: true, oversampling: 4)
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            XCTAssertGreaterThan(host.latencyFrames, 0)
            host.release()
        }
    }

    // MARK: above 384 kHz

    func testRatesAboveTheSupportedMaximumAreRefusedWithANamedReason() {
        XCTAssertEqual(RateCapacity.supportedMaximumSampleRate, 384_000)
        let error = CoreAudioTransportError.sampleRateAboveSupportedMaximum(rate: 705_600, maximum: 384_000)
        XCTAssertEqual(
            error.errorDescription,
            "This output is running at 705600 Hz. Notch Sixty supports rates up to 384000 Hz; set the device to 384000 Hz or lower in Audio MIDI Setup.")
    }
}
