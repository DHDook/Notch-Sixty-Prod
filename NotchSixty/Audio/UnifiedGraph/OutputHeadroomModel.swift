import Foundation

/// E9 S7: the headroom assistant's model. It reads the stage list Swift already publishes (`UnifiedGraphSpec`), follows each
/// output lane's signal path through it, and asks the core's design maths (`n60/headroom.h`, E9 S6) for the peak composite
/// gain of every output. Nothing here runs on an audio callback; `HeadroomRecompute` runs it off the main actor.
///
/// Every stage kind is classified (`HeadroomStageKind`): *modelled* kinds are described to the core, *bounded* kinds add an
/// explicit worst-case gain computed from their parameters, *passive* kinds cannot add level, and *unmodelled* kinds make the
/// affected outputs report an incomplete estimate (the assistant then refuses to Apply to them).
enum HeadroomStageKind: Equatable, Sendable {
    /// Cannot raise the level of a lane (meters, taps, gates, limiters, reductions only, all-passes, source replacement).
    case passive
    /// Described to the core as a gain, PEQ, biquad, delay, FIR, dynamic EQ or compressor stage, or summed as a path.
    case modelled
    /// Adds the explicit worst-case gain the model computes from the stage parameters.
    case bounded
    /// Cannot be bounded here; outputs it reaches are reported incomplete.
    case unmodelled

    /// The class of every kind in `n60_stage_kind`; nil for a kind this table does not know (treated as unmodelled).
    static func classify(_ kind: UInt32) -> HeadroomStageKind? { table[kind] }

    private static let table: [UInt32: HeadroomStageKind] = {
        var t: [UInt32: HeadroomStageKind] = [:]
        func set(_ kinds: [n60_stage_kind], _ value: HeadroomStageKind) { kinds.forEach { t[$0.rawValue] = value } }
        set([N60_STAGE_SANITISE, N60_STAGE_METER_IN, N60_STAGE_METER_OUT, N60_STAGE_FINAL_SANITISE, N60_STAGE_FINAL_METER,
             N60_STAGE_ANALYSER_TAP_EQ, N60_STAGE_ANALYSER_TAP_DYN, N60_STAGE_DELTA_CAPTURE, N60_STAGE_ANC_CAPTURE,
             N60_STAGE_DENOISER, N60_STAGE_EXPANDER, N60_STAGE_DEESS, N60_STAGE_CLEANUP, N60_STAGE_PAUSE_GATE,
             N60_STAGE_MUTE, N60_STAGE_PROTECTION, N60_STAGE_ANC_GUARD, N60_STAGE_GENERATOR, N60_STAGE_FRAC_DELAY,
             N60_STAGE_CROSSFEED, N60_STAGE_MS_ENCODE, N60_STAGE_MS_DECODE], .passive)
        set([N60_STAGE_GAIN, N60_STAGE_OUTPUT_GAIN, N60_STAGE_PEQ, N60_STAGE_DYN_EQ, N60_STAGE_FIR, N60_STAGE_ROOM_FIR,
             N60_STAGE_SPEAKER_IR, N60_STAGE_DRIVER_FIR, N60_STAGE_COMPRESSOR, N60_STAGE_CORE_DYNAMICS, N60_STAGE_DELAY,
             N60_STAGE_LANE_DELAY, N60_STAGE_AMBIENT, N60_STAGE_BASS_MGMT, N60_STAGE_ROUTE, N60_STAGE_XOVER], .modelled)
        set([N60_STAGE_SYMMETRY, N60_STAGE_CROSSTALK, N60_STAGE_HEADPHONE, N60_STAGE_IMAGE, N60_STAGE_LOUDNESS,
             N60_STAGE_MULTIBAND, N60_STAGE_STEREO_CROSSOVER, N60_STAGE_ANC_INJECT], .bounded)
        set([N60_STAGE_BINAURAL, N60_STAGE_EXTERNAL, N60_STAGE_ROOM_FIR_TWO_BAND, N60_STAGE_DRIVER_FIR_TWO_BAND,
             N60_STAGE_DELTA_SUBTRACT], .unmodelled)
        return t
    }()

