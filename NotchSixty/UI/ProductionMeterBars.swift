import AppKit
import SwiftUI

// E28 S1: Canvas level bars, the display model behind them, and the production hub wiring.

/// Per-channel display state: ballistics, hold, clip latch and a throttled accessibility value.
@MainActor
final class MeterChannelDisplay {
    let id: String
    let label: String
    private(set) var ballistics = MeterBallisticsState()
    private(set) var truePeakBallistics = MeterBallisticsState()
    private(set) var hold = MeterPeakHold()
    private(set) var latch = MeterClipLatch()
    private(set) var hasTruePeak = false
    private var throttle = MeterValueThrottle()
    private(set) var accessibilityValue = "No signal"

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    var displayedDB: Double { ballistics.displayedDB }
    var heldDB: Double { hold.heldDB }
    var truePeakDB: Double { truePeakBallistics.displayedDB }
    var isClipped: Bool { latch.isLatched }

    func resetLatch() {
        latch.reset()
        hold.reset()
    }

    func ingest(
        _ reading: MeterChannelReading?,
        mode: MeterBallistics,
        elapsed: Double,
        now: Double
    ) {
        let peakDB = Self.db(reading?.peakLinear)
        let rmsDB = Self.db(reading?.rmsLinear)
        ballistics.advance(mode: mode, peakDB: peakDB, rmsDB: rmsDB, elapsed: elapsed)
        hold.advance(displayedDB: ballistics.displayedDB, elapsed: elapsed)

        var truePeak: Double?
        if let linear = reading?.truePeakLinear {
            hasTruePeak = true
            truePeak = Self.db(linear)
        }
        if hasTruePeak {
            truePeakBallistics.advance(
                mode: .peak, peakDB: truePeak ?? MeterBallisticsState.floorDB,
                rmsDB: MeterBallisticsState.floorDB, elapsed: elapsed)
        }
        latch.update(overRangeCount: reading?.overRangeSamples, truePeakDBTP: truePeak)

        let text = Self.describe(
            mode: mode, displayedDB: ballistics.displayedDB, heldDB: hold.heldDB,
            truePeakDB: hasTruePeak ? truePeakBallistics.displayedDB : nil,
            clipped: latch.isLatched)
        accessibilityValue = throttle.offer(text, latched: latch.isLatched, now: now)
    }

    static func db(_ linear: Float?) -> Double {
        guard let linear, linear.isFinite, linear > 0 else { return MeterBallisticsState.floorDB }
        return max(20.0 * log10(Double(linear)), MeterBallisticsState.floorDB)
    }

    static func describe(
        mode: MeterBallistics, displayedDB: Double, heldDB: Double, truePeakDB: Double?, clipped: Bool
    ) -> String {
        func fmt(_ value: Double) -> String {
            value <= MeterBallisticsState.floorDB + 0.05 ? "below minus 60" : String(format: "%.0f", value)
        }
        var parts = ["\(mode.title) \(fmt(displayedDB)) dBFS", "hold \(fmt(heldDB))"]
        if let truePeakDB { parts.append("true peak \(fmt(truePeakDB)) dBTP") }
        if clipped { parts.append("clipped") }
        return parts.joined(separator: ", ")
    }
}

/// The set of channel displays for one page, with a shared ballistics mode.
@MainActor
final class MeterBankDisplay {
    private(set) var channels: [String: MeterChannelDisplay] = [:]
    private var lastTick: Double?

    func channel(id: String, label: String) -> MeterChannelDisplay {
        if let existing = channels[id] { return existing }
        let created = MeterChannelDisplay(id: id, label: label)
        channels[id] = created
        return created
    }

    func ingest(_ readings: [String: MeterChannelReading], mode: MeterBallistics, now: Double) {
        let elapsed = lastTick.map { min(max(now - $0, 0), 0.25) } ?? 0
        lastTick = now
        for channel in channels.values {
            channel.ingest(readings[channel.id], mode: mode, elapsed: elapsed, now: now)
        }
    }

    func resetAllLatches() {
        for channel in channels.values { channel.resetLatch() }
    }

    func clearTick() { lastTick = nil }
}

/// A Canvas level bar with a hold tick, optional true-peak bar, scale ticks and non-colour zones.
struct MeterBarView: View {
    let channel: MeterChannelDisplay
    let paused: Bool
    let onReset: () -> Void

