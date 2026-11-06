import Foundation

// E25 S5: matrix text wherever a choice is made. Pure. A surface names the features it offers; this returns the matrix
// answer for the selected system's arrangement, or nothing when the system has no arrangement to describe. All wording comes from
// `SystemCapabilityMatrix`; nothing here invents a second set of reasons.
enum SystemCapabilityText {
    typealias Row = (feature: SystemFeature, availability: CapabilityAvailability)

    /// The features each surface offers, in display order.
    static let speakersTabFeatures: [SystemFeature] = [
        .monoBassOnPair, .dspSubFeed, .subAlignment, .multiSubOptimiser, .activeCrossovers, .perSpeakerTrim, .upmixer,
    ]
    static let routingEditorFeatures: [SystemFeature] = [.speakerRoutingEditor, .activeCrossovers]
    static let headphoneFeatures: [SystemFeature] = [.headphoneCorrection, .binauralVirtualSpeakers]
    static let advisorFeatures: [SystemFeature] = [.roomGeometryAdvisor]
    static let profileFeatures: [SystemFeature] = [.exportsAndProfiles, .quietZone, .mimoRoomTreatment]

    /// The stored arrangement, else the one the migration derives in memory (nothing is written).
    static func arrangement(for profile: PlaybackSystemProfile?, deviceChannelCount: Int = 0) -> SystemArrangement? {
        guard let state = profile?.state else { return nil }
        return SystemArrangementMigration.migrated(state, detectedChannelCount: deviceChannelCount).systemArrangement
    }

    static func rows(
        _ features: [SystemFeature], profile: PlaybackSystemProfile?, deviceChannelCount: Int = 0,
        subAwareQuietZone: Bool = false
    ) -> [Row] {
        guard let a = arrangement(for: profile, deviceChannelCount: deviceChannelCount) else { return [] }
        return features.map {
            ($0, SystemCapabilityMatrix.evaluate(
                $0, arrangement: a, deviceChannelCount: deviceChannelCount,
                subAwareQuietZone: subAwareQuietZone))
        }
    }

    /// One plain sentence naming the arrangement, for the room advisor and the profile summary. Downstream bass is
    /// recorded here so advice can say the app cannot control it (decision 4).
    static func arrangementSentence(_ a: SystemArrangement) -> String {
        let channels = a.outputs.channelsInUse == 2 ? "two output channels" : "\(a.outputs.channelsInUse) output channels"
        let bass = SystemSetupArrangementPlanner.title(a.bass).lowercased()
        return "Speakers: \(a.layout.displayName) on \(channels); \(bass)."
    }

    /// Replaces the old "needs an enabled output device profile" readiness reason. Names what the user can do for
    /// their arrangement; the fix stays `describeSpeakers`.
    static func profileRequiredReason(profile: PlaybackSystemProfile?, deviceChannelCount: Int = 0) -> String {
        guard let a = arrangement(for: profile, deviceChannelCount: deviceChannelCount) else {
            return "Describe your speakers in system setup first: this tool needs to know which output drives each speaker."
        }
        switch a.arrangementClass {
        case .a:
            return "Describe your speakers in system setup first: this tool needs to know which output drives each speaker."
        case .b, .c:
            return "This tool needs a separate output for each speaker, and your system uses two output channels. Measure the two feeds from Room Correction instead, or use an output device with more channels."
        case .d, .e:
            return "This tool needs a separate output for each speaker, but your receiver drives them from two feeds. Measure the two feeds from Room Correction instead."
        }
    }
}
