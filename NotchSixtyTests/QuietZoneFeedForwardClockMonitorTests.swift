import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardClockMonitorTests: XCTestCase {
    private let rate = 48_000.0

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "mic", microphoneChannel: 0,
              outputDeviceID: "dac", routeID: "lease", sampleRate: rate,
              clockID: "clock", triggerID: "source")
    }

    private func route(_ name: String = "lease")
        -> QuietZoneHardwareClockRouteLease {
        .init(outputID: "dac", routeID: name, sampleRate: rate)
    }

    private func trace() -> QuietZoneHALClockTrace {
        let points: [QuietZoneHALClockObservation] = (0..<12).map { i in
            .init(hostTimeSeconds: 100 + Double(i) * 0.25,
                  sampleFrame: 20_000 + Double(i) * 12_000)
        }
        return .init(inputDeviceID: "mic", outputDeviceID: "dac",
                     nominalSampleRate: rate,
                     inputObservations: points, outputObservations: points)
    }

    private func monitor() throws -> QuietZoneFeedForwardClockMonitor {
        try .init(rig: rig(), route: route(),
                  initialTrace: trace(), now: 102.8)
    }

    func testQualifiedBaselineAndFreshMatchedFramesAreOnlyDiagnostic() throws {
        let watch = try monitor()
        let next = QuietZoneHALClockObservation(
            hostTimeSeconds: 103, sampleFrame: 164_000)
        let s = try watch.observe(
            input: next, output: next, route: route(), now: 103.02)
        XCTAssertEqual(s.observationCount, 13)
        XCTAssertEqual(s.relativeDriftPPM, 0, accuracy: 0.001)
        XCTAssertFalse(s.physicalLatencyVerified)
        XCTAssertFalse(s.liveANCQualified)
        try watch.requireFresh(route: route(), now: 103.05)
        try watch.requireFrameMapping(
            referenceFrame: 164_000, acousticHostSeconds: 103,
            outputFrame: 164_000, outputHostSeconds: 103)
    }

    func testClockRewindAndCounterJumpPermanentlyStop() throws {
        let rewind = try monitor()
        XCTAssertThrowsError(try rewind.observe(
            input: .init(hostTimeSeconds: 103, sampleFrame: 152_000),
            output: .init(hostTimeSeconds: 103, sampleFrame: 164_000),
            route: route(), now: 103.01)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .stalledClock)
        }
        XCTAssertThrowsError(try rewind.requireFresh(route: route(), now: 103)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .stopped)
        }
        let jump = try monitor()
        XCTAssertThrowsError(try jump.observe(
            input: .init(hostTimeSeconds: 103, sampleFrame: 164_240),
            output: .init(hostTimeSeconds: 103, sampleFrame: 164_000),
            route: route(), now: 103.01)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .clockJump)
        }
    }

    func testExpiredClockAndChangedRouteFailClosed() throws {
        let expired = try monitor()
        XCTAssertThrowsError(try expired.requireFresh(
            route: route(), now: 103)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .staleWitness)
        }
        let moved = try monitor()
        XCTAssertThrowsError(try moved.observe(
            input: .init(hostTimeSeconds: 103, sampleFrame: 164_000),
            output: .init(hostTimeSeconds: 103, sampleFrame: 164_000),
            route: route("restarted"), now: 103)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .mismatchedRoute)
        }
    }

    func testGradualClockDriftFailsMovingQualification() throws {
        let watch = try monitor()
        var fault: QuietZoneFeedForwardClockFault?
        for i in 0..<30 {
            let t = 103 + Double(i) * 0.25
            let input = QuietZoneHALClockObservation(
                hostTimeSeconds: t, sampleFrame: 164_000 + Double(i) * 12_000)
            let output = QuietZoneHALClockObservation(
                hostTimeSeconds: t, sampleFrame: 164_000 + Double(i) * 12_002)
            do {
                _ = try watch.observe(
                    input: input, output: output, route: route(), now: t + 0.01)
            } catch {
                fault = error as? QuietZoneFeedForwardClockFault
                break
            }
        }
        XCTAssertEqual(fault, .excessiveDrift)
        XCTAssertFalse(watch.status().liveANCQualified)
    }

    func testClockTraceCannotLegitimizeUnrelatedReferenceOrOutputFrames() throws {
        let watch = try monitor()
        XCTAssertThrowsError(try watch.requireFrameMapping(
            referenceFrame: 2_000, acousticHostSeconds: 102.8,
            outputFrame: 152_000, outputHostSeconds: 102.75)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .clockJump)
        }
        let other = try monitor()
        XCTAssertThrowsError(try other.requireFrameMapping(
            referenceFrame: 154_400, acousticHostSeconds: 102.8,
            outputFrame: 140_000, outputHostSeconds: 102.75)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardClockFault, .clockJump)
        }
    }
}
