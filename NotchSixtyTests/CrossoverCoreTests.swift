import XCTest

@testable import NotchSixty

/// E8 S1: the Swift face of the crossover filter library. The numerical checks live in the core
/// harness (`core/tests/test_xover.cpp`); these confirm the wrapper maps specs and results faithfully.
final class CrossoverCoreTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testAbiVersionAndFlag() {
        XCTAssertEqual(CrossoverCore.abiVersion, 4)
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

    // E8 S8: the wrapper designs, merges into DRIVER_FIR content and verifies a synthetic driver at every rate.
    private func syntheticDriver() -> CrossoverCore.ResponseCapture {
        var hz: [Double] = [], db: [Double] = []
        var f = 20.0
        while f <= 20_000 {
            func peak(_ f0: Double, _ gain: Double, _ q: Double) -> Double {
                let a = pow(10, gain / 40), x = f / f0
                let num = hypot(1 - x * x, x * a / q), den = hypot(1 - x * x, x / (a * q))
                return 20 * log10(num / den)
            }
            let x = f / 90
            let rolloff = 20 * log10(x * x / hypot(1 - x * x, x / 0.9))
            hz.append(f)
            db.append(88 + rolloff + peak(1_200, 4, 1.5) + peak(6_000, 8, 3))
            f *= pow(2, 1.0 / 48)
        }
        return .init(frequenciesHz: hz, levelsDB: db)
    }

    func testDriverLinearisationAtEveryRate() throws {
        let hp = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 300)
        let lp = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 3_000)
        let capture = syntheticDriver()
        for rate in rates {
            for linear in [false, true] {
                let design = try CrossoverCore.linearise(
                    nearField: capture, highPass: hp, lowPass: lp, sampleRate: rate, linearPhase: linear)
                XCTAssertLessThan(design.rippleAfterDB, 0.5, "rate \(rate)")
                XCTAssertGreaterThan(design.rippleBeforeDB, 2)
                XCTAssertLessThanOrEqual(design.maxBoostDB, CrossoverCore.DriverLinearisation.maximumBoostDB + 1e-9)
                for (hz, c) in zip(design.gridHz, design.correctionDB) where hz < 300 {
                    XCTAssertLessThanOrEqual(c, 1e-12, "boost below the high-pass corner at \(hz)")
                }
                let fir = try CrossoverCore.linearisedDriverFIR(design, highPass: hp, lowPass: lp, sampleRate: rate)
                XCTAssertLessThan(
                    try CrossoverCore.verifyLinearisation(design, fir: fir, highPass: hp, lowPass: lp, sampleRate: rate), 0.5,
                    "rate \(rate) linear \(linear)")
                XCTAssertEqual(fir.stageKind == N60_STAGE_DRIVER_FIR_TWO_BAND.rawValue, fir.plan.twoBand)
            }
        }
    }

    func testDriverLinearisationRejectsBadInput() {
        let hp = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 300)
        XCTAssertThrowsError(try CrossoverCore.linearise(
            nearField: .init(frequenciesHz: [100, 50], levelsDB: [0, 0]), highPass: hp, lowPass: nil,
            sampleRate: 48_000, linearPhase: false))
        XCTAssertThrowsError(try CrossoverCore.linearise(
            nearField: .init(frequenciesHz: [100], levelsDB: []), highPass: hp, lowPass: nil,
            sampleRate: 48_000, linearPhase: false))
    }
}
