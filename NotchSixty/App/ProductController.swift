import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ProductDSPConfiguration: Equatable, Sendable {
    var eq: EQConfiguration
    var stereoEQ: StereoEQConfiguration
    var playback: PlaybackControlConfiguration
    var gain: DSPGainConfiguration
    var bassManagement: BassManagementConfiguration
    var dynamics: DynamicsConfiguration
    var roomCorrection: RoomCorrectionConfiguration
    var speakerIR: SpeakerIRConfiguration

    init(
        eq: EQConfiguration = EQConfiguration(),
        stereoEQ: StereoEQConfiguration = StereoEQConfiguration(),
        playback: PlaybackControlConfiguration = PlaybackControlConfiguration(),
        gain: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        dynamics: DynamicsConfiguration = DynamicsConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),
        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()
    ) {
        self.eq = eq
        self.stereoEQ = stereoEQ
        self.playback = playback
        self.gain = gain
        self.bassManagement = bassManagement
        self.dynamics = dynamics
        self.roomCorrection = roomCorrection
        self.speakerIR = speakerIR
    }
}

struct ProductConfiguration: Equatable, Sendable {
    static let currentSchemaVersion = 6

    var schemaVersion: Int
    var selectedOutputUID: String?
    var masterVolume: MasterVolumeConfiguration
    var dsp: ProductDSPConfiguration

    init(
        schemaVersion: Int = ProductConfiguration.currentSchemaVersion,
        selectedOutputUID: String? = nil,
        masterVolume: MasterVolumeConfiguration = MasterVolumeConfiguration(),
        dsp: ProductDSPConfiguration = ProductDSPConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.selectedOutputUID = selectedOutputUID
        self.masterVolume = masterVolume
        self.dsp = dsp
    }
}

