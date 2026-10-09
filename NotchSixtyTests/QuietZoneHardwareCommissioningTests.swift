import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneHardwareCommissioningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)
    private var evaluator: QuietZoneHardwareCommissioningEvaluator { .init() }

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "mic", microphoneChannel: 0,
              outputDeviceID: "dac", routeID: "session-lease",
              sampleRate: 48_000, clockID: "clock", triggerID: "source")
    }

    private func clock() -> QuietZoneHALClockTrace {
        let stamps = (0..<12).map {
            QuietZoneHALClockObservation(hostTimeSeconds: 200 + Double($0) * 0.25,
                                         sampleFrame: Double($0) * 12_000)
        }
        return .init(inputDeviceID: "mic", outputDeviceID: "dac",
                     nominalSampleRate: 48_000,
                     inputObservations: stamps, outputObservations: stamps)
    }

    private func newSession() throws -> QuietZoneHardwareCalibrationSession {
        try .init(rig: rig(), now: now.addingTimeInterval(-10))
    }

    private func assess(
        _ session: QuietZoneHardwareCalibrationSession,
        route: QuietZoneHardwareHALClockAcquisition.Route? = nil,
        run: QuietZonePhysicalLatencyMeasurementRun? = nil
    ) -> QuietZoneCommissioningChecklist {
        evaluator.assess(session: session, run: run,
                         currentOutput: route, plan: nil, project: nil, now: now)
    }

    func testEmptyPreviewRequiresPhysicalAcceptanceEvenWithNoPlan() {
        let result = evaluator.preview(calibration: nil)
        XCTAssertEqual(result.items.count, QuietZoneCommissioningGate.allCases.count)
        XCTAssertEqual(result.item(.selectedOutput)?.status, .missing)
        XCTAssertEqual(result.item(.speakerToSeat)?.status, .missing)
        XCTAssertEqual(result.item(.independentHardwareReview)?.status,
                       .physicalVerificationRequired)
        XCTAssertEqual(result.item(.acousticAcceptance)?.status,
                       .physicalVerificationRequired)
        XCTAssertFalse(result.hardwareVerified)
        XCTAssertFalse(result.outputConnected)
        XCTAssertFalse(result.liveANCQualified)
    }

    func testPersistedTimingPathCannotBeTreatedAsFourVerifiedStages() {
        let r = rig()
        let saved = QuietZoneFeedForwardCalibration(
            projectID: r.projectID, playbackSystemID: UUID(),
            listenerPositionID: UUID(), upstreamLabel: "doorway",
            microphoneStableID: r.microphoneID,
            timingPath: QuietZoneFeedForwardTimingPath(
                synchronizedClockID: r.clockID, microphoneDeviceID: r.microphoneID,
                microphoneChannel: 0, routeFingerprint: r.routeID,
                sampleRate: 48_000, referenceAcquisitionSeconds: 0.001,
                referenceProcessingSeconds: 0.002, commandToSeatSeconds: 0.004,
                totalWorstCaseJitterSeconds: 0.0001,
                timingUncertaintySeconds: 0.0001,
                lowLatencyTransportVerified: true
            ), halClockTrace: clock()
        )
        let preview = evaluator.preview(calibration: saved)
        XCTAssertEqual(preview.item(.halClocks)?.status, .capturedUnverified)
        XCTAssertEqual(preview.item(.referenceADC)?.status, .missing)
        XCTAssertEqual(preview.item(.outputDAC)?.status, .missing)
        XCTAssertEqual(preview.item(.speakerToSeat)?.status, .missing)
        XCTAssertEqual(preview.item(.causalBudget)?.status, .missing)
        XCTAssertFalse(preview.liveANCQualified)
    }

    func testExactRunningRouteIsRequiredAndRestartInvalidates() throws {
        let session = try newSession()
        let valid = assess(session, route: (
            outputID: session.rig.outputDeviceID,
            routeID: session.rig.routeID,
            sampleRate: session.rig.sampleRate
        ))
        XCTAssertEqual(valid.item(.selectedOutput)?.status, .capturedUnverified)
        let changed = assess(session, route: (
            outputID: session.rig.outputDeviceID,
            routeID: "restarted-lease", sampleRate: session.rig.sampleRate
        ))
        XCTAssertEqual(changed.item(.selectedOutput)?.status, .invalid)
        let rateChanged = assess(session, route: (
            outputID: session.rig.outputDeviceID,
            routeID: session.rig.routeID, sampleRate: 96_000
        ))
        XCTAssertEqual(rateChanged.item(.selectedOutput)?.status, .invalid)
        XCTAssertFalse(changed.liveANCQualified)
    }

    func testQualifiedClockIsRecordedButNotPhysicalLatencyProof() throws {
        var session = try newSession()
        try session.qualifyClock(clock(), now: now.addingTimeInterval(-9))
        let result = assess(session)
        XCTAssertEqual(result.item(.halClocks)?.status, .capturedUnverified)
        XCTAssertEqual(result.item(.wiredLoopback)?.status, .missing)
        XCTAssertEqual(result.item(.speakerToSeat)?.status, .missing)
        XCTAssertFalse(result.hardwareVerified)
    }

    func testStaleClockAndSessionRejectEvidence() throws {
        var session = try newSession()
        try session.qualifyClock(clock(), now: now.addingTimeInterval(-9))
        let old = evaluator.assess(
            session: session, run: nil, currentOutput: (
                outputID: "dac", routeID: "session-lease", sampleRate: 48_000
            ), plan: nil, project: nil, now: now.addingTimeInterval(400)
        )
        XCTAssertEqual(old.item(.selectedOutput)?.status, .invalid)
        XCTAssertEqual(old.item(.halClocks)?.status, .invalid)
        XCTAssertFalse(old.liveANCQualified)
    }

    func testPartialStageCapturesCannotBeMisrepresentedAsComplete() throws {
        let session = try newSession()
        var run = try QuietZonePhysicalLatencyMeasurementRun(
            rig: session.rig, now: session.startedAt
        )
        let shot = QuietZonePhysicalLatencyRepetition(
            rig: session.rig, method: .acousticReferenceToADCReady,
            eventID: "adc-1", measuredAt: now.addingTimeInterval(-2),
            startHostSeconds: 100, endHostSeconds: 100.005,
            calibratedEndpointCorrectionSeconds: 0.001,
            startClockUncertaintySeconds: 0.00002,
            endClockUncertaintySeconds: 0.00002,
            correctionUncertaintySeconds: 0.00002,
            worstSchedulingJitterSeconds: 0.0001,
            clockCalibrationVerified: true,
            endpointCorrectionVerified: true, origin: .instrumentedHardware
        )
        try run.add(shot, now: now)
        let result = assess(session, run: run)
        XCTAssertEqual(result.item(.referenceADC)?.status, .missing)
        XCTAssertTrue(result.item(.referenceADC)?.explanation.contains("1 of 3") == true)
        XCTAssertEqual(result.item(.causalBudget)?.status, .missing)
        XCTAssertEqual(result.item(.independentHardwareReview)?.status,
                       .physicalVerificationRequired)
        XCTAssertFalse(result.liveANCQualified)
    }
}
