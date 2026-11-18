import Foundation

// E28 S1: testable cores behind the Levels meters (plain Swift, no UI, no realtime code).

/// Ballistics for a level meter. Times follow IEC 60268-18 (peak) and IEC 60268-17 (VU).
enum MeterBallistics: String, CaseIterable, Identifiable, Sendable {
    case peak
    case vu
    case rms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peak: return "Peak"
        case .vu: return "VU"
        case .rms: return "RMS"
        }
    }

    /// Peak: instant attack, 20 dB fall in 1.7 s.
    static let peakFallDBPerSecond = 20.0 / 1.7
    /// VU and RMS: integration reaches 99 % of a step in 300 ms.
    static let integrationSecondsTo99Percent = 0.3
    static var integrationTimeConstant: Double {
        integrationSecondsTo99Percent / log(100.0)
    }
}

/// One channel's displayed level, advanced by elapsed time.
struct MeterBallisticsState: Equatable, Sendable {
    static let floorDB = -60.0

    /// E33 S6: the lowest level the meter shows (-60 by default; the Scale preference picks -96 or -120).
    var floorDB = MeterBallisticsState.floorDB
    private(set) var displayedDB = MeterBallisticsState.floorDB

    mutating func reset() { displayedDB = floorDB }

    /// `peakDB` and `rmsDB` are the maximum readings since the last advance.
    mutating func advance(
        mode: MeterBallistics,
        peakDB: Double,
        rmsDB: Double,
        elapsed dt: Double
    ) {
        let dt = max(dt, 0)
        switch mode {
        case .peak:
            let fallen = displayedDB - MeterBallistics.peakFallDBPerSecond * dt
            displayedDB = max(peakDB, fallen, floorDB)
        case .vu, .rms:
            let target = Self.linear(rmsDB)
            let current = Self.linear(displayedDB)
            let alpha = 1.0 - exp(-dt / MeterBallistics.integrationTimeConstant)
            let next = current + (target - current) * alpha
            displayedDB = max(Self.decibels(next), floorDB)
        }
    }

    static func linear(_ db: Double) -> Double { pow(10.0, db / 20.0) }
    static func decibels(_ linear: Double) -> Double {
        linear > 0 ? 20.0 * log10(linear) : -.infinity
    }
}

/// Peak hold: keeps the highest displayed value for `holdSeconds`, then follows the level again.
struct MeterPeakHold: Equatable, Sendable {
    static let holdSeconds = 2.0

    /// E33 S6: the hold time; `.infinity` holds until `reset()` (the Peak hold preference).
    var holdSeconds = MeterPeakHold.holdSeconds
    var floorDB = MeterBallisticsState.floorDB
    private(set) var heldDB = MeterBallisticsState.floorDB
    private var ageSeconds = 0.0

    mutating func reset() {
        heldDB = floorDB
        ageSeconds = 0
    }

    mutating func advance(displayedDB: Double, elapsed dt: Double) {
        ageSeconds += max(dt, 0)
        if displayedDB >= heldDB {
            heldDB = displayedDB
            ageSeconds = 0
        } else if ageSeconds >= holdSeconds {
            heldDB = displayedDB
            ageSeconds = 0
        }
    }
}

/// Clip latch: sets on any new over-range sample or a true peak above 0 dBTP, and clears only on `reset()`.
struct MeterClipLatch: Equatable, Sendable {
    static let truePeakThresholdDBTP = 0.0

    private(set) var isLatched = false
    private var lastOverRangeCount: UInt64?

    mutating func reset() {
        isLatched = false
        // Keep the counter baseline so old over-range samples do not re-latch.
    }

    mutating func update(overRangeCount: UInt64?, truePeakDBTP: Double?) {
        if let overRangeCount {
            if let last = lastOverRangeCount {
                if overRangeCount > last {
                    isLatched = true
                } else if overRangeCount < last, overRangeCount > 0 {
                    // E32 R22 (design 10): a lower count is a counter reset (Stop/Start); re-baseline, and
                    // clips counted since the reset still latch.
                    isLatched = true
                }
            }
            lastOverRangeCount = overRangeCount
        }
        if let truePeakDBTP, truePeakDBTP > Self.truePeakThresholdDBTP { isLatched = true }
    }
}

/// Limits how often an accessibility value changes: at most every 2 s, or immediately on a latch.
struct MeterValueThrottle: Sendable {
    static let minimumIntervalSeconds = 2.0

    private var lastPublished: Double?
    private(set) var value = ""

    mutating func offer(_ text: String, latched: Bool, now: Double) -> String {
        if let lastPublished, !latched, now - lastPublished < Self.minimumIntervalSeconds {
            return value
        }
        if text != value || lastPublished == nil {
            value = text
            lastPublished = now
        }
        return value
    }
}

/// One channel's reading in a hub frame (linear amplitudes).
struct MeterChannelReading: Equatable, Sendable {
    var peakLinear: Float
    var rmsLinear: Float
    var overRangeSamples: UInt64?
    var truePeakLinear: Float?

    func merged(with other: MeterChannelReading) -> MeterChannelReading {
        MeterChannelReading(
            peakLinear: max(peakLinear, other.peakLinear),
            rmsLinear: max(rmsLinear, other.rmsLinear),
            overRangeSamples: other.overRangeSamples ?? overRangeSamples,
            truePeakLinear: {
                switch (truePeakLinear, other.truePeakLinear) {
                case let (a?, b?): return max(a, b)
                case let (a?, nil): return a
                case let (nil, b): return b
                }
            }()
        )
    }
}

/// Everything one hardware read returns, keyed by channel id.
struct MeterFrame<Context> {
    var channels: [String: MeterChannelReading]
    var context: Context
}

