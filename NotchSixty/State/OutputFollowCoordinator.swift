import Foundation

/// E15 S3: the transaction behind Follow macOS output (design notes 5 to 8 and 11). `OutputFollowEventDriver` (S2) decides
/// when to move; this type is the engine the driver talks to, so every switch runs in the order the design requires:
///
/// 1. disarm every live treatment (reason `.outputFollowed`) before any teardown;
/// 2. stop with the existing fade-out, select the new output, apply the bound Playback System, start (the engine entry
///    from S2, with the profile applied between select and start);
/// 3. a profile that cannot be applied leaves the engine stopped on the new output ("paused", macOS plays it unprocessed)
///    and the previous system's state rolled back, never carried to a device it was not designed for.
///
/// Nothing here arms anything. Control plane only; nothing runs in a render callback.

/// What the coordinator needs from the engine.
@MainActor
protocol OutputFollowSwitching: AnyObject {
    var selectedOutputUID: String? { get }
    var isFailed: Bool { get }
    func switchFollowedOutput(to uid: String, resume: Bool, prepare: () throws -> Void) throws
    /// E15 S4 (G7): starts processing on the already selected output (after a paused output got a binding).
    func start() throws
}

extension AudioIOEngine: OutputFollowSwitching {
    var isFailed: Bool { lifecycleState == .failed }
}

/// What the coordinator needs from the Playback System store.
@MainActor
protocol OutputFollowProfiles: AnyObject {
    var outputBindings: OutputProfileBindings { get }
    var systemProfileIDs: Set<UUID> { get }
    var systemProfileIDsNeedingMapping: Set<UUID> { get }
    func systemProfileName(for id: UUID) -> String?
    func applyBoundSystem(_ id: UUID) throws
    func seedOutputBindingsFromAssociations() -> [String]
    func useSelectedSystem(for key: OutputKey)
    /// E15 S4 (G7): the Playback Systems the unbound sheet offers under "Choose…".
    var systemProfileChoices: [OutputFollowSystemChoice] { get }
    func useSystem(_ id: UUID, for key: OutputKey)
    func unbindOutput(_ key: OutputKey)
}

struct OutputFollowSystemChoice: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

extension ProductProfileController: OutputFollowProfiles {
    var systemProfileChoices: [OutputFollowSystemChoice] {
        systemProfiles.map { OutputFollowSystemChoice(id: $0.id, name: $0.name) }
    }
}

/// Disarms every live treatment that is armed. Returns the names of those it disarmed, for the banner.
@MainActor
protocol OutputFollowTreatmentDisarming: AnyObject {
    func disarmAllForOutputFollow() -> [String]
}

/// What the user sees after a switch or pause (design note 8).
struct OutputFollowAnnouncement: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case switched(profile: String)
        case paused(OutputFollowPauseReason)
        case failed(String)
    }

    var device: String
    var kind: Kind
    /// Treatments that were armed and are now off, for example "Quiet Zone".
    var disarmed: [String]

    var title: String {
        switch kind {
        case .switched(let profile): return "Now on \(device) with \(profile)"
        case .paused: return "No Playback System for \(device)"
        case .failed: return "Could not move to \(device)"
        }
    }

    /// "Quiet Zone disarmed: output changed", or nil when nothing was armed.
    var disarmLine: String? {
        disarmed.isEmpty ? nil : "\(disarmed.joined(separator: " and ")) disarmed: output changed"
    }

    var detail: String? {
        switch kind {
        case .switched: return disarmLine
        case .paused(.noBinding):
            return [disarmLine, "Processing is paused on this output, so macOS plays it unprocessed."].compactMap { $0 }.joined(separator: " ")
        case .paused(.needsMapping):
            return [disarmLine, "The bound Playback System needs its hardware mapped first, so it was not applied."]
                .compactMap { $0 }.joined(separator: " ")
        case .paused(.applyFailed(_, let message)):
            return [disarmLine, "The bound Playback System could not be applied (\(message)); processing is paused."]
                .compactMap { $0 }.joined(separator: " ")
        case .failed(let message): return message
        }
    }

    /// The unbound sheet offers "Choose…" and "Use current for this device" for a pause.
    var isPause: Bool {
        if case .paused = kind { return true }
        return false
    }
}

@MainActor
final class OutputFollowCoordinator: ObservableObject, OutputFollowEngineControlling {
    private let engine: any OutputFollowSwitching
    private let profiles: any OutputFollowProfiles
    private let treatments: any OutputFollowTreatmentDisarming
    private let defaults: UserDefaults
    private let flagEnabled: @MainActor () -> Bool
    /// Safe Launch, measurement capture and similar; the engine's own `failed` state is added here.
    private let externalBlocks: () -> Set<OutputFollowBlock>
    private let displayName: (String) -> String

