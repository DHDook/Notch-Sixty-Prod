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

    func testAnalysisBridgeDemandIsLocalSanitizedAndParkedByDefault() {
        guard let first = N60RealtimeAudioBridgeCreate(256),
              let second = N60RealtimeAudioBridgeCreate(256) else {
            XCTFail("Could not create analysis bridge fixtures")
            return
        }
        defer {
            N60RealtimeAudioBridgeDestroy(first)
            N60RealtimeAudioBridgeDestroy(second)
        }

        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(second),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )

        let unsupportedBit = UInt32(1 << 30)
        N60RealtimeAudioBridgeSetAnalysisDemand(
            first,
            UInt32(N60_ANALYSIS_DEMAND_ALL) | unsupportedBit
        )

        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_ALL)
        )
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(second),
            UInt32(N60_ANALYSIS_DEMAND_NONE),
            "Analysis demand must remain bridge-local"
        )

        let activeSnapshot = N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(first)
        XCTAssertEqual(activeSnapshot.demandMask, UInt32(N60_ANALYSIS_DEMAND_ALL))
        XCTAssertEqual(activeSnapshot.availableFrames, 0)
        XCTAssertEqual(activeSnapshot.capturedFrames, 0)
        XCTAssertEqual(activeSnapshot.droppedFrames, 0)

        var frames = [N60AnalysisFrame](
            repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
            count: 8
        )
        let readCount = frames.withUnsafeMutableBufferPointer { buffer in
            N60RealtimeAudioBridgeReadAnalysisFrames(
                first,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        XCTAssertEqual(readCount, 0, "An empty capture ring must not synthesize frames")

        N60RealtimeAudioBridgeSetAnalysisDemand(first, UInt32(N60_ANALYSIS_DEMAND_NONE))
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )
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
                inputLeft: silence,
                inputRight: silence,
                outputLeft: silence,
                outputRight: silence,
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
                inputLeft: samples,
                inputRight: samples,
                outputLeft: samples,
                outputRight: samples,
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

    func testSpectrumStereoEnergyDoesNotCancelAntiPhaseChannels() {
        let sampleRate = 96_000.0
        let analyzer = ProductionSpectrumAnalyzer()
        let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
        let left = (0..<count).map { index in
            Float(sin(2.0 * Double.pi * 1_000.0 * Double(index) / sampleRate))
        }
        let right = left.map { -$0 }

        let bands = analyzer.analyze(
            inputLeft: left,
            inputRight: right,
            outputLeft: left,
            outputRight: right,
            count: count,
            sampleRate: sampleRate
        )

        guard let strongest = bands.max(by: { $0.inputDB < $1.inputDB }) else {
            XCTFail("No anti-phase RTA bands")
            return
        }
        XCTAssertGreaterThan(
            strongest.inputDB,
            -4.0,
            "Stereo RTA must combine channel energy after the transform rather than cancel anti-phase content"
        )
        XCTAssertEqual(strongest.inputDB, strongest.outputDB, accuracy: 0.000_1)
    }
}
