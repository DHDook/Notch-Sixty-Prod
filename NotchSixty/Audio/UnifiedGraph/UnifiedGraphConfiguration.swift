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
    /// Whole frames of delay added to `delayMilliseconds` (the kernel's integer inter-channel taps).
    var delayFrames: UInt32 = 0
    /// Total fractional (Thiran) delay in frames from the kernel's inter-channel delay; replaces `delayFrames`
    /// with a FRAC_DELAY stage when set.
    var fractionalDelayFrames: Double?
    var eq: [UnifiedGraphPEQSection] = []
}

extension UnifiedGraphLane {
    /// The kernel's integer inter-channel taps. The kernel applies them per lane without adding
    /// them to its snapshot latency, so they are not a path difference to align across a fade.
    var interChannelTapFrames: UInt32 {
        let fractional = fractionalDelayFrames ?? 0
        guard fractional.isFinite, fractional >= 0, fractional < 8190 else { return delayFrames }
        return delayFrames + UInt32(fractional.rounded(.down))
    }
}

/// E6 S8d: the taps of a kernel convolver program (program FIR, room correction or speaker IR), as the control plane
/// prepared them. `right == nil` means the kernel uses `left` on both channels.
struct UnifiedGraphFIRProgram: Equatable, Sendable {
    var generation: UInt64
    var left: [Float]
    var right: [Float]?
    /// The filter's own group delay, reported in the snapshot latency but never applied.
    var declaredLatencyFrames: UInt32
}

/// Stereo-only stages the kernel runs between the EQ and the output gain, as raw core
/// parameter lists (see `n60/graph.h`). Every list was verified against the kernel's own
/// snapshot setters by `N60UnifiedGraphEligibility.h` before it gets here.
struct UnifiedGraphStereoStages: Equatable, Sendable {
    /// Mid/Side EQ: the EQ sections run on (mid, side) instead of (left, right).
    var midSideEQ = false
    /// Spectral denoiser (runs before the EQ, as in the kernel).
    var denoiser: [Float]?
    /// Dynamic EQ (runs after the EQ sections).
    var dynamicEQ: [Float]?
    var compressor: [Float]?
    var expander: [Float]?
    var ambient: [Float]?
    var symmetryPosition: Float?
    var crossfeedAmount: Float?
    var crosstalk: [Float]?
    var pauseGate: [Float]?
    /// Program convolution (kernel: after the EQ, before the compressor).
    var programFIR: UnifiedGraphFIRProgram?
    /// Room correction and speaker IR (kernel: after bass management's slot, before ambient and the core dynamics).
    var roomFIR: UnifiedGraphFIRProgram?
    var speakerIR: UnifiedGraphFIRProgram?
    /// Stereo crossover and bass management of the kernel's snapshot (core stage parameters, 8 values; E6 S8d group 4).
    var crossover: [Float]?

    var isEmpty: Bool { self == UnifiedGraphStereoStages() }
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
    /// ABI v12 extension: the soft clipper and the gain rider (nil leaves the stage at its seven-parameter form).
    var clipper: UnifiedGraphSoftClipper?
    var rider: UnifiedGraphGainRider?
}

struct UnifiedGraphSoftClipper: Equatable, Sendable {
    var enabled: Bool
    var driveDB: Double
    var thresholdDB: Double
    var knee: Double
    var curve: Int
    var autoCompensate: Bool
    var asymmetryDB: Double
}