    /// A short name for a kind in the "estimate incomplete" note.
    static func name(_ kind: UInt32) -> String {
        switch kind {
        case N60_STAGE_BINAURAL.rawValue: return "binaural rendering"
        case N60_STAGE_EXTERNAL.rawValue: return "Audio Unit rack"
        case N60_STAGE_ROOM_FIR_TWO_BAND.rawValue, N60_STAGE_DRIVER_FIR_TWO_BAND.rawValue: return "two-band FIR"
        case N60_STAGE_DELTA_SUBTRACT.rawValue: return "delta audition"
        default: return "stage \(kind)"
        }
    }
}

/// One output's headroom estimate.
struct OutputHeadroom: Equatable, Sendable {
    var lane: Int
    /// The highest composite gain of everything that reaches this output with no assistant trim (dB), and where it is.
    var peakGainDB: Double
    var peakHz: Double
    /// The lowest limiter ceiling on this output (dBFS): the user limiter when on, and the hard limit.
    var ceilingDB: Double
    /// The attenuation that keeps a full-scale input under the ceiling with the true-peak margin; 0 when none is needed.
    var neededDB: Double
    /// The trim already in the graph for this output (dB, 0 or negative).
    var currentTrimDB: Double
    /// Names of stages the model could not bound; non-empty means `neededDB` is not trustworthy and Apply skips the output.
    var incomplete: [String]

    var isComplete: Bool { incomplete.isEmpty }
    /// The trim is within 0.05 dB of what the output needs (or above it).
    var isSatisfied: Bool { currentTrimDB <= -neededDB + 0.05 }
    /// With the present trim, a full-scale input would still reach the limiter.
    var limiterPredicted: Bool { neededDB + currentTrimDB > 0.05 }
    /// The trim Apply sets: the need rounded up to 0.1 dB, never a boost, never below the settings range.
    var appliedTrimDB: Double { neededDB <= 0.001 ? 0 : max(OutputProtectionSettings.trimRangeDB.lowerBound, -(neededDB * 10).rounded(.up) / 10) }
}

enum HeadroomAssistant {
    /// Settings with every complete output's trim set from `results`; incomplete outputs keep their trim.
    static func applying(_ results: [OutputHeadroom], to settings: OutputProtectionSettings) -> OutputProtectionSettings {
        var next = settings
        for result in results where result.isComplete {
            var lane = next.lane(result.lane)
            lane.trimDB = result.appliedTrimDB
            next.set(lane, at: result.lane)
        }
        return next
    }
}

/// Runs the model off the main actor (design note 10: recompute on every published snapshot, never on the UI thread).
enum HeadroomRecompute {
    static func run(
        spec: UnifiedGraphSpec, laneCount: Int, strict: Bool, trimsDB: [Int: Double],
        observe: (@Sendable () -> Void)? = nil
    ) async -> [OutputHeadroom] {
        await Task.detached(priority: .utility) {
            observe?()
            return HeadroomModel(spec: spec, laneCount: laneCount, strict: strict, trimsDB: trimsDB).analyse()
        }.value
    }
}

/// Sample rate: the core evaluates on a 1/48-octave grid from 10 Hz to 0.45 fs, so every device rate to 384 kHz is covered.
/// Follows the published stages lane by lane. Pure and deterministic; allocates freely (control or worker thread only).
struct HeadroomModel {
    let spec: UnifiedGraphSpec
    let laneCount: Int
    let strict: Bool
    /// The assistant trims already applied by the graph, subtracted again so `neededDB` is the total need.
    let trimsDB: [Int: Double]

    // MARK: Internal description

    private struct Stage {
        var kind: UInt32
        var params: [Float] = []
        var taps: [Float] = []
    }

    private struct Path {
        var combine: UInt32
        var stages: [Stage]
    }

    /// A lane is a sum of paths plus stages after the sum. `silent` lanes carry nothing (cleared by a bass manager or route).
    private struct Lane {
        var paths: [Path] = [Path(combine: UInt32(N60_HEADROOM_COMBINE_COHERENT), stages: [])]
        var tail: [Stage] = []
        var silent = false
        var incomplete: Set<String> = []

        mutating func append(_ stage: Stage) {
            if paths.count == 1 { paths[0].stages.append(stage) } else { tail.append(stage) }
        }

