import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardProbeTests: XCTestCase {
    private func reference() -> [Float] {
        var state: UInt32 = 0xA6C8_971B
        return (0..<256).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (state & 0x8000_0000) != 0 ? 0.5 : -0.5
        }
    }

    private func recording(
        delay: Int = 640,
        amplitude: Float = 0.25,
        start: Double = 0,
        position: QuietZoneFeedForwardPosition = .listenerFirst
    ) -> QuietZoneFeedForwardProbeCapture {
        let probe = reference()
        var samples = [Float](repeating: 0.0001, count: 2_048)
        for i in probe.indices {
            samples[delay + i] += probe[i] * amplitude
        }
        return QuietZoneFeedForwardProbeCapture(
            position: position,
            emittedProbe: probe,
            recordedSamples: samples,
            sampleRate: 48_000,
            firstInputFrameAfterTriggerSeconds: start,
            triggerClockUncertaintySeconds: 0.00005,
            sourceTriggerID: "wired-trigger",
            synchronizedClockID: "calibrated-loopback-clock",
            microphoneDeviceID: "mic-1",
            microphoneChannel: 0,
            routeFingerprint: "output-route",
        )
    }

    func testKnownCodedProbeArrivalIsRecovered() throws {
        let record = try QuietZoneFeedForwardProbeDetector()
            .detect(recording(delay: 640, start: 0.004))
        XCTAssertEqual(
            record.arrivalAfterTriggerSeconds,
            0.004 + 640.0 / 48_000,
            accuracy: 1.0 / 48_000
        )
        XCTAssertGreaterThan(record.snrDB, 30)
        XCTAssertLessThan(record.oneSigmaTimingUncertaintySeconds, 0.001)
    }

    func testRelativeHallwayAndListenerPreviewFromOneMic() throws {
        let detector = QuietZoneFeedForwardProbeDetector()
        let first = try detector.detect(
            recording(delay: 1_300, position: .listenerFirst)
        )
        let upstream = try detector.detect(
            recording(delay: 800, position: .upstream)
        )
        let last = try detector.detect(
            recording(delay: 1_300, position: .listenerReturn)
        )
        XCTAssertEqual(
            (first.arrivalAfterTriggerSeconds + last.arrivalAfterTriggerSeconds) / 2
                - upstream.arrivalAfterTriggerSeconds,
            500.0 / 48_000,
            accuracy: 1.0 / 48_000
        )
    }

    func testUncorrelatedCaptureNeverInventsArrival() {
        var record = recording()
        record.recordedSamples = Array(repeating: 0.002, count: 2_048)
        XCTAssertThrowsError(
            try QuietZoneFeedForwardProbeDetector().detect(record)
        )
    }

    func testUnsynchronizedOrClippedProbeFails() {
        var record = recording()
        record.synchronizedClockID = ""
        XCTAssertThrowsError(
            try QuietZoneFeedForwardProbeDetector().detect(record)
        )
        record = recording()
        record.recordedSamples[100] = 1
        XCTAssertThrowsError(
            try QuietZoneFeedForwardProbeDetector().detect(record)
        )
    }
}
