import Foundation

/// What `AudioIOEngine.replaceHeadphoneDeviceProfileConfiguration` does with a change while audio is running
/// (E6 S9c, design decisions D1 and D6).
enum HeadphoneLiveEditPlan: Equatable {
    /// The configuration is the one already in force.
    case unchanged
    /// Same session kind on a graph-rendered binaural or stereo headphone session: republish the graph. `assetChanged` prepares the new
    /// response set off the main actor first, with the old one rendering meanwhile.
    case liveEdit(assetChanged: Bool)
    /// A different session kind (profile on or off, Virtual Speakers on or off, another layout, source device or
    /// head-tracking setup): the engine reconfigures through the Reconfiguring state with a fade out and in.
    case reconfigure
    /// Not allowed while running; the setter throws `configurationChangeRequiresRestart`.
    case refuse
}

enum HeadphoneLiveEditPlanner {
    enum BinauralSession: Equatable {
        case none
        /// A running binaural session rendered by the unified graph.
        case graph
        /// A running binaural session on the legacy bridge pipeline.
        case legacy
    }

    struct Context: Equatable {
        var unifiedGraphEnabled: Bool
        var lifecycleRunning: Bool
        var binauralSession: BinauralSession
        var nChannelSessionActive: Bool
        /// A running stereo session whose graph renders a headphone profile (E6 S9d).
        var stereoHeadphoneGraphActive = false
    }

    /// Two stereo profiles are the same session kind when only the correction and crossfeed differ (E6 S9d).
    static func sameStereoSessionKind(
        _ old: HeadphoneDeviceProfileConfiguration, _ new: HeadphoneDeviceProfileConfiguration
    ) -> Bool {
        old.enabled && new.enabled
            && old.spatialMode == .stereo && new.spatialMode == .stereo
            && old.outputDeviceUID == new.outputDeviceUID
    }

    /// Two profiles describe the same session kind when only things the running graph can republish differ:
    /// name, target curve, headroom, channel correction, crossfeed (inert in Virtual Speakers mode) and the HRTF
    /// asset. Anything that builds a different transport or head-tracking controller is a different kind.
    static func sameSessionKind(
        _ old: HeadphoneDeviceProfileConfiguration, _ new: HeadphoneDeviceProfileConfiguration
    ) -> Bool {
        old.enabled && new.enabled
            && old.spatialMode == .virtualSpeakers && new.spatialMode == .virtualSpeakers
            && old.outputDeviceUID == new.outputDeviceUID
            && old.programSourceDeviceUID == new.programSourceDeviceUID
            && old.programLayout == new.programLayout
            && old.headTracking == new.headTracking
    }

    static func plan(
        from old: HeadphoneDeviceProfileConfiguration?,
        to new: HeadphoneDeviceProfileConfiguration?,
        context: Context
    ) -> HeadphoneLiveEditPlan {
        if old == new { return .unchanged }
        guard context.unifiedGraphEnabled, context.lifecycleRunning, !context.nChannelSessionActive else {
            return .refuse
        }
        switch context.binauralSession {
        case .graph:
            if let old, let new, sameSessionKind(old, new) {
                return .liveEdit(assetChanged: old.binauralProfile != new.binauralProfile)
            }
            return .reconfigure
        case .legacy:
            return .refuse
        case .none:
            if context.stereoHeadphoneGraphActive, let old, let new, sameStereoSessionKind(old, new) {
                return .liveEdit(assetChanged: false)
            }
            // A change of session kind (profile on or off, stereo or Virtual Speakers, another device) rebuilds the
            // transport through the fade; two disabled profiles change nothing a running session renders.
            if (old?.enabled == true) || (new?.enabled == true) { return .reconfigure }
            return .refuse
        }
    }
}

/// E13 S3: whether the HEADPHONE stage is built with the fixed 16-section layout that makes every correction edit a
/// posted parameter. Set once at launch from `e13.headphones` (feature flags are main-actor, graph specs are built on
/// any thread); the engine itself reads no flag.
enum UnifiedGraphLiveHeadphoneTuning {
    /// A peaking section at 0 dB: the engine's unused-section filler (identity up to rounding).
    static let unitySection: [Float] = [0, 1000, 0, 1]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false

    static var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    @MainActor static func refresh(_ flags: FeatureFlags? = nil) {
        set((flags ?? FeatureFlags()).isEnabled(.headphones))
    }

    /// Tests and `refresh`.
    static func set(_ value: Bool) {
        lock.lock(); on = value; lock.unlock()
    }
}

