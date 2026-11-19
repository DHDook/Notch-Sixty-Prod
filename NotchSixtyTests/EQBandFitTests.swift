import Foundation
import XCTest
@testable import NotchSixty

/// E33 S21 (G40): the Swift side of "Fit bands": input preparation, refusals, band conversion, determinism.
final class EQBandFitTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func curve(
        _ kind: EQReferenceCurveKind, rate: Double, stale: Bool = false, peak: Bool = true
    ) -> EQReferenceCurve {
        var frequencies: [Double] = []
        var f = 20.0
        while f < min(rate * 0.45, 20_000) { frequencies.append(f); f *= pow(2, 1.0 / 12) }
        let gains = frequencies.map { hz -> Double in
            let x = log2(hz / 80) / 0.15
            return peak ? 8 * exp(-0.5 * x * x) : 0
        }
        return EQReferenceCurve(
            kind: kind, frequenciesHz: frequencies, gainDB: gains,
            date: Date(timeIntervalSince1970: 1_800_000_000), isOutOfDate: stale)
    }

    func testFitsKnownPeakAtEveryRate() throws {
        for rate in rates {
            let proposal = try EQBandFitter.fit(
                EQFitRequest(), curves: [curve(.measurement, rate: rate)], sampleRate: rate)
            XCTAssertFalse(proposal.bands.isEmpty, "rate \(rate)")
            XCTAssertLessThan(proposal.rmsAfterDB, 0.5 * proposal.rmsBeforeDB, "rate \(rate)")
            let cut = try XCTUnwrap(proposal.bands.first { $0.gainDB < -3 }, "rate \(rate)")
            XCTAssertEqual(cut.frequencyHz, 80, accuracy: 12, "rate \(rate)")
            XCTAssertTrue(proposal.bands.allSatisfy { $0.gainDB <= EQFitRequest().maximumBoostDB + 1e-9 })
            XCTAssertTrue(proposal.bands.allSatisfy { EQBandRules.invalidReason($0) == nil }, "rate \(rate)")
            XCTAssertEqual(proposal.predictedDB.count, proposal.frequenciesHz.count)
        }
    }

    func testSameInputGivesSameBands() throws {
        let curves = [curve(.measurement, rate: 48_000)]
        let a = try EQBandFitter.fit(EQFitRequest(), curves: curves, sampleRate: 48_000)
        let b = try EQBandFitter.fit(EQFitRequest(), curves: curves, sampleRate: 48_000)
        XCTAssertEqual(a.bands.map { [$0.frequencyHz, $0.gainDB, $0.q] }, b.bands.map { [$0.frequencyHz, $0.gainDB, $0.q] })
        XCTAssertEqual(a.predictedDB, b.predictedDB)
    }

    func testRefusesMissingAndStaleMeasurement() {
        XCTAssertThrowsError(try EQBandFitter.fit(EQFitRequest(), curves: [], sampleRate: 48_000)) {
            XCTAssertEqual($0 as? EQFitRefusal, .noMeasurement)
        }
        let stale = curve(.measurement, rate: 48_000, stale: true)
        XCTAssertThrowsError(try EQBandFitter.fit(EQFitRequest(), curves: [stale], sampleRate: 48_000)) {
            guard case .staleMeasurement? = $0 as? EQFitRefusal else { return XCTFail("\($0)") }
        }
        // A correction target alone is not a measurement.
        XCTAssertThrowsError(try EQBandFitter.fit(
            EQFitRequest(), curves: [curve(.target, rate: 48_000)], sampleRate: 48_000))
    }

    func testCorrectionTargetNeedsATarget() {
        var request = EQFitRequest()
        request.target = .correctionTarget
        XCTAssertThrowsError(try EQBandFitter.fit(request, curves: [curve(.measurement, rate: 48_000)], sampleRate: 48_000)) {
            XCTAssertEqual($0 as? EQFitRefusal, .noTarget)
        }
    }

    func testFitsTowardTheCorrectionTarget() throws {
        // Measurement is flat; the target has a 6 dB bump at 80 Hz, so the fit must boost near 80 Hz within the cap.
        var request = EQFitRequest()
        request.target = .correctionTarget
        request.maximumBoostDB = 4
        let measurement = curve(.measurement, rate: 96_000, peak: false)
        let shape = curve(.target, rate: 96_000)
        let target = EQReferenceCurve(
            kind: .target, frequenciesHz: shape.frequenciesHz, gainDB: shape.gainDB.map { $0 * 0.75 },
            date: nil, isOutOfDate: false)
        let proposal = try EQBandFitter.fit(request, curves: [measurement, target], sampleRate: 96_000)
        XCTAssertFalse(proposal.bands.isEmpty)
        XCTAssertTrue(proposal.bands.allSatisfy { $0.gainDB <= 4 + 1e-9 })
    }

    func testBoostCapZeroNeverBoosts() throws {
        var request = EQFitRequest()
        request.maximumBoostDB = 0
        let proposal = try EQBandFitter.fit(request, curves: [curve(.measurement, rate: 48_000)], sampleRate: 48_000)
        XCTAssertTrue(proposal.bands.allSatisfy { $0.gainDB < 0 })
    }

    func testProposalDoesNotTouchTheCurves() throws {
        let curves = [curve(.measurement, rate: 48_000)]
        let before = curves
        _ = try EQBandFitter.fit(EQFitRequest(), curves: curves, sampleRate: 48_000)
        XCTAssertEqual(curves, before)
    }

    func testInterpolationIsLogLinearAndHeldAtTheEnds() {
        let f = [100.0, 1_000.0], v = [0.0, 10.0]
        XCTAssertEqual(EQBandFitter.interpolate(f, v, at: 50), 0)
        XCTAssertEqual(EQBandFitter.interpolate(f, v, at: 5_000), 10)
        XCTAssertEqual(EQBandFitter.interpolate(f, v, at: sqrt(100.0 * 1_000.0)), 5, accuracy: 1e-9)
    }
}
