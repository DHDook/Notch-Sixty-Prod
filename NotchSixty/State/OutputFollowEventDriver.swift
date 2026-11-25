import Foundation

/// E15 S2: turns hardware events into engine switches for Follow macOS output (design notes 4, 9 and 11).
///
/// The decision is `OutputFollowPolicy.decide` (S1); this type owns the event wiring, the settle and wake timers and the
/// one pending event. Fixed mode never calls `start()`, so no listener is installed (note 1). It never writes the macOS
/// default. The profile half of a switch (note 5 steps a and d) is the S3 coordinator's, reached through `onOutcome`.

/// What the driver needs from the engine.
@MainActor
protocol OutputFollowEngineControlling: AnyObject {
    var selectedOutputUID: String? { get }
    func switchFollowedOutput(to uid: String, resume: Bool) throws
    /// E15 S3: also names the bound profile, so the coordinator can apply it between select and start.
    func switchFollowedOutput(to uid: String, profileID: UUID?, resume: Bool) throws
}

extension OutputFollowEngineControlling {
    func switchFollowedOutput(to uid: String, profileID: UUID?, resume: Bool) throws {
        try switchFollowedOutput(to: uid, resume: resume)
    }
}

extension AudioIOEngine: OutputFollowEngineControlling {
    var selectedOutputUID: String? { routeConfiguration.selectedOutputUID }
}

/// Cancellable one-shot timer, injected so tests control time.
protocol FollowScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken
}

final class FollowTimerToken {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

final class DispatchFollowScheduler: FollowScheduling {
    func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken {
        let item = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
        return FollowTimerToken { item.cancel() }
    }
}

enum OutputFollowOutcome: Equatable {
    case switched(OutputFollowTarget, profileID: UUID)
    case paused(OutputFollowTarget, OutputFollowPauseReason)
    case failed(OutputFollowTarget, message: String)
}

@MainActor
final class OutputFollowEventDriver {
    private let source: any FollowOutputEventSource
    private let engine: any OutputFollowEngineControlling
    private let scheduler: any FollowScheduling
    private let policy: OutputFollowPolicy
    /// Mode, bindings, profile sets and blocks; the driver fills in the device-derived fields.
    private let stateProvider: () -> OutputFollowState
    /// Called after each switch, pause or failure, so the S3 coordinator can apply the bound profile and announce it.
    var onOutcome: ((OutputFollowOutcome) -> Void)?

    private var running = false
    private var pending: (event: OutputFollowEvent, target: OutputFollowTarget)?
    private var timer: FollowTimerToken?
    private var wake: OutputFollowWake?
    private var preSleepUID: String?

    init(
        source: any FollowOutputEventSource,
        engine: any OutputFollowEngineControlling,
        scheduler: any FollowScheduling = DispatchFollowScheduler(),
        policy: OutputFollowPolicy = OutputFollowPolicy(),
        stateProvider: @escaping () -> OutputFollowState
    ) {
        self.source = source
        self.engine = engine
        self.scheduler = scheduler
        self.policy = policy
        self.stateProvider = stateProvider
    }

    var isListening: Bool { running }

    /// Installs the listeners when the effective mode is follow; removes them otherwise. Call on every mode or flag change.
    func reconcile() {
        if stateProvider().mode == .followSystem { start() } else { stop() }
    }

    func start() {
        guard !running else { return }
        source.onDefaultOutputChanged = { [weak self] target in
            MainActor.assumeIsolated { self?.defaultOutputChanged(target) }
        }
        source.onDataSourceChanged = { [weak self] target in
            MainActor.assumeIsolated { self?.dataSourceChanged(target) }
        }
        source.onDeviceListChanged = { [weak self] in
            MainActor.assumeIsolated { self?.deviceListChanged() }
        }
        source.onWillSleep = { [weak self] in MainActor.assumeIsolated { self?.preSleepUID = self?.engine.selectedOutputUID } }
        source.onDidWake = { [weak self] in MainActor.assumeIsolated { self?.didWake() } }
        do { try source.start() } catch { return }
        running = true
        source.monitorDataSource(ofDeviceUID: engine.selectedOutputUID)
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        pending = nil
        wake = nil
        source.stop()
        source.onDefaultOutputChanged = nil
        source.onDataSourceChanged = nil
        source.onDeviceListChanged = nil
        source.onWillSleep = nil
        source.onDidWake = nil
    }

