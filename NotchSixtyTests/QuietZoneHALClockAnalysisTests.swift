import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneHALClockAnalysisTests: XCTestCase {
    private let analyzer = QuietZoneHALClockAnalyzer()

    private func observations(
        rate: Double = 48_000,
        count: Int = 12,
        jitterSeconds: Double = 0,
        jumpAt: Int? = nil
    ) -> [QuietZoneHALClockObservation] {
        (0..<count).map { index in
            let t = Double(index) * 0.25
            let jitter = index % 2 == 0 ? jitterSeconds : -jitterSeconds
            let discontinuity = jumpAt.map { index >= $0 ? 128.0 : 0 } ?? 0
            return QuietZoneHALClockObservation(
                hostTimeSeconds: 5_000 + t,
                sampleFrame: 1_000_000 + (t + jitter) * rate + discontinuity
            )
        }
    }

    private func trace(
        input: [QuietZoneHALClockObservation]? = nil,
        output: [QuietZoneHALClockObservation]? = nil
    ) -> QuietZoneHALClockTrace {
        QuietZoneHALClockTrace(
            inputDeviceID: "USB measurement mic",
            outputDeviceID: "speaker DAC",
            nominalSampleRate: 48_000,
            inputObservations: input ?? observations(),
            outputObservations: output ?? observations()
        )
    }

    func testStableIndependentClocksQualifyForLoopbackOnly() throws {
        let result = try analyzer.analyze(
            trace(output: observations(rate: 48_001))
        )
        XCTAssertTrue(result.qualifiedForLoopbackBench)
        XCTAssertEqual(result.relativeDriftPPM, 1 / 48_000 * 1_000_000,
                       accuracy: 0.01)
        XCTAssertEqual(result.observationDurationSeconds, 2.75, accuracy: 1e-9)
        XCTAssertFalse(result.physicalLatencyMeasured)
        XCTAssertFalse(result.liveANCQualified)
    }

    func testSignificantDriftRejectsBenchQualification() {
        XCTAssertThrowsError(try analyzer.analyze(
            trace(output: observations(rate: 48_014))
        )) { error in
            XCTAssertEqual(error as? QuietZoneHALClockError, .excessiveDrift)
        }
    }

    func testDiscontinuityWithinClockStreamFailsClosed() {
        var broken = observations()
        broken[5].sampleFrame = broken[4].sampleFrame - 1
        XCTAssertThrowsError(try analyzer.analyze(
            trace(input: broken)
        )) { error in
            XCTAssertEqual(error as? QuietZoneHALClockError, .clockDiscontinuity)
        }
    }

    func testTimestampJitterBeyondBoundRejectsQualification() {
        XCTAssertThrowsError(try analyzer.analyze(
            trace(input: observations(jitterSeconds: 0.001))
        )) { error in
            XCTAssertEqual(error as? QuietZoneHALClockError, .excessiveJitter)
        }
    }

    func testSingleCallbackSnapshotIsNotClockEvidence() {
        XCTAssertThrowsError(try analyzer.analyze(
            trace(input: observations(count: 1))
        )) { error in
            XCTAssertEqual(error as? QuietZoneHALClockError,
                           .insufficientObservation)
        }
    }

    func testUnrelatedOrInvalidTimebaseCannotQualify() {
        var bad = trace()
        bad.nominalSampleRate = .nan
        XCTAssertThrowsError(try analyzer.analyze(bad))
        bad = trace()
        bad.inputObservations[2].hostTimeSeconds = .infinity
        XCTAssertThrowsError(try analyzer.analyze(bad))
    }

    func testReferenceAndOutputObservationArraysMustBeIndependent() throws {
        let qualified = try analyzer.analyze(
            trace(input: observations(rate: 47_999),
                  output: observations(rate: 48_001))
        )
        XCTAssertGreaterThan(qualified.relativeDriftPPM, 0)
        XCTAssertTrue(qualified.qualifiedForLoopbackBench)
        XCTAssertFalse(qualified.liveANCQualified)
    }
}
