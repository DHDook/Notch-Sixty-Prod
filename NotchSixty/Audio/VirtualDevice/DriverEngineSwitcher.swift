import Foundation

// E36 S3b: the engine half of the input switch (design note 7, gap G10). The coordinator's `InputSwitchHooks` land here:
// fade out is the engine's own stop (it fades to zero and waits for the callback to report silence), the source change is the
// selection that the next session reads, and the fade in is the new session's output gate. Main actor, control plane.

/// The slice of the engine the switch needs, so tests drive it without Core Audio.
@MainActor
protocol InputSwitchEngine: AnyObject {
    var isRunningForInputSwitch: Bool { get }
    func stopForInputSwitch()
    func startForInputSwitch() throws
}

@MainActor
extension AudioIOEngine: InputSwitchEngine {
    var isRunningForInputSwitch: Bool { lifecycleState != .idle }
    func stopForInputSwitch() { stop() }
    func startForInputSwitch() throws { try start() }
}

@MainActor
final class DriverEngineSwitcher {
    private weak var engine: (any InputSwitchEngine)?
    private let selection: DriverCaptureSelection
    private let request: () -> DriverCaptureSelection.Request?
    private var wasRunning = false
    private(set) var failure: String?

    init(selection: DriverCaptureSelection = .shared, request: @escaping () -> DriverCaptureSelection.Request?) {
        self.selection = selection
        self.request = request
    }

    func attach(_ engine: any InputSwitchEngine) { self.engine = engine }

    /// The same engine as the rate-following port (E36 S6b), when it offers one.
    var rateFollowingEngine: (any RateFollowingEngine)? { engine as? any RateFollowingEngine }

    var hooks: InputSwitchHooks {
        InputSwitchHooks(
            fadeOut: { [weak self] in self?.fadeOut() },
            applySource: { [weak self] path in self?.apply(path) },
            fadeIn: {},
            applyFailure: { [weak self] in self?.failure })
    }

    private func fadeOut() {
        guard let engine else { return }
        wasRunning = engine.isRunningForInputSwitch
        if wasRunning { engine.stopForInputSwitch() }
    }

    private func apply(_ path: AudioInputPath) {
        failure = nil
        switch path {
        case .processTap: selection.set(nil)
        case .virtualDriver:
            guard let built = request() else {
                selection.set(nil)
                failure = "The virtual audio driver is not ready (no app group or driver object)."
                return
            }
            selection.set(built)
        }
        guard wasRunning, let engine else { return }
        do { try engine.startForInputSwitch() } catch {
            // No silent fallback: the engine stays stopped and the coordinator waits and retries.
            failure = error.localizedDescription
        }
    }
}
