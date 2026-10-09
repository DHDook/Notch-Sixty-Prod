import Foundation
import XCTest
@testable import NotchSixty

final class QuietZonePhysicalLatencyBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_090)

    private func fixture() -> (
        QuietZoneHardwareCalibrationRig,
        RoomCorrectionProject,
        QuietZoneFeedForwardCalibration
    ) {
        let mic = RoomCorrectionMicrophone(
            stableID: "mic", displayName: "Mic",
            manufacturer: nil, inputChannelIndex: 0, calibration: nil
        )
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false, estimatedSNRDB: 45, sweepComplete: true
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: now, rawCapture: [], impulseResponse: [1, 0],
            transferFunction: nil, quality: quality
        )
        let seat = RoomCorrectionMeasurementPosition(
            name: "Listener", sampleRate: 48_000,
            left: channel, right: channel
        )
        var project = RoomCorrectionProject(
            playbackSystemID: UUID(), name: "Bench timing"
        )
        project.microphone = mic
        project.measurements = [seat]
        let rig = QuietZoneHardwareCalibrationRig(
            projectID: project.id, microphoneID: "mic", microphoneChannel: 0,
            outputDeviceID: "dac", routeID: "new-running-route",
            sampleRate: 48_000, clockID: "synced", triggerID: "fixture"
        )
        func arrival(
            _ position: QuietZoneFeedForwardPosition, _ seconds: Double
        ) -> QuietZoneFeedForwardArrival {
            QuietZoneFeedForwardArrival(
                position: position, sourceTriggerID: rig.triggerID,
                synchronizedClockID: rig.clockID, microphoneDeviceID: "mic",
                microphoneChannel: 0, routeFingerprint: rig.routeID,
                sampleRate: 48_000, arrivalAfterTriggerSeconds: seconds,
                oneSigmaTimingUncertaintySeconds: 0.00005, snrDB: 45
            )
        }
        let plan = QuietZoneFeedForwardCalibration(
            projectID: project.id,
            playbackSystemID: project.playbackSystemID,
            listenerPositionID: seat.id, upstreamLabel: "Doorway",
            microphoneStableID: "mic", capturedAt: now,
            arrivals: [
                arrival(.listenerFirst, 0.035),
                arrival(.upstream, 0.020),
                arrival(.listenerReturn, 0.0352)
            ]
        )
        return (rig, project, plan)
    }

    private func clock() -> QuietZoneHALClockTrace {
        func observations() -> [QuietZoneHALClockObservation] {
            (0..<12).map { i in
                QuietZoneHALClockObservation(
                    hostTimeSeconds: 200 + Double(i) * 0.25,
                    sampleFrame: 5_000 + Double(i) * 12_000
                )
            }
        }
        return QuietZoneHALClockTrace(
            inputDeviceID: "mic", outputDeviceID: "dac",
            nominalSampleRate: 48_000,
            inputObservations: observations(),
            outputObservations: observations()
        )
    }

    private func stages(
        origin: QuietZonePhysicalLatencyOrigin = .instrumentedHardware
    ) -> [QuietZonePhysicalLatencyEvidence] {
        let data: [(QuietZonePhysicalLatencyStage, Double)] = [
            (.referenceADC, 0.001),
            (.referenceProcessing, 0.002),
            (.outputDAC, 0.001),
            (.speakerToSeat, 0.004)
        ]
        return data.enumerated().map { index, pair in
            QuietZonePhysicalLatencyEvidence(
                stage: pair.0, origin: origin,
                microphoneDeviceID: "mic", microphoneChannel: 0,
                outputDeviceID: "dac", routeLeaseID: "new-running-route",
                synchronizedClockID: "synced", sampleRate: 48_000,
                capturedAt: startedAt.addingTimeInterval(5),
                independentLaunchIDs: (0..<3).map {
                    "stage-\(index)-independent-\($0)"
                },
                measuredLatencySeconds: pair.1,
                measuredUpperBoundSeconds: pair.1 + 0.0001,
                oneSigmaUncertaintySeconds: 0.000025,
                worstCaseJitterSeconds: 0.0001
            )
        }
    }

    private func analyze(
        _ values: [QuietZonePhysicalLatencyEvidence]
    ) throws -> QuietZonePhysicalLatencyReport {
        let (rig, project, plan) = fixture()
        return try QuietZonePhysicalLatencyBudgetAnalyzer().analyze(
            rig: rig, plan: plan, project: project,
            clock: clock(), stages: values,
            sessionStartedAt: startedAt, now: now
        )
    }

    func testMeasuredSegmentsProduceConservativeReserveButNeverArm() throws {
        // Deterministic synthetic fixture, labelled instrumented solely to
        // exercise the arithmetic. It is NOT a real hardware certification.
        let report = try analyze(stages())
        XCTAssertEqual(report.nominalPathSeconds, 0.008, accuracy: 0.000001)
        XCTAssertEqual(report.upperBoundPathSeconds, 0.0091, accuracy: 0.000001)
        XCTAssertEqual(report.lowerBoundNoiseLeadSeconds, 0.0145, accuracy: 0.000001)
        XCTAssertEqual(report.conservativeReserveSeconds, 0.0054, accuracy: 0.000001)
        XCTAssertEqual(report.readiness, .physicallyPlausible)
        XCTAssertGreaterThan(report.spareAfterSafetyReserveSeconds, 0)
        XCTAssertFalse(report.frequencyResponseVerified)
        XCTAssertFalse(report.cancellationMeasured)
        XCTAssertFalse(report.liveANCQualified)
        XCTAssertFalse(report.budget.runtimeAvailable)
    }

    func testNonCausalPathIsRejectedForANCWithoutThrowingAwayDiagnostics() throws {
        var slow = stages()
        let old = slow[1]
        slow[1] = QuietZonePhysicalLatencyEvidence(
            stage: .referenceProcessing, origin: old.origin,
            microphoneDeviceID: old.microphoneDeviceID,
            microphoneChannel: old.microphoneChannel,
            outputDeviceID: old.outputDeviceID,
            routeLeaseID: old.routeLeaseID,
            synchronizedClockID: old.synchronizedClockID,
            sampleRate: old.sampleRate, capturedAt: old.capturedAt,
            independentLaunchIDs: old.independentLaunchIDs,
            measuredLatencySeconds: 0.018,
            measuredUpperBoundSeconds: 0.0181,
            oneSigmaUncertaintySeconds: old.oneSigmaUncertaintySeconds,
            worstCaseJitterSeconds: old.worstCaseJitterSeconds
        )
        let result = try analyze(slow)
        XCTAssertEqual(result.readiness, .nonCausal)
        XCTAssertLessThan(result.conservativeReserveSeconds, 0)
        XCTAssertFalse(result.liveANCQualified)
    }

    func testMissingOrDuplicateStageFailsClosed() {
        XCTAssertThrowsError(try analyze(Array(stages().dropLast())))
        var duplicated = stages()
        duplicated[3] = duplicated[2]
        XCTAssertThrowsError(try analyze(duplicated)) {
            XCTAssertEqual($0 as? QuietZonePhysicalLatencyError, .duplicateStage)
        }
    }

    func testSyntheticAndUnverifiedStageCannotBecomePhysicalEvidence() {
        XCTAssertThrowsError(try analyze(stages(origin: .syntheticFixture))) {
            XCTAssertEqual($0 as? QuietZonePhysicalLatencyError, .untrustedEvidence)
        }
        XCTAssertThrowsError(try analyze(stages(origin: .unverifiedEstimate)))
    }

    func testRouteDriftStaleCaptureAndReusedStageEventFailClosed() {
        var changed = stages()
        changed[0] = replacing(changed[0], route: "old-session")
        XCTAssertThrowsError(try analyze(changed)) {
            XCTAssertEqual($0 as? QuietZonePhysicalLatencyError, .incompatibleProvenance)
        }
        var stale = stages()
        stale[1] = replacing(stale[1], capturedAt: now.addingTimeInterval(-500))
        XCTAssertThrowsError(try analyze(stale)) {
            XCTAssertEqual($0 as? QuietZonePhysicalLatencyError, .staleEvidence)
        }
        var repeatEvent = stages()
        repeatEvent[3] = replacing(
            repeatEvent[3], ids: repeatEvent[0].independentLaunchIDs
        )
        XCTAssertThrowsError(try analyze(repeatEvent)) {
            XCTAssertEqual($0 as? QuietZonePhysicalLatencyError, .reusedMeasurement)
        }
    }

    func testInvalidNaNAndInvertedBoundsFailClosed() {
        var invalid = stages()
        invalid[0] = replacing(
            invalid[0], measured: .nan
        )
        XCTAssertThrowsError(try analyze(invalid))
        invalid = stages()
        invalid[2] = replacing(
            invalid[2], upper: 0.0002
        )
        XCTAssertThrowsError(try analyze(invalid))
    }

    private func replacing(
        _ item: QuietZonePhysicalLatencyEvidence,
        route: String? = nil, capturedAt: Date? = nil,
        ids: [String]? = nil, measured: Double? = nil,
        upper: Double? = nil
    ) -> QuietZonePhysicalLatencyEvidence {
        .init(
            stage: item.stage, origin: item.origin,
            microphoneDeviceID: item.microphoneDeviceID,
            microphoneChannel: item.microphoneChannel,
            outputDeviceID: item.outputDeviceID,
            routeLeaseID: route ?? item.routeLeaseID,
            synchronizedClockID: item.synchronizedClockID,
            sampleRate: item.sampleRate,
            capturedAt: capturedAt ?? item.capturedAt,
            independentLaunchIDs: ids ?? item.independentLaunchIDs,
            measuredLatencySeconds: measured ?? item.measuredLatencySeconds,
            measuredUpperBoundSeconds: upper ?? item.measuredUpperBoundSeconds,
            oneSigmaUncertaintySeconds: item.oneSigmaUncertaintySeconds,
            worstCaseJitterSeconds: item.worstCaseJitterSeconds
        )
    }
}