        /// The paths with this lane's tail folded in (distributive for gain, EQ and delay; a power path stays a power path).
        var flattened: [Path] {
            tail.isEmpty ? paths : paths.map { Path(combine: $0.combine, stages: $0.stages + tail) }
        }
    }

    private static let pairKinds: Set<UInt32> = [
        N60_STAGE_SYMMETRY, N60_STAGE_CROSSFEED, N60_STAGE_CROSSTALK, N60_STAGE_HEADPHONE, N60_STAGE_IMAGE,
        N60_STAGE_LOUDNESS, N60_STAGE_MULTIBAND, N60_STAGE_STEREO_CROSSOVER, N60_STAGE_MS_ENCODE, N60_STAGE_MS_DECODE,
        N60_STAGE_CLEANUP, N60_STAGE_DEESS,
    ].reduce(into: Set<UInt32>()) { $0.insert($1.rawValue) }

    private static func gainStage(_ linear: Double) -> Stage {
        Stage(kind: UInt32(N60_HEADROOM_STAGE_GAIN), params: [Float(linear)])
    }

    private static func gainDB(_ db: Double) -> Stage { gainStage(pow(10, db / 20)) }

    private static func peqStages(_ sections: [(type: Float, hz: Float, db: Float, q: Float)]) -> [Stage] {
        stride(from: 0, to: sections.count, by: 16).map { start in
            Stage(kind: UInt32(N60_HEADROOM_STAGE_PEQ),
                  params: sections[start..<min(start + 16, sections.count)].flatMap { [$0.type, $0.hz, $0.db, $0.q] })
        }
    }

    private static let butterworthQ: Float = 0.70710678

    // MARK: Walk

    func analyse() -> [OutputHeadroom] {
        let lanes = walk()
        return (0..<laneCount).map { index in
            let ceiling = ceilingDB(lane: index)
            let trim = trimsDB[index] ?? 0
            guard index < lanes.count else {
                return OutputHeadroom(lane: index, peakGainDB: -200, peakHz: 0, ceilingDB: ceiling, neededDB: 0,
                                      currentTrimDB: trim, incomplete: ["lane missing from graph"])
            }
            let lane = lanes[index]
            var incomplete = lane.incomplete
            if lane.silent {
                return OutputHeadroom(lane: index, peakGainDB: -200, peakHz: 0, ceilingDB: ceiling, neededDB: 0,
                                      currentTrimDB: trim, incomplete: incomplete.sorted())
            }
            var peak = -200.0, hz = 0.0
            if let result = evaluate(lane, ceiling: ceiling) {
                peak = result.peak_gain_db - trim
                hz = result.peak_hz
            } else {
                incomplete.insert("evaluation failed")
            }
            let needed = max(0, peak + N60_HEADROOM_TRUE_PEAK_MARGIN_DB - ceiling)
            return OutputHeadroom(lane: index, peakGainDB: peak, peakHz: hz, ceilingDB: ceiling, neededDB: needed,
                                  currentTrimDB: trim, incomplete: incomplete.sorted())
        }
    }

    /// The lowest ceiling of a limiter stage that covers `lane` (the user limiter when on, and the hard limit).
    private func ceilingDB(lane: Int) -> Double {
        var ceiling = 0.0
        for stage in spec.stages where stage.kind == N60_STAGE_PROTECTION.rawValue && stage.params.count > 1 && stage.params[0] == 1 {
            if lanes(of: stage).contains(lane) { ceiling = min(ceiling, Double(stage.params[1])) }
        }
        return ceiling
    }

    private func lanes(of stage: UnifiedGraphStageSpec) -> [Int] {
        let count = Int(spec.outputChannels)
        if stage.laneMask != 0 { return (0..<min(count, 64)).filter { stage.laneMask & (UInt64(1) << UInt64($0)) != 0 } }
        if stage.laneA == N60_LANE_ALL { return Array(0..<count) }
        if Self.pairKinds.contains(stage.kind) {
            return stage.laneA == stage.laneB ? [Int(stage.laneA)] : [Int(stage.laneA), Int(stage.laneB)]
        }
        return [Int(stage.laneA)]
    }