    private static let ticks: [(db: Double, label: String)] = [
        (-48, "-48"), (-36, "-36"), (-24, "-24"), (-12, "-12"), (-6, "-6"), (-3, "-3"), (0, "0"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            Text(channel.label)
                .font(.caption.bold())
                .frame(width: 34, alignment: .leading)
            TimelineView(.animation(paused: paused)) { _ in
                Canvas { context, size in draw(context: &context, size: size) }
            }
            .frame(height: channel.hasTruePeak ? 22 : 16)
            Button {
                onReset()
            } label: {
                Text(channel.isClipped ? "CLIP" : "OK")
                    .font(.caption2.bold().monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.primary, lineWidth: channel.isClipped ? 2 : 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Clip latch. Click to reset.")
            .accessibilityLabel("Reset clip latch for \(channel.label)")
            .accessibilityIdentifier("meter.reset.\(channel.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel.label) level")
        .accessibilityValue(channel.accessibilityValue)
        .accessibilityIdentifier("meter.\(channel.id)")
    }

    private func x(_ db: Double, width: Double) -> Double {
        let span = -MeterBallisticsState.floorDB
        return min(max((db - MeterBallisticsState.floorDB) / span, 0), 1) * width
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let barHeight = channel.hasTruePeak ? size.height * 0.5 : size.height
        let track = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.primary.opacity(0.12)))

        let fill = CGRect(x: 0, y: 0, width: x(channel.displayedDB, width: size.width), height: barHeight)
        context.fill(Path(fill), with: .color(.primary.opacity(0.6)))

        // OVER zone (above -3 dBFS): diagonal hatching, so the zone reads without colour.
        let overStart = x(-3, width: size.width)
        let over = CGRect(x: overStart, y: 0, width: size.width - overStart, height: barHeight)
        var hatchContext = context
        hatchContext.clip(to: Path(over))
        var hatch = Path()
        var hx = over.minX - barHeight
        while hx < over.maxX {
            hatch.move(to: CGPoint(x: hx, y: barHeight))
            hatch.addLine(to: CGPoint(x: hx + barHeight, y: 0))
            hx += 4
        }
        hatchContext.stroke(hatch, with: .color(.primary.opacity(0.35)), lineWidth: 0.75)

        // Scale ticks.
        for tick in Self.ticks {
            let tx = x(tick.db, width: size.width)
            var line = Path()
            line.move(to: CGPoint(x: tx, y: barHeight - 4))
            line.addLine(to: CGPoint(x: tx, y: barHeight))
            context.stroke(line, with: .color(.primary.opacity(0.7)), lineWidth: 1)
        }

        // Peak hold tick.
        let hx2 = x(channel.heldDB, width: size.width)
        context.fill(
            Path(CGRect(x: max(hx2 - 1, 0), y: 0, width: 2, height: barHeight)),
            with: .color(.primary))

        // True-peak bar.
        if channel.hasTruePeak {
            let tp = CGRect(
                x: 0, y: barHeight + 2, width: x(channel.truePeakDB, width: size.width),
                height: size.height - barHeight - 2)
            context.fill(Path(tp), with: .color(.primary.opacity(0.85)))
            let zero = x(0, width: size.width)
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: zero, y: barHeight))
            zeroLine.addLine(to: CGPoint(x: zero, y: size.height))
            context.stroke(zeroLine, with: .color(.primary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}

/// Production hub wiring: the one place that calls the engine's read-and-reset level readbacks.
struct ProductionMeterContext {
    var diagnostics: AudioDiagnosticsSnapshot
    var transport: ProductionTransportMeterSnapshot?
}

@MainActor
final class ProductionMeterWindowVisibility: MeterVisibilityProviding {
    var metersAreVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
    }
}

@MainActor
enum ProductionMeterHub {
    private static var hub: MeterReadbackHub<ProductionMeterContext>?
    private static let visibility = ProductionMeterWindowVisibility()

    static func shared(for engine: AudioIOEngine) -> MeterReadbackHub<ProductionMeterContext> {
        if let hub { return hub }
        let created = MeterReadbackHub<ProductionMeterContext>(
            visibility: visibility,
            isProcessing: { [weak engine] in engine?.lifecycleState == .running },
            source: { [weak engine] in engine.map(frame(from:)) }
        )
        hub = created
        return created
    }

    private static func frame(from engine: AudioIOEngine) -> MeterFrame<ProductionMeterContext> {
        let diagnostics = engine.diagnosticsSnapshot()
        let transport = engine.productionTransportMeterSnapshot()
        var channels: [String: MeterChannelReading] = [:]
        if let transport {
            for channel in transport.programChannels + transport.physicalOutputs {
                channels[channel.id] = MeterChannelReading(
                    peakLinear: channel.peakLinear, rmsLinear: channel.rmsLinear,
                    overRangeSamples: channel.overRangeSamples, truePeakLinear: nil)
            }
            if let input = transport.inputTruePeakLinear {
                channels["input.truePeak"] = MeterChannelReading(
                    peakLinear: input, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: input)
            }
            if let output = transport.outputTruePeakLinear {
                channels["output.truePeak"] = MeterChannelReading(
                    peakLinear: output, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: output)
            }
        } else if let kernel = diagnostics.renderKernelDiagnostics {
            func add(_ stage: String, _ meter: StereoMeterReading, truePeak: Float?) {
                channels["\(stage).L"] = MeterChannelReading(
                    peakLinear: meter.peakLeft, rmsLinear: meter.rmsLeft,
                    overRangeSamples: meter.overRangeSamples, truePeakLinear: truePeak)
                channels["\(stage).R"] = MeterChannelReading(
                    peakLinear: meter.peakRight, rmsLinear: meter.rmsRight,
                    overRangeSamples: meter.overRangeSamples, truePeakLinear: truePeak)
            }
            add("input", kernel.inputMeter, truePeak: kernel.inputTruePeakLinear)
            add("postEQ", kernel.postEQMeter, truePeak: nil)
            add("output", kernel.outputMeter, truePeak: kernel.outputTruePeakLinear)
        }
        return MeterFrame(
            channels: channels,
            context: ProductionMeterContext(diagnostics: diagnostics, transport: transport))
    }
}
