import Foundation

/// E6 S9a: how the graph orders the program DSP (EQ, dynamics, FIR, room, image) against the rest.
enum UnifiedGraphOrderPolicy: Equatable, Sendable {
    /// Two-lane stereo as the kernel orders it. Every guard of `UnifiedGraphConfiguration.makeSpec` stays.
    case kernelParity
    /// The core's own stage order, used by N-channel and binaural graphs. Four kernel-order guards are lifted
    /// (program FIR with dynamic EQ, expander with room or IR, room or IR with subs, dynamic EQ with M/S).
    /// Ambient with compressor or expander stays rejected.
    case canonical
}

struct UnifiedGraphLanePair: Equatable, Sendable {
    var a: Int
    var b: Int
}

/// Which lanes of a program layout pair up, and where the centre, LFE and front pair sit (from
/// `n60_layout_describe`, so Swift and the core agree on pairing).
struct UnifiedGraphLayoutShape: Equatable, Sendable {
    var laneCount: Int
    var pairs: [UnifiedGraphLanePair]
    var centerLane: Int?
    var lfeLane: Int?
    var frontLeft: Int?
    var frontRight: Int?

    init?(layout: n60_layout) {
        var layout = layout
        var info = n60_layout_info()
        info.structSize = UInt32(MemoryLayout<n60_layout_info>.size)
        guard n60_layout_describe(&layout, &info) == N60_STATUS_OK else { return nil }
        laneCount = Int(layout.channelCount)
        var pairA = info.pairLaneA
        var pairB = info.pairLaneB
        var found: [UnifiedGraphLanePair] = []
        withUnsafeBytes(of: &pairA) { rawA in
            withUnsafeBytes(of: &pairB) { rawB in
                let a = rawA.bindMemory(to: UInt32.self)
                let b = rawB.bindMemory(to: UInt32.self)
                for index in 0..<Int(info.pairCount) {
                    found.append(UnifiedGraphLanePair(a: Int(a[index]), b: Int(b[index])))
                }
            }
        }
        pairs = found
        centerLane = info.centerLane >= 0 ? Int(info.centerLane) : nil
        lfeLane = info.lfeLane >= 0 ? Int(info.lfeLane) : nil
        frontLeft = info.frontLeftLane >= 0 ? Int(info.frontLeftLane) : nil
        frontRight = info.frontRightLane >= 0 ? Int(info.frontRightLane) : nil
    }

    init?(roles: [OutputProgramRole]) {
        guard !roles.isEmpty, roles.count <= Int(N60_LAYOUT_MAX_CHANNELS) else { return nil }
        var layout = n60_layout()
        layout.structSize = UInt32(MemoryLayout<n60_layout>.size)
        layout.identifier = UInt32(N60_LAYOUT_CUSTOM.rawValue)
        layout.channelCount = UInt32(roles.count)
        withUnsafeMutableBytes(of: &layout.roles) { raw in
            let slots = raw.bindMemory(to: UInt32.self)
            for (index, role) in roles.enumerated() { slots[index] = UInt32(role.realtimeCType.rawValue) }
        }
        self.init(layout: layout)
    }

    var leftMembers: [Int] { pairs.map(\.a) }
    var rightMembers: [Int] { pairs.map(\.b) }
}

/// E6 S9a: the program DSP the stereo engine would apply (EQ, dynamics, FIR, denoiser, balance, headroom, image,
/// inter-channel delay, room correction, speaker IR), as the verified two-lane stage lists, ready to be mapped onto
/// the lane sets of an N-channel or binaural layout (decision D2 in `docs/epics/E6.md`).
///
/// Lane sets: linked EQ covers every non-LFE lane; independent EQ covers pair members only (centre and LFE get none);
/// M/S encodes and decodes per layout pair and applies the mid curve to unpaired non-LFE lanes unencoded.
/// Latency: a program FIR adds `firPartitionFrames` plus its declared latency, a denoiser adds its FFT size, and
/// delta or delay stages align the lanes they do not cover. Everything is built off the realtime thread; the
/// stage list is immutable once swapped in, and a rate or layout change rebuilds it (reset). Rates 44.1 to 384 kHz.
struct UnifiedGraphProgramDSP: Equatable, Sendable {
    enum EQMode: Equatable, Sendable { case linked, independent, midSide }

