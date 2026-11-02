import CoreGraphics
import SwiftUI

/// E11 S4: Canvas views for the waterfall (CSD), the spectrogram and the gated IR plot.
/// Rendering helpers are pure so they can run off the main thread and be tested from fixed data.

enum MeasurementHeatmapRenderer {
    /// Colour for a level re the peak: black at `-rangeDB` rising through blue and orange to white at 0.
    static func color(levelDB: Double, rangeDB: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let t = min(1, max(0, 1 + levelDB / rangeDB))
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0, 0, 0)), (0.35, (20, 40, 140)), (0.65, (210, 80, 40)), (0.9, (255, 210, 90)), (1, (255, 255, 255))]
        for index in 1..<stops.count where t <= stops[index].0 {
            let (t0, c0) = stops[index - 1], (t1, c1) = stops[index]
            let u = (t - t0) / (t1 - t0)
            func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8((a + (b - a) * u).rounded()) }
            return (mix(c0.0, c1.0), mix(c0.1, c1.1), mix(c0.2, c1.2))
        }
        return (255, 255, 255)
    }

    /// `levelsDB[column][row]`: columns run left to right (time), rows bottom to top (frequency).
    /// Cells at `noDataDB` are transparent. Safe to call from any thread.
    static func image(levelsDB: [[Double]], rangeDB: Double = 60) -> CGImage? {
        guard let width = Optional(levelsDB.count), width > 0, let height = levelsDB.first?.count, height > 0,
              levelsDB.allSatisfy({ $0.count == height }) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0..<width {
            for row in 0..<height {
                let level = levelsDB[x][row]
                guard level > MeasurementCore.Waterfall.noDataDB else { continue }
                let c = color(levelDB: level, rangeDB: rangeDB)
                let offset = ((height - 1 - row) * width + x) * 4
                pixels[offset] = c.r; pixels[offset + 1] = c.g; pixels[offset + 2] = c.b; pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum MeasurementWaterfallLayout {
    /// Polyline of one slice: x on the log frequency grid across `size.width`, y from the baseline of
    /// that slice (later slices sit higher and further right) up by `level / rangeDB` of the plot height.
    static func points(
        waterfall: MeasurementCore.Waterfall, slice: Int, size: CGSize, rangeDB: Double = 60, skew: CGFloat = 0.25
    ) -> [CGPoint] {
        guard waterfall.levelsDB.indices.contains(slice), waterfall.frequencyHz.count > 1 else { return [] }
        let count = waterfall.levelsDB[slice].count
        let slices = max(1, waterfall.levelsDB.count - 1)
        let depth = CGFloat(slice) / CGFloat(slices)
        let plotWidth = size.width * (1 - skew), plotHeight = size.height * 0.7
        let originX = size.width * skew * depth, baseY = size.height - size.height * 0.3 * depth
        return (0..<count).compactMap { index in
            let level = waterfall.levelsDB[slice][index]
            guard level > MeasurementCore.Waterfall.noDataDB else { return nil }
            let x = originX + plotWidth * CGFloat(index) / CGFloat(max(1, count - 1))
            let up = CGFloat(min(1, max(0, 1 + level / rangeDB)))
            return CGPoint(x: x, y: baseY - plotHeight * up)
        }
    }
}

struct MeasurementWaterfallView: View {
    let waterfall: MeasurementCore.Waterfall

    var body: some View {
        Canvas { context, size in
            let slices = waterfall.levelsDB.count
            for slice in stride(from: slices - 1, through: 0, by: -1) {
                let pts = MeasurementWaterfallLayout.points(waterfall: waterfall, slice: slice, size: size)
                guard let first = pts.first else { continue }
                var line = Path()
                line.move(to: first)
                pts.dropFirst().forEach { line.addLine(to: $0) }
                var fill = line
                if let last = pts.last {
                    let base = size.height - size.height * 0.3 * CGFloat(slice) / CGFloat(max(1, slices - 1))
                    fill.addLine(to: CGPoint(x: last.x, y: base))
                    fill.addLine(to: CGPoint(x: first.x, y: base))
                    fill.closeSubpath()
                }
                context.fill(fill, with: .color(Color(white: 0.1, opacity: 0.85)))
                context.stroke(line, with: .color(.accentColor.opacity(0.35 + 0.65 * (1 - Double(slice) / Double(max(1, slices))))), lineWidth: 1)
            }
        }
        .frame(minHeight: 220)
        .accessibilityLabel("Waterfall, \(waterfall.levelsDB.count) slices")
    }
}

struct MeasurementSpectrogramView: View {
    let spectrogram: MeasurementCore.Spectrogram
    @State private var image: CGImage?

    var body: some View {
        Canvas { context, size in
            guard let image else { return }
            context.draw(Image(decorative: image, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: size))
        }
        .frame(minHeight: 200)
        .background(Color.black)
        .accessibilityLabel("Spectrogram, \(spectrogram.frameTimesSeconds.count) frames")
        .task(id: spectrogram) {
            let levels = spectrogram.levelsDB
            image = await Task.detached(priority: .userInitiated) {
                MeasurementHeatmapRenderer.image(levelsDB: levels)
            }.value
        }
    }
}

/// The impulse response with the gate: open, direct arrival, taper start and close, and the lowest valid frequency.
struct MeasurementGatedPlotView: View {
    let plot: MeasurementGatedPlot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                var line = Path()
                let n = plot.envelope.count
                for (index, value) in plot.envelope.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(1, n - 1))
                    let y = size.height * (1 - 0.9 * CGFloat(value)) - 2
                    index == 0 ? line.move(to: CGPoint(x: x, y: size.height)) : line.addLine(to: CGPoint(x: x, y: y))
                    if index == n - 1 { line.addLine(to: CGPoint(x: x, y: size.height)) }
                }
                context.stroke(line, with: .color(.secondary), lineWidth: 1)
                func marker(_ seconds: Double, _ color: Color, dashed: Bool = false) {
                    let x = size.width * plot.fraction(of: seconds)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
                }
                marker(plot.gateStartSeconds, .green)
                marker(plot.arrivalSeconds, .blue, dashed: true)
                marker(plot.taperStartSeconds, .orange, dashed: true)
                marker(plot.gateEndSeconds, .red)
            }
            .frame(height: 140)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    var summary: String {
        String(
            format: "Gate %.1f ms after the arrival. Valid from %.0f Hz (1 / gate = %.0f Hz). Below that the response is not resolved.",
            plot.gateLengthSeconds * 1000, plot.lowestValidFrequencyHz, plot.oneOverGateHz)
    }
}

