import Foundation

// E24 S3b (design note 8): the stored form of a lane-plan room correction and why one is not running.
//
// A `RoomCorrectionLaneInstall` is rate independent: the grid designs per main lane, the main lanes' alignment delays
// in seconds, and the speaker-profile layout it was measured for. It rides in `RoomCorrectionConfiguration.lanes`;
// the engine synthesises taps for the device rate (`RoomCorrectionRateCache`) on the control thread and installs
// them through `makeUnifiedProgramDSP` -> `UnifiedGraphProgramDSP.roomLanes`.
//
// Realtime: none. Everything here is an immutable value built and checked off the audio thread. Allocation:
// allocates freely (control thread). Sample rate: seconds are rounded to frames at the device rate, so every rate to
// 384 kHz is covered. Channels: up to N60_LAYOUT_MAX_CHANNELS lanes, program and sub. Reset: dropping the value restores the
// previous configuration.

/// One main lane's alignment delay.
struct RoomCorrectionLaneDelay: Equatable, Codable, Sendable {
    var lane: Int
    var seconds: Double
}

struct RoomCorrectionLaneInstall: Equatable, Codable, Sendable {
    var name: String
    var design: RoomCorrectionMultiLaneDesign
    var laneDelays: [RoomCorrectionLaneDelay]
    /// The profile's lane layout at design time: the program lanes and the subwoofers after them.
    var programLaneCount: Int
    var subwooferCount: Int

    init(
        name: String, design: RoomCorrectionMultiLaneDesign, laneDelays: [RoomCorrectionLaneDelay] = [],
        programLaneCount: Int, subwooferCount: Int
    ) {
        self.name = name
        self.design = design
        self.laneDelays = laneDelays
        self.programLaneCount = programLaneCount
        self.subwooferCount = subwooferCount
    }

    /// The lanes the design addresses: the program lanes, then the subwoofers' lanes (E24 S3c).
    var sourceLaneCount: Int { programLaneCount + subwooferCount }

    /// Checks the value on its own (no session): the design addresses lanes inside the layout (program lanes and sub
    /// lanes), and the delays are finite, non-negative and on distinct main lanes.
    func validate() throws {
        guard programLaneCount >= 1, subwooferCount >= 0, sourceLaneCount <= Int(N60_LAYOUT_MAX_CHANNELS),
              design.laneCount == sourceLaneCount, !design.lanes.isEmpty else {
            throw RoomCorrectionLaneInstallError.invalidLayout
        }
        var seen = Set<Int>()
        for item in design.lanes {
            guard item.lane >= 0, item.lane < sourceLaneCount else {
                throw RoomCorrectionLaneInstallError.laneOutOfRange(item.lane)
            }
            guard seen.insert(item.lane).inserted else { throw RoomCorrectionLaneInstallError.duplicateLane(item.lane) }
        }
        var delayed = Set<Int>()
        for delay in laneDelays {
            guard delay.lane >= 0, delay.lane < programLaneCount else {
                throw RoomCorrectionLaneInstallError.laneOutOfRange(delay.lane)
            }
            guard delayed.insert(delay.lane).inserted else { throw RoomCorrectionLaneInstallError.duplicateLane(delay.lane) }
            guard delay.seconds.isFinite, delay.seconds >= 0 else { throw RoomCorrectionLaneInstallError.invalidDelay(delay.lane) }
        }
    }

    /// True when the running session has the layout this correction was measured for. A session that does not say how
    /// many subwoofers it has (binaural, Virtual Speakers) has none.
    func matches(programLaneCount lanes: Int, subwooferCount subs: Int?) -> Bool {
        programLaneCount == lanes && (subs ?? 0) == subwooferCount && design.laneCount == sourceLaneCount
    }

    /// Whole frames of each main lane's delay at `sampleRate` (only non-zero delays).
    func delayFrames(sampleRate: Double) throws -> [Int: UInt32] {
        var result: [Int: UInt32] = [:]
        for delay in laneDelays {
            let frames = (delay.seconds * sampleRate).rounded()
            guard frames <= Double(N60_GRAPH_MAX_DELAY_FRAMES) else {
                throw RoomCorrectionLaneInstallError.delayTooLong(lane: delay.lane)
            }
            if frames > 0 { result[delay.lane] = UInt32(frames) }
        }
        return result
    }

    /// Mixed phase is offered when the plan's declared latency fits the mode's budget at this rate (note 8). Minimum
    /// phase has no budget to exceed.
    static func latencyFits(_ plan: RoomCorrectionLanePlan, mode: RoomCorrectionLatencyMode) -> Bool {
        guard mode.isMixedPhase else { return true }
        return Double(plan.declaredLatencyFrames) <= mode.budgetSeconds * plan.sampleRate + 1
    }
}

enum RoomCorrectionLaneInstallError: Error, Equatable, LocalizedError {
    case invalidLayout
    case laneOutOfRange(Int)
    case duplicateLane(Int)
    case invalidDelay(Int)
    case delayTooLong(lane: Int)

    var errorDescription: String? {
        switch self {
        case .invalidLayout: return "The stored correction does not describe a valid speaker layout."
        case .laneOutOfRange(let lane): return "Lane \(lane) is outside the stored speaker layout."
        case .duplicateLane(let lane): return "Lane \(lane) appears twice in the stored correction."
        case .invalidDelay(let lane): return "Lane \(lane) has an invalid alignment delay."
        case .delayTooLong(let lane): return "The alignment delay on lane \(lane) exceeds the graph's delay limit."
        }
    }
}

/// Why a stored correction is not shaping the sound right now. Playback goes on uncorrected (Q9, owner 1 Nov 2026).
enum RoomCorrectionInactiveReason: Equatable, Sendable {
    case needsSpeakerProfile
    case layoutChanged
    case needsUnifiedGraph
    case synthesisFailed(rate: Double)

    var message: String {
        switch self {
        case .needsSpeakerProfile:
            return "This correction was measured for your speaker profile. Turn the profile on to use it."
        case .layoutChanged:
            return "The speaker layout changed since this correction was measured. Measure and correct again."
        case .needsUnifiedGraph:
            return "This correction needs the unified graph renderer, which is off."
        case .synthesisFailed(let rate):
            return "The correction filters could not be built for \(Int(rate.rounded())) Hz, so playback is uncorrected."
        }
    }
}

extension RoomCorrectionConfiguration {
    /// True when the stereo kernel's convolver carries the correction (a stored FIR, not a lane plan).
    var isActiveOnStereoKernel: Bool { enabled && lanes == nil }
}

extension AudioOutputDevice {
    /// The standard rates the device exposes, with its nominal rate: every rate a lane-plan correction can run at.
    static let standardSampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    var correctionSampleRates: [Double] {
        var rates = Self.standardSampleRates.filter { supports(sampleRate: $0) }
        if !rates.contains(where: { abs($0 - nominalSampleRate) < 0.5 }) { rates.append(nominalSampleRate) }
        return rates.sorted()
    }
}
