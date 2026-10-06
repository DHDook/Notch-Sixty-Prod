import Foundation
import XCTest
@testable import NotchSixty

final class MIMORoomTreatmentDesignerTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testMeasuredTwoSourceTwoSeatDesignProducesBoundedSimulationPlan() throws {
        let seatA = MultichannelCalibrationSeat(name: "Center")
        let seatB = MultichannelCalibrationSeat(name: "Right")
        let sources: [MultichannelCalibrationSource] = [
            .speaker(.frontLeft),
            .speaker(.frontRight),
        ]
        let measurements = [
            measurement(
                seat: seatA,
                source: sources[0],
                magnitudes: [5.1, 5.1, 3.8, 2.6, 1.5],
                phases: [0.0, 0.0, 0.20, -0.15, -0.20]
            ),
            measurement(
                seat: seatA,
                source: sources[1],
                magnitudes: [-10.5, -10.5, -7.5, -5.2, -3.0],
                phases: [0.10, 0.10, -0.08, 0.10, 0.15]
            ),
            measurement(
                seat: seatB,
                source: sources[0],
                magnitudes: [-8.0, -8.0, -6.4, -4.1, -2.0],
                phases: [-0.10, -0.10, 0.05, 0.12, 0.18]
            ),
            measurement(
                seat: seatB,
                source: sources[1],
                magnitudes: [3.5, 3.5, 2.6, 1.6, 0.8],
                phases: [0.0, 0.0, -0.16, -0.08, -0.10]
            ),
        ]

        var configuration = MIMORoomTreatmentConfiguration.conservative
        configuration.frequencyCount = 12
        configuration.minimumPredictedImprovementDB = 0.5
        configuration.maximumRobustnessDegradationDB = 3.0
        configuration.minimumColumnSafetyScale = 0.05

        let plan = try MIMORoomTreatmentDesigner().design(
            sources: sources,
            seats: [seatA, seatB],
            measurements: measurements,
            sampleRate: sampleRate,
            configuration: configuration
        )

        XCTAssertTrue(plan.simulationOnly)
        XCTAssertEqual(plan.sources, sources)
        XCTAssertEqual(plan.seatIDs, [seatA.id, seatB.id])
        XCTAssertEqual(plan.frequenciesHz.count, 12)
        XCTAssertEqual(plan.frequencyResults.count, 12)
        XCTAssertEqual(plan.coefficients.count, 12 * 2 * 2)
        XCTAssertGreaterThan(plan.acceptedFrequencyCount, 0)

        for result in plan.frequencyResults {
            XCTAssertGreaterThanOrEqual(result.frequencyHz, 20)
            XCTAssertLessThanOrEqual(result.frequencyHz, 150.000_001)
            XCTAssertLessThanOrEqual(result.maximumCoefficientMagnitude, 1.000_001)
            XCTAssertLessThanOrEqual(result.maximumColumnPower, 1.000_001)
            XCTAssertGreaterThan(result.minimumAppliedSafetyScale, 0)
            XCTAssertLessThanOrEqual(result.minimumAppliedSafetyScale, 1)
        }

