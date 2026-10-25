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
        programs: UnifiedGraphProgramLookup = { _, _ in nil }
    ) -> UnifiedGraphConfiguration? {
        try? stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate, subwoofers: subwoofers, crossoverHz: crossoverHz,
            programs: programs
        ).get()
    }

    /// As `stereoConfiguration`, but says why the kernel keeps the snapshot.
    static func stereoEligibility(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80,
        programs: UnifiedGraphProgramLookup = { _, _ in nil }
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
        guard var stages = stereoStages(snapshot: &snapshot, configuration: &configuration) else {
            return .failure(.stageParametersUnreadable)
        }
        // E6 S8d: recover each enabled convolver's taps by generation and verify them against the snapshot's record.
        let states = [
            (UnifiedGraphProgramKind.convolution, snapshot.convolution),
            (.roomCorrection, snapshot.roomCorrection),
            (.speakerIR, snapshot.speakerIR),
        ]
        for (kind, state) in states where state.enabled {
            guard let program = programs(kind, state.programGeneration),
                  recoveredProgramMatches(program, state) else {
                return .failure(.convolutionProgramUnavailable)
            }
            switch kind {
            case .convolution: stages.programFIR = program
            case .roomCorrection: stages.roomFIR = program
            case .speakerIR: stages.speakerIR = program
            }
        }
        if (stages.roomFIR != nil || stages.speakerIR != nil), !subwoofers.isEmpty {
            return .failure(.convolverWithSubwoofer)
        }
        if stages.crossover != nil, !subwoofers.isEmpty {
            return .failure(.unsupportedKernelStage)
        }
        configuration.stereoStages = stages
        let p = snapshot.protection
        if p.limiterEnabled || p.truePeakGuardEnabled || p.softClipperEnabled || p.gainRiderEnabled {
            let ceilingDB = 20.0 * log10(Double(max(p.limiterCeilingLinear, 1e-6)))
            guard ceilingDB >= -20, ceilingDB <= 0 else { return .failure(.protectionCeilingOutOfRange) }
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
                    driveDB: 20.0 * log10(Double(max(p.clipperDriveLinear, 1e-6))),
                    thresholdDB: 20.0 * log10(Double(max(p.clipperThresholdLinear, 1e-6))),
                    knee: Double(p.clipperKneeSmooth),
                    curve: Int(p.clipperCurve.rawValue),
                    autoCompensate: p.clipperCompensationLinear != 1,
                    asymmetryDB: Double(p.clipperAsymmetryTrimDB)
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
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: crossoverHz, lfeLane: nil, subwoofers: subwoofers
            )
        }
        return .success(configuration)
    }

    /// The retained taps are the ones the kernel was prepared with: same generation, tap count, shared-or-stereo shape
    /// and declared latency as the snapshot's record, all finite, within what the core holds.
    static func recoveredProgramMatches(_ program: UnifiedGraphFIRProgram, _ state: N60ConvolutionGraphState) -> Bool {
        guard program.generation == state.programGeneration,
              program.left.count == Int(state.tapCount), program.left.count <= 32_768,
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
            if dynamics.spectralDenoiser.enabled {
                var values = [Float](repeating: 0, count: 9)
                if N60UnifiedGraphDenoiserParams(pointer, &values) { stages.denoiser = values } else { ok = false }
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
        bassManagementConfiguration: BassManagementConfiguration,
        programDSP: UnifiedGraphProgramDSP? = nil
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
        if let programDSP, !programDSP.isNeutral {
            configuration.orderPolicy = .canonical
            configuration.programDSP = programDSP
            // Dry run, so the reason is known here and not as a bare "spec rejected" at session start.
            do { _ = try configuration.makeSpec() } catch let reason as UnifiedGraphFallbackReason {
                return .failure(reason)
            } catch { return .failure(.specRejected) }
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

    /// Largest response set (floats) a binaural graph may carry: 8M floats, 32 MB.
    static let binauralMaxResponseFloats = 8 * 1024 * 1024
    /// Head-yaw cells of a head-tracked set (15 degree steps, wrapped).
    static let binauralTrackedOrientations: UInt32 = 24

    /// Selection rule and spec for a binaural headphone session (E6 S8b2d): the output must be
    /// a 2-channel headphone endpoint, the program layout must have more than 2 channels and
    /// the profile must carry an asset. `asset` is already resampled to `sampleRate`. The
    /// HEADPHONE stage carries the profile's headroom, channel gain, polarity and EQ; channel
    /// delay and a headroom above 24 dB stay on the legacy path (`headphoneDSP`). Protection
    /// matches the legacy limiter. Program gain is applied by the bridge while gathering.
    static func binauralSpec(
        asset: BinauralProfileAsset?,
        layout: OutputProgramLayout,
        profile: HeadphoneDeviceProfileConfiguration,
        outputChannels: UInt32,
        sampleRate: Double,
        headTracking: Bool,
        maxBlockFrames: UInt32 = 16_384,
        programDSP: UnifiedGraphProgramDSP? = nil
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
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
        guard profile.headroomAttenuationDB.isFinite, (0.0...24.0).contains(profile.headroomAttenuationDB),
              profile.left.delayMilliseconds == 0, profile.right.delayMilliseconds == 0,
              profile.left.eqBands.filter(\.enabled).count <= 16,
              profile.right.eqBands.filter(\.enabled).count <= 16,
              (-24.0...24.0).contains(profile.left.gainDB), (-24.0...24.0).contains(profile.right.gainDB)
        else { return .failure(.headphoneDSP) }

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
        // speakers already carry the spatial image).
        func bands(_ side: HeadphoneChannelCorrection) -> [Float] {
            side.eqBands.filter(\.enabled).flatMap { band -> [Float] in
                [Float(band.type.realtimeCType.rawValue), Float(band.frequencyHz), Float(band.gainDB), Float(band.q)]
            }
        }
        let leftBands = bands(profile.left)
        let rightBands = bands(profile.right)
        var headphone: [Float] = [
            -Float(profile.headroomAttenuationDB), 0, 30, 0.0875, 700,
            Float(profile.left.gainDB), Float(profile.right.gainDB),
            profile.left.polarityInverted ? 1 : 0, profile.right.polarityInverted ? 1 : 0,
            Float(leftBands.count / 4), Float(rightBands.count / 4),
        ]
        headphone += leftBands + rightBands
        let stage = UnifiedGraphStageSpec(
            kind: UInt32(N60_STAGE_HEADPHONE.rawValue), stageId: N60_LSTAGE_HEADPHONE,
            laneA: 0, laneB: 1, laneMask: 0, params: headphone)
        guard let protectionIndex = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_PROTECTION }) else {
            return .failure(.specRejected)
        }
        // Same limiter as the legacy bridge: -1 dB ceiling, 0.5/90 ms, 2 ms look-ahead, 4x true-peak.
        spec.stages[protectionIndex].params = [1, -1, 0.5, 90, 2, 1, 4]
        spec.stages.insert(stage, at: protectionIndex)
        if var programDSP, !programDSP.isNeutral {
            programDSP.virtualSpeakers = true
            do { try programDSP.apply(to: &spec) } catch let reason as UnifiedGraphFallbackReason {
                return .failure(reason)
            } catch { return .failure(.specRejected) }
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
    /// Stereo: a convolver's taps were not retained, or do not match the snapshot's program record.
    case convolutionProgramUnavailable
    /// Stereo: room correction or speaker IR with a subwoofer lane.
    case convolverWithSubwoofer
    case protectionCeilingOutOfRange
    /// Retired in E6 S8e (those routes render through the graph); kept so diagnostics stay stable.
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
        case .convolutionProgramUnavailable: "convolver taps not retained or not matching"
        case .convolverWithSubwoofer: "room or speaker IR with a subwoofer"
        case .protectionCeilingOutOfRange: "protection ceiling out of range"
        case .unsupportedRoute: "same-device, aggregate or rack route"
        case .headphoneDSP: "headphone DSP"
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
