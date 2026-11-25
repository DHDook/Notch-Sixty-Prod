import Foundation

/// E16 S1: the production `ControlHost`. A thin adapter over the controllers the UI already calls. It holds no state
/// and has no method that arms a treatment or selects an output.
@MainActor
final class ProductControlHost: ControlHost {
    private let product: ProductController

    init(product: ProductController) { self.product = product }

    private var engine: AudioIOEngine { product.audioEngine }
    private var profiles: ProductProfileController { product.profiles }

    var safeLaunchActive: Bool { product.recovery.safeLaunchActive }
    var lifecycleState: AudioLifecycleState { engine.lifecycleState }
    var isFollowingOutput: Bool { product.outputFollow.isFollowing }
    var selectedOutputUID: String? { engine.routeConfiguration.selectedOutputUID }

    func outputName(forUID uid: String) -> String? {
        engine.outputDevices.first { $0.uid == uid }?.name
    }

    var systems: [ControlSystemInfo] {
        profiles.systemProfiles.map {
            ControlSystemInfo(id: $0.id, name: $0.name, outputUID: $0.state.associatedOutputUID)
        }
    }

    var presets: [ControlPresetInfo] {
        profiles.contentPresets.map { ControlPresetInfo(id: $0.id, name: $0.name) }
    }

    var selectedSystemID: UUID? { profiles.selectedSystemProfileID }
    var selectedPresetID: UUID? { profiles.selectedContentPresetID }
    var volumeLevel: Double { engine.masterVolumeConfiguration.level }
    var isMuted: Bool { engine.masterVolumeConfiguration.muted }
    var volumeControlMode: String { engine.masterVolumeCapabilities.controlMode.rawValue }
    var isBypassed: Bool { engine.playbackControlConfiguration.globalBypassed }
    var isRoomCorrectionEnabled: Bool { engine.roomCorrectionConfiguration.enabled }

    var quietZoneStatus: String { product.activeQuietZone.arm.isArmed ? "On" : "Off" }
    var roomTreatmentStatus: String { product.mimoTreatment.isArmed ? "On" : "Off" }

    func startProcessing() async throws { try await product.startProcessing() }
    func stopProcessing() { engine.stop() }
    func setVolume(_ level: Double) throws { try engine.setMasterVolumeLevel(level) }
    func setMuted(_ muted: Bool) throws { try engine.setMasterMuted(muted) }
    func setBypassed(_ bypassed: Bool) throws { try engine.setGlobalDSPBypassed(bypassed) }
    func setRoomCorrection(_ enabled: Bool) throws { try engine.setRoomCorrectionEnabled(enabled) }
    func selectPreset(_ id: UUID) async throws { try await product.selectContentPreset(id) }

    func selectSystem(_ id: UUID) -> String? {
        profiles.selectSystemProfile(id)
        guard profiles.selectedSystemProfileID == id, profiles.lastErrorDescription == nil else {
            return profiles.lastErrorDescription ?? ControlRefusal.unknownSystem
        }
        return nil
    }
}

extension ProductController {
    /// E16 S2: creates the media-key controller (which now owns the monitor the engine used to hold) and the hotkeys.
    /// Both read `e16.automation` on every action. `onLevelChanged` shows the level indicator.
    func installAutomationInputs(
        service: ControlService,
        flags: @escaping @MainActor () -> FeatureFlags = { FeatureFlags() },
        onLevelChanged: @escaping () -> Void
    ) {
        let engine = audioEngine
        let volumeKeys = VolumeKeyController(
            target: engine,
            perform: { _ = await service.perform($0) },
            isEnabled: { flags().isEnabled(.automation) })
        volumeKeys.onLevelChanged = onLevelChanged
        self.volumeKeys = volumeKeys
        hotkeys = HotkeyController(
            registrar: CarbonHotkeyRegistrar(),
            service: { service },
            volumeStep: { engine.softwareVolumeKeyStep },
            isEnabled: { flags().isEnabled(.automation) })
    }

    /// E16 S1: the one control service for this app. Reads `e16.automation` on every command, so a stored override or
    /// launch argument takes effect without a rebuild.
    func makeControlService(flags: @escaping @MainActor () -> FeatureFlags = { FeatureFlags() }) -> ControlService {
        ControlService(
            host: ProductControlHost(product: self),
            isEnabled: { flags().isEnabled(.automation) })
    }
}
