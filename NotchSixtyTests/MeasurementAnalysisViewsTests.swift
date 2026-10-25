import SwiftUI
import XCTest
@testable import NotchSixty

/// E11 S4: waterfall, spectrogram and gated plot. The C++ maths is covered by
/// core/tests/test_measure_waterfall.cpp; these cover the Swift seam and the views from fixed data.
final class MeasurementAnalysisViewsTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func resonance(rate: Double, tau: Double = 0.003, seconds: Double = 0.1, lead: Int = 200) -> [Float] {
        var ir = [Float](repeating: 0, count: lead + Int(seconds * rate))
        for index in lead..<ir.count {
            let t = Double(index - lead) / rate
            ir[index] = Float(exp(-t / tau) * sin(2 * Double.pi * 1_000 * t))
        }
        return ir
    }

    func testWaterfallDecaysAtAnalyticRateAtEveryRate() throws {
        for rate in Self.rates {
            let wf = try MeasurementCore.analyzeWaterfall(
                impulseResponse: resonance(rate: rate), sampleRate: rate, arrivalIndex: 200)
            XCTAssertEqual(wf.levelsDB.count, 40)
            let centre = wf.frequencyHz.indices.min { abs(log2(wf.frequencyHz[$0] / 1_000)) < abs(log2(wf.frequencyHz[$1] / 1_000)) }!
            let drop = wf.levelsDB[20][centre] - wf.levelsDB[0][centre]
            XCTAssertEqual(drop, -8.685889638 * 20 * 0.0003 / 0.003, accuracy: 0.4, "rate \(rate)")
        }
    }

    func testSpectrogramPlacesToneBurstAtEveryRate() throws {
        for rate in Self.rates {
            var ir = [Float](repeating: 0, count: Int(0.2 * rate))
            for index in Int(0.05 * rate)..<Int(0.07 * rate) { ir[index] = Float(sin(2 * Double.pi * 1_000 * Double(index) / rate)) }
            let sg = try MeasurementCore.analyzeSpectrogram(impulseResponse: ir, sampleRate: rate)
            var best = (frame: 0, bin: 0, level: -Double.infinity)
            for (f, row) in sg.levelsDB.enumerated() { for (b, v) in row.enumerated() where v > best.level { best = (f, b, v) } }
            XCTAssertEqual(sg.frameTimesSeconds[best.frame], 0.06, accuracy: 0.005 + 1e-6, "rate \(rate)")
            XCTAssertEqual(sg.binFrequenciesHz[best.bin], 1_000, accuracy: sg.binFrequenciesHz[1])
            XCTAssertEqual(best.level, 0, accuracy: 1e-9)
        }
    }

    func testInvalidInputThrows() {
        XCTAssertThrowsError(try MeasurementCore.analyzeWaterfall(impulseResponse: [0, 1], sampleRate: 48_000))
        XCTAssertThrowsError(try MeasurementCore.analyzeSpectrogram(impulseResponse: [], sampleRate: 48_000))
    }

    func testGatedPlotMarkersAndRejection() throws {
        var ir = [Float](repeating: 0, count: 2_048); ir[100] = 1; ir[400] = 0.5
        let plot = try XCTUnwrap(MeasurementGatedPlot(impulseResponse: ir, sampleRate: 48_000, directArrivalSeconds: 100.0 / 48_000))
        XCTAssertLessThan(plot.gateStartSeconds, plot.arrivalSeconds)
        XCTAssertLessThan(plot.arrivalSeconds, plot.taperStartSeconds)
        XCTAssertLessThan(plot.taperStartSeconds, plot.gateEndSeconds)
        XCTAssertEqual(plot.lowestValidFrequencyHz, 2 / 0.006, accuracy: 1e-9)
        XCTAssertEqual(plot.envelope.max(), 1)
        XCTAssertTrue((0.0...1.0).contains(plot.fraction(of: plot.gateEndSeconds)))
        XCTAssertNil(MeasurementGatedPlot(impulseResponse: ir, sampleRate: 48_000, directArrivalSeconds: 10))
        XCTAssertNil(MeasurementGatedPlot(impulseResponse: ir, sampleRate: 48_000, directArrivalSeconds: -1))
    }

    func testHeatmapRendererSizeColoursAndTransparency() throws {
        let image = try XCTUnwrap(MeasurementHeatmapRenderer.image(levelsDB: [[0, -30, -60], [-999, -10, -200]]))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 3)
        XCTAssertEqual(MeasurementHeatmapRenderer.color(levelDB: 0, rangeDB: 60).r, 255)
        XCTAssertEqual(MeasurementHeatmapRenderer.color(levelDB: -60, rangeDB: 60).g, 0)
        XCTAssertNil(MeasurementHeatmapRenderer.image(levelsDB: []))
        XCTAssertNil(MeasurementHeatmapRenderer.image(levelsDB: [[0, 1], [0]]))
    }

    func testWaterfallLayoutStaysInsideSizeAndSkipsNoData() throws {
        let wf = MeasurementCore.Waterfall(
            frequencyHz: [100, 200, 400], sliceTimesSeconds: [0, 1],
            levelsDB: [[0, -20, -40], [-999, -30, -60]])
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(MeasurementWaterfallLayout.points(waterfall: wf, slice: 0, size: size).count, 3)
        XCTAssertEqual(MeasurementWaterfallLayout.points(waterfall: wf, slice: 1, size: size).count, 2)
        for slice in 0..<2 {
            for p in MeasurementWaterfallLayout.points(waterfall: wf, slice: slice, size: size) {
                XCTAssertTrue(p.x >= 0 && p.x <= size.width && p.y >= 0 && p.y <= size.height)
            }
        }
        XCTAssertTrue(MeasurementWaterfallLayout.points(waterfall: wf, slice: 5, size: size).isEmpty)
    }

    @MainActor
    func testViewsRenderFromFixedData() throws {
        let rate = 48_000.0
        let ir = resonance(rate: rate)
        let wf = try MeasurementCore.analyzeWaterfall(impulseResponse: ir, sampleRate: rate, arrivalIndex: 200)
        let sg = try MeasurementCore.analyzeSpectrogram(impulseResponse: ir, sampleRate: rate)
        let plot = try XCTUnwrap(MeasurementGatedPlot(impulseResponse: ir, sampleRate: rate, directArrivalSeconds: 200 / rate))
        let views: [AnyView] = [
            AnyView(MeasurementWaterfallView(waterfall: wf)),
            AnyView(MeasurementSpectrogramView(spectrogram: sg)),
            AnyView(MeasurementGatedPlotView(plot: plot)),
            AnyView(MeasurementAnalysisCard(capture: nil)),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.frame(width: 400, height: 300))
            XCTAssertNotNil(renderer.cgImage)
        }
    }
}
