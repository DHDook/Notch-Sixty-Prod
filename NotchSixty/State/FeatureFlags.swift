import Foundation

/// A feature still in development. An unfinished epic merges to `main` behind
/// a flag that is off by default, so a shipped build never shows it by accident.
///
/// Flags gate app-shell behaviour only. The engine never reads them: Swift
/// decides, then publishes the resulting configuration through the normal
/// graph/snapshot path, which keeps the realtime core flag-free and portable.
struct FeatureFlag: Hashable, Identifiable, Sendable {
    /// Stable identifier; stored as `feature.<id>` and used on the command line.
    let id: String
    let title: String
    /// The program-plan epic that owns the flag, for example "E6".
    let epic: String
    var defaultEnabled = false
}

extension FeatureFlag {
    /// Every flag the app knows. Add one when an epic starts merging dark;
    /// delete it, and the checks that read it, once the epic ships.
    static let all: [FeatureFlag] = [
        .legacyKernel, .ancEngineLease, .adaptiveTonalLive, .earnedCap, .feedForwardLive,
        .noiseSurvey, .conversationUnmasking, .virtualMicrophone, .zones, .headPositionCamera, .overnight,
        .subAwareAnc, .longFIR, .eqSafety
    ]

    /// E6 S11: the unified graph is the default renderer. Turning this on selects the frozen
    /// `N60RenderKernel` fallback instead (no new features). Swift decides; the engine never reads
    /// flags. E23 deletes the kernel and this flag.
    static let legacyKernel = FeatureFlag(
        id: "e6.legacy-kernel",
        title: "Legacy render kernel (frozen fallback)",
        epic: "E6"
    )

    /// E4 S14: the control plane renews a dead-man lease on the live anti-noise; the render path
    /// fades it out if the lease lapses. Off: no lease is enforced. Removed when E4 ships.
    static let ancEngineLease = FeatureFlag(
        id: "e4.engine-lease",
        title: "Anti-noise dead-man lease",
        epic: "E4"
    )

    /// E4 S18b: the adaptive tonal core drives the live anti-noise gains through the render
    /// mailbox, with the supervised microphone-move re-solve. Needs `e4.engine-lease`. Off: the
    /// render snapshot and the control plane behave exactly as before. Removed when E4 ships.
    static let adaptiveTonalLive = FeatureFlag(
        id: "e4.adaptive-tonal-live",
        title: "Adaptive tonal anti-noise (live)",
        epic: "E4"
    )

    /// E4 S20: the anti-noise cap starts at -40 dBFS and rises in 3 dB steps to -18 dBFS as the
    /// seat microphone shows stable improvement, stored per binding. Needs `e4.adaptive-tonal-live`.
    /// Off: the cap is the fixed -40 dBFS, no store is read or written and the render snapshot is
    /// unchanged. Removed when E4 ships.
    static let earnedCap = FeatureFlag(
        id: "e4.earned-cap",
        title: "Earned anti-noise cap",
        epic: "E4"
    )

    /// E4 S22: live feed-forward cancellation. S22b1 gates only the speaker-drive recording the
    /// echo model needs; nothing sets the demand while this is off. Removed when E4 ships.
    static let feedForwardLive = FeatureFlag(
        id: "e4.feedforward-live",
        title: "Live feed-forward cancellation",
        epic: "E4"
    )

    /// E4 S28: the noise survey card (what is cancellable, predicted against achieved reduction, annoyance
    /// estimate). Reads the ambient spectrum only; never touches the arm or output path. Off: no card.
    /// Removed when E4 ships.
    static let noiseSurvey = FeatureFlag(
        id: "e4.noise-survey",
        title: "Noise survey before arming",
        epic: "E4"
    )

    /// E4 S30: Conversation Focus unmasking by speech intelligibility index (per-third-octave music cuts,
    /// syllable-rate speech detection). Ambient compensation only; no ANC output. Off: the broad presence
    /// cut as before. Removed when E4 ships.
    static let conversationUnmasking = FeatureFlag(
        id: "e4.conversation-unmasking",
        title: "Conversation unmasking",
        epic: "E4"
    )

    /// E4 S26a: tonal virtual microphone at the ears (monitor-to-ear ratio survey, effective secondary
    /// path). Offline maths in this slice; nothing drives output while the flag is off. Removed when E4 ships.
    static let virtualMicrophone = FeatureFlag(
        id: "e4.virtual-microphone",
        title: "Virtual microphone at the ears",
        epic: "E4"
    )

    /// E4 S26b: camera head position (Vision body pose, on-device) selects the surveyed virtual-microphone
    /// ratios. Maths and camera source only in this slice; nothing drives output while off. Removed when E4 ships.
    static let headPositionCamera = FeatureFlag(
        id: "e4.head-position-camera",
        title: "Camera head position for the quiet zone",
        epic: "E4"
    )

