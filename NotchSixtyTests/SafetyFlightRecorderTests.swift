import XCTest
@testable import NotchSixty

final class SafetyFlightRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testKeepsOnlyLastSixtySeconds() {
        var r = SafetyFlightRecorder()
        r.record(.environment, "old", at: t0)
        r.record(.environment, "new", at: t0.addingTimeInterval(61))
        XCTAssertEqual(r.recent(now: t0.addingTimeInterval(61)).map(\.message), ["new"])
    }

    func testCapacityIsBounded() {
        var r = SafetyFlightRecorder()
        for i in 0..<1_000 { r.record(.environment, "e\(i)", at: t0.addingTimeInterval(Double(i) * 0.01)) }
        XCTAssertLessThanOrEqual(r.events.count, SafetyFlightRecorder.maximumEvents)
    }

    func testRepeatedIdenticalEventsCollapse() {
        var r = SafetyFlightRecorder()
        r.record(.verifier, "same", at: t0)
        r.record(.verifier, "same", at: t0.addingTimeInterval(1))
        XCTAssertEqual(r.events.count, 1)
    }

    func testEveryDisarmReasonHasPlainExplanationAndKind() {
        for reason in [LiveTreatmentDisarmReason.user, .outputDeviceChanged, .outputDeviceLost, .sleep,
                       .sampleRateChanged, .inputLost, .microphoneInvalid, .engineStopped, .quit,
                       .transportReconfigured, .instabilityTrip, .microphoneStalled,
                       .inputDeviceChanged, .outputGainChanged, .seatRegression] {
            var r = SafetyFlightRecorder()
            r.recordArm(at: t0)
            r.recordDisarm(reason, at: t0.addingTimeInterval(1))
            XCTAssertFalse(r.lastDisarmExplanation?.isEmpty ?? true, "\(reason)")
            XCTAssertEqual(r.events.last?.kind, .disarm)
        }
        var guardRec = SafetyFlightRecorder()
        guardRec.recordDisarm(.instabilityTrip, at: t0)
        XCTAssertTrue(guardRec.events.contains { $0.kind == .guardTrip })
        var seat = SafetyFlightRecorder()
        seat.recordDisarm(.seatRegression, at: t0)
        XCTAssertTrue(seat.events.contains { $0.kind == .verifier })
    }

    func testNextArmClearsExplanationAndExportListsEvents() {
        var r = SafetyFlightRecorder()
        r.recordArm(at: t0)
        r.recordDisarm(.sleep, at: t0.addingTimeInterval(2))
        let lines = r.diagnosticsLines(now: t0.addingTimeInterval(3))
        XCTAssertTrue(lines.contains { $0.contains("Last disarm: The Mac went to sleep.") })
        XCTAssertTrue(lines.contains { $0.contains("arm") && $0.contains("Armed.") })
        r.recordArm(at: t0.addingTimeInterval(4))
        XCTAssertNil(r.lastDisarmExplanation)
    }

    func testEmptyExport() {
        XCTAssertEqual(SafetyFlightRecorder().diagnosticsLines(now: t0), ["Safety Events (last 60 s):", "  none"])
    }
}
