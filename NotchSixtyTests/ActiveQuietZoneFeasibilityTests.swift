import Foundation
import XCTest
@testable import NotchSixty

final class ActiveQuietZoneFeasibilityTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let actuator: MultichannelCalibrationSource = .subwoofer(0)

    func testStrongReferenceLeadSupportsFullConservativeBand() throws {
        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "front-window",
                    errorID: "seat-center",
                    leadFrames: 420,
                    coherence: [0.96, 0.95, 0.94, 0.93, 0.92]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "seat-center",
                    arrivalFrames: 110,
                    headroomDB: 9
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(report.status, .feasible)
        XCTAssertEqual(report.recommendedMaximumHz, 150, accuracy: 0.5)
        XCTAssertEqual(report.errorMicrophones.count, 1)
        XCTAssertTrue(report.errorMicrophones[0].covered)
        XCTAssertGreaterThan(
            report.minimumCausalityMarginFrames ?? 0,
            200
        )
        XCTAssertGreaterThan(
            report.minimumCoherenceFloor ?? 0,
            0.90
        )
        XCTAssertGreaterThanOrEqual(
            report.minimumActuatorHeadroomDB ?? 0,
            9
        )
    }

    func testInsufficientReferenceLeadIsCausallyInfeasible() throws {
        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "late-reference",
                    errorID: "seat-center",
                    leadFrames: 150,
                    coherence: [0.95, 0.95, 0.95, 0.95, 0.95]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "seat-center",
                    arrivalFrames: 100,
                    headroomDB: 10
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(report.status, .infeasible)
        XCTAssertEqual(report.recommendedMaximumHz, 0)
        XCTAssertEqual(
            report.pairResults.first?.failure,
            .insufficientReferenceLead
        )
        XCTAssertLessThan(
            report.pairResults.first?.causalityMarginFrames ?? 0,
            0
        )
    }

    func testLargeQuietZoneNarrowsBandByQuarterWavelength() throws {
        var configuration = ActiveQuietZoneFeasibilityConfiguration.conservative
        configuration.quietZoneRadiusMeters = 1.0

        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "reference",
                    errorID: "zone",
                    leadFrames: 500,
                    coherence: [0.97, 0.97, 0.97, 0.97, 0.97]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "zone",
                    arrivalFrames: 100,
                    headroomDB: 10
                ),
            ],
            sampleRate: sampleRate,
            configuration: configuration
        )

        XCTAssertEqual(report.status, .marginal)
        XCTAssertEqual(
            report.spatialQuarterWavelengthMaximumHz,
            85.75,
            accuracy: 0.2
        )
        XCTAssertEqual(
            report.recommendedMaximumHz,
            85.75,
            accuracy: 1.5
        )
        XCTAssertTrue(report.reasons.contains {
            $0.localizedCaseInsensitiveContains("radius")
        })
    }

    func testTimingJitterCanNarrowOtherwiseCausalBand() throws {
        var configuration = ActiveQuietZoneFeasibilityConfiguration.conservative
        configuration.timingJitterFrames = 30

        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "reference",
                    errorID: "zone",
                    leadFrames: 500,
                    coherence: [0.97, 0.97, 0.97, 0.97, 0.97]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "zone",
                    arrivalFrames: 100,
                    headroomDB: 10
                ),
            ],
            sampleRate: sampleRate,
            configuration: configuration
        )

        XCTAssertEqual(report.status, .marginal)
        XCTAssertEqual(
            report.timingUncertaintyMaximumHz,
            88.888_888,
            accuracy: 0.1
        )
        XCTAssertEqual(
            report.recommendedMaximumHz,
            report.timingUncertaintyMaximumHz,
            accuracy: 1.5
        )
        XCTAssertTrue(report.reasons.contains {
            $0.localizedCaseInsensitiveContains("timing")
        })
    }

    func testCoherenceRolloffProducesMeasuredBandCeiling() throws {
        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "reference",
                    errorID: "zone",
                    leadFrames: 500,
                    coherence: [0.96, 0.94, 0.90, 0.76, 0.55]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "zone",
                    arrivalFrames: 100,
                    headroomDB: 10
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(report.status, .marginal)
        XCTAssertGreaterThan(report.recommendedMaximumHz, 80)
        XCTAssertLessThan(report.recommendedMaximumHz, 120)
        XCTAssertTrue(report.reasons.contains {
            $0.localizedCaseInsensitiveContains("coherence")
        })
    }

    func testEveryErrorMicrophoneRequiresQualifiedCoverage() throws {
        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "reference-a",
                    errorID: "seat-a",
                    leadFrames: 500,
                    coherence: [0.95, 0.95, 0.95, 0.95, 0.95]
                ),
                observation(
                    referenceID: "reference-b",
                    errorID: "seat-b",
                    leadFrames: 500,
                    coherence: [0.95, 0.95, 0.95, 0.95, 0.95]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "seat-a",
                    arrivalFrames: 100,
                    headroomDB: 9
                ),
                secondary(
                    errorID: "seat-b",
                    arrivalFrames: 100,
                    headroomDB: 3
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(report.status, .infeasible)
        XCTAssertEqual(report.recommendedMaximumHz, 0)
        XCTAssertEqual(
            report.errorMicrophones.first {
                $0.errorMicrophoneID == "seat-b"
            }?.covered,
            false
        )
        XCTAssertTrue(report.pairResults.contains {
            $0.errorMicrophoneID == "seat-b"
                && $0.failure == .insufficientActuatorHeadroom
        })
    }

    func testBestReferenceActuatorPairIsSelectedPerErrorMicrophone() throws {
        let report = try ActiveQuietZoneFeasibilityAnalyzer().analyze(
            referenceObservations: [
                observation(
                    referenceID: "weak",
                    errorID: "seat",
                    leadFrames: 240,
                    coherence: [0.86, 0.84, 0.82, 0.78, 0.70]
                ),
                observation(
                    referenceID: "strong",
                    errorID: "seat",
                    leadFrames: 480,
                    coherence: [0.97, 0.96, 0.95, 0.94, 0.93]
                ),
            ],
            secondaryPaths: [
                secondary(
                    errorID: "seat",
                    arrivalFrames: 110,
                    headroomDB: 9
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(
            report.errorMicrophones.first?.bestPair?.referenceID,
            "strong"
        )
        XCTAssertEqual(report.recommendedMaximumHz, 150, accuracy: 0.5)
    }

    func testInvalidCoherenceDataFailsClosed() throws {
        let invalid = ActiveQuietZoneReferenceObservation(
            referenceID: "bad",
            errorMicrophoneID: "seat",
            referenceLeadFrames: 300,
            frequenciesHz: [20, 100, 80],
            magnitudeSquaredCoherence: [0.9, 0.9, 0.9]
        )

        XCTAssertThrowsError(
            try ActiveQuietZoneFeasibilityAnalyzer().analyze(
                referenceObservations: [invalid],
                secondaryPaths: [
                    secondary(
                        errorID: "seat",
                        arrivalFrames: 100,
                        headroomDB: 9
                    ),
                ],
                sampleRate: sampleRate
            )
        )
    }

    private func observation(
        referenceID: String,
        errorID: String,
        leadFrames: Double,
        coherence: [Double]
    ) -> ActiveQuietZoneReferenceObservation {
        ActiveQuietZoneReferenceObservation(
            referenceID: referenceID,
            errorMicrophoneID: errorID,
            referenceLeadFrames: leadFrames,
            frequenciesHz: [20, 50, 80, 120, 150],
            magnitudeSquaredCoherence: coherence
        )
    }

    private func secondary(
        errorID: String,
        arrivalFrames: Double,
        headroomDB: Double
    ) -> ActiveQuietZoneSecondaryPath {
        ActiveQuietZoneSecondaryPath(
            actuator: actuator,
            errorMicrophoneID: errorID,
            commandToErrorArrivalFrames: arrivalFrames,
            reservedHeadroomDB: headroomDB
        )
    }
}
