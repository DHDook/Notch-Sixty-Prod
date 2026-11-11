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
    /// Flag graduation (owner decision, 11 Nov 2026): the epic's software is done, wired and tested, so the feature is
    /// available by default in release builds (and in debug builds, unless a stored override says otherwise). A
    /// graduated flag stays in `FeatureFlag.all` until the flag-cleanup phase removes it. "Graduated" means available,
    /// never armed: live ANC and live MIMO treatment keep their arm switch and written authorisation path, and
    /// graduating never arms anything. No new code may depend on a graduated flag. A user turns a graduated
    /// feature off with `-NotchSixtyFeatures -<id>`. The E4 flags with a production reader graduated on 11 Nov 2026
    /// (the live-output ones make Turn On available, never armed); live MIMO room treatment never graduates in E4.
    var graduated = false

    /// The value used when neither a launch argument nor (debug builds) a stored override decides the flag.
    var resolvedDefault: Bool { defaultEnabled || graduated }
}

extension FeatureFlag {
    /// Every flag the app knows. Add one when an epic starts merging dark. When the epic's software is done and wired
    /// the flag graduates (`graduated: true`, default on); the flag-cleanup phase after E22 deletes it and the checks
    /// that read it. See `docs/FEATURE_FLAGS.md` for the registry.
    static let all: [FeatureFlag] = [
        .legacyKernel, .ancEngineLease, .adaptiveTonalLive, .earnedCap, .feedForwardLive,
        .noiseSurvey, .conversationUnmasking, .virtualMicrophone, .zones, .headPositionCamera, .overnight,
        .subAwareAnc, .longFIR, .outputProtection, .headphones, .mimoTreatment, .dynamicsExtras, .roomModel,
        .parallelRender
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
        epic: "E4",
        graduated: true
    )

    /// E4 S18b: the adaptive tonal core drives the live anti-noise gains through the render
    /// mailbox, with the supervised microphone-move re-solve. Needs `e4.engine-lease`. Off: the
    /// render snapshot and the control plane behave exactly as before. Removed when E4 ships.
    static let adaptiveTonalLive = FeatureFlag(
        id: "e4.adaptive-tonal-live",
        title: "Adaptive tonal anti-noise (live)",
        epic: "E4",
        graduated: true
    )

    /// E4 S20: the anti-noise cap starts at -40 dBFS and rises in 3 dB steps to -18 dBFS as the
    /// seat microphone shows stable improvement, stored per binding. Needs `e4.adaptive-tonal-live`.
    /// Off: the cap is the fixed -40 dBFS, no store is read or written and the render snapshot is
    /// unchanged. Removed when E4 ships.
    static let earnedCap = FeatureFlag(
        id: "e4.earned-cap",
        title: "Earned anti-noise cap",
        epic: "E4",
        graduated: true
    )

    /// E4 S22: live feed-forward cancellation. S22b1 gates only the speaker-drive recording the
    /// echo model needs; nothing sets the demand while this is off. Removed when E4 ships.
    static let feedForwardLive = FeatureFlag(
        id: "e4.feedforward-live",
        title: "Live feed-forward cancellation",
        epic: "E4",
        graduated: true
    )

    /// E4 S28: the noise survey card (what is cancellable, predicted against achieved reduction, annoyance
    /// estimate). Reads the ambient spectrum only; never touches the arm or output path. Off: no card.
    /// Removed when E4 ships.
    static let noiseSurvey = FeatureFlag(
        id: "e4.noise-survey",
        title: "Noise survey before arming",
        epic: "E4",
        graduated: true
    )

    /// E4 S30: Conversation Focus unmasking by speech intelligibility index (per-third-octave music cuts,
    /// syllable-rate speech detection). Ambient compensation only; no ANC output. Off: the broad presence
    /// cut as before. Removed when E4 ships.
    static let conversationUnmasking = FeatureFlag(
        id: "e4.conversation-unmasking",
        title: "Conversation unmasking",
        epic: "E4",
        graduated: true
    )

    /// E4 S26a: tonal virtual microphone at the ears (monitor-to-ear ratio survey, effective secondary
    /// path). Offline maths in this slice; nothing drives output while the flag is off. Removed when E4 ships.
    static let virtualMicrophone = FeatureFlag(
        id: "e4.virtual-microphone",
        title: "Virtual microphone at the ears",
        epic: "E4"
    )

    /// E4 S26b: camera head position (Vision body pose, on-device) selects the surveyed virtual-microphone
    /// ratios. Production reader: head follow card (S26b); graduates in the final G16 PR.
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
        epic: "E4",
        graduated: true
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

    /// E9 S5: protection on every output. Sub lanes get their own limiter, true-peak guard and soft clip with the program
    /// settings, an Advanced switch makes every program lane independent, and an always-on hard limit (-1 dBFS, zero
    /// latency) closes every output. Swift decides; the core only sees the stages. Off: the graph is unchanged.
    static let outputProtection = FeatureFlag(
        id: "e9.output-protection",
        title: "Protection on every output",
        epic: "E9"
    )

    /// E13 S3 and S7 (S4 to S6 join it): live headphone tuning (fixed 16-section layout, Apply while playing) and the
    /// guided personal-BRIR capture in the Headphones workspace. Off: the workspace is unchanged. Removed when E13 ships.
    static let headphones = FeatureFlag(
        id: "e13.headphones",
        title: "Headphones: live tuning and personal BRIR capture",
        epic: "E13"
    )