/// E13 S3: live tuning of the headphone correction and crossfeed. The workspace submits every draft edit; the tuner
/// coalesces them to one engine post per interval (20 ms) and applies them through the engine's live-edit path, which
/// posts parameters into the running graph. A draft whose positive gain exceeds the applied headroom raises headroom
/// first, then follows with the gain. Nothing here is persisted: `restore` puts the saved profile back.
@MainActor
final class HeadphoneLiveTuner {
    typealias Apply = (HeadphoneDeviceProfileConfiguration) throws -> Void
    typealias Sleep = (Duration) async -> Void

    static let interval: Duration = .milliseconds(20)
    /// Longer than the engine's parameter ramp, so a raised headroom has landed before the gain that needs it.
    static let headroomLead: Duration = .milliseconds(60)

    private let apply: Apply
    private let sleep: Sleep
    private(set) var applied: HeadphoneDeviceProfileConfiguration?
    private(set) var lastError: String?
    private var pending: HeadphoneDeviceProfileConfiguration?
    private var pump: Task<Void, Never>?
    /// Number of calls made to `apply` (tests and diagnostics).
    private(set) var postCount = 0

    init(
        apply: @escaping Apply,
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }
    ) {
        self.apply = apply
        self.sleep = sleep
    }

    /// Starts a tuning run from the profile the engine is rendering now.
    func begin(from saved: HeadphoneDeviceProfileConfiguration) {
        pump?.cancel(); pump = nil
        pending = nil
        applied = saved
        lastError = nil
    }

    /// Queues a draft; only the newest draft within an interval is applied.
    func submit(_ draft: HeadphoneDeviceProfileConfiguration) {
        guard applied != nil, draft != applied || pending != nil else { return }
        pending = draft
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(Self.interval)
            await self.drain()
        }
    }

    /// Applies what is queued now (also the body of the interval pump).
    func drain() async {
        defer { pump = nil }
        guard let draft = pending, let last = applied else { return }
        pending = nil
        let steps = Self.steps(from: last, to: draft)
        for (index, step) in steps.enumerated() {
            do {
                try apply(step)
                postCount += 1
                applied = step
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                return
            }
            if index + 1 < steps.count { await sleep(Self.headroomLead) }
        }
        // An edit that arrived while the steps ran.
        if let next = pending, next != applied {
            pump = nil
            submit(next)
        }
    }

    /// Puts `saved` back at once (Revert, leaving the workspace). Drops anything queued.
    func restore(_ saved: HeadphoneDeviceProfileConfiguration) {
        pump?.cancel(); pump = nil
        pending = nil
        guard applied != nil, saved != applied else { return }
        do {
            try apply(saved)
            postCount += 1
            applied = saved
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Headroom a draft needs: the larger of its own setting and the conservative requirement, rounded up to 0.5 dB.
    static func effectiveHeadroomDB(_ draft: HeadphoneDeviceProfileConfiguration) -> Double {
        let need = (draft.conservativeRequiredHeadroomDB * 2).rounded(.up) / 2
        return min(30, max(draft.headroomAttenuationDB, need))
    }

    /// The profiles to apply, in order: when the draft needs more headroom than `last` applies, `last` with the raised
    /// headroom comes first (so the gain edit never plays un-headroomed), then the draft itself.
    static func steps(
        from last: HeadphoneDeviceProfileConfiguration, to draft: HeadphoneDeviceProfileConfiguration
    ) -> [HeadphoneDeviceProfileConfiguration] {
        var target = draft
        target.headroomAttenuationDB = effectiveHeadroomDB(draft)
        guard target.headroomAttenuationDB > last.headroomAttenuationDB + 1e-9,
              target.conservativeRequiredHeadroomDB > last.conservativeRequiredHeadroomDB + 1e-9 else {
            return [target]
        }
        var raised = last
        raised.headroomAttenuationDB = target.headroomAttenuationDB
        return [raised, target]
    }

    /// Whether `draft` can be tuned live against what is rendering: the same session kind, which the engine edits in
    /// place (anything else reconfigures with a fade and stays a stopped-state Apply).
    static func isLiveEditable(
        saved: HeadphoneDeviceProfileConfiguration?, draft: HeadphoneDeviceProfileConfiguration
    ) -> Bool {
        guard let saved, saved.enabled, draft.enabled else { return false }
        return HeadphoneLiveEditPlanner.sameStereoSessionKind(saved, draft)
            || HeadphoneLiveEditPlanner.sameSessionKind(saved, draft)
    }
}
