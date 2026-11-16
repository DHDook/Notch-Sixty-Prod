import Foundation

/// E33 S3 (design 3): the note a band row shows below 20 Hz. Pure; the page shows it only while
/// `e33.page-enhancements` is on.
enum EQSubsonicNote {
    static let boostWarning = "Boost below 20 Hz raises cone excursion"

    /// "Subsonic" for an enabled PEQ band below 20 Hz; with a boost, the excursion warning is added.
    /// Nil otherwise. The headroom badge's rules for boosts are unchanged (no boost cap, decision 3).
    static func note(for band: EQBand) -> String? {
        guard band.type != .fir, EQBandRules.supportsSubsonic(band.type),
              band.frequencyHz.isFinite, band.frequencyHz < EQBandRules.minimumFrequency else { return nil }
        let boosts = band.enabled && band.type.productionHasGainControl && band.gainDB > 0
        return boosts ? "Subsonic. \(boostWarning)" : "Subsonic"
    }
}
