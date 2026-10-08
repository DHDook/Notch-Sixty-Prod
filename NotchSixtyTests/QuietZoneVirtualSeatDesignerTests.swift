import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneVirtualSeatDesignerTests: XCTestCase {
    private let designer = QuietZoneVirtualSeatDesigner()

    private func z(_ x: Double, _ y: Double = 0) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: x, imaginary: y)
    }

    private func budget(
        _ state: QuietZoneFeedForwardReadiness = .physicallyPlausible
    ) -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: state,
            acousticPreviewSeconds: 0.016,
            conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.008,
            conservativeReserveSeconds: state == .physicallyPlausible ? 0.006 : -0.002,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Fixture: measured timing, no runtime"
        )
    }

    private func band(
        frequency: Double = 65,
        coherence: Double = 0.98,
        leakage: Double = 0.2
    ) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: frequency,
            sourceToReference: z(1),
            sourceToListener: z(0.02),
            leftSecondaryAtListener: z(1),
            rightSecondaryAtListener: z(1),
            leftLeakageAtReference: z(leakage),
            rightLeakageAtReference: z(leakage),
            measuredCoherence: coherence
        )
    }

    func testModelCandidateImprovesListenerYetCannotArmLiveANC() throws {
        let result = try designer.design(
            measurements: [band()],
            budget: budget()
        )
        XCTAssertTrue(result.safePreviewOnly)
        XCTAssertEqual(result.bands.count, 1)
        XCTAssertGreaterThan(result.worstModeledReductionDB, 2)
        XCTAssertLessThan(result.bands[0].predictedReferenceLeakageFraction, 0.1)
        XCTAssertLessThan(
            result.bands[0].leftFilter.magnitude,
            pow(10, ActiveQuietZoneConfiguration().maximumPerSourceTonePeakDBFS / 20)
        )
    }

    func testJointBandHeadroomLimitsSumOfOutputs() throws {
        let result = try designer.design(
            measurements: [band(frequency: 45), band(frequency: 80), band(frequency: 110)],
            budget: budget()
        )
        let leftTotal = result.bands.reduce(0.0) { $0 + $1.leftFilter.magnitude }
        let rightTotal = result.bands.reduce(0.0) { $0 + $1.rightFilter.magnitude }
        let aggregate = pow(
            10, ActiveQuietZoneConfiguration().maximumAggregateSourcePeakDBFS / 20
        )
        XCTAssertLessThanOrEqual(leftTotal, aggregate + 1.0e-10)
        XCTAssertLessThanOrEqual(rightTotal, aggregate + 1.0e-10)
    }

    func testPoorRepeatabilityAndSpeakerEchoAreRejected() {
        XCTAssertThrowsError(try designer.design(
            measurements: [band(coherence: 0.6)], budget: budget()
        )) { error in
            XCTAssertEqual(error as? QuietZoneVirtualSeatError, .insufficientCoherence)
        }
        XCTAssertThrowsError(try designer.design(
            measurements: [band(leakage: 25)], budget: budget()
        )) { error in
            XCTAssertEqual(error as? QuietZoneVirtualSeatError, .excessiveReferenceLeakage)
        }
    }

    func testNegativeCausalityMarginCannotGenerateControls() {
        XCTAssertThrowsError(try designer.design(
            measurements: [band()], budget: budget(.nonCausal)
        )) { error in
            XCTAssertEqual(error as? QuietZoneVirtualSeatError, .budgetUnavailable)
        }
    }

    func testWeakSpeakersAndNonFiniteComplexPathFailClosed() {
        var weak = band()
        weak.leftSecondaryAtListener = z(0.000001)
        weak.rightSecondaryAtListener = z(0.000001)
        XCTAssertThrowsError(try designer.design(
            measurements: [weak], budget: budget()
        ))
        var invalid = band()
        invalid.sourceToListener = z(.nan)
        XCTAssertThrowsError(try designer.design(
            measurements: [invalid], budget: budget()
        ))
    }

    func testIndependentFrequencyBandsMustNotOverlapOrLeaveLFRange() {
        XCTAssertThrowsError(try designer.design(
            measurements: [band(frequency: 45), band(frequency: 45)],
            budget: budget()
        ))
        XCTAssertThrowsError(try designer.design(
            measurements: [band(frequency: 600)],
            budget: budget()
        ))
    }
}
