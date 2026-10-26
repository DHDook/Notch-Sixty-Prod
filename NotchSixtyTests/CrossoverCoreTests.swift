import XCTest

@testable import NotchSixty

/// E8 S1: the Swift face of the crossover filter library. The numerical checks live in the core
/// harness (`core/tests/test_xover.cpp`); these confirm the wrapper maps specs and results faithfully.
final class CrossoverCoreTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testAbiVersionAndFlag() {
        XCTAssertEqual(CrossoverCore.abiVersion, 2)
        XCTAssertTrue(FeatureFlag.all.contains(.routingMatrix))
        XCTAssertEqual(FeatureFlag.routingMatrix.id, "e8.routing-matrix")
        XCTAssertFalse(FeatureFlag.routingMatrix.defaultEnabled)
    }

    func testCornerLevelsAtEveryRate() throws {
        for rate in rates {
            for (family, order, expected) in [
                (CrossoverCore.Family.butterworth, 4, -3.0103), (.bessel, 3, -3.0103), (.linkwitzRiley, 4, -6.0206),
            ] {
                for highPass in [false, true] {
                    let spec = CrossoverCore.FilterSpec(family: family, order: order, cornerHz: 1_000)
                    let cascade = try CrossoverCore.design(spec, highPass: highPass, sampleRate: rate)
                    XCTAssertEqual(try cascade.magnitudeDB(atHz: 1_000), expected, accuracy: 0.01)
                    XCTAssertLessThan(cascade.maxPoleRadius, 1)
                }
            }
        }
    }

    func testLinkwitzRileySumsFlat() throws {
        for order in CrossoverCore.Family.linkwitzRiley.orders {
            let spec = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: order, cornerHz: 300)
            let ripple = try CrossoverCore.summedRippleDB(
                lowPass: spec, highPass: spec,
                invertHighPass: CrossoverCore.linkwitzRileyInvertsHighPass(order: order), sampleRate: 96_000)
            XCTAssertLessThan(ripple, 0.001, "LR\(order)")
        }
    }

    func testSectionCountsAndSlopes() throws {
        let lr8 = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 8, cornerHz: 500)
        XCTAssertEqual(lr8.slopeDBPerOctave, 48)
        XCTAssertEqual(try CrossoverCore.design(lr8, highPass: false, sampleRate: 48_000).sections.count, 4)
        let bw1 = CrossoverCore.FilterSpec(family: .butterworth, order: 1, cornerHz: 500)
        XCTAssertEqual(try CrossoverCore.design(bw1, highPass: true, sampleRate: 48_000).sections.count, 1)
    }

    func testLinkwitzTransformMatchesAnalyticTarget() throws {
        let cascade = try CrossoverCore.linkwitzTransform(f0: 50, q0: 0.707, fp: 25, qp: 0.5, sampleRate: 48_000)
        for hz in [10.0, 20, 50, 100, 400, 1_000] {
            let w0 = 2 * Double.pi * 50, wp = 2 * Double.pi * 25, w = 2 * Double.pi * hz
            let want = 20 * log10(hypot(w0 * w0 - w * w, w * w0 / 0.707) / hypot(wp * wp - w * w, w * wp / 0.5))
            XCTAssertEqual(try cascade.magnitudeDB(atHz: hz), want, accuracy: 0.01)
        }
    }

    func testInvalidSpecsThrow() {
        let badOrder = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 3, cornerHz: 1_000)
        XCTAssertThrowsError(try CrossoverCore.design(badOrder, highPass: false, sampleRate: 48_000))
        let badCorner = CrossoverCore.FilterSpec(family: .butterworth, order: 2, cornerHz: 30_000)
        XCTAssertThrowsError(try CrossoverCore.design(badCorner, highPass: false, sampleRate: 48_000)) {
            XCTAssertEqual($0 as? CrossoverCore.CoreError, .status(Int32(N60_XOVER_ERR_CORNER)))
        }
    }
}
