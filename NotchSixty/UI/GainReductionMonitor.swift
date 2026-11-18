import Foundation

/// E28 S5: the stages whose gain reduction the Dynamics and Meters pages draw, and the model that turns the hub's
/// maximum-since-last-take readings into bars, holds and 10 s histories. This closes G5 for gain reduction: the
/// hub is the only reader of the read-and-reset gain-reduction readbacks, so the Dynamics page, the navigator
/// rows and the Meters page all see the same peaks.
enum GainReductionSource: String, CaseIterable, Identifiable, Sendable {
    case compressor, deEsser, multibandLow, multibandMid, multibandHigh, expander, limiter
    /// E33 S6 (G19): the fourth and fifth multiband bands of a 4 or 5 band split.
    case multibandBand4, multibandBand5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compressor: return "Compressor"
        case .deEsser: return "De-Esser"
        case .multibandLow: return "Multiband Low"
        case .multibandMid: return "Multiband Mid"
        case .multibandHigh: return "Multiband High"
        case .expander: return "Expander"
        case .limiter: return "Limiter"
        case .multibandBand4: return "Multiband Band 4"
        case .multibandBand5: return "Multiband Band 5"
        }
    }

    /// The hub channel id. The reading's `peakLinear` carries positive decibels of reduction (not a linear
    /// amplitude); the hub's per-subscriber maximum is the right merge for it.
    var channelID: String { "gr.\(rawValue)" }

    /// The reduction in dB (0 or more) in the kernel diagnostics, which also carry the graph's readbacks.
    func reductionDB(_ diagnostics: RenderKernelDiagnostics) -> Float {
        switch self {
        case .compressor: return diagnostics.compressorGainReductionDB
        case .deEsser: return diagnostics.deEsserGainReductionDB
        case .multibandLow: return diagnostics.multibandLowGainReductionDB
        case .multibandMid: return diagnostics.multibandMidGainReductionDB
        case .multibandHigh: return diagnostics.multibandHighGainReductionDB
        case .expander: return diagnostics.expanderAttenuationDB
        case .limiter: return diagnostics.limiterGainReductionDB
        case .multibandBand4: return diagnostics.multibandBand4GainReductionDB
        case .multibandBand5: return diagnostics.multibandBand5GainReductionDB
        }
    }

    static func channels(from diagnostics: RenderKernelDiagnostics) -> [String: MeterChannelReading] {
        var out: [String: MeterChannelReading] = [:]
        for source in allCases {
            out[source.channelID] = MeterChannelReading(
                peakLinear: max(0, source.reductionDB(diagnostics)), rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)
        }
        return out
    }
}

@MainActor
final class GainReductionMonitor: ObservableObject {
    /// Bumped at about 8 Hz so text readouts and accessibility values refresh without redrawing the body at 60 Hz.
    @Published private(set) var textRevision = 0
    private(set) var histories: [GainReductionSource: GainReductionHistory] = [:]
    private var throttles: [GainReductionSource: MeterValueThrottle] = [:]
    private(set) var spoken: [GainReductionSource: String] = [:]

    private var lastTextBump = -Double.infinity
    private var clients = 0
    private var task: Task<Void, Never>?
    private var token: MeterReadbackHub<ProductionMeterContext>.Token?
    private let provideHub: @MainActor () -> MeterReadbackHub<ProductionMeterContext>?
    private let clock: () -> Double

    private static var cache: GainReductionMonitor?

    static func shared(for engine: AudioIOEngine) -> GainReductionMonitor {
        if let cache { return cache }
        let monitor = GainReductionMonitor(
            hub: { [weak engine] in engine.map { ProductionMeterHub.shared(for: $0) } },
            clock: { ProcessInfo.processInfo.systemUptime })
        cache = monitor
        return monitor
    }

    init(hub: @escaping @MainActor () -> MeterReadbackHub<ProductionMeterContext>?, clock: @escaping () -> Double) {
        self.provideHub = hub
        self.clock = clock
    }

    func history(_ source: GainReductionSource) -> GainReductionHistory { histories[source] ?? GainReductionHistory() }

    func latest(_ source: GainReductionSource) -> Float { history(source).latest }

    func spokenValue(_ source: GainReductionSource) -> String { spoken[source] ?? GainReductionHistory.spoken(0) }

    /// Rate a view asks for (E32 S3, design 7): the Dynamics page bars and Meters > Dynamics 30 Hz, navigator rows 10 Hz.
    nonisolated static let pageHertz = 30.0
    nonisolated static let rowHertz = 10.0
    /// How long the loop waits between looks while the hub is not polling (hidden window or audio stopped).
    nonisolated static let idleSleepNanoseconds: UInt64 = 250_000_000

