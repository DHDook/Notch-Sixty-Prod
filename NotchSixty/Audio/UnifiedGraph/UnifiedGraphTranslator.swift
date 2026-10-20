import Foundation

/// E6 S8: turns what the shipping engine already computes (the kernel DSP snapshot, the
/// multichannel route plan, the sub calibration) into a `UnifiedGraphConfiguration`.
/// Returns nil (never throws) when the core cannot reproduce the snapshot, so the caller
/// keeps the kernel path for that snapshot. Control thread only.
enum UnifiedGraphTranslator {
    /// Stereo snapshot to a two-lane configuration, or nil when the kernel must render it.
    static func stereoConfiguration(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80
    ) -> UnifiedGraphConfiguration? {
        try? stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate, subwoofers: subwoofers, crossoverHz: crossoverHz
        ).get()
    }

    /// As `stereoConfiguration`, but says why the kernel keeps the snapshot.
    static func stereoEligibility(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80
    ) -> Result<UnifiedGraphConfiguration, UnifiedGraphFallbackReason> {
        guard withUnsafePointer(to: &snapshot, {
            N60UnifiedGraphSnapshotUnsupportedReason($0) == N60UnifiedGraphSupported
        }) else { return .failure(.unsupportedKernelStage) }

        var left: [UnifiedGraphPEQSection] = []
        var right: [UnifiedGraphPEQSection] = []
        withUnsafePointer(to: &snapshot) { pointer in
            var band = N60UnifiedGraphBand()
            var index: UInt32 = 0
            while !pointer.pointee.eqBypassed, N60UnifiedGraphReadBand(pointer, index, &band) {
                index += 1
                guard band.enabled else { continue }
                let section = UnifiedGraphPEQSection(
                    type: Int(band.type), frequencyHz: band.frequencyHz,
                    gainDB: band.gainDB, q: band.q
                )
                if band.channelMask & UInt8(N60_EQ_CHANNEL_LEFT) != 0 { left.append(section) }
                if band.channelMask & UInt8(N60_EQ_CHANNEL_RIGHT) != 0 { right.append(section) }
            }
        }

        let output = snapshot.outputGainLinear * snapshot.masterGainLinear
        var configuration = UnifiedGraphConfiguration(
            sampleRate: sampleRate,
            lanes: [
                UnifiedGraphLane(outputGain: output * snapshot.balanceGainLeftLinear, eq: left),
                UnifiedGraphLane(outputGain: output * snapshot.balanceGainRightLinear, eq: right),
            ]
        )
        configuration.inputGain = snapshot.inputGainLinear * snapshot.headroomGainLinear
        guard let stages = stereoStages(snapshot: &snapshot, configuration: &configuration) else {
            return .failure(.stageParametersUnreadable)
        }
        configuration.stereoStages = stages
        if snapshot.protection.limiterEnabled || snapshot.protection.truePeakGuardEnabled {
            let p = snapshot.protection
            let ceilingDB = 20.0 * log10(Double(max(p.limiterCeilingLinear, 1e-6)))
            guard ceilingDB >= -20, ceilingDB <= 0 else { return .failure(.protectionCeilingOutOfRange) }
            configuration.protection = UnifiedGraphProtection(
                limiterEnabled: p.limiterEnabled,
                ceilingDB: ceilingDB,
                attackMilliseconds: Double(p.limiterAttackMs),
                releaseMilliseconds: Double(p.limiterReleaseMs),
                lookAheadMilliseconds: Double(p.limiterLookAheadMs),
                truePeakGuard: p.truePeakGuardEnabled,
                oversampling: (p.limiterEnabled && p.truePeakGuardEnabled) ? 4 : 2
            )
        }
        if !subwoofers.isEmpty {
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: crossoverHz, lfeLane: nil, subwoofers: subwoofers
            )
        }
        return .success(configuration)
    }

    /// The kernel stages between the EQ and the output gain that the core reproduces. The
    /// eligibility check has already accepted every parameter list read here; a failed read is
    /// still treated as ineligible rather than approximated.
    private static func stereoStages(
        snapshot: inout N60DSPGraphSnapshot,
        configuration: inout UnifiedGraphConfiguration
    ) -> UnifiedGraphStereoStages? {
        var stages = UnifiedGraphStereoStages()
        stages.midSideEQ = snapshot.eqMidSideMode && !snapshot.eqBypassed
        var ok = true
        withUnsafePointer(to: &snapshot) { pointer in
            let dynamics = pointer.pointee.dynamics
            if dynamics.compressor.enabled {
                var values = [Float](repeating: 0, count: 10)
                if N60UnifiedGraphCompressorParams(pointer, &values) { stages.compressor = values } else { ok = false }
            }
            if dynamics.expander.enabled {
                var values = [Float](repeating: 0, count: 6)
                if N60UnifiedGraphExpanderParams(pointer, &values) { stages.expander = values } else { ok = false }
            }
            if dynamics.pauseGate.enabled {
                var values = [Float](repeating: 0, count: 5)
                if N60UnifiedGraphPauseGateParams(pointer, &values) { stages.pauseGate = values } else { ok = false }
            }
            if pointer.pointee.ambientCompensation.enabled {
                var values = [Float](repeating: 0, count: 10)
                if N60UnifiedGraphAmbientParams(pointer, &values) { stages.ambient = values } else { ok = false }
            }
            if pointer.pointee.symmetryBalance.enabled {
                stages.symmetryPosition = Float(pointer.pointee.symmetryBalance.position)
            }
            if pointer.pointee.speakerCrossfeed.enabled {
                stages.crossfeedAmount = pointer.pointee.speakerCrossfeed.amount
            }
            if pointer.pointee.crosstalkCancellation.enabled {
                let c = pointer.pointee.crosstalkCancellation
                stages.crosstalk = [Float(c.headShadowFrequencyHz), c.amount]
            }
            if pointer.pointee.interChannelDelay.enabled {
                var frames: (UInt32, UInt32) = (0, 0)
                let read = withUnsafeMutablePointer(to: &frames) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 2) { N60UnifiedGraphIntegerDelay(pointer, $0) }
                }
                if read {
                    configuration.lanes[0].delayFrames = frames.0
                    configuration.lanes[1].delayFrames = frames.1
                } else { ok = false }
            }
        }
        return ok ? stages : nil
    }

    /// A multichannel speaker layout with `programChannels` lanes and 0 to 8 sub lanes.
    /// `trimsDB` is the per-lane calibration gain; lane `lfeLane` (if any) carries the LFE.
    static func multichannelConfiguration(
        sampleRate: Double,
        programChannels: Int,
        lfeLane: Int? = nil,
        trimsDB: [Double] = [],
        masterGain: Float = 1,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80,
        delaysMilliseconds: [Double] = []
    ) -> UnifiedGraphConfiguration {
        var lanes: [UnifiedGraphLane] = []
        for index in 0..<programChannels {
            var lane = UnifiedGraphLane(outputGain: masterGain)
            if index < trimsDB.count { lane.preGain = Float(pow(10.0, trimsDB[index] / 20.0)) }
            if index < delaysMilliseconds.count { lane.delayMilliseconds = delaysMilliseconds[index] }
            lanes.append(lane)
        }
        var configuration = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: lanes)
        if !subwoofers.isEmpty {
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: crossoverHz, lfeLane: lfeLane, subwoofers: subwoofers
            )
        }
        return configuration
    }

    /// The live N-channel session's lanes, bass management and 1 to 8 subs as a graph
    /// configuration (E6 S8b2b), or nil when the legacy render core must keep the session. It
    /// mirrors `LiveNChannelRenderGraphCompiler.makeGraph` field for field. Ineligible, because
    /// the core cannot reproduce them exactly: an optimizer FIR, a polarity-inverted or silent
    /// lane, a lane delay under bass management (the legacy order puts it before the
    /// crossover, the core after), and any crossover other than Linkwitz-Riley 24.
    static func nChannelConfiguration(
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration
    ) -> UnifiedGraphConfiguration? {
        try? nChannelEligibility(
            routePlan: routePlan, sampleRate: sampleRate, gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        ).get()
    }

    /// As `nChannelConfiguration`, but says why the legacy render core keeps the session.
    static func nChannelEligibility(
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration
    ) -> Result<UnifiedGraphConfiguration, UnifiedGraphFallbackReason> {
        guard routePlan.speakerOptimizerFIR == nil else { return .failure(.optimizerFIR) }
        let roles = routePlan.programLayout.roles
        let bassEnabled = bassManagementConfiguration.enabled
        let subCount = Int(routePlan.subwooferCount)
        if bassEnabled {
            guard bassManagementConfiguration.topology == .linkwitzRiley24 else {
                return .failure(.nonLR4Crossover)
            }
            guard subCount <= UnifiedGraphConfiguration.maxSubwoofers else { return .failure(.tooManySubs) }
            guard subCount >= 1 else { return .failure(.noSubForBassManagement) }
            guard routePlan.subwooferCalibrations.count >= subCount else {
                return .failure(.subCalibrationMissing)
            }
        }
        guard !roles.isEmpty else { return .failure(.noProgramLanes) }
        guard roles.count + (bassEnabled ? subCount : 0) <= Int(N60_GRAPH_MAX_CHANNELS) else {
            return .failure(.tooManyChannels)
        }
        let combinedDB = gainConfiguration.inputPreampDB + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
            - (routePlan.speakerOptimizerFIR?.requiredHeadroomDB ?? 0)
        let combined = DSPGainConfiguration.linearGain(forDB: combinedDB)
        guard combined.isFinite, combined > 0, combined <= 16 else { return .failure(.gainOutOfRange) }

        func sections(_ bands: [OutputCalibrationEQBand]) -> [UnifiedGraphPEQSection] {
            bands.map { UnifiedGraphPEQSection(type: 0, frequencyHz: $0.frequencyHz, gainDB: $0.gainDB, q: $0.q) }
        }
        var lanes: [UnifiedGraphLane] = []
        var lfeLane: Int?
        for (index, role) in roles.enumerated() {
            let calibration = routePlan.speakerCalibrations[role]
            if calibration?.polarityInverted == true { return .failure(.invertedPolarity) }
            let delay = calibration?.delayMilliseconds ?? 0
            if bassEnabled, delay > 0 { return .failure(.laneDelayUnderBassMgmt) }
            let lfeGainDB = role == .lowFrequencyEffects && !bassEnabled
                ? LiveNChannelRenderGraphCompiler.lfeInBandGainDB : 0
            let gain = combined * DSPGainConfiguration.linearGain(
                forDB: (calibration?.trimDB ?? 0) + lfeGainDB)
            guard gain.isFinite, gain > 0, gain <= 10_000 else { return .failure(.gainOutOfRange) }
            var peq = sections(calibration?.eqBands ?? [])
            if let optimizer = routePlan.speakerOptimizerPEQ[role] {
                peq += optimizer.map {
                    UnifiedGraphPEQSection(type: 0, frequencyHz: $0.frequencyHz, gainDB: $0.gainDB, q: $0.q)
                }
            }
            if peq.count > Int(N60_PEQ_MAX_SECTIONS) { return .failure(.laneEQTooLarge) }
            lanes.append(UnifiedGraphLane(preGain: gain, delayMilliseconds: delay, eq: peq))
            if role == .lowFrequencyEffects { lfeLane = index }
        }
        var configuration = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: lanes)
        if bassEnabled {
            var subs: [UnifiedGraphSubwoofer] = []
            for index in 0..<subCount {
                let calibration = routePlan.subwooferCalibrations[index]
                let gainDB = bassManagementConfiguration.subGainDB + (calibration?.gainDB ?? 0)
                guard (-60.0...24.0).contains(gainDB) else { return .failure(.subGainOutOfRange) }
                guard (calibration?.eqBands.count ?? 0) <= 8 else { return .failure(.subEQTooLarge) }
                subs.append(UnifiedGraphSubwoofer(
                    gainDB: gainDB,
                    polarityInverted: bassManagementConfiguration.subPolarityInverted
                        != (calibration?.polarityInverted ?? false),
                    delayMilliseconds: calibration?.delayMilliseconds ?? 0,
                    eq: sections(calibration?.eqBands ?? [])
                ))
            }
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: bassManagementConfiguration.frequencyHz,
                lfeLane: lfeLane,
                lfeLowPassHz: LiveNChannelRenderGraphCompiler.lfeLowPassHz,
                lfeGainDB: LiveNChannelRenderGraphCompiler.lfeInBandGainDB,
                subwoofers: subs
            )
        }
        return .success(configuration)
    }

    /// Binaural profile data for `layoutSpec`: `orientations * channels * 2 * taps` responses.
    struct BinauralProfile {
        var taps: UInt32
        var orientations: UInt32 = 1
        var yawStartDeg: Float = 0
        var yawStepDeg: Float = 0
        var wrap: UInt32 = 0
        var equalEarChannel: Int32 = -1
        var responses: [Float]
    }

    /// A standard layout (`N60_LAYOUT_*`) rendered to speakers or, with a profile, to ears
    /// on lanes 0 and 1, through the core's own layout builder.
    static func layoutSpec(
        layoutIdentifier: UInt32,
        sampleRate: Double,
        binaural: BinauralProfile? = nil,
        headphoneCrossfeed: Float = 0,
        linkedDynamics: Bool = false,
        protection: Bool = true,
        maxBlockFrames: UInt32 = 16_384
    ) throws -> UnifiedGraphSpec {
        var layout = n60_layout()
        layout.structSize = UInt32(MemoryLayout<n60_layout>.size)
        let layoutStatus = n60_layout_standard(layoutIdentifier, &layout)
        guard layoutStatus == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(layoutStatus.rawValue) }

        var options = n60_layout_options()
        options.structSize = UInt32(MemoryLayout<n60_layout_options>.size)
        options.sampleRate = sampleRate
        options.maxBlockFrames = maxBlockFrames
        options.mode = binaural == nil ? N60_MODE_SPEAKERS.rawValue : N60_MODE_BINAURAL.rawValue
        options.linkedDynamics = linkedDynamics ? 1 : 0
        options.headphoneCrossfeed = headphoneCrossfeed
        options.protection = protection ? 1 : 0

        var built: OpaquePointer?
        func build(_ options: inout n60_layout_options) -> n60_status {
            withUnsafePointer(to: &layout) { layoutPointer in
                options.layout = layoutPointer
                return n60_layout_graph_build(&options, &built)
            }
        }
        let status: n60_status
        if let binaural {
            status = binaural.responses.withUnsafeBufferPointer { responses in
                var profile = n60_binaural_profile()
                profile.structSize = UInt32(MemoryLayout<n60_binaural_profile>.size)
                profile.taps = binaural.taps
                profile.orientations = binaural.orientations
                profile.yawStartDeg = binaural.yawStartDeg
                profile.yawStepDeg = binaural.yawStepDeg
                profile.wrap = binaural.wrap
                profile.equalEarChannel = binaural.equalEarChannel
                profile.responses = responses.baseAddress
                return withUnsafePointer(to: &profile) { profilePointer in
                    options.binaural = profilePointer
                    return build(&options)
                }
            }
        } else {
            status = build(&options)
        }
        guard status == N60_STATUS_OK, let built else {
            throw UnifiedGraphError.coreStatus(status.rawValue)
        }
        defer { n60_layout_graph_free(built) }
        guard let description = n60_layout_graph_desc(built) else {
            throw UnifiedGraphError.invalidConfiguration("layout description")
        }
        var spec = UnifiedGraphSpec(copying: description)
        spec.maxBlockFrames = maxBlockFrames
        return spec
    }
}