    /// The latest switch or pause; the banner and the unbound sheet read it. Cleared by `dismissAnnouncement()`.
    @Published private(set) var announcement: OutputFollowAnnouncement?
    /// The output the user is being asked about after a pause (the "Use current for this device" target).
    @Published private(set) var pausedKey: OutputFollowTarget?
    /// Device UIDs that more than one Playback System names, left unbound by the first-enable seed.
    @Published private(set) var ambiguousUIDs: [String] = []
    @Published private(set) var storedMode: OutputSelectionMode

    private(set) var driver: OutputFollowEventDriver!
    /// E15 S3b: macOS notifications for each settled switch. Set by `OutputFollowWiring`; nil where a test does not need it.
    var notifications: FollowNotificationController? {
        didSet { notifications?.onPauseResponse = { [weak self] in self?.reopenPauseSheet() } }
    }
    private var lastPause: OutputFollowAnnouncement?

    // The one in-flight transaction's side results, read by `handle(_:)`.
    private var disarmedByTransaction: [String] = []
    private var applyFailure: (UUID, String)?
    private var appliedProfileName: String?

    init(
        engine: any OutputFollowSwitching,
        profiles: any OutputFollowProfiles,
        treatments: any OutputFollowTreatmentDisarming,
        source: any FollowOutputEventSource,
        scheduler: any FollowScheduling = DispatchFollowScheduler(),
        policy: OutputFollowPolicy = OutputFollowPolicy(),
        defaults: UserDefaults = .standard,
        flagEnabled: (@MainActor () -> Bool)? = nil,
        externalBlocks: @escaping () -> Set<OutputFollowBlock> = { [] },
        displayName: @escaping (String) -> String = { $0 }
    ) {
        self.engine = engine
        self.profiles = profiles
        self.treatments = treatments
        self.defaults = defaults
        self.flagEnabled = flagEnabled ?? { FeatureFlags().isEnabled(.followOutput) }
        self.externalBlocks = externalBlocks
        self.displayName = displayName
        storedMode = OutputSelectionMode.stored(in: defaults)
        driver = OutputFollowEventDriver(
            source: source, engine: self, scheduler: scheduler, policy: policy,
            stateProvider: { [weak self] in self?.currentState() ?? OutputFollowState() })
        driver.onOutcome = { [weak self] outcome in self?.handle(outcome) }
    }

    // MARK: Mode

    /// The mode in force: the stored choice, forced to `.fixed` while `e15.follow-output` is off.
    var effectiveMode: OutputSelectionMode {
        OutputSelectionMode.effective(stored: storedMode, flagEnabled: flagEnabled())
    }

    var isFollowing: Bool { effectiveMode == .followSystem }

    /// Settings toggle and "Stop following". First enable seeds the bindings from the old output associations.
    func setFollowing(_ on: Bool) {
        guard flagEnabled() else { return }
        let mode: OutputSelectionMode = on ? .followSystem : .fixed
        OutputSelectionMode.store(mode, in: defaults)
        storedMode = mode
        if on { ambiguousUIDs = profiles.seedOutputBindingsFromAssociations() }
        notifications?.followingChanged(on)
        reconcile()
        if on { driver.syncToCurrentDefault() }
    }

    /// Call at launch and on every flag or mode change: installs the listener only while following.
    func reconcile() {
        driver.reconcile()
        notifications?.refreshInBackground()
    }

    /// A clicked pause notice shows the "Choose…" sheet again while the output is still paused.
    func reopenPauseSheet() {
        guard pausedKey != nil, let lastPause else { return }
        announcement = lastPause
    }

    /// Call when an excluded state ends (Safe Launch decision made, capture finished, engine left `failed`).
    func exclusionEnded() { driver.resumePending() }

    // MARK: Binding actions (design note 3)

    /// "Use for <device>": binds the selected system to the current output (and data source) and clears a pause.
    func useSelectedSystemForCurrentOutput() {
        guard let key = currentKey() else { return }
        let wasPaused = pausedKey?.key.deviceUID == key.deviceUID
        profiles.useSelectedSystem(for: key)
        if wasPaused {
            dismissAnnouncement()
            startPausedOutput(key: key, profileID: nil)
        }
    }

    /// E15 S4 (G7): "Choose…" on the unbound sheet binds the picked Playback System to the paused output, applies it and
    /// starts processing, so the user does not need the toolbar menu or a separate Start.
    func chooseSystemForCurrentOutput(_ id: UUID) {
        guard let key = currentKey() else { return }
        let wasPaused = pausedKey?.key.deviceUID == key.deviceUID
        profiles.useSystem(id, for: key)
        guard wasPaused else { return }
        dismissAnnouncement()
        startPausedOutput(key: key, profileID: id)
    }