    /// True while nothing moves: every bar and hold is at rest and the 10 s history is empty, so the views may
    /// pause their timelines. It flips immediately in `ingest`, which also bumps `textRevision`.
    private(set) var isAtRest = true
    private var clientRates: [UUID: Double] = [:]
    /// E33 S6: the one Peak hold preference, applied to every history. 1 s until `e33.page-enhancements` is on.
    private(set) var holdSeconds = GainReductionHistory.holdSeconds

    var clientCount: Int { clientRates.count }

    /// Starts reading while at least one view needs it (the Dynamics page, a navigator row, the Meters page). The
    /// hub is subscribed at the fastest client's rate. Returns this client's token; `detach` releases only it.
    @discardableResult
    func attach(hertz: Double = GainReductionMonitor.pageHertz) -> UUID {
        let id = UUID()
        clientRates[id] = hertz
        if FeatureFlags().isEnabled(.eqPageEnhancements) { setHold(seconds: MeterHoldChoice.stored().seconds) }
        updateSubscription()
        if task == nil, token != nil {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let worked = self.tick()
                    let nanoseconds = worked
                        ? UInt64(1_000_000_000.0 / max(self.requestedHertz, 1))
                        : Self.idleSleepNanoseconds
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
            }
        }
        return id
    }

    func detach(_ id: UUID) {
        guard clientRates.removeValue(forKey: id) != nil else { return }
        if clientRates.isEmpty {
            task?.cancel()
            task = nil
            if let token, let hub = provideHub() { hub.unsubscribe(token) }
            token = nil
        } else {
            updateSubscription()
        }
    }

    private var requestedHertz: Double { clientRates.values.max() ?? Self.pageHertz }

    private func updateSubscription() {
        guard let hub = provideHub() else { return }
        if let token {
            hub.setHertz(token, requestedHertz)
        } else if !clientRates.isEmpty {
            token = hub.subscribe(hertz: requestedHertz)
        }
    }

    /// One loop pass. Does no work (and returns false) while the hub is not polling.
    @discardableResult
    func tick() -> Bool {
        let polling = provideHub().map { token != nil && $0.shouldPoll } ?? false
        if polling != isPolling {
            isPolling = polling
            textRevision &+= 1
        }
        guard polling, let hub = provideHub(), let token else { return false }
        ingest(hub.take(token), now: clock())
        return true
    }

    /// Whether the last loop pass found the hub polling; false while the window is hidden or audio is stopped.
    private(set) var isPolling = false

    /// The views pause their timelines while nothing moves or nothing is being read.
    var timelinesPaused: Bool { isAtRest || !isPolling }

    /// One tick: folds the hub's maxima since the last take into the histories.
    func ingest(_ readings: [String: MeterChannelReading], now: Double) {
        for source in GainReductionSource.allCases {
            var history = histories[source] ?? GainReductionHistory()
            history.holdSeconds = holdSeconds
            history.ingest(readings[source.channelID]?.peakLinear ?? 0, at: now)
            histories[source] = history
            var throttle = throttles[source] ?? MeterValueThrottle()
            spoken[source] = throttle.offer(GainReductionHistory.spoken(history.maximum), latched: false, now: now)
            throttles[source] = throttle
        }
        let atRest = GainReductionSource.allCases.allSatisfy { source in
            let history = histories[source] ?? GainReductionHistory()
            return history.maximum <= 0.05 && history.held(at: now) <= 0.05
        }
        let restChanged = atRest != isAtRest
        isAtRest = atRest
        // Text (and the telemetry chips that follow it) refresh at about 8 Hz while the hub polls; a rest change
        // is published at once so paused timelines wake without waiting for the next text tick.
        if restChanged || now - lastTextBump >= 0.125 {
            lastTextBump = now
            textRevision &+= 1
        }
    }

    /// Changes the hold time of every history (the Peak hold preference).
    func setHold(seconds: Double) {
        guard seconds != holdSeconds else { return }
        holdSeconds = seconds
        for source in histories.keys { histories[source]?.holdSeconds = seconds }
        textRevision &+= 1
    }

    /// The Reset menu's "Peak hold": clears every held tick and nothing else.
    func resetHolds() {
        for source in histories.keys { histories[source]?.resetHold() }
        textRevision &+= 1
    }

    func reset() {
        histories = [:]
        throttles = [:]
        spoken = [:]
        isAtRest = true
    }
}
