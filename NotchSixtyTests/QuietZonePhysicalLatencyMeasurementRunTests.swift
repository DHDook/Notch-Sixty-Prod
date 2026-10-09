import Foundation
import XCTest
@testable import NotchSixty

final class QuietZonePhysicalLatencyMeasurementRunTests: XCTestCase {
    private let baseline = Date(timeIntervalSince1970: 1_800_000_000)

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(
            projectID: UUID(), microphoneID: "referenceMic",
            microphoneChannel: 0, outputDeviceID: "speakerDAC",
            routeID: "session-Lease", sampleRate: 48_000,
            clockID: "physically-cross-calibrated",
            triggerID: "external-probe-fixture"
        )
    }

    private func sample(
        _ rig: QuietZoneHardwareCalibrationRig,
        method: QuietZoneLatencyWitnessMethod, index: Int,
        stageIndex: Int,
        origin: QuietZonePhysicalLatencyOrigin = .instrumentedHardware,
        correctedLatency: Double = 0.002
    ) -> QuietZonePhysicalLatencyRepetition {
        let startHost = 100 + Double(stageIndex) * 10 + Double(index)
        return .init(
            rig: rig, method: method,
            eventID: "stage-\(stageIndex)-event-\(index)",
            measuredAt: baseline.addingTimeInterval(Double(stageIndex) + Double(index) * 0.1 + 1),
            startHostSeconds: startHost,
            endHostSeconds: startHost + correctedLatency + 0.0006,
            calibratedEndpointCorrectionSeconds: 0.0006,
            startClockUncertaintySeconds: 0.00002,
            endClockUncertaintySeconds: 0.00002,
            correctionUncertaintySeconds: 0.00001,
            worstSchedulingJitterSeconds: 0.00008,
            clockCalibrationVerified: true,
            endpointCorrectionVerified: true,
            origin: origin
        )
    }

    private func fullRun(
        origin: QuietZonePhysicalLatencyOrigin = .instrumentedHardware
    ) throws -> QuietZonePhysicalLatencyMeasurementRun {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(
            rig: device, now: baseline
        )
        for (stageIndex, method) in [
            QuietZoneLatencyWitnessMethod.acousticReferenceToADCReady,
            .adcReadyToAntiNoiseCommand,
            .commandToAnalogDACOutput,
            .analogSpeakerOutputToListenerMic
        ].enumerated() {
            for i in 0..<3 {
                try run.add(sample(device, method: method, index: i,
                                   stageIndex: stageIndex, origin: origin),
                            now: baseline.addingTimeInterval(10))
            }
        }
        return run
    }

    func testAssemblesFourIndependentPhysicalStagesForBudget() throws {
        // A synthetic test rig is used here; these numbers are not evidence
        // that any user hardware has undergone physical commissioning.
        let run = try fullRun()
        let evidence = try run.measurements(
            now: baseline.addingTimeInterval(15)
        )
        XCTAssertTrue(run.isComplete)
        XCTAssertEqual(run.completedStages, 4)
        XCTAssertEqual(evidence.map(\.stage),
                       QuietZonePhysicalLatencyStage.allCases)
        XCTAssertEqual(evidence.count, 4)
        for row in evidence {
            XCTAssertEqual(row.measuredLatencySeconds, 0.002, accuracy: 0.0000001)
            XCTAssertEqual(row.measuredUpperBoundSeconds, 0.002, accuracy: 0.0000001)
            XCTAssertEqual(row.oneSigmaUncertaintySeconds, 0.00005,
                           accuracy: 0.0000001)
            XCTAssertEqual(row.worstCaseJitterSeconds, 0.00008,
                           accuracy: 0.0000001)
            XCTAssertEqual(row.independentLaunchIDs.count, 3)
        }
        XCTAssertFalse(run.liveANCQualified)
    }

    func testRejectsSyntheticAndUncalibratedWitness() throws {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(rig: device,
                                                              now: baseline)
        var entry = sample(device, method: .acousticReferenceToADCReady,
                           index: 0, stageIndex: 0, origin: .syntheticFixture)
        XCTAssertThrowsError(try run.add(entry, now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .unsuitableWitness)
        }
        entry = sample(device, method: .acousticReferenceToADCReady,
                       index: 0, stageIndex: 0)
        entry = .init(
            rig: entry.rig, method: entry.method, eventID: entry.eventID,
            measuredAt: entry.measuredAt,
            startHostSeconds: entry.startHostSeconds,
            endHostSeconds: entry.endHostSeconds,
            calibratedEndpointCorrectionSeconds:
                entry.calibratedEndpointCorrectionSeconds,
            startClockUncertaintySeconds: entry.startClockUncertaintySeconds,
            endClockUncertaintySeconds: entry.endClockUncertaintySeconds,
            correctionUncertaintySeconds: entry.correctionUncertaintySeconds,
            worstSchedulingJitterSeconds: entry.worstSchedulingJitterSeconds,
            clockCalibrationVerified: false,
            endpointCorrectionVerified: true,
            origin: .instrumentedHardware
        )
        XCTAssertThrowsError(try run.add(entry, now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .missingClockCalibration)
        }
    }

    func testReplayedEventAndRouteChangeFailWithoutCorruptingRun() throws {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(rig: device,
                                                              now: baseline)
        let first = sample(device, method: .acousticReferenceToADCReady,
                           index: 0, stageIndex: 0)
        try run.add(first, now: baseline.addingTimeInterval(5))
        XCTAssertThrowsError(try run.add(first, now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .replayedEvent)
        }
        let newLease = QuietZoneHardwareCalibrationRig(
            projectID: device.projectID, microphoneID: device.microphoneID,
            microphoneChannel: device.microphoneChannel,
            outputDeviceID: device.outputDeviceID,
            routeID: "new-output-session", sampleRate: device.sampleRate,
            clockID: device.clockID, triggerID: device.triggerID
        )
        XCTAssertThrowsError(try run.add(
            sample(newLease, method: .acousticReferenceToADCReady,
                   index: 1, stageIndex: 0),
            now: baseline.addingTimeInterval(5)
        )) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .incompatibleRoute)
        }
        XCTAssertEqual(run.count(.referenceADC), 1)
    }

    func testOverlappingFrameWindowsAreRejected() throws {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(rig: device,
                                                              now: baseline)
        let first = sample(device, method: .adcReadyToAntiNoiseCommand,
                           index: 0, stageIndex: 1)
        try run.add(first, now: baseline.addingTimeInterval(5))
        // New ID and later capture time, but the host timeline overlaps.
        let overlapping = QuietZonePhysicalLatencyRepetition(
            rig: device, method: .adcReadyToAntiNoiseCommand,
            eventID: "overlap", measuredAt: baseline.addingTimeInterval(2),
            startHostSeconds: first.endHostSeconds,
            endHostSeconds: first.endHostSeconds + 0.003,
            calibratedEndpointCorrectionSeconds: 0.0006,
            startClockUncertaintySeconds: 0.00002,
            endClockUncertaintySeconds: 0.00002,
            correctionUncertaintySeconds: 0.00001,
            worstSchedulingJitterSeconds: 0.00008,
            clockCalibrationVerified: true,
            endpointCorrectionVerified: true,
            origin: .instrumentedHardware
        )
        XCTAssertThrowsError(try run.add(overlapping,
                                         now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .outOfOrderCapture)
        }
        XCTAssertEqual(run.count(.referenceProcessing), 1)
    }

    func testNegativeCorrectedDelayAndMissingStagesFailClosed() throws {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(rig: device,
                                                              now: baseline)
        let first = sample(device, method: .commandToAnalogDACOutput,
                           index: 0, stageIndex: 2, correctedLatency: -0.0001)
        XCTAssertThrowsError(try run.add(first, now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .implausibleDuration)
        }
        XCTAssertThrowsError(try run.measurements(now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .missingRepetitions)
        }
    }

    func testPublishingExpiredMeasurementsFailsClosed() throws {
        let run = try fullRun()
        XCTAssertThrowsError(try run.measurements(
            now: baseline.addingTimeInterval(400)
        )) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .staleCapture)
        }
    }

    func testEventTimingUncertaintyAndJitterHaveStrictBounds() throws {
        let device = rig()
        var run = try QuietZonePhysicalLatencyMeasurementRun(rig: device,
                                                              now: baseline)
        let entry = sample(device, method: .analogSpeakerOutputToListenerMic,
                           index: 0, stageIndex: 3)
        let excessive = QuietZonePhysicalLatencyRepetition(
            rig: entry.rig, method: entry.method,
            eventID: entry.eventID, measuredAt: entry.measuredAt,
            startHostSeconds: entry.startHostSeconds,
            endHostSeconds: entry.endHostSeconds,
            calibratedEndpointCorrectionSeconds:
                entry.calibratedEndpointCorrectionSeconds,
            startClockUncertaintySeconds: 0.005,
            endClockUncertaintySeconds: entry.endClockUncertaintySeconds,
            correctionUncertaintySeconds: entry.correctionUncertaintySeconds,
            worstSchedulingJitterSeconds: entry.worstSchedulingJitterSeconds,
            clockCalibrationVerified: true,
            endpointCorrectionVerified: true, origin: .instrumentedHardware
        )
        XCTAssertThrowsError(try run.add(excessive,
                                         now: baseline.addingTimeInterval(5))) {
            XCTAssertEqual($0 as? QuietZoneLatencyMeasurementError, .invalidTimestamp)
        }
    }
}
