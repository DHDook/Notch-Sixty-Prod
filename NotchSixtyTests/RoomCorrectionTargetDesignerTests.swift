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
}