    private func walk() -> [Lane] {
        let count = Int(spec.outputChannels)
        var lanes = [Lane](repeating: Lane(), count: count)
        let ordered = spec.stages.enumerated().sorted {
            let a = UnifiedGraphProgramDSP.position(of: $0.element.kind), b = UnifiedGraphProgramDSP.position(of: $1.element.kind)
            return (a, $0.offset) < (b, $1.offset)
        }.map(\.element)
        for stage in ordered {
            let kind = stage.kind
            guard let cls = HeadroomStageKind.classify(kind) else {
                for index in self.lanes(of: stage) where index < count { lanes[index].incomplete.insert("stage \(kind)") }
                continue
            }
            let p = stage.params
            let selected = self.lanes(of: stage).filter { $0 < count }
            func each(_ add: (Int) -> [Stage]) {
                for index in selected where !lanes[index].silent { for s in add(index) { lanes[index].append(s) } }
            }
            switch cls {
            case .passive: continue
            case .unmodelled:
                let name = HeadroomStageKind.name(kind)
                let affected = kind == N60_STAGE_BINAURAL.rawValue ? Array(0..<count) : selected
                for index in affected { lanes[index].incomplete.insert(name) }
                continue
            case .modelled, .bounded: break
            }
            switch kind {
            case N60_STAGE_GAIN.rawValue, N60_STAGE_OUTPUT_GAIN.rawValue:
                guard let g = p.first else { continue }
                each { _ in [Self.gainStage(Double(g))] }
            case N60_STAGE_PEQ.rawValue:
                let stages = Self.peqSpecStages(p)
                each { _ in stages }
            case N60_STAGE_DYN_EQ.rawValue:
                each { _ in [Stage(kind: UInt32(N60_HEADROOM_STAGE_DYN_EQ), params: p)] }
            case N60_STAGE_FIR.rawValue, N60_STAGE_ROOM_FIR.rawValue, N60_STAGE_SPEAKER_IR.rawValue, N60_STAGE_DRIVER_FIR.rawValue:
                guard !p.isEmpty else { continue }
                each { _ in [Stage(kind: UInt32(N60_HEADROOM_STAGE_FIR), taps: p)] }
            case N60_STAGE_COMPRESSOR.rawValue, N60_STAGE_CORE_DYNAMICS.rawValue:
                each { _ in [Stage(kind: UInt32(N60_HEADROOM_STAGE_COMPRESSOR), params: p)] }
            case N60_STAGE_DELAY.rawValue, N60_STAGE_LANE_DELAY.rawValue:
                guard let frames = p.first else { continue }
                each { _ in [Stage(kind: UInt32(N60_HEADROOM_STAGE_DELAY), params: [frames])] }
            case N60_STAGE_AMBIENT.rawValue:
                guard p.count >= 10 else { continue }
                var s = [Self.gainDB(Double(p[0]))]
                s += Self.peqStages([(1, p[1], p[2], p[3]), (0, p[4], p[5], p[6]), (2, p[7], p[8], p[9])])
                each { _ in s }
            case N60_STAGE_BASS_MGMT.rawValue:
                bassManage(&lanes, stage: stage, mask: selected)
            case N60_STAGE_ROUTE.rawValue:
                route(&lanes, stage: stage, destinations: selected)
            case N60_STAGE_XOVER.rawValue:
                guard p.count >= 14 else { continue }
                if p[8] == 1 { for index in selected { lanes[index].incomplete.insert("Linkwitz transform") } }
                let n = Int(p[13])
                var s = [Self.gainDB(Double(p[6]))]
                if n > 0, p.count >= 14 + 4 * n {
                    s += Self.peqStages((0..<n).map { (p[14 + 4 * $0], p[15 + 4 * $0], p[16 + 4 * $0], p[17 + 4 * $0]) })
                }
                each { _ in s }
            default:
                boundedGain(kind: kind, params: p, selected: selected, lanes: &lanes)
            }
        }
        return lanes
    }

