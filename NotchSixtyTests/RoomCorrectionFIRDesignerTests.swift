import Foundation
import XCTest
@testable import NotchSixty

final class RoomCorrectionFIRDesignerTests: XCTestCase {
    private func response(
        frequencies: [Double],
        magnitudes: [Double]
    ) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: nil
        )
    }

    private func aggregate(
        frequencies: [Double],
        left: [Double],
        right: [Double]
    ) -> RoomCorrectionAggregateResponse {
        RoomCorrectionAggregateResponse(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            includedPositionIDs: [UUID()],
            leftResponse: response(frequencies: frequencies, magnitudes: left),
            rightResponse: response(frequencies: frequencies, magnitudes: right)
        )
    }

    private func parameters(
        low: Double = 20,
        high: Double = 20_000,
        smoothing: Double = 0,
        maximumBoost: Double = 6,
        maximumCut: Double = 8,
        taps: Int = 4_096
    ) -> RoomCorrectionDesignParameters {
        RoomCorrectionDesignParameters(
            correctionLowHz: low,
            correctionHighHz: high,
            smoothingOctaves: smoothing,
            maximumBoostDB: maximumBoost,
            maximumCutDB: maximumCut,
            requestedTapCount: taps
        )
    }

    func testFlatZeroCorrectionProducesIdentityMinimumPhaseFilter() throws {
        let frequencies: [Double] = [20, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: 0, count: frequencies.count),
            right: Array(repeating: 0, count: frequencies.count)
        )

        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 1_024),
            sampleRate: 48_000,
            name: "Identity"
        )

        XCTAssertEqual(result.design.filter.leftTaps.count, 1_024)
        XCTAssertEqual(result.design.filter.rightTaps?.count, 1_024)
        XCTAssertEqual(result.design.filter.declaredLatencyFrames, 0)
        XCTAssertEqual(result.design.filter.sampleRate, 48_000)
        XCTAssertEqual(result.design.algorithmVersion, RoomCorrectionFIRDesigner.algorithmVersion)
        XCTAssertEqual(result.design.target, RoomCorrectionBuiltInTarget.flat.curve)
        XCTAssertEqual(result.design.filter.leftTaps[0], 1, accuracy: 0.000_01)
        XCTAssertEqual(result.design.filter.rightTaps?[0] ?? 0, 1, accuracy: 0.000_01)
        XCTAssertLessThan(
            result.design.filter.leftTaps.dropFirst().reduce(0) { $0 + abs(Double($1)) },
            0.000_1
        )
        XCTAssertTrue(result.leftFilterResponse.magnitudeDB.allSatisfy { abs($0) < 0.001 })
        XCTAssertTrue(result.rightFilterResponse.magnitudeDB.allSatisfy { abs($0) < 0.001 })
        XCTAssertLessThan(result.maximumPositiveFilterGainDB, 0.001)
    }

    func testStereoCorrectionTracksRequestedMagnitudeAndPredictedResponse() throws {
        let frequencies: [Double] = [20, 40, 80, 160, 320, 640, 1_000, 2_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -3, count: frequencies.count),
            right: Array(repeating: 3, count: frequencies.count)
        )

        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 4_096),
            sampleRate: 48_000,
            usableLowHz: 40,
            usableHighHz: 10_000,
            name: "Stereo Correction"
        )

        guard let index = frequencies.firstIndex(of: 1_000) else {
            XCTFail("Missing 1 kHz fixture point")
            return
        }
        XCTAssertEqual(result.leftFilterResponse.magnitudeDB[index], 3, accuracy: 0.35)
        XCTAssertEqual(result.rightFilterResponse.magnitudeDB[index], -3, accuracy: 0.35)
        XCTAssertEqual(result.design.predictedLeftResponse?.magnitudeDB[index] ?? 99, 0, accuracy: 0.35)
        XCTAssertEqual(result.design.predictedRightResponse?.magnitudeDB[index] ?? 99, 0, accuracy: 0.35)
        XCTAssertGreaterThan(result.maximumPositiveFilterGainDB, 2.5)
        XCTAssertLessThan(result.maximumPositiveFilterGainDB, 3.75)
        XCTAssertGreaterThanOrEqual(result.design.recommendedHeadroomDB, result.maximumPositiveFilterGainDB)
        XCTAssertLessThanOrEqual(result.design.recommendedHeadroomDB, result.maximumPositiveFilterGainDB + 0.75)
        XCTAssertEqual(result.design.filter.declaredLatencyFrames, 0)
        XCTAssertTrue(result.design.filter.leftTaps.allSatisfy(\.isFinite))
        XCTAssertTrue(result.design.filter.rightTaps?.allSatisfy(\.isFinite) ?? false)
    }

    func testSupportedNativeRatesProduceFiniteBoundedFilters() throws {
        let frequencies: [Double] = [20, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -1.5, count: frequencies.count),
            right: Array(repeating: -1.5, count: frequencies.count)
        )
        let designer = RoomCorrectionFIRDesigner()

        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 384_000.0] {
            let result = try designer.design(
                aggregate: measured,
                target: RoomCorrectionBuiltInTarget.flat.curve,
                parameters: parameters(taps: 1_024),
                sampleRate: sampleRate,
                usableLowHz: 20,
                usableHighHz: 20_000,
                name: "Rate \(Int(sampleRate))"
            )
            XCTAssertEqual(result.design.sampleRate, sampleRate)
            XCTAssertEqual(result.design.filter.sampleRate, sampleRate)
            XCTAssertEqual(result.design.filter.leftTaps.count, 1_024)
            XCTAssertEqual(result.design.filter.rightTaps?.count, 1_024)
            XCTAssertTrue(result.design.filter.leftTaps.allSatisfy(\.isFinite))
            XCTAssertTrue(result.design.filter.rightTaps?.allSatisfy(\.isFinite) ?? false)
            XCTAssertTrue(result.leftFilterResponse.magnitudeDB.allSatisfy(\.isFinite))
            XCTAssertTrue(result.rightFilterResponse.magnitudeDB.allSatisfy(\.isFinite))
        }
    }

    func testMaximumTapBudgetProducesFiniteFilter() throws {
        let frequencies: [Double] = [20, 100, 1_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: 0, count: frequencies.count),
            right: Array(repeating: 0, count: frequencies.count)
        )
        let tapCount = Int(N60_CONVOLUTION_MAX_TAPS)

        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: tapCount),
            sampleRate: 48_000
        )

        XCTAssertEqual(result.design.filter.leftTaps.count, tapCount)
        XCTAssertEqual(result.design.filter.rightTaps?.count, tapCount)
        XCTAssertTrue(result.design.filter.leftTaps.allSatisfy(\.isFinite))
        XCTAssertTrue(result.design.filter.rightTaps?.allSatisfy(\.isFinite) ?? false)
    }

    func testDesignRejectsCorrectionAtOrAboveNyquist() {
        let frequencies: [Double] = [20, 100, 1_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: 0, count: frequencies.count),
            right: Array(repeating: 0, count: frequencies.count)
        )

        XCTAssertThrowsError(
            try RoomCorrectionFIRDesigner().design(
                aggregate: measured,
                target: RoomCorrectionBuiltInTarget.flat.curve,
                parameters: parameters(high: 24_000, taps: 1_024),
                sampleRate: 48_000
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionFIRDesignError,
                .correctionRangeExceedsNyquist(high: 24_000, nyquist: 24_000)
            )
        }
    }

    func testGeneratedDesignPassesProjectPersistenceValidation() throws {
        let frequencies: [Double] = [20, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -2, count: frequencies.count),
            right: Array(repeating: -2, count: frequencies.count)
        )
        let target = RoomCorrectionBuiltInTarget.gentleDownwardTilt.curve
        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: target,
            parameters: parameters(taps: 2_048),
            sampleRate: 48_000
        )
        var project = RoomCorrectionProject(
            playbackSystemID: UUID(),
            name: "Persistence Fixture"
        )
        var persistedAggregate = measured
        persistedAggregate.includedPositionIDs = []
        project.aggregate = persistedAggregate
        project.target = target
        project.designs = [result.design]
        project.selectedDesignID = result.design.id

        XCTAssertNoThrow(try project.validateForPersistence())
    }

    func testDeploymentFilterEmbedsRecommendedHeadroomWithoutMutatingDesign() throws {
        let frequencies: [Double] = [20, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -3, count: frequencies.count),
            right: Array(repeating: -3, count: frequencies.count)
        )
        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 1_024),
            sampleRate: 48_000
        )
        let original = result.design.filter
        let deployed = try result.design.deploymentFilter()
        let expectedScale = pow(10.0, -result.design.recommendedHeadroomDB / 20.0)

        XCTAssertEqual(result.design.filter, original, "Deployment normalization must not mutate the reproducible design asset")
        XCTAssertEqual(deployed.sampleRate, original.sampleRate)
        XCTAssertEqual(deployed.declaredLatencyFrames, original.declaredLatencyFrames)
        XCTAssertEqual(deployed.leftTaps.count, original.leftTaps.count)
        for index in deployed.leftTaps.indices {
            XCTAssertEqual(
                Double(deployed.leftTaps[index]),
                Double(original.leftTaps[index]) * expectedScale,
                accuracy: 0.000_001
            )
        }
    }

    func testIndependentRoomDesignVerificationAcceptsActualDeploymentFIR() throws {
        let frequencies = [
            20.0, 40, 80, 160, 400, 1_000,
            2_500, 5_000, 10_000, 15_000, 20_000,
        ]
        let magnitudes = [0.0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0]
        let position = verificationPosition(
            frequencies: frequencies,
            left: magnitudes,
            right: magnitudes,
            snrDB: 60
        )
        let aggregate = RoomCorrectionAggregateResponse(
            generatedAt: Date(),
            includedPositionIDs: [position.id],
            leftResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            ),
            rightResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            )
        )
        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: aggregate,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 4_096),
            sampleRate: 48_000,
            usableLowHz: 20,
            usableHighHz: 20_000,
            sourcePositions: [
                RoomCorrectionDesignSourcePosition(
                    id: position.id,
                    weight: 1
                ),
            ],
            name: "PR86 Verified"
        )

        let report = try RoomCorrectionDesignPredictionVerifier().verify(
            design: result.design,
            positions: [position]
        )

        XCTAssertTrue(
            report.accepted,
            report.blockingReasons.joined(separator: "\n")
        )
        XCTAssertGreaterThanOrEqual(report.confidence, 0.80)
        XCTAssertLessThan(
            report.rmsErrorAfterDB,
            report.rmsErrorBeforeDB
        )
        XCTAssertLessThanOrEqual(
            report.maximumDeploymentFilterGainDB,
            RoomCorrectionDesignPredictionVerifier.headroomToleranceDB
        )
        XCTAssertLessThanOrEqual(
            report.maximumOutOfBandDeviationDB,
            RoomCorrectionDesignPredictionVerifier
                .maximumOutOfBandDeviationDB
        )
        XCTAssertLessThanOrEqual(
            report.storedPredictionDisagreementDB ?? 99,
            RoomCorrectionDesignPredictionVerifier
                .maximumStoredPredictionDisagreementDB
        )
    }

    func testRoomDesignVerificationFailsClosedOnLowConfidenceCapture() throws {
        let frequencies = [
            20.0, 40, 80, 160, 400, 1_000,
            2_500, 5_000, 10_000, 15_000, 20_000,
        ]
        let magnitudes = [0.0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0]
        let highQuality = verificationPosition(
            frequencies: frequencies,
            left: magnitudes,
            right: magnitudes,
            snrDB: 60
        )
        let aggregate = RoomCorrectionAggregateResponse(
            generatedAt: Date(),
            includedPositionIDs: [highQuality.id],
            leftResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            ),
            rightResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            )
        )
        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: aggregate,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 2_048),
            sampleRate: 48_000,
            sourcePositions: [
                RoomCorrectionDesignSourcePosition(
                    id: highQuality.id,
                    weight: 1
                ),
            ]
        )
        let lowQuality = verificationPosition(
            id: highQuality.id,
            frequencies: frequencies,
            left: magnitudes,
            right: magnitudes,
            snrDB: 20
        )

        let report = try RoomCorrectionDesignPredictionVerifier().verify(
            design: result.design,
            positions: [lowQuality]
        )

        XCTAssertFalse(report.accepted)
        XCTAssertLessThan(
            report.confidence,
            RoomCorrectionDesignPredictionVerifier.minimumConfidence
        )
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("confidence")
            }
        )
    }

    func testRoomDesignVerificationRejectsInsufficientHeadroom() throws {
        let frequencies = [20.0, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = Array(repeating: -4.0, count: frequencies.count)
        let position = verificationPosition(
            frequencies: frequencies,
            left: measured,
            right: measured,
            snrDB: 60
        )
        let aggregate = RoomCorrectionAggregateResponse(
            generatedAt: Date(),
            includedPositionIDs: [position.id],
            leftResponse: response(
                frequencies: frequencies,
                magnitudes: measured
            ),
            rightResponse: response(
                frequencies: frequencies,
                magnitudes: measured
            )
        )
        var design = try RoomCorrectionFIRDesigner().design(
            aggregate: aggregate,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 2_048),
            sampleRate: 48_000,
            sourcePositions: [
                RoomCorrectionDesignSourcePosition(
                    id: position.id,
                    weight: 1
                ),
            ]
        ).design
        XCTAssertGreaterThan(design.recommendedHeadroomDB, 0)
        design.recommendedHeadroomDB = 0

        let report = try RoomCorrectionDesignPredictionVerifier().verify(
            design: design,
            positions: [position]
        )

        XCTAssertFalse(report.accepted)
        XCTAssertGreaterThan(report.maximumDeploymentFilterGainDB, 1)
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("headroom")
                    || $0.localizedCaseInsensitiveContains("positive gain")
            }
        )
    }

    func testRoomDesignVerificationRejectsTamperedStoredPrediction() throws {
        let frequencies = [
            20.0, 40, 80, 160, 400, 1_000,
            2_500, 5_000, 10_000, 15_000, 20_000,
        ]
        let magnitudes = [0.0, 0, 0.2, 1, 3, 6, 3, 1, 0.2, 0, 0]
        let position = verificationPosition(
            frequencies: frequencies,
            left: magnitudes,
            right: magnitudes,
            snrDB: 60
        )
        let aggregate = RoomCorrectionAggregateResponse(
            generatedAt: Date(),
            includedPositionIDs: [position.id],
            leftResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            ),
            rightResponse: response(
                frequencies: frequencies,
                magnitudes: magnitudes
            )
        )
        var design = try RoomCorrectionFIRDesigner().design(
            aggregate: aggregate,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 2_048),
            sampleRate: 48_000,
            sourcePositions: [
                RoomCorrectionDesignSourcePosition(
                    id: position.id,
                    weight: 1
                ),
            ]
        ).design
        if var tampered = design.predictedLeftResponse {
            tampered.magnitudeDB = tampered.magnitudeDB.map { $0 + 2.0 }
            design.predictedLeftResponse = tampered
        }

        let report = try RoomCorrectionDesignPredictionVerifier().verify(
            design: design,
            positions: [position]
        )

        XCTAssertFalse(report.accepted)
        XCTAssertGreaterThan(
            report.storedPredictionDisagreementDB ?? 0,
            RoomCorrectionDesignPredictionVerifier
                .maximumStoredPredictionDisagreementDB
        )
        XCTAssertTrue(
            report.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("predictions disagree")
            }
        )
    }

    private func verificationPosition(
        id: UUID = UUID(),
        frequencies: [Double],
        left: [Double],
        right: [Double],
        snrDB: Double
    ) -> RoomCorrectionMeasurementPosition {
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -72,
            estimatedSNRDB: snrDB,
            sweepComplete: true,
            directArrivalSeconds: 0.01,
            usableLowHz: frequencies.first,
            usableHighHz: frequencies.last,
            warnings: []
        )
        return RoomCorrectionMeasurementPosition(
            id: id,
            name: "Verification Seat",
            included: true,
            weight: 1,
            sampleRate: 48_000,
            left: RoomCorrectionChannelMeasurement(
                capturedAt: Date(),
                rawCapture: [],
                impulseResponse: [1],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: left,
                    phaseRadians: nil
                ),
                quality: quality
            ),
            right: RoomCorrectionChannelMeasurement(
                capturedAt: Date(),
                rawCapture: [],
                impulseResponse: [1],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: right,
                    phaseRadians: nil
                ),
                quality: quality
            )
        )
    }


}
