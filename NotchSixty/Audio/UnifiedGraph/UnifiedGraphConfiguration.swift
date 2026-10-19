import Foundation

/// One PEQ section for the core stage (types 0 to 7 of `N60BiquadFilterType`).
struct UnifiedGraphPEQSection: Equatable, Sendable {
    var type: Int
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
}

/// One program lane of a speaker graph.
struct UnifiedGraphLane: Equatable, Sendable {
    /// Linear gain applied before the lane's EQ (calibration trim, LFE in-band gain).
    var preGain: Float = 1
    /// Linear gain applied after bass management (output, balance, master).
    var outputGain: Float = 1
    var delayMilliseconds: Double = 0
    var eq: [UnifiedGraphPEQSection] = []
}

struct UnifiedGraphSubwoofer: Equatable, Sendable {
    /// Bass-management sub gain plus the sub's own calibration gain.
    var gainDB: Double = 0
    var polarityInverted = false
    var delayMilliseconds: Double = 0
    var eq: [UnifiedGraphPEQSection] = []
}

struct UnifiedGraphBassManagement: Equatable, Sendable {
    var crossoverHz: Double = 80
    var redirectDB: Double = 0
    /// Program lane of the LFE channel, or nil when the layout has none.
    var lfeLane: Int?
    var lfeLowPassHz: Double = 120
    var lfeGainDB: Double = 10
    var subwoofers: [UnifiedGraphSubwoofer]
}

struct UnifiedGraphProtection: Equatable, Sendable {
    var limiterEnabled = true
    var ceilingDB: Double
    var attackMilliseconds: Double
    var releaseMilliseconds: Double
    var lookAheadMilliseconds: Double
    var truePeakGuard: Bool
    var oversampling: Int
}

/// What the engine wants rendered: program lanes (and optional sub lanes) in the shipping
/// engine's terms. `UnifiedGraphConfiguration.makeSpec()` is the single place that decides the
/// stage list, so the stereo hook, the multichannel path and the tests all agree.
struct UnifiedGraphConfiguration: Equatable, Sendable {
    var sampleRate: Double
    var maxBlockFrames: UInt32 = 65_536
    var lanes: [UnifiedGraphLane]
    var inputGain: Float = 1
    var bassManagement: UnifiedGraphBassManagement?
    var protection: UnifiedGraphProtection?

    var subwooferCount: Int { bassManagement?.subwoofers.count ?? 0 }
    var channelCount: Int { lanes.count + subwooferCount }

    static let maxSubwoofers = 8

    func makeSpec() throws -> UnifiedGraphSpec {
        guard sampleRate >= N60_GRAPH_MIN_SAMPLE_RATE, sampleRate <= N60_GRAPH_MAX_SAMPLE_RATE else {
            throw UnifiedGraphError.invalidConfiguration("sample rate")
        }
        let programLanes = lanes.count
        guard programLanes >= 1, channelCount <= Int(N60_GRAPH_MAX_CHANNELS),
              subwooferCount <= Self.maxSubwoofers else {
            throw UnifiedGraphError.invalidConfiguration("channel count")
        }
        guard inputGain > 0, inputGain <= 10_000 else {
            throw UnifiedGraphError.invalidConfiguration("input gain")
        }
        let all = N60_LANE_ALL
        var stages: [UnifiedGraphStageSpec] = []
        func add(_ kind: n60_stage_kind, _ id: UInt32, lane: UInt32 = 0, mask: UInt64 = 0,
                 capacity: UInt32 = 0, params: [Float] = []) {
            stages.append(UnifiedGraphStageSpec(
                kind: kind.rawValue, stageId: id, laneA: lane, laneMask: mask,
                capacityFrames: capacity, params: params
            ))
        }
        add(N60_STAGE_SANITISE, N60_LSTAGE_SANITISE, lane: all)
        add(N60_STAGE_METER_IN, N60_LSTAGE_METER_IN, lane: all)
        add(N60_STAGE_GAIN, N60_LSTAGE_INPUT_GAIN, lane: all, params: [inputGain])
        for (index, lane) in lanes.enumerated() {
            guard lane.preGain > 0, lane.preGain <= 10_000, lane.outputGain > 0,
                  lane.outputGain <= 10_000 else {
                throw UnifiedGraphError.invalidConfiguration("lane gain")
            }
            add(N60_STAGE_GAIN, Self.preGainStageBase + UInt32(index), lane: UInt32(index),
                params: [lane.preGain])
        }
        for (index, lane) in lanes.enumerated() where !lane.eq.isEmpty {
            add(N60_STAGE_PEQ, N60_LSTAGE_PEQ_LANE + UInt32(index), lane: UInt32(index),
                params: try Self.peqParameters(lane.eq))
        }
        add(N60_STAGE_METER_OUT, N60_LSTAGE_METER_OUT, lane: all)

        if let bass = bassManagement {
            let lfe = bass.lfeLane
            var mainMask: UInt64 = 0
            for index in 0..<programLanes where index != lfe { mainMask |= UInt64(1) << UInt64(index) }
            add(N60_STAGE_BASS_MGMT, Self.bassStageId, mask: mainMask,
                params: try Self.bassParameters(bass, firstSubLane: programLanes))
        }
        for (index, lane) in lanes.enumerated() {
            add(N60_STAGE_OUTPUT_GAIN, N60_LSTAGE_OUTPUT_GAIN + UInt32(index), lane: UInt32(index),
                params: [lane.outputGain])
        }
        for (index, lane) in lanes.enumerated() {
            if let frames = try Self.delayFrames(lane.delayMilliseconds, sampleRate: sampleRate) {
                add(N60_STAGE_DELAY, Self.delayStageBase + UInt32(index), lane: UInt32(index),
                    capacity: frames, params: [Float(frames)])
            }
        }
        for (index, sub) in (bassManagement?.subwoofers ?? []).enumerated() {
            let laneIndex = programLanes + index
            if let frames = try Self.delayFrames(sub.delayMilliseconds, sampleRate: sampleRate) {
                add(N60_STAGE_DELAY, Self.delayStageBase + UInt32(laneIndex), lane: UInt32(laneIndex),
                    capacity: frames, params: [Float(frames)])
            }
        }
        if let protection {
            var mask: UInt64 = 0
            for index in 0..<programLanes { mask |= UInt64(1) << UInt64(index) }
            add(N60_STAGE_PROTECTION, N60_LSTAGE_PROTECTION, mask: mask, params: [
                protection.limiterEnabled ? 1 : 0, Float(protection.ceilingDB), Float(protection.attackMilliseconds),
                Float(protection.releaseMilliseconds), Float(protection.lookAheadMilliseconds),
                protection.truePeakGuard ? 1 : 0, Float(protection.oversampling),
            ])
        }
        add(N60_STAGE_FINAL_SANITISE, N60_LSTAGE_FINAL_SANITISE, lane: all)
        add(N60_STAGE_FINAL_METER, N60_LSTAGE_FINAL_METER, lane: all)
        return UnifiedGraphSpec(
            sampleRate: sampleRate, maxBlockFrames: maxBlockFrames,
            inputChannels: UInt32(channelCount), outputChannels: UInt32(channelCount),
            stages: stages
        )
    }

