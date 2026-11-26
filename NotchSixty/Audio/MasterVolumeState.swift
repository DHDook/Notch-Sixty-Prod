import Foundation

/// E23 S4 part 4 (G20): the master volume of `AudioIOEngine`: level and mute, what the selected output can do, the
/// media-key step and the output whose stored volume was last restored. Fields are `private(set)`; they change only
/// through these methods, called from `AudioIOEngine+MasterVolume.swift`, the output selection and the key-step setter.
///
/// Main actor only. The render path never reads it; the engine publishes the resulting gain through the graph.
@MainActor
@Observable
final class MasterVolumeState {
    private(set) var configuration = MasterVolumeConfiguration()
    private(set) var capabilities = MasterVolumeDeviceCapabilities.softwareOnly
    private(set) var softwareVolumeKeyStep = MasterVolumeKeyStep.fraction(denominator: 16)
    /// Output whose stored software volume has already been restored. A sync for the same output (external change,
    /// device-list refresh) never overwrites the user's current level.
    @ObservationIgnored private(set) var synchronizedOutputUID: String?

    func setConfiguration(_ value: MasterVolumeConfiguration) { configuration = value }
    func setCapabilities(_ value: MasterVolumeDeviceCapabilities) { capabilities = value }
    /// Ignores a step that is not valid, so the stored step is always usable.
    func setSoftwareVolumeKeyStep(_ step: MasterVolumeKeyStep) {
        guard step.isValid else { return }
        softwareVolumeKeyStep = step
    }
    func setSynchronizedOutputUID(_ uid: String?) { synchronizedOutputUID = uid }
}

extension AudioIOEngine {
    /// Read-forwarders so callers and the UI keep the old names.
    var masterVolumeConfiguration: MasterVolumeConfiguration { masterVolume.configuration }
    var masterVolumeCapabilities: MasterVolumeDeviceCapabilities { masterVolume.capabilities }
    var softwareVolumeKeyStep: MasterVolumeKeyStep { masterVolume.softwareVolumeKeyStep }
    var masterVolumeSynchronizedOutputUID: String? { masterVolume.synchronizedOutputUID }
}