    /// An excluded state (Safe Launch, acceptance, capture, failed) ended: apply the pending default (note 11).
    func resumePending() { evaluate() }

    func currentDataSourceID(forDeviceUID uid: String) -> UInt32? { source.dataSourceID(forDeviceUID: uid) }

    /// Follow was just turned on, or an excluded state ended with nothing pending: ask macOS what the default is now
    /// and treat it as settled.
    func syncToCurrentDefault() {
        guard running, pending == nil, let target = source.currentDefaultTarget() else { return }
        pending = (.defaultOutputChanged(target, receivedAt: policy.now().addingTimeInterval(-OutputFollowPolicy.settleWindow)), target)
        evaluate()
    }

    private func defaultOutputChanged(_ target: OutputFollowTarget?) {
        guard running else { return }
        guard let target else { return }
        pending = (.defaultOutputChanged(target, receivedAt: policy.now()), target)
        evaluate()
    }

    private func dataSourceChanged(_ target: OutputFollowTarget) {
        guard running else { return }
        pending = (.dataSourceChanged(target, receivedAt: policy.now()), target)
        evaluate()
    }

    private func deviceListChanged() {
        guard running, wake != nil else { return }
        // The pre-sleep device may have reappeared and macOS may have moved the default back: re-read it, then ask again.
        if let target = source.currentDefaultTarget() {
            pending = (.defaultOutputChanged(target, receivedAt: policy.now().addingTimeInterval(-OutputFollowPolicy.settleWindow)), target)
        }
        evaluate()
    }

    private func didWake() {
        guard running, let uid = preSleepUID else { return }
        preSleepUID = nil
        wake = OutputFollowWake(preSleepUID: uid, until: policy.now().addingTimeInterval(OutputFollowPolicy.wakeWindow))
        // macOS may have kept a different default across sleep, so no change event arrives: ask for it.
        guard let target = source.currentDefaultTarget() else { return }
        pending = (.defaultOutputChanged(target, receivedAt: policy.now().addingTimeInterval(-OutputFollowPolicy.settleWindow)), target)
        evaluate()
    }

    private func evaluate() {
        timer?.cancel()
        timer = nil
        guard running, let (event, target) = pending else { return }
        var state = stateProvider()
        if let uid = engine.selectedOutputUID {
            state.selectedKey = OutputKey(deviceUID: uid, dataSourceID: source.dataSourceID(forDeviceUID: uid))
        } else {
            state.selectedKey = nil
        }
        state.availableOutputUIDs = source.availableOutputUIDs()
        state.ownDeviceUIDs = state.ownDeviceUIDs.union(source.ownDeviceUIDs())
        if let wake, policy.now() >= wake.until { self.wake = nil }
        state.wake = wake

        switch policy.decide(event: event, state: state) {
        case .none:
            pending = nil
        case .defer(let deferral):
            switch deferral {
            case .settling(let until), .wakeWindow(let until):
                let delay = until.timeIntervalSince(policy.now())
                timer = scheduler.schedule(after: max(delay, 0) + 0.001) { [weak self] in self?.evaluate() }
            case .blocked:
                break // held until resumePending()
            }
        case .switchTo(let uid, _, let profileID):
            pending = nil
            perform(uid: uid, profileID: profileID, resume: true, target: target) { .switched(target, profileID: profileID) }
        case .pause(let uid, _, let reason):
            pending = nil
            perform(uid: uid, profileID: nil, resume: false, target: target) { .paused(target, reason) }
        }
    }

    private func perform(uid: String, profileID: UUID?, resume: Bool, target: OutputFollowTarget, outcome: () -> OutputFollowOutcome) {
        do {
            try engine.switchFollowedOutput(to: uid, profileID: profileID, resume: resume)
            wake = nil
            source.monitorDataSource(ofDeviceUID: uid)
            onOutcome?(outcome())
        } catch {
            onOutcome?(.failed(target, message: error.localizedDescription))
        }
    }
}
