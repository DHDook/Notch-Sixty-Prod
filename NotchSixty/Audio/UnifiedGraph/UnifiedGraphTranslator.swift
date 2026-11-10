import Foundation

/// E6 S8: turns what the shipping engine already computes (the kernel DSP snapshot, the
/// multichannel route plan, the sub calibration) into a `UnifiedGraphConfiguration`.
/// Returns nil (never throws) when the core cannot reproduce the snapshot, so the caller
/// keeps the kernel path for that snapshot. Control thread only.
/// Which kernel convolver a retained program belongs to.
enum UnifiedGraphProgramKind: Sendable { case convolution, roomCorrection, speakerIR }

/// Looks up the taps the control plane prepared for a program generation (nil when it was not retained).
typealias UnifiedGraphProgramLookup = (UnifiedGraphProgramKind, UInt64) -> UnifiedGraphFIRProgram?

enum UnifiedGraphTranslator {
    /// Stereo snapshot to a two-lane configuration, or nil when the kernel must render it.
    static func stereoConfiguration(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80,
        programs: UnifiedGraphProgramLookup = { _, _ in nil },
        alignment: StereoBassAlignment? = nil
    ) -> UnifiedGraphConfiguration? {
        try? stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate, subwoofers: subwoofers, crossoverHz: crossoverHz,
            programs: programs, alignment: alignment
        ).get()
    }

    /// As `stereoConfiguration`, but says why the kernel keeps the snapshot.
    static func stereoEligibility(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80,
        programs: UnifiedGraphProgramLookup = { _, _ in nil },
        alignment: StereoBassAlignment? = nil,
        firScheme: UInt32 = UnifiedGraphFIRScheme.current()
    ) -> Result<UnifiedGraphConfiguration, UnifiedGraphFallbackReason> {
        if let alignment, alignment.issue != nil { return .failure(.alignmentInvalid) }
        let eligibility = withUnsafePointer(to: &snapshot) {
            N60UnifiedGraphSnapshotUnsupportedReason($0, UInt32(UnifiedGraphFIRScheme.maxTaps(firScheme)))
        }
        if eligibility != N60UnifiedGraphSupported {
            return .failure(UnifiedGraphFallbackReason.eligibility(eligibility))
        }

        // E6 S12e, decision 16 (D5): global bypass and the reference audition remove the program DSP and keep the lane
        // calibration, the bass management and the protection. Parity exception P1: the kernel's bypass keeps only the
        // master gain and the calibration it applies after the program stages; the graph also keeps the stereo crossover.
        let d5 = snapshot.bypassed || snapshot.auditionMode == N60AuditionModeReference
        var left: [UnifiedGraphPEQSection] = []
        var right: [UnifiedGraphPEQSection] = []
        withUnsafePointer(to: &snapshot) { pointer in
            var band = N60UnifiedGraphBand()
            var index: UInt32 = 0
            while !d5, !pointer.pointee.eqBypassed, N60UnifiedGraphReadBand(pointer, index, &band) {
                index += 1
                guard band.enabled else { continue }
                let section = UnifiedGraphPEQSection(
                    type: Int(band.type), frequencyHz: band.frequencyHz,
                    gainDB: band.gainDB, q: band.q,
                    coefficients: band.type == 9 ? [band.b0, band.b1, band.b2, band.a1, band.a2] : nil
                )
                if band.channelMask & UInt8(N60_EQ_CHANNEL_LEFT) != 0 { left.append(section) }
                if band.channelMask & UInt8(N60_EQ_CHANNEL_RIGHT) != 0 { right.append(section) }
            }
        }

        let output = d5 ? snapshot.masterGainLinear : snapshot.outputGainLinear * snapshot.masterGainLinear
        let balanceLeft = d5 ? 1 : snapshot.balanceGainLeftLinear
        let balanceRight = d5 ? 1 : snapshot.balanceGainRightLinear
        var configuration = UnifiedGraphConfiguration(
            sampleRate: sampleRate,
            lanes: [
                UnifiedGraphLane(outputGain: output * balanceLeft, eq: left),
                UnifiedGraphLane(outputGain: output * balanceRight, eq: right),
            ]
        )
        configuration.inputGain = d5 ? 1 : snapshot.inputGainLinear * snapshot.headroomGainLinear
        var stages: UnifiedGraphStereoStages
        if d5 {
            stages = UnifiedGraphStereoStages()
            if snapshot.crossover.enabled {
                let x = snapshot.crossover
                stages.crossover = [
                    Float(x.frequencyHz), Float(x.topology.rawValue), Float(x.monitorMode.rawValue), x.subGainLinear,
                    x.subPolarityInverted ? 1 : 0, x.subPhaseAlignmentEnabled ? 1 : 0,
                    Float(x.subPhaseAlignmentFrequencyHz), Float(x.subPhaseAlignmentQ),
                ]
            }
        } else {
            guard let built = stereoStages(snapshot: &snapshot, configuration: &configuration) else {
                return .failure(.stageParametersUnreadable)
            }
            stages = built
        }
        // E6 S8d: recover each enabled convolver's taps by generation and verify them against the snapshot's record.
        let states = [
            (UnifiedGraphProgramKind.convolution, snapshot.convolution),
            (.roomCorrection, snapshot.roomCorrection),
            (.speakerIR, snapshot.speakerIR),
        ]
        for (kind, state) in states where state.enabled && !d5 {
            guard let program = programs(kind, state.programGeneration),
                  recoveredProgramMatches(program, state, firScheme: firScheme) else {
                return .failure(.convolutionProgramUnavailable)
            }
            switch kind {
            case .convolution: stages.programFIR = program
            case .roomCorrection: stages.roomFIR = program
            case .speakerIR: stages.speakerIR = program
            }
        }
        // E6 S12f (G3): the kernel runs the program convolution inside the mid/side pair. Taps shared by both channels
        // commute with the pair, so the core's order (the FIR ahead of the pair) is exact; distinct left and right taps
        // do not, and the graph names the refusal.
        if snapshot.eqMidSideMode, !snapshot.eqBypassed, let program = stages.programFIR,
           let right = program.right, right != program.left {
            return .failure(.midSideProgramFIR)
        }
        // E6 S12f: a room or speaker IR convolver with subwoofer lanes renders on the graph in the core's order (the
        // convolvers delay the front pair, the other lanes catch up). E8 S11 (G2, G32): the stereo crossover with sub
        // lanes is folded into the one bass management below instead of a second split.
        configuration.stereoStages = stages
        configuration.firScheme = firScheme
        // E6 S12e follow-up (G27): the delta audition runs the full processed chain and subtracts the aligned input.
        configuration.deltaAudition = snapshot.auditionMode == N60AuditionModeDelta
        if let alignment { apply(alignment, to: &configuration) }
        if d5 {
            // The processed path's latency is what the control plane reports for this snapshot; the graph pads the lanes
            // with whatever the removed program DSP contributed, so a toggle keeps the latency (decision 16).
            let pad = Int(snapshot.latencyFrames) - Int(snapshot.protection.latencyFrames)
            // A pad beyond the delay capacity cannot keep the latency, so the kernel keeps the snapshot instead.
            if pad > Int(N60_GRAPH_MAX_DELAY_FRAMES) / 2 { return .failure(.alignmentInvalid) }
            if pad > 0 {
                for index in configuration.lanes.indices { configuration.lanes[index].calibrationDelayFrames += Double(pad) }
            }
        }
        let p = snapshot.protection
        if p.limiterEnabled || p.truePeakGuardEnabled || p.softClipperEnabled || p.gainRiderEnabled {
            // The snapshot carries linear gains, so a setting exactly on a range end (-20 dB, 12 dB drive, -6 dB
            // threshold) comes back a hair outside it after the dB round trip. Ends are snapped (E6 S12f2, G34);
            // only a genuinely out-of-range ceiling is refused.
            let rawCeilingDB = 20.0 * log10(Double(max(p.limiterCeilingLinear, 1e-6)))
            guard rawCeilingDB >= -20.001, rawCeilingDB <= 0.001 else { return .failure(.protectionCeilingOutOfRange) }
            let ceilingDB = min(0, max(-20, rawCeilingDB))
            var protection = UnifiedGraphProtection(
                limiterEnabled: p.limiterEnabled,
                ceilingDB: ceilingDB,
                attackMilliseconds: Double(p.limiterAttackMs),
                releaseMilliseconds: Double(p.limiterReleaseMs),
                lookAheadMilliseconds: Double(p.limiterLookAheadMs),
                truePeakGuard: p.truePeakGuardEnabled,
                oversampling: Int(p.effectiveFactor.rawValue)
            )
            if p.softClipperEnabled || p.gainRiderEnabled {
                protection.clipper = UnifiedGraphSoftClipper(
                    enabled: p.softClipperEnabled,
                    driveDB: min(12, max(0, 20.0 * log10(Double(max(p.clipperDriveLinear, 1e-6))))),
                    thresholdDB: min(0, max(-6, 20.0 * log10(Double(max(p.clipperThresholdLinear, 1e-6))))),
                    knee: Double(p.clipperKneeSmooth),
                    curve: Int(p.clipperCurve.rawValue),
                    autoCompensate: p.clipperCompensationLinear != 1,
                    asymmetryDB: min(3, max(-3, Double(p.clipperAsymmetryTrimDB)))
                )
                protection.rider = UnifiedGraphGainRider(
                    enabled: p.gainRiderEnabled,
                    targetDB: Double(p.gainRiderTargetGRDB),
                    maxDB: Double(p.gainRiderMaxReductionDB),
                    speed: Int(p.gainRiderSpeed.rawValue)
                )
            }
            configuration.protection = protection
        }
        if !subwoofers.isEmpty {
            var bass = UnifiedGraphBassManagement(crossoverHz: crossoverHz, lfeLane: nil, subwoofers: subwoofers)
            if let crossover = configuration.stereoStages.crossover {
                // The crossover is the only split: the sub lanes take its low band (after the alignment's mono-bass
                // filter, which `apply(_:to:)` has already written into the parameters).
                guard let folded = foldCrossover(crossover, into: bass) else { return .failure(.stageParametersUnreadable) }
                if let failure = folded.failure { return .failure(failure) }
                bass = folded.bass
                configuration.stereoStages.crossover = nil
                let subLanes = UInt64((1 << subwoofers.count) - 1) << UInt64(configuration.lanes.count)
                configuration.mutedLanes = (folded.mutesMains ? 0b11 : 0) | (folded.mutesSubs ? subLanes : 0)
            }
            configuration.bassManagement = bass
        }
        return .success(configuration)
    }

    /// E8 S11: the stereo crossover's parameters as the bass management that takes its place when sub lanes exist.
    /// `BASS_MGMT` high-passes each main lane and sums their low-passes, which is the crossover's mains high-pass and its
    /// sub `(A + B) / 2` low-pass; the redirect carries the 1/2 mean, the crossover's sub gain and polarity go to every
    /// sub, and the phase alignment becomes an all-pass at the head of each sub's EQ. Nil when the parameters are not an
    /// 8 or 12 value list. With N subs the bass sum takes `BASS_MGMT`'s 1/N, so N subs together play the level one
    /// sub would. Must run after `apply(_:to:)` (it writes the mono-bass trailer and polarity). No added latency; the
    /// monitor mode is fixed at build time (a change is a rebuild with the core's fade). The mute mask assumes the
    /// stereo path's two program lanes.
    private static func foldCrossover(
        _ x: [Float], into bass: UnifiedGraphBassManagement
    ) -> (bass: UnifiedGraphBassManagement, failure: UnifiedGraphFallbackReason?, mutesMains: Bool, mutesSubs: Bool)? {
        guard x.count == 8 || x.count == 12 else { return nil }
        var result = bass
        result.crossoverHz = Double(x[0])
        result.redirectDB = UnifiedGraphBassManagement.twoMainMeanRedirectDB
        if x.count == 12 {
            result.filterSpec = Array(x[8...11])
        } else {
            result.steepSplit = x[1] != 0
        }
        let mode = Int(x[2])
        let gain = Double(x[3])
        // A gain under -60 dB (the sub range's floor) is a mute, as a zero gain is.
        let silent = gain < 0.001
        let gainDB = silent ? 0 : 20 * log10(gain)
        let invert = x[4] != 0
        let align = x[5] != 0
        for index in result.subwoofers.indices {
            result.subwoofers[index].gainDB += gainDB
            guard (-60.0...24.0).contains(result.subwoofers[index].gainDB) else {
                return (result, .subGainOutOfRange, false, false)
            }
            if invert { result.subwoofers[index].polarityInverted.toggle() }
            if align {
                guard result.subwoofers[index].eq.count < 8 else { return (result, .subEQTooLarge, false, false) }
                result.subwoofers[index].eq.insert(
                    UnifiedGraphPEQSection(type: 6, frequencyHz: Double(x[6]), gainDB: 0, q: Double(x[7])), at: 0)
            }
        }
        // Monitor modes 1 (mains only) and 2 (sub only); a zero sub gain silences the subs in every mode.
        return (result, nil, mode == 2, mode == 1 || silent)
    }

    /// E25 S2: compiles the mono-bass filter into the pair crossover (ABI v19 trailer, with the sum-polarity fix for
    /// Linkwitz-Riley 12 and 36) and the speaker feed calibration into the stereo lanes. With no crossover in the
    /// configuration the filter is ignored; an identity calibration leaves the lanes untouched.
    static func apply(_ alignment: StereoBassAlignment, to configuration: inout UnifiedGraphConfiguration) {
        if let filter = alignment.monoBassFilter, var params = configuration.stereoStages.crossover, params.count == 8 {
            if filter.sumNeedsInversion { params[4] = params[4] == 0 ? 1 : 0 }
            configuration.stereoStages.crossover = params + filter.trailer
        }
        let feeds = [alignment.left, alignment.right]
        for index in 0..<min(2, configuration.lanes.count) {
            let feed = feeds[index]
            configuration.lanes[index].outputGain *= feed.linearGain
            configuration.lanes[index].polarityInverted = feed.polarityInverted
            configuration.lanes[index].calibrationDelayFrames = feed.delayFrames(sampleRate: configuration.sampleRate)
        }
    }

    /// The retained taps are the ones the kernel was prepared with: same generation, tap count, shared-or-stereo shape
    /// and declared latency as the snapshot's record, all finite, within what the core holds.
    static func recoveredProgramMatches(
        _ program: UnifiedGraphFIRProgram, _ state: N60ConvolutionGraphState,
        firScheme: UInt32 = UnifiedGraphFIRScheme.current()
    ) -> Bool {
        guard program.generation == state.programGeneration,
              program.left.count == Int(state.tapCount), program.left.count <= UnifiedGraphFIRScheme.maxTaps(firScheme),
              program.right == nil || program.right?.count == program.left.count,
              program.declaredLatencyFrames == state.declaredLatencyFrames,
              program.declaredLatencyFrames <= N60_GRAPH_MAX_DELAY_FRAMES else { return false }
        return program.left.allSatisfy(\.isFinite) && (program.right?.allSatisfy(\.isFinite) ?? true)
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
            var cleanup = [Float](repeating: 0, count: 26)
            var cleanupNeeded = false
            if N60UnifiedGraphCleanupParams(pointer, &cleanup, &cleanupNeeded) {
                if cleanupNeeded { stages.cleanup = cleanup }
            } else { ok = false }
            var image = [Float](repeating: 0, count: 8)
            var imageNeeded = false
            if N60UnifiedGraphImageParams(pointer, &image, &imageNeeded) {
                if imageNeeded { stages.image = image }
            } else { ok = false }
            var loudness = [Float](repeating: 0, count: 32)
            var loudnessNeeded = false
            if N60UnifiedGraphLoudnessParams(pointer, &loudness, &loudnessNeeded) {
                if loudnessNeeded { stages.loudness = loudness }
            } else { ok = false }
            var multiband = [Float](repeating: 0, count: 29)
            var multibandNeeded = false
            if N60UnifiedGraphMultibandParams(pointer, &multiband, &multibandNeeded) {
                if multibandNeeded { stages.multiband = multiband }
            } else { ok = false }
            var deess = [Float](repeating: 0, count: 12)
            var deessNeeded = false
            if N60UnifiedGraphDeEssParams(pointer, &deess, &deessNeeded) {
                if deessNeeded { stages.deess = deess }
            } else { ok = false }
            if dynamics.spectralDenoiser.enabled {
                var values = [Float](repeating: 0, count: 9)
                if N60UnifiedGraphDenoiserParams(pointer, &values) {
                    stages.denoiser = values
                    stages.denoiserLatencyFrames = dynamics.spectralDenoiser.latencyFrames
                } else { ok = false }
            } else {
                var view = [UInt32](repeating: 0, count: 3)
                if N60UnifiedGraphDenoiserParkView(pointer, &view) {
                    configuration.denoiserPark = UnifiedGraphDenoiserPark(
                        fftSize: view[0], revision: view[1], command: view[2]
                    )
                } else { ok = false }
            }
            // The kernel skips the dynamic EQ while the EQ is bypassed.
            if dynamics.dynamicEQ.enabled, !pointer.pointee.eqBypassed {
                var values = [Float](repeating: 0, count: 1 + 15 * Int(N60_DYNAMIC_EQ_MAX_BANDS))
                var count: UInt32 = 0
                if N60UnifiedGraphDynamicEQParams(pointer, &values, &count) {
                    if count > 0 { stages.dynamicEQ = Array(values.prefix(Int(count))) }
                } else { ok = false }
            }
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
            if pointer.pointee.crossover.enabled {
                let x = pointer.pointee.crossover
                stages.crossover = [
                    Float(x.frequencyHz), Float(x.topology.rawValue), Float(x.monitorMode.rawValue), x.subGainLinear,
                    x.subPolarityInverted ? 1 : 0, x.subPhaseAlignmentEnabled ? 1 : 0,
                    Float(x.subPhaseAlignmentFrequencyHz), Float(x.subPhaseAlignmentQ),
                ]
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
                } else {
                    var totals: (Double, Double) = (0, 0)
                    let fractional = withUnsafeMutablePointer(to: &totals) { tuple in
                        tuple.withMemoryRebound(to: Double.self, capacity: 2) { N60UnifiedGraphFractionalDelay(pointer, $0) }
                    }
                    if fractional {
                        configuration.lanes[0].fractionalDelayFrames = totals.0
                        configuration.lanes[1].fractionalDelayFrames = totals.1
                    } else { ok = false }
                }
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
    /// the core cannot reproduce them exactly: an optimizer FIR (S12g, G39) and a lane EQ or sub
    /// EQ beyond the stages' limits (G39). A lane delay under bass management is a LANE_DELAY stage (ABI v28).
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
        bassManagementConfiguration: BassManagementConfiguration,
        programDSP: UnifiedGraphProgramDSP? = nil,
        ancHostFeed: Bool = false,
        userOutputGain: Float = 1
    ) -> Result<UnifiedGraphConfiguration, UnifiedGraphFallbackReason> {
        let roles = routePlan.programLayout.roles
        // E6 S12g4: the optimizer FIR becomes one FIR stage per corrected lane plus a delay-only delta for the rest.
        var optimizerGraphFIR: UnifiedGraphOptimizerFIR?
        if let fir = routePlan.speakerOptimizerFIR {
            var perLane: [Int: [Float]] = [:]
            for source in fir.sources {
                guard source.role != .lowFrequencyEffects, let lane = roles.firstIndex(of: source.role),
                      source.taps.count == fir.tapCount else { return .failure(.optimizerFIR) }
                perLane[lane] = source.taps
            }
            guard !perLane.isEmpty, fir.tapCount % 2 == 1, fir.declaredGroupDelayFrames == (fir.tapCount - 1) / 2,
                  fir.tapCount <= UnifiedGraphFIRScheme.maxTaps(UnifiedGraphFIRScheme.current()) else {
                return .failure(.optimizerFIR)
            }
            optimizerGraphFIR = UnifiedGraphOptimizerFIR(
                declaredLatencyFrames: UInt32(fir.declaredGroupDelayFrames), taps: perLane)
        }
        let bassEnabled = bassManagementConfiguration.enabled
        let subCount = Int(routePlan.subwooferCount)
        if bassEnabled {
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
            let delay = calibration?.delayMilliseconds ?? 0
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
            // E6 S12g3: lanes chain PEQ stages, so only the chain limit (512 slots) refuses; the legacy 16-section cap is lifted.
            if peq.reduce(0, { $0 + $1.slotCount }) > UnifiedGraphConfiguration.maxPEQSlotsPerLane {
                return .failure(.laneEQTooLarge)
            }
            // E6 S12g2: under bass management the legacy order is delay before the crossover (LANE_DELAY stage).
            lanes.append(UnifiedGraphLane(
                preGain: gain, delayMilliseconds: bassEnabled ? 0 : delay,
                polarityInverted: calibration?.polarityInverted == true,
                preBassDelayMilliseconds: bassEnabled ? delay : 0, eq: peq))
            if role == .lowFrequencyEffects { lfeLane = index }
        }
        var configuration = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: lanes)
        configuration.optimizerFIR = optimizerGraphFIR
        if bassEnabled {
            // E8 S11b: the stereo crossover folded by `stereoEligibility` (two mains, no LFE) supplies the split, the sub
            // gain and polarity, the phase-alignment all-pass and the monitor mute; the route plan's calibrations add on.
            let folded = programDSP?.foldedBass
            if let candidate = folded, roles.count != 2 || candidate.bass.subwoofers.count != subCount {
                return .failure(.laneCountMismatch)
            }
            var subs: [UnifiedGraphSubwoofer] = []
            for index in 0..<subCount {
                let calibration = routePlan.subwooferCalibrations[index]
                let foldedSub = folded?.bass.subwoofers[index]
                let gainDB = (foldedSub?.gainDB ?? bassManagementConfiguration.subGainDB) + (calibration?.gainDB ?? 0)
                guard (-60.0...24.0).contains(gainDB) else { return .failure(.subGainOutOfRange) }
                let eq = (foldedSub?.eq ?? []) + sections(calibration?.eqBands ?? [])
                guard eq.count <= 8 else { return .failure(.subEQTooLarge) }
                subs.append(UnifiedGraphSubwoofer(
                    gainDB: gainDB,
                    polarityInverted: (foldedSub?.polarityInverted ?? bassManagementConfiguration.subPolarityInverted)
                        != (calibration?.polarityInverted ?? false),
                    delayMilliseconds: calibration?.delayMilliseconds ?? 0,
                    eq: eq
                ))
            }
            var bass = UnifiedGraphBassManagement(
                crossoverHz: folded?.bass.crossoverHz ?? bassManagementConfiguration.frequencyHz,
                lfeLane: lfeLane,
                lfeLowPassHz: LiveNChannelRenderGraphCompiler.lfeLowPassHz,
                lfeGainDB: LiveNChannelRenderGraphCompiler.lfeInBandGainDB,
                steepSplit: folded?.bass.steepSplit ?? (bassManagementConfiguration.topology == .linkwitzRiley48),
                subwoofers: subs
            )
            bass.filterSpec = folded?.bass.filterSpec
            configuration.bassManagement = bass
            configuration.mutedLanes = folded?.mutedLanes ?? 0
            // E26 G38: two mains and no LFE (stereo plus sub, class A) play the sub at the stereo path's level.
            if roles.count == 2, lfeLane == nil {
                configuration.bassManagement?.redirectDB = UnifiedGraphBassManagement.twoMainMeanRedirectDB
            }
        }
        if ancHostFeed, let actuators = hostFedAncActuators(
            routePlan: routePlan, bassEnabled: bassEnabled, subCount: subCount, sampleRate: sampleRate,
            userOutputGain: userOutputGain
        ) {
            configuration.ancActuators = actuators
        }
        if optimizerGraphFIR != nil || programDSP?.isNeutral == false {
            configuration.orderPolicy = .canonical
            if let programDSP, !programDSP.isNeutral {
                configuration.programDSP = programDSP
                configuration.deltaAudition = programDSP.deltaAudition
            }
            // Dry run, so the reason is known here and not as a bare "spec rejected" at session start.
            do { _ = try configuration.makeSpec() } catch let reason as UnifiedGraphFallbackReason {
                return .failure(reason)
            } catch { return .failure(.specRejected) }
        } else if configuration.mutedLanes != 0 {
            // The monitor mute is a stage the plain build adds; name a refusal (the ANC actuators) here, not at session start.
            do { _ = try configuration.makeSpec() } catch let reason as UnifiedGraphFallbackReason {
                return .failure(reason)
            } catch { return .failure(.specRejected) }
        }
        return .success(configuration)
    }

    /// E26 S7b2: class A (two mains plus one sub output): the left main, right main and sub lanes are the actuators of
    /// a host-fed Quiet Zone. Any other layout gets none (the engine refuses Quiet Zone there). Not authorised.
    static func hostFedAncActuators(
        routePlan: LiveNChannelOutputRoutePlan, bassEnabled: Bool, subCount: Int, sampleRate: Double,
        userOutputGain: Float
    ) -> UnifiedGraphAncActuators? {
        guard bassEnabled, subCount == 1, let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles),
              shape.laneCount == 2, let left = shape.frontLeft, let right = shape.frontRight, left != right else {
            return nil
        }
        let frames = UInt32(min(Double(N60_GRAPH_MAX_DELAY_FRAMES), max(1, (sampleRate * 0.1).rounded())))
        return UnifiedGraphAncActuators(
            actuators: [.init(targetLane: left), .init(targetLane: right), .init(targetLane: shape.laneCount)],
            captureFrames: frames, hostFed: true, userOutputGain: userOutputGain)
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

    /// Largest response set (floats) a binaural graph may carry: 8M floats, 32 MB.
    static let binauralMaxResponseFloats = 8 * 1024 * 1024
    /// Head-yaw cells of a head-tracked set (15 degree steps, wrapped).
    static let binauralTrackedOrientations: UInt32 = 24

    /// Selection rule and spec for a binaural headphone session (E6 S8b2d): the output must be
    /// a 2-channel headphone endpoint, the program layout must have more than 2 channels and
    /// the profile must carry an asset. `asset` is already resampled to `sampleRate`. The
    /// HEADPHONE stage carries the profile's headroom, channel gain, polarity and EQ and a DELAY stage per ear
    /// carries the channel delay (S9c). The stage covers the profile's whole range (headroom 0 to 30 dB, 16 bands a side,
    /// the same ceilings the legacy `N60HeadphoneDSP` validates), so a valid profile never falls back. Protection
    /// matches the legacy limiter. Program gain is the INPUT_GAIN stage (the bridge applies it only on the legacy pipeline).
    static func binauralSpec(
        asset: BinauralProfileAsset?,
        layout: OutputProgramLayout,
        profile: HeadphoneDeviceProfileConfiguration,
        outputChannels: UInt32,
        sampleRate: Double,
        headTracking: Bool,
        maxBlockFrames: UInt32 = 16_384,
        programDSP: UnifiedGraphProgramDSP? = nil,
        programGain: Float = 1,
        outputProtection: UnifiedGraphOutputProtection? = UnifiedGraphOutputProtection.current()
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        switch binauralBaseSpec(
            asset: asset, layout: layout, profile: profile, outputChannels: outputChannels,
            sampleRate: sampleRate, headTracking: headTracking, maxBlockFrames: maxBlockFrames,
            programGain: programGain
        ) {
        case .failure(let reason): return .failure(reason)
        case .success(let base): return binauralApplyProgram(base: base, programDSP: programDSP, programGain: programGain, outputProtection: outputProtection)
        }
    }

    /// E6 S9b: the program DSP and program gain laid onto a binaural base spec (`binauralBaseSpec`), without
    /// rebuilding the response set. A live edit calls this with the session's retained base; the host then posts
    /// the parameters or fades to the new topology.
    static func binauralApplyProgram(
        base: UnifiedGraphSpec,
        programDSP: UnifiedGraphProgramDSP?,
        programGain: Float,
        outputProtection: UnifiedGraphOutputProtection? = UnifiedGraphOutputProtection.current()
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        guard programGain.isFinite, programGain > 0, programGain <= 16 else { return .failure(.gainOutOfRange) }
        var spec = base
        guard let gainIndex = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_INPUT_GAIN }),
              !spec.stages[gainIndex].params.isEmpty else { return .failure(.specRejected) }
        spec.stages[gainIndex].params[0] = programGain
        if var programDSP, !programDSP.isNeutral {
            programDSP.virtualSpeakers = true
            do { try programDSP.apply(to: &spec) } catch let reason as UnifiedGraphFallbackReason {
                return .failure(reason)
            } catch { return .failure(.specRejected) }
        }
        // E9 S5c (G15): the layout's safety limiter on the ears is one linked stage; with output protection on, each ear also
        // gets its own unlinked hard limit (zero latency), so one ear peaking never ducks the other.
        // `binauralBaseSpec` refuses any output that is not two-channel, so the ears are always lanes 0 and 1.
        outputProtection?.addHardLimits(to: &spec, lanes: 2)
        if spec.stages.count > UnifiedGraphProgramDSP.maxStages { return .failure(.stageBudget) }
        return .success(spec)
    }

    /// The binaural layout graph with the HEADPHONE stage and the safety limiter, before any program DSP.
    /// `programGain` is the INPUT_GAIN stage's value (the bridge does not apply it while the graph renders).
    static func binauralBaseSpec(
        asset: BinauralProfileAsset?,
        layout: OutputProgramLayout,
        profile: HeadphoneDeviceProfileConfiguration,
        outputChannels: UInt32,
        sampleRate: Double,
        headTracking: Bool,
        maxBlockFrames: UInt32 = 16_384,
        programGain: Float = 1
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        guard programGain.isFinite, programGain > 0, programGain <= 16 else { return .failure(.gainOutOfRange) }
        guard outputChannels == 2 else { return .failure(.binauralOutputNotStereo) }
        guard layout.roles.count > 2 else { return .failure(.noProgramLanes) }
        guard layout.roles.count <= Int(N60_LAYOUT_MAX_CHANNELS),
              layout.roles.count <= Int(N60_GRAPH_MAX_CHANNELS) else { return .failure(.tooManyChannels) }
        guard let asset else { return .failure(.binauralProfileMissing) }
        guard abs(asset.sampleRate - sampleRate) < 0.5 else { return .failure(.sampleRateMismatch) }
        guard asset.tapCount >= 1, asset.tapCount <= Int(N60_GRAPH_BINAURAL_MAX_TAPS) else {
            return .failure(.binauralBudget)
        }
        // Headphone correction the stage cannot reproduce stays on the legacy path.
        guard headphoneStagesEligible(profile: profile, sampleRate: sampleRate) else { return .failure(.headphoneDSP) }

        let channels = layout.roles.count
        let orientations = headTracking ? binauralTrackedOrientations : 1
        let perSet = channels * 2 * asset.tapCount
        guard perSet * Int(orientations) <= binauralMaxResponseFloats else { return .failure(.binauralBudget) }
        let step: Float = headTracking ? 360 / Float(orientations) : 0
        let start: Float = headTracking ? -180 : 0
        var responses: [Float] = []
        responses.reserveCapacity(perSet * Int(orientations))
        var equalEar: Int32 = -1
        do {
            for set in 0..<Int(orientations) {
                let pose = N60HeadPose(
                    yawDegrees: N60HeadPoseWrap180(Double(start + step * Float(set))),
                    pitchDegrees: 0, rollDegrees: 0)
                let prepared = try asset.prepare(for: layout, headPose: pose)
                if set == 0, prepared.descriptor.lfeMode == N60BinauralLFEModeEqualEar,
                   let lfe = layout.roles.firstIndex(of: .lowFrequencyEffects) {
                    equalEar = Int32(lfe)
                }
                for channel in 0..<channels {
                    let base = channel * asset.tapCount
                    responses.append(contentsOf: prepared.leftIRs[base..<(base + asset.tapCount)])
                    responses.append(contentsOf: prepared.rightIRs[base..<(base + asset.tapCount)])
                }
            }
        } catch {
            return .failure(.specRejected)
        }

        var layoutC = n60_layout()
        layoutC.structSize = UInt32(MemoryLayout<n60_layout>.size)
        layoutC.identifier = UInt32(N60_LAYOUT_CUSTOM.rawValue)
        layoutC.channelCount = UInt32(channels)
        withUnsafeMutableBytes(of: &layoutC.roles) { raw in
            let roles = raw.bindMemory(to: UInt32.self)
            for (index, role) in layout.roles.enumerated() { roles[index] = UInt32(role.realtimeCType.rawValue) }
        }
        var options = n60_layout_options()
        options.structSize = UInt32(MemoryLayout<n60_layout_options>.size)
        options.sampleRate = sampleRate
        options.maxBlockFrames = maxBlockFrames
        options.mode = N60_MODE_BINAURAL.rawValue
        options.protection = 1
        options.inputGain = programGain
        var built: OpaquePointer?
        let status: n60_status = responses.withUnsafeBufferPointer { responsePointer in
            var binaural = n60_binaural_profile()
            binaural.structSize = UInt32(MemoryLayout<n60_binaural_profile>.size)
            binaural.taps = UInt32(asset.tapCount)
            binaural.orientations = orientations
            binaural.yawStartDeg = start
            binaural.yawStepDeg = step
            binaural.wrap = headTracking ? 1 : 0
            binaural.equalEarChannel = equalEar
            binaural.declaredLatency = UInt32(max(0, asset.declaredLatencyFrames))
            binaural.responses = responsePointer.baseAddress
            return withUnsafePointer(to: &layoutC) { layoutPointer in
                options.layout = layoutPointer
                return withUnsafePointer(to: &binaural) { binauralPointer in
                    options.binaural = binauralPointer
                    return n60_layout_graph_build(&options, &built)
                }
            }
        }
        guard status == N60_STATUS_OK, let built else { return .failure(.specRejected) }
        defer { n60_layout_graph_free(built) }
        guard let description = n60_layout_graph_desc(built) else { return .failure(.specRejected) }
        var spec = UnifiedGraphSpec(copying: description)
        spec.maxBlockFrames = maxBlockFrames

        // Headphone stage: pair (left, right) on lanes 0 and 1, crossfeed off (the virtual
        // speakers already carry the spatial image). Then one DELAY stage per ear.
        let stage = headphoneStage(profile: profile)
        let delays = headphoneDelayStages(profile: profile, sampleRate: sampleRate)
        guard let protectionIndex = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_PROTECTION }) else {
            return .failure(.specRejected)
        }
        // Same limiter as the legacy bridge: -1 dB ceiling, 0.5/90 ms, 2 ms look-ahead, 4x true-peak.
        spec.stages[protectionIndex].params = [1, -1, 0.5, 90, 2, 1, 4]
        spec.stages.insert(contentsOf: [stage] + delays, at: protectionIndex)
        return .success(spec)
    }

    /// First DELAY stage id of the ear lanes of a binaural graph (lane 0, lane 1).
    static let headphoneDelayStageBase: UInt32 = 2_400

    /// True when the HEADPHONE stage and the ear DELAY stages reproduce `profile`: headroom 0 to 30 dB (the profile's
    /// full range), at most `N60_PEQ_MAX_SECTIONS` (16, the legacy maximum, which `validateStructure` also
    /// enforces) enabled bands a side, channel gain within the stage's range and a delay within the delay capacity.
    /// A profile that passed `validateStructure` always satisfies this; it guards hand-built configurations.
    static func headphoneStagesEligible(profile: HeadphoneDeviceProfileConfiguration, sampleRate: Double) -> Bool {
        if profile.crossfeedActive {
            // The stage's crossfeed ranges (graph.h, HEADPHONE); a wider legacy setting stays on the kernel.
            let crossfeed = profile.crossfeed
            guard crossfeed.amount.isFinite, (0.0...1.0).contains(crossfeed.amount),
                  crossfeed.virtualSpeakerAngleDegrees.isFinite, (15.0...90.0).contains(crossfeed.virtualSpeakerAngleDegrees),
                  crossfeed.headRadiusMeters.isFinite, (0.06...0.12).contains(crossfeed.headRadiusMeters),
                  crossfeed.headShadowFrequencyHz.isFinite, (200.0...2000.0).contains(crossfeed.headShadowFrequencyHz)
            else { return false }
        }
        guard profile.headroomAttenuationDB.isFinite, (0.0...30.0).contains(profile.headroomAttenuationDB),
              profile.left.eqBands.filter(\.enabled).count <= Int(N60_PEQ_MAX_SECTIONS),
              profile.right.eqBands.filter(\.enabled).count <= Int(N60_PEQ_MAX_SECTIONS),
              (-24.0...24.0).contains(profile.left.gainDB), (-24.0...24.0).contains(profile.right.gainDB),
              sampleRate.isFinite, sampleRate > 0 else { return false }
        for side in [profile.left, profile.right] {
            guard side.delayMilliseconds.isFinite, side.delayMilliseconds >= 0,
                  sampleRate * side.delayMilliseconds * 0.001 <= Double(N60_HEADPHONE_MAX_DELAY_FRAMES) else {
                return false
            }
        }
        return true
    }

    /// The HEADPHONE pair stage (lanes 0 and 1) for `profile`; call only when `headphoneStagesEligible`.
    /// E13 S3: with `fixedSections` (live tuning on) each ear always carries `N60_PEQ_MAX_SECTIONS` sections, the
    /// unused ones at unity, so adding or removing a band changes parameter values and never the parameter count (a
    /// posted edit, not a rebuild).
    static func headphoneStage(
        profile: HeadphoneDeviceProfileConfiguration,
        fixedSections: Bool = UnifiedGraphLiveHeadphoneTuning.isOn
    ) -> UnifiedGraphStageSpec {
        func bands(_ side: HeadphoneChannelCorrection) -> [Float] {
            var out = side.eqBands.filter(\.enabled).flatMap { band -> [Float] in
                [Float(band.type.realtimeCType.rawValue), Float(band.frequencyHz), Float(band.gainDB), Float(band.q)]
            }
            if fixedSections {
                while out.count < 4 * Int(N60_PEQ_MAX_SECTIONS) { out += UnifiedGraphLiveHeadphoneTuning.unitySection }
            }
            return out
        }
        let leftBands = bands(profile.left)
        let rightBands = bands(profile.right)
        // Crossfeed runs only for a stereo profile (the legacy bridge's rule); the virtual speakers already carry the image.
        let crossfeed = profile.crossfeedActive
            ? [Float(profile.crossfeed.amount), Float(profile.crossfeed.virtualSpeakerAngleDegrees),
               Float(profile.crossfeed.headRadiusMeters), Float(profile.crossfeed.headShadowFrequencyHz)]
            : [0, 30, 0.0875, 700]
        var headphone: [Float] = [
            -Float(profile.headroomAttenuationDB), crossfeed[0], crossfeed[1], crossfeed[2], crossfeed[3],
            Float(profile.left.gainDB), Float(profile.right.gainDB),
            profile.left.polarityInverted ? 1 : 0, profile.right.polarityInverted ? 1 : 0,
            Float(leftBands.count / 4), Float(rightBands.count / 4),
        ]
        headphone += leftBands + rightBands
        return UnifiedGraphStageSpec(
            kind: UInt32(N60_STAGE_HEADPHONE.rawValue), stageId: N60_LSTAGE_HEADPHONE,
            laneA: 0, laneB: 1, laneMask: 0, params: headphone)
    }

    /// The per-ear channel delay as two DELAY stages with a fixed capacity, so a delay edit is a posted parameter
    /// and never a rebuild. Frames round to nearest like the legacy `N60HeadphoneDSPSetChannelDelayMs`.
    static func headphoneDelayStages(
        profile: HeadphoneDeviceProfileConfiguration, sampleRate: Double
    ) -> [UnifiedGraphStageSpec] {
        [profile.left, profile.right].enumerated().map { lane, side in
            let frames = min(UInt32(N60_HEADPHONE_MAX_DELAY_FRAMES), UInt32((sampleRate * side.delayMilliseconds * 0.001).rounded()))
            return UnifiedGraphStageSpec(
                kind: UInt32(N60_STAGE_DELAY.rawValue), stageId: headphoneDelayStageBase + UInt32(lane),
                laneA: UInt32(lane), laneB: 0, laneMask: 0, capacityFrames: UInt32(N60_HEADPHONE_MAX_DELAY_FRAMES),
                params: [Float(frames)])
        }
    }

    /// E6 S9d: the stereo graph `spec` with the profile's HEADPHONE stage after the last output gain (the kernel's
    /// position: after output gain, before the pause gate) and the two ear DELAY stages ahead of protection. Fails with
    /// `headphoneDSP` when the stages cannot reproduce the profile. `earDelayFrames` is the per-ear frame count, for
    /// the caller's hand-over latency alignment (the kernel applies the delay without reporting it).
    static func stereoApplyHeadphone(
        spec: UnifiedGraphSpec, profile: HeadphoneDeviceProfileConfiguration
    ) -> Result<(spec: UnifiedGraphSpec, earDelayFrames: [UInt32]), UnifiedGraphFallbackReason> {
        guard profile.spatialMode == .stereo, headphoneStagesEligible(profile: profile, sampleRate: spec.sampleRate) else {
            return .failure(.headphoneDSP)
        }
        var result = spec
        let gainKinds = [UInt32(N60_STAGE_OUTPUT_GAIN.rawValue)]
        guard let lastGain = result.stages.lastIndex(where: { gainKinds.contains($0.kind) }) else {
            return .failure(.specRejected)
        }
        let delays = headphoneDelayStages(profile: profile, sampleRate: spec.sampleRate)
        result.stages.insert(headphoneStage(profile: profile), at: lastGain + 1)
        let protection = result.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_PROTECTION })
            ?? result.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_FINAL_SANITISE })
            ?? result.stages.count
        result.stages.insert(contentsOf: delays, at: protection)
        return .success((result, delays.map { UInt32($0.params.first ?? 0) }))
    }

    /// E6 S9c: `base` (a binaural base spec) with the HEADPHONE stage and ear delays of `profile`, without
    /// rebuilding the response set. Fails with `headphoneDSP` when the stages cannot reproduce the profile.
    static func binauralApplyHeadphone(
        base: UnifiedGraphSpec, profile: HeadphoneDeviceProfileConfiguration
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        guard headphoneStagesEligible(profile: profile, sampleRate: base.sampleRate) else {
            return .failure(.headphoneDSP)
        }
        var spec = base
        guard let hp = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_HEADPHONE }) else {
            return .failure(.specRejected)
        }
        spec.stages[hp] = headphoneStage(profile: profile)
        for delay in headphoneDelayStages(profile: profile, sampleRate: base.sampleRate) {
            guard let index = spec.stages.firstIndex(where: { $0.stageId == delay.stageId }) else {
                return .failure(.specRejected)
            }
            spec.stages[index].params = delay.params
        }
        return .success(spec)
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
    /// Stereo: a convolver's taps were not retained, or do not match the snapshot's program record.
    case convolutionProgramUnavailable
    /// Retired in E6 S12f (room correction or speaker IR with a subwoofer lane renders on the graph); kept so diagnostics stay stable.
    case convolverWithSubwoofer
    /// Retired in E8 S11 (the stereo crossover feeds the subwoofer lanes from its low band); kept so diagnostics stay stable.
    case crossoverWithSubwoofer
    /// E6 S12f: the snapshot's unsupported stage group, by name (replaces the generic kernel-stage refusal).
    case snapshotBypassOrAudition
    case snapshotMidSideOrMixedPhase
    case snapshotEQSection
    case snapshotSpatial
    case snapshotCrossover
    case snapshotDynamics
    case snapshotProtection
    case snapshotConvolution
    case snapshotAmbientOrANC
    case snapshotDelay
    case snapshotGain
    case protectionCeilingOutOfRange
    /// Retired in E6 S8e (those routes render through the graph); kept so diagnostics stay stable.
    case unsupportedRoute
    /// Stereo: headphone DSP is configured.
    case headphoneDSP
    /// E25 S2: the stereo alignment (mono-bass filter or speaker feed calibration) is out of range.
    case alignmentInvalid
    // Session-level (after the configuration was accepted).
    case sampleRateMismatch
    case laneCountMismatch
    case blockSizeTooLarge
    case specRejected
    case graphBuildFailed
    case attachFailed
    // Binaural (S8b2d).
    /// The headphone profile carries no imported HRTF/SOFA asset the graph could use.
    case binauralProfileMissing
    /// The output is not a two-channel headphone endpoint.
    case binauralOutputNotStereo
    /// The response set exceeds the core's tap or memory budget at this rate.
    case binauralBudget
    // Program DSP on an N-channel or binaural layout (S9a).
    /// Mid/Side EQ together with calibration EQ on a paired lane (the calibration would run in the M/S domain).
    case midSideWithPairCalibration
    /// Mid/Side EQ together with a program FIR.
    case midSideProgramFIR
    /// The latency to align across lanes is larger than a delta FIR or a delay can carry.
    case latencyAlignment
    /// The graph would have more than 256 stages.
    case stageBudget
    /// A stereo image, room or speaker stage needs a front left and right pair the layout lacks.
    case noFrontPair
    /// Room correction, speaker IR or an image stage with Virtual Speakers (they act on speakers, not ears).
    case virtualSpeakersSpeakerStage

    /// Maps the snapshot eligibility result to its named refusal.
    static func eligibility(_ reason: N60UnifiedGraphUnsupportedReason) -> UnifiedGraphFallbackReason {
        switch reason {
        case N60UnifiedGraphUnsupportedBypassOrAudition: .snapshotBypassOrAudition
        case N60UnifiedGraphUnsupportedMidSideOrMixedPhase: .snapshotMidSideOrMixedPhase
        case N60UnifiedGraphUnsupportedEQSection: .snapshotEQSection
        case N60UnifiedGraphUnsupportedSpatial: .snapshotSpatial
        case N60UnifiedGraphUnsupportedCrossover: .snapshotCrossover
        case N60UnifiedGraphUnsupportedDynamics: .snapshotDynamics
        case N60UnifiedGraphUnsupportedProtection: .snapshotProtection
        case N60UnifiedGraphUnsupportedConvolution: .snapshotConvolution
        case N60UnifiedGraphUnsupportedAmbientOrANC: .snapshotAmbientOrANC
        case N60UnifiedGraphUnsupportedDelay: .snapshotDelay
        case N60UnifiedGraphUnsupportedGain: .snapshotGain
        default: .unsupportedKernelStage
        }
    }

    /// Short text for the diagnostics row.
    var displayText: String {
        switch self {
        case .optimizerFIR: "speaker optimizer FIR"
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
        case .convolutionProgramUnavailable: "convolver taps not retained or not matching"
        case .convolverWithSubwoofer: "room or speaker IR with a subwoofer"
        case .crossoverWithSubwoofer: "stereo crossover with a subwoofer"
        case .snapshotBypassOrAudition: "delta audition"
        case .snapshotMidSideOrMixedPhase: "Mid/Side or mixed-phase EQ out of range"
        case .snapshotEQSection: "EQ section out of range"
        case .snapshotSpatial: "spatial stage out of range"
        case .snapshotCrossover: "crossover out of range"
        case .snapshotDynamics: "dynamics stage out of range"
        case .snapshotProtection: "protection out of range"
        case .snapshotConvolution: "convolution out of range"
        case .snapshotAmbientOrANC: "ambient or ANC stage"
        case .snapshotDelay: "delay out of range"
        case .snapshotGain: "gain out of range"
        case .protectionCeilingOutOfRange: "protection ceiling out of range"
        case .unsupportedRoute: "same-device, aggregate or rack route"
        case .headphoneDSP: "headphone DSP"
        case .alignmentInvalid: "speaker trim, delay or mono-bass slope out of range"
        case .sampleRateMismatch: "sample rate mismatch"
        case .laneCountMismatch: "lane count mismatch"
        case .blockSizeTooLarge: "buffer larger than graph block"
        case .specRejected: "graph spec rejected"
        case .graphBuildFailed: "graph build failed"
        case .attachFailed: "graph attach failed"
        case .binauralProfileMissing: "no HRTF profile asset"
        case .binauralOutputNotStereo: "output is not two-channel headphones"
        case .binauralBudget: "HRTF set over the graph budget"
        case .midSideWithPairCalibration: "Mid/Side EQ with calibration EQ on a paired lane"
        case .midSideProgramFIR: "Mid/Side EQ with a program FIR"
        case .latencyAlignment: "latency alignment over the graph limit"
        case .stageBudget: "more than 256 graph stages"
        case .noFrontPair: "layout has no front left/right pair"
        case .virtualSpeakersSpeakerStage: "room, speaker IR or image stage with Virtual Speakers"
        }
    }
}
