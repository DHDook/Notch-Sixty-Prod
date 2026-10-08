import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardTests: XCTestCase {
    private let analyzer = QuietZoneFeedForwardBudgetAnalyzer()

    private func fixture() -> (RoomCorrectionProject, QuietZoneFeedForwardCalibration) {
        let microphone = RoomCorrectionMicrophone(
            stableID: "usb-mic", displayName: "Measurement mic",
            manufacturer: nil, inputChannelIndex: 0,
            calibration: nil
        )
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false, estimatedSNRDB: 40, sweepComplete: true
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [], impulseResponse: [1, 0],
            transferFunction: nil, quality: quality
        )
        let seat = RoomCorrectionMeasurementPosition(
            name: "Couch", sampleRate: 48_000,
            left: channel, right: channel
        )
        var project = RoomCorrectionProject(
            playbackSystemID: UUID(), name: "Hallway test"
        )
        project.microphone = microphone
        project.measurements = [seat]
        let session = QuietZoneFeedForwardCalibration(
            projectID: project.id,
            playbackSystemID: project.playbackSystemID,
            listenerPositionID: seat.id,
            upstreamLabel: "Hallway entrance",
            microphoneStableID: "usb-mic",
            arrivals: [
                arrival(.listenerFirst, at: 0.0350),
                arrival(.upstream, at: 0.0200),
                arrival(.listenerReturn, at: 0.0352),
            ],
            timingPath: path()
        )
        return (project, session)
    }

    private func arrival(
        _ position: QuietZoneFeedForwardPosition,
        at seconds: Double
    ) -> QuietZoneFeedForwardArrival {
        QuietZoneFeedForwardArrival(
            position: position,
            sourceTriggerID: "repeatable-trigger",
            synchronizedClockID: "clock-calibrated-1",
            microphoneDeviceID: "usb-mic",
            microphoneChannel: 0,
            routeFingerprint: "output-DAC",
            sampleRate: 48_000,
            arrivalAfterTriggerSeconds: seconds,
            oneSigmaTimingUncertaintySeconds: 0.00010,
            snrDB: 40
        )
    }

    private func path() -> QuietZoneFeedForwardTimingPath {
        QuietZoneFeedForwardTimingPath(
            synchronizedClockID: "clock-calibrated-1",
            microphoneDeviceID: "usb-mic",
            microphoneChannel: 0,
            routeFingerprint: "output-DAC",
            sampleRate: 48_000,
            referenceAcquisitionSeconds: 0.001,
            referenceProcessingSeconds: 0.002,
            commandToSeatSeconds: 0.005,
            totalWorstCaseJitterSeconds: 0.0005,
            timingUncertaintySeconds: 0.00010,
            lowLatencyTransportVerified: false
        )
    }

    func testPositiveMeasuredMarginIsPlausibleButNeverArmsLiveANC() throws {
        let (project, session) = fixture()
        let result = try analyzer.analyze(session, project: project)
        XCTAssertEqual(result.readiness, .physicallyPlausible)
        XCTAssertEqual(result.acousticPreviewSeconds ?? 0, 0.0151, accuracy: 0.000001)
        XCTAssertGreaterThan(result.conservativeReserveSeconds ?? 0, 0.004)
        XCTAssertFalse(result.runtimeAvailable)
        XCTAssertFalse(result.geometryOnly)
    }

    func testNegativeMarginFailsCausality() throws {
        let (project, session) = fixture()
        var slow = session
        slow.timingPath?.referenceProcessingSeconds = 0.020
        let result = try analyzer.analyze(slow, project: project)
        XCTAssertEqual(result.readiness, .nonCausal)
        XCTAssertLessThan(result.conservativeReserveSeconds ?? 0, 0)
        XCTAssertFalse(result.runtimeAvailable)
    }

    func testShortMarginReportsLimitedRatherThanGreen() throws {
        let (project, session) = fixture()
        var limited = session
        limited.timingPath?.referenceProcessingSeconds = 0.0065
        let result = try analyzer.analyze(limited, project: project)
        XCTAssertEqual(result.readiness, .limitedMargin)
        XCTAssertGreaterThan(result.conservativeReserveSeconds ?? 0, 0)
        XCTAssertLessThan(result.conservativeReserveSeconds ?? 1, 0.002)
    }

    func testNoOutputPathShowsPreviewWithoutClaimingANC() throws {
        let (project, session) = fixture()
        var noPath = session
        noPath.timingPath = nil
        let result = try analyzer.analyze(noPath, project: project)
        XCTAssertEqual(result.readiness, .missingMeasurements)
        XCTAssertNotNil(result.acousticPreviewSeconds)
        XCTAssertNil(result.antiNoisePathSeconds)
    }

    func testRejectsTriggerClockMismatchAndListenerDrift() throws {
        let (project, session) = fixture()
        var wrong = session
        wrong.arrivals[1].synchronizedClockID = "untrusted-phone-clock"
        XCTAssertThrowsError(try analyzer.analyze(wrong, project: project)) { error in
            XCTAssertEqual(error as? QuietZoneFeedForwardError, .incompatibleClock)
        }
        wrong = session
        wrong.arrivals[2].arrivalAfterTriggerSeconds = 0.040
        XCTAssertThrowsError(try analyzer.analyze(wrong, project: project)) { error in
            XCTAssertEqual(error as? QuietZoneFeedForwardError, .sourceDrift)
        }
    }

    func testRejectsClippedCaptureAndUnboundedTimingUncertainty() throws {
        let (project, session) = fixture()
        var bad = session
        bad.arrivals[0].clipped = true
        XCTAssertThrowsError(try analyzer.analyze(bad, project: project))
        bad = session
        bad.arrivals[0].oneSigmaTimingUncertaintySeconds = 0.002
        XCTAssertThrowsError(try analyzer.analyze(bad, project: project))
    }

    func testStaleOrDifferentProjectFailsClosed() throws {
        let (project, session) = fixture()
        var old = session
        old.capturedAt = Date().addingTimeInterval(-90_000)
        XCTAssertThrowsError(try analyzer.analyze(old, project: project))
        var mismatch = session
        mismatch.playbackSystemID = UUID()
        XCTAssertThrowsError(try analyzer.analyze(mismatch, project: project))
    }

    func testSidecarDoesNotChangePlaybackOrRoomProjectState() throws {
        let (project, session) = fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR96-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectStore = RoomCorrectionProjectStore(rootDirectory: directory)
        try projectStore.save(project)
        let store = QuietZoneFeedForwardStore(roomStore: projectStore)
        try store.save(session, project: project)
        let recovered = try XCTUnwrap(store.load(for: project))
        XCTAssertEqual(recovered, session)
        XCTAssertEqual(try projectStore.load(project.id), project)
        XCTAssertTrue(store.url(for: project.id).lastPathComponent
            .hasPrefix("quiet-zone-feed-forward-"))
    }
}
