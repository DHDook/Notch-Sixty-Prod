import CoreAudio
import Foundation

// E23 S4 part 3: stereo EQ and playback-control application, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func legacyEQConfiguration(from configuration: StereoEQConfiguration) -> EQConfiguration {
        EQConfiguration(
            phaseMode: configuration.phaseMode,
            bypassed: configuration.bypassed,
            bands: configuration.sessionEditableBands
        )
    }

    func processingIsBypassed(_ configuration: PlaybackControlConfiguration) -> Bool {
        FIRUpdatePolicy.isRawBypassed(configuration)
    }

    func validateStereoEQStorage(_ configuration: StereoEQConfiguration) throws {
        try configuration.validateStorage(sampleRate: transportSession?.outputFormat.sampleRate)
    }

    func applyStereoEQConfiguration(
        _ configuration: StereoEQConfiguration, forceRepublish: Bool = false
    ) throws {
        try validateStereoEQStorage(configuration)
        transportSession?.linearFadeForEQRepublish = true
        nChannelTransportSession?.linearFadeForEQRepublish = true
        defer {
            transportSession?.linearFadeForEQRepublish = false
            nChannelTransportSession?.linearFadeForEQRepublish = false
        }
        // E27 S3b: an active audition replaces what is rendered, never what is stored.
        let rendered = eqAudition.map { configuration.auditioned($0) } ?? configuration
        if immutableSemanticTransportActive, forceRepublish || rendered != renderStereoEQConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.stereoEQ = rendered
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try rendered.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            if processingIsBypassed(playbackControlConfiguration) {
                // The raw path is already active. Update state without rotating FIR
                // programs or fading an audibly identical raw graph.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeEQFIRProgram = nil
                linearPhaseDesignInfo = nil
            } else {
                var preparedEQFIRProgram: PreparedEQFIRProgram?
                if rendered.requiresEQFIRProgram && !rendered.bypassed {
                    let prepared = try prepareEQFIRProgram(rendered, for: session)
                    preparedEQFIRProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }

                try attachActiveRoomCorrectionProgramIfNeeded(
                    to: &graph,
                    playbackConfiguration: playbackControlConfiguration
                )

                let leavingEQFIR = activeEQFIRProgram != nil
                    && (!rendered.requiresEQFIRProgram || rendered.bypassed)
                let enteringOrReplacingEQFIR = preparedEQFIRProgram != nil
                if leavingEQFIR || enteringOrReplacingEQFIR {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeEQFIRProgram = preparedEQFIRProgram
            }
        } else {
            activeEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = configuration
        eqConfiguration = legacyEQConfiguration(from: configuration)
        lastErrorDescription = nil
    }

    func applyPlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        guard configuration.balance.isFinite,
              PlaybackControlConfiguration.balanceRange.contains(configuration.balance) else {
            throw PlaybackControlConfigurationError.invalidBalance(configuration.balance)
        }
        guard configuration.interChannelDelayMs.isFinite,
              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)
        }
        if immutableSemanticTransportActive, configuration != playbackControlConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.playback = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: configuration,
                masterGainLinear: currentMasterSoftwareGain
            )

            let wasBypassed = processingIsBypassed(playbackControlConfiguration)
            let willBeBypassed = processingIsBypassed(configuration)

            if !willBeBypassed {
                if FIRUpdatePolicy.shouldPrepareEQFIR(
                    stereoEQ: renderStereoEQConfiguration,
                    playback: configuration
                ) {
                    if activeEQFIRProgram == nil {
                        let prepared = try prepareEQFIRProgram(renderStereoEQConfiguration, for: session)
                        activeEQFIRProgram = prepared
                        linearPhaseDesignInfo = prepared.designInfo
                    }
                    try attachActiveEQFIRProgramIfNeeded(
                        to: &graph,
                        stereoConfiguration: renderStereoEQConfiguration,
                        playbackConfiguration: configuration
                    )
                }

                if roomCorrectionConfiguration.isActiveOnStereoKernel {
                    guard let filter = roomCorrectionConfiguration.filter else {
                        throw RoomCorrectionConfigurationError.filterRequired
                    }
                    if activeRoomCorrectionProgram == nil {
                        activeRoomCorrectionProgram = try prepareRoomCorrectionProgram(filter, for: session)
                    }
                    try attachActiveRoomCorrectionProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }

                if speakerIRConfiguration.enabled {
                    guard let filter = speakerIRConfiguration.filter else {
                        throw SpeakerIRConfigurationError.filterRequired
                    }
                    if activeSpeakerIRProgram == nil {
                        activeSpeakerIRProgram = try prepareSpeakerIRProgram(filter, for: session)
                    }
                    try attachActiveSpeakerIRProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }
            }

            let auditionModeChanged = playbackControlConfiguration.auditionMode != configuration.auditionMode
            if wasBypassed != willBeBypassed || auditionModeChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
            }
        }

        playbackControlConfiguration = configuration
        lastErrorDescription = nil
    }
}
