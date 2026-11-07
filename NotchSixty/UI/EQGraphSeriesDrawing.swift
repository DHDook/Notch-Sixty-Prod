import SwiftUI

/// E27 S2: draws the Phase, Group delay, Impulse and Step views of the Equalizer graph. The
/// numbers come from `EQFilterAnalysis`; this only maps them onto the canvas.
enum EQGraphSeriesDrawing {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        series: EQAnalysisSeries,
        geometry: EQGraphGeometry,
        sampleRate: Double
    ) {
        guard series.xs.count > 1, series.xs.count == series.ys.count else { return }
        let range = series.autoRange
        let span = max(range.upperBound - range.lowerBound, 1.0e-12)
        func y(_ value: Double) -> CGFloat {
            CGFloat((range.upperBound - min(max(value, range.lowerBound), range.upperBound)) / span) * size.height
        }

        // Horizontal gridlines and value labels.
        for tick in EQAxisScale.ticks(in: range) {
            let position = y(tick)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: position))
            line.addLine(to: CGPoint(x: size.width, y: position))
            let isZero = tick == 0
            context.stroke(line, with: .color(.secondary.opacity(isZero ? 0.34 : 0.14)), lineWidth: isZero ? 1.3 : 1)
            if position > 10, position < size.height - 24 {
                context.draw(
                    Text(label(tick)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                    at: CGPoint(x: 26, y: position - 7)
                )
            }
        }

        // Vertical gridlines: log frequency, or linear milliseconds.
        let x: (Double) -> CGFloat
        if series.view.isFrequencyDomain {
            x = { geometry.x(frequency: $0, width: size.width) }
            for frequency in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 40_000, 80_000, 160_000]
            where frequency <= geometry.maximumFrequency {
                let position = x(frequency)
                var line = Path()
                line.move(to: CGPoint(x: position, y: 0))
                line.addLine(to: CGPoint(x: position, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                let text = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
                context.draw(
                    Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                    at: CGPoint(x: min(max(position, 24), size.width - 24), y: size.height - 11)
                )
            }
        } else {
            let end = max(series.xs.last ?? 1, 1.0e-9)
            x = { CGFloat($0 / end) * size.width }
            for tick in EQAxisScale.ticks(in: 0...end, target: 6) where tick > 0 {
                let position = x(tick)
                var line = Path()
                line.move(to: CGPoint(x: position, y: 0))
                line.addLine(to: CGPoint(x: position, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                context.draw(
                    Text(String(format: "%g ms", tick)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                    at: CGPoint(x: min(max(position, 24), size.width - 24), y: size.height - 11)
                )
            }
        }

        var path = Path()
        for index in series.xs.indices {
            let point = CGPoint(x: x(series.xs[index]), y: y(series.ys[index]))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2.2)
        context.draw(
            Text(title(series.view)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary),
            at: CGPoint(x: size.width - 60, y: 12)
        )
    }

    private static func label(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func title(_ view: EQGraphView) -> String {
        switch view {
        case .magnitude: return "dB"
        case .phase: return "Phase (degrees)"
        case .groupDelay: return "Group delay (ms)"
        case .impulse: return "Impulse (amplitude)"
        case .step: return "Step (amplitude)"
        }
    }
}