    /// E19: MIMO room treatment on the unified graph. S3 gates the Swift designer on it; later slices add the stages,
    /// the safety layer, the verifier and the controls. Off: today's code paths, UI and routing refusal. On: the new
    /// designer and controls; live output still needs a permit and the user's arm. Removed when E19 ships.
    static let mimoTreatment = FeatureFlag(
        id: "e19.mimo-treatment",
        title: "MIMO room treatment",
        epic: "E19"
    )

    /// E28 S7: compressor mix, link amount, peak/RMS detector and lookahead on the unified graph (ABI v33). Swift decides;
    /// the core only sees the widened compressor, expander and multiband blocks. Off: today's 10, 6 and 29 value blocks.
    /// Graduated by E28 S8 (default on, available not armed); the flag-cleanup phase after E22 removes it.
    static let dynamicsExtras = FeatureFlag(
        id: "e28.dynamics-extras",
        title: "Dynamics extras",
        epic: "E28",
        graduated: true
    )

    /// E29: the shared room position model. S1 builds the read-only index; the seat map (S4) and the consumers (S6, S7)
    /// follow. Off: every feature reads its own records exactly as today. Removed when E29 ships.
    static let roomModel = FeatureFlag(
        id: "e29.room-model",
        title: "Shared room position model",
        epic: "E29"
    )

    /// E20 S6: parallel rendering of the non-uniform FIR lanes on up to three extra realtime worker threads in the
    /// output device's Audio Workgroup. Swift decides the worker count (`ParallelRenderPolicy`); the core never reads the
    /// flag. Read once at launch. Off: no worker thread exists and the graph renders on the audio thread alone.
    static let parallelRender = FeatureFlag(
        id: "e20.parallel-render",
        title: "Parallel render workers",
        epic: "E20"
    )
}

/// Resolves feature flags.
///
/// - Debug builds honour overrides stored from the Developer section of Settings.
/// - Release builds ignore stored overrides; the launch argument `-NotchSixtyFeatures` is the only switch.
/// - Launch argument syntax: a comma-separated list. `id` or `id=on` turns a flag on; `-id` or `id=off` turns it off
///   (so a release user can switch off a graduated feature). If an id appears both on and off, off wins.
///   The launch argument beats a stored override and the compiled default.
/// - Flags that are not in `known` are always off, so a stale stored override or
///   a mistyped launch argument can never switch anything on.
@MainActor
final class FeatureFlags: ObservableObject {
    enum OverridePolicy: Sendable {
        case storedOverrides
        case launchArgumentOnly
    }

    nonisolated static let launchArgument = "-NotchSixtyFeatures"
    /// Debug builds only: `NOTCHSIXTY_GRADUATED_FLAGS_OFF=1` behaves like `-NotchSixtyFeatures -<id>` for every graduated flag.
    nonisolated static let graduatedOffEnvironmentKey = "NOTCHSIXTY_GRADUATED_FLAGS_OFF"

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
    private let launchDisabledIDs: Set<String>

    init(
        known: [FeatureFlag] = FeatureFlag.all,
        defaults: UserDefaults = .standard,
        policy: OverridePolicy = FeatureFlags.buildPolicy,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.known = known
        self.defaults = defaults
        self.policy = policy
        let parsed = Self.launchSwitches(in: arguments)
        self.launchEnabledIDs = parsed.on
        var off = parsed.off
        // Flags-off CI run (FC1): the test host cannot take launch arguments, so debug builds also accept this
        // environment variable to switch every graduated flag off. Release builds ignore it.
        if policy == .storedOverrides, environment[Self.graduatedOffEnvironmentKey] == "1" {
            off.formUnion(known.filter(\.graduated).map(\.id))
        }
        self.launchDisabledIDs = off
    }

    var canEditOverrides: Bool { policy == .storedOverrides }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        guard known.contains(flag) else { return false }
        if launchDisabledIDs.contains(flag.id) { return false }
        if launchEnabledIDs.contains(flag.id) { return true }
        if canEditOverrides, let stored = defaults.object(forKey: Self.key(for: flag)) as? Bool {
            return stored
        }
        return flag.resolvedDefault
    }

    /// True when the launch argument (on or off), not a stored override, decides the flag.
    func isForcedByLaunchArgument(_ flag: FeatureFlag) -> Bool {
        known.contains(flag) && (launchEnabledIDs.contains(flag.id) || launchDisabledIDs.contains(flag.id))
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

    /// Parses the value after `-NotchSixtyFeatures`. Entries are trimmed; `-id` and `id=off` switch off,
    /// `id` and `id=on` switch on; anything else with `=` is ignored. Off wins over on for the same id.
    nonisolated static func launchSwitches(in arguments: [String]) -> (on: Set<String>, off: Set<String>) {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1) else {
            return ([], [])
        }
        var on = Set<String>()
        var off = Set<String>()
        for raw in arguments[index + 1].split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("-") {
                let id = String(entry.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { off.insert(id) }
            } else if let eq = entry.firstIndex(of: "=") {
                let id = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces).lowercased()
                guard !id.isEmpty else { continue }
                if value == "off" { off.insert(id) } else if value == "on" { on.insert(id) }
            } else {
                on.insert(entry)
            }
        }
        return (on.subtracting(off), off)
    }
}