    /// E4 S27: choose the zone (fixed seat, follow, or two zones) with the 2 x 2 per-tone core. Offline maths
    /// and the zone mode in the earned-cap binding in this slice; nothing drives output while off.
    /// Removed when E4 ships.
    static let zones = FeatureFlag(
        id: "e4.zones",
        title: "Choose the quiet zone",
        epic: "E4"
    )

    /// E4 S29: overnight mode keeps the Mac awake (display may sleep) while Quiet Zone is armed, with the
    /// 10-minute thermal mean. Power assertion type only in this slice; nothing arms it while off.
    /// Removed when E4 ships.
    static let overnight = FeatureFlag(
        id: "e4.overnight",
        title: "Overnight Quiet Zone runs",
        epic: "E4"
    )

    /// E26: sub-aware Quiet Zone. Bass-path records, per-band eligibility and `SubAwareAncReadiness` replace the blanket
    /// "not available with a subwoofer yet" refusal. S1 only stops counting mono bass on the pair (class C) as a sub.
    /// The undeclared-receiver refusal is not behind this flag. Live output still needs the E4 flags and the user's
    /// Turn On. On by default (owner decision, E26 S7). Removed when E26 ships.
    static let subAwareAnc = FeatureFlag(
        id: "e26.sub-aware-anc",
        title: "Sub-aware Quiet Zone",
        epic: "E26",
        // Owner-approved flag enablement (E26 S7): on in release builds too. Live output still needs the E4 flags,
        // the readiness checks, the per-feature arm and the user's Turn On; none of those is loosened.
        defaultEnabled: true
    )

    /// E9 S3: graph FIRs (program, room, speaker IR, driver) of up to 262,144 taps at the engine's 256-frame latency
    /// (`firScheme` 1, the non-uniform engine). Off: the uniform scheme, 32,768 taps, and a longer stereo filter keeps
    /// the kernel's convolver. Swift decides; the core only sees `firScheme`. Removed with the uniform scheme when E9's
    /// FIR part ships.
    static let longFIR = FeatureFlag(
        id: "e9.long-fir",
        title: "Long FIR (up to 262,144 taps) on the graph",
        epic: "E9"
    )

    /// E27 S3a: auto preamp on the Equalizer page (the input preamp follows the EQ's predicted boost).
    /// S3b adds EQ A/B and audition, S2b the program analyser. Swift decides; the engine reads no flag.
    /// Off: the page has the headroom badge and gain controls but never writes a gain by itself.
    /// Removed when E27 ships.
    static let eqSafety = FeatureFlag(
        id: "e27.eq-safety",
        title: "EQ safety and compare (auto preamp)",
        epic: "E27"
    )

}

/// Resolves feature flags.
///
/// - Debug builds honour overrides stored from the Developer section of Settings.
/// - Release builds ignore stored overrides; testers can still enable flags with
///   the launch argument `-NotchSixtyFeatures id1,id2`.
/// - Flags that are not in `known` are always off, so a stale stored override or
///   a mistyped launch argument can never switch anything on.
@MainActor
final class FeatureFlags: ObservableObject {
    enum OverridePolicy: Sendable {
        case storedOverrides
        case launchArgumentOnly
    }

    nonisolated static let launchArgument = "-NotchSixtyFeatures"

    nonisolated static var buildPolicy: OverridePolicy {
        #if DEBUG
        .storedOverrides
        #else
        .launchArgumentOnly
        #endif
    }

    let known: [FeatureFlag]
    let policy: OverridePolicy
    private let defaults: UserDefaults
    private let launchEnabledIDs: Set<String>

    init(
        known: [FeatureFlag] = FeatureFlag.all,
        defaults: UserDefaults = .standard,
        policy: OverridePolicy = FeatureFlags.buildPolicy,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.known = known
        self.defaults = defaults
        self.policy = policy
        self.launchEnabledIDs = Self.launchEnabledIDs(in: arguments)
    }

    var canEditOverrides: Bool { policy == .storedOverrides }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        guard known.contains(flag) else { return false }
        if launchEnabledIDs.contains(flag.id) { return true }
        if canEditOverrides, let stored = defaults.object(forKey: Self.key(for: flag)) as? Bool {
            return stored
        }
        return flag.defaultEnabled
    }

    /// True when the launch argument, not a stored override, decides the flag.
    func isForcedByLaunchArgument(_ flag: FeatureFlag) -> Bool {
        known.contains(flag) && launchEnabledIDs.contains(flag.id)
    }

    func setEnabled(_ enabled: Bool, for flag: FeatureFlag) {
        guard canEditOverrides, known.contains(flag) else { return }
        objectWillChange.send()
        defaults.set(enabled, forKey: Self.key(for: flag))
    }

    func resetOverrides() {
        guard canEditOverrides else { return }
        objectWillChange.send()
        for flag in known {
            defaults.removeObject(forKey: Self.key(for: flag))
        }
    }

    static func key(for flag: FeatureFlag) -> String {
        PreferenceKeys.featureFlagPrefix + flag.id
    }

    private static func launchEnabledIDs(in arguments: [String]) -> Set<String> {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return []
        }
        return Set(
            arguments[index + 1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }
}
