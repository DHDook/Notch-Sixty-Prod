import Foundation

/// E28 S5: the stages whose gain reduction the Dynamics and Meters pages draw, and the model that turns the hub's
/// maximum-since-last-take readings into bars, holds and 10 s histories. This closes G5 for gain reduction: the
/// hub is the only reader of the read-and-reset gain-reduction readbacks, so the Dynamics page, the navigator
/// rows and the Meters page all see the same peaks.
enum GainReductionSource: String, CaseIterable, Identifiable, Sendable {
    case compressor, deEsser, multibandLow, multibandMid, multibandHigh, expander, limiter

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

    /// Starts reading while at least one view needs it (the Dynamics page, a navigator row, the Meters page).
    func attach() {
        clients += 1
        guard task == nil, let hub = provideHub() else { return }
        token = hub.subscribe(hertz: 60)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.step()
                try? await Task.sleep(nanoseconds: 16_666_667)
            }
        }
    }

    func detach() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        task?.cancel()
        task = nil
        if let token, let hub = provideHub() { hub.unsubscribe(token) }
        token = nil
    }

    private func step() {
        guard let hub = provideHub(), let token else { return }
        guard hub.shouldPoll else { return }
        ingest(hub.take(token), now: clock())
    }

    /// One tick: folds the hub's maxima since the last take into the histories.
    func ingest(_ readings: [String: MeterChannelReading], now: Double) {
        for source in GainReductionSource.allCases {
            var history = histories[source] ?? GainReductionHistory()
            history.ingest(readings[source.channelID]?.peakLinear ?? 0, at: now)
            histories[source] = history
            var throttle = throttles[source] ?? MeterValueThrottle()
            spoken[source] = throttle.offer(GainReductionHistory.spoken(history.maximum), latched: false, now: now)
            throttles[source] = throttle
        }
        if now - lastTextBump >= 0.125 {
            lastTextBump = now
            textRevision &+= 1
        }
    }

    func reset() {
        histories = [:]
        throttles = [:]
        spoken = [:]
    }
}