    var systemChoices: [OutputFollowSystemChoice] { profiles.systemProfileChoices }

    private func startPausedOutput(key: OutputKey, profileID: UUID?) {
        do {
            if let profileID { try profiles.applyBoundSystem(profileID) }
            try engine.start()
        } catch {
            announcement = OutputFollowAnnouncement(
                device: displayName(key.deviceUID), kind: .failed(error.localizedDescription), disarmed: [])
        }
    }

    func removeBindingForCurrentOutput() {
        guard let key = currentKey() else { return }
        profiles.unbindOutput(key)
    }

    func dismissAnnouncement() {
        announcement = nil
        pausedKey = nil
    }

    private func currentKey() -> OutputKey? {
        if let pausedKey { return pausedKey.key }
        guard let uid = engine.selectedOutputUID else { return nil }
        return OutputKey(deviceUID: uid, dataSourceID: driver.currentDataSourceID(forDeviceUID: uid))
    }

    // MARK: Driver state

    private func currentState() -> OutputFollowState {
        var state = OutputFollowState()
        state.mode = effectiveMode
        state.bindings = profiles.outputBindings
        state.existingProfileIDs = profiles.systemProfileIDs
        state.needsMappingProfileIDs = profiles.systemProfileIDsNeedingMapping
        var blocks = externalBlocks()
        if engine.isFailed { blocks.insert(.engineFailed) }
        state.blocks = blocks
        return state
    }

    // MARK: The transaction (OutputFollowEngineControlling)

    var selectedOutputUID: String? { engine.selectedOutputUID }

    func switchFollowedOutput(to uid: String, resume: Bool) throws {
        try switchFollowedOutput(to: uid, profileID: nil, resume: resume)
    }

    func switchFollowedOutput(to uid: String, profileID: UUID?, resume: Bool) throws {
        // (a) Disarm first, before any teardown, so the old device never renders anti-noise against a stale path.
        disarmedByTransaction = treatments.disarmAllForOutputFollow()
        applyFailure = nil
        appliedProfileName = nil
        let willResume = resume && profileID != nil
        do {
            try engine.switchFollowedOutput(to: uid, resume: willResume) { [self] in
                // (d) Apply the bound system (transactional; a failure rolls the previous system back), only when
                // there is something to start. A paused output carries no profile at all (note 6).
                guard let profileID else { return }
                do {
                    try profiles.applyBoundSystem(profileID)
                    appliedProfileName = profiles.systemProfileName(for: profileID)
                } catch {
                    applyFailure = (profileID, error.localizedDescription)
                    throw OutputFollowApplyAbort()
                }
            }
        } catch is OutputFollowApplyAbort {
            // The engine is stopped on the new output; the outcome is rewritten to a pause in `handle`.
        }
    }

    private struct OutputFollowApplyAbort: Error {}

    // MARK: Outcomes (design note 8)

    private func handle(_ outcome: OutputFollowOutcome) {
        let disarmed = disarmedByTransaction
        disarmedByTransaction = []
        switch outcome {
        case .switched(let target, let profileID):
            if let (failedID, message) = applyFailure {
                publish(target, .paused(.applyFailed(failedID, message: message)), disarmed)
            } else {
                publish(target, .switched(profile: appliedProfileName ?? profiles.systemProfileName(for: profileID) ?? "Playback System"), disarmed)
            }
        case .paused(let target, let reason):
            publish(target, .paused(reason), disarmed)
        case .failed(let target, let message):
            publish(target, .failed(message), disarmed)
        }
        applyFailure = nil
    }

    private func publish(_ target: OutputFollowTarget, _ kind: OutputFollowAnnouncement.Kind, _ disarmed: [String]) {
        let name = target.displayName.isEmpty ? displayName(target.key.deviceUID) : target.displayName
        let note = OutputFollowAnnouncement(device: name, kind: kind, disarmed: disarmed)
        announcement = note
        if note.isPause { lastPause = note }
        notifications?.announce(note)
        if case .paused = kind { pausedKey = target } else { pausedKey = nil }
    }
}

/// The qualified policy copy (design note 8): the fixed-output promise holds "unless Follow macOS output is on".
enum OutputFollowCopy {
    static func recoveryPolicy(following: Bool) -> String {
        following
            ? "Follow macOS output is on: Notch Sixty processes whichever output macOS is set to and never changes the macOS default itself."
            : "Recovery remains pinned to the selected stable device UID. Unless Follow macOS output is on, Notch Sixty does not silently follow the macOS default output or substitute a different device after disconnect."
    }
}
