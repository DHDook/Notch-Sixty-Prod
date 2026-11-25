import CoreAudio
import Foundation

// E23 S4 part 3: attaching prepared programs, ambient compensation and quiet zone to a graph, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func attachEQFIRProgram(
        _ program: PreparedEQFIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetConvolutionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw EQConfigurationError.linearPhaseDesignFailed
        }
    }

    func attachActiveEQFIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        stereoConfiguration: StereoEQConfiguration,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.requiresEQFIRProgram,
              !stereoConfiguration.bypassed else { return }
        guard let activeEQFIRProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        try attachEQFIRProgram(activeEQFIRProgram, to: &graph)
    }

    func attachRoomCorrectionProgram(
        _ program: PreparedRoomCorrectionProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw RoomCorrectionConfigurationError.graphAttachmentFailed
        }
    }

    func attachActiveRoomCorrectionProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              roomCorrectionConfiguration.isActiveOnStereoKernel else { return }
        guard let activeRoomCorrectionProgram else {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    func attachAmbientCompensation(
        _ target: AmbientCompensationTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let enabled = abs(target.levelDB) > 0.000_1
            || abs(target.lowSupportDB) > 0.000_1
            || abs(target.presenceSupportDB) > 0.000_1
            || abs(target.detailSupportDB) > 0.000_1
        guard N60DSPGraphSnapshotSetActiveAcousticsAdaptation(
            &graph,
            target.levelDB,
            target.lowSupportDB,
            target.presenceSupportDB,
            target.detailSupportDB,
            enabled
        ) else {
            throw AmbientCompensationError.invalidConfiguration
        }
    }

    func attachAmbientCompensation(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(
            ambientCompensationRuntimeTarget,
            to: &graph
        )
    }

    func ambientTargetClampedToHeadroom(
        _ target: AmbientCompensationTarget,
        gainConfiguration: DSPGainConfiguration
    ) -> AmbientCompensationTarget {
        var clamped = target
        let available = max(
            -gainConfiguration.headroomAttenuationDB,
            0
        )
        if target.levelDB > 0 {
            clamped.levelDB = min(
                target.levelDB,
                available,
                AmbientCompensationConfiguration
                    .hardMaximumLevelCompensationDB
            )
        } else {
            clamped.levelDB = max(target.levelDB, -6.0)
        }
        return clamped
    }

    func attachActiveQuietZone(
        _ target: ActiveQuietZoneRuntimeTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let resolved =
            processingIsBypassed(
                playbackControlConfiguration
            )
            ? ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds:
                    target.transitionMilliseconds
            )
            : target
        let transitionFramesDouble =
            graph.sampleRate
            * resolved.transitionMilliseconds
            / 1_000
        guard transitionFramesDouble.isFinite,
              transitionFramesDouble >= 1,
              transitionFramesDouble
                <= Double(UInt32.max) else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let transitionFrames =
            UInt32(transitionFramesDouble.rounded())

        var tones = resolved.tones.map { tone in
            var value =
                N60ActiveQuietZoneToneSnapshot()
            value.frequencyHz = tone.frequencyHz
            value.leftReal =
                Float(tone.leftOutput.real)
            value.leftImaginary =
                Float(tone.leftOutput.imaginary)
            value.rightReal =
                Float(tone.rightOutput.real)
            value.rightImaginary =
                Float(tone.rightOutput.imaginary)
            return value
        }

        let attached: Bool
        if tones.isEmpty {
            attached =
                N60DSPGraphSnapshotSetActiveQuietZone(
                    &graph,
                    nil,
                    0,
                    transitionFrames,
                    false
                )
        } else {
            attached =
                tones.withUnsafeMutableBufferPointer {
                    N60DSPGraphSnapshotSetActiveQuietZone(
                        &graph,
                        $0.baseAddress,
                        UInt32($0.count),
                        transitionFrames,
                        true
                    )
                }
        }
        if attached, adaptiveTonalMailboxEnabled, !tones.isEmpty, let generation = resolved.armGeneration,
           !N60DSPGraphSnapshotSetActiveQuietZoneArmGeneration(&graph, generation &+ 1) {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let toneCaps: [Float] = excursionCapCurve.map { curve in
            tones.map { curve.trackedCapLinear(atHz: Double($0.frequencyHz)) }
        } ?? []
        let earnedInitial = earnedCapInitialLinear
        let snapshotCapDBFS = earnedInitial > 0
            ? LiveTreatmentSafeguards.hardMaximumPeakCapDBFS
            : LiveTreatmentSafeguards.defaultPeakCapDBFS
        guard attached,
              N60DSPGraphSnapshotSetActiveQuietZonePeakCap(
                &graph,
                Float(LiveTreatmentSafeguards.linearPeak(dbfs: snapshotCapDBFS))
              ),
              N60DSPGraphSnapshotSetActiveQuietZoneInitialCap(&graph, tones.isEmpty ? 0 : earnedInitial),
              toneCaps.withUnsafeBufferPointer({
                  N60DSPGraphSnapshotSetActiveQuietZoneToneCaps(&graph, $0.baseAddress, UInt32($0.count))
              }) else {
            throw ActiveQuietZoneError
                .invalidConfiguration
        }
    }

    func attachActiveQuietZone(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachActiveQuietZone(
            activeQuietZoneRuntimeTarget,
            to: &graph
        )
    }

    func activeQuietZoneTargetAfterHeadroomChange(
        _ target: ActiveQuietZoneRuntimeTarget,
        gainConfiguration: DSPGainConfiguration,
        ambientTarget: AmbientCompensationTarget
    ) -> ActiveQuietZoneRuntimeTarget {
        guard target.active else { return target }
        let available = LiveTreatmentSafeguards.limitedInjectionPeak(
            (
                try? ActiveQuietZonePlanner()
                    .availableInjectionPeak(
                        headroomAttenuationDB:
                            gainConfiguration
                                .headroomAttenuationDB,
                        ambientLevelRecoveryDB:
                            max(ambientTarget.levelDB, 0),
                        configuration:
                            ActiveQuietZoneConfiguration()
                    )
            )
            ?? 0
        )
        guard target.maximumSourceMagnitude
                <= available + 1.0e-7 else {
            // Never rescale solved phasors behind the controller's back.
            return ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds: 100
            )
        }
        return target
    }

    func applyAudioUnitRackLatency(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(to: &graph)
        try attachActiveQuietZone(to: &graph)
        guard let stagedAudioUnitRack else { return }
        let combinedLatency =
            UInt64(graph.latencyFrames)
            + UInt64(max(stagedAudioUnitRack.latencyFrames, 0))
        guard combinedLatency <= UInt64(UInt32.max) else {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        if graph.auditionMode != N60AuditionModeProcessed,
           combinedLatency >= UInt64(N60_MAX_AUDITION_DELAY_FRAMES) {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        graph.latencyFrames = UInt32(combinedLatency)
    }

    func attachSpeakerIRProgram(
        _ program: PreparedSpeakerIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetSpeakerIRProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw SpeakerIRConfigurationError.graphAttachmentFailed
        }
    }

    func attachActiveSpeakerIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              speakerIRConfiguration.enabled else { return }
        guard let activeSpeakerIRProgram else {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        try attachSpeakerIRProgram(activeSpeakerIRProgram, to: &graph)
    }
}