/// Visibility of the meters' window, injectable for tests.
@MainActor
protocol MeterVisibilityProviding: AnyObject {
    var metersAreVisible: Bool { get }
}

/// The only caller of the read-and-reset meter readbacks. It keeps, for each subscriber, the maximum
/// reading since that subscriber last took one, so several readers (Levels page, sidebar) see the same peaks.
@MainActor
final class MeterReadbackHub<Context> {
    typealias Token = UUID

    private struct Subscriber {
        var hertz: Double
        var pending: [String: MeterChannelReading] = [:]
    }

    private var subscribers: [Token: Subscriber] = [:]
    private let source: @MainActor () -> MeterFrame<Context>?
    private let isProcessing: @MainActor () -> Bool
    private weak var visibility: (any MeterVisibilityProviding)?
    private var pollTask: Task<Void, Never>?
    private(set) var pollCount = 0
    private(set) var latestContext: Context?

    init(
        visibility: any MeterVisibilityProviding,
        isProcessing: @escaping @MainActor () -> Bool,
        source: @escaping @MainActor () -> MeterFrame<Context>?
    ) {
        self.visibility = visibility
        self.isProcessing = isProcessing
        self.source = source
    }

    var subscriberCount: Int { subscribers.count }

    /// The poll rate: the fastest subscriber (0 with none).
    var currentHertz: Double { subscribers.values.map(\.hertz).max() ?? 0 }

    /// Whether the meters window is on screen (not hidden or occluded), whatever the audio state.
    var isWindowVisible: Bool { visibility?.metersAreVisible ?? false }

    var shouldPoll: Bool {
        !subscribers.isEmpty && (visibility?.metersAreVisible ?? false) && isProcessing()
    }

    func subscribe(hertz: Double = 60) -> Token {
        let token = Token()
        subscribers[token] = Subscriber(hertz: hertz)
        startPollingIfNeeded()
        return token
    }

    /// Changes one subscriber's rate (a monitor whose fastest client left).
    func setHertz(_ token: Token, _ hertz: Double) {
        subscribers[token]?.hertz = hertz
    }

    func unsubscribe(_ token: Token) {
        subscribers[token] = nil
        if subscribers.isEmpty { stopPolling() }
    }

    /// Returns the maximum readings since this subscriber's last take, and clears them.
    func take(_ token: Token) -> [String: MeterChannelReading] {
        guard var subscriber = subscribers[token] else { return [:] }
        let result = subscriber.pending
        subscriber.pending = [:]
        subscribers[token] = subscriber
        return result
    }

    /// One poll: reads the source once and fans the frame out. Returns false when polling is not allowed.
    @discardableResult
    func pollOnce() -> Bool {
        guard shouldPoll, let frame = source() else { return false }
        pollCount += 1
        latestContext = frame.context
        for token in subscribers.keys {
            guard var subscriber = subscribers[token] else { continue }
            for (id, reading) in frame.channels {
                if let existing = subscriber.pending[id] {
                    subscriber.pending[id] = existing.merged(with: reading)
                } else {
                    subscriber.pending[id] = reading
                }
            }
            subscribers[token] = subscriber
        }
        return true
    }

    private var pollInterval: UInt64 {
        let hertz = currentHertz > 0 ? currentHertz : 8
        return UInt64(1_000_000_000.0 / max(hertz, 1))
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollOnce()
                try? await Task.sleep(nanoseconds: self.pollInterval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// E32 S3 (R15, design 7): the one rule for how often a meter loop works. Hidden or occluded means idle whatever
/// the audio state; visible with processing stopped draws once and waits for a lifecycle change (the page's task is
/// keyed on it); visible and running polls at the page's rate.
enum MeterPollPolicy {
    enum Schedule: Equatable {
        case idle
        case once
        case every(hertz: Double)
    }

    static func hertz(for page: ProductionMetersPage) -> Double {
        switch page {
        case .levels, .stereo: return 60
        case .spectrum: return 20
        case .dynamics: return 8
        case .transport: return 4
        }
    }

    static func schedule(windowVisible: Bool, isRunning: Bool, page: ProductionMetersPage) -> Schedule {
        guard windowVisible else { return .idle }
        guard isRunning else { return .once }
        return .every(hertz: hertz(for: page))
    }
}

/// E32 S3 (R20, design 9): "dBTP" only when the detector runs at 4x at 44.1 kHz or better, that is device rate
/// times detection factor of at least 176.4 kHz (the usual BS.1770-4 practice); otherwise it is a sample-domain peak.
enum PeakLabel {
    static let minimumTruePeakRate = 176_400.0

    static func suffix(sampleRate: Double, detectionFactor: Int) -> String {
        sampleRate * Double(max(detectionFactor, 1)) >= minimumTruePeakRate - 1 ? "dBTP" : "dBFS peak"
    }
}

/// E32 S3 (R21, design 7): the analysis demand mask held as one entry per page task. A page's teardown releases
/// only its own entry, so an old task finishing after the next page's task started cannot clear the new demand.
@MainActor
final class AnalysisDemandLedger {
    private var holders: [UUID: UInt32] = [:]
    private let apply: (UInt32) -> Void

    init(apply: @escaping (UInt32) -> Void) { self.apply = apply }

    /// The union of every held mask (0 when none).
    var effective: UInt32 { holders.values.reduce(0, |) }

    /// Holds `mask` and publishes the union. Returns the token that releases it.
    func acquire(_ mask: UInt32) -> UUID {
        let token = UUID()
        holders[token] = mask
        apply(effective)
        return token
    }

    /// Drops this token's mask and publishes what is left; an unknown token changes nothing.
    func release(_ token: UUID) {
        guard holders.removeValue(forKey: token) != nil else { return }
        apply(effective)
    }
}
