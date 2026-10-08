import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneCausalFIRCompilerTests: XCTestCase {
    private let compiler = QuietZoneCausalFIRCompiler()

    private func z(_ re: Double) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: re, imaginary: 0)
    }

    private func measurement(_ hz: Double) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz,
            sourceToReference: z(1),
            sourceToListener: z(0.02),
            leftSecondaryAtListener: z(1),
            rightSecondaryAtListener: z(1),
            leftLeakageAtReference: z(0.2),
            rightLeakageAtReference: z(0.2),
            measuredCoherence: 0.98
        )
    }

    private func budget(
        _ readiness: QuietZoneFeedForwardReadiness = .physicallyPlausible
    ) -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: readiness, acousticPreviewSeconds: 0.018,
            conservativePreviewSeconds: 0.016, antiNoisePathSeconds: 0.008,
            conservativeReserveSeconds: 0.007,
            geometryOnly: false, runtimeAvailable: false,
            explanation: "simulated fixture"
        )
    }

    private func input() throws -> (
        QuietZoneVirtualSeatDesign, [QuietZoneVirtualSeatBand]
    ) {
        let model = [measurement(40), measurement(70), measurement(110)]
        let design = try QuietZoneVirtualSeatDesigner()
            .design(measurements: model, budget: budget())
        return (design, model)
    }

    func testCausalShortFIRReproducesSimpleLowFrequencyModel() throws {
        let (design, model) = try input()
        let candidate = try compiler.compile(
            design: design, measurements: model,
            budget: budget(), sampleRate: 48_000,
            tapCount: 16
        )
        XCTAssertEqual(candidate.leftTaps.count, 16)
        XCTAssertEqual(candidate.rightTaps.count, 16)
        XCTAssertFalse(candidate.liveDeploymentAuthorized)
        XCTAssertLessThan(
            candidate.maximumRelativeFitError,
            QuietZoneCausalFIRCompiler.maximumRelativeFitError
        )
        XCTAssertGreaterThan(
            candidate.worstPredictedReductionDB, 0.25
        )
        XCTAssertLessThanOrEqual(
            candidate.leftTaps.reduce(0.0) { $0 + abs(Double($1)) },
            QuietZoneCausalFIRCompiler.peakGainLimit
        )
    }

    func testNeverCompileWithoutPositiveMeasuredBudget() throws {
        let (design, model) = try input()
        XCTAssertThrowsError(try compiler.compile(
            design: design, measurements: model,
            budget: budget(.nonCausal), sampleRate: 48_000
        ))
    }

    func testInvalidRateAndGridMismatchFailClosed() throws {
        let (design, model) = try input()
        XCTAssertThrowsError(try compiler.compile(
            design: design, measurements: model,
            budget: budget(), sampleRate: .nan
        ))
        XCTAssertThrowsError(try compiler.compile(
            design: design, measurements: model.dropLast().map { $0 },
            budget: budget(), sampleRate: 48_000
        ))
    }

    func testImpossibleFastPhaseFlipCannotClaimCausalFilter() throws {
        let (design, model) = try input()
        var contradictory = design
        contradictory.bands[1].leftFilter =
            ActiveQuietZoneComplex(real: 0.02, imaginary: 0)
        contradictory.bands[1].rightFilter =
            ActiveQuietZoneComplex(real: 0.02, imaginary: 0)
        XCTAssertThrowsError(try compiler.compile(
            design: contradictory, measurements: model,
            budget: budget(), sampleRate: 48_000,
            tapCount: 8
        ))
    }

    func testCompiledTapsCanBeLoadedIntoNativeDryRun() throws {
        let (design, model) = try input()
        let candidate = try compiler.compile(
            design: design, measurements: model,
            budget: budget(), sampleRate: 48_000, tapCount: 16
        )
        let fir = try XCTUnwrap(N60FeedForwardPreviewFIRCreate())
        defer { N60FeedForwardPreviewFIRDestroy(fir) }
        let valid = candidate.leftTaps.withUnsafeBufferPointer { l in
            candidate.rightTaps.withUnsafeBufferPointer { r in
                N60FeedForwardPreviewFIRConfigure(
                    fir, l.baseAddress!, r.baseAddress!,
                    UInt32(l.count)
                )
            }
        }
        XCTAssertTrue(valid)
        XCTAssertTrue(
            N60FeedForwardPreviewFIRGetSnapshot(fir).configured
        )
    }
}