    /// PEQ sections of the graph (types 0..8, and 9 plus 10 as one prepared biquad) as core stages, in order.
    private static func peqSpecStages(_ p: [Float]) -> [Stage] {
        var out: [Stage] = []
        var run: [(type: Float, hz: Float, db: Float, q: Float)] = []
        func flush() { out += peqStages(run); run = [] }
        var i = 0
        while i + 3 < p.count {
            let type = p[i]
            if type == 9, i + 7 < p.count, p[i + 4] == 10 {
                flush()
                out.append(Stage(kind: UInt32(N60_HEADROOM_STAGE_BIQUAD), params: [p[i + 1], p[i + 2], p[i + 3], p[i + 5], p[i + 6]]))
                i += 8
                continue
            }
            // Type 8 (constant-Q peaking) peaks at the same gain as type 0.
            run.append((type == 8 ? 0 : min(type, 7), p[i + 1], p[i + 2], p[i + 3]))
            i += 4
        }
        flush()
        return out
    }

    /// Worst-case gains of the bounded kinds, derived from their parameters (see the stage documentation in `n60/graph.h`).
    private func boundedGain(kind: UInt32, params p: [Float], selected: [Int], lanes: inout [Lane]) {
        func add(_ linear: Double, to indices: [Int]) {
            guard linear.isFinite, abs(linear - 1) > 1e-9 else { return }
            for index in indices where !lanes[index].silent { lanes[index].append(Self.gainStage(linear)) }
        }
        switch kind {
        case N60_STAGE_SYMMETRY.rawValue:
            add(2.0.squareRoot(), to: selected) // gains are sqrt(2) cos / sin of the position: at most +3.01 dB
        case N60_STAGE_CROSSTALK.rawValue:
            if p.count > 1 { add(1 + Double(max(0, p[1])), to: selected) }
        case N60_STAGE_IMAGE.rawValue:
            // A widener scales the side signal by up to the widest band width, so a fully out-of-phase input gains that much.
            if p.count >= 8, p[1] == 1 { add(max(1, Double(max(p[5], p[6], p[7]))), to: selected) }
        case N60_STAGE_LOUDNESS.rawValue:
            guard p.count >= 21 else { return }
            var boost = 0.0
            if p[0] == 1 { boost += Double(p[3]) }
            if p[6] == 1 { boost += Double(p[11]) }
            if p[14] == 1 { boost += Double(p[20]) }
            add(pow(10, boost / 20), to: selected)
        case N60_STAGE_MULTIBAND.rawValue:
            if p.count >= 26, p[0] == 1 { add(pow(10, Double(max(0, p[23], p[24], p[25])) / 20), to: selected) }
        case N60_STAGE_STEREO_CROSSOVER.rawValue:
            // Mains high-pass plus the sub low-pass at gain g recombine to at most 1 + |g - 1|.
            if p.count > 3 { add(1 + abs(Double(p[3]) - 1), to: selected) }
        case N60_STAGE_ANC_INJECT.rawValue:
            // Only when authorised: the (at most full-scale) source lane is added at gain dB.
            if p.count > 2, p[1] == 1 { add(1 + pow(10, Double(min(0, p[2])) / 20), to: selected) }
        case N60_STAGE_HEADPHONE.rawValue:
            guard p.count >= 11 else { return }
            let nA = Int(p[9]), nB = Int(p[10])
            guard nA >= 0, nB >= 0, p.count >= 11 + 4 * (nA + nB) else { return }
            let mix = 1 + 0.5 * Double(max(0, p[1]))
            func side(_ gainDB: Float, _ first: Int, _ n: Int) -> [Stage] {
                [Self.gainDB(Double(p[0] + gainDB)), Self.gainStage(mix)]
                    + Self.peqStages((0..<n).map { (p[first + 4 * $0], p[first + 4 * $0 + 1], p[first + 4 * $0 + 2], p[first + 4 * $0 + 3]) })
            }
            if let a = selected.first, !lanes[a].silent { side(p[5], 11, nA).forEach { lanes[a].append($0) } }
            if selected.count > 1, !lanes[selected[1]].silent { side(p[6], 11 + 4 * nA, nB).forEach { lanes[selected[1]].append($0) } }
        default:
            break
        }
    }

    // MARK: Bass management and routing

