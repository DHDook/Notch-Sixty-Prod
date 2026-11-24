import Foundation

// E36 S5: the control-plane switch between the process tap and the virtual driver (design notes 4, 6 and 7).
//
// Allocation: none on a realtime path; everything here runs on the main actor. Synchronisation: main actor only; the
// lease timer lives in `DriverLeaseWriter`. Latency: none added. Rates and channels: not touched (S3). Reset: `release`
// paths restore the system output, then the lease.
//
// Order that matters: switching to the driver is fade out, take the lease, take over the default output, change source,
// fade in. Switching away, and Quit, restore the default output BEFORE the lease is released, so macOS never lands on a
// vanished device. A missing, refused or unknown-version driver enters `waitingForInputDevice`; it never quietly goes
// back to the tap.

/// What the engine side does around a source change. Production closures are `DriverEngineSwitcher`'s (E36 S3b);
/// tests record the order.
struct InputSwitchHooks {
    var fadeOut: () -> Void = {}
    var applySource: (AudioInputPath) -> Void = { _ in }
    var fadeIn: () -> Void = {}
    /// E36 S3b: after `applySource`, a message when the engine could not start on the new source (nil: it did).
    var applyFailure: () -> String? = { nil }
}

@MainActor
final class DriverInputCoordinator {
    private(set) var lifecycle = AudioLifecycleStateMachine(initialState: .running)
    private(set) var path: AudioInputPath = .processTap
    private(set) var statusMessage: String?

    private let driver: DriverStatusModel
    private let output: any SystemOutputControlling
    private let store: any PreviousOutputStoring
    private let hooks: InputSwitchHooks
    private let virtualDeviceUID: String
    private let latency: DriverLatencyReporter?
    private let latencySource: () -> DriverLatencyInputs?

    /// `latency` and `latencySource` (E36 S6): the delay macOS is told about while the driver path is on. A source that
    /// returns nil (nothing known yet) writes nothing.
    init(driver: DriverStatusModel, output: any SystemOutputControlling, store: any PreviousOutputStoring,
         hooks: InputSwitchHooks = InputSwitchHooks(), virtualDeviceUID: String = N60_VD_DEVICE_UID,
         latency: DriverLatencyReporter? = nil, latencySource: @escaping () -> DriverLatencyInputs? = { nil }) {
        self.latency = latency
        self.latencySource = latencySource
        self.driver = driver
        self.output = output
        self.store = store
        self.hooks = hooks
        self.virtualDeviceUID = virtualDeviceUID
    }

    var status: DriverStatus { driver.refresh() }

    /// The switch. Returns the path now in effect (`.virtualDriver` while waiting for the driver: the choice stands).
    @discardableResult
    func switchTo(_ target: AudioInputPath) -> AudioInputPath {
        guard target != path else { return path }
        move(to: .switchingInput)
        hooks.fadeOut()
        switch target {
        case .virtualDriver: engageDriver()
        case .processTap: releaseDriver()
        }
        return path
    }

    /// Control-plane poll: a driver that vanished or went stale puts the path in `waitingForInputDevice`; one that comes
    /// back is re-engaged. Does nothing on the tap path.
    func reconcile() {
        guard path == .virtualDriver else { return }
        switch lifecycle.state {
        case .running:
            if !driver.refresh().isUsable { enterWaiting(for: driver.status) } else { publishLatency() }
        case .waitingForInputDevice:
            move(to: .switchingInput)
            engageDriver()
        default: break
        }
    }

    /// Writes the current total delay to the driver when it changed. Control plane only; called by the poll and on engage.
    func publishLatency() {
        guard path == .virtualDriver, let latency, let plugIn = driver.plugIn, let inputs = latencySource() else { return }
        latency.report(plugIn: plugIn, inputs: inputs)
    }

    /// Normal Quit: restore the output first, then release the lease at once.
    func shutdownForTermination() {
        restoreOutput()
        driver.releaseLease()
        latency?.reset()
    }

    /// First launch after a crash: gives the output back if the crashed run left the virtual device as the default.
    func recoverAfterCrash() {
        guard store.previousOutputUID != nil else { return }
        restoreOutput()
    }

    // MARK: Steps

    private func engageDriver() {
        path = .virtualDriver
        let leased = driver.acquireLease()
        guard leased.isUsable, case .inUse = leased else { enterWaiting(for: leased); return }
        let current = output.defaultOutputUID()
        if current != virtualDeviceUID {
            if store.previousOutputUID == nil { store.previousOutputUID = current }
            guard output.setDefaultOutput(uid: virtualDeviceUID) else {
                driver.releaseLease()
                enterWaiting(message: "macOS would not make the virtual device the output. Check again.")
                return
            }
        }
        hooks.applySource(.virtualDriver)
        if let failure = hooks.applyFailure() {
            // No silent fallback to the tap: wait, and `reconcile` retries.
            enterWaiting(message: "The virtual audio driver could not start: \(failure). Waiting; audio does not fall back to the default capture path.")
            return
        }
        hooks.fadeIn()
        publishLatency()
        statusMessage = nil
        move(to: .running)
    }

    private func releaseDriver() {
        restoreOutput()
        driver.releaseLease()
        latency?.reset()
        path = .processTap
        statusMessage = nil
        hooks.applySource(.processTap)
        hooks.fadeIn()
        move(to: .running)
    }

    private func restoreOutput() {
        guard let previous = store.previousOutputUID else { return }
        let current = output.defaultOutputUID()
        if current == nil || current == virtualDeviceUID {
            // A previous output that is gone stays unrestored: macOS already chose a real output.
            _ = output.setDefaultOutput(uid: previous)
        }
        store.previousOutputUID = nil
    }

    private func enterWaiting(for status: DriverStatus) {
        enterWaiting(message: AudioInputPathPresentation(status: status).headline + ". Waiting for the driver; audio does not fall back to the default capture path.")
    }

    private func enterWaiting(message: String) {
        statusMessage = message
        move(to: .waitingForInputDevice)
    }

    private func move(to state: AudioLifecycleState) {
        if lifecycle.state == state { return }
        try? lifecycle.transition(to: state)
    }
}
