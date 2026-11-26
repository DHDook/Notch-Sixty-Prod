import Foundation

// E12 S27 (behind `e12.blind-listening`): the Blind Listening page tests what the app does. A side is a content
// configuration (current settings, processing off, or a saved content preset) played through the normal
// `transitionContentAuditionState` path, which is the engine's rebuild-with-fade; there is never a second graph.
//
// Control plane, main actor. Nothing here runs on an audio thread. Allocation: allocates (offline). Synchronisation:
// none. Latency: unchanged (no side adds delay). Sample rate: the level model is evaluated at the output device's rate,
// any rate to 384 kHz. Reset: `restoreApplied` puts the captured current settings back on close, stop, reconfiguration
// or device loss. The comparison never starts playback and never arms live ANC or MIMO treatment: room correction,
// bass management, output protection and the Playback System stay as they are on both sides.

/// What can be heard as A or B.
struct ComparisonCandidate: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case current, processingOff, preset(UUID), everythingOff, system(UUID) }

    var kind: Kind
    var name: String
    var state: ContentABAuditionState
    /// E12 S28b2: what a system side plays besides its content settings (room correction, bass management); nil for a
    /// content side.
    var systemOverride: AuditionOverride?
    /// Non-nil when the side is listed greyed: the plain-words reason it cannot be chosen now.
    var unavailableReason: String?

    var isSystemSide: Bool {
        switch kind {
        case .everythingOff, .system: return true
        case .current, .processingOff, .preset: return false
        }
    }

    var id: String {
        switch kind {
        case .current: return "current"
        case .processingOff: return "off"
        case .preset(let id): return id.uuidString
        case .everythingOff: return ComparisonCandidates.everythingOffID
        case .system(let id): return "system-\(id.uuidString)"
        }
    }
}

enum ComparisonCandidates {
    /// Current settings, processing off, then every saved content preset. E31 snapshots join when E31 builds them.
    static func list(current: ContentABAuditionState, presets: [ContentPreset]) -> [ComparisonCandidate] {
        var off = ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(), inputPreampDB: 0, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration())
        // Output protection is a safety setting, not a sound setting: "off" keeps the user's own.
        off.dynamics.outputProtection = current.dynamics.outputProtection
        var out = [
            ComparisonCandidate(kind: .current, name: "Current settings", state: current),
            ComparisonCandidate(kind: .processingOff, name: "Processing off (equaliser, preamp, dynamics)", state: off),
        ]
        out += presets.map {
            ComparisonCandidate(kind: .preset($0.id), name: $0.name, state: ContentABAuditionState(contentState: $0.state))
        }
        return out
    }
}

enum BlindLiveComparisonError: Error, Equatable, LocalizedError {
    case identicalSides
    case levelsTooFarApart

    var errorDescription: String? {
        switch self {
        case .identicalSides: return "A and B are the same settings, so there is nothing to tell apart. Choose two different sides."
        case .levelsTooFarApart: return "These two sides differ in level by more than the level match can remove. Choose closer sides."
        }
    }
}

/// The engine boundary a live comparison plays through (tests inject a fake; production is `ProfileContentAuditionPlayer`).
@MainActor
protocol ContentAuditionPlaying: ComparisonEngine {
    /// The content settings playing now.
    func currentContentState() -> ContentABAuditionState
    /// The output device's sample rate the level model is evaluated at.
    var outputSampleRate: Double { get }
    /// Called once when a test is built: remembers the output, rate, settings and override the test started with, so a
    /// change made elsewhere ends it. No-op by default.
    func beginSession()
    /// Moves the running graph to `state`, with `attenuationDB` (zero or negative) taken off the input.
    func apply(_ state: ContentABAuditionState, attenuationDB: Double) throws
}

extension ContentAuditionPlaying {
    func beginSession() {}
}

@MainActor
enum BlindLiveComparison {
    /// Level of a side in dB on the K-weighted pink-noise model plus its own preamp and headroom.
    static func levelDB(of state: ContentABAuditionState, sampleRate: Double) -> Double? {
        let power = EQLoudnessMatch.power(configuration: state.stereoEQ, rate: sampleRate)
        guard power > 0, power.isFinite else { return nil }
        return 10 * log10(power) + state.inputPreampDB + state.headroomAttenuationDB
    }

    /// `extraADB` and `extraBDB` add a side's level outside the content settings (E13 S12: the headphone correction).
    static func match(
        a: ContentABAuditionState, b: ContentABAuditionState, sampleRate: Double, extraADB: Double = 0, extraBDB: Double = 0
    ) throws -> ComparisonLevelMatch {
        guard let contentA = levelDB(of: a, sampleRate: sampleRate), let contentB = levelDB(of: b, sampleRate: sampleRate) else {
            throw BlindABXError.invalidTrial
        }
        let levelA = contentA + extraADB, levelB = contentB + extraBDB
        return try ComparisonLevelMatch.make(
            lanePowersA: [pow(10, levelA / 10)], lanePowersB: [pow(10, levelB / 10)],
            hasActiveDynamicsA: a.dynamics.hasActiveProcessing, hasActiveDynamicsB: b.dynamics.hasActiveProcessing)
    }

