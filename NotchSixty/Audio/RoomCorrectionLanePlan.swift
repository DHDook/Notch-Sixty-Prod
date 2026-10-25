import Foundation

// E10 S4: rate-independent room-correction designs on any layout (design note 6).
//
// A design is stored as grid designs (one per lane, independent of sample rate). When a design is
// activated, and whenever the device rate changes, taps are synthesised for that rate here, on a
// control or worker thread, cached per rate, and handed to the graph as an immutable plan that is
// published through the normal snapshot path. Nothing here runs on an audio thread and the engine
// never reads the feature flag: the caller passes `unifiedGraphEnabled`.
//
// Allocation: every call allocates (offline). Synchronisation: the cache holds one lock around
// dictionary access only; synthesis runs outside it. Latency: every lane of a plan reports one
// declared latency (the plan refuses mixed latencies). Sample rate: any rate the core supports,
// 44.1 to 384 kHz. Channels: up to N60_LAYOUT_MAX_CHANNELS lanes, sub lanes included (ROOM_FIR
// sits after bass management in the graph).

/// One lane's correction on the rate-independent grid.
struct RoomCorrectionLaneDesign: Equatable, Codable, Sendable {
    var lane: Int
    var grid: RoomCorrectionGridDesign
}

/// A design for a whole layout: one grid design per corrected lane.
struct RoomCorrectionMultiLaneDesign: Equatable, Codable, Sendable {
    var id: UUID
    var latencyMode: RoomCorrectionLatencyMode
    var laneCount: Int
    var lanes: [RoomCorrectionLaneDesign]

    init(id: UUID = UUID(), latencyMode: RoomCorrectionLatencyMode, laneCount: Int, lanes: [RoomCorrectionLaneDesign]) {
        self.id = id
        self.latencyMode = latencyMode
        self.laneCount = laneCount
        self.lanes = lanes
    }
}

/// One ROOM_FIR stage: the lanes that share one tap set.
struct RoomCorrectionLaneStage: Equatable, Sendable {
    var laneMask: UInt64
    var taps: [Float]
}

/// The taps of a design at one sample rate, grouped into one stage per distinct tap set.
struct RoomCorrectionLanePlan: Equatable, Sendable {
    var designID: UUID
    var sampleRate: Double
    var stages: [RoomCorrectionLaneStage]
    /// The declared group delay shared by every stage (reported by the graph, never applied).
    var declaredLatencyFrames: UInt32
    var laneCount: Int

    /// Every lane a stage corrects.
    var coveredMask: UInt64 { stages.reduce(0) { $0 | $1.laneMask } }
}

enum RoomCorrectionLanePlanError: Error, Equatable, LocalizedError {
    case legacyKernel
    case noLanes
    case laneOutOfRange(Int)
    case duplicateLane(Int)
    case tapsExceedSingleBand(required: Int, maximum: Int)
    case synthesis(Int32)

    var errorDescription: String? {
        switch self {
        case .legacyKernel:
            return "Mixed-phase and multichannel room correction need the unified graph; the legacy kernel (e6.legacy-kernel) runs stereo minimum-phase correction only."
        case .noLanes:
            return "The design has no corrected lanes."
        case .laneOutOfRange(let lane):
            return "Lane \(lane) is outside the layout."
        case .duplicateLane(let lane):
            return "Lane \(lane) appears twice in the design."
        case let .tapsExceedSingleBand(required, maximum):
            return "This mode needs \(required) taps at this rate; the single-band room stage holds \(maximum). Choose a shorter latency budget or the video mode."
        case .synthesis(let status):
            return "Filter synthesis failed (status \(status))."
        }
    }
}

/// Synthesises a rate-independent design for a device rate and caches the result per rate.
final class RoomCorrectionRateCache: @unchecked Sendable {
    /// The longest single-band ROOM_FIR (graph limit).
    static let maximumSingleBandTaps = 32_768
    /// Stage ids of the plan's stages in the graph: base + stage index.
    static let stageIDBase: UInt32 = 2_400

