import Foundation

/// E4 / E19 groundwork: the always-on safeguards for live speaker ANC and MIMO room
/// treatment. They replace the evidence-based `LiveANCAuthorisation` (owner decision,
/// 27 Oct 2026): live output is decided by a per-feature ARM switch (`LiveTreatmentArm`)
/// and these limits, which no setting can switch off.
///
/// Swift decides and publishes through the normal snapshot path; the engine never reads
/// flags and the realtime callback sees only the resulting, already-limited target.
enum LiveTreatmentSafeguards {
    /// Peak cap on the anti-noise / treatment signal while a feature is armed. Far below
    /// normal use (the old per-source and aggregate caps were -24 and -18 dBFS), so a
    /// first arm cannot be loud even if the solve is wrong.
    static let defaultPeakCapDBFS = -40.0

    /// The most any later commissioning ramp may raise the cap to. A plain setting can
    /// never exceed this, and nothing in this slice raises the cap at all.
    static let hardMaximumPeakCapDBFS = -18.0

    /// Ramp-in after arming and ramp-out after a user disarm or an environment auto-disarm.
    /// Both far exceed the howl detector's contract that anti-noise fades in no faster than
    /// half its growth threshold (`N60AncGuard.h`).
    static let startRampMilliseconds = 3_000.0
    static let stopRampMilliseconds = 1_000.0

    /// Shortest fade the engine accepts (`ActiveQuietZoneRuntimeTarget.validated`). Used for
    /// an instability trip, where the howl detector has already muted the signal itself
    /// over `QuietZoneQualificationTargets.howlMuteRampSeconds`.
    static let tripRampMilliseconds = 20.0

    /// Silent-microphone detection: no input above this level for this long disarms.
    /// A disconnected input still shows preamp noise around -90 to -100 dBFS, so the floor sits
    /// above that, not at digital silence.
    static let silentMicrophoneFloorDBFS = -96.0
    static let silentMicrophoneSeconds = 5.0

    /// No new microphone analysis for this long while armed disarms (frozen analysis).
    static let analysisStallSeconds = 2.0

    /// A change in output gain (volume, headroom) beyond this disarms.
    static let outputGainToleranceDB = 1.0

    /// The cap in force, clamped into [-120, hardMaximum]. Non-finite input yields the default.
    static func clampedPeakCapDBFS(_ requested: Double) -> Double {
        guard requested.isFinite else { return defaultPeakCapDBFS }
        return min(max(requested, -120), hardMaximumPeakCapDBFS)
    }

    static func linearPeak(dbfs: Double) -> Double {
        pow(10, dbfs / 20)
    }

    /// Applies the cap to a planned peak (linear). Non-finite or negative input gives zero.
    static func limitedInjectionPeak(
        _ planned: Double,
        capDBFS: Double = defaultPeakCapDBFS
    ) -> Double {
        guard planned.isFinite, planned > 0 else { return 0 }
        return min(planned, linearPeak(dbfs: clampedPeakCapDBFS(capDBFS)))
    }

    /// Fade length for a disarm of the given cause.
    static func rampMilliseconds(for reason: LiveTreatmentDisarmReason) -> Double {
        reason == .instabilityTrip ? tripRampMilliseconds : stopRampMilliseconds
    }
}

/// Proposed targets from `docs/ANC_QUALIFICATION.md`, accepted with #157.
enum QuietZoneQualificationTargets {
    static let primaryTonalReductionDB = 15.0
    static let primaryBroadbandBandReductionDB = 6.0
    static let quietZoneTonalReductionDB = 10.0
    static let maximumOtherSeatIncreaseDB = 1.0
    static let maximumWaterbedIncreaseDB = 0.5
    static let maximumRepeatDifferenceDB = 1.5
    static let maximumBaselineDriftDB = 1.5
    static let howlTripSeconds = 0.050
    static let howlMuteRampSeconds = 0.010
    static let campaignSeconds: TimeInterval = 1800
}