    static let preGainStageBase: UInt32 = 400
    static let delayStageBase: UInt32 = 500
    static let bassStageId: UInt32 = 90

    private static func delayFrames(_ milliseconds: Double, sampleRate: Double) throws -> UInt32? {
        guard milliseconds.isFinite, milliseconds >= 0 else {
            throw UnifiedGraphError.invalidConfiguration("delay")
        }
        let frames = (milliseconds * 0.001 * sampleRate).rounded()
        guard frames <= Double(N60_GRAPH_MAX_DELAY_FRAMES) else {
            throw UnifiedGraphError.invalidConfiguration("delay")
        }
        return frames >= 1 ? UInt32(frames) : nil
    }

    private static func peqParameters(_ sections: [UnifiedGraphPEQSection]) throws -> [Float] {
        guard sections.count <= Int(N60_PEQ_MAX_SECTIONS) else {
            throw UnifiedGraphError.unsupportedConfiguration("more than 16 EQ sections")
        }
        var result: [Float] = []
        result.reserveCapacity(sections.count * 4)
        for section in sections {
            guard (0...7).contains(section.type), (-24.0...24.0).contains(section.gainDB) else {
                throw UnifiedGraphError.unsupportedConfiguration("EQ section type or gain")
            }
            result += [Float(section.type), Float(section.frequencyHz), Float(section.gainDB), Float(section.q)]
        }
        return result
    }

    private static func bassParameters(
        _ bass: UnifiedGraphBassManagement,
        firstSubLane: Int
    ) throws -> [Float] {
        let subs = bass.subwoofers
        guard (1...maxSubwoofers).contains(subs.count) else {
            throw UnifiedGraphError.invalidConfiguration("subwoofer count")
        }
        for sub in subs {
            guard sub.eq.count <= 8, (-60.0...24.0).contains(sub.gainDB) else {
                throw UnifiedGraphError.unsupportedConfiguration("sub gain or EQ section count")
            }
        }
        var p: [Float] = [
            Float(bass.crossoverHz), Float(bass.redirectDB), Float(firstSubLane),
            Float(bass.lfeLane ?? -1), Float(bass.lfeLowPassHz), Float(bass.lfeGainDB),
            Float(subs[0].gainDB), subs[0].polarityInverted ? 1 : 0, Float(subs[0].eq.count),
        ]
        p += try peqParameters(subs[0].eq)
        if subs.count > 1 {
            // Default mode (w < 8): each sub is scaled by 1/N, matching the shipping redirect route.
            p.append(Float(subs.count - 1))
            for index in 1..<subs.count {
                p += [Float(firstSubLane + index), Float(subs[index].gainDB),
                      subs[index].polarityInverted ? 1 : 0, Float(subs[index].eq.count)]
                p += try peqParameters(subs[index].eq)
            }
        }
        return p
    }
}