/// Product-level ownership boundary for application state and services.
///
/// `AudioIOEngine` remains the transport/DSP execution controller. Product-facing
/// configuration is exposed here as a compact snapshot so persistence, presets,
/// and the production UI can grow without turning the transport engine into a
/// replacement for the historical monolithic application store.
@MainActor
final class ProductController: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let audioEngine: AudioIOEngine
    let audioUnitHost: AudioUnitHostController
    let profiles: ProductProfileController
    let abComparison: ContentABComparisonController
    let calibration: RoomCorrectionCalibrationController
    let multichannelCalibration: MultichannelCalibrationController
    /// E19 S8: the Room Treatment screen's model (shown behind `e19.mimo-treatment`).
    let mimoTreatment: MIMOTreatmentController
    let roomCorrectionProjects: RoomCorrectionProjectController
    let roomTreatmentAdvisor: RoomTreatmentAdvisorController
    let ambientCompensation: AmbientCompensationController
    let activeQuietZone: ActiveQuietZoneController
    let adaptiveQuietZone: AdaptiveQuietZoneShadow
    let feedForwardSurvey: QuietZoneFeedForwardSurveyController
    let feedForwardShadow: QuietZoneFeedForwardShadow
    /// E4 S25 arming: nil unless `e4.feedforward-live` is on.
    let feedForwardArming: FeedForwardLiveArmingController?
    let hardwareAcceptance: HardwareAcceptanceController
    let backup: NotchSixtyBackupService
    let recovery: ProductRecoveryController
    let headroomAssistant: HeadroomAssistantController
    let reference: ProductionReferenceNavigator
    private var calibrationObservation: AnyCancellable?
    private var multichannelCalibrationObservation: AnyCancellable?
    private var ambientCompensationObservation: AnyCancellable?
    private var activeQuietZoneObservation: AnyCancellable?
    private var audioUnitHostObservation: AnyCancellable?
    private var recoveryObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var didShutdownForTermination = false
    private var selectedOutputObservation: ObservationSubscription?
    static let selectedOutputDefaultsKey = "audio.selectedOutputUID"

    init() {
        let launchSignpost = AppSignposts.signposter.beginInterval("launchServices")
        defer { AppSignposts.signposter.endInterval("launchServices", launchSignpost) }
        let audioEngine = AudioIOEngine(
            initialRouteConfiguration: AudioRouteConfiguration(
                selectedOutputUID: UserDefaults.standard.string(
                    forKey: Self.selectedOutputDefaultsKey
                )
            ),
            masterVolumeStore: UserDefaultsMasterVolumeStore()
        )
        // E6 S11: the graph is the default; `e6.legacy-kernel` selects the frozen kernel fallback.
        // Swift decides; the engine only receives the result. Read once at launch.
        audioEngine.unifiedGraphEnabled = !FeatureFlags().isEnabled(.legacyKernel)
        // E4 S32: the live-output flags are decided in one place so a test drives the production configuration.
        let adaptiveTonalLive = QuietZoneFlagWiring.configureEngine(audioEngine, flags: FeatureFlags())
        let audioUnitHost = AudioUnitHostController()
        audioUnitHost.rateAdaptEnabled = FeatureFlags().isEnabled(.rateAdapt)
        let profiles = ProductProfileController(
            engine: audioEngine,
            audioUnitHost: audioUnitHost
        )
        let calibration = RoomCorrectionCalibrationController(
            engine: audioEngine
        )
        self.audioEngine = audioEngine
        self.audioUnitHost = audioUnitHost
        self.profiles = profiles
        let abComparison = ContentABComparisonController(profiles: profiles)
        self.abComparison = abComparison
        self.calibration = calibration
        let multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.multichannelCalibration = multichannelCalibration
        self.mimoTreatment = MIMOTreatmentController(
            host: audioEngine, flags: FeatureFlags(),
            seats: { multichannelCalibration.seats },
            baseline: { multichannelCalibration.measurements },
            wayMeasurer: CalibrationTreatmentWayMeasurer(calibration: multichannelCalibration))
        let roomProjects =
            RoomCorrectionProjectController(profiles: profiles)
        self.roomCorrectionProjects = roomProjects
        self.roomTreatmentAdvisor =
            RoomTreatmentAdvisorController(
                store: roomProjects.store
            )
        let ambientCompensation = AmbientCompensationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration,
            projects: roomProjects
        )
        self.ambientCompensation = ambientCompensation
        ambientCompensation.unmaskingInputsEnabled = FeatureFlags().isEnabled(.conversationUnmasking)
        let activeQuietZone = ActiveQuietZoneController(
            engine: audioEngine,
            profiles: profiles,
            ambient: ambientCompensation
        )
        UnifiedGraphFIRScheme.refresh()
        UnifiedGraphOutputProtection.refresh()
        ParallelRenderPolicy.refresh()
        UnifiedGraphLiveHeadphoneTuning.refresh()
        activeQuietZone.subAwareAncEnabled = FeatureFlags().isEnabled(.subAwareAnc)
        if activeQuietZone.subAwareAncEnabled {
            roomProjects.ancBassStamp = { [weak activeQuietZone] in activeQuietZone?.ancBassPathState.fingerprint }
            roomProjects.outputGainStamp = { [weak activeQuietZone] in activeQuietZone?.currentOutputGainDB }
        }
        self.activeQuietZone = activeQuietZone
        QuietZoneFlagWiring.attachControllers(
            to: activeQuietZone, engine: audioEngine, ambient: ambientCompensation, roomProjects: roomProjects,
            adaptiveTonalLive: adaptiveTonalLive, flags: FeatureFlags())
        self.adaptiveQuietZone = AdaptiveQuietZoneShadow(
            quietZone: activeQuietZone,
            ambient: ambientCompensation
        )
        let feedForwardSurvey = QuietZoneFeedForwardSurveyController(
            quietZone: activeQuietZone,
            calibration: calibration
        )
        self.feedForwardSurvey = feedForwardSurvey
        // E4 S28: the design survey's coherence turns the noise survey's reference predictions on.
        activeQuietZone.noiseSurvey?.attach(to: feedForwardSurvey)
        let feedForwardShadow = QuietZoneFeedForwardShadow()
        // E4 S22b2: the drive is only ever requested while `e4.feedforward-live` is on.
        feedForwardShadow.driveSource = audioEngine
        // E4 S25: the engine refuses the weights unless that flag is on, and publishing never arms.
        feedForwardShadow.weightsSink = audioEngine
        feedForwardShadow.echoSink = audioEngine
        feedForwardShadow.referenceDriver = audioEngine
        feedForwardShadow.observe(feedForwardSurvey)
        self.feedForwardShadow = feedForwardShadow
        // E4 S25: user-initiated arming of the feed-forward live output (flag-gated, never persisted).
        if FeatureFlags().isEnabled(.feedForwardLive) {
            let arming = FeedForwardLiveArmingController(
                engine: audioEngine,
                shadowFacts: { [weak feedForwardShadow, weak audioEngine] in
                    guard let feedForwardShadow, let audioEngine else { return .none }
                    return FeedForwardLiveShadowFacts.read(shadow: feedForwardShadow, engine: audioEngine)
                })
            activeQuietZone.attachFeedForwardArming(arming)
            self.feedForwardArming = arming
        } else {
            self.feedForwardArming = nil
        }
        self.hardwareAcceptance = HardwareAcceptanceController()
        self.backup = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: roomProjects.store
        )
        self.recovery = ProductRecoveryController(
            store: .forCurrentProcess()
        )
        self.headroomAssistant = HeadroomAssistantController(
            engine: audioEngine,
            profiles: profiles,
            abComparison: abComparison
        )
        self.reference = ProductionReferenceNavigator()
        observeAudioEngine()
        observeTermination()
        // The explicitly selected output is authoritative across launches,
        // including for systems without an associated output.
        selectedOutputObservation = ObservationSubscription(
            value: { audioEngine.routeConfiguration.selectedOutputUID },
            onChange: { uid in
                if let uid {
                    UserDefaults.standard.set(uid, forKey: Self.selectedOutputDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.selectedOutputDefaultsKey)
                }
            }
        )
    }

    init(
        audioEngine: AudioIOEngine,
        recoveryStore: ProductRecoveryStore =
            ProductRecoveryStore(storageURL: nil)
    ) {
        let audioUnitHost = AudioUnitHostController()
        audioUnitHost.rateAdaptEnabled = FeatureFlags().isEnabled(.rateAdapt)
        let profiles = ProductProfileController(
            engine: audioEngine,
            audioUnitHost: audioUnitHost
        )
        let calibration = RoomCorrectionCalibrationController(
            engine: audioEngine
        )
        self.audioEngine = audioEngine
        self.audioUnitHost = audioUnitHost
        self.profiles = profiles
        let abComparison = ContentABComparisonController(profiles: profiles)
        self.abComparison = abComparison
        self.calibration = calibration
        let multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.multichannelCalibration = multichannelCalibration
        self.mimoTreatment = MIMOTreatmentController(
            host: audioEngine, flags: FeatureFlags(),
            seats: { multichannelCalibration.seats },
            baseline: { multichannelCalibration.measurements },
            wayMeasurer: CalibrationTreatmentWayMeasurer(calibration: multichannelCalibration))
        let roomProjects =
            RoomCorrectionProjectController(profiles: profiles)
        self.roomCorrectionProjects = roomProjects
        self.roomTreatmentAdvisor =
            RoomTreatmentAdvisorController(
                store: roomProjects.store
            )
        let ambientCompensation = AmbientCompensationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration,
            projects: roomProjects
        )
        self.ambientCompensation = ambientCompensation
        ambientCompensation.unmaskingInputsEnabled = FeatureFlags().isEnabled(.conversationUnmasking)
        let activeQuietZone = ActiveQuietZoneController(
            engine: audioEngine,
            profiles: profiles,
            ambient: ambientCompensation
        )
        UnifiedGraphFIRScheme.refresh()
        UnifiedGraphOutputProtection.refresh()
        ParallelRenderPolicy.refresh()
        UnifiedGraphLiveHeadphoneTuning.refresh()
        activeQuietZone.subAwareAncEnabled = FeatureFlags().isEnabled(.subAwareAnc)
        if activeQuietZone.subAwareAncEnabled {
            roomProjects.ancBassStamp = { [weak activeQuietZone] in activeQuietZone?.ancBassPathState.fingerprint }
            roomProjects.outputGainStamp = { [weak activeQuietZone] in activeQuietZone?.currentOutputGainDB }
        }
        self.activeQuietZone = activeQuietZone
        // E4 S32: the same flag wiring as `init()`, so an injected engine gets the production configuration.
        let adaptiveTonalLive = QuietZoneFlagWiring.configureEngine(audioEngine, flags: FeatureFlags())
        QuietZoneFlagWiring.attachControllers(
            to: activeQuietZone, engine: audioEngine, ambient: ambientCompensation, roomProjects: roomProjects,
            adaptiveTonalLive: adaptiveTonalLive, flags: FeatureFlags())
        self.adaptiveQuietZone = AdaptiveQuietZoneShadow(
            quietZone: activeQuietZone,
            ambient: ambientCompensation
        )
        let feedForwardSurvey = QuietZoneFeedForwardSurveyController(
            quietZone: activeQuietZone,
            calibration: calibration
        )
        self.feedForwardSurvey = feedForwardSurvey
        activeQuietZone.noiseSurvey?.attach(to: feedForwardSurvey)
        let feedForwardShadow = QuietZoneFeedForwardShadow()
        // E4 S22b2: the drive is only ever requested while `e4.feedforward-live` is on.
        feedForwardShadow.driveSource = audioEngine
        // E4 S25: the engine refuses the weights unless that flag is on, and publishing never arms.
        feedForwardShadow.weightsSink = audioEngine
        feedForwardShadow.echoSink = audioEngine
        feedForwardShadow.referenceDriver = audioEngine
        feedForwardShadow.observe(feedForwardSurvey)
        self.feedForwardShadow = feedForwardShadow
        // E4 S25: user-initiated arming of the feed-forward live output (flag-gated, never persisted).
        if FeatureFlags().isEnabled(.feedForwardLive) {
            let arming = FeedForwardLiveArmingController(
                engine: audioEngine,
                shadowFacts: { [weak feedForwardShadow, weak audioEngine] in
                    guard let feedForwardShadow, let audioEngine else { return .none }
                    return FeedForwardLiveShadowFacts.read(shadow: feedForwardShadow, engine: audioEngine)
                })
            activeQuietZone.attachFeedForwardArming(arming)
            self.feedForwardArming = arming
        } else {
            self.feedForwardArming = nil
        }
        self.hardwareAcceptance = HardwareAcceptanceController()
        self.backup = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: roomProjects.store
        )
        self.recovery = ProductRecoveryController(
            store: recoveryStore
        )
        self.headroomAssistant = HeadroomAssistantController(
            engine: audioEngine,
            profiles: profiles,
            abComparison: abComparison
        )
        self.reference = ProductionReferenceNavigator()
        observeAudioEngine()
    }

    var configuration: ProductConfiguration {
        ProductConfiguration(
            selectedOutputUID: audioEngine.routeConfiguration.selectedOutputUID,
            masterVolume: audioEngine.masterVolumeConfiguration,
            dsp: ProductDSPConfiguration(
                eq: audioEngine.eqConfiguration,
                stereoEQ: audioEngine.stereoEQConfiguration,
                playback: audioEngine.playbackControlConfiguration,
                gain: audioEngine.gainConfiguration,
                bassManagement: audioEngine.bassManagementConfiguration,
                dynamics: audioEngine.dynamicsConfiguration,
                roomCorrection: audioEngine.roomCorrectionConfiguration,
                speakerIR: audioEngine.speakerIRConfiguration
            )
        )
    }

    func prepareForUse() {
        recovery.prepareForLaunch()
        audioEngine.prepareForUse()
        if !recovery.safeLaunchActive {
            profiles.restoreSelectedLayers()
        }
        roomCorrectionProjects.prepareForUse()
        roomTreatmentAdvisor.prepareForUse()
        calibration.prepareForUse()
        multichannelCalibration.prepareForUse()
        ambientCompensation.prepareForUse()
        activeQuietZone.prepareForUse()
        hardwareAcceptance.prepareForUse()
    }

    func openNormallyFromSafeLaunch() throws {
        try normalizeRecoveryLifecycleToIdle()
        try profiles.applySelectedLayersNow()
        recovery.openNormally()
    }

    func openWithPlugInsBypassedFromSafeLaunch() throws {
        try normalizeRecoveryLifecycleToIdle()
        try profiles.applySelectedLayersNow()
        recovery.openWithPlugInsBypassed()
    }

    func restoreLastKnownGoodFromSafeLaunch() throws {
        try normalizeRecoveryLifecycleToIdle()
        let previous = profiles.makeBackupSnapshot()
        let lastKnownGood = try recovery.lastKnownGoodSnapshot()

        do {
            let report = try profiles.restoreBackupSnapshot(
                lastKnownGood,
                availableOutputUIDs:
                    Set(audioEngine.outputDevices.map(\.uid)),
                recomputeHardwareRequirements: true
            )
            guard report.hardwareMappingRequiredCount == 0 else {
                throw ProductRecoveryError
                    .lastKnownGoodRequiresHardwareMapping(
                        report.hardwareMappingRequiredCount
                    )
            }
            try profiles.applySelectedLayersNow()
            abComparison.clearAll()
            recovery.resolveAfterLastKnownGoodRestore()
        } catch {
            _ = try? profiles.restoreBackupSnapshot(
                previous,
                availableOutputUIDs:
                    Set(audioEngine.outputDevices.map(\.uid)),
                recomputeHardwareRequirements: false
            )
            // applySelectedLayersNow() already rolls engine state back to its
            // pre-recovery state on failure. Keep Safe Launch neutral here;
            // the user can still explicitly choose Open Normally afterward.
            throw error
        }
    }

    func startProcessing() async throws {
        guard !recovery.safeLaunchActive else {
            throw ProductRecoveryError.safeLaunchDecisionRequired
        }

        if audioEngine.lifecycleState == .failed {
            audioEngine.stop()
        }
        let format: AudioUnitRackProcessingFormat
        do {
            format =
                try audioEngine.audioUnitRackProcessingFormatForNextStart()
        } catch {
            recovery.recordStartFailure(
                .audioStart,
                description: error.localizedDescription
            )
            throw error
        }

        if recovery.plugInsBypassedForThisLaunch {
            do {
                try audioEngine.stageAudioUnitRackForNextStart(nil)
                try audioEngine.start()
                recovery.recordSuccessfulStart(
                    profiles: profiles.makeBackupSnapshot(),
                    plugInChainHealthy: false
                )
                return
            } catch {
                recovery.recordStartFailure(
                    .audioStart,
                    description: error.localizedDescription
                )
                throw error
            }
        }

        await audioUnitHost.prepareActiveSlotsForLive(format: format)

        let liveRack: AudioUnitLiveRackRuntime?
        do {
            liveRack =
                try await audioUnitHost.makeLiveRackRuntime(
                    format: format
                )
        } catch {
            recovery.recordStartFailure(
                .plugInStart,
                description: error.localizedDescription
            )
            throw error
        }

        do {
            try audioEngine.stageAudioUnitRackForNextStart(liveRack)
            try audioEngine.start()
            recovery.recordSuccessfulStart(
                profiles: profiles.makeBackupSnapshot(),
                plugInChainHealthy:
                    !audioUnitHost.activeRackHasQuarantinedComponent
            )
        } catch {
            // AudioIOEngine owns any staged live rack until the failed state is
            // explicitly stopped. Do not tear it out from under a transport
            // teardown that may still be completing.
            recovery.recordStartFailure(
                .audioStart,
                description: error.localizedDescription
            )
            throw error
        }
    }

    /// Re-instantiates the plug-in rack after a nominal-rate change or output
    /// recovery brought the transport back dry because the previous rack was
    /// bound to another format.
    func rebuildAudioUnitRackAfterFormatChange() async {
        guard audioEngine.lifecycleState == .running,
              !recovery.plugInsBypassedForThisLaunch else { return }
        do {
            let format =
                try audioEngine.audioUnitRackProcessingFormatForMutation()
            await audioUnitHost.prepareActiveSlotsForLive(format: format)
            guard let runtime =
                    try await audioUnitHost.makeLiveRackRuntime(format: format),
                  audioEngine.lifecycleState == .running else { return }
            try audioEngine.restoreAudioUnitRackAfterFormatChange(runtime)
        } catch {
            recovery.recordStartFailure(
                .plugInStart,
                description: error.localizedDescription
            )
        }
    }

    func mutateAudioUnitRack(
        _ mutation: AudioUnitRackMutation,
        crossfadeFrames: Int =
            AudioUnitLiveRackSwitchboard.defaultCrossfadeFrames
    ) async throws -> AudioUnitRackMutationActivation {
        let format =
            try audioEngine.audioUnitRackProcessingFormatForMutation()
        let candidate =
            try await audioUnitHost.makeMutationCandidate(
                applying: mutation,
                format: format
            )

        // Activation is the commit barrier. Host/preset-visible state remains
        // unchanged until the live exchange or controlled restart succeeds.
        let activation =
            try await audioEngine.activateAudioUnitRackMutation(
                candidate,
                crossfadeFrames: crossfadeFrames
            )
        try audioUnitHost.commitMutationCandidate(candidate)
        return activation
    }

    /// `keeping`: E33 S18 (G38), the EQ slot to keep when slot B differs from A; without it that case throws
    /// `EQSlotChoiceError.choiceRequired` and nothing changes.
    func selectContentPreset(_ id: UUID, keeping slot: EQComparisonSlot? = nil) async throws {
        guard let preset = profiles.contentPresets.first(where: {
            $0.id == id
        }) else {
            return
        }
        try profiles.resolveEQSlotsBeforePresetSwitch(keeping: slot)

        let previous = profiles.captureContentState()
        let targetRack = preset.state.audioUnitRack
        let rackChanged = targetRack != audioUnitHost.rackConfiguration

        var candidate: AudioUnitRackMutationCandidate?
        if rackChanged {
            let format =
                try audioEngine.audioUnitRackProcessingFormatForMutation()
            candidate =
                try await audioUnitHost.makeMutationCandidate(
                    applying: .replaceConfiguration(targetRack),
                    format: format
                )
        }

        do {
            try profiles.applyContentStateWithoutAudioUnitRack(
                preset.state
            )

            if let candidate {
                _ = try await audioEngine.activateAudioUnitRackMutation(
                    candidate,
                    crossfadeFrames:
                        AudioUnitLiveRackSwitchboard.defaultCrossfadeFrames
                )
                try audioUnitHost.commitMutationCandidate(candidate)
            }

            profiles.commitContentPresetSelection(id)
        } catch {
            try? profiles.applyContentStateWithoutAudioUnitRack(previous)
            throw error
        }
    }

    /// Idempotent: the menu-bar Quit calls this before `terminate`, which then
    /// posts willTerminate and calls it again.
    func shutdownForTermination() {
        guard !didShutdownForTermination else { return }
        didShutdownForTermination = true
        activeQuietZone.stop()
        ambientCompensation.stopMonitoring()
        multichannelCalibration.cancelMeasurement()
        calibration.cancelMeasurement()
        audioEngine.shutdownForTermination()
        recovery.markCleanTermination()
    }

    private func normalizeRecoveryLifecycleToIdle() throws {
        if audioEngine.lifecycleState == .failed {
            audioEngine.stop()
        }
        guard audioEngine.lifecycleState == .idle else {
            throw ProductRecoveryError.recoveryRequiresIdle
        }
    }

    func diagnosticsReport(
        version: String,
        build: String
    ) -> String {
        let output = audioEngine.selectedOutputDevice
        let kernel =
            audioEngine.diagnosticsSnapshot().renderKernelDiagnostics

        let outputName = output?.name ?? "None selected"
        let outputUID = output?.uid ?? "None"
        let outputRate = output.map {
            String(
                format: "%.1f kHz",
                $0.nominalSampleRate / 1_000.0
            )
        } ?? "Unavailable"
        let latency: String
        if let kernel, kernel.sampleRate > 0 {
            latency = String(
                format: "%u frames / %.3f ms",
                kernel.latencyFrames,
                Double(kernel.latencyFrames)
                    / kernel.sampleRate * 1_000.0
            )
        } else {
            latency = "Unavailable"
        }

        return ([
            "Notch Sixty Diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: Apple Silicon",
            "Lifecycle: \(audioEngine.lifecycleState.rawValue)",
            "Output: \(outputName)",
            "Output UID: \(outputUID)",
            "Output Rate: \(outputRate)",
            "Content Preset: \(profiles.selectedContentPresetName)",
            "Playback System: \(profiles.selectedSystemProfileName)",
            "Global Bypass: \(audioEngine.playbackControlConfiguration.globalBypassed ? "On" : "Off")",
            "EQ Phase: \(audioEngine.stereoEQConfiguration.phaseMode.displayName)",
            "EQ Bands Enabled: \(audioEngine.stereoEQConfiguration.enabledBandCount)",
            "Bass Management: \(audioEngine.bassManagementConfiguration.enabled ? "On" : "Off")",
            "Room Correction: \(audioEngine.roomCorrectionConfiguration.enabled ? "On" : "Off")",
            "DSP Latency: \(latency)",
            "Quarantined Plug-ins: \(audioUnitHost.quarantinedComponentCount)",
        ] + recovery.diagnosticsLines() + activeQuietZone.flightRecorder.diagnosticsLines()
            + measurementReport(version: version, build: build).diagnosticsLines)
            .joined(separator: "\n")
    }

    /// E4 S31: the reviewer measurement report (S16 readout, S28 predictions, S17 log). Predictions come from
    /// the noise survey when `e4.noise-survey` is on and enough ambient snapshots have been seen.
    func measurementReport(version: String, build: String) -> ANCMeasurementReport {
        ANCMeasurementReport(
            version: version,
            build: build,
            verifiedReadout: activeQuietZone.verifiedReadout,
            survey: activeQuietZone.noiseSurvey?.report,
            recorder: activeQuietZone.flightRecorder
        )
    }

    private func observeAudioEngine() {
        audioEngine.roomCorrectionFilterAdapter = { [weak self] filter, sampleRate in
            self?.roomCorrectionProjects.rateAdaptedDeploymentFilter(
                matching: filter,
                sampleRate: sampleRate
            )
        }
        audioEngine.onAudioUnitRackRequiresRebuild = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.rebuildAudioUnitRackAfterFormatChange()
            }
        }
        // E20 S9: the engine is `@Observable`; views read its properties directly, so no relay.
        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        multichannelCalibrationObservation = multichannelCalibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        ambientCompensationObservation = ambientCompensation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        activeQuietZoneObservation = activeQuietZone.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        audioUnitHostObservation = audioUnitHost.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        recoveryObservation = recovery.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func observeTermination() {
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shutdownForTermination()
                }
            }
    }
}
