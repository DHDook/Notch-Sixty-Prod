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
    /// E8 S7: the way's high-pass and low-pass realised as a linear-phase FIR (the crossover then carries trim, polarity
    /// and EQ only). nil for IIR ways.
    var driverFIR: UnifiedGraphDriverFIR?
}

/// A DRIVER_FIR or DRIVER_FIR_TWO_BAND stage's content, designed for the graph's sample rate.
struct UnifiedGraphDriverFIR: Equatable, Sendable {
    var kind: UInt32
    var groupDelayFrames: UInt32
    var latencyFrames: UInt32
    var params: [Float]
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
    /// Compile-time notes (for example a linearisation left out); the validation warnings come from `validate`.
    var warnings: [SpeakerRoutingWarning] = []
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
    /// Minimum-phase (or linear-phase) driver linearisation adds latency to every output, because the alignment pads the
    /// others up to the largest. Beyond this the correction is left out and a warning says so (owner decision 26 Oct 2026).
    static let maxLinearisationLatencyMilliseconds = 50.0
    /// The deploy gate: the realised FIR may differ from the design by at most this many dB over the passband.
    static let linearisationVerifierToleranceDB = 0.5

    static func compile(
        _ routing: SpeakerRoutingConfiguration,
        onto base: UnifiedGraphConfiguration,
        preferLowLatency: Bool = false
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
        // E8 S7: a speaker's linear-phase ways share one group delay (the largest automatic choice) so their windows match
        // and their sum stays a pure delay. Low-latency mode (video) realises every way as IIR instead.
        var speakerDelay: [Int: Int] = [:]
        if !preferLowLatency {
            for (index, speaker) in routing.speakers.enumerated() {
                var delay = 0
                for way in speaker.ways where way.realisation == .fir && (way.highPass != nil || way.lowPass != nil) {
                    let plan = try? CrossoverCore.linearPhasePlan(
                        highPass: way.highPass, lowPass: way.lowPass, sampleRate: base.sampleRate)
                    delay = max(delay, plan?.groupDelayFrames ?? 0)
                    // A linearised linear-phase way needs the longer window its correction asks for (automatic choice).
                    if let lin = way.linearisation,
                       let design = try? CrossoverCore.linearise(
                        nearField: lin.nearField, farField: lin.farField, mergeHz: lin.mergeHz, highPass: way.highPass,
                        lowPass: way.lowPass, sampleRate: base.sampleRate, linearPhase: true),
                       let fir = try? CrossoverCore.linearisedDriverFIR(
                        design, highPass: way.highPass, lowPass: way.lowPass, sampleRate: base.sampleRate) {
                        delay = max(delay, fir.plan.groupDelayFrames)
                    }
                }
                speakerDelay[index] = delay
            }
        }
        var outputs: [UnifiedGraphOutputLane] = []
        var latencies: [UInt32] = []
        var notes: [SpeakerRoutingWarning] = []
        for (position, endpoint) in endpoints.enumerated() {
            var entries: [UnifiedGraphRouteEntry] = []
            var owner: RoutedWay?
            var ownerDelay = 0
            for (speakerIndex, speaker) in routing.speakers.enumerated() {
                for way in speaker.ways where way.endpoint == endpoint {
                    entries.append(UnifiedGraphRouteEntry(source: lane(speaker.source), gain: 1))
                    owner = way
                    ownerDelay = speakerDelay[speakerIndex] ?? 0
                }
            }
            for entry in routing.matrix where entry.output == endpoint {
                entries.append(UnifiedGraphRouteEntry(source: lane(entry.source), gain: Float(entry.gain)))
            }
            var protection = base.protection
            var crossover: UnifiedGraphCrossover?
            var userDelayMilliseconds = 0.0
            var driverFIR: UnifiedGraphDriverFIR?
            if let way = owner {
                var highPass = way.highPass, lowPass = way.lowPass
                let wayName = way.name.isEmpty ? way.id.uuidString : way.name
                let isFIR = way.realisation == .fir && ownerDelay > 0 && (highPass != nil || lowPass != nil)
                if let lin = way.linearisation {
                    if preferLowLatency {
                        notes.append(.linearisationSkipped(way: wayName, reason: .lowLatencyMode))
                    } else if let designed = Self.linearisedFIR(
                        lin, way: way, linearPhase: isFIR, groupDelayFrames: isFIR ? ownerDelay : 0,
                        sampleRate: base.sampleRate, name: wayName, notes: &notes) {
                        driverFIR = designed
                        if isFIR { highPass = nil; lowPass = nil }
                    }
                } else if isFIR {
                    let design = try CrossoverCore.linearPhaseDesign(
                        highPass: highPass, lowPass: lowPass, sampleRate: base.sampleRate, groupDelayFrames: ownerDelay)
                    driverFIR = UnifiedGraphDriverFIR(
                        kind: design.stageKind, groupDelayFrames: UInt32(design.plan.groupDelayFrames),
                        latencyFrames: UInt32(design.plan.latencyFrames), params: design.stageParameters)
                    highPass = nil
                    lowPass = nil
                }
                crossover = UnifiedGraphCrossover(
                    highPass: highPass, lowPass: lowPass, trimDB: way.trimDB,
                    polarityInverted: way.polarityInverted,
                    eq: way.eq.map { UnifiedGraphPEQSection(type: $0.type, frequencyHz: $0.frequencyHz, gainDB: $0.gainDB, q: $0.q) })
                userDelayMilliseconds = way.delayMilliseconds
                if let l = way.limiter {
                    protection = l.graphProtection
                }
            }
            outputs.append(UnifiedGraphOutputLane(
                lane: firstOutputLane + position, entries: entries, crossover: crossover,
                delayFrames: userDelayMilliseconds * 0.001 * base.sampleRate, protection: protection,
                driverFIR: driverFIR))
            latencies.append((protection?.latencyFrames(sampleRate: base.sampleRate) ?? 0) + (driverFIR?.latencyFrames ?? 0))
        }
        // Alignment: every physical output ends up with the same total latency (the largest limiter latency).
        let target = latencies.max() ?? 0
        for index in outputs.indices { outputs[index].delayFrames += Double(target - latencies[index]) }

        var config = base
        config.protection = nil          // replaced by the per-output protection above
        config.routing = UnifiedGraphRouting(outputs: outputs, warnings: notes)
        return config
    }

