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
        .parallelRender, .multirate, .rateAdapt, .coreDesigners,
        .eqPageEnhancements, .dynamicsSound, .designLanguage, .followOutput, .dashboardRemote, .virtualDriver,
        .blindListening,
        .setupFlow, .systemPages, .selfQualification, .headphonesPage, .activeAcousticsPage,
        .activeCommissioning, .settingsPage
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
    /// path). Graduated 11 Nov 2026 (E4 G16): available, never armed.
    static let virtualMicrophone = FeatureFlag(
        id: "e4.virtual-microphone",
        title: "Virtual microphone at the ears",
        epic: "E4",
        graduated: true
    )

    /// E4 S26b: camera head position (Vision body pose, on-device) selects the surveyed virtual-microphone
    /// ratios. Production reader: head follow card (S26b). Graduated 11 Nov 2026 (E4 G16).
    static let headPositionCamera = FeatureFlag(
        id: "e4.head-position-camera",
        title: "Camera head position for the quiet zone",
        epic: "E4",
        graduated: true
    )

    /// E4 S27: choose the zone (fixed seat, follow, or two zones) with the 2 x 2 per-tone core. Offline maths
    /// and the zone mode in the earned-cap binding. Graduated 11 Nov 2026 (E4 G16): available, never armed.
    static let zones = FeatureFlag(
        id: "e4.zones",
        title: "Choose the quiet zone",
        epic: "E4",
        graduated: true
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
    /// the kernel's convolver. Swift decides; the core only sees `firScheme`. Graduated by E9 S8 (default on, available
    /// not armed); the flag-cleanup phase after E22 removes it with the uniform scheme.
    static let longFIR = FeatureFlag(
        id: "e9.long-fir",
        title: "Long FIR (up to 262,144 taps) on the graph",
        epic: "E9",
        graduated: true
    )

    /// E9 S5: protection on every output. Sub lanes get their own limiter, true-peak guard and soft clip with the program
    /// settings, an Advanced switch makes every program lane independent, and an always-on hard limit (-1 dBFS, zero
    /// latency) closes every output. Swift decides; the core only sees the stages. Off: the graph is unchanged.
    /// Graduated by E9 S8 (default on, available not armed): also covers the headroom assistant and the active-speaker
    /// failsafe. The flag-cleanup phase after E22 removes it.
    static let outputProtection = FeatureFlag(
        id: "e9.output-protection",
        title: "Protection on every output",
        epic: "E9",
        graduated: true
    )

    /// E13 S3 and S7 (S4 to S6 join it): live headphone tuning (fixed 16-section layout, Apply while playing) and the
    /// guided personal-BRIR capture in the Headphones workspace, with long BRIRs and head-tracked interpolation. Off: the
    /// workspace is unchanged. Graduated by E13 S8 (default on); the flag-cleanup phase after E22 removes it.
    static let headphones = FeatureFlag(
        id: "e13.headphones",
        title: "Headphones: live tuning and personal BRIR capture",
        epic: "E13",
        graduated: true
    )

    /// E19: MIMO room treatment on the unified graph (designer, stage, safety layer, verifier and Room Treatment controls).
    /// Off: today's code paths, UI and routing refusal. On: the new designer and controls; live output still needs a permit
    /// and the user's arm. Graduated by E19 S11 (default on; `-NotchSixtyFeatures -e19.mimo-treatment` switches it off):
    /// available, never armed. No permit exists before the E22 qualification, and the arm switch, the written authorisation
    /// path and the PR75 verification are unchanged. The flag-cleanup phase after E22 removes it.
    static let mimoTreatment = FeatureFlag(
        id: "e19.mimo-treatment",
        title: "MIMO room treatment",
        epic: "E19",
        graduated: true
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
    /// Graduated at E20 ship (13 Nov 2026): on by default, `-NotchSixtyFeatures -e20.parallel-render` switches it off.
    /// The policy still picks zero workers for graphs one thread can carry.
    static let parallelRender = FeatureFlag(
        id: "e20.parallel-render",
        title: "Parallel render workers",
        epic: "E20",
        graduated: true
    )

    /// E7 S2: imported assets follow the device rate. A speaker impulse response that carries a rate, and a SOFA
    /// HRTF previewed in the research workspace, are resampled (core `n60/resample.h`, cached per rate, original kept)
    /// when used at another rate, and the row says "Resampled from 48 kHz". Off: a rate mismatch refuses as before.
    /// Measurements used for design or verification refuse a mismatch either way. Swift decides; the engine never
    /// reads the flag. E7 S3 adds the per-rate plug-in bypass. Graduated in E7 S5 (default on); the flag-cleanup phase
    /// removes it. `-NotchSixtyFeatures -e7.rate-adapt` switches it off.
    static let rateAdapt = FeatureFlag(
        id: "e7.rate-adapt",
        title: "Imported assets follow the device rate",
        epic: "E7",
        graduated: true
    )

    /// E20 S7 and S8 (multirate low-frequency paths) were skipped on the measured entry rule (12 Nov 2026), so no code
    /// reads this flag. It graduates empty with its epic and is removed in the flag-cleanup phase after E22.
    static let multirate = FeatureFlag(
        id: "e20.multirate",
        title: "Multirate low-frequency paths",
        epic: "E20",
        graduated: true
    )

    /// E21 S5: the measurement and program-analyser maths (direct arrival, analysis window, log-grid response, stereo band
    /// spectrum) runs in libn60core (`n60/measure.h`) instead of Swift and vDSP. Later E21 slices put the designers
    /// behind the same flag. Off: the Swift path, unchanged. Read where the analysis starts (off the main thread, through
    /// `FeatureFlags.isEnabledProcessWide`); the engine never reads it. Removed in the flag-cleanup phase.
    static let coreDesigners = FeatureFlag(
        id: "e21.core-designers",
        title: "Portable core designers and analysis",
        epic: "E21"
    )
    /// E36: the optional Notch Sixty virtual audio driver as a second input path beside the process tap (S1 adds the input-source
    /// seam and the two input lifecycle states; the Settings section, protocol and switch follow). The process tap stays the
    /// default input path and every v1 feature works without the driver. Swift only: the engine never reads it. Off: today's
    /// session, unchanged. Graduated in E36 S7 (available, never armed); removed in the flag-cleanup phase.
    static let virtualDriver = FeatureFlag(
        id: "e36.virtual-driver",
        title: "Virtual audio driver input path",
        epic: "E36"
    )
    /// E33 S1: Equalizer page layout (band list and two-column editor), range hint and moved-to-fit note, and the
    /// sectioned filter picker; later slices add the Dynamics and Meters changes. Graduated in E33 S11d (21 Nov 2026):
    /// available by default, never armed (live ANC and MIMO keep their arm). `-NotchSixtyFeatures -e33.page-enhancements`
    /// restores today's pages and parameters. No new code may depend on it; removed in the flag-cleanup phase.
    static let eqPageEnhancements = FeatureFlag(
        id: "e33.page-enhancements",
        title: "Equalizer, Dynamics and Meters enhancements",
        epic: "E33",
        graduated: true
    )
    /// E32 S5: three sound changes in the graph's dynamics (the limiter's attack never exceeds its look-ahead, the expander's
    /// Attack opens and Release closes, the true-peak factor follows the device rate). Swift decides and publishes them in the
    /// stage parameters; the core never reads the flag. Graduated in E32 S6 (21 Nov 2026): available by default, never armed.
    /// `-NotchSixtyFeatures -e32.dynamics-sound` restores the old attack, expander timing and fixed 4x factor. No new code may
    /// depend on it; removed in the flag-cleanup phase.
    static let dynamicsSound = FeatureFlag(
        id: "e32.dynamics-sound",
        title: "Dynamics sound fixes",
        epic: "E32",
        graduated: true
    )
    /// E34: the app-wide design language (macOS 27 Liquid Glass rules in `docs/DESIGN_LANGUAGE.md`, shared values and
    /// components from S1). Visible changes sit behind it; pages move onto the shared parts first with almost no visible
    /// change. Swift UI only: the engine never reads it. Off: today's look. Graduated in E34 S7; removed in the
    /// flag-cleanup phase.
    static let designLanguage = FeatureFlag(
        id: "e34.design-language",
        title: "Design language",
        epic: "E34"
    )

    /// E15: opt-in "Follow macOS output". With the flag off the mode is forced to fixed, the default-output listener is
    /// never installed and the selected output stays authoritative (`AGENTS.md` section 3). On: the Follow toggle and
    /// binding UI appear; the mode itself still defaults to fixed. Swift only; the engine never reads it. S1 is the
    /// binding table and decision policy (no UI yet). Graduates in E15 S4; removed in the flag-cleanup phase.
    static let followOutput = FeatureFlag(
        id: "e15.follow-output",
        title: "Follow macOS output",
        epic: "E15"
    )

    /// E12 S12-S14: the Dashboard becomes the status page (cards link, health strip, attention area, now playing) and the
    /// menu bar panel becomes the remote control. Swift UI only; the engine never reads it. Off: today's Dashboard and
    /// panel. Graduated in E12 S14 (default on, never arms anything); removed in the flag-cleanup phase.
    static let dashboardRemote = FeatureFlag(
        id: "e12.dashboard-remote",
        title: "Dashboard and menu bar remote",
        epic: "E12",
        graduated: true
    )

    /// E12 S26-S28: Blind Listening. S26 adds the shared comparison service (`BlindComparisonService`) that the setup
    /// sheet's room-correction test already runs on; S27 and S28 add the page that tests what the app does. Swift only;
    /// the engine never reads it. Off: the page and the setup sheet are as they are today. Graduates in E12 S28;
    /// removed in the flag-cleanup phase.
    static let blindListening = FeatureFlag(
        id: "e12.blind-listening",
        title: "Blind Listening",
        epic: "E12"
    )

    /// E12 S10, S11, S29-S31: guided setup improvements. S10 adds the quick path (a step preset of the same flow);
    /// S11 and S29-S31 add the verdict, shell, graphs and level runs. Swift only; the engine never reads it. Off:
    /// guided setup is as it is today. Graduates in E12 S31; removed in the flag-cleanup phase.
    static let setupFlow = FeatureFlag(
        id: "e12.setup-flow",
        title: "Guided setup improvements",
        epic: "E12"
    )

    /// E19 S12a to S12c: MIMO room treatment self-qualification (evidence check and the self-qualified permit basis, then
    /// the probe arm and the guided steps). Swift only. Off: today's permit path exactly. Available is never armed: the
    /// permit never arms, and the arm switch and written authorisation path are unchanged. Graduated by S12c.
    static let selfQualification = FeatureFlag(
        id: "e19.self-qualification",
        title: "MIMO room treatment self-qualification",
        epic: "E19"
    )
}

extension FeatureFlag {
    /// E12 S15-S18: System pages. S15 adds the Overview checklist and the out-of-date notice (the verification
    /// defect fix is not gated); S16 the Speakers page, S17 the calibration summary, S18 the one measure surface.
    /// Swift only; the engine never reads it. Off: the System tabs are as they are today. Graduates in E12 S18;
    /// removed in the flag-cleanup phase.
    static let systemPages = FeatureFlag(
        id: "e12.system-pages",
        title: "System pages",
        epic: "E12"
    )
}

extension FeatureFlag {
    /// E12 S19-S22: the Active Acoustics page. S19 adds the one Quiet Zone card. Swift only; the engine never reads
    /// it. Off: the page is as it is today. Never arms anything. Graduates in E12 S22; removed in the flag-cleanup phase.
    static let activeAcousticsPage = FeatureFlag(
        id: "e12.active-acoustics-page",
        title: "Active Acoustics page",
        epic: "E12"
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
        let launch = Self.launchSets(known: known, policy: policy, arguments: arguments, environment: environment)
        self.launchEnabledIDs = launch.on
        self.launchDisabledIDs = launch.off
    }

    nonisolated private static func launchSets(
        known: [FeatureFlag],
        policy: OverridePolicy,
        arguments: [String],
        environment: [String: String]
    ) -> (on: Set<String>, off: Set<String>) {
        let parsed = launchSwitches(in: arguments)
        var off = parsed.off
        // Flags-off CI run (FC1): the test host cannot take launch arguments, so debug builds also accept this
        // environment variable to switch every graduated flag off. Release builds ignore it.
        if policy == .storedOverrides, environment[graduatedOffEnvironmentKey] == "1" {
            off.formUnion(known.filter(\.graduated).map(\.id))
        }
        return (parsed.on, off)
    }

    /// Process-wide read of a flag with the same rules as `isEnabled`, safe from any thread (no instance, no MainActor).
    /// Graph building runs off the MainActor executor too and must not trap on `MainActor.assumeIsolated`.
    nonisolated static func isEnabledProcessWide(_ flag: FeatureFlag) -> Bool {
        let known = FeatureFlag.all
        guard known.contains(flag) else { return false }
        let policy = buildPolicy
        let launch = launchSets(
            known: known, policy: policy,
            arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        if launch.off.contains(flag.id) { return false }
        if launch.on.contains(flag.id) { return true }
        if policy == .storedOverrides, let stored = UserDefaults.standard.object(forKey: key(for: flag)) as? Bool {
            return stored
        }
        return flag.resolvedDefault
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

    nonisolated static func key(for flag: FeatureFlag) -> String {
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

extension FeatureFlag {
    /// E13 S9-S12: the Headphones page clean-up (one target, one import, shaping sliders, drawn fit, Auto headroom,
    /// crossfeed Custom controls, plain wording), then the headphone list, the generated generic HRTF and compare.
    /// Swift only; the engine never reads it. Off: the page as E13 S8 shipped it. Graduates in E13 S12; removed in
    /// the flag-cleanup phase.
    static let headphonesPage = FeatureFlag(
        id: "e13.headphones-page",
        title: "Headphones page clean-up",
        epic: "E13"
    )
}

extension FeatureFlag {
    /// E8 S12-S16: active-speaker commissioning. S12: a driver role per way and a hard high-pass rule (a tweeter or
    /// midrange way with no high-pass, or one below its lowest safe frequency, is an error and live edits that break it
    /// are refused). Swift only; the engine never reads it. Off: routing behaves exactly as before. Graduates in S16;
    /// removed in the flag-cleanup phase.
    static let activeCommissioning = FeatureFlag(
        id: "e8.active-commissioning",
        title: "Active-speaker commissioning",
        epic: "E8"
    )
}
