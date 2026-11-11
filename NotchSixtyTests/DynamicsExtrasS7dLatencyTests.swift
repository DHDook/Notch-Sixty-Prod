import XCTest
@testable import NotchSixty

/// E28 S7d part 2 (G33): the compressor and multiband lookahead appear in the latency the UI and AV sync report.
final class DynamicsExtrasLatencyTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func dynamics(compressorMs: Double?, multibandMs: Double?) -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.compressor.enabled = compressorMs != nil
        d.compressor.lookaheadMs = compressorMs
        d.multibandCompressor.enabled = multibandMs != nil
        d.multibandCompressor.lookaheadMs = multibandMs
        return d
    }

    func testStagesNameEachEnabledLookaheadAtEveryRate() {
        for rate in rates {
            let d = dynamics(compressorMs: 5, multibandMs: 10)
            let stages = DynamicsLatency.stages(d, sampleRate: rate, flagOn: true)
            XCTAssertEqual(stages.map(\.name), ["Compressor lookahead", "Multiband lookahead"], "\(rate)")
            let expected = CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate)
                + CompressorConfiguration.lookaheadFrames(ms: 10, sampleRate: rate)
            XCTAssertEqual(DynamicsLatency.programFrames(d, sampleRate: rate, flagOn: true), expected, "\(rate)")
            XCTAssertGreaterThan(expected, 0)
        }
    }

    func testFlagOffAndDisabledStagesReportNothing() {
        let d = dynamics(compressorMs: 5, multibandMs: 10)
        XCTAssertEqual(DynamicsLatency.programFrames(d, sampleRate: 48_000, flagOn: false), 0)
        var off = d
        off.compressor.enabled = false
        off.multibandCompressor.enabled = false
        XCTAssertTrue(DynamicsLatency.stages(off, sampleRate: 48_000, flagOn: true).isEmpty)
        XCTAssertEqual(DynamicsLatency.programFrames(dynamics(compressorMs: 0, multibandMs: nil), sampleRate: 48_000, flagOn: true), 0)
    }

    /// The hand-over clamp is min(50 ms, 16382 frames); the longest lookahead (20 ms) must fit under it at every rate.
    func testLongestLookaheadFitsTheHandOverAlignmentClamp() {
        for rate in rates {
            let frames = CompressorConfiguration.lookaheadFrames(ms: 20, sampleRate: rate)
            XCTAssertLessThanOrEqual(Double(frames), min(0.05 * rate, 16_382), "\(rate)")
        }
    }
}