/// E6 S8b2b: why a session that asked for the unified graph (`e6.unified-graph` on) is still
/// rendered by the legacy path. Recorded by the translator and the transport sessions and
/// surfaced in `UnifiedGraphDiagnostics`, so a fallback is never silent.
enum UnifiedGraphFallbackReason: String, Error, Equatable, Sendable, CaseIterable {
    // N-channel and stereo eligibility (translator).
    /// A speaker optimizer FIR is in the route; the core has no equivalent FIR lane stage.
    case optimizerFIR
    /// A lane or sub with inverted polarity that the legacy core applies in a different place.
    case invertedPolarity
    /// A lane delay under bass management (legacy: before the crossover; core: after).
    case laneDelayUnderBassMgmt
    /// Bass management with a crossover other than Linkwitz-Riley 24 dB.
    case nonLR4Crossover
    /// More than eight subwoofers.
    case tooManySubs
    /// Bass management enabled with no subwoofer lane.
    case noSubForBassManagement
    /// Fewer sub calibrations than subwoofers.
    case subCalibrationMissing
    case noProgramLanes
    /// Program plus sub lanes exceed `N60_GRAPH_MAX_CHANNELS`.
    case tooManyChannels
    case gainOutOfRange
    case laneEQTooLarge
    case subGainOutOfRange
    case subEQTooLarge
    /// Stereo: the kernel snapshot uses a stage the core does not reproduce.
    case unsupportedKernelStage
    case stageParametersUnreadable
    case protectionCeilingOutOfRange
    /// Stereo: same-device, aggregate or rack route.
    case unsupportedRoute
    /// Stereo: headphone DSP is configured.
    case headphoneDSP
    // Session-level (after the configuration was accepted).
    case sampleRateMismatch
    case laneCountMismatch
    case blockSizeTooLarge
    case specRejected
    case graphBuildFailed
    case attachFailed

