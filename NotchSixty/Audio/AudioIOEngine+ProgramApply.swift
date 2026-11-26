import CoreAudio
import Foundation

// E23 S4 part 3: gain, room correction and speaker IR application, program preparation and unified-graph program DSP, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: configuration
            )

        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: configuration,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive,
           configuration != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.gain = configuration
            inputs.ambient = clampedAmbientTarget
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: configuration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )
            try session.publishDSPGraph(graph)
        }

        commitGainConfiguration(configuration)
        commitAmbientCompensationRuntimeTarget(clampedAmbientTarget)
        commitActiveQuietZoneRuntimeTarget(candidateQuietZone)
        setLastError(nil)
    }

    func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        if configuration.enabled && configuration.filter == nil && configuration.lanes == nil {
            throw RoomCorrectionConfigurationError.filterRequired
        }
        if configuration.filter != nil && configuration.lanes != nil {
            throw RoomCorrectionConfigurationError.filterAndLanes
        }
        try configuration.lanes?.validate()
        if immutableSemanticTransportActive, configuration != roomCorrectionConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.room = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateRoomCorrectionFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                // Stay on the untreated path without rotating a stale FIR slot or
                // invoking a fade-through-silence transition.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                programs.setActiveRoomCorrectionProgram(nil)
            } else if configuration.isActiveOnStereoKernel {
                guard let filter = configuration.filter else {
                    throw RoomCorrectionConfigurationError.filterRequired
                }
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                programs.setActiveRoomCorrectionProgram(preparedProgram)
            } else {
                if activeRoomCorrectionProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                programs.setActiveRoomCorrectionProgram(nil)
            }
        } else {
            programs.setActiveRoomCorrectionProgram(nil)
        }

        // A lane plan cannot run on the stereo kernel (two-band stages, per-lane delays): the session plays uncorrected
        // and says why (Q9, owner 1 Nov 2026). N-channel sessions set the reason while they build the graph.
        if transportSession != nil {
            programs.setRoomCorrectionInactiveReason(configuration.enabled && configuration.lanes != nil ? .needsSpeakerProfile : nil)
        } else if !immutableSemanticTransportActive {
            programs.setRoomCorrectionInactiveReason(nil)
        }
        commitRoomCorrectionConfiguration(configuration)
        setLastError(nil)
    }

    /// E24 S3b: synthesises the lane plan at every rate the selected output exposes, before a deploy commits (Q8), so a
    /// rate change later hits the cache. Any failure throws and the deploy fails.
    func precomputeRoomCorrectionPlans(for lanes: RoomCorrectionLaneInstall) async throws {
        try lanes.validate()
        let rates = selectedOutputDevice?.correctionSampleRates ?? [48_000]
        for rate in rates {
            _ = try await roomCorrectionRateCache.planAsync(
                for: lanes.design, sampleRate: rate, unifiedGraphEnabled: unifiedGraphEnabled)
        }
    }

    /// The plan the graph runs at `sampleRate` for the stored lanes (a cache hit after the precompute), for verification.
    func installedRoomCorrectionPlan(sampleRate: Double) -> RoomCorrectionLanePlan? {
        guard roomCorrectionConfiguration.enabled, roomCorrectionInactiveReason == nil,
              let lanes = roomCorrectionConfiguration.lanes else { return nil }
        return try? roomCorrectionRateCache.plan(
            for: lanes.design, sampleRate: sampleRate, unifiedGraphEnabled: unifiedGraphEnabled)
    }

    func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw SpeakerIRConfigurationError.filterRequired
        }
        if immutableSemanticTransportActive, configuration != speakerIRConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.speakerIR = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateSpeakerIRFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                programs.setActiveSpeakerIRProgram(nil)
            } else if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw SpeakerIRConfigurationError.filterRequired
                }
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                programs.setActiveSpeakerIRProgram(preparedProgram)
            } else {
                if activeSpeakerIRProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                programs.setActiveSpeakerIRProgram(nil)
            }
        } else {
            programs.setActiveSpeakerIRProgram(nil)
        }

        commitSpeakerIRConfiguration(configuration)
        setLastError(nil)
    }

    /// The EQ FIR taps for the configured channel mode (left and optional second channel padded to one length), their
    /// declared latency and the linear-phase design report. Pure: prepares nothing.
    func eqFIRTaps(
        _ configuration: StereoEQConfiguration,
        sampleRate: Double
    ) throws -> (left: [Float], right: [Float]?, declaredLatencyFrames: UInt32, designInfo: EQLinearPhaseDesignInfo?) {
        let design = try eqFIRCache.design(for: EQFIRProgramKey(configuration, sampleRate: sampleRate)) {
            let taps = try EQFIRDesigner.design(configuration, sampleRate: sampleRate)
            return EQFIRDesign(
                left: taps.left, right: taps.right,
                declaredLatencyFrames: taps.declaredLatencyFrames, designInfo: taps.designInfo)
        }
        return (design.left, design.right, design.declaredLatencyFrames, design.designInfo)
    }

    func prepareEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedEQFIRProgram {
        // The taps come from the design cache (E27 S3c); the program itself is always freshly
        // prepared so its convolver runtime starts clean.
        let primary = try eqFIRTaps(configuration, sampleRate: session.outputFormat.sampleRate)
        let secondaryTaps = primary.right

        let slot = programs.eqFIRSlotToUse
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: primary.left,
                rightTaps: secondaryTaps,
                declaredLatencyFrames: primary.declaredLatencyFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        programs.advanceEQFIRSlot(after: slot)
        return PreparedEQFIRProgram(
            slot: slot,
            programInfo: programInfo,
            designInfo: primary.designInfo
        )
    }

    /// E27 S3c: designs `partner` (the other A/B slot) now and keeps its design cached while the
    /// live EQ is edited, so a toggle to it designs nothing. `nil` ends the protection. Control
    /// thread; publishes nothing. Skipped when the partner needs no FIR.
    func prewarmEQFIRPartner(_ partner: StereoEQConfiguration?) {
        guard let partner, partner.requiresEQFIRProgram else {
            eqFIRCache.protect(nil)
            return
        }
        let rate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? selectedOutputDevice?.nominalSampleRate ?? 48_000
        eqFIRCache.protect(EQFIRProgramKey(partner, sampleRate: rate))
        _ = try? eqFIRTaps(partner, sampleRate: rate)
    }

    func rateAdaptedRoomCorrectionFilter(
        _ filter: RoomCorrectionFilter,
        sampleRate: Double
    ) -> RoomCorrectionFilter {
        guard let designRate = filter.sampleRate,
              abs(designRate - sampleRate) >= 0.5 else { return filter }
        if let cached = adaptedRoomCorrectionFilter,
           abs(cached.sampleRate - sampleRate) < 0.5,
           cached.source == filter {
            return cached.filter
        }
        guard let adapted = roomCorrectionFilterAdapter?(filter, sampleRate),
              let adaptedRate = adapted.sampleRate,
              abs(adaptedRate - sampleRate) < 0.5 else {
            return filter
        }
        programs.setAdaptedRoomCorrectionFilter(source: filter, sampleRate: sampleRate, filter: adapted)
        return adapted
    }

    func validateRoomCorrectionFilter(
        _ deployedFilter: RoomCorrectionFilter,
        outputSampleRate: Double
    ) throws {
        let filter = rateAdaptedRoomCorrectionFilter(deployedFilter, sampleRate: outputSampleRate)
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw RoomCorrectionConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw RoomCorrectionConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw RoomCorrectionConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
    }

    func prepareRoomCorrectionProgram(
        _ deployedFilter: RoomCorrectionFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedRoomCorrectionProgram {
        try validateRoomCorrectionFilter(deployedFilter, outputSampleRate: session.outputFormat.sampleRate)
        let filter = rateAdaptedRoomCorrectionFilter(
            deployedFilter,
            sampleRate: session.outputFormat.sampleRate
        )

        let slot = programs.roomCorrectionSlotToUse
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareRoomCorrectionProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        programs.advanceRoomCorrectionSlot(after: slot)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    /// Validates `filter` for `outputSampleRate` and returns what plays: with `e7.rate-adapt` a filter that carries
    /// another rate is resampled (cached, control plane; E7 S2), otherwise a rate mismatch refuses as before.
    @discardableResult
    func validateSpeakerIRFilter(_ filter: SpeakerIRFilter, outputSampleRate: Double) throws -> SpeakerIRFilter {
        try SpeakerIRRateAdapter.shared.validated(
            filter, outputSampleRate: outputSampleRate, enabled: FeatureFlags().isEnabled(.rateAdapt))
    }

    func prepareSpeakerIRProgram(
        _ filter: SpeakerIRFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedSpeakerIRProgram {
        let filter = try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)

        let slot = programs.speakerIRSlotToUse
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareSpeakerIRProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        programs.advanceSpeakerIRSlot(after: slot)
        return PreparedSpeakerIRProgram(slot: slot, programInfo: programInfo)
    }

    /// E6 S9a: the stereo-class DSP (EQ, dynamics, FIR, room, Speaker IR, image, protection) the active configuration
    /// would apply, ready to map onto an N-channel or Virtual Speakers graph. Nil when the flag is off, when global
    /// bypass or reference audition removes the program DSP (the lane calibration, bass management, binaural
    /// rendering and protection stay), or when nothing is active. Throws when the configuration is unusable
    /// (missing filter, rate mismatch) or when the graph cannot reproduce it, so activation never silently drops it.
    func makeUnifiedProgramDSP(
        sampleRate: Double,
        shape: UnifiedGraphLayoutShape,
        virtualSpeakers: Bool,
        subwooferCount: Int? = nil,
        foldStereoCrossover: Bool = false,
        inputs candidate: LiveGraphInputs? = nil
    ) throws -> UnifiedGraphProgramDSP? {
        guard unifiedGraphEnabled else {
            let room = candidate?.room ?? roomCorrectionConfiguration
            programs.setRoomCorrectionInactiveReason(room.enabled && room.lanes != nil ? .needsUnifiedGraph : nil)
            return nil
        }
        let inputs = candidate ?? currentLiveGraphInputs
        let playback = inputs.playback
        if FIRUpdatePolicy.isRawBypassed(playback) || playback.auditionMode == .reference { return nil }
        // E6 S12h part 3 (G50): the delta runs on the program lanes of a speaker graph (mask form, ABI v31). Virtual
        // Speakers renders the ears from the lanes, so a lane delta would not be what the listener hears.
        let deltaAudition = playback.auditionMode == .delta
        if deltaAudition, virtualSpeakers {
            throw LiveNChannelTransportError.unsupportedActiveDSP("delta audition in Virtual Speakers mode")
        }
        // E8 S11b: stereo plus sub lanes folds the user's crossover (monitor mode, phase alignment, filter) into the
        // session's one bass management; every other layout keeps the route plan's own split and a disabled crossover.
        let subLaneTotal = subwooferCount ?? 0
        let fold = foldStereoCrossover && !virtualSpeakers && subLaneTotal > 0 && shape.laneCount == 2
            && shape.lfeLane == nil && renderBassManagementConfiguration(inputs.bass).enabled
        let foldedBassSettings = fold ? renderBassManagementConfiguration(inputs.bass) : BassManagementConfiguration()
        var snapshot = try inputs.stereoEQ.makeGraphSnapshot(
            sampleRate: sampleRate,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: foldedBassSettings,
            dynamicsConfiguration: inputs.dynamics,
            playbackConfiguration: playback,
            masterGainLinear: 1, groupRoleCodes: shape.roleCodes
        )
        // The ambient live target rides in the snapshot like the stereo path (E6 S9b); the stereo engine only
        // runs it on speakers, so Virtual Speakers keeps it off.
        if !virtualSpeakers {
            try attachAmbientCompensation(
                ambientTargetClampedToHeadroom(inputs.ambient, gainConfiguration: inputs.gain), to: &snapshot)
        }
        // The graph never reads the kernel's convolver slots; it takes the taps by generation. Generations here are
        // local to this one translation (1 EQ FIR, 2 room correction, 3 Speaker IR).
        var retained: [UInt64: UnifiedGraphFIRProgram] = [:]
        func info(_ generation: UInt64, _ left: [Float], _ declared: UInt32) -> N60ConvolutionProgramInfo {
            N60ConvolutionProgramInfo(
                prepared: true,
                generation: generation,
                tapCount: UInt32(left.count),
                partitionCount: N60ConvolutionPartitionCountForTapCount(UInt32(left.count)),
                engineLatencyFrames: N60_CONVOLUTION_PARTITION_FRAMES,
                declaredLatencyFrames: declared
            )
        }
        if FIRUpdatePolicy.shouldPrepareEQFIR(stereoEQ: inputs.stereoEQ, playback: playback) {
            let taps = try eqFIRTaps(inputs.stereoEQ, sampleRate: sampleRate)
            retained[1] = UnifiedGraphFIRProgram(
                generation: 1, left: taps.left, right: taps.right, declaredLatencyFrames: taps.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetConvolutionProgram(
                &snapshot, 0, info(1, taps.left, taps.declaredLatencyFrames), true) else {
                throw EQConfigurationError.convolutionProgramUnavailable
            }
        }
        var installedLanes: (plan: RoomCorrectionLanePlan, delays: [Int: UInt32])?
        var inactive: RoomCorrectionInactiveReason?
        // E24 S9: a blind-ABX override replaces the profile's lanes while its sheet is open. It never changes the
        // stored configuration, and a layout or delay it cannot honour throws instead of silently falling back.
        let abx = roomCorrectionABXOverride
        var abxGain: Float = 1
        if let abx {
            guard abx.install.matches(programLaneCount: shape.laneCount, subwooferCount: subwooferCount) else {
                throw RoomCorrectionLaneInstallError.invalidLayout
            }
            var delays = try abx.install.delayFrames(sampleRate: sampleRate)
            if abx.extraDelayFrames > 0 {
                for lane in 0..<(shape.laneCount + (subwooferCount ?? 0)) {
                    let total = delays[lane, default: 0] + abx.extraDelayFrames
                    guard total <= N60_GRAPH_MAX_DELAY_FRAMES else {
                        throw RoomCorrectionLaneInstallError.delayTooLong(lane: lane)
                    }
                    delays[lane] = total
                }
            }
            installedLanes = (try roomCorrectionRateCache.plan(for: abx.install.design, sampleRate: sampleRate), delays)
            abxGain = abx.gain
        } else if inputs.room.enabled, let lanes = inputs.room.lanes {
            // Lane plans install on the main lanes (design note 8). A layout that no longer matches, or a rate the
            // filters cannot be built for, leaves correction off with its reason; playback is never refused (Q9, Q11).
            if !lanes.matches(programLaneCount: shape.laneCount, subwooferCount: subwooferCount) {
                inactive = .layoutChanged
            } else {
                do {
                    let delays = try lanes.delayFrames(sampleRate: sampleRate)
                    // Cache hit after the deploy-time precompute; a miss (new device rate) synthesises here, on the control thread.
                    let plan = try roomCorrectionRateCache.plan(for: lanes.design, sampleRate: sampleRate)
                    installedLanes = (plan, delays)
                } catch {
                    inactive = .synthesisFailed(rate: sampleRate)
                }
            }
        } else if inputs.room.enabled {
            guard let filter = inputs.room.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: sampleRate)
            let adapted = rateAdaptedRoomCorrectionFilter(filter, sampleRate: sampleRate)
            retained[2] = UnifiedGraphFIRProgram(
                generation: 2, left: adapted.leftTaps, right: adapted.rightTaps,
                declaredLatencyFrames: adapted.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
                &snapshot, 1, info(2, adapted.leftTaps, adapted.declaredLatencyFrames), true) else {
                throw RoomCorrectionConfigurationError.graphAttachmentFailed
            }
        }
        if inputs.speakerIR.enabled {
            guard let deployed = inputs.speakerIR.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            let filter = try validateSpeakerIRFilter(deployed, outputSampleRate: sampleRate)
            retained[3] = UnifiedGraphFIRProgram(
                generation: 3, left: filter.leftTaps, right: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetSpeakerIRProgram(
                &snapshot, 2, info(3, filter.leftTaps, filter.declaredLatencyFrames), true) else {
                throw SpeakerIRConfigurationError.graphAttachmentFailed
            }
        }
        let programs = retained
        var stereo: UnifiedGraphConfiguration
        // Neutral placeholders: the fold adds the crossover's sub gain, polarity and all-pass; the route plan's
        // calibrations are added by `nChannelEligibility`.
        switch UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate,
            subwoofers: fold ? Array(repeating: UnifiedGraphSubwoofer(), count: subLaneTotal) : [],
            crossoverHz: foldedBassSettings.frequencyHz,
            programs: { _, generation in programs[generation] },
            compressorExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.compressor.coreExtras(sampleRate: sampleRate) : nil,
            expanderExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.expander.coreExtras(sampleRate: sampleRate, lookahead: FeatureFlags.isEnabledProcessWide(.eqPageEnhancements), swapTiming: FeatureFlags.isEnabledProcessWide(.dynamicsSound)) : nil,
            multibandExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.multibandCompressor.translatorBlock(sampleRate: sampleRate, bands: FeatureFlags.isEnabledProcessWide(.eqPageEnhancements)) : nil
        ) {
        case .success(let configuration): stereo = configuration
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        }
        // E4 S30a: planned unmasking cuts ride as the AMBIENT stage's section trailer (graph ABI v32). nil cuts, an
        // invalid plan or Virtual Speakers keep the plain stage. A neutral base is made when the kernel left ambient off.
        if !virtualSpeakers, let cuts = inputs.ambient.unmaskingCutsDB,
           let params = AmbientUnmaskOverlay.stageParameters(
            base: stereo.stereoStages.ambient, plannedCutsDB: cuts, sampleRate: sampleRate) {
            stereo.stereoStages.ambient = params
        }
        // Bypassed EQ covers every lane (the other program stages follow the lane set of the EQ mode).
        let mode: UnifiedGraphProgramDSP.EQMode
        switch inputs.stereoEQ.bypassed ? .linked : inputs.stereoEQ.channelMode {
        case .linked: mode = .linked
        case .independent: mode = .independent
        case .midSide: mode = .midSide
        }
        var program = UnifiedGraphProgramDSP(
            stereo: stereo, shape: shape, eqMode: mode, virtualSpeakers: virtualSpeakers, groupEQ: try inputs.stereoEQ.groupCurves(shape: shape, sampleRate: sampleRate))
        program.deltaAudition = deltaAudition
        if let installedLanes {
            program.inputGain *= abxGain
            program.roomLanes = installedLanes.plan
            program.laneDelayFrames = installedLanes.delays
            program.subLaneCount = subwooferCount ?? 0
        }
        self.programs.setRoomCorrectionInactiveReason(inactive)
        return program.isNeutral && program.foldedBass == nil ? nil : program
    }
}