struct UnifiedGraphGainRider: Equatable, Sendable {
    var enabled: Bool
    var targetDB: Double
    var maxDB: Double
    var speed: Int
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
    /// Two-lane configurations only.
    var stereoStages = UnifiedGraphStereoStages()
    /// The kernel denoiser's view while it is off (ignored when the denoiser stage is present).
    var denoiserPark: UnifiedGraphDenoiserPark?

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
        let stereo = stereoStages
        if !stereo.isEmpty, programLanes != 2 {
            throw UnifiedGraphError.unsupportedConfiguration("stereo stages need two lanes")
        }
        if stereo.ambient != nil, stereo.compressor != nil || stereo.expander != nil {
            // The kernel runs ambient before its dynamics; the core runs them the other way round.
            throw UnifiedGraphError.unsupportedConfiguration("ambient with compressor or expander")
        }
        if stereo.programFIR != nil, stereo.dynamicEQ != nil || stereo.midSideEQ {
            // The kernel runs the convolution inside the mid/side pair and before the dynamic EQ.
            throw UnifiedGraphError.unsupportedConfiguration("program FIR with mid/side or dynamic EQ")
        }
        let hasPostConvolver = stereo.roomFIR != nil || stereo.speakerIR != nil
        if hasPostConvolver, stereo.expander != nil {
            throw UnifiedGraphError.unsupportedConfiguration("expander with room or speaker IR")
        }
        if hasPostConvolver, !(bassManagement?.subwoofers.isEmpty ?? true) {
            // Where the kernel feeds the sub relative to the room and speaker convolvers is not reproduced.
            throw UnifiedGraphError.unsupportedConfiguration("room or speaker IR with subwoofers")
        }
        let programMask: UInt64 = (UInt64(1) << UInt64(programLanes)) - 1
        var stages: [UnifiedGraphStageSpec] = []
        func add(_ kind: n60_stage_kind, _ id: UInt32, lane: UInt32 = 0, mask: UInt64 = 0,
                 capacity: UInt32 = 0, params: [Float] = []) {
            stages.append(UnifiedGraphStageSpec(
                kind: kind.rawValue, stageId: id, laneA: lane, laneMask: mask,
                capacityFrames: capacity, params: params
            ))
        }
        /// One FIR stage when both channels share taps, else one per lane (the core applies identical taps to every
        /// lane a stage selects).
        func addFIR(_ kind: n60_stage_kind, _ program: UnifiedGraphFIRProgram, baseId: UInt32) throws {
            guard !program.left.isEmpty, program.left.count <= 32_768,
                  program.right == nil || program.right?.count == program.left.count,
                  program.declaredLatencyFrames <= N60_GRAPH_MAX_DELAY_FRAMES else {
                throw UnifiedGraphError.unsupportedConfiguration("FIR taps")
            }
            if let right = program.right {
                add(kind, baseId, lane: 0, capacity: program.declaredLatencyFrames, params: program.left)
                add(kind, baseId + 1, lane: 1, capacity: program.declaredLatencyFrames, params: right)
            } else {
                add(kind, baseId, mask: programMask, capacity: program.declaredLatencyFrames, params: program.left)
            }
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
        if stereo.dynamicEQ != nil, stereo.midSideEQ {
            // The kernel runs the dynamic EQ after the mid/side decode; the core runs it before.
            throw UnifiedGraphError.unsupportedConfiguration("dynamic EQ with mid/side EQ")
        }
        if let params = stereo.denoiser {
            add(N60_STAGE_DENOISER, Self.denoiserStageId, mask: programMask, params: params)
        }
        let msActive = stereo.midSideEQ && lanes.contains(where: { !$0.eq.isEmpty })
        if msActive {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_MS_ENCODE.rawValue, stageId: N60_LSTAGE_MS_ENCODE, laneA: 0, laneB: 1))
        }
        for (index, lane) in lanes.enumerated() where !lane.eq.isEmpty {
            add(N60_STAGE_PEQ, N60_LSTAGE_PEQ_LANE + UInt32(index), lane: UInt32(index),
                params: try Self.peqParameters(lane.eq))
        }
        if let params = stereo.dynamicEQ {
            add(N60_STAGE_DYN_EQ, Self.dynamicEQStageId, mask: programMask, params: params)
        }
        if msActive {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_MS_DECODE.rawValue, stageId: N60_LSTAGE_MS_DECODE, laneA: 0, laneB: 1))
        }
        if let program = stereo.programFIR {
            try addFIR(N60_STAGE_FIR, program, baseId: Self.programFIRStageId)
        }
        if let params = stereo.compressor, !hasPostConvolver {
            add(N60_STAGE_COMPRESSOR, Self.compressorStageId, mask: programMask, params: params)
        }
        if let params = stereo.expander {
            add(N60_STAGE_EXPANDER, Self.expanderStageId, mask: programMask, params: params)
        }
        add(N60_STAGE_METER_OUT, N60_LSTAGE_METER_OUT, lane: all)

        if let params = stereo.crossover {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_STEREO_CROSSOVER.rawValue, stageId: Self.crossoverStageId, laneA: 0, laneB: 1,
                params: params))
        }
        if let bass = bassManagement {
            let lfe = bass.lfeLane
            var mainMask: UInt64 = 0
            for index in 0..<programLanes where index != lfe { mainMask |= UInt64(1) << UInt64(index) }
            add(N60_STAGE_BASS_MGMT, Self.bassStageId, mask: mainMask,
                params: try Self.bassParameters(bass, firstSubLane: programLanes))
        }
        if let room = stereo.roomFIR {
            try addFIR(N60_STAGE_ROOM_FIR, room, baseId: Self.roomFIRStageId)
        }
        if let speaker = stereo.speakerIR {
            try addFIR(N60_STAGE_SPEAKER_IR, speaker, baseId: Self.speakerIRStageId)
        }
        if let params = stereo.ambient {
            add(N60_STAGE_AMBIENT, Self.ambientStageId, mask: programMask, params: params)
        }
        if let params = stereo.compressor, hasPostConvolver {
            // The kernel runs its core dynamics after the room and speaker convolvers.
            add(N60_STAGE_CORE_DYNAMICS, Self.compressorStageId, mask: programMask, params: params)
        }
        if let position = stereo.symmetryPosition {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_SYMMETRY.rawValue, stageId: Self.symmetryStageId, laneA: 0, laneB: 1,
                params: [position]))
        }
        if let amount = stereo.crossfeedAmount {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_CROSSFEED.rawValue, stageId: Self.crossfeedStageId, laneA: 0, laneB: 1,
                params: [amount]))
        }
        if let params = stereo.crosstalk {
            stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_CROSSTALK.rawValue, stageId: Self.crosstalkStageId, laneA: 0, laneB: 1,
                params: params))
        }
        for (index, lane) in lanes.enumerated() {
            add(N60_STAGE_OUTPUT_GAIN, N60_LSTAGE_OUTPUT_GAIN + UInt32(index), lane: UInt32(index),
                params: [lane.outputGain])
        }
        if let params = stereo.pauseGate {
            add(N60_STAGE_PAUSE_GATE, Self.pauseGateStageId, mask: programMask, params: params)
        }
        for (index, lane) in lanes.enumerated() {
            if let total = lane.fractionalDelayFrames {
                guard total.isFinite, total >= 0, total < 8190 else {
                    throw UnifiedGraphError.invalidConfiguration("fractional delay")
                }
                add(N60_STAGE_FRAC_DELAY, Self.delayStageBase + UInt32(index), lane: UInt32(index),
                    params: [Float(total.rounded(.down)), Float(total - total.rounded(.down))])
            } else if let frames = try Self.delayFrames(lane.delayMilliseconds, extraFrames: lane.delayFrames,
                                                 sampleRate: sampleRate) {
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
            var params: [Float] = [
                protection.limiterEnabled ? 1 : 0, Float(protection.ceilingDB), Float(protection.attackMilliseconds),
                Float(protection.releaseMilliseconds), Float(protection.lookAheadMilliseconds),
                protection.truePeakGuard ? 1 : 0, Float(protection.oversampling),
            ]
            if protection.clipper != nil || protection.rider != nil {
                let c = protection.clipper ?? UnifiedGraphSoftClipper(
                    enabled: false, driveDB: 0, thresholdDB: 0, knee: 0, curve: 0, autoCompensate: false, asymmetryDB: 0)
                let r = protection.rider ?? UnifiedGraphGainRider(enabled: false, targetDB: 2, maxDB: 6, speed: 1)
                params += [
                    c.enabled ? 1 : 0, Float(c.driveDB), Float(c.thresholdDB), Float(c.knee), Float(c.curve),
                    c.autoCompensate ? 1 : 0, Float(c.asymmetryDB),
                    r.enabled ? 1 : 0, Float(r.targetDB), Float(r.maxDB), Float(r.speed),
                ]
            }
            add(N60_STAGE_PROTECTION, N60_LSTAGE_PROTECTION, mask: mask, params: params)
        }
        add(N60_STAGE_FINAL_SANITISE, N60_LSTAGE_FINAL_SANITISE, lane: all)
        add(N60_STAGE_FINAL_METER, N60_LSTAGE_FINAL_METER, lane: all)
        return UnifiedGraphSpec(
            sampleRate: sampleRate, maxBlockFrames: maxBlockFrames,
            inputChannels: UInt32(channelCount), outputChannels: UInt32(channelCount),
            stages: stages,
            denoiserPark: stereo.denoiser == nil ? denoiserPark : nil
        )
    }

    static let preGainStageBase: UInt32 = 400
    static let delayStageBase: UInt32 = 500
    static let bassStageId: UInt32 = 90
    static let compressorStageId: UInt32 = 600
    static let expanderStageId: UInt32 = 601
    static let ambientStageId: UInt32 = 602
    static let symmetryStageId: UInt32 = 603
    static let crossfeedStageId: UInt32 = 604
    static let crosstalkStageId: UInt32 = 605
    static let pauseGateStageId: UInt32 = 606
    static let denoiserStageId: UInt32 = 607
    static let dynamicEQStageId: UInt32 = 608
    static let crossoverStageId: UInt32 = 616
    /// FIR stages take two consecutive ids (left, right) when the channels differ.
    static let programFIRStageId: UInt32 = 610
    static let roomFIRStageId: UInt32 = 612
    static let speakerIRStageId: UInt32 = 614

    private static func delayFrames(
        _ milliseconds: Double, extraFrames: UInt32 = 0, sampleRate: Double
    ) throws -> UInt32? {
        guard milliseconds.isFinite, milliseconds >= 0 else {
            throw UnifiedGraphError.invalidConfiguration("delay")
        }
        let frames = (milliseconds * 0.001 * sampleRate).rounded() + Double(extraFrames)
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