    /// Builds the service for a live test of `a` against `b`. The applied settings are captured now and restored by
    /// `close()` and on every other exit.
    static func makeService(
        player: ContentAuditionPlaying, a: ComparisonCandidate, b: ComparisonCandidate, kind: BlindComparisonService.Kind,
        trialCount: Int, initialAssignment: Bool = Bool.random(), nextAssignment: @escaping () -> Bool = { Bool.random() },
        switchHold: TimeInterval = ComparisonSwitchTiming.fixedSeconds, clock: @escaping () -> Date = { Date() }
    ) throws -> BlindComparisonService {
        guard a.state != b.state else { throw BlindLiveComparisonError.identicalSides }
        let level = try match(a: a.state, b: b.state, sampleRate: player.outputSampleRate)
        let trimA = level.trimADB, trimB = level.trimBDB
        let floor = DSPGainConfiguration.inputPreampRange.lowerBound
        guard trimA >= -24, trimB >= -24,
              a.state.inputPreampDB + trimA >= floor, b.state.inputPreampDB + trimB >= floor else {
            throw BlindLiveComparisonError.levelsTooFarApart
        }
        let adapter = LiveComparisonEngine(player: player, baseline: player.currentContentState())
        return try BlindComparisonService(
            engine: adapter,
            a: ComparisonSide(name: a.name) { try player.apply(a.state, attenuationDB: trimA) },
            b: ComparisonSide(name: b.name) { try player.apply(b.state, attenuationDB: trimB) },
            match: level, kind: kind, trialCount: trialCount, initialAssignment: initialAssignment,
            nextAssignment: nextAssignment, switchHold: switchHold, clock: clock)
    }
}

/// Restores the captured settings; availability and switching come from the player.
@MainActor
final class LiveComparisonEngine: ComparisonEngine {
    private let player: ContentAuditionPlaying
    private let baseline: ContentABAuditionState

    init(player: ContentAuditionPlaying, baseline: ContentABAuditionState) {
        self.player = player
        self.baseline = baseline
    }

    var unavailableReason: String? { player.unavailableReason }
    var isSwitching: Bool { player.isSwitching }
    func restoreApplied() throws { try player.apply(baseline, attenuationDB: 0) }
}

/// Production player: the profile controller's engine, through the A/B-safe content transition.
@MainActor
final class ProfileContentAuditionPlayer: ContentAuditionPlaying {
    private let profiles: ProductProfileController
    private let outputUID: String?
    /// E12 S28b2: what the running test started from; a difference at any later poll ends it and restores.
    private var session: (rate: Double, system: PlaybackSystemState, content: ContentABAuditionState)?
    /// The override the player last applied; another opener of the audition slot makes the engine's differ from it.
    private var appliedOverride: AuditionOverride?

    init(profiles: ProductProfileController) {
        self.profiles = profiles
        outputUID = profiles.engine.selectedOutputDevice?.uid
    }

    var unavailableReason: String? {
        guard profiles.engine.lifecycleState == .running else { return "Start playback with music to compare by ear." }
        if profiles.engine.selectedOutputDevice?.uid != outputUID { return "The output changed, so the comparison ended." }
        if profiles.eqComparison.isComparing || profiles.eqComparison.contentABActive() {
            return "Finish the Equalizer or content A/B comparison first."
        }
        if let endedReason { return endedReason }
        guard let session else { return nil }
        if profiles.engine.auditionOverride != appliedOverride { return "Another comparison opened, so the test ended." }
        if outputSampleRate != session.rate { return "The sample rate changed, so the comparison ended." }
        if appliedOverride.map({ $0.roomCorrection != .applied || $0.bassManagement != nil }) == true,
           let refusal = profiles.engine.auditionSystemDomainsRefusal {
            return refusal
        }
        if profiles.captureSystemState() != session.system || currentContentState() != session.content {
            return "Settings were changed elsewhere, so the comparison ended."
        }
        return nil
    }

    func beginSession() {
        session = (outputSampleRate, profiles.captureSystemState(), currentContentState())
        appliedOverride = profiles.engine.auditionOverride
        endedReason = nil
        // A live treatment about to arm asks the open system test to end and restore first (design note 7).
        profiles.engine.auditionEndRequest = { [weak self] in
            guard let self, let session = self.session, self.profiles.engine.auditionOverride != nil else { return }
            try? self.apply(session.content, attenuationDB: 0)
            self.endedReason = "Room treatment was turned on, so the comparison ended."
        }
    }

    private var endedReason: String?

    var isSwitching: Bool { profiles.engine.graphRebuildInProgress }
    var outputSampleRate: Double { profiles.engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }

    func currentContentState() -> ContentABAuditionState {
        ContentABAuditionState(contentState: profiles.captureContentState())
    }

    /// A standalone player restores nothing by itself; a comparison restores through `LiveComparisonEngine`.
    func restoreApplied() throws {}

    func apply(_ state: ContentABAuditionState, attenuationDB: Double) throws {
        try applySide(content: state, attenuationDB: attenuationDB, override: nil)
    }
}

extension ProfileContentAuditionPlayer: SystemAuditionPlaying {
    var systemContext: SystemAuditionContext? {
        let engine = profiles.engine
        guard engine.lifecycleState == .running, engine.liveGraphEditsAvailable, let layout = engine.auditionLayout else { return nil }
        return SystemAuditionContext(
            running: profiles.captureSystemState(), speakerRouting: engine.speakerRoutingConfiguration,
            programLanes: layout.programLanes, subwoofers: layout.subwoofers, refusal: engine.auditionSystemDomainsRefusal)
    }

    func analyse(content: ContentABAuditionState, override: AuditionOverride?) async throws -> AuditionSideAnalysis {
        let spec = try profiles.engine.auditionSideSpec(content: content, override: override)
        return try await AuditionSideAnalyser.analyse(spec: spec)
    }

    func applySide(content: ContentABAuditionState, attenuationDB: Double, override: AuditionOverride?) throws {
        do {
            try profiles.engine.applyAuditionSide(content: content, attenuationDB: attenuationDB, override: override)
            appliedOverride = override
        } catch {
            // A restore must always clear the slot, even when the republish itself fails.
            if override == nil { profiles.engine.auditionOverride = nil; appliedOverride = nil }
            throw error
        }
    }
}
