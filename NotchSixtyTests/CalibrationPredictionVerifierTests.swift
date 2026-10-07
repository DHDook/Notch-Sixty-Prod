import Foundation
import XCTest
@testable import NotchSixty

final class CalibrationPredictionVerifierTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let seat = MultichannelCalibrationSeat(
        name: "Main Seat",
        included: true,
        weight: 1
    )

    func testIndependentPredictionAcceptsUsefulCorrection() throws {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let measurement = makeMeasurement(
            seat: seat,
            source: source,
            magnitudes: [0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0],
            snrDB: 60
        )
        let design = makeDesign(
            speakers: [
                MultichannelSpeakerDesign(
                    role: .frontLeft,
                    calibration: SemanticSpeakerCalibration(
                        trimDB: 0,
                        delayMilliseconds: 0,
                        polarityInverted: false,
                        eqBands: [
                            OutputCalibrationEQBand(
                                frequencyHz: 1_000,
                                gainDB: -6,
                                q: 1
                            ),
                        ]
                    ),
                    errorBeforeDB: 2.2,
                    errorAfterDB: 0.7,
                    seatVarianceDBSquared: 0
                ),
            ]
        )

        let report = try MultichannelCalibrationPredictionVerifier().verify(
            design: design,
            seats: [seat],
            measurements: [measurement]
        )

        XCTAssertTrue(report.accepted, report.blockingReasons.joined(separator: "\n"))
        XCTAssertGreaterThan(report.confidence, 0.8)
        XCTAssertGreaterThan(report.speakerImprovementDB, 0.25)
        XCTAssertLessThan(
            report.speakerRMSErrorAfterDB,
            report.speakerRMSErrorBeforeDB
        )
        XCTAssertTrue(report.blockingReasons.isEmpty)
        XCTAssertEqual(report.sourceReports.count, 1)
        XCTAssertEqual(report.seatReports.count, 1)
    }

    func testLowConfidenceCaptureFailsClosed() throws {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let measurement = makeMeasurement(
            seat: seat,
            source: source,
            magnitudes: [0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0],
            snrDB: 20
        )
        let design = makeDesign(
            speakers: [
                MultichannelSpeakerDesign(
                    role: .frontLeft,
                    calibration: SemanticSpeakerCalibration(
                        eqBands: [
                            OutputCalibrationEQBand(
                                frequencyHz: 1_000,
                                gainDB: -6,
                                q: 1
                            ),
                        ]
                    ),
                    errorBeforeDB: 2.2,
                    errorAfterDB: 0.7,
                    seatVarianceDBSquared: 0
                ),
            ]
        )

        let report = try MultichannelCalibrationPredictionVerifier().verify(
            design: design,
            seats: [seat],
            measurements: [measurement]
        )

        XCTAssertFalse(report.accepted)
        XCTAssertLessThan(
            report.confidence,
            MultichannelCalibrationPredictionVerifier.minimumConfidence
        )
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("confidence")
            }
        )
    }

    func testIndependentPredictionRejectsDesignerRegression() throws {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let measurement = makeMeasurement(
            seat: seat,
            source: source,
            magnitudes: Array(repeating: 0, count: 11),
            snrDB: 60
        )
        let design = makeDesign(
            speakers: [
                MultichannelSpeakerDesign(
                    role: .frontLeft,
                    calibration: SemanticSpeakerCalibration(
                        eqBands: [
                            OutputCalibrationEQBand(
                                frequencyHz: 1_000,
                                gainDB: -10,
                                q: 0.8
                            ),
                        ]
                    ),
                    errorBeforeDB: 0.1,
                    errorAfterDB: 0.1,
                    seatVarianceDBSquared: 0
                ),
            ]
        )

        let report = try MultichannelCalibrationPredictionVerifier().verify(
            design: design,
            seats: [seat],
            measurements: [measurement]
        )

        XCTAssertFalse(report.accepted)
        XCTAssertLessThan(report.speakerImprovementDB, -0.25)
        XCTAssertGreaterThan(report.worstSourceRegressionDB, 0.25)
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("regress")
            }
        )
    }

    func testCoherentSubPredictionCatchesDelayInducedCancellation() throws {
        let speakerSource: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let sub0: MultichannelCalibrationSource = .subwoofer(0)
        let sub1: MultichannelCalibrationSource = .subwoofer(1)

        let speaker = makeMeasurement(
            seat: seat,
            source: speakerSource,
            magnitudes: [0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0],
            snrDB: 60
        )
        let flatSub0 = makeMeasurement(
            seat: seat,
            source: sub0,
            magnitudes: Array(repeating: 0, count: 11),
            snrDB: 60,
            usableHighHz: 300
        )
        let flatSub1 = makeMeasurement(
            seat: seat,
            source: sub1,
            magnitudes: Array(repeating: 0, count: 11),
            snrDB: 60,
            usableHighHz: 300
        )

        let design = makeDesign(
            speakers: [
                MultichannelSpeakerDesign(
                    role: .frontLeft,
                    calibration: SemanticSpeakerCalibration(
                        eqBands: [
                            OutputCalibrationEQBand(
                                frequencyHz: 1_000,
                                gainDB: -6,
                                q: 1
                            ),
                        ]
                    ),
                    errorBeforeDB: 2.2,
                    errorAfterDB: 0.7,
                    seatVarianceDBSquared: 0
                ),
            ],
            subwoofers: [
                MultichannelSubwooferDesign(
                    index: 0,
                    calibration: PhysicalSubwooferCalibration()
                ),
                MultichannelSubwooferDesign(
                    index: 1,
                    calibration: PhysicalSubwooferCalibration(
                        gainDB: 0,
                        delayMilliseconds: 5,
                        polarityInverted: false,
                        eqBands: []
                    )
                ),
            ]
        )

        let report = try MultichannelCalibrationPredictionVerifier().verify(
            design: design,
            seats: [seat],
            measurements: [speaker, flatSub0, flatSub1]
        )

        XCTAssertNotNil(report.subCombinedRMSErrorBeforeDB)
        XCTAssertNotNil(report.subCombinedRMSErrorAfterDB)
        XCTAssertGreaterThan(
            try XCTUnwrap(report.subCombinedRMSErrorAfterDB),
            try XCTUnwrap(report.subCombinedRMSErrorBeforeDB) + 0.5
        )
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("summed-sub")
                    || $0.localizedCaseInsensitiveContains("subwoofer")
            }
        )
    }

    func testSpeakerDelayPredictionTracksArrivalAlignment() throws {
        let seatA = MultichannelCalibrationSeat(
            name: "Seat A",
            included: true,
            weight: 1
        )
        let left: MultichannelCalibrationSource = .speaker(.frontLeft)
        let right: MultichannelCalibrationSource = .speaker(.frontRight)
        let leftMeasurement = makeMeasurement(
            seat: seatA,
            source: left,
            magnitudes: [0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0],
            snrDB: 60,
            arrivalSeconds: 0.010
        )
        let rightMeasurement = makeMeasurement(
            seat: seatA,
            source: right,
            magnitudes: [0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0],
            snrDB: 60,
            arrivalSeconds: 0.012
        )
        let eq = [
            OutputCalibrationEQBand(
                frequencyHz: 1_000,
                gainDB: -6,
                q: 1
            ),
        ]
        let design = makeDesign(
            speakers: [
                MultichannelSpeakerDesign(
                    role: .frontLeft,
                    calibration: SemanticSpeakerCalibration(
                        delayMilliseconds: 2,
                        eqBands: eq
                    ),
                    errorBeforeDB: 2.2,
                    errorAfterDB: 0.7,
                    seatVarianceDBSquared: 0
                ),
                MultichannelSpeakerDesign(
                    role: .frontRight,
                    calibration: SemanticSpeakerCalibration(
                        delayMilliseconds: 0,
                        eqBands: eq
                    ),
                    errorBeforeDB: 2.2,
                    errorAfterDB: 0.7,
                    seatVarianceDBSquared: 0
                ),
            ]
        )

        let report = try MultichannelCalibrationPredictionVerifier().verify(
            design: design,
            seats: [seatA],
            measurements: [leftMeasurement, rightMeasurement]
        )

        XCTAssertEqual(
            report.maximumSpeakerTimingSpreadBeforeMs,
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            report.maximumSpeakerTimingSpreadAfterMs,
            0,
            accuracy: 0.001
        )
    }

    private func makeDesign(
        speakers: [MultichannelSpeakerDesign],
        subwoofers: [MultichannelSubwooferDesign] = []
    ) -> MultichannelCalibrationDesign {
        MultichannelCalibrationDesign(
            sampleRate: sampleRate,
            speakers: speakers,
            subwoofers: subwoofers,
            summary: MultichannelCalibrationDeploymentSummary(
                measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                deployedAt: Date(timeIntervalSince1970: 1_700_000_010),
                seatCount: 1,
                speakerCount: max(speakers.count, 1),
                subwooferCount: subwoofers.count,
                targetName: "Neutral",
                sampleRate: sampleRate,
                maximumSpeakerErrorBeforeDB:
                    speakers.map(\.errorBeforeDB).max(),
                maximumSpeakerErrorAfterDB:
                    speakers.map(\.errorAfterDB).max(),
                multiSubObjective: subwoofers.isEmpty ? nil : 0
            )
        )
    }

    private func makeMeasurement(
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource,
        magnitudes: [Double],
        snrDB: Double,
        usableHighHz: Double = 20_000,
        arrivalSeconds: Double = 0.010
    ) -> MultichannelCalibrationMeasurement {
        let frequencies = [
            20.0, 40, 80, 160, 400, 1_000,
            2_500, 5_000, 10_000, 15_000, 20_000,
        ]
        return MultichannelCalibrationMeasurement(
            seatID: seat.id,
            source: source,
            sampleRate: sampleRate,
            channel: RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                rawCapture: [],
                impulseResponse: [1],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: magnitudes,
                    phaseRadians: Array(
                        repeating: 0,
                        count: frequencies.count
                    )
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -18,
                    capturePeakDBFS: -12,
                    estimatedNoiseFloorDBFS: -72,
                    estimatedSNRDB: snrDB,
                    sweepComplete: true,
                    directArrivalSeconds: arrivalSeconds,
                    usableLowHz: 20,
                    usableHighHz: usableHighHz,
                    warnings: []
                )
            )
        )
    }
}
