import CoreAudio
import Foundation

// E23 S4 part 3: EQ, playback-control and gain setters, content/headroom transitions and output/headphone profile replacement, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func addEQBand(_ band: EQBand = EQBand()) throws {
        guard stereoEQConfiguration.editableBands.count < EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(stereoEQConfiguration.editableBands.count + 1)
        }
        var updated = stereoEQConfiguration
        var bands = updated.editableBands
        bands.append(band)
        updated.replaceEditableBands(bands)
        try applyStereoEQConfiguration(updated)
    }

    func updateEQBand(_ band: EQBand) throws {
        var updated = stereoEQConfiguration
        guard updated.editableBands.contains(where: { $0.id == band.id }) else { return }
        updated.updateEditableBand(band)
        try applyStereoEQConfiguration(updated)
    }

    func removeEQBand(id: UUID) throws {
        var updated = stereoEQConfiguration
        updated.removeEditableBand(id: id)
        try applyStereoEQConfiguration(updated)
    }

    func setEQBypassed(_ bypassed: Bool) throws {
        var updated = stereoEQConfiguration
        updated.bypassed = bypassed
        try applyStereoEQConfiguration(updated)
    }

    func setEQPhaseMode(_ mode: EQPhaseMode) throws {
        guard mode != stereoEQConfiguration.phaseMode else { return }
        var updated = stereoEQConfiguration
        updated.phaseMode = mode
        try applyStereoEQConfiguration(updated)
    }

    func setEQChannelMode(_ mode: EQChannelMode) throws {
        var updated = stereoEQConfiguration
        updated.setChannelMode(mode)
        try applyStereoEQConfiguration(updated)
    }

    func setEQEditChannel(_ channel: EQEditChannel) {
        var updated = stereoEQConfiguration
        updated.setEditChannel(channel)
        commitStereoEQConfiguration(updated)
        commitEQConfiguration(legacyEQConfiguration(from: updated))
        setLastError(nil)
    }

    func replaceStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {
        try applyStereoEQConfiguration(configuration)
    }

    /// E27 S3b: starts, moves or ends the Listen audition. The stored EQ is untouched; the
    /// rendered EQ becomes one unity-peak band-pass (minimum phase) and returns on `nil`.
    /// Control thread only; it publishes through the normal EQ snapshot path.
    func setEQAudition(_ override: EQAuditionOverride?) throws {
        guard override != eqAudition else { return }
        let previous = eqAudition
        commitEQAudition(override)
        do {
            try applyStereoEQConfiguration(stereoEQConfiguration, forceRepublish: true)
        } catch {
            commitEQAudition(previous)
            throw error
        }
    }

    func replaceEQConfiguration(_ configuration: EQConfiguration) throws {
        var updated = stereoEQConfiguration
        updated.phaseMode = configuration.phaseMode
        updated.bypassed = configuration.bypassed
        updated.replaceEditableBands(configuration.bands)
        try applyStereoEQConfiguration(updated)
    }

    func replacePlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        try applyPlaybackControlConfiguration(configuration)
    }

    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkCancellationAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkHeadShadowFrequency(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkHeadShadowFrequencyHz = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.speakerCrossfeedRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(value)
        }
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalanceEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.symmetryBalanceEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalancePosition(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.symmetryBalanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSymmetryBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.symmetryBalancePosition = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setChannelBalance(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.balanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.balance = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setInterChannelDelayMs(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.interChannelDelayRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(value)
        }
        var updated = playbackControlConfiguration
        updated.interChannelDelayMs = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setGlobalDSPBypassed(_ bypassed: Bool) throws {
        var updated = playbackControlConfiguration
        updated.globalBypassed = bypassed
        try applyPlaybackControlConfiguration(updated)
    }

    func setFlatAuditionEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.auditionMode = enabled ? .reference : .processed
        try applyPlaybackControlConfiguration(updated)
    }

    func setAuditionMode(_ mode: AuditionMode) throws {
        if mode == .delta, !deltaAuditionAvailable {
            throw LiveNChannelTransportError.routingRefused("the delta audition is not available with speaker routing or Virtual Speakers; switch to Processed or Reference.")
        }
        var updated = playbackControlConfiguration
        updated.auditionMode = mode
        try applyPlaybackControlConfiguration(updated)
    }

    func setSoftwareVolumeKeyStep(_ step: MasterVolumeKeyStep) {
        guard step.isValid else { return }
        masterVolume.setSoftwareVolumeKeyStep(step)
    }

    func setMasterVolumeLevel(_ level: Double) throws {
        guard level.isFinite, MasterVolumeConfiguration.levelRange.contains(level) else {
            throw MasterVolumeConfigurationError.invalidLevel(level)
        }
        var updated = masterVolumeConfiguration
        updated.level = level
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func setMasterMuted(_ muted: Bool) throws {
        var updated = masterVolumeConfiguration
        updated.muted = muted
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func replaceGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        try applyGainConfiguration(configuration)
    }

    /// Applies the PR113B A/B-safe content domain as one complete graph
    /// transition. Playback-System state, output routing, room/speaker
    /// correction, master/output gain and Audio Unit topology remain owned by
    /// their existing domains and are only reattached to the candidate graph.
    ///
    /// The extra attenuation is intentionally non-positive and exists only for
    /// measured A/B level matching. It is not written back into the captured
    /// snapshot.
    func transitionContentAuditionState(
        _ state: ContentABAuditionState,
        additionalInputAttenuationDB: Double = 0,
        forceRepublish: Bool = false
    ) throws {
        guard additionalInputAttenuationDB.isFinite,
              (-24.0...0.0).contains(additionalInputAttenuationDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                state.inputPreampDB + additionalInputAttenuationDB
            )
        }

        try validateStereoEQStorage(state.stereoEQ)

        var targetGain = gainConfiguration
        targetGain.inputPreampDB = min(
            max(
                state.inputPreampDB + additionalInputAttenuationDB,
                DSPGainConfiguration.inputPreampRange.lowerBound
            ),
            DSPGainConfiguration.inputPreampRange.upperBound
        )
        targetGain.headroomAttenuationDB = state.headroomAttenuationDB

        guard DSPGainConfiguration.inputPreampRange
                .contains(targetGain.inputPreampDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                targetGain.inputPreampDB
            )
        }
        guard DSPGainConfiguration.headroomAttenuationRange
                .contains(targetGain.headroomAttenuationDB) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(
                targetGain.headroomAttenuationDB
            )
        }

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: targetGain
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: targetGain,
                ambientTarget: clampedAmbientTarget
            )

        // E9 S5b: the graph builders read the output-protection policy; whatever happens, leave it matching the stored settings.
        UnifiedGraphOutputProtection.apply(settings: state.dynamics.outputProtection ?? OutputProtectionSettings())
        defer { UnifiedGraphOutputProtection.apply(settings: dynamicsConfiguration.outputProtection ?? OutputProtectionSettings()) }
        if immutableSemanticTransportActive {
            if forceRepublish
                || state.stereoEQ != stereoEQConfiguration
                || state.dynamics != dynamicsConfiguration
                || targetGain != gainConfiguration
                || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.stereoEQ = state.stereoEQ
                inputs.dynamics = state.dynamics
                inputs.gain = targetGain
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            // E28 S8: a profile switch changes the dynamics, so the stereo session's extras follow it (put back if refused).
            let previousExtras = session.dynamicsExtras
            session.setDynamicsExtras(DynamicsGraphExtras.make(
                state.dynamics, sampleRate: session.outputFormat.sampleRate, flagOn: FeatureFlags().isEnabled(.dynamicsExtras)))
            var extrasAdopted = false
            defer { if !extrasAdopted { session.setDynamicsExtras(previousExtras) } }
            var graph = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics.mergingFoldProtection(foldMatrixInUse),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            var preparedEQFIRProgram: PreparedEQFIRProgram?
            if !processingIsBypassed(playbackControlConfiguration),
               state.stereoEQ.requiresEQFIRProgram,
               !state.stereoEQ.bypassed {
                let prepared =
                    try prepareEQFIRProgram(state.stereoEQ, for: session)
                try attachEQFIRProgram(prepared, to: &graph)
                preparedEQFIRProgram = prepared
            }

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

            // Always use the sample-domain structural transition for A/B.
            // Even when only biquad/gain values differ this avoids an
            // instantaneous coefficient/gain discontinuity at the output.
            try session.transitionDSPGraph(graph)
            extrasAdopted = true
            programs.setActiveEQFIRProgram(preparedEQFIRProgram)
            programs.setLinearPhaseDesignInfo(preparedEQFIRProgram?.designInfo)
        } else {
            // Validate the complete target graph while idle even though there
            // is no transport to publish it to yet.
            let validationRate =
                selectedOutputDevice?.nominalSampleRate ?? 48_000
            _ = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: validationRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics.mergingFoldProtection(foldMatrixInUse),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            programs.setActiveEQFIRProgram(nil)
            programs.setLinearPhaseDesignInfo(nil)
        }

        commitStereoEQConfiguration(state.stereoEQ)
        commitEQConfiguration(legacyEQConfiguration(from: state.stereoEQ))
        commitDynamicsConfiguration(state.dynamics)
        clearDynamicsListening()  // E28 S7d (G36): a profile switch ends listening and solo
        commitGainConfiguration(targetGain)
        commitAmbientCompensationRuntimeTarget(clampedAmbientTarget)
        commitActiveQuietZoneRuntimeTarget(candidateQuietZone)
        setLastError(nil)
    }

    func setInputPreampDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.inputPreampRange.contains(value) else {
            throw DSPGainConfigurationError.invalidInputPreamp(value)
        }
        var updated = gainConfiguration
        updated.inputPreampDB = value
        try applyGainConfiguration(updated)
    }

    /// Applies a Headroom Assistant recommendation through the same
    /// sample-domain silent-boundary transition used for other click-sensitive
    /// structural graph changes. This changes only the existing headroom gain;
    /// it does not save/overwrite the selected Content Preset.
    func transitionHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite,
              DSPGainConfiguration.headroomAttenuationRange
                .contains(value) else {
            throw DSPGainConfigurationError
                .invalidHeadroomAttenuation(value)
        }

        var updated = gainConfiguration
        updated.headroomAttenuationDB = value

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: updated
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: updated,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive {
            if updated != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.gain = updated
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            var graph = try renderStereoEQConfiguration
                .makeGraphSnapshot(
                    sampleRate:
                        session.outputFormat.sampleRate,
                    gainConfiguration: updated,
                    bassManagementConfiguration:
                        renderBassManagementConfiguration(),
                    dynamicsConfiguration:
                        dynamicsConfiguration,
                    playbackConfiguration:
                        playbackControlConfiguration,
                    masterGainLinear:
                        currentMasterSoftwareGain
                )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration:
                    renderStereoEQConfiguration,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
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
            try session.transitionDSPGraph(graph)
        }

        commitGainConfiguration(updated)
        commitAmbientCompensationRuntimeTarget(clampedAmbientTarget)
        commitActiveQuietZoneRuntimeTarget(candidateQuietZone)
        setLastError(nil)
    }

    func setHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.headroomAttenuationRange.contains(value) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(value)
        }
        var updated = gainConfiguration
        updated.headroomAttenuationDB = value
        try applyGainConfiguration(updated)
    }

    func setOutputGainDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.outputGainRange.contains(value) else {
            throw DSPGainConfigurationError.invalidOutputGain(value)
        }
        var updated = gainConfiguration
        updated.outputGainDB = value
        try applyGainConfiguration(updated)
    }

    func replaceMultiOutputRoutingConfiguration(
        _ configuration: MultiOutputRoutingConfiguration?
    ) throws {
        if let configuration {
            try configuration.validateStructure()
        }
        if configuration?.enabled == true, outputDeviceProfileConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if configuration?.enabled == true, headphoneDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
        }
        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {
            throw MultiOutputRoutingError.routingChangeRequiresIdle
        }
        commitMultiOutputRoutingConfiguration(configuration)
        setLastError(nil)
    }

    func replaceOutputDeviceProfileConfiguration(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        if configuration?.enabled == true {
            try configuration?.validateStructure(
                bassManagementEnabled: bassManagementConfiguration.enabled
            )
            if multiOutputRoutingConfiguration?.enabled == true {
                throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if headphoneDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
        }
        guard lifecycle.state == .idle || configuration == outputDeviceProfileConfiguration else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        commitOutputDeviceProfileConfiguration(configuration)
        setLastError(nil)
    }

    func replaceHeadphoneDeviceProfileConfiguration(
        _ configuration: HeadphoneDeviceProfileConfiguration?
    ) throws {
        if let configuration, configuration.enabled {
            if outputDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            if multiOutputRoutingConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if !speakerDriverProcessingConfiguration.isNeutral {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("per-driver speaker processing")
            }
            if bassManagementConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker bass management")
            }
            if roomCorrectionConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker room correction")
            }
            if speakerIRConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("Speaker IR")
            }
            if let output = selectedOutputDevice {
                try configuration.validateStructure(sampleRate: output.nominalSampleRate)
            }
        }
        if lifecycle.state != .idle {
            let context = HeadphoneLiveEditPlanner.Context(
                unifiedGraphEnabled: unifiedGraphEnabled,
                lifecycleRunning: lifecycle.state == .running,
                binauralSession: binauralHeadphoneTransportSession.map { $0.unifiedGraphActive ? .graph : .legacy } ?? .none,
                nChannelSessionActive: nChannelTransportSession != nil,
                stereoHeadphoneGraphActive: transportSession?.headphoneGraphActive == true)
            switch HeadphoneLiveEditPlanner.plan(from: headphoneDeviceProfileConfiguration, to: configuration, context: context) {
            case .unchanged: break
            case .refuse: throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
            case .liveEdit(let assetChanged):
                guard let configuration else { throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart }
                if transportSession?.headphoneGraphActive == true {
                    try applyLiveStereoHeadphoneEdit(configuration)
                } else {
                    try applyLiveHeadphoneEdit(configuration, assetChanged: assetChanged)
                }
                return
            case .reconfigure:
                try validateHeadphoneSessionKindChange(configuration)
                commitHeadphoneDeviceProfileConfiguration(configuration)
                setLastError(nil)
                scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, settleDelay: 0.03)
                return
            }
        }
        commitHeadphoneDeviceProfileConfiguration(configuration)
        if configuration?.enabled == true,
           configuration?.spatialMode == .virtualSpeakers,
           configuration?.headTracking?.enabled == true {
            transport.setHeadTrackingRuntimeStatus(.configuredStopped)
        } else {
            transport.setHeadTrackingRuntimeStatus(.disabled)
        }
        setLastError(nil)
    }

    /// E6 S9c: everything a session-kind change would need at the rebuild, checked before the change is committed so
    /// a refusal leaves the running session and the stored configuration alone.
    func validateHeadphoneSessionKindChange(_ configuration: HeadphoneDeviceProfileConfiguration?) throws {
        guard let configuration, configuration.enabled else { return }
        guard let output = selectedOutputDevice else {
            throw HeadphoneDeviceProfileError.outputDeviceRequired
        }
        let selected = try configuration.validateForActivation(
            availableDevices: outputDevices, selectedOutputUID: output.uid, sampleRate: output.nominalSampleRate)
        if configuration.spatialMode == .stereo {
            guard multiOutputRoutingConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
        }
        if configuration.spatialMode == .virtualSpeakers {
            let source = try configuration.resolveProgramSource(availableDevices: outputDevices, selectedOutput: selected)
            guard source.supports(sampleRate: output.nominalSampleRate) else {
                throw BinauralHeadphoneTransportError.sampleRateMismatch(
                    source: source.nominalSampleRate, output: output.nominalSampleRate)
            }
            try validateBinauralHeadphoneActivation()
        }
    }

    /// E25 S2: sets the stereo session's mono-bass filter and speaker feed calibration (from the compiled
    /// arrangement). Built dark: the arrangement wizard (S3) calls it.
    func applyStereoAlignment(_ alignment: StereoBassAlignment?) throws {
        if let session = transportSession {
            try session.applyStereoAlignment(alignment)
        } else if let alignment {
            if let issue = alignment.issue { throw issue }
            if !unifiedGraphEnabled, let refusal = alignment.legacyKernelRefusal { throw refusal }
        }
        commitStereoAlignment(alignment)
        setLastError(nil)
    }

    /// The stored dynamics with the fold's output limiter merged in while a wider source is folded (stricter of each
    /// setting; see `DynamicsConfiguration.mergingFoldProtection`).
    func renderDynamicsConfiguration() -> DynamicsConfiguration {
        dynamicsConfiguration.mergingFoldProtection(foldMatrixInUse)
    }

    /// E25 S8a: sets the wider program source and fold. The source is tapped and folded onto the two feeds inside the
    /// capture callback, so the change needs a new tap: a running stereo session is rebuilt through the planned-profile
    /// path (one short dropout). Called by the Speakers tab (S8b) behind.
    func applyProgramFoldDown(_ plan: ProgramFoldDownPlan?) throws {
        if plan != nil {
            if let reason = ProgramFoldDownPlan.incompatibility(
                sameDeviceOrAggregateOutput: multiOutputRoutingConfiguration?.enabled == true,
                headphoneProfileEnabled: headphoneDeviceProfileConfiguration?.enabled == true) {
                throw CoreAudioTransportError.programFoldFailed(reason)
            }
        }
        guard plan != programFoldPlan else { return }
        commitProgramFoldPlan(plan)
        setLastError(nil)
        if transportSession != nil {
            scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, cause: .plannedProfileChange)
        }
    }

    /// What `buildStereoTransport` does for this output given the configured fold and the devices present now.
    func programFoldBuildDecision(for output: AudioOutputDevice) -> ProgramFoldDownPlan.BuildDecision {
        ProgramFoldDownPlan.buildDecision(
            plan: programFoldPlan, availableDevices: outputDevices, sampleRate: output.nominalSampleRate, driverPathActive: DriverCaptureSelection.shared.current != nil)
    }

    /// E6 S9d: a headphone profile edit inside one graph-rendered stereo session. The session rebuilds the HEADPHONE
    /// and ear delay stages and republishes; stored state changes only after the graph accepted it.
    func applyLiveStereoHeadphoneEdit(_ configuration: HeadphoneDeviceProfileConfiguration) throws {
        guard let session = transportSession else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        try session.applyLiveHeadphoneProfile(configuration)
        commitHeadphoneDeviceProfileConfiguration(configuration)
        setLastError(nil)
    }

    /// E6 S9c: a headphone profile edit inside one graph-rendered binaural session. The channel correction (headroom,
    /// gain, polarity, EQ, delay) is laid onto the retained base spec and republished as a posted parameter or a
    /// faded rebuild; stored state changes only after the graph accepted it. A new HRTF asset is prepared off the main
    /// actor and published when ready, the old one rendering meanwhile.
    func applyLiveHeadphoneEdit(
        _ configuration: HeadphoneDeviceProfileConfiguration, assetChanged: Bool
    ) throws {
        guard let session = binauralHeadphoneTransportSession, let base = session.unifiedGraphBaseSpec else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        switch UnifiedGraphTranslator.binauralApplyHeadphone(base: base, profile: configuration) {
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        case .success(let newBase): try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
        }
        commitHeadphoneDeviceProfileConfiguration(configuration)
        setLastError(nil)
        if assetChanged { beginHeadphoneAssetSwap(session: session, profile: configuration) }
    }

    func beginHeadphoneAssetSwap(
        session: CoreAudioBinauralHeadphoneTransportSession, profile: HeadphoneDeviceProfileConfiguration
    ) {
        advanceHeadphoneAssetGeneration()
        let generation = headphoneAssetGeneration
        guard let reference = profile.binauralProfile else { return }
        let rate = session.outputFormat.sampleRate
        let store = binauralProfileAssetStore
        let cache = binauralAssetCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<UnifiedGraphSpec, Error>
            do {
                let asset = try cache.asset(for: reference, sampleRate: rate, store: store)
                switch UnifiedGraphTranslator.binauralBaseSpec(
                    asset: asset, layout: profile.programLayout, profile: profile, outputChannels: 2,
                    sampleRate: rate, headTracking: profile.headTracking?.enabled == true
                ) {
                case .success(let base): result = .success(base)
                case .failure(let reason): result = .failure(LiveNChannelTransportError.unifiedGraphRejected(reason))
                }
            } catch {
                result = .failure(error)
            }
            await self?.finishHeadphoneAssetSwap(
                generation: generation, reference: reference, session: session, result: result)
        }
    }

    func finishHeadphoneAssetSwap(
        generation: UInt64,
        reference: BinauralProfileReference,
        session: CoreAudioBinauralHeadphoneTransportSession,
        result: Result<UnifiedGraphSpec, Error>
    ) {
        guard generation == headphoneAssetGeneration,
              binauralHeadphoneTransportSession === session,
              lifecycle.state == .running,
              let profile = headphoneDeviceProfileConfiguration,
              profile.binauralProfile == reference else { return }
        do {
            // Edits made while the asset prepared are already in the configuration: lay them onto the new set.
            let prepared = try result.get()
            let newBase: UnifiedGraphSpec
            switch UnifiedGraphTranslator.binauralApplyHeadphone(base: prepared, profile: profile) {
            case .success(let base): newBase = base
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
            try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
            transport.setRenderedBinauralProfile(reference)
            setLastError(nil)
        } catch {
            setLastError(error.localizedDescription)
            if var restored = headphoneDeviceProfileConfiguration, let rendered = renderedBinauralProfile {
                restored.binauralProfile = rendered
                commitHeadphoneDeviceProfileConfiguration(restored)
            }
        }
    }
}