    /// Short text for the diagnostics row.
    var displayText: String {
        switch self {
        case .optimizerFIR: "speaker optimizer FIR"
        case .invertedPolarity: "inverted polarity"
        case .laneDelayUnderBassMgmt: "lane delay under bass management"
        case .nonLR4Crossover: "crossover is not LR4"
        case .tooManySubs: "more than 8 subs"
        case .noSubForBassManagement: "bass management without a sub"
        case .subCalibrationMissing: "sub calibration missing"
        case .noProgramLanes: "no program lanes"
        case .tooManyChannels: "too many lanes"
        case .gainOutOfRange: "lane gain out of range"
        case .laneEQTooLarge: "lane EQ too large"
        case .subGainOutOfRange: "sub gain out of range"
        case .subEQTooLarge: "sub EQ too large"
        case .unsupportedKernelStage: "kernel stage not in the core"
        case .stageParametersUnreadable: "stage parameters unreadable"
        case .protectionCeilingOutOfRange: "protection ceiling out of range"
        case .unsupportedRoute: "same-device, aggregate or rack route"
        case .headphoneDSP: "headphone DSP"
        case .sampleRateMismatch: "sample rate mismatch"
        case .laneCountMismatch: "lane count mismatch"
        case .blockSizeTooLarge: "buffer larger than graph block"
        case .specRejected: "graph spec rejected"
        case .graphBuildFailed: "graph build failed"
        case .attachFailed: "graph attach failed"
        }
    }
}
