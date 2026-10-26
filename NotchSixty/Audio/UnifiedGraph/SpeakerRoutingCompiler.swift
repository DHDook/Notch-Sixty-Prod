import Foundation

// E8 S3: compiles a `SpeakerRoutingConfiguration` onto a program graph. Pure and deterministic. Not wired to the live
// session yet (E8 S4). The graph this describes has lanes [program][sub][output], where each output lane is one
// physical output (a way, or a matrix-only output); see `n60/graph.h`, "Speaker routing".

struct UnifiedGraphRouteEntry: Equatable, Sendable {
    var source: Int
    var gain: Float
}

/// One output lane of a routed graph.
struct UnifiedGraphOutputLane: Equatable, Sendable {
    /// Absolute graph lane (after the program and sub lanes).
    var lane: Int
    /// At most `N60_ROUTE_MAX_ENTRIES` entries, summed into this lane.
    var entries: [UnifiedGraphRouteEntry]
    /// nil leaves the lane without an XOVER stage (a matrix-only output).
    var crossover: UnifiedGraphCrossover?
    /// Total delay in frames: the driver's own delay plus the latency alignment.
    var delayFrames: Double
    var protection: UnifiedGraphProtection?
}

/// An XOVER stage's content.
struct UnifiedGraphCrossover: Equatable, Sendable {
    var highPass: CrossoverCore.FilterSpec?
    var lowPass: CrossoverCore.FilterSpec?
    var trimDB: Double = 0
    var polarityInverted = false
    var eq: [UnifiedGraphPEQSection] = []
}

struct UnifiedGraphRouting: Equatable, Sendable {
    var outputs: [UnifiedGraphOutputLane]
    var outputLaneCount: Int { outputs.count }
}

enum SpeakerRoutingCompileError: Error, Equatable {
    case invalid([SpeakerRoutingError])
}

extension UnifiedGraphProtection {
    /// The PROTECTION stage's latency in frames, as the core computes it (half-band plus look-ahead).
    func latencyFrames(sampleRate: Double) -> UInt32 {
        let clipperOn = clipper?.enabled ?? false
        guard limiterEnabled || clipperOn else { return 0 }
        let factor: UInt32 = (limiterEnabled && truePeakGuard) ? 4 : UInt32(max(1, oversampling))
        let highRate = sampleRate * Double(factor)
        let lookAheadHigh = limiterEnabled
            ? UInt32((Double(Float(lookAheadMilliseconds)) * 0.001 * highRate).rounded(.up)) : 0
        let osLatency: UInt32 = factor == 2 ? 32 : (factor == 4 ? 48 : 0)
        return osLatency + (lookAheadHigh + factor - 1) / factor
    }
}

enum SpeakerRoutingCompiler {
    static func compile(
        _ routing: SpeakerRoutingConfiguration,
        onto base: UnifiedGraphConfiguration
    ) throws -> UnifiedGraphConfiguration {
        let context = SpeakerRoutingContext(
            programLanes: base.lanes.count, subwoofers: base.subwooferCount, sampleRate: base.sampleRate)
        let validation = routing.validate(in: context)
        guard validation.isValid else { throw SpeakerRoutingCompileError.invalid(validation.errors) }

        let firstOutputLane = base.lanes.count + base.subwooferCount
        func lane(_ source: RoutingSource) -> Int {
            source.kind == .program ? source.index : base.lanes.count + source.index
        }
        let endpoints = routing.outputEndpoints
        var outputs: [UnifiedGraphOutputLane] = []
        var latencies: [UInt32] = []
        for (position, endpoint) in endpoints.enumerated() {
            var entries: [UnifiedGraphRouteEntry] = []
            var owner: RoutedWay?
            for speaker in routing.speakers {
                for way in speaker.ways where way.endpoint == endpoint {
                    entries.append(UnifiedGraphRouteEntry(source: lane(speaker.source), gain: 1))
                    owner = way
                }
            }
            for entry in routing.matrix where entry.output == endpoint {
                entries.append(UnifiedGraphRouteEntry(source: lane(entry.source), gain: Float(entry.gain)))
            }
            var protection = base.protection
            var crossover: UnifiedGraphCrossover?
            var userDelayMilliseconds = 0.0
            if let way = owner {
                crossover = UnifiedGraphCrossover(
                    highPass: way.highPass, lowPass: way.lowPass, trimDB: way.trimDB,
                    polarityInverted: way.polarityInverted,
                    eq: way.eq.map { UnifiedGraphPEQSection(type: $0.type, frequencyHz: $0.frequencyHz, gainDB: $0.gainDB, q: $0.q) })
                userDelayMilliseconds = way.delayMilliseconds
                if let l = way.limiter {
                    protection = l.graphProtection
                }
            }
            outputs.append(UnifiedGraphOutputLane(
                lane: firstOutputLane + position, entries: entries, crossover: crossover,
                delayFrames: userDelayMilliseconds * 0.001 * base.sampleRate, protection: protection))
            latencies.append(protection?.latencyFrames(sampleRate: base.sampleRate) ?? 0)
        }
        // Alignment: every physical output ends up with the same total latency (the largest limiter latency).
        let target = latencies.max() ?? 0
        for index in outputs.indices { outputs[index].delayFrames += Double(target - latencies[index]) }

        var config = base
        config.protection = nil          // replaced by the per-output protection above
        config.routing = UnifiedGraphRouting(outputs: outputs)
        return config
    }
}

