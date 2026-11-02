import Foundation

// E24 S3c (design note 8): merges the room correction grids with the joint-bass grids into one lane-plan install.
//
// Room correction designs the main lanes (`RoomCorrectionLaneInstall`); the joint bass optimiser
// (`RoomCorrectionBassApply.plan`) designs low-frequency grids for the mains and the subwoofers. A lane that has both gets
// the product of the two grids on the shared core grid (dB add, phase add), so one ROOM_FIR stage carries both. A sub lane
// carries only its bass grid. The result uses the room's latency mode (a bass-only result uses the bass plan's), and the
// mains' alignment delays add. Sub gain, delay and polarity are not part of it: they stay in the profile's sub calibration.
//
// Realtime: none. A pure function over immutable values, run on the control thread. Allocation: allocates freely.
// Sample rate: grid based, so every rate to 384 kHz is covered. Channels: up to N60_LAYOUT_MAX_CHANNELS lanes. Reset:
// the inputs stay with the caller, so recomposing without the bass plan restores the room-only result.

enum RoomCorrectionLaneComposerError: Error, Equatable, LocalizedError {
    case nothingToCompose
    case layoutMismatch
    case laneOutOfRange(Int)
    case gridMismatch(lane: Int)
    case roomOnSubLane(Int)

    var errorDescription: String? {
        switch self {
        case .nothingToCompose: return "There is no room or bass correction to install."
        case .layoutMismatch: return "The room and bass designs were made for different speaker layouts."
        case .laneOutOfRange(let lane): return "Lane \(lane) is outside the speaker layout."
        case .gridMismatch(let lane): return "The room and bass grids on lane \(lane) do not share one frequency grid."
        case .roomOnSubLane(let lane): return "The room correction addresses subwoofer lane \(lane); only bass grids go there."
        }
    }
}

enum RoomCorrectionLaneComposer {
    /// The product of two grid designs on one core grid: corrections add in dB and in phase; the coherence is the lower of
    /// the two (the less certain design limits the claim); the seat contribution is the first design's.
    static func product(_ a: RoomCorrectionGridDesign, _ b: RoomCorrectionGridDesign, lane: Int) throws -> RoomCorrectionGridDesign {
        guard a.correctionDB.count == b.correctionDB.count, a.correctionPhaseRadians.count == b.correctionPhaseRadians.count,
              a.correctionDB.count == a.correctionPhaseRadians.count, a.coherence.count == b.coherence.count else {
            throw RoomCorrectionLaneComposerError.gridMismatch(lane: lane)
        }
        return RoomCorrectionGridDesign(
            correctionDB: zip(a.correctionDB, b.correctionDB).map(+),
            correctionPhaseRadians: zip(a.correctionPhaseRadians, b.correctionPhaseRadians).map(+),
            coherence: zip(a.coherence, b.coherence).map(min),
            seatContribution: a.seatContribution)
    }

    /// Composes `room` and `bass` for a layout of `programLaneCount` program lanes followed by `subwooferCount` sub lanes.
    /// Either may be nil (not both). The result's design covers `programLaneCount + subwooferCount` lanes.
    static func compose(
        room: RoomCorrectionLaneInstall?, bass: RoomCorrectionBassApplyPlan?, name: String,
        programLaneCount: Int, subwooferCount: Int
    ) throws -> RoomCorrectionLaneInstall {
        guard room != nil || bass != nil else { throw RoomCorrectionLaneComposerError.nothingToCompose }
        let total = programLaneCount + subwooferCount
        guard programLaneCount >= 1, total <= Int(N60_LAYOUT_MAX_CHANNELS) else {
            throw RoomCorrectionLaneComposerError.layoutMismatch
        }
        if let room {
            guard room.matches(programLaneCount: programLaneCount, subwooferCount: subwooferCount),
                  room.design.laneCount == total else { throw RoomCorrectionLaneComposerError.layoutMismatch }
            for item in room.design.lanes where item.lane >= programLaneCount {
                throw RoomCorrectionLaneComposerError.roomOnSubLane(item.lane)
            }
        }
        if let bass {
            guard bass.design.laneCount == total else { throw RoomCorrectionLaneComposerError.layoutMismatch }
            for lane in bass.mainLanes where lane < 0 || lane >= programLaneCount {
                throw RoomCorrectionLaneComposerError.laneOutOfRange(lane)
            }
            for lane in bass.subLanes where lane < programLaneCount || lane >= total {
                throw RoomCorrectionLaneComposerError.laneOutOfRange(lane)
            }
        }
        var grids: [Int: RoomCorrectionGridDesign] = [:]
        for item in room?.design.lanes ?? [] { grids[item.lane] = item.grid }
        for item in bass?.design.lanes ?? [] {
            if let existing = grids[item.lane] {
                grids[item.lane] = try product(existing, item.grid, lane: item.lane)
            } else {
                grids[item.lane] = item.grid
            }
        }
        var delays: [Int: Double] = [:]
        for delay in room?.laneDelays ?? [] { delays[delay.lane, default: 0] += delay.seconds }
        if let bass {
            for (lane, seconds) in zip(bass.mainLanes, bass.mainDelaySeconds) where seconds > 0 {
                delays[lane, default: 0] += seconds
            }
        }
        let mode = room?.design.latencyMode ?? bass!.design.latencyMode
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: total,
            lanes: grids.keys.sorted().map { RoomCorrectionLaneDesign(lane: $0, grid: grids[$0]!) })
        let install = RoomCorrectionLaneInstall(
            name: name, design: design,
            laneDelays: delays.keys.sorted().map { RoomCorrectionLaneDelay(lane: $0, seconds: delays[$0]!) },
            programLaneCount: programLaneCount, subwooferCount: subwooferCount)
        try install.validate()
        return install
    }
}
