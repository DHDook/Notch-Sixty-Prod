import SwiftUI

/// E28 S5: the gain-reduction bar (instant fill plus a 1 s hold tick) used on the Dynamics page, the navigator rows
/// and the Meters page. It draws in a Canvas inside a paused-when-idle TimelineView so nothing re-renders the body at
/// 60 Hz, and exposes one accessibility value that refreshes at most every 2 s.
struct GainReductionBar: View {
    let monitor: GainReductionMonitor
    let source: GainReductionSource
    var rangeDB: Double = 24
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let now = ProcessInfo.processInfo.systemUptime
            let history = monitor.history(source)
            let current = Double(history.latest)
            let held = Double(history.held(at: now))
            Canvas { gc, size in
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                gc.fill(track, with: .color(.secondary.opacity(0.18)))
                let width = size.width * min(1, current / rangeDB)
                if width > 0 {
                    gc.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: size.height / 2),
                            with: .color(.orange))
                }
                if held > 0.05 {
                    let x = size.width * min(1, held / rangeDB)
                    gc.fill(Path(CGRect(x: max(0, x - 1), y: 0, width: 2, height: size.height)), with: .color(.primary))
                }
            }
            .id(context.date)
        }
        .frame(height: compact ? 4 : 10)
        .accessibilityElement()
        .accessibilityLabel("\(source.title) gain reduction")
        .accessibilityValue(monitor.spokenValue(source))
        .accessibilityIdentifier("gain-reduction-bar-\(source.rawValue)")
    }
}

/// The last 10 s of reduction, newest at the right.
struct GainReductionHistoryView: View {
    let monitor: GainReductionMonitor
    let source: GainReductionSource
    var rangeDB: Double = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let points = monitor.history(source).points
            Canvas { gc, size in
                gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
                guard points.count > 1 else { return }
                var path = Path()
                let step = size.width / CGFloat(GainReductionHistory.capacity - 1)
                let offset = size.width - step * CGFloat(points.count - 1)
                for (i, value) in points.enumerated() {
                    let x = offset + step * CGFloat(i)
                    let y = size.height * CGFloat(min(1, Double(value) / rangeDB))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                gc.stroke(path, with: .color(.orange), lineWidth: 1.5)
            }
            .id(context.date)
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel("\(source.title) gain reduction, last 10 seconds")
        .accessibilityValue("Peak " + GainReductionHistory.spoken(monitor.history(source).maximum))
    }
}

/// The static curve with the live operating point.
struct DynamicsTransferCurveView: View {
    let monitor: GainReductionMonitor
    let source: GainReductionSource
    let curve: DynamicsTransferCurve
    var range: ClosedRange<Double> = -60...0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let live = curve.livePoint(reductionDB: Double(monitor.latest(source)))
            Canvas { gc, size in
                func map(_ input: Double, _ output: Double) -> CGPoint {
                    let x = (input - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let y = (output - range.lowerBound) / (range.upperBound - range.lowerBound)
                    return CGPoint(x: size.width * CGFloat(x), y: size.height * (1 - CGFloat(min(1, max(0, y)))))
                }
                var diagonal = Path()
                diagonal.move(to: map(range.lowerBound, range.lowerBound))
                diagonal.addLine(to: map(range.upperBound, range.upperBound))
                gc.stroke(diagonal, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var path = Path()
                for (i, p) in curve.points(over: range).enumerated() {
                    let pt = map(p.input, p.output)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                gc.stroke(path, with: .color(.accentColor), lineWidth: 2)
                if let live {
                    let pt = map(live.input, live.output)
                    gc.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(.orange))
                }
            }
            .id(context.date)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 180)
        .accessibilityElement()
        .accessibilityLabel("\(source.title) transfer curve")
        .accessibilityValue(curve.accessibilityDescription)
    }
}

/// Bar plus 10 s history plus curve for one stage; attaches the shared monitor while on screen.
struct GainReductionPanel: View {
    var engine: AudioIOEngine
    let source: GainReductionSource
    let curve: DynamicsTransferCurve?

    var body: some View {
        let monitor = GainReductionMonitor.shared(for: engine)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                GainReductionBar(monitor: monitor, source: source)
                GainReductionHistoryView(monitor: monitor, source: source)
            }
            if let curve {
                DynamicsTransferCurveView(monitor: monitor, source: source, curve: curve)
            }
        }
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }
}