    var shape: UnifiedGraphLayoutShape
    var eqMode: EQMode
    /// The stereo lanes: `eq` curves (left/right, or mid/side), `outputGain` = balance, inter-channel delays.
    var left: UnifiedGraphLane
    var right: UnifiedGraphLane
    /// Automatic headroom (input gain stays with the engine's own gain path).
    var inputGain: Float
    var stages: UnifiedGraphStereoStages
    /// Soft clipper, gain rider, limiter and true-peak guard of the stereo engine.
    var protection: UnifiedGraphProtection?
    /// Binaural: the layout lanes are virtual speakers, so only pre-binaural stages, balance on the ears and the
    /// pause gate apply.
    var virtualSpeakers: Bool

    init(
        stereo: UnifiedGraphConfiguration,
        shape: UnifiedGraphLayoutShape,
        eqMode: EQMode,
        virtualSpeakers: Bool = false
    ) {
        self.shape = shape
        self.eqMode = eqMode
        left = stereo.lanes[0]
        right = stereo.lanes[1]
        inputGain = stereo.inputGain
        stages = stereo.stereoStages
        protection = stereo.protection
        self.virtualSpeakers = virtualSpeakers
    }

    /// Nothing for the graph to add: the spec stays exactly the calibration, bass management and system stages.
    var isNeutral: Bool {
        var rest = stages
        rest.midSideEQ = false
        func plain(_ lane: UnifiedGraphLane) -> Bool {
            guard lane.eq.isEmpty, lane.preGain == 1, lane.outputGain == 1 else { return false }
            guard lane.delayMilliseconds == 0, lane.delayFrames == 0 else { return false }
            return lane.fractionalDelayFrames == nil
        }
        guard rest.isEmpty, plain(left), plain(right), inputGain == 1 else { return false }
        return protection == nil
    }

    static let firStageBase: UInt32 = 2_000
    static let roomStageBase: UInt32 = 2_100
    static let speakerStageBase: UInt32 = 2_200
    static let headroomStageId: UInt32 = 898
    static let deltaFIRStageId: UInt32 = 899
    static let alignmentDelayBase: UInt32 = 900
    static let programPEQBase: UInt32 = 800
    static let interChannelDelayBase: UInt32 = 1_000
    static let firPartitionFrames: UInt32 = 256
    static let maxStages = 256

    private static func denoiserFFTSize(_ params: [Float]) -> UInt32 {
        let quality = params.count > 1 ? Int(params[1]) : 1
        return [1_024, 2_048, 4_096][min(max(quality, 0), 2)]
    }

    private static func mask(_ lanes: [Int]) -> UInt64 {
        lanes.reduce(into: UInt64(0)) { $0 |= UInt64(1) << UInt64($1) }
    }

