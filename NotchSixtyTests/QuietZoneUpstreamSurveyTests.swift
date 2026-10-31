import Foundation
import XCTest
@testable import NotchSixty

/// E4 S24: the upstream (step 2) survey on simulated stationary noise at the eight standard rates.
final class QuietZoneUpstreamSurveyTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let latency = 0.005
    private let flight = 0.003  // budget with the 1 ms margin: 9 ms

    /// The reference hears x; the seat monitor hears gain * x delayed by `leadSeconds` plus its own noise.
    private func run(
        rate: Double, leadSeconds: Double, gain: Float, ownNoise: Float, seconds: Double = 12
    ) -> (run: QuietZoneUpstreamSurveyRun, lead: Double) {
        let delay = Int((leadSeconds * rate).rounded())
        let survey = QuietZoneUpstreamSurveyRun(sampleRate: rate)!
        var common = SplitMix(seed: 0xA11CE)
        var own = SplitMix(seed: 0xB0B)
        var history = [Float](repeating: 0, count: delay + 1)
        var position = 0
        var time = 0.0
        let total = Int(seconds * rate)
        var made = 0
        while made < total {
            let count = min(16_384, total - made)
            var frames: [N60FeedForwardReferenceFrame] = []
            var error: [Float] = []
            frames.reserveCapacity(count)
            error.reserveCapacity(count)
            for offset in 0..<count {
                let x = common.next()
                history[position] = x
                position = (position + 1) % history.count
                var frame = N60FeedForwardReferenceFrame()
                frame.sample = x
                frame.firstFrameSampleTime = time
                frame.frameOffset = UInt32(offset)
                frame.firstFrameHostTime = 1
                frames.append(frame)
                error.append(gain * history[position] + ownNoise * own.next())
            }
            time += Double(count)
            made += count
            survey.ingest(reference: frames, error: error)
        }
        return (survey, Double(delay) / rate)
    }

    func testLeadWithinATenthOfAMillisecondAndPredictionWithinADecibelAtEveryRate() {
        for rate in rates {
            let (survey, truth) = run(rate: rate, leadSeconds: 0.012, gain: 0.9, ownNoise: 0.3)
            let result = survey.assess(latencySeconds: latency, flightSeconds: flight)
            XCTAssertEqual(result.verdict, .suitable, "\(rate) Hz")
            XCTAssertEqual(result.leadSeconds, truth, accuracy: 0.0001, "\(rate) Hz")
            XCTAssertEqual(result.budgetSeconds, 0.009, accuracy: 1e-9)
            // The twin: coherence 0.81 / (0.81 + 0.09) = 0.9.
            let twin = QuietZoneUpstreamAssessment.reductionBoundDB(coherence: 0.9)
            let predicted = try? XCTUnwrap(result.predictedReductionDB)
            XCTAssertEqual(predicted ?? .nan, twin, accuracy: 1.0, "\(rate) Hz")
            XCTAssertGreaterThan(result.meanCoherence, QuietZoneUpstreamAssessment.minimumCoherence)
        }
    }

    func testAShortLeadSaysMoveFurtherOut() {
        for rate in rates {
            let (survey, truth) = run(rate: rate, leadSeconds: 0.006, gain: 0.9, ownNoise: 0.3, seconds: 8)
            let result = survey.assess(latencySeconds: latency, flightSeconds: flight)
            XCTAssertEqual(result.verdict, .moveFurtherOut, "\(rate) Hz")
            XCTAssertEqual(result.leadSeconds, truth, accuracy: 0.0001, "\(rate) Hz")
            XCTAssertNil(result.predictedReductionDB)
        }
    }

    func testClockOffsetErrorCanTurnASuitableLeadIntoMoveFurtherOut() {
        let (survey, _) = run(rate: 48_000, leadSeconds: 0.012, gain: 0.9, ownNoise: 0.3, seconds: 8)
        XCTAssertEqual(survey.assess(latencySeconds: latency, flightSeconds: flight).verdict, .suitable)
        let blurred = survey.assess(latencySeconds: latency, flightSeconds: flight, clockOffsetErrorSeconds: 0.004)
        XCTAssertEqual(blurred.verdict, .moveFurtherOut)
        XCTAssertGreaterThanOrEqual(blurred.leadUncertaintySeconds, 0.004)
    }

    func testDifferentNoiseIsLowCoherenceAndNoNoiseIsNoCommonNoise() {
        let weak = run(rate: 48_000, leadSeconds: 0.012, gain: 0.3, ownNoise: 0.9, seconds: 8).run
            .assess(latencySeconds: latency, flightSeconds: flight)
        XCTAssertEqual(weak.verdict, .lowCoherence)
        XCTAssertNil(weak.predictedReductionDB)
        let none = run(rate: 48_000, leadSeconds: 0.012, gain: 0, ownNoise: 0.9, seconds: 8).run
            .assess(latencySeconds: latency, flightSeconds: flight)
        XCTAssertEqual(none.verdict, .noCommonNoise)
    }

    func testTooLittleCaptureGivesNoEstimate() {
        let estimator = QuietZoneUpstreamLeadEstimator(sampleRate: 48_000)
        estimator.ingest(reference: [Float](repeating: 0.1, count: 48_000), error: [Float](repeating: 0.1, count: 48_000))
        XCTAssertNil(estimator.estimate())
        let result = QuietZoneUpstreamAssessment.assess(
            estimate: nil, bands: [], latencySeconds: latency, flightSeconds: flight)
        XCTAssertEqual(result.verdict, .noCommonNoise)
    }

    func testReductionBoundIsCappedAndReferenceKindsAreLabelled() {
        XCTAssertEqual(QuietZoneUpstreamAssessment.reductionBoundDB(coherence: 0.5), 3.0103, accuracy: 0.001)
        XCTAssertEqual(QuietZoneUpstreamAssessment.reductionBoundDB(coherence: 1), 30)
        XCTAssertEqual(QuietZoneUpstreamAssessment.reductionBoundDB(coherence: 0.99999), 30)
        XCTAssertEqual(QuietZoneReferenceInputKind.allCases.map(\.label),
                       ["Microphone", "Contact microphone", "Accelerometer"])
        let accelerometer = QuietZoneUpstreamAssessment.assess(
            estimate: nil, bands: [], latencySeconds: 0, flightSeconds: 0, referenceKind: .accelerometer)
        XCTAssertEqual(accelerometer.referenceKind, .accelerometer)
    }
}

/// Deterministic uniform noise in [-0.1, 0.1).
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Int64(z >> 11) % 2_000_000 - 1_000_000) / 10_000_000
    }
}