    private func bassManage(_ lanes: inout [Lane], stage: UnifiedGraphStageSpec, mask: [Int]) {
        let p = stage.params
        guard p.count >= 9 else { for index in mask { lanes[index].incomplete.insert("bass management") }; return }
        let crossover = p[0], redirect = Double(p[1])
        let lfeLane = Int(p[3])
        let count = lanes.count
        // Sub blocks: sub 0 then the extension.
        struct Sub { var lane: Int; var gainDB: Double; var inverted: Bool; var sections: [(type: Float, hz: Float, db: Float, q: Float)] }
        func sections(at start: Int, count n: Int) -> [(type: Float, hz: Float, db: Float, q: Float)]? {
            guard n >= 0, p.count >= start + 4 * n else { return nil }
            return (0..<n).map { (p[start + 4 * $0], p[start + 4 * $0 + 1], p[start + 4 * $0 + 2], p[start + 4 * $0 + 3]) }
        }
        let n0 = Int(p[8])
        guard let s0 = sections(at: 9, count: n0) else { for index in mask { lanes[index].incomplete.insert("bass management") }; return }
        var subs = [Sub(lane: Int(p[2]), gainDB: Double(p[6]), inverted: p[7] == 1, sections: s0)]
        var cursor = 9 + 4 * n0
        var hostWeighted = false
        var customSplit = false
        if p.count > cursor {
            let word = Int(p[cursor]); cursor += 1
            hostWeighted = word >= 8
            for _ in 0..<(word % 8) {
                guard p.count >= cursor + 4, let s = sections(at: cursor + 4, count: Int(p[cursor + 3])) else {
                    for index in mask { lanes[index].incomplete.insert("bass management") }; return
                }
                subs.append(Sub(lane: Int(p[cursor]), gainDB: Double(p[cursor + 1]), inverted: p[cursor + 2] == 1, sections: s))
                cursor += 4 + 4 * Int(p[cursor + 3])
            }
            customSplit = p.count >= cursor + 4
        }
        let norm = hostWeighted ? 1.0 : 1.0 / Double(subs.count)
        let lowPass: [Stage] = customSplit ? [] : (0..<2).map { _ in
            Stage(kind: UInt32(N60_HEADROOM_STAGE_PEQ), params: [3, crossover, 0, Self.butterworthQ])
        }
        let highPass: [Stage] = customSplit ? [] : (0..<2).map { _ in
            Stage(kind: UInt32(N60_HEADROOM_STAGE_PEQ), params: [4, crossover, 0, Self.butterworthQ])
        }
        // The front pair is the first two main lanes; the rest add as power unless Strict (owner Q3).
        let front = Set(mask.sorted().prefix(2))
        var sources: [(path: Path, lane: Int)] = []
        for index in mask.sorted() where !lanes[index].silent {
            for var path in lanes[index].flattened {
                path.stages += lowPass + [Self.gainDB(redirect)]
                path.combine = UInt32(front.contains(index) ? N60_HEADROOM_COMBINE_COHERENT : N60_HEADROOM_COMBINE_POWER)
                sources.append((path, index))
            }
        }
        if lfeLane >= 0, lfeLane < count, !lanes[lfeLane].silent, !subs.contains(where: { $0.lane == lfeLane }) {
            for var path in lanes[lfeLane].flattened {
                path.stages += [Stage(kind: UInt32(N60_HEADROOM_STAGE_PEQ), params: [3, p[4], 0, Self.butterworthQ]), Self.gainDB(Double(p[5]))]
                path.combine = UInt32(N60_HEADROOM_COMBINE_POWER)
                sources.append((path, lfeLane))
            }
        }
        var incomplete = Set<String>()
        for index in mask { incomplete.formUnion(lanes[index].incomplete) }
        let lfeIncomplete = (lfeLane >= 0 && lfeLane < count) ? lanes[lfeLane].incomplete : []
        incomplete.formUnion(lfeIncomplete)
        // Sub lanes are replaced; the LFE lane is cleared unless it is a sub lane.
        if lfeLane >= 0, lfeLane < count, !subs.contains(where: { $0.lane == lfeLane }) {
            lanes[lfeLane].silent = true
            lanes[lfeLane].paths = []
            lanes[lfeLane].tail = []
        }
        for sub in subs where sub.lane >= 0 && sub.lane < count {
            var lane = Lane()
            lane.paths = sources.map(\.path)
            lane.silent = lane.paths.isEmpty
            lane.incomplete = incomplete
            lane.tail = [Self.gainStage(norm * pow(10, sub.gainDB / 20) * (sub.inverted ? -1 : 1))]
                + Self.peqStages(sub.sections)
            lanes[sub.lane] = lane
        }
        for index in mask { for s in highPass where !lanes[index].silent { lanes[index].append(s) } }
    }

