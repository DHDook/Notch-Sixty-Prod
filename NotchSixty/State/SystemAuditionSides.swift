import Foundation

// E12 S28b2 (behind `e12.blind-listening`): system-profile sides and the "Everything off" side of the Blind Listening
// page. A side is a content configuration plus an `AuditionOverride` (room correction, bass management), played as one
// faded republish through `SystemAuditionPlaying`. Nothing here writes stored configuration: restoring is "clear the
// slot and republish".
//
// Control plane, main actor; the level and latency analysis runs off the main actor. Allocation: allocates (offline).
// Synchronisation: none. Latency: the shorter side is padded to the longer one, measured on the built graphs (convolver
// engine latency plus declared latency), never from declared latency alone. Sample rate: analysed at the output rate, any
// rate to 384 kHz. Channels: the running layout. Reset: `LiveComparisonEngine.restoreApplied` clears the slot.

/// What the running system looks like, for deciding which saved profiles can be a side.
struct SystemAuditionContext: Equatable, Sendable {
    var running: PlaybackSystemState
    var speakerRouting: SpeakerRoutingConfiguration?
    var programLanes: Int
    var subwoofers: Int
    /// Non-nil while system sides cannot play at all (live room treatment armed, a bi-amp or tri-amp splitter).
    var refusal: String?
}

/// Whether a saved system profile can be a side, and the override that plays it.
enum SystemSideEligibility {
    static func evaluate(profile: PlaybackSystemProfile, context: SystemAuditionContext) -> (override: AuditionOverride?, reason: String?) {
        let saved = profile.state, running = context.running
        if let refusal = context.refusal { return (nil, refusal) }
        if let uid = saved.associatedOutputUID, uid != running.associatedOutputUID { return (nil, "uses a different output") }
        if saved.systemArrangement != running.systemArrangement { return (nil, "uses a different speaker arrangement") }
        if saved.outputRouting != running.outputRouting || saved.speakerRouting != context.speakerRouting {
            return (nil, "uses different output routing")
        }
        if saved.speakerDriverProcessing.flatMap({ $0.isNeutral ? nil : $0 }) != running.speakerDriverProcessing {
            return (nil, "uses different speaker-driver processing")
        }
        if saved.speakerIR != running.speakerIR { return (nil, "uses a different speaker response") }
        if saved.outputDeviceProfile != running.outputDeviceProfile || saved.headphoneDeviceProfile != running.headphoneDeviceProfile {
            return (nil, "uses a different headphone or device profile")
        }
        if saved.playback != running.playback { return (nil, "uses different Playback System controls") }
        if saved.bassManagement.physicalOutputMode != running.bassManagement.physicalOutputMode {
            return (nil, "uses a different bass output mode")
        }
        var override = AuditionOverride()
        let room = saved.roomCorrection
        if !room.enabled {
            if running.roomCorrection.enabled { override.roomCorrection = .off }
        } else if let lanes = room.lanes {
            guard lanes.matches(programLaneCount: context.programLanes, subwooferCount: context.subwoofers) else {
                return (nil, "was measured for a different speaker layout")
            }
            if !(running.roomCorrection.enabled && running.roomCorrection.lanes == lanes) { override.roomCorrection = .lanes(lanes) }
        } else {
            return (nil, "uses an older room correction that cannot be compared live")
        }
        if saved.bassManagement != running.bassManagement { override.bassManagement = saved.bassManagement }
        guard override.roomCorrection != .applied || override.bassManagement != nil else {
            return (nil, "plays the same room correction and bass management as now")
        }
        return (override, nil)
    }
}

extension ComparisonCandidates {
    static let everythingOffID = "everything-off"

    /// The side that turns room correction and bass management off as well as the content processing. Bass management goes
    /// off only when `bassOff` says so (no subwoofer, or the user confirmed the mains can take full-range bass).
    static func everythingOff(current: ContentABAuditionState, context: SystemAuditionContext?, bassOff: Bool) -> ComparisonCandidate {
        var candidate = list(current: current, presets: [])[1]
        candidate.kind = .everythingOff
        candidate.name = "Everything off (room correction, bass management, equaliser, preamp, dynamics)"
        // The content side keeps the current content settings' output protection, like "Processing off".
        guard let context else {
            candidate.unavailableReason = "Start playback with music to compare system settings."
            return candidate
        }
        if let refusal = context.refusal { candidate.unavailableReason = refusal; return candidate }
        var override = AuditionOverride()
        if context.running.roomCorrection.enabled { override.roomCorrection = .off }
        if bassOff, context.running.bassManagement.enabled {
            var bass = context.running.bassManagement
            bass.enabled = false
            override.bassManagement = bass
        }
        candidate.systemOverride = override
        return candidate
    }

    /// Saved system profiles as sides: eligible ones play; the others are listed greyed with the first difference.
    static func systemProfiles(
        _ profiles: [PlaybackSystemProfile], current: ContentABAuditionState, context: SystemAuditionContext?
    ) -> [ComparisonCandidate] {
        profiles.map { profile in
            var candidate = ComparisonCandidate(kind: .system(profile.id), name: "System: \(profile.name)", state: current)
            guard let context else {
                candidate.unavailableReason = "Start playback with music to compare system settings."
                return candidate
            }
            let result = SystemSideEligibility.evaluate(profile: profile, context: context)
            candidate.systemOverride = result.override
            if let reason = result.reason {
                candidate.unavailableReason = context.refusal == reason ? reason : "\(profile.name) \(reason)"
            }
            return candidate
        }
    }
}

