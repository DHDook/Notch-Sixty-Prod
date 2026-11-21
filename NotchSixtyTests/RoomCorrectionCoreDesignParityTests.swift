import Foundation
import XCTest
@testable import NotchSixty

/// E21 S6a and S6b: the core's room-correction design maths against the Swift implementation it replaces under
/// `e21.core-designers`, at the eight standard device rates (parity protocol, design note 9d).
final class RoomCorrectionCoreDesignParityTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func logGrid(_ count: Int, low: Double = 20, high: Double = 20_000) -> [Double] {
        (0..<count).map { low * pow(high / low, Double($0) / Double(count - 1)) }
    }

    private func response(_ frequencies: [Double], _ magnitude: (Double) -> Double) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies, magnitudeDB: frequencies.map(magnitude), phaseRadians: nil)
    }

    private func aggregate(_ frequencies: [Double]) -> RoomCorrectionAggregateResponse {
        RoomCorrectionAggregateResponse(
            generatedAt: Date(timeIntervalSince1970: 100),
            includedPositionIDs: [UUID()],
            leftResponse: response(frequencies) { 4 * sin(log2($0) * 3) + (abs($0 - 120) < 15 ? -14 : 0) },
            rightResponse: response(frequencies) { 3 * cos(log2($0) * 2.3) + ($0 > 5_000 ? -4 : 0) })
    }

    private func parameters(taps: Int = 2_048, smoothing: Double = 1.0 / 6.0) -> RoomCorrectionDesignParameters {
        RoomCorrectionDesignParameters(
            correctionLowHz: 25, correctionHighHz: 16_000, smoothingOctaves: smoothing, maximumBoostDB: 6,
            maximumCutDB: 10, requestedTapCount: taps)
    }

    func testDesignerPicksUpTheFlagAtConstruction() {
        let expected = FeatureFlags.isEnabledProcessWide(.coreDesigners)
        XCTAssertEqual(RoomCorrectionFIRDesigner().useCoreMaths, expected)
        XCTAssertEqual(RoomCorrectionCorrectionPreviewDesigner().useCoreMaths, expected)
        XCTAssertEqual(RoomCorrectionTargetCurveParser().useCoreMaths, expected)
    }

    func testBuiltInTargetPointsMatchTheSwiftCurves() {
        for (index, builtIn) in RoomCorrectionBuiltInTarget.allCases.enumerated() {
            XCTAssertEqual(RoomCorrectionCore.builtInTargetPoints(index: index), builtIn.curve.points, "\(builtIn)")
        }
    }

    func testParserParityOnFixturesAndErrors() throws {
        let valid = [
            "# comment\n1000, 2\n\n100\t-3\n; c\n// c\n* c\n1000 4\n20000 0\n",
            "20 1.5\r\n1000 0\r\n20000 -2.5\r\n",
            "1e2 +1.5\n2e3 -0.5e1\n   50   0  \n",
            "100 1\n100 3\n200 5\n",
        ]
        for text in valid {
            let swift = try RoomCorrectionTargetCurveParser(useCoreMaths: false).parse(text, id: UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000199")!)
            let core = try RoomCorrectionTargetCurveParser(useCoreMaths: true).parse(text, id: UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000199")!)
            XCTAssertEqual(core, swift, text)
        }
        let malformed = [
            "", "# only\n", "100 1\n", "100 1\n100 2\n", "100 1\n200 x\n", "100 1 5\n", "100\n", "0 1\n", "-5 1\n",
            "100 1\ninf 1\n", "100 nan\n", "100 1\r\n200 oops\r\n", "\n\n 300 1\n400\n",
        ]
        for text in malformed {
            var swiftError: RoomCorrectionTargetDesignError?
            var coreError: RoomCorrectionTargetDesignError?
            do { _ = try RoomCorrectionTargetCurveParser(useCoreMaths: false).parse(text) } catch {
                swiftError = error as? RoomCorrectionTargetDesignError
            }
            do { _ = try RoomCorrectionTargetCurveParser(useCoreMaths: true).parse(text) } catch {
                coreError = error as? RoomCorrectionTargetDesignError
            }
            XCTAssertNotNil(swiftError, text)
            XCTAssertEqual(coreError, swiftError, text)
        }
    }

    func testPreviewParityAcrossParameters() throws {
        let frequencies = logGrid(240)
        let target = RoomCorrectionBuiltInTarget.bassShelfAndTilt.curve
        for smoothing in [0.0, 1.0 / 6.0, 1.0] {
            for (low, high) in [(nil, nil), (60.0, 9_000.0)] as [(Double?, Double?)] {
                var swiftDesigner = RoomCorrectionCorrectionPreviewDesigner()
                swiftDesigner.useCoreMaths = false
                var coreDesigner = RoomCorrectionCorrectionPreviewDesigner()
                coreDesigner.useCoreMaths = true
                let swift = try swiftDesigner.preview(
                    aggregate: aggregate(frequencies), target: target, parameters: parameters(smoothing: smoothing),
                    usableLowHz: low, usableHighHz: high)
                let core = try coreDesigner.preview(
                    aggregate: aggregate(frequencies), target: target, parameters: parameters(smoothing: smoothing),
                    usableLowHz: low, usableHighHz: high)
                XCTAssertEqual(core.effectiveCorrectionLowHz, swift.effectiveCorrectionLowHz)
                XCTAssertEqual(core.effectiveCorrectionHighHz, swift.effectiveCorrectionHighHz)
                XCTAssertEqual(core.maximumPositiveCorrectionDB, swift.maximumPositiveCorrectionDB, accuracy: 1e-9)
                XCTAssertEqual(core.estimatedHeadroomDB, swift.estimatedHeadroomDB)
                for (a, b) in [
                    (core.targetResponse, swift.targetResponse), (core.smoothedLeftResponse, swift.smoothedLeftResponse),
                    (core.smoothedRightResponse, swift.smoothedRightResponse),
                    (core.leftCorrectionResponse, swift.leftCorrectionResponse),
                    (core.rightCorrectionResponse, swift.rightCorrectionResponse),
                ] {
                    XCTAssertEqual(a.frequenciesHz, b.frequenciesHz)
                    for (x, y) in zip(a.magnitudeDB, b.magnitudeDB) { XCTAssertEqual(x, y, accuracy: 1e-9) }
                }
            }
        }
    }

    func testPreviewErrorParity() {
        let frequencies = logGrid(60)
        let target = RoomCorrectionBuiltInTarget.flat.curve
        let cases: [(RoomCorrectionDesignParameters, Double?, Double?)] = [
            (RoomCorrectionDesignParameters(correctionLowHz: 100, correctionHighHz: 50, smoothingOctaves: 0, maximumBoostDB: 6, maximumCutDB: 6, requestedTapCount: 1024), nil, nil),
            (RoomCorrectionDesignParameters(correctionLowHz: 20, correctionHighHz: 5000, smoothingOctaves: -1, maximumBoostDB: 6, maximumCutDB: 6, requestedTapCount: 1024), nil, nil),
            (RoomCorrectionDesignParameters(correctionLowHz: 20, correctionHighHz: 5000, smoothingOctaves: 0, maximumBoostDB: -1, maximumCutDB: 6, requestedTapCount: 1024), nil, nil),
            (RoomCorrectionDesignParameters(correctionLowHz: 20, correctionHighHz: 5000, smoothingOctaves: 0, maximumBoostDB: 6, maximumCutDB: -1, requestedTapCount: 1024), nil, nil),
            (RoomCorrectionDesignParameters(correctionLowHz: 20, correctionHighHz: 5000, smoothingOctaves: 0, maximumBoostDB: 6, maximumCutDB: 6, requestedTapCount: 0), nil, nil),
            (parameters(), 500, 400),
            (parameters(), 17_000, 19_000),
        ]
        for (index, entry) in cases.enumerated() {
            var swiftError: RoomCorrectionTargetDesignError?
            var coreError: RoomCorrectionTargetDesignError?
            var swiftDesigner = RoomCorrectionCorrectionPreviewDesigner()
            swiftDesigner.useCoreMaths = false
            var coreDesigner = RoomCorrectionCorrectionPreviewDesigner()
            coreDesigner.useCoreMaths = true
            do { _ = try swiftDesigner.preview(aggregate: aggregate(frequencies), target: target, parameters: entry.0, usableLowHz: entry.1, usableHighHz: entry.2) } catch { swiftError = error as? RoomCorrectionTargetDesignError }
            do { _ = try coreDesigner.preview(aggregate: aggregate(frequencies), target: target, parameters: entry.0, usableLowHz: entry.1, usableHighHz: entry.2) } catch { coreError = error as? RoomCorrectionTargetDesignError }
            XCTAssertNotNil(swiftError, "case \(index)")
            XCTAssertEqual(coreError, swiftError, "case \(index)")
        }
    }

    func testFIRDesignParityAtTheEightRates() throws {
        for rate in rates {
            let frequencies = logGrid(200, low: 20, high: min(20_000, rate * 0.45))
            var swiftDesigner = RoomCorrectionFIRDesigner()
            swiftDesigner.useCoreMaths = false
            var coreDesigner = RoomCorrectionFIRDesigner()
            coreDesigner.useCoreMaths = true
            let target = RoomCorrectionBuiltInTarget.gentleDownwardTilt.curve
            let id = UUID()
            let date = Date(timeIntervalSince1970: 200)
            let swift = try swiftDesigner.design(
                aggregate: aggregate(frequencies), target: target, parameters: parameters(), sampleRate: rate, createdAt: date, id: id)
            let core = try coreDesigner.design(
                aggregate: aggregate(frequencies), target: target, parameters: parameters(), sampleRate: rate, createdAt: date, id: id)
            XCTAssertEqual(core.design.filter.leftTaps, swift.design.filter.leftTaps, "taps come from the same core call at \(rate)")
            XCTAssertEqual(core.design.filter.rightTaps, swift.design.filter.rightTaps)
            XCTAssertEqual(core.design.recommendedHeadroomDB, swift.design.recommendedHeadroomDB, "\(rate)")
            XCTAssertEqual(core.maximumPositiveFilterGainDB, swift.maximumPositiveFilterGainDB, accuracy: 0.01, "\(rate)")
            for (a, b) in [
                (core.leftFilterResponse, swift.leftFilterResponse), (core.rightFilterResponse, swift.rightFilterResponse),
                (core.design.predictedLeftResponse!, swift.design.predictedLeftResponse!),
                (core.design.predictedRightResponse!, swift.design.predictedRightResponse!),
            ] {
                XCTAssertEqual(a.frequenciesHz, b.frequenciesHz)
                for (x, y) in zip(a.magnitudeDB, b.magnitudeDB) { XCTAssertEqual(x, y, accuracy: 0.01, "\(rate)") }
            }
            XCTAssertEqual(core.design.effectiveCorrectionLowHz, swift.design.effectiveCorrectionLowHz)
            XCTAssertEqual(core.design.effectiveCorrectionHighHz, swift.design.effectiveCorrectionHighHz)
        }
    }

    func testDeploymentScalingMatchesTheSwiftFormula() throws {
        let frequencies = logGrid(120)
        let result = try RoomCorrectionFIRDesigner(useCoreMaths: true).design(
            aggregate: aggregate(frequencies), target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(), sampleRate: 48_000)
        let headroom = result.design.recommendedHeadroomDB
        let scale = pow(10.0, -headroom / 20.0)
        let deployed = try result.design.deploymentFilter()
        for (a, b) in zip(deployed.leftTaps, result.design.filter.leftTaps) {
            XCTAssertEqual(a, Float(Double(b) * scale))
        }
    }

    func testCoreRejectsInvalidDeploymentHeadroom() {
        XCTAssertThrowsError(try RoomCorrectionCore.scaledTaps([1, 2], headroomDB: -1))
        XCTAssertThrowsError(try RoomCorrectionCore.scaledTaps([1, 2], headroomDB: .nan))
    }
}
