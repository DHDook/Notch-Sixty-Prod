import Foundation
import XCTest
@testable import NotchSixty

final class RoomCorrectionTargetDesignerTests: XCTestCase {
    private func response(
        frequencies: [Double],
        magnitudes: [Double]
    ) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: Array(repeating: 0, count: frequencies.count)
        )
    }

    private func aggregate(
        frequencies: [Double],
        left: [Double],
        right: [Double]
    ) -> RoomCorrectionAggregateResponse {
        RoomCorrectionAggregateResponse(
            generatedAt: Date(timeIntervalSince1970: 100),
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

    func testBuiltInTargetsHaveStableIdentityAndValidInterpolation() throws {
        let targets = RoomCorrectionBuiltInTarget.allCases.map(\.curve)
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(Set(targets.map(\.id)).count, 3)
        XCTAssertEqual(
            targets.map(\.name),
            ["Flat", "Gentle Downward Tilt", "Bass Shelf + Tilt"]
        )

        for target in targets {
            XCTAssertGreaterThanOrEqual(target.points.count, 2)
            XCTAssertTrue(target.points.allSatisfy { $0.frequencyHz.isFinite && $0.gainDB.isFinite })
            _ = try target.interpolatedGainDB(at: 1_000)
        }
        XCTAssertEqual(try RoomCorrectionBuiltInTarget.flat.curve.interpolatedGainDB(at: 1_000), 0)
    }

    func testTargetParserSortsDeduplicatesAndInterpolatesInLogFrequency() throws {
        let parsed = try RoomCorrectionTargetCurveParser().parse(
            "# target\n1000 0\n100, 3\n100 1\n10000 -3",
            name: "Custom"
        )

        XCTAssertEqual(parsed.name, "Custom")
        XCTAssertEqual(parsed.points.map(\.frequencyHz), [100, 1_000, 10_000])
        XCTAssertEqual(parsed.points[0].gainDB, 2, accuracy: 0.000_001)
        XCTAssertEqual(
            try parsed.interpolatedGainDB(at: sqrt(100 * 1_000)),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(try parsed.interpolatedGainDB(at: 20), 2, accuracy: 0.000_001)
        XCTAssertEqual(try parsed.interpolatedGainDB(at: 20_000), -3, accuracy: 0.000_001)
    }

    func testTargetParserRejectsAmbiguousOrInsufficientInput() {
        XCTAssertThrowsError(
            try RoomCorrectionTargetCurveParser().parse("100 1 2\n1000 0")
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionTargetDesignError,
                .malformedTargetLine(1)
            )
        }
        XCTAssertThrowsError(
            try RoomCorrectionTargetCurveParser().parse("100 1\n100 2")
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionTargetDesignError,
                .insufficientTargetPoints
            )
        }
    }

    func testFractionalOctaveSmoothingReducesNarrowSpikeWithoutMutatingInput() throws {
        let factor = pow(2.0, 0.25)
        let center = 282.842712474619
        let frequencies = (-4...4).map { center * pow(factor, Double($0)) }
        var magnitudes = Array(repeating: 0.0, count: frequencies.count)
        magnitudes[4] = -20
        let original = response(frequencies: frequencies, magnitudes: magnitudes)

        let smoothed = try RoomCorrectionMagnitudeSmoother().smooth(original, octaves: 1.0)

        XCTAssertEqual(original.magnitudeDB[4], -20)
        XCTAssertGreaterThan(smoothed.magnitudeDB[4], -20)
        XCTAssertLessThan(smoothed.magnitudeDB[4], 0)
        XCTAssertEqual(smoothed.magnitudeDB[4], -10, accuracy: 0.000_01)
        XCTAssertNil(smoothed.phaseRadians)
    }

    func testCorrectionPreviewRespectsUsableRangeAndBoostCutLimits() throws {
        let frequencies: [Double] = [20, 40, 80, 160, 320, 640, 1_280, 2_560, 5_120, 10_240, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -12, count: frequencies.count),
            right: Array(repeating: 12, count: frequencies.count)
        )

        let preview = try RoomCorrectionCorrectionPreviewDesigner().preview(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(
                low: 40,
                high: 10_000,
                maximumBoost: 6,
                maximumCut: 4
            ),
            usableLowHz: 80,
            usableHighHz: 5_120
        )

        XCTAssertEqual(preview.effectiveCorrectionLowHz, 80)
        XCTAssertEqual(preview.effectiveCorrectionHighHz, 5_120)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[0], 0)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[2], 0)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[3], 6, accuracy: 0.000_001)
        XCTAssertEqual(preview.rightCorrectionResponse.magnitudeDB[3], -4, accuracy: 0.000_001)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[8], 0)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[9], 0)
        XCTAssertEqual(preview.maximumPositiveCorrectionDB, 6, accuracy: 0.000_001)
        XCTAssertEqual(preview.estimatedHeadroomDB, 6.5, accuracy: 0.000_001)
        XCTAssertTrue(preview.targetResponse.magnitudeDB.allSatisfy { abs($0) < 0.000_001 })
    }

    func testDeepNarrowNullSuppressesBoostAfterSmoothing() throws {
        let factor = pow(2.0, 0.25)
        let center = 282.842712474619
        let frequencies = (-4...4).map { center * pow(factor, Double($0)) }
        var magnitudes = Array(repeating: 0.0, count: frequencies.count)
        magnitudes[4] = -20
        let measured = aggregate(
            frequencies: frequencies,
            left: magnitudes,
            right: magnitudes
        )

        let preview = try RoomCorrectionCorrectionPreviewDesigner().preview(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(
                low: frequencies.first!,
                high: frequencies.last!,
                smoothing: 1.0,
                maximumBoost: 6,
                maximumCut: 8
            )
        )

        XCTAssertEqual(preview.smoothedLeftResponse.magnitudeDB[4], -10, accuracy: 0.000_01)
        XCTAssertEqual(preview.leftCorrectionResponse.magnitudeDB[4], 2, accuracy: 0.000_01)
        XCTAssertLessThan(preview.leftCorrectionResponse.magnitudeDB[4], 6)
    }

    func testPreviewRejectsInvalidLimitsAndNonOverlappingUsableRange() {
        let frequencies: [Double] = [100, 1_000, 10_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: [0, 0, 0],
            right: [0, 0, 0]
        )
        let designer = RoomCorrectionCorrectionPreviewDesigner()

        XCTAssertThrowsError(
            try designer.preview(
                aggregate: measured,
                target: RoomCorrectionBuiltInTarget.flat.curve,
                parameters: parameters(maximumBoost: -1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionTargetDesignError,
                .invalidMaximumBoost(-1)
            )
        }

        XCTAssertThrowsError(
            try designer.preview(
                aggregate: measured,
                target: RoomCorrectionBuiltInTarget.flat.curve,
                parameters: parameters(low: 20, high: 80),
                usableLowHz: 100,
                usableHighHz: 10_000
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionTargetDesignError,
                .noUsableCorrectionRange
            )
        }

        XCTAssertThrowsError(
            try designer.preview(
                aggregate: measured,
                target: RoomCorrectionBuiltInTarget.flat.curve,
                parameters: parameters(taps: Int(N60_CONVOLUTION_MAX_TAPS) + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionTargetDesignError,
                .invalidTapCount(Int(N60_CONVOLUTION_MAX_TAPS) + 1)
            )
        }
    }

    func testIntelligentTargetsAreDeterministicBoundedAndPreferenceOrdered() throws {
        let frequencies = [
            20.0, 40, 80, 160, 300, 1_000,
            4_000, 10_000, 20_000,
        ]
        let magnitudes = [0.0, 0, 0, 0, 0, 0, -1, -2, -2.5]
        let sample = intelligentSample(
            frequencies: frequencies,
            magnitudes: magnitudes,
            snrDB: 60
        )
        let generator = IntelligentRoomTargetGenerator()
        let neutral = try generator.generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .neutral
        )
        let neutralAgain = try generator.generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .neutral
        )
        let warm = try generator.generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .warm
        )
        let studio = try generator.generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .studio
        )

        XCTAssertEqual(neutral, neutralAgain)
        XCTAssertGreaterThan(warm.generatedBassShelfDB, neutral.generatedBassShelfDB)
        XCTAssertGreaterThan(neutral.generatedBassShelfDB, studio.generatedBassShelfDB)
        XCTAssertLessThan(warm.generatedTrebleAt20KDB, neutral.generatedTrebleAt20KDB)
        XCTAssertLessThan(neutral.generatedTrebleAt20KDB, studio.generatedTrebleAt20KDB)
        XCTAssertLessThanOrEqual(
            warm.generatedBassShelfDB,
            IntelligentRoomTargetGenerator.maximumBassShelfDB
        )
        XCTAssertGreaterThanOrEqual(
            warm.generatedTrebleAt20KDB,
            IntelligentRoomTargetGenerator.minimumTrebleAt20KDB
        )
        XCTAssertLessThanOrEqual(
            studio.generatedTrebleAt20KDB,
            IntelligentRoomTargetGenerator.maximumTrebleAt20KDB
        )
        XCTAssertLessThanOrEqual(neutral.maximumRequestedBoostDB, 4.000_1)
        XCTAssertLessThanOrEqual(neutral.maximumRequestedCutDB, 8.000_1)
    }

    func testIntelligentTargetLowConfidenceFallsBackConservatively() throws {
        let sample = intelligentSample(
            frequencies: [20, 40, 80, 160, 300, 1_000, 4_000, 10_000, 20_000],
            magnitudes: [0, 0, 0, 0, 0, 0, -1, -2, -3],
            snrDB: 20
        )

        let report = try IntelligentRoomTargetGenerator().generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .warm
        )

        XCTAssertTrue(report.fallbackUsed)
        XCTAssertLessThan(
            report.confidence,
            IntelligentRoomTargetGenerator.minimumConfidence
        )
        XCTAssertTrue(
            report.warnings.contains {
                $0.localizedCaseInsensitiveContains("confidence")
            }
        )
        XCTAssertGreaterThanOrEqual(report.generatedBassShelfDB, 0)
        XCTAssertLessThanOrEqual(
            report.generatedBassShelfDB,
            IntelligentRoomTargetGenerator.maximumBassShelfDB
        )
    }

    func testIntelligentTargetSpatialVarianceReducesAggressiveness() throws {
        let frequencies = [
            20.0, 40, 80, 160, 300, 1_000,
            4_000, 10_000, 20_000,
        ]
        let stable = intelligentSample(
            label: "Stable",
            frequencies: frequencies,
            magnitudes: Array(repeating: 0, count: frequencies.count),
            snrDB: 60
        )
        let high = intelligentSample(
            label: "High",
            frequencies: frequencies,
            magnitudes: Array(repeating: 6, count: frequencies.count),
            snrDB: 60,
            weight: 0.5
        )
        let low = intelligentSample(
            label: "Low",
            frequencies: frequencies,
            magnitudes: Array(repeating: -6, count: frequencies.count),
            snrDB: 60,
            weight: 0.5
        )

        let generator = IntelligentRoomTargetGenerator()
        let stableReport = try generator.generate(
            samples: [stable],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .warm
        )
        let variableReport = try generator.generate(
            samples: [high, low],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .warm
        )

        XCTAssertGreaterThan(variableReport.meanSpatialDeviationDB, 5)
        XCTAssertLessThan(variableReport.confidence, stableReport.confidence)
        XCTAssertLessThan(
            variableReport.generatedBassShelfDB,
            stableReport.generatedBassShelfDB
        )
        XCTAssertTrue(
            variableReport.warnings.contains {
                $0.localizedCaseInsensitiveContains("variance")
            }
        )
    }

    func testIntelligentTargetDoesNotTraceNarrowRoomNull() throws {
        let frequencies = [
            20.0, 40, 80, 160, 300, 700, 1_000,
            4_000, 10_000, 20_000,
        ]
        let magnitudes = [0.0, 0, 0, 0, 0, -20, 0, -1, -2, -2.5]
        let sample = intelligentSample(
            frequencies: frequencies,
            magnitudes: magnitudes,
            snrDB: 60
        )

        let report = try IntelligentRoomTargetGenerator().generate(
            samples: [sample],
            parameters: parameters(maximumBoost: 4, maximumCut: 8),
            preference: .neutral
        )

        XCTAssertFalse(
            report.target.points.contains {
                abs($0.frequencyHz - 700) < 0.001
            },
            "A narrow measurement null must not become a target anchor."
        )
        XCTAssertLessThanOrEqual(report.target.points.count, 9)
        XCTAssertTrue(
            report.target.points.allSatisfy {
                $0.gainDB.isFinite
            }
        )
    }

    func testIntelligentTargetClampsToConfiguredCorrectionLimits() throws {
        let sample = intelligentSample(
            frequencies: [20, 40, 80, 160, 300, 1_000, 4_000, 10_000, 20_000],
            magnitudes: [-8, -6, -4, 0, 0, 0, 4, 6, 8],
            snrDB: 60
        )

        let report = try IntelligentRoomTargetGenerator().generate(
            samples: [sample],
            parameters: parameters(
                maximumBoost: 1,
                maximumCut: 2
            ),
            preference: .warm
        )

        XCTAssertLessThanOrEqual(report.maximumRequestedBoostDB, 1.000_1)
        XCTAssertLessThanOrEqual(report.maximumRequestedCutDB, 2.000_1)
        XCTAssertFalse(report.clampDecisions.isEmpty)
        XCTAssertGreaterThanOrEqual(report.effectiveLowHz, 20)
        XCTAssertLessThanOrEqual(report.effectiveHighHz, 20_000)
    }

    func testIntelligentTargetDoesNotDemandUnsupportedDeepBass() throws {
        let frequencies = [
            20.0, 40, 80, 160, 300, 1_000,
            4_000, 10_000, 20_000,
        ]
        let deep = intelligentSample(
            label: "Deep Extension",
            frequencies: frequencies,
            magnitudes: [0, 0, 0, 0, 0, 0, -1, -2, -2.5],
            snrDB: 60
        )
        let limited = intelligentSample(
            label: "Limited Extension",
            frequencies: frequencies,
            magnitudes: [-14, -12, -9, -3, 0, 0, -1, -2, -2.5],
            snrDB: 60
        )
        let generator = IntelligentRoomTargetGenerator()
        let parameters = parameters(maximumBoost: 4, maximumCut: 8)

        let deepReport = try generator.generate(
            samples: [deep],
            parameters: parameters,
            preference: .warm
        )
        let limitedReport = try generator.generate(
            samples: [limited],
            parameters: parameters,
            preference: .warm
        )

        XCTAssertGreaterThan(
            limitedReport.estimatedBassExtensionHz,
            deepReport.estimatedBassExtensionHz
        )
        XCTAssertLessThan(
            limitedReport.generatedBassShelfDB,
            deepReport.generatedBassShelfDB
        )
        XCTAssertLessThanOrEqual(
            limitedReport.maximumRequestedBoostDB,
            parameters.maximumBoostDB + 0.000_1
        )
    }


    private func intelligentSample(
        label: String = "Fixture",
        frequencies: [Double],
        magnitudes: [Double],
        snrDB: Double,
        weight: Double = 1
    ) -> IntelligentTargetEvidenceSample {
        IntelligentTargetEvidenceSample(
            label: label,
            response: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: magnitudes,
                phaseRadians: nil
            ),
            quality: RoomCorrectionMeasurementQuality(
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
            ),
            weight: weight
        )
    }

}
