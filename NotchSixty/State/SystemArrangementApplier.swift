import Foundation

// E12 S16 (G17): the one place a chosen arrangement is compiled and written. The setup wizard and the Speakers tab
// editor both call it, so there is no second implementation. Control plane only (main actor); nothing runs on an
// audio thread. Throws a user-readable reason when the arrangement cannot be used.

@MainActor
enum SystemArrangementApplier {
    /// Compiles `arrangement` and writes it: the output device profile, bass management, the stored arrangement and
    /// the stereo session's mono-bass and feed calibration. `base` is the system state the compile starts from.
    static func apply(
        _ arrangement: SystemArrangement, base: PlaybackSystemState, topologyPreset: SystemSetupTopologyPreset,
        profiles: ProductProfileController, engine: AudioIOEngine
    ) throws {
        let compiled: CompiledArrangement
        switch SystemArrangementCompiler.compile(arrangement, preserving: base.outputDeviceProfile) {
        case .success(let value): compiled = value
        case .failure(let issue):
            throw SystemSetupFlowModel.SystemSetupApplyError(issue.errorDescription ?? "This arrangement cannot be used.")
        }
        var target = base
        if compiled.bassManagementEnabled {
            target.bassManagement.frequencyHz = min(
                max(topologyPreset.crossoverHz, SystemSetupTopologyPreset.crossoverRangeHz.lowerBound),
                SystemSetupTopologyPreset.crossoverRangeHz.upperBound)
            target.bassManagement.topology = topologyPreset.slope
        }
        target = compiled.apply(to: target)
        // Clearing the profile first keeps each validation true whichever way the bass switch moves.
        try profiles.replaceSelectedSystemOutputDeviceProfile(nil)
        try profiles.replaceSelectedSystemBassManagement(target.bassManagement)
        if let profile = compiled.outputDeviceProfile {
            try profiles.replaceSelectedSystemOutputDeviceProfile(profile)
        }
        try profiles.replaceSelectedSystemArrangement(arrangement)
        try engine.applyStereoAlignment(compiled.stereoAlignment)
    }

    /// The arrangement with `edit` applied to its stereo alignment, validated by the compiler, stored and sent to the
    /// engine. Rolls the stored arrangement back when the compiler or the engine refuses.
    static func editStereoAlignment(
        of arrangement: SystemArrangement, _ edit: (inout StereoBassAlignment) -> Void,
        profiles: ProductProfileController, engine: AudioIOEngine
    ) throws -> SystemArrangement {
        var updated = arrangement
        var alignment = updated.stereoAlignment ?? StereoBassAlignment()
        edit(&alignment)
        updated.stereoAlignment = alignment
        let compiled: CompiledArrangement
        switch SystemArrangementCompiler.compile(updated, preserving: nil) {
        case .success(let value): compiled = value
        case .failure(let issue):
            throw SystemSetupFlowModel.SystemSetupApplyError(issue.errorDescription ?? "This arrangement cannot be used.")
        }
        try profiles.replaceSelectedSystemArrangement(updated)
        do { try engine.applyStereoAlignment(compiled.stereoAlignment) } catch {
            try? profiles.replaceSelectedSystemArrangement(arrangement)
            throw error
        }
        return updated
    }
}
