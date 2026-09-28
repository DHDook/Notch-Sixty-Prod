import Foundation
import XCTest
@testable import NotchSixty

final class ProductionAnalysisTests: XCTestCase {
    func testAdaptiveFFTSizeThrough384k() {
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 44_100), 4_096)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 48_000), 4_096)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 96_000), 8_192)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 192_000), 16_384)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 384_000), 32_768)
    }

    func testPhaseCorrelationCanonicalCases() {
        let sampleCount = 4_096
        let phaseStep = 2.0 * Double.pi * 64.0 / Double(sampleCount)
        let sine = (0..<sampleCount).map { Float(sin(Double($0) * phaseStep)) }
        let inverted = sine.map { -$0 }
        let cosine = (0..<sampleCount).map { Float(cos(Double($0) * phaseStep)) }

        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: sine, count: sampleCount) ?? 0,
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: inverted, count: sampleCount) ?? 0,
            -1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: cosine, count: sampleCount) ?? 1,
            0,
            accuracy: 0.001
        )
    }

    func testPhaseCorrelationTreatsSilenceAsUndefined() {
        let silence = [Float](repeating: 0, count: 2_048)
        XCTAssertNil(ProductionAnalysisMath.phaseCorrelation(
            left: silence,
            right: silence,
            count: silence.count
        ))
    }

    func testGoniometerUsesStandardFortyFiveDegreeRotation() {
        let mono = ProductionAnalysisMath.goniometerPoint(left: 1, right: 1)
        XCTAssertEqual(mono.x, 0, accuracy: 0.000_01)
        XCTAssertEqual(mono.y, Float(2).squareRoot(), accuracy: 0.000_01)

        let side = ProductionAnalysisMath.goniometerPoint(left: 1, right: -1)
        XCTAssertEqual(side.x, Float(2).squareRoot(), accuracy: 0.000_01)
        XCTAssertEqual(side.y, 0, accuracy: 0.000_01)
    }

    func testSpectrumSilenceStaysAtFloorThrough384k() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let analyzer = ProductionSpectrumAnalyzer()
            let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
            let silence = [Float](repeating: 0, count: count)
            let bands = analyzer.analyze(
                input: silence,
                output: silence,
                count: count,
                sampleRate: sampleRate
            )

            XCTAssertEqual(bands.count, 96, "Unexpected band count at \(sampleRate) Hz")
            for band in bands {
                XCTAssertTrue(band.inputDB.isFinite)
                XCTAssertTrue(band.outputDB.isFinite)
                XCTAssertEqual(band.inputDB, ProductionAnalysisMath.spectrumFloorDB, accuracy: 0.000_1)
                XCTAssertEqual(band.outputDB, ProductionAnalysisMath.spectrumFloorDB, accuracy: 0.000_1)
            }
        }
    }

    func testFullScaleOneKilohertzSineLandsNearZeroDBFS() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let analyzer = ProductionSpectrumAnalyzer()
            let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
            let samples = (0..<count).map { index in
                Float(sin(2.0 * Double.pi * 1_000.0 * Double(index) / sampleRate))
            }
            let bands = analyzer.analyze(
                input: samples,
                output: samples,
                count: count,
                sampleRate: sampleRate
            )

            guard let strongest = bands.max(by: { $0.inputDB < $1.inputDB }) else {
                XCTFail("No RTA bands at \(sampleRate) Hz")
                continue
            }
            XCTAssertGreaterThan(strongest.inputDB, -4.0, "1 kHz too low at \(sampleRate) Hz")
            XCTAssertLessThanOrEqual(strongest.inputDB, 0.000_1)
            XCTAssertEqual(strongest.inputDB, strongest.outputDB, accuracy: 0.000_1)
            XCTAssertLessThan(abs(strongest.frequencyHz - 1_000.0), 175.0)
        }
    }
}
