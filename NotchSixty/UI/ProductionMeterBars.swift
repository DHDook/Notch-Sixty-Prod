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

    /// E33 S6: the Reset menu's named targets clear one thing each.
    func resetClipLatch() { latch.reset() }
    func resetPeakHold() { hold.reset() }

    /// E33 S6: the Scale and Peak hold preferences. Defaults keep the shipped behaviour (-60 floor, 2 s hold, no zones).
    private(set) var floorDB = MeterBallisticsState.floorDB
    private(set) var zonesEnabled = false

    func configure(floorDB: Double, holdSeconds: Double, zones: Bool) {
        let floorChanged = floorDB != self.floorDB
        self.floorDB = floorDB
        zonesEnabled = zones
        ballistics.floorDB = floorDB
        truePeakBallistics.floorDB = floorDB
        hold.floorDB = floorDB
        hold.holdSeconds = holdSeconds
        if floorChanged {
            // The resting level moves with the scale, so a quiet signal shows at once on a lower floor.
            ballistics.reset()
            truePeakBallistics.reset()
            hold.reset()
        }
    }

    var zone: MeterZone { MeterZone.zone(forDB: ballistics.displayedDB) }

    func ingest(
        _ reading: MeterChannelReading?,
        mode: MeterBallistics,
        elapsed: Double,
        now: Double
    ) {
        let peakDB = Self.db(reading?.peakLinear, floorDB: floorDB)
        let rmsDB = Self.db(reading?.rmsLinear, floorDB: floorDB)
        ballistics.advance(mode: mode, peakDB: peakDB, rmsDB: rmsDB, elapsed: elapsed)
        hold.advance(displayedDB: ballistics.displayedDB, elapsed: elapsed)

        var truePeak: Double?
        if let linear = reading?.truePeakLinear {
            hasTruePeak = true
            truePeak = Self.db(linear, floorDB: floorDB)
        }
        if hasTruePeak {
            truePeakBallistics.advance(
                mode: .peak, peakDB: truePeak ?? floorDB,
                rmsDB: floorDB, elapsed: elapsed)
        }
        latch.update(overRangeCount: reading?.overRangeSamples, truePeakDBTP: truePeak)

        let text = Self.describe(
            mode: mode, displayedDB: ballistics.displayedDB, heldDB: hold.heldDB,
            truePeakDB: hasTruePeak ? truePeakBallistics.displayedDB : nil,
            clipped: latch.isLatched, floorDB: floorDB, zone: zonesEnabled ? zone : nil)
        accessibilityValue = throttle.offer(text, latched: latch.isLatched, now: now)
    }

    static func db(_ linear: Float?, floorDB: Double = MeterBallisticsState.floorDB) -> Double {
        guard let linear, linear.isFinite, linear > 0 else { return floorDB }
        return max(20.0 * log10(Double(linear)), floorDB)
    }

    static func describe(
        mode: MeterBallistics, displayedDB: Double, heldDB: Double, truePeakDB: Double?, clipped: Bool,
        floorDB: Double = MeterBallisticsState.floorDB, zone: MeterZone? = nil
    ) -> String {
        func fmt(_ value: Double) -> String {
            value <= floorDB + 0.05 ? "below minus \(Int(-floorDB))" : String(format: "%.0f", value)
        }
        var parts = ["\(mode.title) \(fmt(displayedDB)) dBFS", "hold \(fmt(heldDB))"]
        if let zone { parts.append("\(zone.spokenName) zone") }
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
        if zonesEnabled || floorDB != MeterBallisticsState.floorDB || holdSeconds != MeterPeakHold.holdSeconds {
            created.configure(floorDB: floorDB, holdSeconds: holdSeconds, zones: zonesEnabled)
        }
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

    /// E33 S6: the Scale and Peak hold preferences, applied to every channel now and to channels made later.
    private(set) var floorDB = MeterBallisticsState.floorDB
    private(set) var holdSeconds = MeterPeakHold.holdSeconds
    private(set) var zonesEnabled = false

    func configure(floorDB: Double, holdSeconds: Double, zones: Bool) {
        self.floorDB = floorDB
        self.holdSeconds = holdSeconds
        zonesEnabled = zones
        for channel in channels.values { channel.configure(floorDB: floorDB, holdSeconds: holdSeconds, zones: zones) }
    }

    /// The Reset menu's level targets; loudness and true-peak max reset their own state in the page.
    func reset(_ target: MeterResetTarget) {
        switch target {
        case .clipLatches: for channel in channels.values { channel.resetClipLatch() }
        case .peakHold: for channel in channels.values { channel.resetPeakHold() }
        case .loudness, .truePeakMax: break
        }
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

    /// Scale ticks for a given floor: every 12 dB from 0 down, with the zone boundaries.
    static func zoneTicks(floorDB: Double) -> [Double] {
        var out = Set(MeterZone.boundariesDB)
        var db = 0.0
        while db >= floorDB { out.insert(db); db -= db > -60 ? 12 : 24 }
        return out.sorted()
    }

    var body: some View {
        HStack(spacing: DesignSpacing.s.pt) {
            Text(channel.label)
                .font(DesignType.caption.font.bold())
                .frame(width: 34, alignment: .leading)
            TimelineView(.animation(paused: paused)) { _ in
                Canvas { context, size in draw(context: &context, size: size) }
            }
            .frame(height: channel.hasTruePeak ? 22 : 16)
            if channel.zonesEnabled {
                Text(MeterReadout.peakText(channel.heldDB, floorDB: channel.floorDB))
                    .font(DesignType.caption.font.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("meter.peak.\(channel.id)")
                clipTag
            } else {
            Button {
                onReset()
            } label: {
                Text(channel.isClipped ? "CLIP" : "OK")
                    .font(DesignType.caption.font.bold().monospaced())
                    .padding(.horizontal, DesignSpacing.xs.pt)
                    .padding(.vertical, DesignSpacing.xs.pt)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignRadius.small.pt)
                            .stroke(.primary, lineWidth: channel.isClipped ? 2 : 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Clip latch. Click to reset.")
            .accessibilityLabel("Reset clip latch for \(channel.label)")
            .accessibilityIdentifier("meter.reset.\(channel.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(channel.label) level")
        .accessibilityValue(channel.accessibilityValue)
        .accessibilityIdentifier("meter.\(channel.id)")
    }

    /// E33 S6: a filled red "CLIP" tag with its own reset; nothing at all while the latch is clear (no "OK" text).
    private var clipTag: some View {
        ZStack {
            Text("CLIP").font(DesignType.caption.font.bold().monospaced()).padding(.horizontal, DesignSpacing.xs.pt)
                .hidden()
            if channel.isClipped {
                Button(action: onReset) {
                    Text("CLIP")
                        .font(DesignType.caption.font.bold().monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSpacing.xs.pt)
                        .padding(.vertical, DesignSpacing.xs.pt)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.small.pt)
                                .fill(MeterPalette.swiftUIColor(.over)))
                }
                .buttonStyle(.plain)
                .help("Clip latch. Click to reset.")
                .accessibilityLabel("Clipped. Reset clip latch for \(channel.label)")
                .accessibilityIdentifier("meter.reset.\(channel.id)")
            }
        }
    }

    private func x(_ db: Double, width: Double) -> Double {
        let floor = channel.floorDB
        return min(max((db - floor) / -floor, 0), 1) * width
    }

    /// Fills the part of the bar between two levels with the zone tint and its hatching.
    private func drawZones(context: inout GraphicsContext, width: Double, barHeight: Double, level: Double) {
        let filled = x(level, width: width)
        for zone in MeterZone.allCases {
            let lower = zone.lowerBoundDB.map { x($0, width: width) } ?? 0
            let upperDB = MeterZone(rawValue: zone.rawValue + 1)?.lowerBoundDB
            let upper = upperDB.map { x($0, width: width) } ?? width
            let end = min(upper, filled)
            guard end > lower else { continue }
            let rect = CGRect(x: lower, y: 0, width: end - lower, height: barHeight)
            context.fill(Path(rect), with: .color(MeterPalette.swiftUIColor(zone)))
            guard zone.hatchDirections > 0 else { continue }
            var clipped = context
            clipped.clip(to: Path(rect))
            var hatch = Path()
            var hx = rect.minX - barHeight
            while hx < rect.maxX {
                hatch.move(to: CGPoint(x: hx, y: barHeight)); hatch.addLine(to: CGPoint(x: hx + barHeight, y: 0))
                if zone.hatchDirections > 1 {
                    hatch.move(to: CGPoint(x: hx, y: 0)); hatch.addLine(to: CGPoint(x: hx + barHeight, y: barHeight))
                }
                hx += 4
            }
            clipped.stroke(hatch, with: .color(.black.opacity(0.55)), lineWidth: 0.75)
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let barHeight = channel.hasTruePeak ? size.height * 0.5 : size.height
        let track = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.primary.opacity(0.12)))

        if channel.zonesEnabled {
            drawZones(context: &context, width: size.width, barHeight: barHeight, level: channel.displayedDB)
        } else {
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
        }

        // Scale ticks (the zone boundaries -18, -6 and -3 are longer when zones are on).
        let ticks = channel.zonesEnabled ? Self.zoneTicks(floorDB: channel.floorDB) : Self.ticks.map(\.db)
        for db in ticks {
            let tick = (db: db, label: "")
            let tx = x(tick.db, width: size.width)
            var line = Path()
            let long = channel.zonesEnabled && MeterZone.boundariesDB.contains(tick.db)
            line.move(to: CGPoint(x: tx, y: barHeight - (long ? barHeight : 4)))
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
    /// E28 S6: per-route meters of a same-device speaker map (stereo session with several DAC channels).
    var routes: [ProductionRouteMeter] = []
    /// E28 S6: E9 per-output protection readings, keyed by lane. Empty when the flag is off.
    var protection: [UnifiedGraphOutputProtectionReading] = []
}

/// E28 S6: the channel ids the hub publishes for routes and output protection, and the pure builder the hub and the
/// matrix tests share, so a synthetic snapshot exercises exactly the production encoding.
enum MultichannelMeterChannels {
    static func routeID(_ route: ProductionRouteMeter) -> String { route.id }
    static func protectionHardID(lane: Int) -> String { "protect.\(lane).hard" }
    static func protectionUserID(lane: Int) -> String { "protect.\(lane).user" }

    /// Route and protection channels. Protection gain reduction rides `peakLinear` as positive dB (like `gr.*`), and the
    /// output true peak rides `truePeakLinear`.
    static func channels(
        routes: [ProductionRouteMeter],
        protection: [UnifiedGraphOutputProtectionReading]
    ) -> [String: MeterChannelReading] {
        var channels: [String: MeterChannelReading] = [:]
        for route in routes {
            channels[routeID(route)] = MeterChannelReading(
                peakLinear: route.peakLinear, rmsLinear: route.rmsLinear,
                overRangeSamples: route.overRangeSamples, truePeakLinear: nil)
        }
        for reading in protection {
            channels[protectionHardID(lane: reading.lane)] = MeterChannelReading(
                peakLinear: reading.hardLimitGainReductionDB, rmsLinear: 0,
                overRangeSamples: nil, truePeakLinear: reading.outputTruePeakLinear)
            if let user = reading.userGainReductionDB {
                channels[protectionUserID(lane: reading.lane)] = MeterChannelReading(
                    peakLinear: user, rmsLinear: 0, overRangeSamples: nil,
                    truePeakLinear: reading.userTruePeakLinear)
            }
        }
        return channels
    }

    /// Inverse of the protection encoding: the per-lane readings a hub `take` carries.
    static func protectionReadings(
        from taken: [String: MeterChannelReading], lanes: [Int]
    ) -> [Int: UnifiedGraphOutputProtectionReading] {
        var result: [Int: UnifiedGraphOutputProtectionReading] = [:]
        for lane in lanes {
            guard let hard = taken[protectionHardID(lane: lane)] else { continue }
            let user = taken[protectionUserID(lane: lane)]
            result[lane] = UnifiedGraphOutputProtectionReading(
                lane: lane,
                userGainReductionDB: user?.peakLinear,
                userTruePeakLinear: user?.truePeakLinear,
                hardLimitGainReductionDB: hard.peakLinear,
                outputTruePeakLinear: hard.truePeakLinear ?? 0)
        }
        return result
    }
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
    /// E33 S16 (behind `e33.page-enhancements`): the session event log and session dropout counter. The hub's poll
    /// feeds it, so it fills while any meter reader is polling, whichever page is open.
    static let eventHistory = SessionEventHistory(store: SessionEventStore(url: SessionEventStore.defaultURL()))

    static func shared(for engine: AudioIOEngine) -> MeterReadbackHub<ProductionMeterContext> {
        if let hub { return hub }
        let flags = FeatureFlags()
        // E12 S12: the Dashboard health strip reads the same samples, so it also switches the feed on.
        let eventsEnabled = flags.isEnabled(.eqPageEnhancements) || flags.isEnabled(.dashboardRemote)
        let created = MeterReadbackHub<ProductionMeterContext>(
            visibility: visibility,
            isProcessing: { [weak engine] in engine?.lifecycleState == .running },
            source: { [weak engine] in
                guard let engine else { return nil }
                let result = frame(from: engine)
                if eventsEnabled {
                    eventHistory.observe(SessionEventSample.make(
                        channels: result.channels, diagnostics: result.context.diagnostics,
                        protection: result.context.protection, now: Date()))
                }
                return result
            }
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
                    overRangeSamples: meter.overRangeLeft, truePeakLinear: truePeak)
                channels["\(stage).R"] = MeterChannelReading(
                    peakLinear: meter.peakRight, rmsLinear: meter.rmsRight,
                    overRangeSamples: meter.overRangeRight, truePeakLinear: truePeak)
            }
            add("input", kernel.inputMeter, truePeak: kernel.inputTruePeakLinear)
            add("postEQ", kernel.postEQMeter, truePeak: nil)
            add("output", kernel.outputMeter, truePeak: kernel.outputTruePeakLinear)
        }
        // E28 S5: gain-reduction maxima ride the same hub so it stays the only reader of the read-and-reset values.
        if let kernel = diagnostics.renderKernelDiagnostics {
            channels.merge(GainReductionSource.channels(from: kernel)) { _, new in new }
        }
        // E28 S6: per-route and per-output-protection readings, also read-and-reset and so read only here.
        let routes = engine.productionRouteMeters()
        let protection = engine.outputProtectionReadings()
        channels.merge(MultichannelMeterChannels.channels(routes: routes, protection: protection)) { _, new in new }
        return MeterFrame(
            channels: channels,
            context: ProductionMeterContext(
                diagnostics: diagnostics, transport: transport, routes: routes, protection: protection))
    }
}