        for frequencyIndex in plan.frequenciesHz.indices {
            guard !plan.frequencyResults[frequencyIndex].accepted else { continue }
            for sourceIndex in sources.indices {
                for targetIndex in sources.indices {
                    let coefficient = try XCTUnwrap(plan.coefficient(
                        frequencyIndex: frequencyIndex,
                        sourceIndex: sourceIndex,
                        targetIndex: targetIndex
                    ))
                    XCTAssertEqual(
                        coefficient.real,
                        sourceIndex == targetIndex ? 1 : 0,
                        accuracy: 1.0e-12
                    )
                    XCTAssertEqual(coefficient.imaginary, 0, accuracy: 1.0e-12)
                }
            }
        }
    }

    func testSpatiallyUniformFieldProducesNoTreatmentAndExactIdentity() throws {
        let seatA = MultichannelCalibrationSeat(name: "A")
        let seatB = MultichannelCalibrationSeat(name: "B")
        let sources: [MultichannelCalibrationSource] = [
            .speaker(.frontLeft),
            .speaker(.frontRight),
        ]

        let left = response(
            magnitudes: [0, 0, 0, 0, 0],
            phases: [0, 0, 0, 0, 0]
        )
        let right = response(
            magnitudes: [-5, -5, -5, -5, -5],
            phases: [0.2, 0.2, 0.2, 0.2, 0.2]
        )
        let measurements = [
            measurement(seat: seatA, source: sources[0], response: left),
            measurement(seat: seatB, source: sources[0], response: left),
            measurement(seat: seatA, source: sources[1], response: right),
            measurement(seat: seatB, source: sources[1], response: right),
        ]

        var configuration = MIMORoomTreatmentConfiguration.conservative
        configuration.frequencyCount = 8
        let plan = try MIMORoomTreatmentDesigner().design(
            sources: sources,
            seats: [seatA, seatB],
            measurements: measurements,
            sampleRate: sampleRate,
            configuration: configuration
        )

        XCTAssertEqual(plan.acceptedFrequencyCount, 0)
        XCTAssertTrue(plan.frequencyResults.allSatisfy { !$0.accepted })
        for frequencyIndex in plan.frequenciesHz.indices {
            for sourceIndex in sources.indices {
                for targetIndex in sources.indices {
                    let coefficient = try XCTUnwrap(plan.coefficient(
                        frequencyIndex: frequencyIndex,
                        sourceIndex: sourceIndex,
                        targetIndex: targetIndex
                    ))
                    XCTAssertEqual(
                        coefficient.real,
                        sourceIndex == targetIndex ? 1 : 0,
                        accuracy: 1.0e-12
                    )
                    XCTAssertEqual(coefficient.imaginary, 0, accuracy: 1.0e-12)
                }
            }
        }
    }

    func testMissingSourceSeatMeasurementFailsClosed() throws {
        let seatA = MultichannelCalibrationSeat(name: "A")
        let seatB = MultichannelCalibrationSeat(name: "B")
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let measurements = [
            measurement(
                seat: seatA,
                source: source,
                magnitudes: [0, 0, 0, 0, 0],
                phases: [0, 0, 0, 0, 0]
            ),
        ]

        XCTAssertThrowsError(
            try MIMORoomTreatmentDesigner().design(
                sources: [source],
                seats: [seatA, seatB],
                measurements: measurements,
                sampleRate: sampleRate
            )
        ) { error in
            guard case MIMORoomTreatmentDesignError.missingMeasurement(
                let seatID,
                let missingSource
            ) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(seatID, seatB.id)
            XCTAssertEqual(missingSource, source)
        }
    }

    func testMissingPhaseDataFailsClosed() throws {
        let seat = MultichannelCalibrationSeat(name: "A")
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let transfer = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 40, 63, 100, 150],
            magnitudeDB: [0, 0, 0, 0, 0],
            phaseRadians: nil
        )

        XCTAssertThrowsError(
            try MIMORoomTreatmentDesigner().design(
                sources: [source],
                seats: [seat],
                measurements: [
                    measurement(seat: seat, source: source, response: transfer),
                ],
                sampleRate: sampleRate
            )
        ) { error in
            XCTAssertEqual(
                error as? MIMORoomTreatmentDesignError,
                .invalidTransferFunction(source: source)
            )
        }
    }

    func testDuplicateActuatorSourceIsRejected() throws {
        let seat = MultichannelCalibrationSeat(name: "A")
        let source: MultichannelCalibrationSource = .subwoofer(0)
        XCTAssertThrowsError(
            try MIMORoomTreatmentDesigner().design(
                sources: [source, source],
                seats: [seat],
                measurements: [],
                sampleRate: sampleRate
            )
        ) { error in
            XCTAssertEqual(
                error as? MIMORoomTreatmentDesignError,
                .duplicateSource(source)
            )
        }
    }

    private func measurement(
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource,
        magnitudes: [Double],
        phases: [Double]
    ) -> MultichannelCalibrationMeasurement {
        measurement(
            seat: seat,
            source: source,
            response: response(magnitudes: magnitudes, phases: phases)
        )
    }

    private func response(
        magnitudes: [Double],
        phases: [Double]
    ) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 40, 63, 100, 150],
            magnitudeDB: magnitudes,
            phaseRadians: phases
        )
    }

    private func measurement(
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource,
        response: RoomCorrectionFrequencyResponse
    ) -> MultichannelCalibrationMeasurement {
        MultichannelCalibrationMeasurement(
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