    private func route(_ lanes: inout [Lane], stage: UnifiedGraphStageSpec, destinations: [Int]) {
        let p = stage.params
        guard p.count >= 16 * destinations.count else {
            for index in destinations { lanes[index].incomplete.insert("route") }
            return
        }
        let before = lanes
        let destinationSet = Set(destinations)
        var sources = Set<Int>()
        for (k, destination) in destinations.sorted().enumerated() {
            var next = Lane()
            next.paths = []
            for e in 0..<8 {
                let source = Int(p[16 * k + 2 * e])
                guard source >= 0, source < before.count else { continue }
                sources.insert(source)
                next.incomplete.formUnion(before[source].incomplete)
                guard !before[source].silent else { continue }
                for var path in before[source].flattened {
                    // ROUTE runs after OUTPUT_GAIN, so a source lane's trim is already in its path: take it out again, because
                    // `analyse` subtracts only the destination's own trim.
                    if let trim = trimsDB[source], trim != 0 { path.stages.append(Self.gainDB(-trim)) }
                    path.stages.append(Self.gainStage(Double(p[16 * k + 2 * e + 1])))
                    path.combine = UInt32(N60_HEADROOM_COMBINE_COHERENT)
                    next.paths.append(path)
                }
            }
            next.silent = next.paths.isEmpty
            lanes[destination] = next
        }
        for source in sources where !destinationSet.contains(source) {
            lanes[source].silent = true
            lanes[source].paths = []
            lanes[source].tail = []
        }
    }

    // MARK: Core call

    private func evaluate(_ lane: Lane, ceiling: Double) -> n60_headroom_result? {
        guard (1...64).contains(lane.paths.count), lane.tail.count <= 64 else { return nil }
        var owned: [UnsafeMutableRawPointer] = []
        defer { owned.forEach { $0.deallocate() } }
        func floats(_ values: [Float]) -> UnsafePointer<Float>? {
            guard !values.isEmpty else { return nil }
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: values.count)
            buffer.initialize(from: values, count: values.count)
            owned.append(UnsafeMutableRawPointer(buffer))
            return UnsafePointer(buffer)
        }
        func cStages(_ stages: [Stage]) -> UnsafePointer<n60_headroom_stage>? {
            guard !stages.isEmpty else { return nil }
            let buffer = UnsafeMutablePointer<n60_headroom_stage>.allocate(capacity: stages.count)
            for (i, s) in stages.enumerated() {
                (buffer + i).initialize(to: n60_headroom_stage(
                    kind: s.kind, param_count: UInt32(s.params.count), params: floats(s.params),
                    tap_count: UInt32(s.taps.count), taps: floats(s.taps)))
            }
            owned.append(UnsafeMutableRawPointer(buffer))
            return UnsafePointer(buffer)
        }
        let pathBuffer = UnsafeMutablePointer<n60_headroom_path>.allocate(capacity: lane.paths.count)
        owned.append(UnsafeMutableRawPointer(pathBuffer))
        for (i, path) in lane.paths.enumerated() {
            (pathBuffer + i).initialize(to: n60_headroom_path(
                combine: path.combine, stage_count: UInt32(path.stages.count), stages: cStages(path.stages)))
        }
        var output = n60_headroom_output(
            struct_size: UInt32(MemoryLayout<n60_headroom_output>.size), sample_rate: spec.sampleRate,
            strict: strict ? 1 : 0, path_count: UInt32(lane.paths.count), paths: UnsafePointer(pathBuffer),
            tail_stage_count: UInt32(lane.tail.count), tail_stages: cStages(lane.tail), ceiling_db: ceiling)
        var result = n60_headroom_result()
        result.struct_size = UInt32(MemoryLayout<n60_headroom_result>.size)
        guard n60_headroom_evaluate(&output, &result) == N60_HEADROOM_OK else { return nil }
        return result
    }
}
