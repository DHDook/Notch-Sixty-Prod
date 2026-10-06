import Foundation
import XCTest
@testable import NotchSixty

final class MIMORoomTreatmentVerificationTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let source0: MultichannelCalibrationSource = .subwoofer(0)
    private let source1: MultichannelCalibrationSource = .subwoofer(1)

    func testRepeatMeasurementAcceptsMaterialSpatialImprovementWithoutLevelShift() throws {
        let seatA = MultichannelCalibrationSeat(name: "A")
        let seatB = MultichannelCalibrationSeat(name: "B")
        let sources = [source0, source1]

        let baseline = [
            measurement(seat: seatA, source: source0, levelDB: 6),
            measurement(seat: seatB, source: source0, levelDB: -6),
            measurement(seat: seatA, source: source1, levelDB: 4),
            measurement(seat: seatB, source: source1, levelDB: -4),
        ]
        let treated = [
            measurement(seat: seatA, source: source0, levelDB: 1),
            measurement(seat: seatB, source: source0, levelDB: -1),
            measurement(seat: seatA, source: source1, levelDB: 0.5),
            measurement(seat: seatB, source: source1, levelDB: -0.5),
        ]

        let report = try MIMORoomTreatmentVerifier().verify(
            sources: sources,
            seats: [seatA, seatB],
            baselineMeasurements: baseline,
            treatedMeasurements: treated,
            sampleRate: sampleRate
        )

        XCTAssertTrue(report.accepted)
        XCTAssertGreaterThan(report.spatialRMSErrorImprovementDB, 3)
        XCTAssertLessThan(report.treatedSpatialRMSErrorDB, 1.1)
        XCTAssertEqual(report.maximumAbsoluteMeanLevelShiftDB, 0, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(report.worstSeatErrorIncreaseDB, 0)
        XCTAssertEqual(report.sourceReports.count, 2)
    }

    func testRepeatMeasurementRejectsFakeWinFromOverallLevelShift() throws {
        let seatA = MultichannelCalibrationSeat(name: "A")
        let seatB = MultichannelCalibrationSeat(name: "B")
        let baseline = [
            measurement(seat: seatA, source: source0, levelDB: 6),
            measurement(seat: seatB, source: source0, levelDB: -6),
        ]
        let treated = [
            measurement(seat: seatA, source: source0, levelDB: 4),
            measurement(seat: seatB, source: source0, levelDB: 2),
        ]

        let report = try MIMORoomTreatmentVerifier().verify(
            sources: [source0],
            seats: [seatA, seatB],
            baselineMeasurements: baseline,
            treatedMeasurements: treated,
            sampleRate: sampleRate
        )

        XCTAssertFalse(report.accepted)
        XCTAssertGreaterThan(report.spatialRMSErrorImprovementDB, 4)
        XCTAssertGreaterThan(report.maximumAbsoluteMeanLevelShiftDB, 1.5)
    }

    func testMissingRepeatMeasurementFailsClosed() throws {
        let seatA = MultichannelCalibrationSeat(name: "A")
        let seatB = MultichannelCalibrationSeat(name: "B")
        let baseline = [
            measurement(seat: seatA, source: source0, levelDB: 3),
            measurement(seat: seatB, source: source0, levelDB: -3),
        ]
        let treated = [
            measurement(seat: seatA, source: source0, levelDB: 0.5),
        ]

        XCTAssertThrowsError(
            try MIMORoomTreatmentVerifier().verify(
                sources: [source0],
                seats: [seatA, seatB],
                baselineMeasurements: baseline,
                treatedMeasurements: treated,
                sampleRate: sampleRate
            )
        ) { error in
            guard case MIMORoomTreatmentVerificationError.missingMeasurement(
                let phase,
                let seatID,
                let source
            ) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(phase, "treated")
            XCTAssertEqual(seatID, seatB.id)
            XCTAssertEqual(source, self.source0)
        }
    }

    func testDeploymentGateRequiresSafetyThenMeasurementThenHardwareAcceptance() throws {
        let program = dummyProgram()
        let gate = MIMORoomTreatmentDeploymentGate()

        var result = gate.evaluate(
            firProgram: program,
            sourceSafety: [],
            verification: nil,
            hardwareAcceptance: nil
        )
        XCTAssertEqual(result.status, .blockedBySourceSafety)

        let safety = [
            safetyDeclaration(source0),
            safetyDeclaration(source1),
        ]
        result = gate.evaluate(
            firProgram: program,
            sourceSafety: safety,
            verification: nil,
            hardwareAcceptance: nil
        )
        XCTAssertEqual(result.status, .repeatMeasurementRequired)

        let verification = acceptedVerification()
        result = gate.evaluate(
            firProgram: program,
            sourceSafety: safety,
            verification: verification,
            hardwareAcceptance: nil
        )
        XCTAssertEqual(result.status, .hardwareAcceptanceRequired)

        let incompleteHardware = MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceCount: 2,
            sampleRate: sampleRate,
            longRunThermalPassed: true,
            protectionChainPassed: true,
            stopStartPassed: true,
            unplugReplugPassed: true,
            sleepWakePassed: true,
            audibleArtifactCheckPassed: false
        )
        result = gate.evaluate(
            firProgram: program,
            sourceSafety: safety,
            verification: verification,
            hardwareAcceptance: incompleteHardware
        )
        XCTAssertEqual(result.status, .hardwareAcceptanceRequired)

        let completeHardware = MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceCount: 2,
            sampleRate: sampleRate,
            longRunThermalPassed: true,
            protectionChainPassed: true,
            stopStartPassed: true,
            unplugReplugPassed: true,
            sleepWakePassed: true,
            audibleArtifactCheckPassed: true
        )
        result = gate.evaluate(
            firProgram: program,
            sourceSafety: safety,
            verification: verification,
            hardwareAcceptance: completeHardware
        )
        XCTAssertEqual(result.status, .eligibleForFutureLiveIntegration)
        XCTAssertTrue(result.blockingReasons.isEmpty)
    }

    func testSourceSafetyRequiresBandHeadroomAndPhysicalModels() {
        let program = dummyProgram()
        let gate = MIMORoomTreatmentDeploymentGate()
        var bad = safetyDeclaration(source0)
        bad = MIMORoomTreatmentSourceSafetyDeclaration(
            source: bad.source,
            safeMinimumFrequencyHz: 25,
            safeMaximumFrequencyHz: 150,
            reservedHeadroomDB: 2,
            excursionModelConfirmed: false,
            thermalModelConfirmed: true,
            finalProtectionChainConfirmed: true
        )
        let result = gate.evaluate(
            firProgram: program,
            sourceSafety: [bad, safetyDeclaration(source1)],
            verification: acceptedVerification(),
            hardwareAcceptance: nil
        )
        XCTAssertEqual(result.status, .blockedBySourceSafety)
        XCTAssertFalse(result.blockingReasons.isEmpty)
    }

    func testFailedRepeatMeasurementCannotAdvanceToHardwareAcceptance() {
        let program = dummyProgram()
        let failed = MIMORoomTreatmentVerificationReport(
            sampleRate: sampleRate,
            seatIDs: [],
            sources: [source0, source1],
            frequenciesHz: [20, 150],
            sourceReports: [],
            baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 5.2,
            spatialRMSErrorImprovementDB: -0.2,
            maximumAbsoluteMeanLevelShiftDB: 0.1,
            worstSeatErrorIncreaseDB: 0.2,
            accepted: false
        )
        let completeHardware = MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(),
            sourceCount: 2,
            sampleRate: sampleRate,
            longRunThermalPassed: true,
            protectionChainPassed: true,
            stopStartPassed: true,
            unplugReplugPassed: true,
            sleepWakePassed: true,
            audibleArtifactCheckPassed: true
        )
        let result = MIMORoomTreatmentDeploymentGate().evaluate(
            firProgram: program,
            sourceSafety: [
                safetyDeclaration(source0),
                safetyDeclaration(source1),
            ],
            verification: failed,
            hardwareAcceptance: completeHardware
        )
        XCTAssertEqual(result.status, .repeatMeasurementFailed)
    }

    private func safetyDeclaration(
        _ source: MultichannelCalibrationSource
    ) -> MIMORoomTreatmentSourceSafetyDeclaration {
        MIMORoomTreatmentSourceSafetyDeclaration(
            source: source,
            safeMinimumFrequencyHz: 15,
            safeMaximumFrequencyHz: 180,
            reservedHeadroomDB: 6,
            excursionModelConfirmed: true,
            thermalModelConfirmed: true,
            finalProtectionChainConfirmed: true
        )
    }

    private func dummyProgram() -> MIMORoomTreatmentFIRProgram {
        MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: [source0, source1],
            tapCount: 4_096,
            declaredLatencyFrames: 2_048,
            engineLatencyFrames: 256,
            taps: [],
            diagnostics: MIMORoomTreatmentFIRCompileDiagnostics(
                maximumEdgeEnergyFraction: 0,
                maximumCoefficientMagnitude: 1,
                maximumColumnPower: 1,
                maximumPerSourcePower: 1,
                maximumCoefficientOvershootDB: 0,
                maximumColumnPowerOvershootDB: 0,
                maximumPerSourcePowerOvershootDB: 0
            )
        )
    }

    private func acceptedVerification() -> MIMORoomTreatmentVerificationReport {
        MIMORoomTreatmentVerificationReport(
            sampleRate: sampleRate,
            seatIDs: [],
            sources: [source0, source1],
            frequenciesHz: [20, 150],
            sourceReports: [],
            baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 1,
            spatialRMSErrorImprovementDB: 4,
            maximumAbsoluteMeanLevelShiftDB: 0.2,
            worstSeatErrorIncreaseDB: 0.3,
            accepted: true
        )
    }

    private func measurement(
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource,
        levelDB: Double
    ) -> MultichannelCalibrationMeasurement {
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 40, 63, 100, 150],
            magnitudeDB: [levelDB, levelDB, levelDB, levelDB, levelDB],
            phaseRadians: [0, 0, 0, 0, 0]
        )
        return MultichannelCalibrationMeasurement(
            seatID: seat.id,
            source: source,
            sampleRate: sampleRate,
            channel: RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                rawCapture: [0],
                impulseResponse: [1],
                transferFunction: response,
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -18,
                    capturePeakDBFS: -12,
                    estimatedNoiseFloorDBFS: -70,
                    estimatedSNRDB: 58,
                    sweepComplete: true,
                    directArrivalSeconds: 0.01,
                    usableLowHz: 20,
                    usableHighHz: 150,
                    warnings: []
                )
            )
        )
    }
}
