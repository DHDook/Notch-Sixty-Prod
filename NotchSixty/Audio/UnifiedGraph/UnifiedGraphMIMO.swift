import Accelerate
import Foundation

/// E19 S6: the graph-side description of `N60_STAGE_MIMO` (ABI v33, `n60/graph.h`). It is a staged, designed filter
/// set plus the live arm and trip words; `UnifiedGraphConfiguration.makeSpec` turns it into the stage and the
/// latency-matching delays of the lanes outside the stage. Nothing here arms anything: `armed` is written only by
/// `MIMOGraphTreatment` after every gate passed.
///
/// Realtime notes: control plane only. The audio thread sees the stage through the snapshot; `armed` and `trip` are the
/// stage's two live parameters (posted through the normal parameter mailbox, never a rebuild).
/// - allocation: none on the audio thread (the core allocates in build and publish).
/// - latency: `latencyFrames` (10 D + tau frames), identical on every lane, armed or not.
/// - rates: every device rate from 44.1 to 384 kHz (D = 16, 32, 64, 128 by family); channels: 1 to 8 source lanes.
/// - reset: a new snapshot starts with the delta at zero and held (the core's rebuild rule).
struct UnifiedGraphMIMOStage: Equatable, Sendable {
    static let stageId: UInt32 = 640
    /// DELAY stages on the lanes outside the mask (+ lane): they match the stage's latency (E19 S6).
    static let alignStageBase: UInt32 = 650

    let filters: MIMOTreatmentFilterSet
    /// Graph lanes (program lanes, then sub lanes) of source 0, 1, ... in ascending order.
    let sourceLanes: [Int]
    /// Per-source bound on the RMS of the delta over the RMS of the program feeds (linear).
    let rowGainBounds: [Float]
    /// Live word [4]. Written only by the arm controller.
    var armed = false
    /// Support range [low, high] Hz of every source, flattened (low0, high0, low1, ...): bound by the permit's fingerprint
    /// (E19 S7). Not a stage parameter; the design's own filters already carry it.
    var supportRangesHz: [Double] = []
    /// Live word [5]: a trip (10 ms fade, latches `held` until the host writes arm = 0 and trip = 0).
    var trip = false
    /// Live word [6]: the dead-man heartbeat (E19 G22). The arm controller changes it on every poll tick while armed; the
    /// core faults the stage (reason 3) when the word stays unchanged for `leaseMilliseconds`.
    var heartbeat: UInt32 = 0
    /// Topology word [7]: the lease in milliseconds (0 = none). Constant for the life of a design, so it never forces a rebuild.
    static let leaseMilliseconds: UInt32 = 1_000
    static let maxHeartbeat: UInt32 = 999_983
    /// E19 S10: set for a routed graph (`N60_STAGE_MIMO_ROUTED`); nil for the unrouted stage.
    var routed: Routed?

    /// Where the routed stage sits among the routing's output lanes (design note 10). Positions are indices into the routing's
    /// output lanes (`firstOutputLane + position` is the graph lane). Source k is one speaker: it listens to
    /// `inputPositions[k]` (its lowest in-band way, the pre-crossover feed) and its delta goes to `injectionPositions[k]` (every
    /// in-band way, at most four). Every other output lane in the mask, tweeters included, carries the program delayed by L.
    struct Routed: Equatable, Sendable {
        static let maxInjections = 4
        static let maxLanes = 32
        var firstOutputLane: Int
        var outputCount: Int
        var inputPositions: [Int]
        var injectionPositions: [[Int]]
    }

    enum Refusal: Error, Equatable {
        case sourceLaneCount
        case sourceLanesNotAscending
        case tauNotRepresentable
        case unsupportedRate
        case routedLayout
        case routingMismatch
    }

    init(filters: MIMOTreatmentFilterSet, sourceLanes: [Int]) throws {
        guard sourceLanes.count == filters.sourceCount, (1...Int(N60_MIMO_MAX_SOURCES)).contains(sourceLanes.count) else {
            throw Refusal.sourceLaneCount
        }
        guard zip(sourceLanes, sourceLanes.dropFirst()).allSatisfy({ $0 < $1 }), sourceLanes.allSatisfy({ $0 >= 0 }) else {
            throw Refusal.sourceLanesNotAscending
        }
        guard [16, 32, 64, 128].contains(filters.decimation) else { throw Refusal.unsupportedRate }
        self.filters = filters
        self.sourceLanes = sourceLanes
        rowGainBounds = Self.rowGainBounds(filters)
        guard Self.tauFrames(filters) <= Self.maxTauFrames(sampleRate: filters.sampleRate) else {
            throw Refusal.tauNotRepresentable
        }
    }

