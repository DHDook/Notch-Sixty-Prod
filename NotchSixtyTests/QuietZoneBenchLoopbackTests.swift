import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneBenchLoopbackTests: XCTestCase {
    private func clock() -> QuietZoneHALClockTrace {
        let stamps = (0..<12).map { index in
            QuietZoneHALClockObservation(
                hostTimeSeconds: 100 + Double(index) * 0.25,
                sampleFrame: 20_000 + Double(index) * 12_000
            )
        }
        return QuietZoneHALClockTrace(
            inputDeviceID: "USB-mic", outputDeviceID: "USB-DAC",
            nominalSampleRate: 48_000,
            inputObservations: stamps, outputObservations: stamps
        )
    }

    private func probe() -> [Float] {
        var state: UInt32 = 0x4242ABCD
        return (0..<128).map { _ in
            state = state &* 1664525 &+ 1013904223
            return (state & 0x8000_0000) == 0 ? 0.5 : -0.5
        }
    }

    private func capture(
        offset: Int = 480, route: String = "wired-loop",
        clockUncertainty: Double = 0.00001
    ) -> QuietZoneBenchLoopbackCapture {
        let signal = probe()
        var samples = [Float](repeating: 0.0001, count: 2048)
        for i in signal.indices {
            samples[offset + i] += signal[i] * 0.4
        }
        return QuietZoneBenchLoopbackCapture(
            routeFingerprint: route,
            inputDeviceID: "USB-mic", outputDeviceID: "USB-DAC",
            nominalSampleRate: 48_000, stimulus: signal,
            recorded: samples, stimulusStartHostSeconds: 100,
            firstRecordedFrameHostSeconds: 100.002,
            clockUncertaintySeconds: clockUncertainty,
            captureClipped: false
        )
    }

    func testMeasuredElectricalRoundTripHasConservativeUpperBound() throws {
        let result = try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(), capture(), capture()], clock: clock()
        )
        XCTAssertEqual(result.electricalRoundTripSeconds, 0.012, accuracy: 1.0e-5)
        XCTAssertGreaterThan(result.conservativeUpperBoundSeconds, 0.012)
        XCTAssertEqual(result.repetitions, 3)
        XCTAssertFalse(result.acousticFlightTimeMeasured)
        XCTAssertFalse(result.liveANCQualified)
        XCTAssertFalse(result.antiNoiseLatencyVerified)
    }

    func testUnstableRepeatAndDifferentRouteAreRejected() {
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(), capture(offset: 570), capture()], clock: clock()
        ))
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(), capture(route: "different-DAC"), capture()], clock: clock()
        ))
    }

    func testMissingClockQualityAndClippingFailClosed() {
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(), capture()], clock: clock()
        ))
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(clockUncertainty: 0.01), capture(), capture()],
            clock: clock()
        ))
        var bad = capture()
        bad.recorded[100] = 1
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [bad, capture(), capture()], clock: clock()
        ))
        var wrongClock = clock()
        wrongClock.inputObservations = []
        XCTAssertThrowsError(try QuietZoneBenchLoopbackAnalyzer().analyze(
            [capture(), capture(), capture()], clock: wrongClock
        ))
    }
}
