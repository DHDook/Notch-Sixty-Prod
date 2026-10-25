import Foundation

// E10 S7: deploys the joint bass optimiser's result (S6) to the graph.
//
// The optimiser (`RoomCorrectionCore.optimiseBass`, backed by `n60_correct_bass_optimise` in `n60/correct.h`) returns
// per-channel low-frequency filters on the rate-independent grid plus delay, gain and polarity. This file turns that
// into one value that is published through the normal snapshot path:
//   - the per-channel filters become a `RoomCorrectionMultiLaneDesign` (one ROOM_FIR lane each, synthesised per rate by
//     `RoomCorrectionRateCache`), with the headroom applied as a uniform attenuation of every channel so the set of
//     filters cannot clip;
//   - sub gain, polarity and delay go to `UnifiedGraphBassManagement.subwoofers` (BASS_MGMT gain and polarity, DELAY
//     stage on the sub lane), checked against the BASS_MGMT ranges and the graph's delay limit at the device rate.
// Measurements are taken with the sub gain, polarity and delay neutral, so the result replaces those three values.
//
// Realtime: none. Everything here runs off the audio thread and produces immutable values; the engine never reads the
// feature flag (the caller passes it). Allocation: allocates freely (offline). Sample rate: delay is carried in
// seconds and rounded to frames at the device rate, so every rate to 384 kHz is covered. Channels: up to
// N60_LAYOUT_MAX_CHANNELS lanes. Reset: a plan is a value; dropping it restores the previous snapshot.

/// A bass design ready for the snapshot path.
struct RoomCorrectionBassApplyPlan: Equatable, Sendable {
    /// Filters per corrected lane, headroom applied. Synthesised per rate by `RoomCorrectionRateCache`.
    var design: RoomCorrectionMultiLaneDesign
    /// Lanes of the mains (delay free = false) and of the subwoofers, in subwoofer order.
    var mainLanes: [Int]
    var subLanes: [Int]
    /// Per subwoofer: gain, polarity and delay, as published to BASS_MGMT and DELAY.
    var subGainDB: [Double]
    var subPolarityInverted: [Bool]
    var subDelaySeconds: [Double]
    /// Per main lane, in `mainLanes` order: its delay (a DELAY stage on the lane).
    var mainDelaySeconds: [Double]
    /// The attenuation applied to every channel, in dB (>= 0).
    var headroomDB: Double

    /// Whole frames of each main's delay at `sampleRate`, by lane (only non-zero delays).
    func mainDelayFrames(sampleRate: Double) -> [Int: UInt32] {
        var result: [Int: UInt32] = [:]
        for (lane, seconds) in zip(mainLanes, mainDelaySeconds) {
            let frames = Int((seconds * sampleRate).rounded())
            if frames > 0 { result[lane] = UInt32(frames) }
        }
        return result
    }

    /// Whole frames of each sub's delay at `sampleRate`.
    func subDelayFrames(sampleRate: Double) -> [Int] {
        subDelaySeconds.map { Int(($0 * sampleRate).rounded()) }
    }
}

enum RoomCorrectionBassApplyError: Error, Equatable, LocalizedError {
    case channelMismatch
    case laneOutOfRange(Int)
    case duplicateLane(Int)
    case noSubwoofer
    case tooManySubwoofers(Int)
    case subGainOutOfRange(Double)
    case delayTooLong(frames: Int)

    var errorDescription: String? {
        switch self {
        case .channelMismatch:
            return "The bass design and the lane assignment do not describe the same channels."
        case .laneOutOfRange(let lane):
            return "Lane \(lane) is outside the layout."
        case .duplicateLane(let lane):
            return "Lane \(lane) is assigned to two channels."
        case .noSubwoofer:
            return "The bass design has no subwoofer channel to apply."
        case .tooManySubwoofers(let count):
            return "Bass management drives up to \(UnifiedGraphConfiguration.maxSubwoofers) subwoofers; the design has \(count)."
        case .subGainOutOfRange(let gain):
            return "A subwoofer gain of \(gain) dB is outside the bass-management range (-60 to 24 dB)."
        case .delayTooLong(let frames):
            return "A subwoofer delay of \(frames) frames exceeds the graph's delay limit."
        }
    }
}