    /// E19 S10: the routed stage. `sourceLanes` are the graph lanes each source listens to (output lanes of its lowest in-band way).
    init(filters: MIMOTreatmentFilterSet, routed: Routed) throws {
        let count = filters.sourceCount
        guard (1...Int(N60_MIMO_MAX_SOURCES)).contains(count), routed.inputPositions.count == count,
              routed.injectionPositions.count == count, routed.firstOutputLane >= 0,
              (1...Routed.maxLanes).contains(routed.outputCount), routed.firstOutputLane + routed.outputCount <= 64,
              routed.inputPositions.allSatisfy({ (0..<routed.outputCount).contains($0) })
        else { throw Refusal.routedLayout }
        var taken = Set<Int>()
        for list in routed.injectionPositions {
            guard (1...Routed.maxInjections).contains(list.count) else { throw Refusal.routedLayout }
            for position in list {
                guard (0..<routed.outputCount).contains(position), taken.insert(position).inserted else { throw Refusal.routedLayout }
            }
        }
        guard [16, 32, 64, 128].contains(filters.decimation) else { throw Refusal.unsupportedRate }
        self.filters = filters
        self.routed = routed
        sourceLanes = routed.inputPositions.map { routed.firstOutputLane + $0 }
        rowGainBounds = Self.rowGainBounds(filters)
        guard Self.tauFrames(filters) <= Self.maxTauFrames(sampleRate: filters.sampleRate) else {
            throw Refusal.tauNotRepresentable
        }
    }

    var laneMask: UInt64 {
        if let routed { return (0..<routed.outputCount).reduce(0) { $0 | (UInt64(1) << UInt64(routed.firstOutputLane + $1)) } }
        return sourceLanes.reduce(0) { $0 | (UInt64(1) << UInt64($1)) }
    }
    var tauFrames: UInt32 { Self.tauFrames(filters) }
    /// L = 10 D + tau frames: the delay every lane carries through the stage.
    var latencyFrames: UInt32 { UInt32(10 * filters.decimation) + tauFrames }

    private static func tauFrames(_ filters: MIMOTreatmentFilterSet) -> UInt32 {
        UInt32((filters.tauSeconds * filters.sampleRate).rounded())
    }

    private static func maxTauFrames(sampleRate: Double) -> UInt32 {
        UInt32((N60_MIMO_MAX_TAU_SECONDS * sampleRate).rounded(.up))
    }

    /// The (source, graph lane) pairs whose output headroom the design must be checked on: the source lanes when unrouted; for a
    /// routed stage every injection lane of every speaker (the delta lands there, design note 10).
    var headroomChecks: [(source: Int, lane: Int)] {
        guard let routed else { return sourceLanes.enumerated().map { (source: $0.offset, lane: $0.element) } }
        return routed.injectionPositions.enumerated().flatMap { source, positions in
            positions.map { (source: source, lane: routed.firstOutputLane + $0) }
        }
    }

    /// The stage's parameter list (`n60/graph.h`): 8 + S + S * S * T floats (routed: plus 5 per source).
    var parameters: [Float] {
        var p: [Float] = [
            Float(filters.decimation), Float(filters.tapCount), Float(filters.sourceCount), Float(tauFrames),
            armed ? 1 : 0, trip ? 1 : 0, Float(heartbeat), Float(Self.leaseMilliseconds),
        ]
        p += rowGainBounds
        p += filters.taps
        if let routed {
            for (source, input) in routed.inputPositions.enumerated() {
                p.append(Float(input))
                for slot in 0..<Routed.maxInjections {
                    let list = routed.injectionPositions[source]
                    p.append(slot < list.count ? Float(list[slot]) : -1)
                }
            }
        }
        return p
    }