    /// Designs the way's driver FIR from its capture: minimum phase carries the correction alone (the crossover stays IIR);
    /// linear phase folds the crossover in. Returns nil, with a note, when the correction is over the latency cap or fails.
    private static func linearisedFIR(
        _ lin: RoutedWayLinearisation, way: RoutedWay, linearPhase: Bool, groupDelayFrames: Int, sampleRate: Double,
        name: String, notes: inout [SpeakerRoutingWarning]
    ) -> UnifiedGraphDriverFIR? {
        do {
            let design = try CrossoverCore.linearise(
                nearField: lin.nearField, farField: lin.farField, mergeHz: lin.mergeHz,
                highPass: way.highPass, lowPass: way.lowPass, sampleRate: sampleRate, linearPhase: linearPhase)
            let fir = try CrossoverCore.linearisedDriverFIR(
                design, highPass: way.highPass, lowPass: way.lowPass, sampleRate: sampleRate, groupDelayFrames: groupDelayFrames)
            let milliseconds = Double(fir.plan.latencyFrames) / sampleRate * 1_000
            guard milliseconds <= maxLinearisationLatencyMilliseconds else {
                notes.append(.linearisationSkipped(way: name, reason: .latencyCap(milliseconds: milliseconds)))
                return nil
            }
            let error = try CrossoverCore.verifyLinearisation(
                design, fir: fir, highPass: way.highPass, lowPass: way.lowPass, sampleRate: sampleRate)
            guard error <= linearisationVerifierToleranceDB else {
                notes.append(.linearisationSkipped(way: name, reason: .designFailed))
                return nil
            }
            return UnifiedGraphDriverFIR(
                kind: fir.stageKind, groupDelayFrames: UInt32(fir.plan.groupDelayFrames),
                latencyFrames: UInt32(fir.plan.latencyFrames), params: fir.stageParameters)
        } catch {
            notes.append(.linearisationSkipped(way: name, reason: .designFailed))
            return nil
        }
    }
}

extension UnifiedGraphConfiguration {
    static let routeStageId: UInt32 = 3_000
    static let xoverStageBase: UInt32 = 3_100
    static let outputProtectionStageBase: UInt32 = 3_200
    static let driverFIRStageBase: UInt32 = 3_300

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
            guard let fir = output.driverFIR else { continue }
            let id = UInt32(output.lane)
            rest.append(UnifiedGraphStageSpec(
                kind: fir.kind, stageId: Self.driverFIRStageBase + id, laneA: id,
                capacityFrames: fir.groupDelayFrames, params: fir.params))
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
