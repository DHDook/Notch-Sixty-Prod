import Foundation

// E24 S9: blind ABX of two lane-plan designs (minimum and mixed phase) played through the live graph.
//
// Control plane only. Matching is computed from the stage response (`RoomCorrectionCore.filterResponse`, two-band
// aware) of each program lane over 500 Hz to 2 kHz, so a two-band stage is measured through its low band and not
// from its full-rate taps alone. Allocation: allocates (offline). Synchronisation: none. Latency: the match adds the
// difference of the plans' declared latencies as a pure delay on the shorter one. Sample rate: any rate to 384 kHz.
// Channels: up to N60_LAYOUT_MAX_CHANNELS lanes. Reset: the engine clears the override on Stop and teardown.

enum RoomCorrectionABXError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case noProgramLanes
    case rateMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .noProgramLanes: return "The designs share no corrected program lane to match."
        case .rateMismatch: return "The two designs were built for different sample rates."
        }
    }
}

/// The engine boundary the ABX controller plays through (tests inject a fake; production is the engine).
@MainActor
protocol RoomCorrectionABXPlaying: ComparisonEngine {
    /// `unavailableReason`, `isSwitching` and `restoreApplied` come from `ComparisonEngine` (E12 S26).
    func play(_ override: AuditionOverride) throws
}

extension AudioIOEngine: RoomCorrectionABXPlaying {
    var unavailableReason: String? { roomCorrectionABXUnavailableReason }
    var isSwitching: Bool { graphRebuildInProgress }
    func play(_ override: AuditionOverride) throws { try setAuditionOverride(override) }
    func restoreApplied() throws { try setAuditionOverride(nil) }
}

extension RoomCorrectionABXMatch {
    /// Per-lane 500 Hz to 2 kHz power (linear) of the stage that corrects `lane`; a lane with no stage is flat.
    static func lanePower(plan: RoomCorrectionLanePlan, lane: Int) throws -> Double {
        guard let stage = plan.stages.first(where: { $0.laneMask & (UInt64(1) << UInt64(lane)) != 0 }) else { return 1 }
        var frequencies: [Double] = []
        var f = bandLowHz
        let step = pow(2.0, 1.0 / 12.0)
        while f <= bandHighHz * 1.0000001 {
            frequencies.append(f)
            f *= step
        }
        let response = try RoomCorrectionCore.filterResponse(
            sampleRate: plan.sampleRate, taps: stage.taps, twoBand: stage.twoBand,
            declaredLatencyFrames: plan.declaredLatencyFrames, frequencies: frequencies)
        let power = response.magnitudeDB.reduce(0.0) { $0 + pow(10, $1 / 10) }
        return power / Double(frequencies.count)
    }

    /// Matches two lane plans: one global trim (the candidate level is the power mean over `programLanes`), and the
    /// declared-latency difference as delay on the shorter plan. `maxLaneResidualDB` is the largest per-lane level
    /// difference left after the trim, which the sheet warns about above 0.5 dB.
    static func make(
        a: RoomCorrectionLanePlan, b: RoomCorrectionLanePlan, programLanes: [Int]
    ) throws -> RoomCorrectionABXMatch {
        guard !programLanes.isEmpty else { throw RoomCorrectionABXError.noProgramLanes }
        guard abs(a.sampleRate - b.sampleRate) < 0.5 else { throw RoomCorrectionABXError.rateMismatch }
        guard (8_000...384_000).contains(a.sampleRate) else { throw BlindABXError.invalidTrial }
        var powersA: [Double] = [], powersB: [Double] = []
        for lane in programLanes {
            powersA.append(try lanePower(plan: a, lane: lane))
            powersB.append(try lanePower(plan: b, lane: lane))
        }
        // E12 S26: the level maths is the shared comparison service's.
        let level = try ComparisonLevelMatch.make(lanePowersA: powersA, lanePowersB: powersB)
        let latency = max(a.declaredLatencyFrames, b.declaredLatencyFrames)
        var match = RoomCorrectionABXMatch(
            sampleRate: a.sampleRate, levelADB: level.levelADB, levelBDB: level.levelBDB,
            gainA: level.gainA, gainB: level.gainB,
            delayA: Int(latency - a.declaredLatencyFrames), delayB: Int(latency - b.declaredLatencyFrames))
        match.maxLaneResidualDB = level.remainingDifferenceDB
        return match
    }

    /// The override for candidate A (`isA`) or B: its install with the match's trim and delay.
    func override(for install: RoomCorrectionLaneInstall, isA: Bool) -> AuditionOverride {
        .lanes(install, gain: Float(isA ? gainA : gainB), latencyPadFrames: UInt32(isA ? delayA : delayB))
    }

    /// True when a lane differs by more than the 0.5 dB the sheet tolerates without a warning (Q16).
    static let laneResidualWarningDB = 0.5
    var hasLaneResidualWarning: Bool { maxLaneResidualDB > Self.laneResidualWarningDB }
}
