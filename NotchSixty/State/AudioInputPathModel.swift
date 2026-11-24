import Combine
import Foundation

/// E36 S4: which capture path the user wants. The tap is the default and never changes unless the user chooses the driver.
enum AudioInputPath: String, Equatable, Sendable {
    case processTap
    case virtualDriver
}

/// What one driver status shows in Settings: pure text and the actions on offer, so every status is testable without a view.
struct AudioInputPathPresentation: Equatable {
    enum Action: Equatable {
        case openDownloadPage
        case recheck
    }

    let headline: String
    let detail: String
    let actions: [Action]
    /// The driver switch is available only when the app can take the driver path.
    let canSwitchToDriver: Bool

    init(status: DriverStatus) {
        canSwitchToDriver = status.isUsable
        switch status {
        case .notInstalled:
            headline = "Driver not installed"
            detail = "The optional Notch Sixty virtual audio driver is not on this Mac. Audio keeps using the default capture path."
            actions = [.openDownloadPage, .recheck]
        case .installed(let version):
            headline = "Driver installed (protocol \(version))"
            detail = "Ready. Switch below to send other apps' audio through the driver instead of the default capture path."
            actions = [.recheck]
        case .needsUpdate(let version):
            headline = "Driver needs an update (protocol \(version))"
            detail = "The installed driver is older than this app accepts. Download the current installer and run it; Notch Sixty never installs or updates the driver itself."
            actions = [.openDownloadPage, .recheck]
        case .unknownVersion(let version):
            headline = "Unknown driver version (\(version))"
            detail = "This app does not speak that driver version. Update Notch Sixty, or reinstall the matching driver. The driver path stays off."
            actions = [.openDownloadPage, .recheck]
        case .inUse(let version):
            headline = "Driver in use (protocol \(version))"
            detail = "Audio is flowing through the driver."
            actions = [.recheck]
        case .leaseRefused(let code):
            headline = "Driver refused the connection (error \(code))"
            detail = "The driver is installed and the right version, but it did not accept this app. Check again, or reinstall the driver."
            actions = [.openDownloadPage, .recheck]
        }
    }

    static let crashWarning =
        "If Notch Sixty stops unexpectedly while the driver path is on, macOS goes back to a real output within a few seconds and plays it unprocessed. With active speakers (no passive crossover) that can be very loud or unbalanced, so turn the volume down before using the driver path."

    static let sheetTitle = "Set up the virtual audio driver"
    static let sheetBody =
        "The driver is an optional add-on that gives Notch Sixty its own audio input without the capture indicator. Notch Sixty works fully without it. It is a separate download with its own installer: you run the installer yourself, and Notch Sixty only detects it. The app never downloads, installs, updates or removes the driver."
    static let downloadUnavailable = "The download page is not published yet."
}

/// Drives the "Audio input path" Settings section. The status comes from an injected closure (the read-only driver probe in
/// production, a fake in tests). With a `coordinator` (E36 S5) the switch goes through `switchingInput`, the default-output
/// takeover and the lease; without one (S4 tests) it only calls `onSwitch`.
@MainActor
final class AudioInputPathModel: ObservableObject {
    @Published private(set) var status: DriverStatus
    @Published private(set) var selectedPath: AudioInputPath = .processTap
    @Published var isShowingSetupSheet = false
    /// Set while the driver path is chosen but the driver is missing, stale or refused; never a silent tap fallback.
    @Published private(set) var waitingMessage: String?
    let coordinator: DriverInputCoordinator?
    /// E36 S3b: the engine half of the switch; the product controller attaches the engine once it exists.
    var engineSwitcher: DriverEngineSwitcher?
    /// E36 S6b: automatic sample-rate following (off by default); nil in tests that do not need it.
    var rateFollower: DriverRateFollower?
    @Published private(set) var rateFollowingEnabled = false

    let downloadURL: URL?
    private let probe: () -> DriverStatus
    private let openURL: (URL) -> Void
    private let onSwitch: (AudioInputPath) -> Void