    /// An upper bound of each row's delta over the program feeds: sqrt(sum over inputs t of max_f |E_st(f)|^2), from an
    /// 8,192-point transform of every filter (taps never exceed 4,096). Never below 1e-4 so an excluded (all-zero) row
    /// stays a valid positive bound.
    static func rowGainBounds(_ filters: MIMOTreatmentFilterSet) -> [Float] {
        let sources = filters.sourceCount
        let taps = filters.tapCount
        let log2n = 13
        let n = 1 << log2n
        guard taps >= 1, taps <= n, filters.taps.count == sources * sources * taps,
              let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 1_000, count: sources)
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n)
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var bounds = [Float](repeating: 0, count: sources)
        for s in 0..<sources {
            var sumSquares: Float = 0
            for t in 0..<sources {
                let base = (s * sources + t) * taps
                for i in 0..<n { real[i] = i < taps ? filters.taps[base + i] : 0 }
                var peak: Float = 0
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        real.withUnsafeBufferPointer { raw in
                            raw.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        // zrip packs DC in realp[0] and Nyquist in imagp[0], both scaled by 2.
                        peak = max(abs(rp[0]), abs(ip[0])) / 2
                        for k in 1..<(n / 2) { peak = max(peak, hypotf(rp[k], ip[k]) / 2) }
                    }
                }
                sumSquares += peak * peak
            }
            bounds[s] = max(1e-4, sumSquares.squareRoot())
        }
        return bounds
    }

    // MARK: Graph assembly (used by `UnifiedGraphConfiguration.makeSpec`)

    /// Validates the stage against the configuration it joins and returns its spec plus the matching delays.
    func stageSpecs(
        sampleRate: Double, graphLaneCount: Int, routing: UnifiedGraphRouting?, hasAncActuators: Bool, hasHardLimit: Bool
    ) throws -> [UnifiedGraphStageSpec] {
        // An unrouted design needs an unrouted graph and a routed design a routed one (E19 S10, design note 10).
        guard (routing != nil) == (routed != nil) else {
            throw UnifiedGraphError.unsupportedConfiguration(
                routing != nil ? "MIMO treatment designed for an unrouted graph" : "routed MIMO treatment on an unrouted graph")
        }
        guard !hasAncActuators else { throw UnifiedGraphError.unsupportedConfiguration("MIMO treatment with Quiet Zone actuators") }
        guard hasHardLimit else { throw UnifiedGraphError.unsupportedConfiguration("MIMO treatment without the output hard limit") }
        guard abs(filters.sampleRate - sampleRate) < 0.5 else {
            throw UnifiedGraphError.invalidConfiguration("MIMO design rate")
        }
        guard let last = sourceLanes.last, last < graphLaneCount else {
            throw UnifiedGraphError.invalidConfiguration("MIMO source lane")
        }
        let latency = latencyFrames
        guard latency <= N60_GRAPH_MAX_DELAY_FRAMES else { throw UnifiedGraphError.invalidConfiguration("MIMO latency") }
        if let routed, let routing {
            // The stage describes the outputs it was designed on: a different output set needs a new design. Every output lane is
            // in the mask, so all carry L and no alignment delays are needed.
            guard routing.outputs.count == routed.outputCount, routing.outputs.first?.lane == routed.firstOutputLane,
                  routed.firstOutputLane + routed.outputCount <= graphLaneCount
            else { throw UnifiedGraphError.invalidConfiguration("MIMO routed outputs") }
            return [UnifiedGraphStageSpec(
                kind: N60_STAGE_MIMO_ROUTED.rawValue, stageId: Self.stageId, laneA: 0, laneMask: laneMask, params: parameters)]
        }
        var specs = [UnifiedGraphStageSpec(
            kind: N60_STAGE_MIMO.rawValue, stageId: Self.stageId, laneA: 0, laneMask: laneMask, params: parameters)]
        let inMask = Set(sourceLanes)
        for lane in 0..<graphLaneCount where !inMask.contains(lane) {
            specs.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_DELAY.rawValue, stageId: Self.alignStageBase + UInt32(lane), laneA: UInt32(lane),
                capacityFrames: latency, params: [Float(latency)]))
        }
        return specs
    }
}

extension UnifiedGraphMIMOStage.Routed {
    /// E19 S10 (design note 10): the stage's lane layout for a routing and its plan. Source k is `plan.speakers[k]`, so the
    /// plan, the request and the stage agree on order. Every output lane is in the mask; a speaker's input is the endpoint of its
    /// in-band way with the lowest high-pass corner (the pre-crossover feed), its injections are all in-band ways. A speaker
    /// with no in-band way (an excluded one) takes its first way, so its row (all zero) still has a lane.
    static func make(
        routing: SpeakerRoutingConfiguration, plan: MIMORoutedTreatmentPlan, firstOutputLane: Int
    ) throws -> UnifiedGraphMIMOStage.Routed {
        let endpoints = routing.outputEndpoints
        guard plan.speakers.count == routing.speakers.count else { throw UnifiedGraphMIMOStage.Refusal.routedLayout }
        var inputs: [Int] = []
        var injections: [[Int]] = []
        for (speaker, planned) in zip(routing.speakers, plan.speakers) {
            let inBand = speaker.ways.filter { planned.inBandWayIDs.contains($0.id) }
            let ways = inBand.isEmpty ? Array(speaker.ways.prefix(1)) : inBand
            guard let lowest = ways.min(by: { ($0.highPass?.cornerHz ?? 0) < ($1.highPass?.cornerHz ?? 0) }),
                  let input = endpoints.firstIndex(of: lowest.endpoint) else { throw UnifiedGraphMIMOStage.Refusal.routedLayout }
            let positions = try ways.map { way -> Int in
                guard let position = endpoints.firstIndex(of: way.endpoint) else { throw UnifiedGraphMIMOStage.Refusal.routedLayout }
                return position
            }
            inputs.append(input)
            injections.append(positions)
        }
        return UnifiedGraphMIMOStage.Routed(
            firstOutputLane: firstOutputLane, outputCount: endpoints.count, inputPositions: inputs, injectionPositions: injections)
    }
}
