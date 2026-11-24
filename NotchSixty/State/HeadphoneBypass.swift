import Combine
import Foundation

// E13 S12 (`e13.headphones-page`): a bypass switch per Headphones card, and the headphone side of the remote's
// level-matched before/after button. Control plane, main actor; nothing here runs on an audio thread. A bypass is a
// transform of the profile the engine renders: it is applied through the same live-edit path as every other headphone
// edit (a parameter post for correction and crossfeed, a faded reconfigure for Virtual Speakers) and is never written
// to the saved profile. Allocation: allocates (offline). Synchronisation: none. Sample rate: any rate to 384 kHz.

/// Which parts of the headphone processing are switched off for listening.
struct HeadphoneBypassSet: OptionSet, Sendable, Equatable {
    let rawValue: Int
    /// Device Correction: every EQ band and the channel trims. Delay and polarity are channel matching, not tone, and stay.
    static let correction = HeadphoneBypassSet(rawValue: 1)
    static let crossfeed = HeadphoneBypassSet(rawValue: 2)
    /// Virtual Speakers: the session plays as plain stereo (head tracking, which needs Virtual Speakers, goes off with it).
    static let virtualSpeakers = HeadphoneBypassSet(rawValue: 4)
    static let all: HeadphoneBypassSet = [.correction, .crossfeed, .virtualSpeakers]

    /// The profile to render with these parts switched off. Section counts are kept (bands are disabled, not removed), so
    /// a correction or crossfeed bypass is a live edit; a profile with no part to bypass comes back unchanged.
    func applied(to profile: HeadphoneDeviceProfileConfiguration) -> HeadphoneDeviceProfileConfiguration {
        var out = profile
        if contains(.correction) {
            for ear in [\HeadphoneDeviceProfileConfiguration.left, \HeadphoneDeviceProfileConfiguration.right] {
                out[keyPath: ear].gainDB = 0
                for i in out[keyPath: ear].eqBands.indices { out[keyPath: ear].eqBands[i].enabled = false }
            }
        }
        if contains(.crossfeed) { out.crossfeed.preset = .off }
        if contains(.virtualSpeakers), out.spatialMode == .virtualSpeakers {
            out.spatialMode = .stereo
            out.headTracking = nil
        }
        return out
    }

    /// The parts of `profile` that bypass would change (what the cards can offer a switch for).
    static func available(in profile: HeadphoneDeviceProfileConfiguration) -> HeadphoneBypassSet {
        var out: HeadphoneBypassSet = []
        let hasCorrection = [profile.left, profile.right].contains { $0.gainDB != 0 || $0.eqBands.contains(where: \.enabled) }
        if hasCorrection { out.insert(.correction) }
        if profile.crossfeedActive { out.insert(.crossfeed) }
        if profile.spatialMode == .virtualSpeakers { out.insert(.virtualSpeakers) }
        return out
    }
}

/// The page's bypass state for this session. Never persisted; cleared when the page closes.
@MainActor
final class HeadphoneBypassState: ObservableObject {
    @Published private(set) var bypassed: HeadphoneBypassSet = []

    func set(_ part: HeadphoneBypassSet, on: Bool) {
        if on { bypassed.insert(part) } else { bypassed.remove(part) }
    }

    func clear() { bypassed = [] }

    func isBypassed(_ part: HeadphoneBypassSet) -> Bool { bypassed.contains(part) }

    /// What the engine should render for a (saved or draft) profile.
    func effective(_ profile: HeadphoneDeviceProfileConfiguration) -> HeadphoneDeviceProfileConfiguration {
        bypassed.applied(to: profile)
    }
}

enum HeadphoneBypassLevel {
    /// Level in dB of a profile's tonal correction on the 500 Hz to 2 kHz grid the level match uses (power mean over the grid
    /// and both ears), including the channel trims and the headroom attenuation. Crossfeed and Virtual Speakers change level
    /// by amounts that depend on the program and the head model, so they are not part of this number.
    static func levelDB(of profile: HeadphoneDeviceProfileConfiguration, sampleRate: Double) -> Double {
        let grid = ComparisonLevelMatch.gridFrequencies()
        var total = 0.0
        for ear in [profile.left, profile.right] {
            for hz in grid {
                var db = ear.gainDB
                for band in ear.eqBands where band.enabled {
                    db += HeadphoneAutoFitter.bandMagnitudeDB(band, frequencyHz: hz, sampleRate: sampleRate) ?? 0
                }
                total += pow(10, db / 10)
            }
        }
        let mean = total / Double(max(1, 2 * grid.count))
        return 10 * log10(mean) - profile.headroomAttenuationDB
    }
}

/// What the remote's before/after button needs from a headphone session (E12 S13 gets no second compare mechanism).
@MainActor
protocol HeadphoneCompareSupporting: AnyObject {
    /// Why a comparison cannot run now, or nil.
    var unavailableReason: String? { get }
    /// True when switching the headphone processing off changes what plays.
    var hasEffect: Bool { get }
    /// The level of the headphone side with its processing on or off, in dB; both are 0 when `hasEffect` is false.
    func levelDB(bypassed: Bool) -> Double
    /// Whether the level of Virtual Speakers (head model and crossfeed gain) is part of `levelDB`; it is not.
    var levelIsApproximate: Bool { get }
    /// Renders the headphone processing off (`true`) or as saved (`false`), live and without saving.
    func apply(bypassed: Bool) throws
}

@MainActor
final class ProfileHeadphoneCompare: HeadphoneCompareSupporting {
    private let profiles: ProductProfileController

    init(profiles: ProductProfileController) { self.profiles = profiles }

    private var saved: HeadphoneDeviceProfileConfiguration? {
        guard let profile = profiles.selectedSystemHeadphoneDeviceProfile, profile.enabled else { return nil }
        return profile
    }

    private var rate: Double { profiles.engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    var unavailableReason: String? {
        guard FeatureFlags().isEnabled(.headphonesPage) else { return nil }
        if !profiles.headphoneBypass.bypassed.isEmpty {
            return "Turn off the bypass switches on the Headphones page first."
        }
        return nil
    }

    var hasEffect: Bool {
        guard FeatureFlags().isEnabled(.headphonesPage), let saved, profiles.engine.lifecycleState == .running else { return false }
        return HeadphoneBypassSet.all.applied(to: saved) != saved
    }

    var levelIsApproximate: Bool { saved?.spatialMode == .virtualSpeakers }

    func levelDB(bypassed: Bool) -> Double {
        guard hasEffect, let saved else { return 0 }
        return HeadphoneBypassLevel.levelDB(of: bypassed ? HeadphoneBypassSet.all.applied(to: saved) : saved, sampleRate: rate)
    }

    func apply(bypassed: Bool) throws {
        guard let saved else { return }
        try profiles.engine.replaceHeadphoneDeviceProfileConfiguration(bypassed ? HeadphoneBypassSet.all.applied(to: saved) : saved)
    }
}
