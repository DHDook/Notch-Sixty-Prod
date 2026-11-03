import Foundation

// E24 S9: blind ABX of two lane-plan designs (minimum and mixed phase) played through the live graph.
//
// Control plane only. Matching is computed from the stage response (`RoomCorrectionCore.filterResponse`, two-band
// aware) of each program lane over 500 Hz to 2 kHz, so a two-band stage is measured through its low band and not
// from its full-rate taps alone. Allocation: allocates (offline). Synchronisation: none. Latency: the match adds the
// difference of the plans' declared latencies as a pure delay on the shorter one. Sample rate: any rate to 384 kHz.
// Channels: up to N60_LAYOUT_MAX_CHANNELS lanes. Reset: the engine clears the override on Stop and teardown.

/// What the engine plays instead of the profile's applied lanes while the ABX sheet is open.
struct RoomCorrectionABXOverride: Equatable, Sendable {
    var install: RoomCorrectionLaneInstall
    /// Linear trim applied to the whole program (the louder candidate is trimmed down, so nothing clips).
    var gain: Float
    /// Frames added to every source lane (mains and subwoofers) so both candidates arrive together.
    var extraDelayFrames: UInt32
}

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
protocol RoomCorrectionABXPlaying: AnyObject {
    /// Why the ABX cannot play right now, or nil.
    var unavailableReason: String? { get }
    /// True while a previous switch is still warming or fading.
    var isSwitching: Bool { get }
    func play(_ override: RoomCorrectionABXOverride) throws
    /// Back to the applied correction.
    func restoreApplied() throws
}

extension AudioIOEngine: RoomCorrectionABXPlaying {
    var unavailableReason: String? { roomCorrectionABXUnavailableReason }
    var isSwitching: Bool { graphRebuildInProgress }
    func play(_ override: RoomCorrectionABXOverride) throws { try setRoomCorrectionABXOverride(override) }
    func restoreApplied() throws { try setRoomCorrectionABXOverride(nil) }
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
        guard powersA.allSatisfy({ $0 > 0 && $0.isFinite }), powersB.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw BlindABXError.invalidTrial
        }
        func db(_ x: Double) -> Double { 10 * log10(x) }
        let levelA = db(powersA.reduce(0, +) / Double(powersA.count))
        let levelB = db(powersB.reduce(0, +) / Double(powersB.count))
        let target = min(levelA, levelB)
        let trimA = target - levelA, trimB = target - levelB
        var residual = 0.0
        for index in programLanes.indices {
            residual = max(residual, abs((db(powersA[index]) + trimA) - (db(powersB[index]) + trimB)))
        }
        let latency = max(a.declaredLatencyFrames, b.declaredLatencyFrames)
        var match = RoomCorrectionABXMatch(
            sampleRate: a.sampleRate, levelADB: levelA, levelBDB: levelB,
            gainA: pow(10, trimA / 20), gainB: pow(10, trimB / 20),
            delayA: Int(latency - a.declaredLatencyFrames), delayB: Int(latency - b.declaredLatencyFrames))
        match.maxLaneResidualDB = residual
        return match
    }

    /// The override for candidate A (`isA`) or B: its install with the match's trim and delay.
    func override(for install: RoomCorrectionLaneInstall, isA: Bool) -> RoomCorrectionABXOverride {
        RoomCorrectionABXOverride(
            install: install, gain: Float(isA ? gainA : gainB), extraDelayFrames: UInt32(isA ? delayA : delayB))
    }

    /// True when a lane differs by more than the 0.5 dB the sheet tolerates without a warning (Q16).
    static let laneResidualWarningDB = 0.5
    var hasLaneResidualWarning: Bool { maxLaneResidualDB > Self.laneResidualWarningDB }
}
