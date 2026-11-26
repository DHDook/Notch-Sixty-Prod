import CoreAudio
import Foundation

// E23 S4 part 2: transport start, build (stereo, routed, N-channel, binaural) and teardown,
// moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func start(resetProcessingSessionCounters: Bool) throws {
        guard lifecycle.state == .idle else { return }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "No output selected")
            setLastError(error.localizedDescription)
            throw error
        }

        if resetProcessingSessionCounters {
            transport.resetProcessingSessionCounters()
        }

        do {
            try setLifecycle(.requestingPermission)
            try setLifecycle(.creatingTap)
            try buildTransport(output: output)
            try setLifecycle(.creatingAggregate)
            try setLifecycle(.openingOutput)
            try setLifecycle(.starting)
            try setLifecycle(.running)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            try syncMasterVolumeMonitorToSelectedOutput()
            setLastError(nil)
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            throw error
        }
    }

    func setLifecycle(_ nextState: AudioLifecycleState) throws {
        try lifecycle.transition(to: nextState)
        mirrorLifecycleState()
    }

    func buildTransport(output: AudioOutputDevice) throws {
        guard output.nominalSampleRate <= RateCapacity.supportedMaximumSampleRate else {
            throw CoreAudioTransportError.sampleRateAboveSupportedMaximum(
                rate: output.nominalSampleRate, maximum: RateCapacity.supportedMaximumSampleRate)
        }
        applyLowLatencyOutputProfile(to: output)
        if let headphone = headphoneDeviceProfileConfiguration, headphone.enabled {
            if outputDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            if headphone.spatialMode == .virtualSpeakers {
                try buildBinauralHeadphoneTransport(output: output, profile: headphone)
            } else {
                try buildStereoTransport(output: output)
            }
            return
        }
        if let routing = speakerRoutingConfiguration, routing.enabled {
            try buildRoutedTransport(output: output, routing: routing)
            return
        }
        if outputDeviceProfileConfiguration?.enabled == true {
            try buildNChannelTransport(output: output)
            return
        }
        try buildStereoTransport(output: output)
    }

    /// E8 S4: the graph configuration of a routed session: the program lanes and sub lanes the N-channel path
    /// builds, with the routing compiled onto them (ROUTE, XOVER, delay alignment, per-output protection).
    func makeRoutedGraphConfiguration(
        routing: SpeakerRoutingConfiguration,
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        inputs: LiveGraphInputs
    ) throws -> UnifiedGraphConfiguration {
        guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
        }
        // E6 S12h part 3 (G51 decision): a delta cannot be compared across a routing (each output has its own
        // crossover, delay and protection), so a routed session refuses it and the picker offers it only unrouted.
        if inputs.playback.auditionMode == .delta {
            throw LiveNChannelTransportError.routingRefused("the delta audition is not available with speaker routing; switch to Processed or Reference.")
        }
        let program = try makeUnifiedProgramDSP(
            sampleRate: sampleRate, shape: shape, virtualSpeakers: false,
            subwooferCount: Int(routePlan.subwooferCount), inputs: inputs)
        // The routing's sub sources decide the sub lanes; bass management supplies their crossover and trims.
        var bass = renderBassManagementConfiguration(inputs.bass)
        bass.enabled = routePlan.subwooferCount > 0
        switch UnifiedGraphTranslator.nChannelEligibility(
            routePlan: routePlan, sampleRate: sampleRate, gainConfiguration: inputs.gain,
            bassManagementConfiguration: bass, programDSP: program
        ) {
        case .success(var base):
            // The user's protection moves from the program lanes to every output lane (the compiler gives each
            // output its own PROTECTION stage, aligned in latency); a program-lane limiter would run on cleared lanes.
            if base.protection == nil, let moved = base.programDSP?.protection { base.protection = moved }
            base.programDSP?.protection = nil
            // The bridge reads the output lanes as the last `routedOutputPhysicalChannels.count` graph lanes, so the
            // compiled routing must have exactly that many (it does by construction; this keeps it so).
            guard routing.outputEndpoints.count == routePlan.routedOutputPhysicalChannels.count else {
                throw LiveNChannelTransportError.routingRefused("the routing outputs do not match the output plan.")
            }
            return try compileRoutedAttachingTreatment(routing, onto: base)
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        }
    }

    /// Checks that apply to any enabled routing, whether it is being set or started.
    func validateSpeakerRoutingActivation(_ routing: SpeakerRoutingConfiguration) throws {
        guard unifiedGraphEnabled else {
            throw LiveNChannelTransportError.routingRefused("it needs the unified graph, and the legacy render kernel is selected.")
        }
        if headphoneDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.speakerProfileConflict
        }
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        let subs = routing.subwooferSourceCount
        if subs > UnifiedGraphConfiguration.maxSubwoofers {
            throw LiveNChannelTransportError.routingRefused("it reads \(subs) subwoofer sources and the limit is \(UnifiedGraphConfiguration.maxSubwoofers).")
        }
        if subs > 0, !bassManagementConfiguration.enabled {
            throw LiveNChannelTransportError.routingRefused("it reads subwoofer sources, so bass management must be on.")
        }
        if subs == 0, bassManagementConfiguration.enabled {
            throw LiveNChannelTransportError.routingRefused("bass management is on but no speaker reads a subwoofer source.")
        }
    }

    /// E8 S4: sets (or, with nil, clears) the speaker routing. Idle, it just stores it. Running, an edit that keeps
    /// the same outputs and subwoofer sources (crossover corners, gains, trims, delays, EQ) is republished to the
    /// graph, which posts gain changes over 5 ms and fades a family or order change; any other change is a
    /// session-kind change and reconfigures with the shutdown fade. Throws, leaving the routing and the running
    /// session as they were, when the routing cannot run.
    func replaceSpeakerRoutingConfiguration(_ configuration: SpeakerRoutingConfiguration?) throws {
        let active = configuration?.enabled == true
        if let configuration, active { try validateSpeakerRoutingActivation(configuration) }
        guard configuration != speakerRoutingConfiguration else { return }
        let wasActive = speakerRoutingConfiguration?.enabled == true
        guard lifecycle.state != .idle, active || wasActive else {
            transport.setSpeakerRoutingConfiguration(configuration)
            setLastError(nil)
            return
        }
        if let configuration, active, let current = speakerRoutingConfiguration, wasActive,
           let session = nChannelTransportSession, session.routePlan.isRouted, liveGraphEditsAvailable,
           current.outputEndpoints == configuration.outputEndpoints,
           current.subwooferSourceCount == configuration.subwooferSourceCount {
            try republishLiveGraph(currentLiveGraphInputs, routing: configuration)
            transport.setSpeakerRoutingConfiguration(configuration)
            setLastError(nil)
            return
        }
        transport.setSpeakerRoutingConfiguration(configuration)
        setLastError(nil)
        scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, settleDelay: 0.03)
    }

    func buildRoutedTransport(output: AudioOutputDevice, routing: SpeakerRoutingConfiguration) throws {
        try validateSpeakerRoutingActivation(routing)
        try validateLiveNChannelActivation()
        try requireNoCrossoverAudition(bassManagementConfiguration)
        if stagedRoomTreatment != nil {
            throw LiveNChannelTransportError.routingRefused("room treatment cannot run with the routing matrix.")
        }
        // The program layout comes from an enabled Output Device Profile (5.1 and so on), else stereo. The routing
        // owns every physical output, so the profile's speaker and subwoofer assignments are not used.
        let layout = outputDeviceProfileConfiguration?.enabled == true
            ? (outputDeviceProfileConfiguration?.programLayout ?? .stereo) : .stereo
        let routePlan = try routing.makeLivePlan(
            programLayout: layout,
            availableDevices: outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid,
            bassManagementEnabled: routing.subwooferSourceCount > 0
        )
        let renderGraph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        let configuration = try makeRoutedGraphConfiguration(
            routing: routing, routePlan: routePlan, sampleRate: output.nominalSampleRate,
            inputs: currentLiveGraphInputs)
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: renderGraph,
            outputGain: currentMasterSoftwareGain,
            roomTreatment: nil,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphConfiguration: configuration,
            unifiedGraphIneligibility: nil,
            unifiedGraphRequired: true
        )
        programs.clearAll()
        nChannelTransportSession = session
    }

    func validateLiveNChannelActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy per-driver speaker processing")
        }
        // E6 S9a: with the unified graph the stereo-class DSP is mapped onto the program lanes (or the activation
        // throws the graph's reason); without it every restriction below stays.
        if !unifiedGraphEnabled {
            if !stereoEQConfiguration.bypassed {
                if stereoEQConfiguration.channelMode != .linked
                    || stereoEQConfiguration.phaseMode != .minimumPhase
                    || stereoEQConfiguration.enabledBandCount != 0 {
                    throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ")
                }
            }
            // Gate on what would actually process audio. Disabled processors keep
            // their edited parameters and must not block activation.
            if playbackControlConfiguration.globalBypassed {
                throw LiveNChannelTransportError.globalBypassUnsupported
            }
            if playbackControlConfiguration.hasActiveImageProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls")
            }
            if dynamicsConfiguration.hasActiveProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics/protection")
            }
            if roomCorrectionConfiguration.enabled {
                throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo room correction")
            }
            if speakerIRConfiguration.enabled {
                throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo Speaker IR")
            }
        }
        if bassManagementConfiguration.physicalOutputMode != nil {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy physical crossover routing")
        }
    }

    /// E8 S11b: true when the session is stereo plus 1 to 8 subs on the unified graph, unrouted, so the stereo
    /// crossover's monitor mode, phase-alignment all-pass and filter family fold into its bass management.
    func foldsStereoCrossover(
        routePlan: LiveNChannelOutputRoutePlan, bass: BassManagementConfiguration, requiresRackFree: Bool = false
    ) -> Bool {
        guard unifiedGraphEnabled, bass.enabled, !routePlan.isRouted, routePlan.subwooferCount >= 1,
              !(requiresRackFree && stagedAudioUnitRack != nil),
              let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles),
              shape.laneCount == 2, shape.lfeLane == nil else { return false }
        return true
    }

    /// Where the crossover does not fold, its monitor audition and single-sub phase alignment have no stage to run in.
    func requireNoCrossoverAudition(_ bass: BassManagementConfiguration) throws {
        if bass.subPhaseAlignmentEnabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy single-sub phase alignment")
        }
        if bass.monitorMode != .recombined {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo crossover monitor audition")
        }
    }

    func buildNChannelTransport(output: AudioOutputDevice) throws {
        guard let profile = outputDeviceProfileConfiguration, profile.enabled else {
            throw OutputDeviceProfileError.profileDisabled
        }
        try validateLiveNChannelActivation()
        let routePlan = try profile.makeLivePlan(
            availableDevices: outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid,
            bassManagementEnabled: bassManagementConfiguration.enabled
        )
        let foldsCrossover = foldsStereoCrossover(
            routePlan: routePlan, bass: renderBassManagementConfiguration(), requiresRackFree: true)
        if !foldsCrossover { try requireNoCrossoverAudition(bassManagementConfiguration) }
        if let stagedRoomTreatment {
            guard stagedRoomTreatment.acceptedProfile == profile,
                  stagedRoomTreatment.acceptedSelectedOutputUID == output.uid else {
                throw LiveNChannelTransportError.roomTreatmentPermitMismatch
            }
        }
        // E8 A3: the legacy kernel drives at most 4 subs; refuse by name rather than truncate. The graph path below
        // takes 5 to 8 and must then be required (checked after eligibility).
        if bassManagementConfiguration.enabled,
           Int(routePlan.subwooferCount) > SubwooferLimit.legacyKernel,
           !unifiedGraphEnabled {
            throw LiveNChannelTransportError.tooManySubwoofersForLegacyKernel(Int(routePlan.subwooferCount))
        }
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        var graphConfiguration: UnifiedGraphConfiguration?
        var graphIneligibility: UnifiedGraphFallbackReason?
        var programDSP: UnifiedGraphProgramDSP?
        let ancSplitter = unifiedGraphEnabled
            ? hostedQuietZoneSplitter(routePlan: routePlan, sampleRate: output.nominalSampleRate) : nil
        if unifiedGraphEnabled {
            // E6 S9a: stereo-class DSP runs on the graph or activation throws; it is never dropped.
            guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            programDSP = try makeUnifiedProgramDSP(
                sampleRate: output.nominalSampleRate, shape: shape, virtualSpeakers: false,
                subwooferCount: Int(routePlan.subwooferCount), foldStereoCrossover: foldsCrossover)
            switch UnifiedGraphTranslator.nChannelEligibility(
                routePlan: routePlan,
                sampleRate: output.nominalSampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration,
                programDSP: programDSP,
                ancHostFeed: ancSplitter != nil,
                userOutputGain: currentMasterSoftwareGain
            ) {
            case .success(var configuration):
                attachStagedMIMOTreatment(to: &configuration)
                graphConfiguration = configuration
            case .failure(let reason): graphIneligibility = reason
            }
        }
        // E8 A3: a graph that cannot take the setup would fall back to the legacy kernel; with 5 to 8 subs that is
        // a refusal, not a truncation.
        let needsGraphForSubs = bassManagementConfiguration.enabled
            && Int(routePlan.subwooferCount) > SubwooferLimit.legacyKernel
        if needsGraphForSubs, graphConfiguration == nil {
            throw LiveNChannelTransportError.tooManySubwoofersForLegacyKernel(Int(routePlan.subwooferCount))
        }
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: graph,
            outputGain: currentMasterSoftwareGain,
            roomTreatment: stagedRoomTreatment,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphConfiguration: graphConfiguration,
            unifiedGraphIneligibility: graphIneligibility,
            // E6 S12g4: with the graph on, every N-channel session runs on it or activation throws the named reason; only an
            // Audio Unit rack (not a graph stage) keeps the legacy pipeline.
            unifiedGraphRequired: unifiedGraphEnabled && stagedAudioUnitRack == nil || needsGraphForSubs,
            ancFeedSplitter: ancSplitter
        )
        programs.clearAll()
        nChannelTransportSession = session
        adoptQuietZoneReferenceHost()
    }

    /// E26 S7b2c: a new profile session starts with fresh reference rings, so the anchor fan-out restarts and the
    /// speaker-drive demand is re-applied to the new feed (a no-op unless the profile session hosts Quiet Zone).
    func adoptQuietZoneReferenceHost() {
        speakerDrive.resetAnchorFanout()
        applySpeakerDriveDemand()
    }

    /// E26 S7b2: the bus splitter the Quiet Zone feed renders through, for a profile session that is class A (two mains
    /// plus one sub output) with `e26.sub-aware-anc` on; nil otherwise, which leaves the graph exactly as before. The
    /// splitter is the app's own mains-plus-sub design from the active bass management.
    func hostedQuietZoneSplitter(
        routePlan: LiveNChannelOutputRoutePlan, sampleRate: Double
    ) -> N60SpeakerBusSplitterSnapshot? {
        // A routed session (the ROUTE stage owns every physical output) never hosts Quiet Zone in v1 (gap G18).
        guard FeatureFlags().isEnabled(.subAwareAnc), bassManagementConfiguration.enabled, !routePlan.isRouted,
              routePlan.subwooferCount == 1, routePlan.programLayout.roles.count == 2 else { return nil }
        var bass = bassManagementConfiguration
        bass.physicalOutputMode = .mainsSub
        return try? bass.makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
    }

    func validateBinauralHeadphoneActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if outputDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.speakerProfileConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("per-driver speaker processing")
        }
        if !unifiedGraphEnabled {
            if !stereoEQConfiguration.bypassed {
                if stereoEQConfiguration.channelMode != .linked
                    || stereoEQConfiguration.phaseMode != .minimumPhase
                    || stereoEQConfiguration.enabledBandCount != 0 {
                    throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ in Virtual Speakers mode")
                }
            }
            if playbackControlConfiguration.globalBypassed {
                throw LiveNChannelTransportError.globalBypassUnsupported
            }
            if playbackControlConfiguration.hasActiveImageProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls in Virtual Speakers mode")
            }
            if dynamicsConfiguration.hasActiveProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics in Virtual Speakers mode")
            }
        }
        if bassManagementConfiguration.enabled
            || bassManagementConfiguration.physicalOutputMode != nil
            || bassManagementConfiguration.subPhaseAlignmentEnabled
            || bassManagementConfiguration.monitorMode != .recombined {
            throw LiveNChannelTransportError.unsupportedActiveDSP("speaker bass management in Virtual Speakers mode")
        }
        if roomCorrectionConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("speaker room correction in Virtual Speakers mode")
        }
        if speakerIRConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("Speaker IR in Virtual Speakers mode")
        }
    }

    func buildBinauralHeadphoneTransport(
        output: AudioOutputDevice,
        profile: HeadphoneDeviceProfileConfiguration
    ) throws {
        try validateBinauralHeadphoneActivation()
        let selected = try profile.validateForActivation(
            availableDevices: outputDevices,
            selectedOutputUID: output.uid,
            sampleRate: output.nominalSampleRate
        )
        let source = try profile.resolveProgramSource(
            availableDevices: outputDevices,
            selectedOutput: selected
        )
        guard source.supports(sampleRate: output.nominalSampleRate) else {
            throw BinauralHeadphoneTransportError.sampleRateMismatch(
                source: source.nominalSampleRate, output: output.nominalSampleRate
            )
        }
        guard let reference = profile.binauralProfile else {
            throw HeadphoneDeviceProfileError.binauralProfileRequired
        }
        // HRIRs measured at another rate are converted off the realtime path
        // rather than refusing to start after a nominal-rate change.
        let asset = try binauralAssetCache.asset(
            for: reference, sampleRate: output.nominalSampleRate, store: binauralProfileAssetStore)
        transport.setRenderedBinauralProfile(reference)
        let prepared = try asset.prepare(for: profile.programLayout)
        let headphoneSnapshot = try profile.makeRealtimeSnapshot(
            sampleRate: output.nominalSampleRate
        )
        let combinedGainDB = gainConfiguration.inputPreampDB
            + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
        let programGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard programGain.isFinite, programGain > 0, programGain <= 16 else {
            throw BinauralHeadphoneTransportError.bridgeAllocationFailed
        }
        // E6 S8b2d: with the flag on, the core renders binaural, headphone DSP and protection when
        // the setup is one it reproduces; otherwise the legacy pipeline stays and the reason shows
        // in diagnostics.
        var graphSpec: UnifiedGraphSpec?
        var graphBaseSpec: UnifiedGraphSpec?
        var graphIneligibility: UnifiedGraphFallbackReason?
        var programDSP: UnifiedGraphProgramDSP?
        if unifiedGraphEnabled {
            guard let shape = UnifiedGraphLayoutShape(roles: profile.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            programDSP = try makeUnifiedProgramDSP(
                sampleRate: output.nominalSampleRate, shape: shape, virtualSpeakers: true)
            switch UnifiedGraphTranslator.binauralBaseSpec(
                asset: asset,
                layout: profile.programLayout,
                profile: profile,
                outputChannels: UInt32(output.outputChannelCount),
                sampleRate: output.nominalSampleRate,
                headTracking: profile.headTracking?.enabled == true,
                programGain: Float(programGain)
            ) {
            case .success(let base):
                switch UnifiedGraphTranslator.binauralApplyProgram(
                    base: base, programDSP: programDSP, programGain: Float(programGain)
                ) {
                case .success(let spec):
                    graphBaseSpec = base
                    graphSpec = spec
                case .failure(let reason): graphIneligibility = reason
                }
            case .failure(let reason): graphIneligibility = reason
            }
        }
        // E13 S4: a response longer than the legacy renderer's taps renders only through the unified graph's
        // early/tail split; the dormant legacy bridge gets the truncation, and without a graph the setup is refused.
        let longResponse = asset.tapCount > Int(N60_BINAURAL_MAX_TAPS)
        if longResponse, graphSpec == nil {
            throw BinauralHeadphoneTransportError.longResponseNeedsUnifiedGraph
        }
        let session = try CoreAudioBinauralHeadphoneTransportSession(
            selectedOutput: output,
            programSource: source,
            programLayout: profile.programLayout,
            preparedProfile: prepared.truncated(toTaps: Int(N60_BINAURAL_MAX_TAPS)),
            headphoneSnapshot: headphoneSnapshot,
            programGain: programGain,
            outputGain: currentMasterSoftwareGain,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphSpec: graphSpec,
            unifiedGraphBaseSpec: graphBaseSpec,
            unifiedGraphIneligibility: graphIneligibility,
            unifiedGraphRequired: (unifiedGraphEnabled && stagedAudioUnitRack == nil) || longResponse
        )
        programs.clearAll()
        transport.setBinauralHeadphoneSession(session)

        if let tracking = profile.headTracking, tracking.enabled {
            let controller = SpatialHeadTrackingController(
                configuration: tracking,
                asset: asset,
                layout: profile.programLayout,
                session: session
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.transport.setHeadTrackingRuntimeStatus(status)
                }
            }
            transport.setHeadTrackingController(controller)
            try controller.start()
        } else {
            transport.setHeadTrackingController(nil)
            transport.setHeadTrackingRuntimeStatus(.disabled)
        }
    }

    func buildStereoTransport(output: AudioOutputDevice) throws {
        var headphoneSnapshot: N60HeadphoneDSPSnapshot?
        if let headphone = headphoneDeviceProfileConfiguration, headphone.enabled {
            _ = try headphone.validateForActivation(
                availableDevices: outputDevices,
                selectedOutputUID: output.uid,
                sampleRate: output.nominalSampleRate
            )
            guard headphone.spatialMode == .stereo else {
                throw HeadphoneDeviceProfileError.binauralRuntimeUnavailable
            }
            guard multiOutputRoutingConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
            guard outputDeviceProfileConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            guard speakerDriverProcessingConfiguration.isNeutral else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("per-driver speaker processing")
            }
            guard !bassManagementConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker bass management")
            }
            guard !roomCorrectionConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker room correction")
            }
            guard !speakerIRConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("Speaker IR")
            }
            headphoneSnapshot = try headphone.makeRealtimeSnapshot(sampleRate: output.nominalSampleRate)
        }

        let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?
        let aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan?
        if let routing = multiOutputRoutingConfiguration, routing.enabled {
            if routing.usesMultiplePhysicalDevices {
                let plan = try routing.makeAggregateDevicePlan(
                    availableDevices: outputDevices,
                    sampleRate: output.nominalSampleRate
                )
                try plan.validateForC3LiveTransport(selectedOutputUID: output.uid)
                aggregateDeviceOutputPlan = plan
                sameDeviceOutputPlan = nil
            } else {
                let plan = try routing.makeSameDevicePlan(
                    availableDevices: outputDevices,
                    sampleRate: output.nominalSampleRate
                )
                try plan.validateForC2bLiveTransport(selectedOutputUID: output.uid)
                sameDeviceOutputPlan = plan
                aggregateDeviceOutputPlan = nil
            }
        } else {
            sameDeviceOutputPlan = nil
            aggregateDeviceOutputPlan = nil
        }
        let speakerCrossoverMode: SpeakerCrossoverMode?
        let speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot?
        if physicalSpeakerBusRoutingActive {
            speakerCrossoverMode = bassManagementConfiguration.physicalOutputMode
            speakerBusSplitterSnapshot = try bassManagementConfiguration.makeSpeakerBusSplitterSnapshot(
                sampleRate: output.nominalSampleRate
            )
        } else {
            speakerCrossoverMode = nil
            speakerBusSplitterSnapshot = nil
        }
        if let plan = sameDeviceOutputPlan {
            try plan.validateForC4LiveTransport(
                selectedOutputUID: output.uid,
                crossoverMode: speakerCrossoverMode
            )
        }
        if let plan = aggregateDeviceOutputPlan {
            try plan.validateForC4LiveTransport(
                selectedOutputUID: output.uid,
                crossoverMode: speakerCrossoverMode
            )
        }
        let speakerDriverProcessingSnapshot = try speakerDriverProcessingConfiguration
            .makeRealtimeSnapshot(sampleRate: output.nominalSampleRate)
        var foldSource: AudioOutputDevice?
        var foldPlan: ProgramFoldDownPlan?
        transport.setFoldMatrixInUse(nil)
        switch programFoldBuildDecision(for: output) {
        case .standard: break
        case .tapSource(let device):
            if let reason = ProgramFoldDownPlan.incompatibility(
                sameDeviceOrAggregateOutput: sameDeviceOutputPlan != nil || aggregateDeviceOutputPlan != nil,
                headphoneProfileEnabled: headphoneSnapshot != nil) {
                throw CoreAudioTransportError.programFoldFailed(reason)
            }
            foldSource = device
            foldPlan = programFoldPlan
            transport.setFoldMatrixInUse(programFoldPlan?.matrix)
        case .waitForSource(let uid): throw CoreAudioTransportError.programFoldFailed(.sourceUnavailable(uid: uid))
        case .refuse(let reason): throw CoreAudioTransportError.programFoldFailed(reason)
        }
        let session = try CoreAudioTransportSession(
            selectedOutput: output,
            sameDeviceOutputPlan: sameDeviceOutputPlan,
            aggregateDeviceOutputPlan: aggregateDeviceOutputPlan,
            speakerCrossoverMode: speakerCrossoverMode,
            speakerBusSplitterSnapshot: speakerBusSplitterSnapshot,
            speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot,
            audioUnitRack: stagedAudioUnitRack,
            programSource: foldSource,
            programFoldPlan: foldPlan
        )
        session.unifiedGraphEnabled = unifiedGraphEnabled
        // E6 S12h part 2b: a plain stereo speaker session renders the Quiet Zone on the unified graph (the ANC lane feed
        // as its EXTERNAL stage). Decided here, before the first graph is built, and never changed for the session.
        // Authorisation is unchanged: only a snapshot carrying `activeQuietZone.enabled` (an armed target) arms the feed.
        session.hostsQuietZoneFeedRequested = unifiedGraphEnabled && FeatureFlags().isEnabled(.subAwareAnc)
            && headphoneSnapshot == nil && foldSource == nil
            && headphoneDeviceProfileConfiguration?.enabled != true
            && outputDeviceProfileConfiguration?.enabled != true
            && multiOutputRoutingConfiguration?.enabled != true
        session.setInitialStereoAlignment(stereoAlignment)
        session.setDynamicsExtras(DynamicsGraphExtras.make(
            dynamicsConfiguration, sampleRate: session.outputFormat.sampleRate, flagOn: FeatureFlags().isEnabled(.dynamicsExtras)))
        session.setInitialAnalyserTaps(installed: analyserTapsInstalled)
        try session.configureHeadphoneDSP(
            headphoneSnapshot, profile: headphoneSnapshot == nil ? nil : headphoneDeviceProfileConfiguration)
        programs.resetForNewSession()
        eqFIRCache.removeAll()
        var graph = try stereoTransportStartGraph(sampleRate: session.outputFormat.sampleRate)

        if FIRUpdatePolicy.shouldPrepareEQFIR(
            stereoEQ: renderStereoEQConfiguration,
            playback: playbackControlConfiguration
        ) {
            let preparedProgram = try prepareEQFIRProgram(renderStereoEQConfiguration, for: session)
            programs.setActiveEQFIRProgram(preparedProgram)
            programs.setLinearPhaseDesignInfo(preparedProgram.designInfo)
            try attachEQFIRProgram(preparedProgram, to: &graph)
        } else {
            programs.setLinearPhaseDesignInfo(nil)
        }

        programs.setRoomCorrectionInactiveReason(roomCorrectionConfiguration.enabled && roomCorrectionConfiguration.lanes != nil
            ? .needsSpeakerProfile : nil)
        if roomCorrectionConfiguration.isActiveOnStereoKernel {
            guard let filter = roomCorrectionConfiguration.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareRoomCorrection(
                roomCorrection: roomCorrectionConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                programs.setActiveRoomCorrectionProgram(preparedProgram)
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
            }
        }

        if speakerIRConfiguration.enabled {
            guard let filter = speakerIRConfiguration.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareSpeakerIR(
                speakerIR: speakerIRConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                programs.setActiveSpeakerIRProgram(preparedProgram)
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
            }
        }

        try applyAudioUnitRackLatency(to: &graph)
        session.feedForwardLiveFeatureEnabled = speakerDriveFeatureEnabled
        try session.publishDSPGraph(graph)
        transport.setSession(session)
        speakerDrive.resetAnchorFanout()
        applySpeakerDriveDemand()
    }

    /// Base graph for a newly built stereo transport (start, rate change,
    /// recovery, wake). It must carry the current software master gain and
    /// mute; the realtime kernel otherwise starts at unity until the next
    /// volume change republishes the graph.
    func stereoTransportStartGraph(sampleRate: Double) throws -> N60DSPGraphSnapshot {
        try renderStereoEQConfiguration.makeGraphSnapshot(
            sampleRate: sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: renderBassManagementConfiguration(),
            dynamicsConfiguration: renderDynamicsConfiguration(),
            playbackConfiguration: playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
    }

    func tearDownTransport(fadeOut: Bool, cause: TransportTeardownCause = .other) {
        liveGenerator = nil
        transport.setFoldMatrixInUse(nil)
        auditionOverride = nil
        // E27 S3b: an audition never outlives the transport. The stored EQ is untouched.
        if eqAudition != nil { commitEQAudition(nil) }
        // E28 S7d (G36): the graph dies with the transport, and so does listening and solo (Stop, output change, Quit).
        commitDynamicsListener(nil)
        commitDynamicsSoloBands([])
        if let controller = headTrackingController {
            controller.stop()
            transport.setHeadTrackingController(nil)
        }
        if headphoneDeviceProfileConfiguration?.enabled == true,
           headphoneDeviceProfileConfiguration?.spatialMode == .virtualSpeakers,
           headphoneDeviceProfileConfiguration?.headTracking?.enabled == true {
            transport.setHeadTrackingRuntimeStatus(.configuredStopped)
        } else {
            transport.setHeadTrackingRuntimeStatus(.disabled)
        }

        if let session = transportSession {
            let counters = session.counters()
            transport.archive(counters)
            // E4 S25 follow-up: the reference ring dies with the session; the pump must not outlive it.
            feedForwardLiveDriver.stop()
            speakerDrive.resetAnchorFanout()
            session.stop(fadeOut: fadeOut)
            transport.setSession(nil)
        }
        if let session = nChannelTransportSession {
            let counters = session.counters()
            transport.archive(counters)
            // The reference ring dies with the session; the live pump must not outlive it.
            if session.hostsQuietZone {
                feedForwardLiveDriver.stop()
                speakerDrive.resetAnchorFanout()
            }
            session.stop(fadeOut: fadeOut)
            nChannelTransportSession = nil
        }
        if let session = binauralHeadphoneTransportSession {
            let counters = session.counters()
            transport.archive(counters)
            session.stop(fadeOut: fadeOut)
            transport.setBinauralHeadphoneSession(nil)
        }
        programs.clearActivePrograms()
        // E4 S30c: a transport rebuild clears the unmasking cuts (the session that held them is gone).
        var ambientTarget = ambientCompensationRuntimeTarget
        ambientTarget.unmaskingCutsDB = nil
        commitAmbientCompensationRuntimeTarget(ambientTarget)
        syncActiveQuietZoneLease(active: false)
        // The app's own profile switch happens while arming and keeps the arm (see `disarmReason`).
        if cause != .plannedProfileChange { transport.advanceLiveTreatmentGeneration() }
        notifyTransportTeardown(cause)
    }

    func forceFailedState(_ error: Error) {
        setLastError(error.localizedDescription)
        if AudioLifecycleStateMachine.canTransition(from: lifecycle.state, to: .failed) {
            try? lifecycle.transition(to: .failed)
            mirrorLifecycleState()
        }
    }

    func handleDeviceListChanged() {
        do { try refreshOutputDevices() } catch { return }
        guard let selectedUID = routeConfiguration.selectedOutputUID else { return }
        let selectedIsPresent = outputDevices.contains { $0.uid == selectedUID }
        let spatialSourceUID = headphoneDeviceProfileConfiguration?.spatialMode == .virtualSpeakers
            ? (headphoneDeviceProfileConfiguration?.programSourceDeviceUID ?? selectedUID)
            : selectedUID
        let foldSourceIsPresent = programFoldPlan.map { plan in plan.foldDown.usesDriverSource || outputDevices.contains { $0.uid == plan.sourceUID } } ?? true
        let spatialSourceIsPresent = foldSourceIsPresent && outputDevices.contains { $0.uid == spatialSourceUID }

        if !selectedIsPresent {
            masterVolumeController.stopMonitoring()
            masterVolume.setCapabilities(.softwareOnly)
        } else {
            try? syncMasterVolumeMonitorToSelectedOutput()
        }

        if (!selectedIsPresent || !spatialSourceIsPresent)
            && (lifecycle.state == .running || lifecycle.state == .reconfiguring) {
            beginOutputRecovery()
            return
        }

        // Fast-path only while waiting for an absent output. After a failed build
        // the backoff schedule owns retries; our own tap/aggregate teardown also
        // posts device-list changes and must not turn backoff into a tight loop.
        if selectedIsPresent,
           lifecycle.state == .recoveringOutput,
           recoveryConsecutiveBuildFailures == 0 {
            scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
        }
    }
}
