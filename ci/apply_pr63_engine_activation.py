#!/usr/bin/env python3
"""One-shot asserted source transformer for PR63 live N-channel activation.

This helper is removed by the workflow commit after applying the patch. Every
replacement must match exactly once so the automation cannot silently edit a
shifted seam.
"""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
WORKFLOW = ROOT / ".github/workflows/pr63-apply-engine-activation.yml"
SELF = pathlib.Path(__file__)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"PR63 patch seam {label!r} matched {count} times, expected exactly 1")
    return text.replace(old, new, 1)


def patch_engine(text: str) -> str:
    text = replace_once(
        text,
        "    private var transportSession: CoreAudioTransportSession?\n",
        "    private var transportSession: CoreAudioTransportSession?\n"
        "    private var nChannelTransportSession: CoreAudioNChannelTransportSession?\n",
        "nchannel session storage",
    )
    text = replace_once(
        text,
        "    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?\n"
        "    @Published private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()\n",
        "    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?\n"
        "    @Published private(set) var outputDeviceProfileConfiguration: OutputDeviceProfileConfiguration?\n"
        "    @Published private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()\n",
        "published output device profile",
    )
    text = replace_once(
        text,
        "    var physicalSpeakerBusRoutingActive: Bool {\n"
        "        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }\n"
        "        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }\n"
        "    }\n",
        "    var physicalSpeakerBusRoutingActive: Bool {\n"
        "        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }\n"
        "        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }\n"
        "    }\n\n"
        "    var liveNChannelActive: Bool { nChannelTransportSession != nil }\n",
        "live mode state",
    )
    text = replace_once(
        text,
        "    func replaceMultiOutputRoutingConfiguration(\n"
        "        _ configuration: MultiOutputRoutingConfiguration?\n"
        "    ) throws {\n"
        "        if let configuration {\n"
        "            try configuration.validateStructure()\n"
        "        }\n"
        "        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {\n"
        "            throw MultiOutputRoutingError.routingChangeRequiresIdle\n"
        "        }\n"
        "        multiOutputRoutingConfiguration = configuration\n"
        "        lastErrorDescription = nil\n"
        "    }\n",
        "    func replaceMultiOutputRoutingConfiguration(\n"
        "        _ configuration: MultiOutputRoutingConfiguration?\n"
        "    ) throws {\n"
        "        if let configuration {\n"
        "            try configuration.validateStructure()\n"
        "        }\n"
        "        if configuration?.enabled == true, outputDeviceProfileConfiguration?.enabled == true {\n"
        "            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict\n"
        "        }\n"
        "        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {\n"
        "            throw MultiOutputRoutingError.routingChangeRequiresIdle\n"
        "        }\n"
        "        multiOutputRoutingConfiguration = configuration\n"
        "        lastErrorDescription = nil\n"
        "    }\n\n"
        "    func replaceOutputDeviceProfileConfiguration(\n"
        "        _ configuration: OutputDeviceProfileConfiguration?\n"
        "    ) throws {\n"
        "        if configuration?.enabled == true {\n"
        "            try configuration?.validateStructure(\n"
        "                bassManagementEnabled: bassManagementConfiguration.enabled\n"
        "            )\n"
        "            if multiOutputRoutingConfiguration?.enabled == true {\n"
        "                throw OutputDeviceProfileError.legacyPhysicalRoutingConflict\n"
        "            }\n"
        "        }\n"
        "        guard lifecycle.state == .idle || configuration == outputDeviceProfileConfiguration else {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        outputDeviceProfileConfiguration = configuration\n"
        "        lastErrorDescription = nil\n"
        "    }\n",
        "profile setter",
    )
    text = replace_once(
        text,
        "        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {\n"
        "            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle\n"
        "        }\n"
        "        if let session = transportSession {\n",
        "        if let outputDeviceProfile = outputDeviceProfileConfiguration, outputDeviceProfile.enabled {\n"
        "            try outputDeviceProfile.validateStructure(bassManagementEnabled: configuration.enabled)\n"
        "        }\n"
        "        if nChannelTransportSession != nil, configuration != bassManagementConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {\n"
        "            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle\n"
        "        }\n"
        "        if let session = transportSession {\n",
        "bass profile and restart guard",
    )
    text = replace_once(
        text,
        "    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {\n"
        "        let validationRate = transportSession?.outputFormat.sampleRate ?? 48_000\n",
        "    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {\n"
        "        if nChannelTransportSession != nil, configuration != dynamicsConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        let validationRate = transportSession?.outputFormat.sampleRate\n"
        "            ?? nChannelTransportSession?.outputFormat.sampleRate\n"
        "            ?? 48_000\n",
        "dynamics restart guard",
    )
    text = replace_once(
        text,
        "    func setDetailedMeteringDemand(_ enabled: Bool) throws {\n"
        "        let previousDemand = N60RealtimeAudioBridgeMeteringDemand()\n",
        "    func setDetailedMeteringDemand(_ enabled: Bool) throws {\n"
        "        guard nChannelTransportSession == nil else { return }\n"
        "        let previousDemand = N60RealtimeAudioBridgeMeteringDemand()\n",
        "stereo metering guard",
    )
    text = replace_once(
        text,
        "        let currentCounters = transportSession?.counters() ?? AudioTransportCounters()\n"
        "        let processingSessionCounters = processingSessionArchivedCounters + currentCounters\n"
        "        let lifetimeCounters = lifetimeArchivedCounters + currentCounters\n"
        "        return AudioDiagnosticsSnapshot(\n",
        "        let currentCounters = transportSession?.counters()\n"
        "            ?? nChannelTransportSession?.counters()\n"
        "            ?? AudioTransportCounters()\n"
        "        let processingSessionCounters = processingSessionArchivedCounters + currentCounters\n"
        "        let lifetimeCounters = lifetimeArchivedCounters + currentCounters\n"
        "        let activeTapSampleRate = transportSession?.tapFormat.sampleRate\n"
        "            ?? nChannelTransportSession?.tapFormat.sampleRate\n"
        "        let activeOutputSampleRate = transportSession?.outputFormat.sampleRate\n"
        "            ?? nChannelTransportSession?.outputFormat.sampleRate\n"
        "        let startupGateOpened = transportSession?.startupGateOpened\n"
        "            ?? nChannelTransportSession?.startupGateOpened\n"
        "        let startupGateTargetFrames = transportSession?.startupGateTargetFrames\n"
        "            ?? nChannelTransportSession?.startupGateTargetFrames\n"
        "        let startupGateActivationFrames = transportSession?.startupGateActivationFrames\n"
        "            ?? nChannelTransportSession?.startupGateActivationFrames\n"
        "        return AudioDiagnosticsSnapshot(\n",
        "diagnostic active counters",
    )
    text = replace_once(
        text,
        "            tapSampleRate: transportSession?.tapFormat.sampleRate,\n"
        "            outputSampleRate: transportSession?.outputFormat.sampleRate,\n"
        "            sessionTransportCounters: processingSessionCounters,\n"
        "            lifetimeTransportCounters: lifetimeCounters,\n"
        "            renderKernelDiagnostics: transportSession?.renderDiagnostics(),\n"
        "            startupGateOpened: transportSession?.startupGateOpened,\n"
        "            startupGateTargetFrames: transportSession?.startupGateTargetFrames,\n"
        "            startupGateActivationFrames: transportSession?.startupGateActivationFrames,\n",
        "            tapSampleRate: activeTapSampleRate,\n"
        "            outputSampleRate: activeOutputSampleRate,\n"
        "            sessionTransportCounters: processingSessionCounters,\n"
        "            lifetimeTransportCounters: lifetimeCounters,\n"
        "            renderKernelDiagnostics: transportSession?.renderDiagnostics(),\n"
        "            startupGateOpened: startupGateOpened,\n"
        "            startupGateTargetFrames: startupGateTargetFrames,\n"
        "            startupGateActivationFrames: startupGateActivationFrames,\n",
        "diagnostic active fields",
    )
    text = replace_once(
        text,
        "    private func applyStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {\n"
        "        try validateStereoEQStorage(configuration)\n",
        "    private func applyStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {\n"
        "        try validateStereoEQStorage(configuration)\n"
        "        if nChannelTransportSession != nil, configuration != stereoEQConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n",
        "eq restart guard",
    )
    text = replace_once(
        text,
        "        guard configuration.interChannelDelayMs.isFinite,\n"
        "              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {\n"
        "            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)\n"
        "        }\n\n"
        "        if let session = transportSession {\n",
        "        guard configuration.interChannelDelayMs.isFinite,\n"
        "              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {\n"
        "            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)\n"
        "        }\n"
        "        if nChannelTransportSession != nil, configuration != playbackControlConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n\n"
        "        if let session = transportSession {\n",
        "playback restart guard",
    )
    text = replace_once(
        text,
        "        if let session = transportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {\n",
        "        if let session = transportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {\n",
        "master stereo seam",
    )
    # Add N-channel atomic master gain immediately after the stereo publication block.
    master_marker = (
        "            try session.publishDSPGraph(graph)\n"
        "        }\n\n"
        "        masterVolumeConfiguration = configuration\n"
        "        lastErrorDescription = nil\n"
        "    }\n\n"
        "    private func syncMasterVolumeMonitorToSelectedOutput() throws {\n"
    )
    master_replacement = (
        "            try session.publishDSPGraph(graph)\n"
        "        }\n"
        "        if let session = nChannelTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {\n"
        "            session.setOutputGain(newSoftwareGain)\n"
        "        }\n\n"
        "        masterVolumeConfiguration = configuration\n"
        "        lastErrorDescription = nil\n"
        "    }\n\n"
        "    private func syncMasterVolumeMonitorToSelectedOutput() throws {\n"
    )
    text = replace_once(text, master_marker, master_replacement, "nchannel master volume")

    external_marker = (
        "            try session.publishDSPGraph(graph)\n"
        "        }\n"
        "        masterVolumeConfiguration = updated\n"
        "    }\n\n"
        "    private func handleMasterVolumeDeviceChange() {\n"
    )
    external_replacement = (
        "            try session.publishDSPGraph(graph)\n"
        "        }\n"
        "        if let session = nChannelTransportSession, abs(oldGain - newGain) > 0.000_001 {\n"
        "            session.setOutputGain(newGain)\n"
        "        }\n"
        "        masterVolumeConfiguration = updated\n"
        "    }\n\n"
        "    private func handleMasterVolumeDeviceChange() {\n"
    )
    text = replace_once(text, external_marker, external_replacement, "external master volume")

    text = replace_once(
        text,
        "    private func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {\n"
        "        if let session = transportSession {\n",
        "    private func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {\n"
        "        if nChannelTransportSession != nil, configuration != gainConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        if let session = transportSession {\n",
        "gain restart guard",
    )
    text = replace_once(
        text,
        "    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {\n"
        "        if configuration.enabled && configuration.filter == nil {\n",
        "    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {\n"
        "        if nChannelTransportSession != nil, configuration != roomCorrectionConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        if configuration.enabled && configuration.filter == nil {\n",
        "room correction restart guard",
    )
    text = replace_once(
        text,
        "    private func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {\n"
        "        if configuration.enabled && configuration.filter == nil {\n",
        "    private func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {\n"
        "        if nChannelTransportSession != nil, configuration != speakerIRConfiguration {\n"
        "            throw LiveNChannelTransportError.configurationChangeRequiresRestart\n"
        "        }\n"
        "        if configuration.enabled && configuration.filter == nil {\n",
        "speaker IR restart guard",
    )

    build_marker = "    private func buildTransport(output: AudioOutputDevice) throws {\n"
    build_replacement = '''    private func buildTransport(output: AudioOutputDevice) throws {
        if outputDeviceProfileConfiguration?.enabled == true {
            try buildNChannelTransport(output: output)
            return
        }
        try buildStereoTransport(output: output)
    }

    private func validateLiveNChannelActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy per-driver speaker processing")
        }
        if !stereoEQConfiguration.bypassed {
            if stereoEQConfiguration.channelMode != .linked
                || stereoEQConfiguration.phaseMode != .minimumPhase
                || stereoEQConfiguration.enabledBandCount != 0 {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ")
            }
        }
        if playbackControlConfiguration != PlaybackControlConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls")
        }
        if dynamicsConfiguration != DynamicsConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics/protection")
        }
        if roomCorrectionConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo room correction")
        }
        if speakerIRConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo Speaker IR")
        }
        if bassManagementConfiguration.physicalOutputMode != nil {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy physical crossover routing")
        }
        if bassManagementConfiguration.subPhaseAlignmentEnabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy single-sub phase alignment")
        }
        if bassManagementConfiguration.monitorMode != .recombined {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo crossover monitor audition")
        }
    }

    private func buildNChannelTransport(output: AudioOutputDevice) throws {
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
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: graph,
            outputGain: currentMasterSoftwareGain
        )
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
        linearPhaseDesignInfo = nil
        nChannelTransportSession = session
    }

    private func buildStereoTransport(output: AudioOutputDevice) throws {
'''
    text = replace_once(text, build_marker, build_replacement, "transport selector")

    teardown_old = '''    private func tearDownTransport(fadeOut: Bool) {
        if let session = transportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            transportSession = nil
        }
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
    }
'''
    teardown_new = '''    private func tearDownTransport(fadeOut: Bool) {
        if let session = transportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            transportSession = nil
        }
        if let session = nChannelTransportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            nChannelTransportSession = nil
        }
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
    }
'''
    text = replace_once(text, teardown_old, teardown_new, "teardown both modes")
    return text


