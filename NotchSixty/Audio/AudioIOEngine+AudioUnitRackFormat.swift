import Foundation

/// E33 S25: the Audio Unit rack's processing format, with the program role of every lane so a stereo-only plug-in can
/// be placed on left/right pairs. Control plane only.
extension AudioIOEngine {
    /// The program roles of the rack's lanes, in lane order; nil on a stereo session.
    func audioUnitRackRoles() -> [OutputProgramRole]? {
        if let headphone = headphoneDeviceProfileConfiguration,
           headphone.enabled,
           headphone.spatialMode == .virtualSpeakers {
            return headphone.programLayout.roles
        }
        if let profile = outputDeviceProfileConfiguration, profile.enabled {
            return profile.programLayout.roles
        }
        return nil
    }

    func makeAudioUnitRackFormat(sampleRate: Double) -> AudioUnitRackProcessingFormat {
        let roles = audioUnitRackRoles()
        return AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: roles?.count ?? 2,
            maximumFramesPerSlice: AudioUnitRackProcessingFormat
                .recommendedMaximumFramesPerSlice(sampleRate: sampleRate),
            channelRoles: roles,
            allowsStereoPairs: FeatureFlags().isEnabled(.eqPageEnhancements)
        )
    }
}
