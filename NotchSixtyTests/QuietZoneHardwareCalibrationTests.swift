import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneHardwareCalibrationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func rig(_ id: UUID = UUID()) -> QuietZoneHardwareCalibrationRig {
        QuietZoneHardwareCalibrationRig(
            projectID: id, microphoneID: "mic", microphoneChannel: 0,
            outputDeviceID: "dac", routeID: "wired-route", sampleRate: 48_000,
            clockID: "clock-1", triggerID: "source-1"
        )
    }

    private func clock(_ rate: Double = 48_000) -> QuietZoneHALClockTrace {
        func stamps(_ r: Double) -> [QuietZoneHALClockObservation] {
            (0..<12).map {
                QuietZoneHALClockObservation(
                    hostTimeSeconds: 100 + Double($0) * 0.25,
                    sampleFrame: 20_000 + Double($0) * 0.25 * r
                )
            }
        }
        return QuietZoneHALClockTrace(
            inputDeviceID: "mic", outputDeviceID: "dac",
            nominalSampleRate: 48_000, inputObservations: stamps(48_000),
            outputObservations: stamps(rate)
        )
    }

    private func probe() -> [Float] {
        var s: UInt32 = 0x414ABEEF
        return (0..<128).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return s & 0x80000000 == 0 ? 0.4 : -0.4
        }
    }

    private func loops(_ route: String = "wired-route")
        -> [QuietZoneBenchLoopbackCapture] {
        [100.2, 101.1, 102.0].map { time in
            let p = probe()
            var x = [Float](repeating: 0.0001, count: 2048)
            for i in p.indices { x[480 + i] += p[i] * 0.5 }
            return QuietZoneBenchLoopbackCapture(
                routeFingerprint: route,
                inputDeviceID: "mic", outputDeviceID: "dac",
                nominalSampleRate: 48_000, stimulus: p, recorded: x,
                stimulusStartHostSeconds: time,
                firstRecordedFrameHostSeconds: time + 0.002,
                clockUncertaintySeconds: 0.00001, captureClipped: false
            )
        }
    }

    private func acoustic(
        _ position: QuietZoneFeedForwardPosition, offset: Int
    ) -> QuietZoneFeedForwardProbeCapture {
        let p = probe()
        var x = [Float](repeating: 0.0001, count: 2048)
        for i in p.indices { x[offset + i] += p[i] * 0.5 }
        return QuietZoneFeedForwardProbeCapture(
            position: position, emittedProbe: p, recordedSamples: x,
            sampleRate: 48_000, firstInputFrameAfterTriggerSeconds: 0.004,
            triggerClockUncertaintySeconds: 0.00005,
            sourceTriggerID: "source-1", synchronizedClockID: "clock-1",
            microphoneDeviceID: "mic", microphoneChannel: 0,
            routeFingerprint: "wired-route"
        )
    }

    func testProgressionAndFailClosedReceipt() throws {
        let r = rig()
        var session = try QuietZoneHardwareCalibrationSession(
            rig: r, now: start
        )
        XCTAssertEqual(session.nextStep, .clock)
        try session.qualifyClock(clock(), now: start.addingTimeInterval(1))
        XCTAssertEqual(session.nextStep, .electrical)
        let electrical = try session.qualifyLoopback(
            loops(), now: start.addingTimeInterval(2)
        )
        XCTAssertEqual(electrical.electricalRoundTripSeconds, 0.012, accuracy: 0.00001)
        XCTAssertEqual(session.nextStep, .listener)
        try session.addAcousticCapture(
            acoustic(.listenerFirst, offset: 1200),
            projectID: r.projectID, now: start.addingTimeInterval(3)
        )
        XCTAssertEqual(session.nextStep, .upstream)
        try session.addAcousticCapture(
            acoustic(.upstream, offset: 700),
            projectID: r.projectID, now: start.addingTimeInterval(4)
        )
        XCTAssertEqual(session.nextStep, .listenerReturn)
        try session.addAcousticCapture(
            acoustic(.listenerReturn, offset: 1200),
            projectID: r.projectID, now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(session.nextStep, .physicalReview)
        XCTAssertEqual(session.arrivals.count, 3)
        XCTAssertThrowsError(try session.addAcousticCapture(
            acoustic(.upstream, offset: 700),
            projectID: r.projectID, now: start.addingTimeInterval(6)
        ))
    }

    func testClockMismatchAndOutOfOrderCaptureAreRejected() throws {
        var session = try QuietZoneHardwareCalibrationSession(
            rig: rig(), now: start
        )
        XCTAssertThrowsError(try session.qualifyLoopback(
            loops(), now: start.addingTimeInterval(1)
        ))
        XCTAssertThrowsError(try session.qualifyClock(
            clock(48_030), now: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(session.nextStep, .clock)
        try session.qualifyClock(clock(), now: start.addingTimeInterval(1))
        XCTAssertThrowsError(try session.qualifyLoopback(
            loops("wrong-route"), now: start.addingTimeInterval(2)
        ))
        XCTAssertEqual(session.nextStep, .electrical)
    }

    func testReplayedCapturesAndExpiredSessionAreRejected() throws {
        var session = try QuietZoneHardwareCalibrationSession(
            rig: rig(), now: start
        )
        try session.qualifyClock(clock(), now: start.addingTimeInterval(1))
        let one = loops()[0]
        XCTAssertThrowsError(try session.qualifyLoopback(
            [one, one, one], now: start.addingTimeInterval(2)
        ))
        XCTAssertThrowsError(try session.qualifyLoopback(
            loops(), now: start.addingTimeInterval(400)
        ))
        XCTAssertEqual(session.nextStep, .electrical)
    }

    func testListenerDriftInvalidatesEntireAcousticSurvey() throws {
        let r = rig()
        var session = try QuietZoneHardwareCalibrationSession(
            rig: r, now: start
        )
        try session.qualifyClock(clock(), now: start.addingTimeInterval(1))
        _ = try session.qualifyLoopback(
            loops(), now: start.addingTimeInterval(2)
        )
        try session.addAcousticCapture(
            acoustic(.listenerFirst, offset: 1000),
            projectID: r.projectID, now: start.addingTimeInterval(3)
        )
        try session.addAcousticCapture(
            acoustic(.upstream, offset: 600),
            projectID: r.projectID, now: start.addingTimeInterval(4)
        )
        XCTAssertThrowsError(try session.addAcousticCapture(
            acoustic(.listenerReturn, offset: 1120),
            projectID: r.projectID, now: start.addingTimeInterval(5)
        ))
        XCTAssertEqual(session.nextStep, .listener)
        XCTAssertTrue(session.arrivals.isEmpty)
    }
}
