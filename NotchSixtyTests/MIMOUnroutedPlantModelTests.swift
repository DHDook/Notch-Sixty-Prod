import XCTest
@testable import NotchSixty

/// E19 S8 remainder (G33, G34): the unrouted plant model. Downstream chain, FFT convolution, arrival onset, the real programme
/// feed at the stage and the default support range, at the standard rates where a rate matters.
final class MIMOUnroutedPlantModelTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testFFTConvolutionMatchesTheDirectSum() {
        var seed: UInt32 = 12345
        func noise(_ n: Int) -> [Float] {
            (0..<n).map { _ in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        }
        let a = noise(700), b = noise(300)
        let fast = MIMOUnroutedPlantModel.convolve(a, b)
        var direct = [Float](repeating: 0, count: a.count + b.count - 1)
        for i in 0..<a.count { for j in 0..<b.count { direct[i + j] += a[i] * b[j] } }
        XCTAssertEqual(fast.count, direct.count)
        let worst = zip(fast, direct).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-3)
    }

    func testDownstreamChainCarriesGainPolarityDelayAndTheCorrectionFIR() {
        var lane = UnifiedGraphLane()
        lane.outputGain = 0.5
        lane.polarityInverted = true
        lane.delayFrames = 10
        lane.calibrationDelayFrames = 5
        var config = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [lane, UnifiedGraphLane()])
        config.outputProtection = nil
        var chain = MIMOUnroutedPlantModel.downstreamChain(of: config, lane: 0)
        XCTAssertEqual(chain.count, 16)
        XCTAssertEqual(chain[15], -0.5, accuracy: 1e-6)
        XCTAssertEqual(chain.enumerated().filter { $0.offset != 15 }.map { abs($0.element) }.max() ?? 0, 0, accuracy: 1e-9)
        config.stereoStages.roomFIR = UnifiedGraphFIRProgram(generation: 1, left: [1, 0, 0.5], right: nil, declaredLatencyFrames: 0)
        chain = MIMOUnroutedPlantModel.downstreamChain(of: config, lane: 0)
        XCTAssertEqual(chain[15], -0.5, accuracy: 1e-6)
        XCTAssertEqual(chain[17], -0.25, accuracy: 1e-6)
        // The second lane has unit gain and no delay.
        XCTAssertEqual(MIMOUnroutedPlantModel.downstreamChain(of: config, lane: 1)[0], 1, accuracy: 1e-6)
    }

    func testArrivalOnsetIsEarlierThanTheLargestSampleOfALateModeBuildUp() {
        for rate in rates {
            var plant = [Float](repeating: 0, count: Int(rate * 0.2))
            let onset = Int(rate * 0.004)
            plant[onset] = 0.3
            plant[Int(rate * 0.02)] = 1
            let arrival = MIMOUnroutedPlantModel.arrivalSeconds(of: plant, sampleRate: rate)
            XCTAssertEqual(try XCTUnwrap(arrival), Double(onset) / rate, accuracy: 1e-9, "rate \(rate)")
        }
        XCTAssertNil(MIMOUnroutedPlantModel.arrivalSeconds(of: [0, 0], sampleRate: 48_000))
    }

    func testUpstreamFeedsShowBassManagementAndIgnoreTheDownstreamChain() throws {
        for rate in [48_000.0, 384_000.0] {
            var lane = UnifiedGraphLane()
            lane.outputGain = 0.25
            lane.delayFrames = 100
            var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, lane])
            var bass = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
            bass.crossoverHz = 80
            bass.redirectDB = UnifiedGraphBassManagement.twoMainMeanRedirectDB
            bass.subwoofers = [UnifiedGraphSubwoofer()]
            config.bassManagement = bass
            let feeds = try MIMOUnroutedPlantModel.upstreamFeeds(of: config, lanes: [0, 1, 2])
            XCTAssertEqual(feeds.count, 3)
            func level(_ feed: [Float], _ hz: Double) -> Double { MIMORoutedTreatmentPlanner.magnitudeDB(feed, hz: hz, sampleRate: rate) }
            XCTAssertGreaterThan(level(feeds[2], 40), level(feeds[0], 40) + 12, "rate \(rate): the sub carries the bass the mains lose")
            XCTAssertGreaterThan(level(feeds[0], 400), level(feeds[2], 400) + 12, "rate \(rate)")
            // The lane gain and delay are downstream: the main feed at 400 Hz sits near unity and arrives at once.
            XCTAssertEqual(level(feeds[0], 400), 0, accuracy: 1.5, "rate \(rate)")
            let peak = feeds[0].enumerated().max { abs($0.element) < abs($1.element) }?.offset ?? 0
            XCTAssertLessThan(Double(peak) / rate, 0.02, "rate \(rate)")
        }
    }

    func testUnequalFeedsChangeThePredictedFilter() throws {
        let rate = 48_000.0
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        let taps = 8
        let filters = MIMOTreatmentFilterSet(
            sampleRate: rate, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: 2, tapCount: taps, tauSeconds: 0,
            taps: [Float](repeating: 0, count: 2 * 2 * taps), solved: [], gridLowHz: 0, gridBins: 0)
        let equal = try MIMOTreatmentController.predictedFilters(filters: filters, feeds: nil, rate: rate)
        XCTAssertEqual(equal.treated[0][0], 1, accuracy: 1e-6)
        let unequal = try MIMOTreatmentController.predictedFilters(filters: filters, feeds: [[1], [0.25]], rate: rate)
        XCTAssertGreaterThan(abs(unequal.treated[0][0]), 0.01)
        XCTAssertEqual(unequal.treated[1][0] / unequal.treated[0][0], 0.25, accuracy: 1e-4, "the second source carries a quarter of the feed")
    }

    /// A second-order Butterworth high pass at `cornerHz` as an impulse response, so the capture rolls off by 12 dB per octave.
    private func highPass(cornerHz: Double, rate: Double, seconds: Double = 0.5) -> [Float] {
        let w = tan(Double.pi * cornerHz / rate)
        let q = 2.0.squareRoot() / 2
        let norm = 1 / (1 + w / q + w * w)
        let b0 = norm, b1 = -2 * norm, b2 = norm
        let a1 = 2 * (w * w - 1) * norm, a2 = (1 - w / q + w * w) * norm
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return (0..<Int(rate * seconds)).map { n in
            let x = n == 0 ? 1.0 : 0
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return Float(y)
        }
    }

    func testDefaultSupportFollowsTheMinusTenDBPointAtEveryRate() {
        for rate in rates {
            let range = MIMOUnroutedPlantModel.defaultSupportHz(captures: [highPass(cornerHz: 40, rate: rate)], sampleRate: rate)
            // 12 dB per octave: -10 dB sits about 0.74 octave below the corner, near 24 Hz.
            XCTAssertEqual(range.lowerBound, 24, accuracy: 4, "rate \(rate)")
            XCTAssertEqual(range.upperBound, 150, "rate \(rate)")
        }
        let flat = [Float(1)] + [Float](repeating: 0, count: 4_000)
        XCTAssertEqual(MIMOUnroutedPlantModel.defaultSupportHz(captures: [flat], sampleRate: 48_000), 15.0...150.0)
        XCTAssertEqual(MIMOUnroutedPlantModel.defaultSupportHz(captures: [], sampleRate: 48_000), 15.0...150.0)
    }
}
