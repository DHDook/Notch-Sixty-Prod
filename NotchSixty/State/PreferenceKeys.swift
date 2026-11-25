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
        /// E16 S2: our own level indicator when a media key changes the software volume (default on).
        static let showMediaKeyIndicator = "application.showMediaKeyIndicator"
        static let showDeveloperTools = "application.showDeveloperTools"
        /// E12 S8: "simple" or "expert" (`InterfaceMode`).
        static let interfaceMode = "application.interfaceMode"
    }

    static let abComparisonEnabled = "toolbar.abComparisonEnabled"
    static let vuMetersEnabled = "production.vuMetersEnabled"
    /// E4 S7: measured Quiet Zone round trips, per interface, rate and buffer.
    static let quietZoneMeasuredLatency = "quietZone.measuredLatency"
    /// E4 S20: the anti-noise cap earned per output, microphone, rate and output gain.
    static let quietZoneEarnedCaps = "quietZone.earnedCaps"
    /// E4 G19/G20: the ear surveys, saved head-follow seats and camera placement, kept across launches.
    static let quietZoneSurveys = "quietZone.surveys"
    /// E4 S9b2: the feed-forward reference microphone's input channel on the
    /// seat microphone's interface (zero-based).
    static let quietZoneFeedForwardReferenceChannel = "quietZone.feedForwardReferenceChannel"

    /// E27 S2: the Equalizer graph's visible ranges and band-curve choice.
    enum Dynamics {
        /// Whether a gain-reduction panel shows its transfer curve; one key per `GainReductionSource.rawValue`.
        static func showTransferCurve(_ source: String) -> String { "dynamics.showTransferCurve.\(source)" }
    }

    /// E33 S6: the Meters display choices (`e33.page-enhancements`). One hold time drives the level and
    /// gain-reduction peak holds.
    enum Meters {
        static let peakHold = "meters.peakHold"
        static let scaleFloorDB = "meters.scaleFloorDB"
        /// E33 S7: the loudness history target when Loudness Match is off (-14, -16 or -23 LUFS).
        static let loudnessTarget = "meters.loudnessTarget"
    }

    enum Equalizer {
        static let graphYRange = "equalizer.graphYRange"
        static let graphXZoom = "equalizer.graphXZoom"
        static let bandCurves = "equalizer.bandCurves"
        static let programAnalyser = "equalizer.programAnalyser"
        static let programAnalyserMode = "equalizer.programAnalyserMode"
    }

    /// Feature-flag overrides are stored as `feature.<flag id>`.
    static let featureFlagPrefix = "feature."
}
