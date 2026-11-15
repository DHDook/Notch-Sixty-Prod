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

/// The last 10 s of reduction, newest at the right. Top edge is 0 dB (no reduction), bottom is `rangeDB`.
struct GainReductionHistoryView: View {
    let monitor: GainReductionMonitor
    let source: GainReductionSource
    var rangeDB: Double = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let history = monitor.history(source)
            let points = history.points
            ZStack(alignment: .topLeading) {
                Canvas { gc, size in
                    gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
                    for fraction in [0.25, 0.5, 0.75] {
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                        grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        gc.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                    }
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
                Text("0 dB").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 4).padding(.top, 2)
                VStack {
                    Spacer()
                    HStack {
                        Text("-\(Int(rangeDB)) dB").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("10 s").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4).padding(.bottom, 2)
                }
                if history.maximum <= 0.05 {
                    Text("No reduction").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel("\(source.title) gain reduction, last 10 seconds")
        .accessibilityValue("Peak " + GainReductionHistory.spoken(monitor.history(source).maximum))
    }
}

/// The static curve with the live operating point: input level (x) against output level (y), both in dBFS,
/// with a 12 dB grid, labelled axes and a marker at the threshold (the ceiling for a limiter).
struct DynamicsTransferCurveView: View {
    let monitor: GainReductionMonitor
    let source: GainReductionSource
    let curve: DynamicsTransferCurve
    var range: ClosedRange<Double> = -60...0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let live = curve.livePoint(reductionDB: Double(monitor.latest(source)))
            Canvas { gc, size in
                let span = range.upperBound - range.lowerBound
                func map(_ input: Double, _ output: Double) -> CGPoint {
                    let x = (input - range.lowerBound) / span
                    let y = (output - range.lowerBound) / span
                    return CGPoint(x: size.width * CGFloat(x), y: size.height * (1 - CGFloat(min(1, max(0, y)))))
                }
                let gridColor = GraphicsContext.Shading.color(.secondary.opacity(0.18))
                var level = (range.lowerBound / 12).rounded(.up) * 12
                while level <= range.upperBound {
                    var v = Path(); v.move(to: map(level, range.lowerBound)); v.addLine(to: map(level, range.upperBound))
                    var h = Path(); h.move(to: map(range.lowerBound, level)); h.addLine(to: map(range.upperBound, level))
                    gc.stroke(v, with: gridColor, lineWidth: 0.5)
                    gc.stroke(h, with: gridColor, lineWidth: 0.5)
                    if level > range.lowerBound {
                        let label = gc.resolve(Text("\(Int(level))").font(.system(size: 8)).foregroundColor(.secondary))
                        gc.draw(label, at: CGPoint(x: map(level, range.lowerBound).x - 2, y: size.height - 1), anchor: .bottomTrailing)
                    }
                    level += 12
                }
                var diagonal = Path()
                diagonal.move(to: map(range.lowerBound, range.lowerBound))
                diagonal.addLine(to: map(range.upperBound, range.upperBound))
                gc.stroke(diagonal, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if range.contains(curve.thresholdDB) {
                    var marker = Path()
                    marker.move(to: map(curve.thresholdDB, range.lowerBound))
                    marker.addLine(to: map(curve.thresholdDB, range.upperBound))
                    gc.stroke(marker, with: .color(.orange.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                }
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
                let outLabel = gc.resolve(Text("Out dBFS").font(.system(size: 9)).foregroundColor(.secondary))
                gc.draw(outLabel, at: CGPoint(x: 3, y: 2), anchor: .topLeading)
            }
            .id(context.date)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 150)
        .overlay(alignment: .bottomTrailing) {
            Text("In dBFS").font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 12)
        }
        .padding(.bottom, 12)
        .accessibilityElement()
        .accessibilityLabel("\(source.title) transfer curve")
        .accessibilityValue(curve.accessibilityDescription)
    }
}

/// Bar plus 10 s history for one stage, with an optional transfer curve at the bottom; attaches the shared monitor
/// while on screen. The curve is off by default for the limiter (its curve is a near-straight line, so the bar and
/// history say more) and on for the other stages; the choice is remembered per stage.
struct GainReductionPanel: View {
    var engine: AudioIOEngine
    let source: GainReductionSource
    let curve: DynamicsTransferCurve?

    @AppStorage private var showCurve: Bool

    init(engine: AudioIOEngine, source: GainReductionSource, curve: DynamicsTransferCurve?) {
        self.engine = engine
        self.source = source
        self.curve = curve
        let isLimiter = curve?.kind == .limiter
        _showCurve = AppStorage(wrappedValue: !isLimiter, PreferenceKeys.Dynamics.showTransferCurve(source.rawValue))
    }

    var body: some View {
        let monitor = GainReductionMonitor.shared(for: engine)
        VStack(alignment: .leading, spacing: 6) {
            GainReductionBar(monitor: monitor, source: source)
            GainReductionHistoryView(monitor: monitor, source: source)
            if let curve {
                Toggle("Show transfer curve", isOn: $showCurve)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .accessibilityIdentifier("transfer-curve-toggle-\(source.rawValue)")
                if showCurve {
                    DynamicsTransferCurveView(monitor: monitor, source: source, curve: curve,
                                              range: curve.kind == .limiter ? -24...0 : -60...0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { monitor.attach() }
        .onDisappear { monitor.detach() }
    }
}