enum RoomCorrectionBassApply {
    /// Builds the plan. Returns nil, changing nothing, when `enabled` (the E10 flag, resolved by Swift) is false.
    /// `lanes[i]` is the output lane of optimiser channel `i`; the subs' order is their channel order.
    static func plan(
        optimisation: BassOptimisation,
        channels: [BassChannelSpec],
        lanes: [Int],
        laneCount: Int,
        latencyMode: RoomCorrectionLatencyMode,
        enabled: Bool
    ) throws -> RoomCorrectionBassApplyPlan? {
        guard enabled else { return nil }
        let results = optimisation.report.channels
        guard results.count == channels.count, lanes.count == channels.count,
              optimisation.designs.count == channels.count else {
            throw RoomCorrectionBassApplyError.channelMismatch
        }
        var seen = Set<Int>()
        for lane in lanes {
            guard lane >= 0, lane < laneCount, lane < Int(N60_LAYOUT_MAX_CHANNELS) else {
                throw RoomCorrectionBassApplyError.laneOutOfRange(lane)
            }
            guard seen.insert(lane).inserted else { throw RoomCorrectionBassApplyError.duplicateLane(lane) }
        }
        var mainLanes: [Int] = [], subLanes: [Int] = []
        var gains: [Double] = [], polarity: [Bool] = [], delays: [Double] = [], mainDelays: [Double] = []
        for (index, spec) in channels.enumerated() {
            let result = results[index]
            switch spec.role {
            case .main:
                mainDelays.append(result.delaySeconds)
                mainLanes.append(lanes[index])
            case .sub:
                guard (-60.0...24.0).contains(result.gainDB) else {
                    throw RoomCorrectionBassApplyError.subGainOutOfRange(result.gainDB)
                }
                subLanes.append(lanes[index])
                gains.append(result.gainDB)
                polarity.append(result.polarityInverted)
                delays.append(result.delaySeconds)
            }
        }
        guard !subLanes.isEmpty else { throw RoomCorrectionBassApplyError.noSubwoofer }
        guard subLanes.count <= UnifiedGraphConfiguration.maxSubwoofers else {
            throw RoomCorrectionBassApplyError.tooManySubwoofers(subLanes.count)
        }
        let headroom = max(0, optimisation.report.headroomDB)
        let laneDesigns = zip(lanes, optimisation.designs).map { lane, grid -> RoomCorrectionLaneDesign in
            var shifted = grid
            shifted.correctionDB = grid.correctionDB.map { $0 - headroom }
            return RoomCorrectionLaneDesign(lane: lane, grid: shifted)
        }
        return RoomCorrectionBassApplyPlan(
            design: RoomCorrectionMultiLaneDesign(latencyMode: latencyMode, laneCount: laneCount, lanes: laneDesigns),
            mainLanes: mainLanes, subLanes: subLanes, subGainDB: gains, subPolarityInverted: polarity,
            subDelaySeconds: delays, mainDelaySeconds: mainDelays, headroomDB: headroom)
    }

    /// Writes the main-lane delays and the ROOM_FIR plan into `program`, and the sub gain, polarity and delay into the bass-management configuration and returns the ROOM_FIR plan
    /// for `sampleRate`, to be set as `UnifiedGraphProgramDSP.roomLanes`. Throws when a delay exceeds the graph limit
    /// at this rate (checked at 384 kHz as well as the current rate by the caller's rate sweep).
    static func install(
        _ plan: RoomCorrectionBassApplyPlan,
        into bass: inout UnifiedGraphBassManagement,
        program: inout UnifiedGraphProgramDSP,
        sampleRate: Double,
        cache: RoomCorrectionRateCache
    ) throws -> RoomCorrectionLanePlan {
        guard bass.subwoofers.count == plan.subLanes.count else { throw RoomCorrectionBassApplyError.channelMismatch }
        for frames in plan.subDelayFrames(sampleRate: sampleRate) {
            guard frames >= 0, frames <= Int(N60_GRAPH_MAX_DELAY_FRAMES) else {
                throw RoomCorrectionBassApplyError.delayTooLong(frames: frames)
            }
        }
        let mainFrames = plan.mainDelayFrames(sampleRate: sampleRate)
        for frames in mainFrames.values {
            guard frames <= N60_GRAPH_MAX_DELAY_FRAMES else { throw RoomCorrectionBassApplyError.delayTooLong(frames: Int(frames)) }
        }
        let lanePlan = try cache.plan(for: plan.design, sampleRate: sampleRate)
        var updated = bass
        for index in updated.subwoofers.indices {
            updated.subwoofers[index].gainDB = plan.subGainDB[index]
            updated.subwoofers[index].polarityInverted = plan.subPolarityInverted[index]
            updated.subwoofers[index].delayMilliseconds = plan.subDelaySeconds[index] * 1_000
        }
        bass = updated
        program.roomLanes = lanePlan
        program.laneDelayFrames = mainFrames
        return lanePlan
    }
}