extension UnifiedGraphConfiguration {
    static let routeStageId: UInt32 = 3_000
    static let xoverStageBase: UInt32 = 3_100
    static let outputProtectionStageBase: UInt32 = 3_200

    /// ROUTE, XOVER, per-output DELAY or FRAC_DELAY and PROTECTION stages, appended in the core's order by `makeSpec`.
    func routeStages(programLanes: Int) throws -> (route: [UnifiedGraphStageSpec], rest: [UnifiedGraphStageSpec]) {
        guard let routing, !routing.outputs.isEmpty else { return ([], []) }
        let firstLane = programLanes + subwooferCount
        var mask: UInt64 = 0
        var params: [Float] = []
        for (position, output) in routing.outputs.enumerated() {
            guard output.lane == firstLane + position, output.entries.count <= Int(N60_ROUTE_MAX_ENTRIES),
                  !output.entries.isEmpty else {
                throw UnifiedGraphError.invalidConfiguration("route destination")
            }
            mask |= UInt64(1) << UInt64(output.lane)
            for entry in output.entries {
                guard entry.source >= 0, entry.source < firstLane, entry.gain.isFinite, abs(entry.gain) <= 100 else {
                    throw UnifiedGraphError.invalidConfiguration("route entry")
                }
                params += [Float(entry.source), entry.gain]
            }
            for _ in output.entries.count..<Int(N60_ROUTE_MAX_ENTRIES) { params += [-1, 0] }
        }
        let route = UnifiedGraphStageSpec(
            kind: N60_STAGE_ROUTE.rawValue, stageId: Self.routeStageId, laneA: 0, laneMask: mask, params: params)

        var rest: [UnifiedGraphStageSpec] = []
        func off() -> [Float] { [Float(N60_GRAPH_FILTER_OFF), 0, 0] }
        func filter(_ spec: CrossoverCore.FilterSpec?) -> [Float] {
            spec.map { [Float($0.family.rawValue), Float($0.order), Float($0.cornerHz)] } ?? off()
        }
        for output in routing.outputs {
            let id = UInt32(output.lane)
            if let x = output.crossover {
                guard (-60.0...24.0).contains(x.trimDB) else { throw UnifiedGraphError.invalidConfiguration("way trim") }
                let eq = try Self.peqParameters(x.eq)
                let p: [Float] = filter(x.highPass) + filter(x.lowPass)
                    + [Float(x.trimDB), x.polarityInverted ? 1 : 0, 0, 0, 0, 0, 0, Float(x.eq.count)] + eq
                rest.append(UnifiedGraphStageSpec(
                    kind: N60_STAGE_XOVER.rawValue, stageId: Self.xoverStageBase + id, laneA: id, params: p))
            }
        }
        for output in routing.outputs {
            let id = UInt32(output.lane)
            let total = output.delayFrames
            guard total.isFinite, total >= 0, total <= Double(N60_GRAPH_MAX_DELAY_FRAMES) else {
                throw UnifiedGraphError.invalidConfiguration("way delay")
            }
            let whole = total.rounded(.down)
            if total - whole > 1e-6, total < 8190 {
                rest.append(UnifiedGraphStageSpec(
                    kind: N60_STAGE_FRAC_DELAY.rawValue, stageId: Self.delayStageBase + id, laneA: id,
                    params: [Float(whole), Float(total - whole)]))
            } else {
                let frames = UInt32(total.rounded())
                if frames >= 1 {
                    rest.append(UnifiedGraphStageSpec(
                        kind: N60_STAGE_DELAY.rawValue, stageId: Self.delayStageBase + id, laneA: id,
                        capacityFrames: frames, params: [Float(frames)]))
                }
            }
        }
        for output in routing.outputs {
            guard let protection = output.protection else { continue }
            let id = UInt32(output.lane)
            rest.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_PROTECTION.rawValue, stageId: Self.outputProtectionStageBase + id,
                laneA: 0, laneMask: UInt64(1) << UInt64(id), params: Self.protectionParameters(protection)))
        }
        return ([route], rest)
    }
}