    private struct Key: Hashable {
        var id: UUID
        var mode: RoomCorrectionLatencyMode
        var rate: Int
    }

    private let lock = NSLock()
    private var plans: [Key: RoomCorrectionLanePlan] = [:]
    private(set) var synthesisCount = 0

    init() {}

    private static func rateKey(_ rate: Double) -> Int { Int((rate * 10).rounded()) }

    /// The plan for `rate`, from the cache when this design has been synthesised at that rate before.
    /// Throws `.legacyKernel` (with a user-facing reason) when `unifiedGraphEnabled` is false.
    func plan(
        for design: RoomCorrectionMultiLaneDesign, sampleRate: Double, unifiedGraphEnabled: Bool = true
    ) throws -> RoomCorrectionLanePlan {
        guard unifiedGraphEnabled else { throw RoomCorrectionLanePlanError.legacyKernel }
        guard !design.lanes.isEmpty else { throw RoomCorrectionLanePlanError.noLanes }
        var seen = Set<Int>()
        for item in design.lanes {
            guard item.lane >= 0, item.lane < design.laneCount, item.lane < Int(N60_LAYOUT_MAX_CHANNELS) else {
                throw RoomCorrectionLanePlanError.laneOutOfRange(item.lane)
            }
            guard seen.insert(item.lane).inserted else { throw RoomCorrectionLanePlanError.duplicateLane(item.lane) }
        }
        let key = Key(id: design.id, mode: design.latencyMode, rate: Self.rateKey(sampleRate))
        lock.lock()
        let cached = plans[key]
        lock.unlock()
        if let cached { return cached }

        let required = Int(n60_correct_latency_mode_tap_count(design.latencyMode.rawValue, sampleRate))
        guard required <= Self.maximumSingleBandTaps else {
            throw RoomCorrectionLanePlanError.tapsExceedSingleBand(required: required, maximum: Self.maximumSingleBandTaps)
        }

        // Lanes with the same grid share one synthesis and one stage.
        var groups: [(grid: RoomCorrectionGridDesign, lanes: [Int])] = []
        for item in design.lanes.sorted(by: { $0.lane < $1.lane }) {
            if let index = groups.firstIndex(where: { $0.grid == item.grid }) {
                groups[index].lanes.append(item.lane)
            } else {
                groups.append((item.grid, [item.lane]))
            }
        }
        var stages: [RoomCorrectionLaneStage] = []
        var latency: UInt32?
        for group in groups {
            let result: (taps: [Float], declaredLatencyFrames: UInt32)
            do {
                result = try RoomCorrectionCore.synthesize(group.grid, sampleRate: sampleRate, mode: design.latencyMode)
            } catch RoomCorrectionCore.CoreError.status(let status) {
                throw RoomCorrectionLanePlanError.synthesis(status)
            }
            // The latency is a function of the mode and rate, so it is equal across groups.
            latency = latency ?? result.declaredLatencyFrames
            let mask = group.lanes.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64($1)) }
            stages.append(RoomCorrectionLaneStage(laneMask: mask, taps: result.taps))
        }
        let plan = RoomCorrectionLanePlan(
            designID: design.id, sampleRate: sampleRate, stages: stages,
            declaredLatencyFrames: latency ?? 0, laneCount: design.laneCount)
        lock.lock()
        plans[key] = plan
        synthesisCount += groups.count
        lock.unlock()
        return plan
    }

    /// Synthesises on a background task, for the rate-change path (never on the main actor or an audio thread).
    func planAsync(
        for design: RoomCorrectionMultiLaneDesign, sampleRate: Double, unifiedGraphEnabled: Bool = true
    ) async throws -> RoomCorrectionLanePlan {
        try await Task.detached(priority: .userInitiated) { [self] in
            try plan(for: design, sampleRate: sampleRate, unifiedGraphEnabled: unifiedGraphEnabled)
        }.value
    }

    func invalidate(designID: UUID) {
        lock.lock()
        plans = plans.filter { $0.key.id != designID }
        lock.unlock()
    }
}
