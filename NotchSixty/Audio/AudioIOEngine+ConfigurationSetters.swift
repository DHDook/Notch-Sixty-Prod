import CoreAudio
import Foundation

// E23 S4 part 3: head tracking, bass management, mains hum, spectral denoiser, output protection, dynamics, room correction and speaker IR setters, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func recenterHeadTracking() {
        headTrackingController?.recenter()
    }

    func importNormalizedBinauralProfile(from url: URL) throws -> BinauralProfileReference {
        let reference = try binauralProfileAssetStore.importNormalizedDocument(from: url)
        setLastError(nil)
        return reference
    }

    func replaceSpeakerDriverProcessingConfiguration(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        try configuration.validateStructure()
        guard lifecycle.state == .idle || configuration == speakerDriverProcessingConfiguration else {
            throw SpeakerDriverProcessingError.changesRequireIdle
        }
        commitSpeakerDriverProcessingConfiguration(configuration)
        setLastError(nil)
    }

    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {
        guard configuration.frequencyHz.isFinite,
              configuration.lowerFrequencyRange.contains(configuration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(configuration.frequencyHz)
        }
        guard configuration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(configuration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(configuration.subGainDB)
        }
        guard configuration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(configuration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                configuration.subPhaseAlignmentFrequencyHz
            )
        }
        guard configuration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)
        }
        if configuration.physicalOutputMode == .triAmp {
            let upper = configuration.upperFrequencyHz ?? .nan
            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),
                  upper > configuration.frequencyHz else {
                throw BassManagementConfigurationError.invalidUpperFrequency(upper)
            }
        }
        if let outputDeviceProfile = outputDeviceProfileConfiguration, outputDeviceProfile.enabled {
            try outputDeviceProfile.validateStructure(bassManagementEnabled: configuration.enabled)
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration {
            // The crossover topology is fixed when the session starts, so toggling bass management restarts.
            // Retuning an enabled N-channel crossover republishes the graph. A graph-rendered binaural
            // session has no bass stage in the graph, so with `enabled` unchanged its bass edits are live
            // state commits. A legacy binaural session still needs a restart for any change.
            let binauralGraphLive = binauralHeadphoneTransportSession?.unifiedGraphActive == true
            if (binauralHeadphoneTransportSession != nil && !binauralGraphLive)
                || configuration.enabled != bassManagementConfiguration.enabled {
                throw LiveNChannelTransportError.configurationChangeRequiresRestart
            }
        }
        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {
            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration,
           binauralHeadphoneTransportSession == nil {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.bass = configuration
            try republishLiveGraph(inputs)
        }
        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(configuration),
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
            try session.publishDSPGraph(graph)
        }
        commitBassManagementConfiguration(configuration)
        setLastError(nil)
    }

    @discardableResult
    func applyDetectedMainsHum(minimumConfidence: Float = 0.55) throws -> Bool {
        guard let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectedFrequencyHz.isFinite,
              diagnostics.mainsDetectionConfidence >= minimumConfidence,
              MainsNotchConfiguration.detectedFrequencyRange.contains(Double(diagnostics.mainsDetectedFrequencyHz)) else {
            return false
        }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = Double(diagnostics.mainsDetectedFrequencyHz)
        try replaceDynamicsConfiguration(updated)
        return true
    }

    func detectMainsHumOnce(minimumConfidence: Float = 0.55) async throws -> Bool {
        guard lifecycle.state == .running else { return false }
        let trackingWasEnabled = dynamicsConfiguration.mainsNotch.continuousTracking
        if !trackingWasEnabled {
            var detecting = dynamicsConfiguration
            detecting.mainsNotch.continuousTracking = true
            try replaceDynamicsConfiguration(detecting)
        }
        defer {
            if !trackingWasEnabled {
                var restored = dynamicsConfiguration
                restored.mainsNotch.continuousTracking = false
                try? replaceDynamicsConfiguration(restored)
            }
        }
        try await Task.sleep(nanoseconds: 1_150_000_000)
        return try applyDetectedMainsHum(minimumConfidence: minimumConfidence)
    }

    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {
        guard dynamicsConfiguration.mainsNotch.continuousTracking,
              let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectionConfidence >= minimumConfidence else { return }
        let detected = Double(diagnostics.mainsDetectedFrequencyHz)
        guard detected.isFinite,
              MainsNotchConfiguration.detectedFrequencyRange.contains(detected),
              abs(detected - dynamicsConfiguration.mainsNotch.fundamentalHz) >= 0.03 else { return }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = detected
        try? replaceDynamicsConfiguration(updated)
    }

    func applySpectralDenoiserPreset(_ preset: SpectralDenoiserPreset) throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.applyPreset(preset)
        try replaceDynamicsConfiguration(updated)
    }

    func captureSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.requestProfileCapture()
        try replaceDynamicsConfiguration(updated)
    }

    func resetSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.resetProfile()
        try replaceDynamicsConfiguration(updated)
    }

    /// E9 S5b: one output the Protection card's Outputs list can show.
    struct OutputProtectionLane: Equatable, Identifiable, Sendable {
        let index: Int
        let label: String
        let isSub: Bool
        var id: Int { index }
    }

    /// E9 S5b: the outputs that have user protection of their own under `e9.output-protection`: the program lanes (one linked
    /// group unless "Independent per output" is on) then each subwoofer lane. Empty when the flag is off, or for a routed or
    /// binaural session (those keep their own stages; E9 S5c). A stereo session shows its two lanes.
    var outputProtectionLanes: [OutputProtectionLane] {
        guard UnifiedGraphOutputProtection.current() != nil else { return [] }
        if let session = nChannelTransportSession {
            guard !session.routePlan.isRouted else { return [] }
            var lanes = session.routePlan.programLayout.roles.enumerated().map {
                OutputProtectionLane(index: $0.offset, label: $0.element.displayName, isSub: false)
            }
            for sub in 0..<Int(session.routePlan.subwooferCount) {
                lanes.append(OutputProtectionLane(index: lanes.count, label: "Sub \(sub + 1)", isSub: true))
            }
            return lanes
        }
        if binauralHeadphoneTransportSession != nil { return [] }
        return [OutputProtectionLane(index: 0, label: "Left", isSub: false), OutputProtectionLane(index: 1, label: "Right", isSub: false)]
    }

    /// E9 S5b (G14): gain reduction and true peak per output since the last call (read-and-reset in the core). Empty when no
    /// graph renders or the flag is off. Only the Outputs list calls this, so no other reader loses its values.
    func outputProtectionReadings() -> [UnifiedGraphOutputProtectionReading] {
        let lanes = outputProtectionLanes.count
        guard lanes > 0,
              let host = transportSession?.unifiedGraphReadback ?? nChannelTransportSession?.unifiedGraphReadback else { return [] }
        return host.outputProtectionReadings(lanes: lanes)
    }

    /// E9 S7: the published graph spec of the running render, with the output lane count, for the headroom assistant. nil when
    /// no graph renders. Control plane (the host lock); the model itself runs off the main actor on the copy.
    func headroomSpecSnapshot() -> (spec: UnifiedGraphSpec, lanes: Int)? {
        let lanes = outputProtectionLanes.count
        guard lanes > 0,
              let host = transportSession?.unifiedGraphReadback ?? nChannelTransportSession?.unifiedGraphReadback else { return nil }
        return (host.currentSpec, lanes)
    }

    /// E28 S7d: the graph host of whichever session renders now (stereo, N-channel or binaural), for listen and solo.
    var dynamicsListenHost: UnifiedGraphHost? {
        transportSession?.unifiedGraphReadback
            ?? nChannelTransportSession?.unifiedGraphReadback
            ?? binauralHeadphoneTransportSession?.unifiedGraphReadback
    }

    func setDynamicsListenerMirror(_ listener: DynamicsListener?, solo: Set<Int>) {
        if dynamicsListener != listener { commitDynamicsListener(listener) }
        if dynamicsSoloBands != solo { commitDynamicsSoloBands(solo) }
    }

    func reportDynamicsListenError(_ message: String) { setLastError(message) }

    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {
        let validationRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
            ?? 48_000
        _ = try configuration.makeSnapshot(sampleRate: validationRate)
        let newProtection = try configuration.mergingFoldProtection(foldMatrixInUse).makeProtectionSnapshot(sampleRate: validationRate)
        // E9 S5b: the graph builders read the output-protection policy from here, so it is set before they run and put back if
        // the edit is refused (the running graph and the stored configuration then stay as they were).
        let previousOutputProtection = UnifiedGraphOutputProtection.apply(settings: configuration.outputProtection ?? OutputProtectionSettings())
        // Main-actor only: the policy static is written from here, the dynamicsConfiguration didSet and state restore.
        var committed = false
        // The stereo session's extras are restored on any throw before the edit is stored, whatever `committed` says.
        var extrasStored = false
        let previousStereoExtras = transportSession?.dynamicsExtras
        defer {
            if !extrasStored { transportSession?.setDynamicsExtras(previousStereoExtras) }
            if !committed { UnifiedGraphOutputProtection.apply(settings: previousOutputProtection) }
        }
        // E28 S7d part 3 (G34): a lookahead-only edit crossfades two copies of one signal, so it uses the linear law.
        let lookaheadOnly = FeatureFlags().isEnabled(.dynamicsExtras) && configuration.differsOnlyInLookahead(from: dynamicsConfiguration)
        let previousStereoFade = transportSession?.linearFadeForEQRepublish ?? false
        let previousNChannelFade = nChannelTransportSession?.linearFadeForEQRepublish ?? false
        if lookaheadOnly {
            transportSession?.linearFadeForEQRepublish = true
            nChannelTransportSession?.linearFadeForEQRepublish = true
        }
        defer {
            if lookaheadOnly {
                transportSession?.linearFadeForEQRepublish = previousStereoFade
                nChannelTransportSession?.linearFadeForEQRepublish = previousNChannelFade
            }
        }
        if immutableSemanticTransportActive, configuration != dynamicsConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.dynamics = configuration
            try republishLiveGraph(inputs)
            // The live graph now carries the new policy; keep it even if a later step throws.
            committed = true
        }
        if let session = transportSession {
            // E28 S8: the stereo graph is built with the new configuration's extras (the stored one is replaced below).
            session.setDynamicsExtras(DynamicsGraphExtras.make(
                configuration, sampleRate: session.outputFormat.sampleRate, flagOn: FeatureFlags().isEnabled(.dynamicsExtras)))
            let oldProtection = try renderDynamicsConfiguration().makeProtectionSnapshot(sampleRate: session.outputFormat.sampleRate)
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: configuration.mergingFoldProtection(foldMatrixInUse),
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
            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames
                || oldProtection.effectiveFactor != newProtection.effectiveFactor
                || oldProtection.limiterEnabled != newProtection.limiterEnabled
                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled
                || (dynamicsConfiguration.outputProtection?.independent ?? false) != (configuration.outputProtection?.independent ?? false)
            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || (configuration.spectralDenoiser.enabled
                    && dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality)
            if protectionStructureChanged || denoiserStructureChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
                try session.publishDSPGraph(graph)
            }
        }
        commitDynamicsConfiguration(configuration)
        extrasStored = true
        committed = true
        setLastError(nil)
        surfaceDynamicsListenRepostFailure()  // E28 S7d part 3 (G37): a rebuild that lost the listener is reported, not swallowed
    }

    func loadRoomCorrectionValidationFilter() throws {
        var updated = roomCorrectionConfiguration
        updated.filter = .validation
        try applyRoomCorrectionConfiguration(updated)
    }

    func setRoomCorrectionEnabled(_ enabled: Bool) throws {
        var updated = roomCorrectionConfiguration
        updated.enabled = enabled
        try applyRoomCorrectionConfiguration(updated)
    }

    func replaceRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        try applyRoomCorrectionConfiguration(configuration)
    }

    func loadSpeakerIRValidationFilter() throws {
        var updated = speakerIRConfiguration
        updated.filter = .validation
        try applySpeakerIRConfiguration(updated)
    }

    func setSpeakerIREnabled(_ enabled: Bool) throws {
        var updated = speakerIRConfiguration
        updated.enabled = enabled
        try applySpeakerIRConfiguration(updated)
    }

    func clearSpeakerIRFilter() throws {
        var updated = speakerIRConfiguration
        updated.enabled = false
        updated.filter = nil
        try applySpeakerIRConfiguration(updated)
    }

    func replaceSpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        try applySpeakerIRConfiguration(configuration)
    }
}
