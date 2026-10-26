import Foundation

// E8 S9: the advanced pipeline view's model. For each physical output it lists the stages a sample passes through,
// from source to physical channel, with the latency each adds. It reads the same routing model the compiler does and
// uses the same protection-latency rule and alignment, so the totals match the graph. Pure value logic.

struct SpeakerRoutingProgramStage: Equatable, Sendable {
    var name: String
    var latencyFrames: Double = 0
}

struct SpeakerRoutingPipelineStep: Equatable, Sendable {
    var title: String
    var detail: String
    var latencyFrames: Double
}

struct SpeakerRoutingPipelineRow: Equatable, Sendable {
    var output: PhysicalOutputEndpoint
    var title: String
    var steps: [SpeakerRoutingPipelineStep]
    var totalLatencyFrames: Double { steps.reduce(0) { $0 + $1.latencyFrames } }

    func totalLatencyMilliseconds(sampleRate: Double) -> Double { totalLatencyFrames / sampleRate * 1000 }
}

extension RoutingLimiter {
    /// The PROTECTION stage settings for this limiter.
    var graphProtection: UnifiedGraphProtection {
        UnifiedGraphProtection(
            ceilingDB: ceilingDB, attackMilliseconds: attackMilliseconds, releaseMilliseconds: releaseMilliseconds,
            lookAheadMilliseconds: lookAheadMilliseconds, truePeakGuard: truePeakGuard, oversampling: oversampling)
    }
}

enum SpeakerRoutingPipeline {
    /// `programStages` are the stages every program lane passes before the route (room correction, EQ, ...), each with
    /// its latency; `defaultProtection` is the session's protection that outputs without their own limiter use.
    static func rows(
        _ routing: SpeakerRoutingConfiguration,
        context: SpeakerRoutingContext,
        programStages: [SpeakerRoutingProgramStage] = [],
        defaultProtection: UnifiedGraphProtection? = nil
    ) -> [SpeakerRoutingPipelineRow] {
        let rate = context.sampleRate
        let endpoints = routing.outputEndpoints
        struct Plan {
            var endpoint: PhysicalOutputEndpoint
            var way: RoutedWay?
            var sources: [(RoutingSource, Double)]
            var protection: UnifiedGraphProtection?
            var protectionFrames: Double
        }
        let plans: [Plan] = endpoints.map { endpoint in
            var way: RoutedWay?
            var sources: [(RoutingSource, Double)] = []
            for speaker in routing.speakers {
                for w in speaker.ways where w.endpoint == endpoint { way = w; sources.append((speaker.source, 1)) }
            }
            for entry in routing.matrix where entry.output == endpoint { sources.append((entry.source, entry.gain)) }
            let protection = way?.limiter?.graphProtection ?? defaultProtection
            return Plan(endpoint: endpoint, way: way, sources: sources, protection: protection,
                        protectionFrames: Double(protection?.latencyFrames(sampleRate: rate) ?? 0))
        }
        let target = plans.map(\.protectionFrames).max() ?? 0

        return plans.map { plan in
            var steps: [SpeakerRoutingPipelineStep] = []
            let sourceNames = plan.sources.map { sourceName($0.0) }
            steps.append(SpeakerRoutingPipelineStep(
                title: "Source", detail: sourceNames.isEmpty ? "none" : sourceNames.joined(separator: " + "), latencyFrames: 0))
            for stage in programStages {
                steps.append(SpeakerRoutingPipelineStep(title: stage.name, detail: "program", latencyFrames: stage.latencyFrames))
            }
            steps.append(SpeakerRoutingPipelineStep(
                title: "Route",
                detail: plan.sources.count == 1 ? "1 feed" : "\(plan.sources.count) feeds summed", latencyFrames: 0))
            if let way = plan.way {
                steps.append(SpeakerRoutingPipelineStep(title: "Crossover", detail: crossoverDetail(way), latencyFrames: 0))
                if !way.eq.isEmpty {
                    steps.append(SpeakerRoutingPipelineStep(
                        title: "Driver EQ", detail: "\(way.eq.count) section\(way.eq.count == 1 ? "" : "s")", latencyFrames: 0))
                }
            }
            let userFrames = (plan.way?.delayMilliseconds ?? 0) * 0.001 * rate
            let alignment = target - plan.protectionFrames
            let delayTotal = userFrames + alignment
            if delayTotal > 0 {
                var parts: [String] = []
                if userFrames > 0 { parts.append(String(format: "%.2f ms driver delay", userFrames / rate * 1000)) }
                if alignment > 0 { parts.append(String(format: "%.0f frames alignment", alignment)) }
                steps.append(SpeakerRoutingPipelineStep(title: "Delay", detail: parts.joined(separator: " + "), latencyFrames: delayTotal))
            }
            if let protection = plan.protection {
                steps.append(SpeakerRoutingPipelineStep(
                    title: "Protection", detail: String(format: "ceiling %.1f dB", protection.ceilingDB),
                    latencyFrames: plan.protectionFrames))
            }
            steps.append(SpeakerRoutingPipelineStep(
                title: "Output", detail: "channel \(plan.endpoint.channelIndex + 1) on \(plan.endpoint.deviceUID)", latencyFrames: 0))
            return SpeakerRoutingPipelineRow(
                output: plan.endpoint, title: plan.way?.name.isEmpty == false ? plan.way!.name : "Output \(plan.endpoint.channelIndex + 1)",
                steps: steps)
        }
    }

    static func sourceName(_ source: RoutingSource) -> String {
        source.kind == .program ? "Program lane \(source.index + 1)" : "Subwoofer \(source.index + 1)"
    }

    static func filterDescription(_ spec: CrossoverCore.FilterSpec, highPass: Bool) -> String {
        let family: String
        switch spec.family {
        case .butterworth: family = "Butterworth"
        case .bessel: family = "Bessel"
        case .linkwitzRiley: family = "Linkwitz-Riley"
        }
        return "\(family) \(spec.slopeDBPerOctave) dB/oct \(highPass ? "high" : "low")-pass \(Int(spec.cornerHz.rounded())) Hz"
    }

    private static func crossoverDetail(_ way: RoutedWay) -> String {
        var parts: [String] = []
        if let hp = way.highPass { parts.append(filterDescription(hp, highPass: true)) }
        if let lp = way.lowPass { parts.append(filterDescription(lp, highPass: false)) }
        if way.trimDB != 0 { parts.append(String(format: "trim %+.1f dB", way.trimDB)) }
        if way.polarityInverted { parts.append("inverted") }
        return parts.isEmpty ? "full range" : parts.joined(separator: ", ")
    }
}
