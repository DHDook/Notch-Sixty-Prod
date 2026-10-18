import Foundation
import XCTest
@testable import NotchSixty

/// E4 S9b1: the feed-forward survey core (`N60FeedForwardSurvey`) through its
/// C interface at the eight standard rates. The statistical checks live in
/// ci/harness_e4_ff_survey.c and the reference lab
/// (ci/acoustic_reference_lab/e4_ff_survey_reference.py).
final class FeedForwardSurveyTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let bands: [Float] = (0..<16).map { Float(25 * pow(2, Double($0) / 6)) }

    private func makeSurvey(rate: Double) throws -> OpaquePointer {
        var config = N60FeedForwardSurveyConfigDefault(rate)
        config.bandCount = UInt32(bands.count)
        withUnsafeMutableBytes(of: &config.bandHz) { raw in
            let hz = raw.bindMemory(to: Float.self)
            for (k, f) in bands.enumerated() { hz[k] = f }
        }
        return try XCTUnwrap(N60FeedForwardSurveyCreate(&config), "\(rate) Hz")
    }

    private func transfers(_ result: N60FeedForwardSurveyResult) -> [N60AncComplex] {
        withUnsafeBytes(of: result.transfer) { Array($0.bindMemory(to: N60AncComplex.self)) }
    }

    private func coherences(_ result: N60FeedForwardSurveyResult) -> [Float] {
        withUnsafeBytes(of: result.coherence) { Array($0.bindMemory(to: Float.self)) }
    }

    /// e = 0.5 x delayed by 2 ms: H = 0.5 exp(-j 2 pi f d / fs), coherence 1.
    func testMeasuresADelayedGainAtEveryStandardRate() throws {
        for rate in rates {
            let survey = try makeSurvey(rate: rate)
            defer { N60FeedForwardSurveyDestroy(survey) }
            let delay = Int((0.002 * rate).rounded())
            var generator = SeededGenerator(seed: 3)
            let frames = 512
            var history = [Float](repeating: 0, count: delay + frames)
            for _ in 0..<(Int(rate) * 8 / frames) {
                for i in 0..<frames {
                    history[delay + i] = Float.random(in: -0.1...0.1, using: &generator)
                }
                let x = Array(history[delay...])
                let e = history[0..<frames].map { 0.5 * $0 }
                N60FeedForwardSurveyProcess(survey, x, e, UInt32(frames))
                history.replaceSubrange(0..<delay, with: history[frames..<(frames + delay)])
            }
            let result = N60FeedForwardSurveyRead(survey)
            XCTAssertGreaterThanOrEqual(result.segments, 13, "\(rate) Hz")
            XCTAssertEqual(result.gaps, 0)
            let measured = zip(transfers(result), coherences(result)).prefix(bands.count)
            for (k, (h, g2)) in measured.enumerated() {
                let angle = -2 * Double.pi * Double(bands[k]) * Double(delay) / rate
                let error = hypot(Double(h.re) - 0.5 * cos(angle), Double(h.im) - 0.5 * sin(angle))
                XCTAssertLessThan(error, 0.005, "\(rate) Hz at \(bands[k]) Hz")
                XCTAssertGreaterThan(g2, 0.999, "\(rate) Hz at \(bands[k]) Hz")
            }
        }
    }

    func testNonFiniteRunIsOneGapAndResetClears() throws {
        let survey = try makeSurvey(rate: 48_000)
        defer { N60FeedForwardSurveyDestroy(survey) }
        let bad = [Float](repeating: .nan, count: 64)
        N60FeedForwardSurveyProcess(survey, bad, bad, 64)
        N60FeedForwardSurveyProcess(survey, bad, bad, 64)
        XCTAssertEqual(N60FeedForwardSurveyRead(survey).gaps, 1)
        N60FeedForwardSurveyReset(survey)
        XCTAssertEqual(N60FeedForwardSurveyRead(survey).gaps, 0)
    }

    func testRejectsBandsOutsideTheDecimatedRange() {
        var config = N60FeedForwardSurveyConfigDefault(48_000)
        config.bandCount = 1
        config.bandHz.0 = 1_500
        XCTAssertFalse(N60FeedForwardSurveyConfigIsValid(&config))
        config.bandHz.0 = 60
        XCTAssertTrue(N60FeedForwardSurveyConfigIsValid(&config))
        config.sampleRate = 1_000_000
        XCTAssertNil(N60FeedForwardSurveyCreate(&config))
    }
}

/// Deterministic generator (SplitMix64) so the test input repeats.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
