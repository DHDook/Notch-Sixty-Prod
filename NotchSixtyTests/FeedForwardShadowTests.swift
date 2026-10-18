import Foundation
import XCTest
@testable import NotchSixty

/// E4 S9a: the offline feed-forward design refitted at the shadow's decimated
/// rate, and the shadow core (`N60FeedForwardShadow`) accepting it, at the
/// eight standard rates. Convergence is covered by ci/harness_e4_ff_shadow.c
/// and the reference lab (ci/acoustic_reference_lab/e4_ff_shadow_reference.py).
final class FeedForwardShadowTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let builder = QuietZoneFeedForwardShadowSeedBuilder()

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

    private func budget() -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.018,
            conservativePreviewSeconds: 0.016, antiNoisePathSeconds: 0.008,
            conservativeReserveSeconds: 0.007,
            geometryOnly: false, runtimeAvailable: false,
            explanation: "simulated fixture"
        )
    }

    private func seed(rate: Double) throws -> QuietZoneFeedForwardShadowSeed {
        let model = [measurement(40), measurement(70), measurement(110)]
        let design = try QuietZoneVirtualSeatDesigner().design(measurements: model, budget: budget())
        return try builder.build(
            design: design, measurements: model, budget: budget(),
            nativeSampleRate: rate, pathBulkDelaySeconds: 0, weightTaps: 32, pathTaps: 16
        )
    }

    func testSeedIsCompiledAtTheDecimatedRateAtEveryStandardRate() throws {
        for rate in rates {
            let s = try seed(rate: rate)
            let fd = rate / Double(N60AncDecimationFactor(rate))
            XCTAssertEqual(s.decimatedRate, fd, "\(rate) Hz")
            XCTAssertEqual(s.weights.sampleRate, fd, "\(rate) Hz")
            XCTAssertEqual(s.weights.leftTaps.count, 32)
            XCTAssertEqual(s.leftPath.taps.count, 16)
            XCTAssertEqual(s.leftPath.bulkDelay, 0)
            XCTAssertLessThan(
                s.weights.maximumRelativeFitError,
                QuietZoneCausalFIRCompiler.maximumRelativeFitError, "\(rate) Hz"
            )
            XCTAssertFalse(s.liveDeploymentAuthorized)
        }
    }

    func testPathFitReproducesADelayedPathInBand() throws {
        let frequencies = stride(from: 40.0, through: 120.0, by: 10.0).map { $0 }
        let delaySeconds = 0.004
        let measured = frequencies.map { f in
            let angle = -2 * Double.pi * f * delaySeconds
            return ActiveQuietZoneComplex(real: 0.8 * cos(angle), imaginary: 0.8 * sin(angle))
        }
        for rate in rates {
            let fd = rate / Double(N60AncDecimationFactor(rate))
            let bulk = Int((0.003 * fd).rounded(.down))
            let path = try builder.fitPath(
                measured, at: frequencies, decimatedRate: fd, bulkDelay: bulk, taps: 64
            )
            XCTAssertEqual(path.bulkDelay, bulk)
            for (f, s) in zip(frequencies, measured) {
                let fitted = QuietZoneCausalFIRCompiler()
                    .response(path.taps.map(Double.init), frequency: f, sampleRate: fd)
                let angle = -2 * Double.pi * f * Double(bulk) / fd
                let delayed = fitted * ActiveQuietZoneComplex(real: cos(angle), imaginary: sin(angle))
                let error = ActiveQuietZoneComplex(
                    real: delayed.real - s.real, imaginary: delayed.imaginary - s.imaginary
                ).magnitude / s.magnitude
                XCTAssertLessThan(error, 0.05, "\(rate) Hz at \(f) Hz")
            }
        }
    }

    func testRejectsRatesAndDelaysTheCoreCannotTake() throws {
        let model = [measurement(40), measurement(70), measurement(110)]
        let design = try QuietZoneVirtualSeatDesigner().design(measurements: model, budget: budget())
        XCTAssertThrowsError(try builder.build(
            design: design, measurements: model, budget: budget(),
            nativeSampleRate: 4_000, pathBulkDelaySeconds: 0
        )) { XCTAssertEqual($0 as? QuietZoneFeedForwardShadowSeedError, .unsupportedRate) }
        XCTAssertThrowsError(try builder.build(
            design: design, measurements: model, budget: budget(),
            nativeSampleRate: 48_000, pathBulkDelaySeconds: 0.2
        )) { XCTAssertEqual($0 as? QuietZoneFeedForwardShadowSeedError, .invalidPathDelay) }
        XCTAssertThrowsError(try builder.build(
            design: design, measurements: model, budget: budget(),
            nativeSampleRate: 48_000, pathBulkDelaySeconds: 0, pathTaps: 129
        )) { XCTAssertEqual($0 as? QuietZoneFeedForwardShadowSeedError, .invalidPathTaps) }
    }

    /// The seed loads into the core; a gap keeps the weights and a reset
    /// restores the seed.
    func testCoreTakesTheSeedAndKeepsItAcrossAGap() throws {
        for rate in rates {
            let s = try seed(rate: rate)
            var config = N60FeedForwardShadowConfigDefault(rate)
            config.taps = 32
            let shadow = try XCTUnwrap(N60FeedForwardShadowCreate(&config), "\(rate) Hz")
            defer { N60FeedForwardShadowDestroy(shadow) }
            XCTAssertTrue(N60FeedForwardShadowSetSeed(
                shadow, s.weights.leftTaps, s.weights.rightTaps, UInt32(s.weights.leftTaps.count)
            ))
            XCTAssertTrue(N60FeedForwardShadowSetPath(
                shadow, 0, UInt32(s.leftPath.bulkDelay), s.leftPath.taps, UInt32(s.leftPath.taps.count)
            ))
            XCTAssertTrue(N60FeedForwardShadowSetPath(
                shadow, 1, UInt32(s.rightPath.bulkDelay), s.rightPath.taps, UInt32(s.rightPath.taps.count)
            ))

            var generator = SystemRandomNumberGenerator()
            let frames = 512
            let buffers = Int(rate) / frames
            for _ in 0..<buffers {
                let x = (0..<frames).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
                let e = (0..<frames).map { _ in Float.random(in: -0.01...0.01, using: &generator) }
                N60FeedForwardShadowProcess(shadow, x, e, UInt32(frames))
            }
            var before = [Float](repeating: 0, count: 32)
            N60FeedForwardShadowCopyWeights(shadow, 0, &before, 32)
            N60FeedForwardShadowMarkDiscontinuity(shadow)
            let status = N60FeedForwardShadowReadStatus(shadow)
            var after = [Float](repeating: 0, count: 32)
            N60FeedForwardShadowCopyWeights(shadow, 0, &after, 32)
            XCTAssertEqual(status.gaps, 1, "\(rate) Hz")
            XCTAssertEqual(status.samplesSinceRestart, 0, "\(rate) Hz")
            XCTAssertEqual(before, after, "\(rate) Hz")
            XCTAssertTrue(after.allSatisfy(\.isFinite), "\(rate) Hz")

            N60FeedForwardShadowReset(shadow)
            N60FeedForwardShadowCopyWeights(shadow, 0, &after, 32)
            XCTAssertEqual(after, s.weights.leftTaps, "\(rate) Hz")
        }
    }
}
