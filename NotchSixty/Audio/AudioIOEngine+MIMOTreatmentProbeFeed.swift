import Foundation

/// E19 S12c (D15, mechanism B): the engine's probe stimulus feed. The measurement generator (a cued sweep, graph ABI v48) is
/// installed once, with the stage unarmed, and afterwards only posts live words: the cue (a new sweep) and the solo (which
/// source plays). A post never rebuilds, so it never goes through `graphRebuilt()` and an armed stage stays armed; a request
/// that would rebuild while the stage is armed throws and changes nothing (decision 1). Control plane, main actor.
extension AudioIOEngine {
    /// The live words of a cued sweep generator.
    struct ProbeCue: Equatable {
        /// 0 plays every mask lane; k plays only the k-th mask lane (ascending).
        var solo = 0
        /// Each change starts the sweep.
        var cue = 0
        /// Word [9]; false returns programme on the mask lanes.
        var active = true
    }

    /// A generator the engine keeps playing across live graph edits. `probe` is set for the cued sweep of the probe.
    struct LiveGenerator: Equatable {
        var settings: SignalGeneratorSettings
        var selection: SignalGeneratorLaneSelection
        var probe: ProbeCue?

        /// The core stage parameters at `sampleRate` (11 floats, or 13 for the cued sweep), or nil when they are not valid.
        func stageParams(sampleRate: Double) -> [Float]? {
            guard let probe else { return settings.stageParams(active: true, sampleRate: sampleRate) }
            return settings.cuedStageParams(active: probe.active, sampleRate: sampleRate, solo: probe.solo, cue: probe.cue)
        }
    }

    /// Installs the probe's cued sweep generator on program lanes `lanes` (ascending). Refuses while the stage is armed
    /// (the install rebuilds, which would disarm it) or when another generator is playing. Programme is replaced by silence on
    /// those lanes from here until `removeProbeStimulus`.
    func installProbeStimulus(_ settings: SignalGeneratorSettings, programLanes lanes: [Int]) throws {
        guard let session = nChannelTransportSession, liveGraphEditsAvailable else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        guard !mimoGraphTreatment.isArmed else { throw MIMOProbeFeedError.stageArmed }
        guard liveGenerator == nil else { throw MIMOProbeFeedError.generatorBusy }
        guard settings.kind == .sweep, lanes == lanes.sorted(), Set(lanes).count == lanes.count,
              settings.cuedStageParams(active: true, sampleRate: session.outputFormat.sampleRate, solo: 0, cue: 0) != nil else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
        }
        var wanted = LiveGenerator(settings: settings, selection: .lanes(lanes))
        wanted.probe = ProbeCue()
        var inputs = currentLiveGraphInputs
        inputs.generator = wanted
        try republishLiveGraph(inputs)
        liveGenerator = wanted
    }

    /// True while the probe's generator is installed.
    var probeStimulusInstalled: Bool { liveGenerator?.probe != nil }

    /// Starts one sweep on source `solo` (1-based position in the installed lanes; 0 = all) by posting the solo and cue words.
    /// Post-only: throws without touching the graph or the arm when the edit would need a rebuild.
    func cueProbeStimulus(solo: Int) throws {
        try postProbeCue { cue in
            guard cue.cue < 16_777_216 else { throw MIMOProbeFeedError.cueExhausted }
            cue.solo = solo
            cue.cue += 1
        }
    }

    /// Posts word [9] (false returns programme on the mask lanes after the 100 ms ramp). Post-only.
    func setProbeStimulusActive(_ active: Bool) throws {
        try postProbeCue { $0.active = active }
    }

    private func postProbeCue(_ change: (inout ProbeCue) throws -> Void) throws {
        guard let session = nChannelTransportSession, var generator = liveGenerator, var probe = generator.probe else {
            throw MIMOProbeFeedError.notInstalled
        }
        try change(&probe)
        generator.probe = probe
        guard var configuration = session.currentGraphConfiguration,
              let params = generator.stageParams(sampleRate: session.outputFormat.sampleRate) else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
        }
        configuration.generatorParams = params
        try session.republishGraph(configuration, postOnly: true)
        liveGenerator = generator
    }

    /// Ends the probe's stimulus. The stage is disarmed first (explicitly, then again by the rebuild's own interlock), word [9]
    /// goes to 0 as a post, and only then is the generator removed by a normal republish. A failed removal leaves the generator
    /// installed (programme stays replaced, never half-removed).
    func removeProbeStimulus() throws {
        guard liveGenerator?.probe != nil else { return }
        if mimoGraphTreatment.isArmed { mimoGraphTreatment.userDisarm() }
        try? setProbeStimulusActive(false)
        var inputs = currentLiveGraphInputs
        inputs.generator = nil
        try republishLiveGraph(inputs)
        liveGenerator = nil
    }
}

enum MIMOProbeFeedError: Error, Equatable, LocalizedError {
    case stageArmed
    case generatorBusy
    case notInstalled
    case cueExhausted

    var errorDescription: String? {
        switch self {
        case .stageArmed: return "The measurement stimulus cannot be installed while Room Treatment is armed."
        case .generatorBusy: return "Another test signal is playing; stop it before the treated measurement."
        case .notInstalled: return "The measurement stimulus is not installed."
        case .cueExhausted: return "The measurement stimulus ran out of cues."
        }
    }
}

extension AudioIOEngine: MIMOProbeStimulusFeeding {
    var probeOutputSampleRate: Double? { nChannelTransportSession?.outputFormat.sampleRate }
    var probeStageArmed: Bool { mimoGraphTreatment.isArmed }

    /// The staged design's sources, in source order, with the program lane that can play each alone. A source on a sub lane
    /// or on a routed output has no program lane (the generator sits ahead of bass management and routing): its lane is nil.
    func probeSources() -> [MIMOProbeSource] {
        guard let session = nChannelTransportSession, let stage = mimoGraphTreatment.stage else { return [] }
        let roles = session.routePlan.programLayout.roles
        return stage.sourceLanes.map { lane in
            if stage.routed != nil { return MIMOProbeSource(source: nil, programLane: nil) }
            if lane < roles.count { return MIMOProbeSource(source: .speaker(roles[lane]), programLane: lane) }
            return MIMOProbeSource(source: .subwoofer(UInt32(lane - roles.count)), programLane: nil)
        }
    }
}
