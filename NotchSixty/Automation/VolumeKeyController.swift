import Combine
import Foundation

// E16 S2: owns the listen-only media-key monitor that `AudioIOEngine` used to hold. Same rules as before (software volume
// only, no key suppression, no Accessibility permission). Behind `e16.automation` it also acts on the mute key, takes
// Option-Shift quarter steps and shows our own level indicator; with the flag off only volume up and down act, as today.

/// What the controller needs from the engine, so tests drive it with a fake.
@MainActor
protocol VolumeKeyTarget: AnyObject {
    var softwareVolumeKeyStep: MasterVolumeKeyStep { get }
    var masterVolumeConfiguration: MasterVolumeConfiguration { get }
    var isSoftwareVolumeActive: Bool { get }
    var onVolumeKeyRouteChange: ((Bool) -> Void)? { get set }
    func applySoftwareVolumeKey(level: Double)
}

extension AudioIOEngine: VolumeKeyTarget {
    var isSoftwareVolumeActive: Bool {
        selectedOutputDevice != nil && masterVolumeCapabilities.controlMode == .softwareDSP
    }
}

@MainActor
final class VolumeKeyController: ObservableObject {
    @Published private(set) var monitoringState: GlobalVolumeKeyMonitoringState = .stopped

    private let monitor: any GlobalVolumeKeyMonitoring
    private let target: VolumeKeyTarget
    private let perform: @MainActor (ControlCommand) async -> Void
    private let isEnabled: @MainActor () -> Bool
    /// Called after a key changed the software volume while the flag is on (the level indicator).
    var onLevelChanged: (() -> Void)?

    init(
        target: VolumeKeyTarget,
        monitor: any GlobalVolumeKeyMonitoring = CoreGraphicsGlobalVolumeKeyMonitor(),
        perform: @escaping @MainActor (ControlCommand) async -> Void,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.target = target
        self.monitor = monitor
        self.perform = perform
        self.isEnabled = isEnabled
        monitor.onKey = { [weak self] action, fine in
            MainActor.assumeIsolated { self?.handle(action, fine: fine) }
        }
        target.onVolumeKeyRouteChange = { [weak self] active in
            MainActor.assumeIsolated { self?.routeChanged(active: active) }
        }
        routeChanged(active: target.isSoftwareVolumeActive)
    }

    /// Starts the monitor only for software volume on a selected output; stops it otherwise.
    func routeChanged(active: Bool) {
        monitor.stop()
        monitoringState = .stopped
        guard active else { return }
        do {
            try monitor.start()
        } catch {
            // Input Monitoring is a keyboard-control capability, not an audio-route requirement: the output stays usable
            // and the state is shown in Settings > Shortcuts.
        }
        monitoringState = monitor.state
    }

    func handle(_ action: GlobalVolumeKeyAction, fine: Bool) {
        guard target.isSoftwareVolumeActive else { return }
        let extras = isEnabled()
        switch action {
        case .increment, .decrement:
            let step = fine && extras ? target.softwareVolumeKeyStep.quartered : target.softwareVolumeKeyStep
            let current = target.masterVolumeConfiguration.level
            let level = step.level(afterPress: action == .increment ? 1 : -1, from: current)
            guard abs(level - current) > 0.000_001 else { return }
            target.applySoftwareVolumeKey(level: level)
            if extras { onLevelChanged?() }
        case .mute:
            guard extras else { return }
            Task { @MainActor in
                await perform(.toggleMute)
                onLevelChanged?()
            }
        }
    }
}
