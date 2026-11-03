import XCTest
@testable import NotchSixty

/// E25 S6: Quiet Zone eligibility with synthetic latencies at the eight standard rates, and the two-feed MIMO set.
final class TwoChannelAncEligibilityTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func arrangement(_ bass: BassHandling, layout: OutputProgramLayout = .stereo, channels: Int = 2) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 8, channelsInUse: channels,
            choices: .init(layout: layout, bass: bass, subwooferCount: bass == .dspToSubOutputs || bass.isDownstream ? 1 : 0))
    }

    func testEligibilityTableAtEightRates() {
        let preview = 0.020
        let required = QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds
        let cases: [(String, SystemArrangement)] = [
            ("B", arrangement(.fullRange)), ("C", arrangement(.dspMonoToMains)),
            ("D", arrangement(.downstreamSubCrossover)), ("E", arrangement(.downstreamReceiver, layout: .fiveOne)),
        ]
        for rate in rates {
            // 10 ms of frames fits (reserve 8 ms); 19 ms leaves under the required reserve.
            let fits = TwoChannelAncEligibility.seconds(frames: Int((0.010 * rate).rounded()), sampleRate: rate)
            let over = TwoChannelAncEligibility.seconds(frames: Int((0.019 * rate).rounded()), sampleRate: rate)
            for (name, a) in cases {
                guard case .eligible(let reserve) = TwoChannelAncEligibility.evaluate(
                    arrangement: a, feedLatencyUpperBoundSeconds: fits, conservativePreviewSeconds: preview)
                else { return XCTFail("class \(name) at \(rate) should be eligible") }
                XCTAssertEqual(reserve, preview - fits - required, accuracy: 1e-9)
                guard case .refused(let reason) = TwoChannelAncEligibility.evaluate(
                    arrangement: a, feedLatencyUpperBoundSeconds: over, conservativePreviewSeconds: preview)
                else { return XCTFail("class \(name) at \(rate) should be refused") }
                XCTAssertTrue(reason.contains("short by"), reason)
            }
        }
    }

    func testReceiverClassesNeedAMeasurementAndNamesTheReceiver() {
        for a in [arrangement(.downstreamSubCrossover), arrangement(.downstreamReceiver, layout: .fiveOne)] {
            guard case .refused(let reason) = TwoChannelAncEligibility.evaluate(
                arrangement: a, feedLatencyUpperBoundSeconds: nil, conservativePreviewSeconds: 0.02)
            else { return XCTFail("unmeasured receiver feed must be refused") }
            XCTAssertTrue(reason.contains("receiver"))
        }
        for bad in [Double.nan, -1, .infinity] {
            guard case .refused = TwoChannelAncEligibility.evaluate(
                arrangement: arrangement(.fullRange), feedLatencyUpperBoundSeconds: bad, conservativePreviewSeconds: 0.02)
            else { return XCTFail("invalid latency \(bad) must be refused") }
        }
        guard case .refused = TwoChannelAncEligibility.evaluate(
            arrangement: arrangement(.fullRange), feedLatencyUpperBoundSeconds: 0.005, conservativePreviewSeconds: nil)
        else { return XCTFail("missing survey must be refused") }
    }

    func testDirectMultiOutputIsRefusedRegardlessOfLatency() {
        let a = arrangement(.dspToSubOutputs, layout: .fiveOne, channels: 6)
        guard case .refused = TwoChannelAncEligibility.evaluate(
            arrangement: a, feedLatencyUpperBoundSeconds: 0, conservativePreviewSeconds: 1)
        else { return XCTFail("class A must be refused") }
    }

    func testEligibilityIsDecisionOnlyAndMatchesMatrixClasses() {
        // The result carries no arming data: only a reserve in seconds or a reason.
        let r = TwoChannelAncEligibility.evaluate(
            arrangement: arrangement(.fullRange), feedLatencyUpperBoundSeconds: 0.001, conservativePreviewSeconds: 0.02)
        XCTAssertEqual(r, .eligible(reserveSeconds: 0.02 - 0.001 - QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds))
    }

    func testMimoSourcesLimitedToTwoFeedsOnTwoChannels() {
        let all: [MultichannelCalibrationSource] = [.speaker(.frontLeft), .speaker(.frontRight), .subwoofer(0)]
        for a in [arrangement(.fullRange), arrangement(.dspMonoToMains), arrangement(.downstreamSubCrossover),
                  arrangement(.downstreamReceiver, layout: .fiveOne)] {
            XCTAssertEqual(TwoChannelMimoSources.restrict(all, arrangement: a), [.speaker(.frontLeft), .speaker(.frontRight)])
        }
        let direct = arrangement(.dspToSubOutputs, layout: .fiveOne, channels: 6)
        XCTAssertEqual(TwoChannelMimoSources.restrict(all, arrangement: direct), all)
        XCTAssertEqual(TwoChannelMimoSources.restrict(all, arrangement: nil), all)
    }
}