/// Level and latency of one built side.
struct AuditionSideAnalysis: Equatable, Sendable {
    var latencyFrames: UInt32
    /// K-weighted pink-noise power summed over every output lane, relative to a flat unity chain per lane.
    var powerRatio: Double
    /// True when the model could not describe every stage of the side.
    var isApproximate: Bool
}

enum AuditionSideAnalyser {
    /// Builds the graph core instance only to read its latency, and runs the weighted-level model, off the main actor.
    static func analyse(spec: UnifiedGraphSpec, strict: Bool = false) async throws -> AuditionSideAnalysis {
        try await Task.detached(priority: .userInitiated) {
            let host = try UnifiedGraphHost(spec: spec)
            defer { host.release() }
            guard let level = HeadroomModel(spec: spec, laneCount: Int(spec.outputChannels), strict: strict, trimsDB: [:]).analyseLevel()
            else { throw BlindABXError.invalidTrial }
            return AuditionSideAnalysis(latencyFrames: host.latencyFrames, powerRatio: level.powerRatio, isApproximate: !level.incomplete.isEmpty)
        }.value
    }
}

/// The engine boundary of a system comparison (tests inject a fake; production is `ProfileContentAuditionPlayer`).
@MainActor
protocol SystemAuditionPlaying: ContentAuditionPlaying {
    /// The running system, or nil when system sides cannot be played now (no N-channel graph session).
    var systemContext: SystemAuditionContext? { get }
    /// Builds and measures the side without playing it.
    func analyse(content: ContentABAuditionState, override: AuditionOverride?) async throws -> AuditionSideAnalysis
    /// Plays the side in one faded republish; a nil override is the stored system.
    func applySide(content: ContentABAuditionState, attenuationDB: Double, override: AuditionOverride?) throws
}

extension BlindLiveComparison {
    /// The pair's level and latency match through the built graphs. The shorter side gets the latency difference as a pad.
    struct SystemPair {
        var match: ComparisonLevelMatch
        var overrideA: AuditionOverride?
        var overrideB: AuditionOverride?
    }

    static func systemPair(
        player: SystemAuditionPlaying, a: ComparisonCandidate, b: ComparisonCandidate
    ) async throws -> SystemPair {
        async let analysisA = player.analyse(content: a.state, override: a.systemOverride)
        async let analysisB = player.analyse(content: b.state, override: b.systemOverride)
        let (sideA, sideB) = try await (analysisA, analysisB)
        var overrideA = a.systemOverride, overrideB = b.systemOverride
        let pad = max(sideA.latencyFrames, sideB.latencyFrames) - min(sideA.latencyFrames, sideB.latencyFrames)
        if pad > N60_GRAPH_MAX_DELAY_FRAMES { throw AuditionOverrideError.padTooLong }
        if pad > 0 {
            if sideA.latencyFrames < sideB.latencyFrames {
                overrideA = (overrideA ?? AuditionOverride()).padded(pad)
            } else {
                overrideB = (overrideB ?? AuditionOverride()).padded(pad)
            }
        }
        var match = try ComparisonLevelMatch.make(
            lanePowersA: [sideA.powerRatio], lanePowersB: [sideB.powerRatio],
            hasActiveDynamicsA: a.state.dynamics.hasActiveProcessing || sideA.isApproximate,
            hasActiveDynamicsB: b.state.dynamics.hasActiveProcessing || sideB.isApproximate)
        match.isElectricalModel = true
        return SystemPair(match: match, overrideA: overrideA, overrideB: overrideB)
    }

    /// The live test when either side is a system side. Same exits as `makeService`: the applied settings are captured now
    /// and restored by `close()` and every other exit, which also clears the audition override.
    static func makeSystemService(
        player: SystemAuditionPlaying, a: ComparisonCandidate, b: ComparisonCandidate, kind: BlindComparisonService.Kind,
        trialCount: Int, initialAssignment: Bool = Bool.random(), nextAssignment: @escaping () -> Bool = { Bool.random() },
        switchHold: TimeInterval = ComparisonSwitchTiming.fixedSeconds, clock: @escaping () -> Date = { Date() }
    ) async throws -> BlindComparisonService {
        guard a.id != b.id else { throw BlindLiveComparisonError.identicalSides }
        for side in [a, b] where side.unavailableReason != nil {
            throw AuditionOverrideError.unavailable(side.unavailableReason ?? "")
        }
        if let reason = player.unavailableReason { throw AuditionOverrideError.unavailable(reason) }
        let pair = try await systemPair(player: player, a: a, b: b)
        let level = pair.match
        let floor = DSPGainConfiguration.inputPreampRange.lowerBound
        guard level.trimADB >= -24, level.trimBDB >= -24,
              a.state.inputPreampDB + level.trimADB >= floor, b.state.inputPreampDB + level.trimBDB >= floor else {
            throw BlindLiveComparisonError.levelsTooFarApart
        }
        player.beginSession()
        let adapter = LiveComparisonEngine(player: player, baseline: player.currentContentState())
        let trimA = level.trimADB, trimB = level.trimBDB
        return try BlindComparisonService(
            engine: adapter,
            a: ComparisonSide(name: a.name) { try player.applySide(content: a.state, attenuationDB: trimA, override: pair.overrideA) },
            b: ComparisonSide(name: b.name) { try player.applySide(content: b.state, attenuationDB: trimB, override: pair.overrideB) },
            match: level, kind: kind, trialCount: trialCount, initialAssignment: initialAssignment,
            nextAssignment: nextAssignment, switchHold: switchHold, clock: clock)
    }
}

extension AuditionOverride {
    /// The same override with `frames` of latency pad on every source lane.
    func padded(_ frames: UInt32) -> AuditionOverride {
        var copy = self
        copy.latencyPadFrames = frames
        return copy
    }
}