    init(
        probe: @escaping () -> DriverStatus,
        downloadURL: URL?,
        openURL: @escaping (URL) -> Void,
        onSwitch: @escaping (AudioInputPath) -> Void = { _ in },
        coordinator: DriverInputCoordinator? = nil
    ) {
        self.coordinator = coordinator
        self.probe = probe
        self.downloadURL = downloadURL
        self.openURL = openURL
        self.onSwitch = onSwitch
        status = probe()
    }

    var presentation: AudioInputPathPresentation { AudioInputPathPresentation(status: status) }
    var canOpenDownloadPage: Bool { downloadURL != nil }
    /// Every driver-only feature with its availability and "Needs the driver" note (E36 S6a; one registry).
    var unlocks: [DriverUnlockPresentation] { DriverUnlockRegistry.presentation(path: selectedPath, status: status) }

    /// Whether rate following can act now: the driver path is on and the driver is in use.
    var rateFollowingAvailable: Bool {
        DriverUnlockRegistry.isAvailable(.automaticRateFollowing, path: selectedPath, status: status)
    }

    func setRateFollowing(_ enabled: Bool) {
        rateFollower?.isEnabled = enabled
        rateFollowingEnabled = rateFollower?.isEnabled ?? false
    }

    func refresh() {
        refreshStatusAndPath()
        // After the status and path are current, so a driver that just went away stops following at once.
        rateFollower?.tick(driverInUse: rateFollowingAvailable)
    }

    private func refreshStatusAndPath() {
        status = probe()
        if let coordinator {
            coordinator.reconcile()
            waitingMessage = coordinator.statusMessage
            // The choice stands while waiting: the driver path is not abandoned for the tap.
            selectedPath = coordinator.path
            return
        }
        // A driver that went away or became unusable cannot stay selected in the UI.
        if selectedPath == .virtualDriver, !status.isUsable { selectedPath = .processTap }
    }

    func openDownloadPage() {
        guard let url = downloadURL else { return }
        openURL(url)
    }

    /// The switch. Refuses the driver path when the status does not allow it.
    func select(_ path: AudioInputPath) {
        if path == .virtualDriver, !status.isUsable { return }
        guard path != selectedPath else { return }
        if let coordinator {
            selectedPath = coordinator.switchTo(path)
            waitingMessage = coordinator.statusMessage
            status = probe()
            return
        }
        selectedPath = path
        onSwitch(path)
    }

    private var monitorTask: Task<Void, Never>?

    /// Re-checks the driver every two seconds, so a driver that vanishes or returns is noticed without opening Settings.
    func startMonitoring(everySeconds interval: Double = 2) {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Production wiring (E36 S5): real Core Audio status, system output and persisted previous-output record.
    /// `latencySource` supplies the total added delay plus the DAC latency; E31 provides the production value (gap G13).
    static func production(
        openURL: @escaping (URL) -> Void, latencySource: @escaping () -> DriverLatencyInputs? = { nil }
    ) -> AudioInputPathModel {
        let access = SystemHALPropertyStore()
        let driver = DriverStatusModel(
            discovery: DriverDiscovery(access: access),
            lease: DriverLeaseWriter(access: access))
        let switcher = DriverEngineSwitcher(request: {
            guard let plugIn = driver.plugIn, let group = DriverCaptureAttachment.appGroupID() else { return nil }
            return DriverCaptureSelection.Request(plugIn: plugIn, appGroupID: group, access: access)
        })
        let coordinator = DriverInputCoordinator(
            driver: driver, output: CoreAudioSystemOutputController(), store: UserDefaultsPreviousOutputStore(),
            hooks: switcher.hooks, latency: DriverLatencyReporter(access: access), latencySource: latencySource)
        let model = AudioInputPathModel(
            probe: { driver.refresh() }, downloadURL: nil, openURL: openURL, coordinator: coordinator)
        model.engineSwitcher = switcher
        let follower = DriverRateFollower(
            store: UserDefaultsRateFollowingStore(),
            ports: DriverRateFollowingSystem.ports(engine: { [weak switcher] in switcher?.rateFollowingEngine }))
        model.rateFollower = follower
        model.rateFollowingEnabled = follower.isEnabled
        return model
    }
}
