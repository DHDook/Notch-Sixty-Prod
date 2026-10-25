import Foundation

/// What `AudioIOEngine.replaceHeadphoneDeviceProfileConfiguration` does with a change while audio is running
/// (E6 S9c, design decisions D1 and D6).
enum HeadphoneLiveEditPlan: Equatable {
    /// The configuration is the one already in force.
    case unchanged
    /// Same session kind on a graph-rendered binaural or stereo headphone session: republish the graph. `assetChanged` prepares the new
    /// response set off the main actor first, with the old one rendering meanwhile.
    case liveEdit(assetChanged: Bool)
    /// A different session kind (profile on or off, Virtual Speakers on or off, another layout, source device or
    /// head-tracking setup): the engine reconfigures through the Reconfiguring state with a fade out and in.
    case reconfigure
    /// Not allowed while running; the setter throws `configurationChangeRequiresRestart`.
    case refuse
}

enum HeadphoneLiveEditPlanner {
    enum BinauralSession: Equatable {
        case none
        /// A running binaural session rendered by the unified graph.
        case graph
        /// A running binaural session on the legacy bridge pipeline.
        case legacy
    }

    struct Context: Equatable {
        var unifiedGraphEnabled: Bool
        var lifecycleRunning: Bool
        var binauralSession: BinauralSession
        var nChannelSessionActive: Bool
        /// A running stereo session whose graph renders a headphone profile (E6 S9d).
        var stereoHeadphoneGraphActive = false
    }

    /// Two stereo profiles are the same session kind when only the correction and crossfeed differ (E6 S9d).
    static func sameStereoSessionKind(
        _ old: HeadphoneDeviceProfileConfiguration, _ new: HeadphoneDeviceProfileConfiguration
    ) -> Bool {
        old.enabled && new.enabled
            && old.spatialMode == .stereo && new.spatialMode == .stereo
            && old.outputDeviceUID == new.outputDeviceUID
    }

    /// Two profiles describe the same session kind when only things the running graph can republish differ:
    /// name, target curve, headroom, channel correction, crossfeed (inert in Virtual Speakers mode) and the HRTF
    /// asset. Anything that builds a different transport or head-tracking controller is a different kind.
    static func sameSessionKind(
        _ old: HeadphoneDeviceProfileConfiguration, _ new: HeadphoneDeviceProfileConfiguration
    ) -> Bool {
        old.enabled && new.enabled
            && old.spatialMode == .virtualSpeakers && new.spatialMode == .virtualSpeakers
            && old.outputDeviceUID == new.outputDeviceUID
            && old.programSourceDeviceUID == new.programSourceDeviceUID
            && old.programLayout == new.programLayout
            && old.headTracking == new.headTracking
    }

    static func plan(
        from old: HeadphoneDeviceProfileConfiguration?,
        to new: HeadphoneDeviceProfileConfiguration?,
        context: Context
    ) -> HeadphoneLiveEditPlan {
        if old == new { return .unchanged }
        guard context.unifiedGraphEnabled, context.lifecycleRunning, !context.nChannelSessionActive else {
            return .refuse
        }
        switch context.binauralSession {
        case .graph:
            if let old, let new, sameSessionKind(old, new) {
                return .liveEdit(assetChanged: old.binauralProfile != new.binauralProfile)
            }
            return .reconfigure
        case .legacy:
            return .refuse
        case .none:
            if context.stereoHeadphoneGraphActive, let old, let new, sameStereoSessionKind(old, new) {
                return .liveEdit(assetChanged: false)
            }
            // A change of session kind (profile on or off, stereo or Virtual Speakers, another device) rebuilds the
            // transport through the fade; two disabled profiles change nothing a running session renders.
            if (old?.enabled == true) || (new?.enabled == true) { return .reconfigure }
            return .refuse
        }
    }
}
