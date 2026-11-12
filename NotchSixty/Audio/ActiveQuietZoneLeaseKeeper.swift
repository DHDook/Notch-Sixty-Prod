import Foundation

/// E4 S14: control-plane half of the anti-noise dead-man lease.
///
/// While running, it renews the render path's lease every `renewInterval`. If this task, the
/// main actor or the whole process stalls, renewals stop and the render path fades the anti-noise
/// out once `leaseSeconds` pass. `stop()` releases the lease (no lease enforced). Main actor only;
/// the renew closure runs on it and must not block.
@MainActor
final class ActiveQuietZoneLeaseKeeper {
    nonisolated static let renewIntervalSeconds = 1.0
    /// Three missed renewals fit before the fade starts.
    nonisolated static let leaseSeconds = 3.0

    private let renewIntervalSeconds: Double
    private let leaseSeconds: Double
    private let renew: (Double) -> Void
    private let release: () -> Void
    /// E26 S7b2b (G20): called every `pollIntervalSeconds` while running (graph guard trips are read by polling, so the
    /// feed learns of one within a poll, not a renewal). Must not block.
    private let poll: (() -> Void)?
    private let pollIntervalSeconds: Double
    private var task: Task<Void, Never>?

    init(
        renewIntervalSeconds: Double = ActiveQuietZoneLeaseKeeper.renewIntervalSeconds,
        leaseSeconds: Double = ActiveQuietZoneLeaseKeeper.leaseSeconds,
        pollIntervalSeconds: Double = 0.05,
        poll: (() -> Void)? = nil,
        renew: @escaping (Double) -> Void,
        release: @escaping () -> Void
    ) {
        self.poll = poll
        self.pollIntervalSeconds = max(0.001, pollIntervalSeconds)
        self.renewIntervalSeconds = max(0.001, renewIntervalSeconds)
        self.leaseSeconds = max(self.renewIntervalSeconds, leaseSeconds)
        self.renew = renew
        self.release = release
    }

    var isRunning: Bool { task != nil }

    /// Starts renewing. The first renewal is immediate, so the lease exists before any anti-noise
    /// is published. Idempotent.
    func start() {
        guard task == nil else { return }
        renew(leaseSeconds)
        let interval = renewIntervalSeconds
        let step = poll == nil ? interval : min(interval, pollIntervalSeconds)
        task = Task { [weak self] in
            var sinceRenew = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.poll?()
                sinceRenew += step
                if sinceRenew >= interval - 1e-9 {
                    sinceRenew = 0
                    self.renew(self.leaseSeconds)
                }
            }
        }
    }

    /// Stops renewing and releases the lease. Idempotent.
    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        release()
    }
}