/// Gated response, waterfall and spectrogram for the Analysis tab's selected source.
struct MeasurementAnalysisCard: View {
    let source: MeasurementAnalysisSource?

    @State private var gated: MeasurementGatedPlot?
    @State private var waterfall: MeasurementCore.Waterfall?
    @State private var spectrogram: MeasurementCore.Spectrogram?

    var body: some View {
        GroupBox("Gated response, waterfall and spectrogram") {
            if source == nil {
                Text("Pick a source to see its gated impulse response, waterfall and spectrogram.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let gated { Text("Impulse response and gate").font(.headline); MeasurementGatedPlotView(plot: gated) }
                    if let waterfall { Text("Waterfall").font(.headline); MeasurementWaterfallView(waterfall: waterfall) }
                    if let spectrogram { Text("Spectrogram").font(.headline); MeasurementSpectrogramView(spectrogram: spectrogram) }
                }
            }
        }
        .task(id: source?.id) {
            guard let source else { gated = nil; waterfall = nil; spectrogram = nil; return }
            let ir = source.impulseResponse, rate = source.sampleRate
            let arrival = source.arrivalSeconds
            let result = await Task.detached(priority: .userInitiated) {
                (
                    arrival.flatMap { MeasurementGatedPlot(impulseResponse: ir, sampleRate: rate, directArrivalSeconds: $0) },
                    try? MeasurementCore.analyzeWaterfall(
                        impulseResponse: ir, sampleRate: rate, arrivalIndex: arrival.map { Int(($0 * rate).rounded()) }),
                    try? MeasurementCore.analyzeSpectrogram(impulseResponse: ir, sampleRate: rate))
            }.value
            gated = result.0; waterfall = result.1; spectrogram = result.2
        }
    }
}
