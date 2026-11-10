import Foundation

/// E9 S5b: the user's per-output protection settings (`e9.output-protection`). They live in `DynamicsConfiguration`, so they
/// persist with the other Dynamics settings; the graph reads them through `UnifiedGraphOutputProtection`. The always-on hard
/// limit is not part of this: no setting here can lower or remove it.
struct OutputProtectionSettings: Equatable, Codable, Sendable {
    /// One output lane's override of the program protection settings.
    struct Lane: Equatable, Codable, Sendable {
        /// false parks the lane's user protection: its ceiling moves up to the hard ceiling (the stage keeps its look-ahead
        /// and oversampling, so every output still reports the same latency, and the change is a live parameter edit).
        var enabled = true
        /// nil follows the program ceiling. Always held between `ceilingRangeDB` and the hard ceiling.
        var ceilingDB: Double?

        init(enabled: Bool = true, ceilingDB: Double? = nil) {
            self.enabled = enabled
            self.ceilingDB = ceilingDB
        }
    }

    static let ceilingRangeDB: ClosedRange<Double> = -20 ... Double(UnifiedGraphOutputProtection.hardLimitCeilingDB)

    /// The Advanced "Independent per output" switch.
    var independent = false
    /// Overrides by output lane index (program lanes first, then sub lanes). Absent means the defaults.
    var lanes: [Int: Lane] = [:]

    init(independent: Bool = false, lanes: [Int: Lane] = [:]) {
        self.independent = independent
        self.lanes = lanes
    }

    func lane(_ index: Int) -> Lane { lanes[index] ?? Lane() }

    /// Stores `lane` for `index`; a lane equal to the defaults is dropped so equal settings compare equal.
    mutating func set(_ lane: Lane, at index: Int) {
        var value = lane
        if let ceiling = value.ceilingDB {
            value.ceilingDB = ceiling.isFinite ? min(max(ceiling, Self.ceilingRangeDB.lowerBound), Self.ceilingRangeDB.upperBound) : nil
        }
        if value == Lane() { lanes[index] = nil } else { lanes[index] = value }
    }
}

/// E9 S5c (G20): coalesces the ceiling slider's drag ticks. Each tick would otherwise publish the whole graph; the debouncer keeps
/// only the latest value and delivers it once the drag has paused for `delay`, or at once on `flush` (drag end).
@MainActor
final class OutputProtectionEditDebouncer<Value> {
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let deliver: (Value) -> Void
    private var pending: Value?
    private var task: Task<Void, Never>?

    init(
        delay: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        deliver: @escaping (Value) -> Void
    ) {
        self.delay = delay
        self.sleep = sleep
        self.deliver = deliver
    }

    /// Replaces any value still waiting and restarts the pause.
    func submit(_ value: Value) {
        pending = value
        task?.cancel()
        let wait = delay
        let sleep = self.sleep
        task = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Delivers the waiting value now, if any.
    func flush() {
        task?.cancel()
        task = nil
        guard let value = pending else { return }
        pending = nil
        deliver(value)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