    /// Adds this program DSP to `spec` (a graph of calibration, bass management, system stages, or the binaural
    /// layout graph). Throws a `UnifiedGraphFallbackReason` when a lane-set mapping is not reproducible.
    func apply(to spec: inout UnifiedGraphSpec) throws {
        guard !isNeutral else { return }
        let count = shape.laneCount
        guard count >= 1, count <= Int(N60_LAYOUT_MAX_CHANNELS), Int(spec.outputChannels) >= count else {
            throw UnifiedGraphFallbackReason.laneCountMismatch
        }
        let st = stages
        guard inputGain.isFinite, inputGain > 0, inputGain <= 10_000 else {
            throw UnifiedGraphFallbackReason.gainOutOfRange
        }
        if st.ambient != nil, st.compressor != nil || st.expander != nil {
            throw UnifiedGraphFallbackReason.unsupportedKernelStage
        }
        if eqMode == .midSide, st.programFIR != nil {
            throw UnifiedGraphFallbackReason.midSideProgramFIR
        }
        let hasPostConvolver = st.roomFIR != nil || st.speakerIR != nil
        let hasDelay = [left, right].contains {
            $0.delayMilliseconds != 0 || $0.delayFrames != 0 || $0.fractionalDelayFrames != nil
        }
        let needsFront = st.symmetryPosition != nil || st.crossfeedAmount != nil || st.crosstalk != nil
            || hasPostConvolver || hasDelay
        if needsFront {
            if virtualSpeakers { throw UnifiedGraphFallbackReason.virtualSpeakersSpeakerStage }
            guard shape.frontLeft != nil, shape.frontRight != nil else {
                throw UnifiedGraphFallbackReason.noFrontPair
            }
        }

        let lfe = shape.lfeLane
        let nonLFE = (0..<count).filter { $0 != lfe }
        let leftMembers = shape.leftMembers
        let rightMembers = shape.rightMembers
        let pairedLanes = (leftMembers + rightMembers).sorted()
        let programMask = Self.mask(Array(0..<count))

        // D2: which lanes carry the EQ-like stages, and which curve each gets.
        var covered: [Int]
        var curves: [(lane: Int, sections: [UnifiedGraphPEQSection])] = []
        switch eqMode {
        case .linked:
            covered = nonLFE
            curves = nonLFE.map { ($0, left.eq) }
        case .independent:
            covered = pairedLanes
            curves = leftMembers.map { ($0, left.eq) } + rightMembers.map { ($0, right.eq) }
        case .midSide:
            covered = nonLFE
            curves = nonLFE.map { lane in (lane, rightMembers.contains(lane) ? right.eq : left.eq) }
        }
        curves = curves.filter { !$0.sections.isEmpty }.sorted { $0.lane < $1.lane }
        let midSideActive = eqMode == .midSide && !curves.isEmpty
        if midSideActive {
            let calibrated = spec.stages.contains { stage in
                stage.kind == N60_STAGE_PEQ.rawValue && pairedLanes.contains(Int(stage.laneA))
            }
            if calibrated { throw UnifiedGraphFallbackReason.midSideWithPairCalibration }
        }
        let coveredMask = Self.mask(covered)

        var added: [UnifiedGraphStageSpec] = []
        func add(_ kind: n60_stage_kind, _ id: UInt32, lane: UInt32 = 0, laneB: UInt32 = 0, mask: UInt64 = 0,
                 capacity: UInt32 = 0, params: [Float] = []) {
            added.append(UnifiedGraphStageSpec(
                kind: kind.rawValue, stageId: id, laneA: lane, laneB: laneB, laneMask: mask,
                capacityFrames: capacity, params: params))
        }
        func addFIR(_ kind: n60_stage_kind, _ program: UnifiedGraphFIRProgram, base: UInt32,
                    sharedMask: UInt64, leftLanes: [Int], rightLanes: [Int]) throws {
            guard !program.left.isEmpty, program.left.count <= 32_768,
                  program.right == nil || program.right?.count == program.left.count,
                  program.declaredLatencyFrames <= N60_GRAPH_MAX_DELAY_FRAMES else {
                throw UnifiedGraphFallbackReason.convolutionProgramUnavailable
            }
            if let right = program.right {
                for lane in leftLanes {
                    add(kind, base + 1 + UInt32(lane), lane: UInt32(lane),
                        capacity: program.declaredLatencyFrames, params: program.left)
                }
                for lane in rightLanes {
                    add(kind, base + 1 + UInt32(lane), lane: UInt32(lane),
                        capacity: program.declaredLatencyFrames, params: right)
                }
            } else {
                add(kind, base, mask: sharedMask, capacity: program.declaredLatencyFrames, params: program.left)
            }
        }

        if inputGain != 1 {
            add(N60_STAGE_GAIN, Self.headroomStageId, lane: N60_LANE_ALL, params: [inputGain])
        }
        // Latency of what the covered lanes run through before bass management.
        var coveredLatency: UInt32 = 0
        if !covered.isEmpty {
            if let params = st.denoiser {
                add(N60_STAGE_DENOISER, UnifiedGraphConfiguration.denoiserStageId, mask: coveredMask, params: params)
                coveredLatency += Self.denoiserFFTSize(params)
            }
            if midSideActive {
                for (index, pair) in shape.pairs.enumerated() {
                    add(N60_STAGE_MS_ENCODE, N60_LSTAGE_MS_ENCODE + UInt32(index),
                        lane: UInt32(pair.a), laneB: UInt32(pair.b))
                }
            }
            for curve in curves {
                add(N60_STAGE_PEQ, Self.programPEQBase + UInt32(curve.lane), lane: UInt32(curve.lane),
                    params: try UnifiedGraphConfiguration.peqParameters(curve.sections))
            }
            if let params = st.dynamicEQ {
                add(N60_STAGE_DYN_EQ, UnifiedGraphConfiguration.dynamicEQStageId, mask: coveredMask, params: params)
            }
            if midSideActive {
                for (index, pair) in shape.pairs.enumerated() {
                    add(N60_STAGE_MS_DECODE, N60_LSTAGE_MS_DECODE + UInt32(index),
                        lane: UInt32(pair.a), laneB: UInt32(pair.b))
                }
            }
            if let program = st.programFIR {
                try addFIR(N60_STAGE_FIR, program, base: Self.firStageBase, sharedMask: coveredMask,
                           leftLanes: leftMembers, rightLanes: rightMembers)
                coveredLatency += Self.firPartitionFrames + program.declaredLatencyFrames
            }
        }
        // The core does not align latency across lanes: lanes the FIR / denoiser do not cover get a delta FIR so
        // every program lane reaches bass management with the same delay.
        let uncovered = (0..<count).filter { !covered.contains($0) }
        if coveredLatency > 0, !uncovered.isEmpty {
            let delta = Int(coveredLatency) - Int(Self.firPartitionFrames)
            guard delta >= 0, delta + 1 <= 32_768 else { throw UnifiedGraphFallbackReason.latencyAlignment }
            var taps = [Float](repeating: 0, count: delta)
            taps.append(1)
            add(N60_STAGE_FIR, Self.deltaFIRStageId, mask: Self.mask(uncovered), capacity: UInt32(delta), params: taps)
        }
        if let params = st.compressor {
            add(N60_STAGE_COMPRESSOR, UnifiedGraphConfiguration.compressorStageId, mask: programMask, params: params)
        }
        if let params = st.expander {
            add(N60_STAGE_EXPANDER, UnifiedGraphConfiguration.expanderStageId, mask: programMask, params: params)
        }
        var postLatency: UInt32 = 0
        if hasPostConvolver, let fl = shape.frontLeft, let fr = shape.frontRight {
            let frontMask = Self.mask([fl, fr])
            if let room = st.roomFIR {
                try addFIR(N60_STAGE_ROOM_FIR, room, base: Self.roomStageBase, sharedMask: frontMask,
                           leftLanes: [fl], rightLanes: [fr])
                postLatency += Self.firPartitionFrames + room.declaredLatencyFrames
            }
            if let speaker = st.speakerIR {
                try addFIR(N60_STAGE_SPEAKER_IR, speaker, base: Self.speakerStageBase, sharedMask: frontMask,
                           leftLanes: [fl], rightLanes: [fr])
                postLatency += Self.firPartitionFrames + speaker.declaredLatencyFrames
            }
        }
        if let params = st.ambient {
            add(N60_STAGE_AMBIENT, UnifiedGraphConfiguration.ambientStageId, mask: programMask, params: params)
        }
        if let fl = shape.frontLeft, let fr = shape.frontRight, !virtualSpeakers {
            if let position = st.symmetryPosition {
                add(N60_STAGE_SYMMETRY, UnifiedGraphConfiguration.symmetryStageId,
                    lane: UInt32(fl), laneB: UInt32(fr), params: [position])
            }
            if let amount = st.crossfeedAmount {
                add(N60_STAGE_CROSSFEED, UnifiedGraphConfiguration.crossfeedStageId,
                    lane: UInt32(fl), laneB: UInt32(fr), params: [amount])
            }
            if let params = st.crosstalk {
                add(N60_STAGE_CROSSTALK, UnifiedGraphConfiguration.crosstalkStageId,
                    lane: UInt32(fl), laneB: UInt32(fr), params: params)
            }
            for (stereoLane, lane) in [(left, fl), (right, fr)] {
                if let total = stereoLane.fractionalDelayFrames {
                    guard total.isFinite, total >= 0, total < 8_190 else {
                        throw UnifiedGraphFallbackReason.specRejected
                    }
                    add(N60_STAGE_FRAC_DELAY, Self.interChannelDelayBase + UInt32(lane), lane: UInt32(lane),
                        params: [Float(total.rounded(.down)), Float(total - total.rounded(.down))])
                } else if let frames = try UnifiedGraphConfiguration.delayFrames(
                    stereoLane.delayMilliseconds, extraFrames: stereoLane.delayFrames, sampleRate: spec.sampleRate) {
                    add(N60_STAGE_DELAY, Self.interChannelDelayBase + UInt32(lane), lane: UInt32(lane),
                        capacity: frames, params: [Float(frames)])
                }
            }
        }
        if let params = st.pauseGate {
            let mask = virtualSpeakers ? UInt64(0b11) : programMask
            add(N60_STAGE_PAUSE_GATE, UnifiedGraphConfiguration.pauseGateStageId, mask: mask, params: params)
        }
        // Room and IR convolvers delay the front pair only; every other lane (subs included) catches up.
        if postLatency > 0, let fl = shape.frontLeft, let fr = shape.frontRight {
            guard postLatency <= N60_GRAPH_MAX_DELAY_FRAMES else { throw UnifiedGraphFallbackReason.latencyAlignment }
            for lane in 0..<Int(spec.outputChannels) where lane != fl && lane != fr {
                add(N60_STAGE_DELAY, Self.alignmentDelayBase + UInt32(lane), lane: UInt32(lane),
                    capacity: postLatency, params: [Float(postLatency)])
            }
        }

        if let protection {
            let params = UnifiedGraphConfiguration.protectionParameters(protection)
            if let index = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_PROTECTION }) {
                // Binaural: the ears stage exists already; the user's protection replaces its parameters.
                guard virtualSpeakers else { throw UnifiedGraphFallbackReason.specRejected }
                spec.stages[index].params = params
            } else {
                add(N60_STAGE_PROTECTION, N60_LSTAGE_PROTECTION, mask: Self.mask(Array(0..<count)), params: params)
            }
        }

        // Balance multiplies the output gain of the left and right members (the ears when binaural).
        let balance: [(lane: Int, gain: Float)] = virtualSpeakers
            ? [(0, left.outputGain), (1, right.outputGain)]
            : leftMembers.map { ($0, left.outputGain) } + rightMembers.map { ($0, right.outputGain) }
        for item in balance where item.gain != 1 {
            let id = N60_LSTAGE_OUTPUT_GAIN + UInt32(item.lane)
            guard let index = spec.stages.firstIndex(where: { $0.stageId == id }),
                  let current = spec.stages[index].params.first else {
                throw UnifiedGraphFallbackReason.specRejected
            }
            let product = current * item.gain
            guard product.isFinite, product > 0, product <= 10_000 else {
                throw UnifiedGraphFallbackReason.gainOutOfRange
            }
            spec.stages[index].params[0] = product
        }

        // Merge by the core's stage position; an existing stage stays ahead of a program stage at the same position.
        var merged: [(position: Double, origin: Int, index: Int, stage: UnifiedGraphStageSpec)] = []
        for (index, stage) in spec.stages.enumerated() {
            merged.append((Self.position(of: stage.kind), 0, index, stage))
        }
        for (index, stage) in added.enumerated() {
            merged.append((Self.position(of: stage.kind), 1, index, stage))
        }
        merged.sort { ($0.position, $0.origin, $0.index) < ($1.position, $1.origin, $1.index) }
        guard merged.count <= Self.maxStages else { throw UnifiedGraphFallbackReason.stageBudget }
        spec.stages = merged.map(\.stage)
    }

    /// The core's processing position of each stage kind (`n60/graph.h`).
    static func position(of kind: UInt32) -> Double {
        positions[kind] ?? 100
    }

    private static let positions: [UInt32: Double] = [
        N60_STAGE_SANITISE.rawValue: 1, N60_STAGE_METER_IN.rawValue: 2, N60_STAGE_GAIN.rawValue: 3,
        N60_STAGE_DENOISER.rawValue: 4, N60_STAGE_MS_ENCODE.rawValue: 5, N60_STAGE_PEQ.rawValue: 6,
        N60_STAGE_DYN_EQ.rawValue: 7, N60_STAGE_MS_DECODE.rawValue: 8, N60_STAGE_FIR.rawValue: 9,
        N60_STAGE_COMPRESSOR.rawValue: 10, N60_STAGE_EXPANDER.rawValue: 11, N60_STAGE_METER_OUT.rawValue: 12,
        N60_STAGE_EXTERNAL.rawValue: 12.5, N60_STAGE_BASS_MGMT.rawValue: 13,
        N60_STAGE_STEREO_CROSSOVER.rawValue: 13, N60_STAGE_ROOM_FIR.rawValue: 14,
        N60_STAGE_SPEAKER_IR.rawValue: 15, N60_STAGE_AMBIENT.rawValue: 16, N60_STAGE_CORE_DYNAMICS.rawValue: 17,
        N60_STAGE_BINAURAL.rawValue: 17.5, N60_STAGE_SYMMETRY.rawValue: 18, N60_STAGE_CROSSFEED.rawValue: 19,
        N60_STAGE_CROSSTALK.rawValue: 20, N60_STAGE_OUTPUT_GAIN.rawValue: 21, N60_STAGE_HEADPHONE.rawValue: 22,
        N60_STAGE_PAUSE_GATE.rawValue: 23, N60_STAGE_DELAY.rawValue: 24, N60_STAGE_FRAC_DELAY.rawValue: 24,
        N60_STAGE_ANC_GUARD.rawValue: 25, N60_STAGE_ANC_INJECT.rawValue: 26, N60_STAGE_PROTECTION.rawValue: 27,
        N60_STAGE_MUTE.rawValue: 28, N60_STAGE_ANC_CAPTURE.rawValue: 29, N60_STAGE_FINAL_SANITISE.rawValue: 30,
        N60_STAGE_FINAL_METER.rawValue: 31,
    ]
}
