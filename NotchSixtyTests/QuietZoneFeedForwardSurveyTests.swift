import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardSurveyTests: XCTestCase {
    private func probe() -> [Float] {
        var state: UInt32 = 0x1234ABCD
        return (0..<128).map { _ in
            state = 1_664_525 &* state &+ 1_013_904_223
            return state & 0x80000000 == 0 ? 0.4 : -0.4
        }
    }

    private func capture(
        _ position: QuietZoneFeedForwardPosition,
        offset: Int
    ) -> QuietZoneFeedForwardProbeCapture {
        let sequence = probe()
        var recording = [Float](repeating: 0.0001, count: 2048)
        for i in sequence.indices {
            recording[offset + i] += sequence[i] * 0.5
        }
        return QuietZoneFeedForwardProbeCapture(
            position: position,
            emittedProbe: sequence,
            recordedSamples: recording,
            sampleRate: 48_000,
            firstInputFrameAfterTriggerSeconds: 0.004,
            triggerClockUncertaintySeconds: 0.00005,
            sourceTriggerID: "stable-source-fixture",
            synchronizedClockID: "shared-clock",
            microphoneDeviceID: "mic",
            microphoneChannel: 0,
            routeFingerprint: "routed-test"
        )
    }

    private func makeSession(
        projectID: UUID,
        now: Date
    ) throws -> QuietZoneFeedForwardSurveySession {
        try QuietZoneFeedForwardSurveySession(
            projectID: projectID,
            microphoneStableID: "mic",
            microphoneChannel: 0,
            routeFingerprint: "routed-test",
            clockID: "shared-clock",
            stimulusID: "stable-source-fixture",
            now: now
        )
    }

    func testSequentialSurveyCollectsOnlyListenerUpstreamListener() throws {
        let id = UUID()
        let now = Date()
        var session = try makeSession(projectID: id, now: now)
        XCTAssertEqual(session.nextStage, .listener)
        try session.add(
            capture(.listenerFirst, offset: 1200),
            projectID: id, capturedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(session.nextStage, .upstream)
        try session.add(
            capture(.upstream, offset: 700),
            projectID: id, capturedAt: now.addingTimeInterval(2)
        )
        try session.add(
            capture(.listenerReturn, offset: 1200),
            projectID: id, capturedAt: now.addingTimeInterval(3)
        )
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.arrivals.count, 3)
        XCTAssertEqual(
            session.arrivals[0].arrivalAfterTriggerSeconds
                - session.arrivals[1].arrivalAfterTriggerSeconds,
            500.0 / 48_000,
            accuracy: 1.0 / 48_000
        )
    }

    func testSurveyRejectsOutOfOrderAndClockMismatchWithoutAdvancing() throws {
        let id = UUID(), now = Date()
        var session = try makeSession(projectID: id, now: now)
        XCTAssertThrowsError(try session.add(
            capture(.upstream, offset: 700),
            projectID: id, capturedAt: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(session.arrivals.count, 0)

        var mismatched = capture(.listenerFirst, offset: 1000)
        mismatched.synchronizedClockID = "unrelated-clock"
        XCTAssertThrowsError(try session.add(
            mismatched,
            projectID: id, capturedAt: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(session.arrivals.count, 0)
    }

    func testListenerReturnDriftInvalidatesSurvey() throws {
        let id = UUID(), now = Date()
        var session = try makeSession(projectID: id, now: now)
        try session.add(capture(.listenerFirst, offset: 1000),
                        projectID: id, capturedAt: now.addingTimeInterval(1))
        try session.add(capture(.upstream, offset: 600),
                        projectID: id, capturedAt: now.addingTimeInterval(2))
        XCTAssertThrowsError(try session.add(
            capture(.listenerReturn, offset: 1110),
            projectID: id, capturedAt: now.addingTimeInterval(3)
        ))
        XCTAssertEqual(session.arrivals.count, 0)
        XCTAssertEqual(session.nextStage, .listener)
    }

    func testTooQuickOrStaleCapturesFailClosed() throws {
        let id = UUID(), now = Date()
        var session = try makeSession(projectID: id, now: now)
        try session.add(capture(.listenerFirst, offset: 1000),
                        projectID: id, capturedAt: now.addingTimeInterval(1))
        XCTAssertThrowsError(try session.add(
            capture(.upstream, offset: 600),
            projectID: id, capturedAt: now.addingTimeInterval(1.1)
        ))
        XCTAssertThrowsError(try session.add(
            capture(.upstream, offset: 600),
            projectID: id, capturedAt: now.addingTimeInterval(400)
        ))
        XCTAssertEqual(session.arrivals.count, 1)
    }
}
