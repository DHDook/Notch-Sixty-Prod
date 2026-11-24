import Foundation

extension FeatureFlag {
    /// E12 S23-S25: the Settings window. S23 adds the five tabs, the About page, the hidden developer switch and the
    /// page-display reset. Swift only; the engine never reads it. Off: the Settings window is as it is today.
    /// Graduates in E12 S25; removed in the flag-cleanup phase.
    static let settingsPage = FeatureFlag(
        id: "e12.settings-page",
        title: "Settings window",
        epic: "E12"
    )
}

/// E12 S23 (G41, owner decision 17): whether the Developer menu (bench and research workspaces) is shown, and whether
/// Settings offers the switch for it.
///
/// With `e12.settings-page` off the stored switch decides in every build, as before. With it on, release builds ignore
/// the stored switch and show the menu only when the launch argument is present; debug builds keep the switch.
enum DeveloperToolsPolicy {
    nonisolated static let launchArgument = "-NotchSixtyDeveloperTools"

    /// True when Settings shows the "Show developer tools" switch.
    nonisolated static func offersSwitch(policy: FeatureFlags.OverridePolicy) -> Bool {
        policy == .storedOverrides
    }

    nonisolated static func isShown(
        stored: Bool,
        settingsPageEnabled: Bool,
        policy: FeatureFlags.OverridePolicy,
        arguments: [String]
    ) -> Bool {
        guard settingsPageEnabled else { return stored }
        if arguments.contains(launchArgument) { return true }
        return policy == .storedOverrides && stored
    }
}

/// E12 S23 (G39): the display choices that pages store for themselves. "Reset page displays" removes exactly these
/// keys, so each page returns to its default, and touches nothing else (presets, profiles, flags, app preferences).
enum PageDisplayPreferences {
    nonisolated static var keys: [String] {
        typealias K = PreferenceKeys
        var keys = [
            K.Meters.peakHold, K.Meters.scaleFloorDB, K.Meters.loudnessTarget,
            K.Equalizer.graphYRange, K.Equalizer.graphXZoom, K.Equalizer.bandCurves,
            K.Equalizer.programAnalyser, K.Equalizer.programAnalyserMode
        ]
        keys += GainReductionSource.allCases.map { K.Dynamics.showTransferCurve($0.rawValue) }
        return keys
    }

    nonisolated static func reset(_ defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
