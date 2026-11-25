import Foundation

/// E16 S1: where App Intents find the running app's control service and navigation. Intents run in the app process but
/// are constructed by the system, so they reach the app through this one holder. The app installs it at launch; tests
/// install a fake-backed service. Never persisted, holds no audio state.
@MainActor
final class AutomationRuntime {
    static let shared = AutomationRuntime()

    private(set) var service: ControlService?
    private(set) var navigation: ProductionNavigation?

    func install(service: ControlService, navigation: ProductionNavigation?) {
        self.service = service
        self.navigation = navigation
    }

    func uninstall() {
        service = nil
        navigation = nil
    }

    static let notReady = "Notch Sixty is not ready yet; open it and try again."

    /// Runs a command, or reports why nothing happened.
    func run(_ command: ControlCommand) async -> ControlResult {
        guard let service else { return .refused(Self.notReady) }
        return await service.perform(command)
    }

    /// "Open Quiet Zone": shows the Active Acoustics page. It arms nothing; Turn On stays a click in the app.
    func openQuietZone() -> ControlResult {
        guard let service else { return .refused(Self.notReady) }
        guard service.isAutomationEnabled else { return .refused(ControlRefusal.notAvailable) }
        navigation?.navigate(to: .activeAcoustics)
        return .done
    }
}
