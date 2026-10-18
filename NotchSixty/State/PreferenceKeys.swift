import Foundation

/// Every `UserDefaults` key the app shell writes, in one place. The strings are
/// persisted on users' Macs, so never change one; add a new key and migrate.
enum PreferenceKeys {
    enum Application {
        static let appearance = "application.appearance"
        static let presence = "application.presence"
        static let volumeStepResolution = "application.volumeStepResolution"
        static let showVolumeInMenuBar = "application.showVolumeInMenuBar"
        static let showVolumePopup = "application.showVolumePopup"
        static let volumePopupPosition = "application.volumePopupPosition"
        static let coverSystemVolumePopup = "application.coverSystemVolumePopup"
        static let showDeveloperTools = "application.showDeveloperTools"
    }

    static let abComparisonEnabled = "toolbar.abComparisonEnabled"
    static let vuMetersEnabled = "production.vuMetersEnabled"
    /// E4 S7: measured Quiet Zone round trips, per interface, rate and buffer.
    static let quietZoneMeasuredLatency = "quietZone.measuredLatency"
    /// E4 S9b2: the feed-forward reference microphone's input channel on the
    /// seat microphone's interface (zero-based).
    static let quietZoneFeedForwardReferenceChannel = "quietZone.feedForwardReferenceChannel"

    /// Feature-flag overrides are stored as `feature.<flag id>`.
    static let featureFlagPrefix = "feature."
}