def patch_profiles(text: str) -> str:
    old = '''        let previous = systemProfiles[index].state.outputDeviceProfile
        systemProfiles[index].state.outputDeviceProfile = configuration
        do {
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state.outputDeviceProfile = previous
            lastErrorDescription = error.localizedDescription
            throw error
        }
'''
    new = '''        let previousEngineConfiguration = engine.outputDeviceProfileConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceOutputDeviceProfileConfiguration(configuration)
            systemProfiles[index].state.outputDeviceProfile = configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceOutputDeviceProfileConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
'''
    text = replace_once(text, old, new, "profile mutation engine sync")
    text = replace_once(
        text,
        "            outputDeviceProfile: selectedSystemProfile?.state.outputDeviceProfile,\n",
        "            outputDeviceProfile: engine.outputDeviceProfileConfiguration,\n",
        "profile capture engine state",
    )
    text = replace_once(
        text,
        "            try engine.replaceBassManagementConfiguration(state.bassManagement)\n"
        "            try engine.replaceGainConfiguration(gain)\n",
        "            try engine.replaceBassManagementConfiguration(state.bassManagement)\n"
        "            try engine.replaceOutputDeviceProfileConfiguration(state.outputDeviceProfile)\n"
        "            try engine.replaceGainConfiguration(gain)\n",
        "apply system profile to engine",
    )
    text = replace_once(
        text,
        "            try? engine.replacePlaybackControlConfiguration(playback)\n"
        "            try? engine.replaceBassManagementConfiguration(previous.bassManagement)\n"
        "            try? engine.replaceGainConfiguration(gain)\n",
        "            try? engine.replacePlaybackControlConfiguration(playback)\n"
        "            try? engine.replaceOutputDeviceProfileConfiguration(nil)\n"
        "            try? engine.replaceBassManagementConfiguration(previous.bassManagement)\n"
        "            try? engine.replaceOutputDeviceProfileConfiguration(previous.outputDeviceProfile)\n"
        "            try? engine.replaceGainConfiguration(gain)\n",
        "rollback profile/bass ordering",
    )
    return text


engine = patch_engine(ENGINE.read_text(encoding="utf-8"))
profiles = patch_profiles(PROFILES.read_text(encoding="utf-8"))
ENGINE.write_text(engine, encoding="utf-8")
PROFILES.write_text(profiles, encoding="utf-8")

# Remove one-shot machinery before the resulting source commit.
if WORKFLOW.exists():
    WORKFLOW.unlink()
if SELF.exists():
    SELF.unlink()
