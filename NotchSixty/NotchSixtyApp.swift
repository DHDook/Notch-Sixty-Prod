import AppKit
import Combine
import ServiceManagement
import SwiftUI

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
    let roomCorrectionProjects: RoomCorrectionProjectController
    let roomTreatmentAdvisor: RoomTreatmentAdvisorController
    let ambientCompensation: AmbientCompensationController
    let activeQuietZone: ActiveQuietZoneController
    let adaptiveQuietZone: AdaptiveQuietZoneShadow
    let feedForwardSurvey: QuietZoneFeedForwardSurveyController
    let feedForwardShadow: QuietZoneFeedForwardShadow
    let hardwareAcceptance: HardwareAcceptanceController
    let backup: NotchSixtyBackupService
    let recovery: ProductRecoveryController
    let headroomAssistant: HeadroomAssistantController
    let reference: ProductionReferenceNavigator
    private var audioEngineObservation: AnyCancellable?
    private var calibrationObservation: AnyCancellable?
    private var multichannelCalibrationObservation: AnyCancellable?
    private var ambientCompensationObservation: AnyCancellable?
    private var activeQuietZoneObservation: AnyCancellable?
    private var audioUnitHostObservation: AnyCancellable?
    private var recoveryObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var didShutdownForTermination = false
    private var selectedOutputObservation: AnyCancellable?
    static let selectedOutputDefaultsKey = "audio.selectedOutputUID"

    init() {
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
        audioEngine.activeQuietZoneLeaseEnabled = FeatureFlags().isEnabled(.ancEngineLease)
        // E4 S18b: the adaptive tonal canceller needs the lease; with either flag off the engine
        // stamps no arm token and the gain mailbox stays shut.
        let adaptiveTonalLive = FeatureFlags().isEnabled(.adaptiveTonalLive)
            && audioEngine.activeQuietZoneLeaseEnabled
        audioEngine.adaptiveTonalMailboxEnabled = adaptiveTonalLive
        // E4 S22b1: only this flag lets the speaker-drive recording be requested at all.
        audioEngine.speakerDriveFeatureEnabled = FeatureFlags().isEnabled(.feedForwardLive)
        let audioUnitHost = AudioUnitHostController()
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
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
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
        let activeQuietZone = ActiveQuietZoneController(
            engine: audioEngine,
            profiles: profiles,
            ambient: ambientCompensation
        )
        self.activeQuietZone = activeQuietZone
        if adaptiveTonalLive {
            activeQuietZone.attachAdaptiveLive(AdaptiveTonalLiveCoordinator(
                ambient: ambientCompensation,
                linkProvider: { [weak audioEngine] in audioEngine?.adaptiveTonalLink }
            ))
        }
        if adaptiveTonalLive, FeatureFlags().isEnabled(.earnedCap) {
            activeQuietZone.attachEarnedCap(EarnedCapPolicy(store: EarnedCapStore()))
            // E4 S21: limits from the bass-management crossover and the speaker's role. A
            // Room Correction -10 dB point (`ExcursionLimits.lowerLimitHz`) replaces the
            // unmeasured default when the measurement store is wired in.
            activeQuietZone.attachExcursionCap { [weak audioEngine] in
                let bass = audioEngine?.bassManagementConfiguration
                let hasSub = bass?.enabled == true
                let crossover = bass?.frequencyHz ?? 80
                return ExcursionLimits(
                    mainLowerLimitHz: hasSub ? crossover : ExcursionLimits.unmeasuredMainLowerLimitHz,
                    subCrossoverHz: hasSub ? crossover : nil
                )
            }
        }
        self.adaptiveQuietZone = AdaptiveQuietZoneShadow(
            quietZone: activeQuietZone,
            ambient: ambientCompensation
        )
        let feedForwardSurvey = QuietZoneFeedForwardSurveyController(
            quietZone: activeQuietZone,
            calibration: calibration
        )
        self.feedForwardSurvey = feedForwardSurvey
        let feedForwardShadow = QuietZoneFeedForwardShadow()
        // E4 S22b2: the drive is only ever requested while `e4.feedforward-live` is on.
        feedForwardShadow.driveSource = audioEngine
        feedForwardShadow.observe(feedForwardSurvey)
        self.feedForwardShadow = feedForwardShadow
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
        selectedOutputObservation = audioEngine.$routeConfiguration
            .map(\.selectedOutputUID)
            .removeDuplicates()
            .dropFirst()
            .sink { uid in
                if let uid {
                    UserDefaults.standard.set(uid, forKey: Self.selectedOutputDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.selectedOutputDefaultsKey)
                }
            }
    }

    init(
        audioEngine: AudioIOEngine,
        recoveryStore: ProductRecoveryStore =
            ProductRecoveryStore(storageURL: nil)
    ) {
        let audioUnitHost = AudioUnitHostController()
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
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
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
        let activeQuietZone = ActiveQuietZoneController(
            engine: audioEngine,
            profiles: profiles,
            ambient: ambientCompensation
        )
        self.activeQuietZone = activeQuietZone
        self.adaptiveQuietZone = AdaptiveQuietZoneShadow(
            quietZone: activeQuietZone,
            ambient: ambientCompensation
        )
        let feedForwardSurvey = QuietZoneFeedForwardSurveyController(
            quietZone: activeQuietZone,
            calibration: calibration
        )
        self.feedForwardSurvey = feedForwardSurvey
        let feedForwardShadow = QuietZoneFeedForwardShadow()
        // E4 S22b2: the drive is only ever requested while `e4.feedforward-live` is on.
        feedForwardShadow.driveSource = audioEngine
        feedForwardShadow.observe(feedForwardSurvey)
        self.feedForwardShadow = feedForwardShadow
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

    func selectContentPreset(_ id: UUID) async throws {
        guard let preset = profiles.contentPresets.first(where: {
            $0.id == id
        }) else {
            return
        }

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
        ] + recovery.diagnosticsLines() + activeQuietZone.flightRecorder.diagnosticsLines())
            .joined(separator: "\n")
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
        audioEngineObservation = audioEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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

#if DEBUG
private struct PR27ProtectionValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private func dynamicsBinding<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let oversampling = dynamicsBinding(\.oversampling)
        let clipperEnabled = dynamicsBinding(\.softClipper.enabled)
        let clipperDrive = dynamicsBinding(\.softClipper.driveDB)
        let clipperThreshold = dynamicsBinding(\.softClipper.thresholdDB)
        let clipperCurve = dynamicsBinding(\.softClipper.curve)
        let clipperAutoGain = dynamicsBinding(\.softClipper.autoCompensateGain)
        let limiterEnabled = dynamicsBinding(\.limiter.enabled)
        let limiterCeiling = dynamicsBinding(\.limiter.ceilingDB)
        let limiterAttack = dynamicsBinding(\.limiter.attackMs)
        let limiterRelease = dynamicsBinding(\.limiter.releaseMs)
        let limiterLookAhead = dynamicsBinding(\.limiter.lookAheadMs)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR27 Protection / Oversampling Validation")
                    .font(.title2.bold())

                Text("Hardware validation surface for the oversampling, soft-clipper, true-peak detector, and limiter paths. Use this tab for the PR27 acceptance pass.")
                    .foregroundStyle(.secondary)

                GroupBox("Oversampling") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Factor", selection: oversampling) {
                            ForEach(OversamplingFactor.allCases) { factor in
                                Text(factor.displayName).tag(factor)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        Text("Compare 1×, 2×, and 4× with the clipper and limiter disabled first. There should be no material level change; the historical 4× attenuation bug is a release blocker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Soft Clipper") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Soft Clipper", isOn: clipperEnabled)
                            .toggleStyle(.switch)

                        HStack(spacing: 12) {
                            Text("Drive").frame(width: 90, alignment: .leading)
                            Slider(value: clipperDrive, in: SoftClipperConfiguration.driveRange, step: 0.5)
                            Text("\(engine.dynamicsConfiguration.softClipper.driveDB, specifier: "%.1f") dB")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 90, alignment: .leading)
                            Slider(value: clipperThreshold, in: SoftClipperConfiguration.thresholdRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.softClipper.thresholdDB, specifier: "%.1f") dB")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Picker("Curve", selection: clipperCurve) {
                                ForEach(SoftClipperCurve.allCases) { curve in
                                    Text(curve.displayName).tag(curve)
                                }
                            }
                            .frame(width: 260)

                            Toggle("Auto gain compensation", isOn: clipperAutoGain)
                                .toggleStyle(.switch)
                        }
                    }
                    .padding(6)
                }

                GroupBox("True-Peak Limiter") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable TP Limiter", isOn: limiterEnabled)
                            .toggleStyle(.switch)

                        HStack(spacing: 12) {
                            Text("Ceiling").frame(width: 90, alignment: .leading)
                            Slider(value: limiterCeiling, in: LimiterConfiguration.ceilingRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.ceilingDB, specifier: "%.1f") dBTP")
                                .monospacedDigit().frame(width: 82)
                        }

                        HStack(spacing: 12) {
                            Text("Look-ahead").frame(width: 90, alignment: .leading)
                            Slider(value: limiterLookAhead, in: LimiterConfiguration.lookAheadRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.lookAheadMs, specifier: "%.1f") ms")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Attack").frame(width: 90, alignment: .leading)
                            Slider(value: limiterAttack, in: LimiterConfiguration.attackRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.attackMs, specifier: "%.1f") ms")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Release").frame(width: 90, alignment: .leading)
                            Slider(value: limiterRelease, in: LimiterConfiguration.releaseRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.limiter.releaseMs, specifier: "%.0f") ms")
                                .monospacedDigit().frame(width: 72)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Realtime Protection Telemetry") {
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            telemetryRow("Requested oversampling", oversamplingName(diagnostics?.oversamplingFactor ?? N60OversamplingFactor1x))
                            telemetryRow("Effective oversampling", oversamplingName(diagnostics?.effectiveOversamplingFactor ?? N60OversamplingFactor1x))
                            telemetryRow("Soft clipper", (diagnostics?.softClipperEnabled ?? false) ? "enabled" : "bypassed")
                            telemetryRow("TP limiter", (diagnostics?.limiterEnabled ?? false) ? "enabled" : "bypassed")
                            telemetryRow("Input true peak", formattedLevel(diagnostics?.inputTruePeakLinear ?? 0))
                            telemetryRow("Output true peak", formattedLevel(diagnostics?.outputTruePeakLinear ?? 0))
                            telemetryRow("Limiter gain reduction", String(format: "%.2f dB", diagnostics?.limiterGainReductionDB ?? 0))
                            telemetryRow("Limiter safety clamps", "\(diagnostics?.limiterSafetyClampSamples ?? 0)")
                            if let diagnostics {
                                telemetryRow("Total DSP latency", formattedLatency(frames: diagnostics.latencyFrames, sampleRate: diagnostics.sampleRate))
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    .padding(6)
                }

                Text("Test order: protection disabled at 1× → 2× → 4×; then soft clipper; then TP limiter. Also verify Processed / Reference / Delta and Global Bypass from the Main Validation tab after changing latency-producing settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }

    @ViewBuilder
    private func telemetryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func oversamplingName(_ factor: N60OversamplingFactor) -> String {
        switch factor {
        case N60OversamplingFactor4x: return "4×"
        case N60OversamplingFactor2x: return "2×"
        default: return "1×"
        }
    }

    private func formattedLevel(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dBFS" }
        return String(format: "%.2f dBFS", 20.0 * log10(Double(linear)))
    }

    private func formattedLatency(frames: UInt32, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames) frames" }
        return String(format: "%u frames / %.3f ms", frames, Double(frames) / sampleRate * 1_000.0)
    }
}

private struct PR28AdvancedDynamicsValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private func dynamicsBinding<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let dcEnabled = dynamicsBinding(\.dcOffsetFilter.enabled)
        let infrasonicEnabled = dynamicsBinding(\.infrasonicFilter.enabled)
        let infrasonicCutoff = dynamicsBinding(\.infrasonicFilter.cutoffHz)
        let infrasonicSlope = dynamicsBinding(\.infrasonicFilter.slope)
        let contourEnabled = dynamicsBinding(\.loudnessContour.enabled)
        let contourStrength = dynamicsBinding(\.loudnessContour.strength)
        let deEsserEnabled = dynamicsBinding(\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\.deEsser.thresholdDB)
        let deEsserDynamicEQ = dynamicsBinding(\.deEsser.dynamicEQMode)
        let multibandEnabled = dynamicsBinding(\.multibandCompressor.enabled)
        let lowMid = dynamicsBinding(\.multibandCompressor.lowMidFrequencyHz)
        let midHigh = dynamicsBinding(\.multibandCompressor.midHighFrequencyHz)
        let slope = dynamicsBinding(\.multibandCompressor.slope)
        let lowThreshold = dynamicsBinding(\.multibandCompressor.lowThresholdDB)
        let midThreshold = dynamicsBinding(\.multibandCompressor.midThresholdDB)
        let highThreshold = dynamicsBinding(\.multibandCompressor.highThresholdDB)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR28 Advanced Dynamics Validation")
                    .font(.title2.bold())
                Text("Clean-room validation surface for De-Esser and three-band Multiband Compressor parity.")
                    .foregroundStyle(.secondary)

                GroupBox("Signal Conditioning") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("DC Offset Filter (0.5 Hz)", isOn: dcEnabled).toggleStyle(.switch)
                        Toggle("Infrasonic Filter", isOn: infrasonicEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Cutoff").frame(width: 90, alignment: .leading)
                            Slider(value: infrasonicCutoff, in: InfrasonicFilterConfiguration.cutoffRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.infrasonicFilter.cutoffHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        Picker("Slope", selection: infrasonicSlope) {
                            ForEach(InfrasonicSlope.allCases) { value in Text(value.displayName).tag(value) }
                        }.frame(maxWidth: 320)
                        Divider()
                        Toggle("Loudness Contour", isOn: contourEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Strength").frame(width: 90, alignment: .leading)
                            Slider(value: contourStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05)
                            Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: "%.2f")")
                                .monospacedDigit().frame(width: 70)
                        }
                    }.padding(6)
                }

                GroupBox("De-Esser") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Frequency").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserFrequency, in: DeEsserConfiguration.frequencyRange, step: 50)
                            Text("\(engine.dynamicsConfiguration.deEsser.frequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 90)
                        }
                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserThreshold, in: DeEsserConfiguration.thresholdRange, step: 0.5)
                            Text("\(engine.dynamicsConfiguration.deEsser.thresholdDB, specifier: "%.1f") dB")
                                .monospacedDigit().frame(width: 80)
                        }
                        Toggle("Dynamic EQ Mode — attenuate only the sibilance band", isOn: deEsserDynamicEQ)
                            .toggleStyle(.switch)
                    }
                    .padding(6)
                }

                GroupBox("3-Band Multiband Compressor") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Multiband Compressor", isOn: multibandEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Low / Mid").frame(width: 90, alignment: .leading)
                            Slider(value: lowMid, in: MultibandCompressorConfiguration.lowMidFrequencyRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.lowMidFrequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        HStack(spacing: 12) {
                            Text("Mid / High").frame(width: 90, alignment: .leading)
                            Slider(value: midHigh, in: MultibandCompressorConfiguration.midHighFrequencyRange, step: 25)
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.midHighFrequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        Picker("Slope", selection: slope) {
                            ForEach(MultibandSlope.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .frame(maxWidth: 320)
                        thresholdRow("Low threshold", binding: lowThreshold, value: engine.dynamicsConfiguration.multibandCompressor.lowThresholdDB)
                        thresholdRow("Mid threshold", binding: midThreshold, value: engine.dynamicsConfiguration.multibandCompressor.midThresholdDB)
                        thresholdRow("High threshold", binding: highThreshold, value: engine.dynamicsConfiguration.multibandCompressor.highThresholdDB)
                    }
                    .padding(6)
                }

                GroupBox("Realtime Gain Reduction") {
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            telemetryRow("De-Esser GR", diagnostics?.deEsserGainReductionDB ?? 0)
                            telemetryRow("Multiband Low GR", diagnostics?.multibandLowGainReductionDB ?? 0)
                            telemetryRow("Multiband Mid GR", diagnostics?.multibandMidGainReductionDB ?? 0)
                            telemetryRow("Multiband High GR", diagnostics?.multibandHighGainReductionDB ?? 0)
                            GridRow {
                                Text("Total DSP latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.latencyFrames ?? 0) frames")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                    .padding(6)
                }

                Text("Acceptance focus: bypass transparency, sibilance-selective reduction, independent band triggering, linked-stereo image stability, click-free toggling, and no change to Reference / Delta / Global Bypass semantics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }

    @ViewBuilder
    private func thresholdRow(_ label: String, binding: Binding<Double>, value: Double) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: binding, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5)
            Text("\(value, specifier: "%.1f") dB").monospacedDigit().frame(width: 80)
        }
    }

    @ViewBuilder
    private func telemetryRow(_ label: String, _ value: Float) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(value, specifier: "%.2f") dB")
        }
    }
}

private struct PR30PhaseTimeValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private var delayBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.interChannelDelayMs },
            set: { try? engine.setInterChannelDelayMs($0) }
        )
    }

    private var phaseModeBinding: Binding<EQPhaseMode> {
        Binding(
            get: { engine.stereoEQConfiguration.phaseMode },
            set: { try? engine.setEQPhaseMode($0) }
        )
    }

    private var allPassBands: [EQBand] {
        engine.stereoEQConfiguration.editableBands.filter { $0.type == .allPass }
    }

    private func bandDoubleBinding(_ source: EQBand, _ keyPath: WritableKeyPath<EQBand, Double>) -> Binding<Double> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?[keyPath: keyPath]
                    ?? source[keyPath: keyPath]
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated[keyPath: keyPath] = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    private func bandEnabledBinding(_ source: EQBand) -> Binding<Bool> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?.enabled ?? source.enabled
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated.enabled = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR30 Phase / Time Alignment Validation")
                    .font(.title2.bold())

                Text("Focused hardware validation for the new phase-only All-Pass EQ and signed fractional inter-channel timing alignment.")
                    .foregroundStyle(.secondary)

                GroupBox("All-Pass EQ") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("EQ Phase Mode", selection: phaseModeBinding) {
                            ForEach(EQPhaseMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        HStack {
                            Button("Add All-Pass Test Band") {
                                try? engine.setEQPhaseMode(.minimumPhase)
                                try? engine.addEQBand(
                                    EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 0.707)
                                )
                            }
                            Button("Remove All-Pass Bands") {
                                let ids = allPassBands.map(\.id)
                                for id in ids { try? engine.removeEQBand(id: id) }
                            }
                            .disabled(allPassBands.isEmpty)
                        }

                        Text("All-Pass is intentionally available only in Minimum phase/IIR mode. It rotates phase/group delay while preserving steady-state magnitude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if allPassBands.isEmpty {
                            Text("No All-Pass bands yet. Add one above for the PR30 listening test.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(allPassBands) { band in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("Enabled", isOn: bandEnabledBinding(band))
                                        .toggleStyle(.switch)
                                    Spacer()
                                    Button("Remove") { try? engine.removeEQBand(id: band.id) }
                                }

                                HStack(spacing: 12) {
                                    Text("Frequency").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.frequencyHz), in: 20...20_000, step: 10)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.frequencyHz ?? band.frequencyHz, specifier: "%.0f") Hz")
                                        .monospacedDigit().frame(width: 92)
                                }

                                HStack(spacing: 12) {
                                    Text("Q").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.q), in: 0.10...20.0, step: 0.01)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.q ?? band.q, specifier: "%.2f")")
                                        .monospacedDigit().frame(width: 72)
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(6)
                }

                GroupBox("Fractional Inter-Channel Delay") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Delay L").foregroundStyle(.secondary)
                            Slider(
                                value: delayBinding,
                                in: PlaybackControlConfiguration.interChannelDelayRange,
                                step: 0.01
                            )
                            Text("Delay R").foregroundStyle(.secondary)
                            Text("\(engine.playbackControlConfiguration.interChannelDelayMs, specifier: "%+.2f") ms")
                                .monospacedDigit().frame(width: 84, alignment: .trailing)
                        }

                        HStack {
                            Button("Reset to 0.00 ms") { try? engine.setInterChannelDelayMs(0) }
                            Text("Negative values delay Left; positive values delay Right. Zero is transparent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("The fractional stage uses phase-preserving all-pass interpolation with a tiny common alignment delay when active, rather than amplitude-interpolating between adjacent samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Realtime Alignment Telemetry") {
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            GridRow {
                                Text("Published L/R delay").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelDelayMs ?? 0, specifier: "%+.3f") ms")
                            }
                            GridRow {
                                Text("Alignment latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelAlignmentLatencyFrames ?? 0) frames")
                            }
                            GridRow {
                                Text("Total DSP latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.latencyFrames ?? 0) frames")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    .padding(6)
                }

                Text("Acceptance focus: All-Pass should alter phase/spatial behavior without an obvious level or tonal shift; ± delay should move the appropriate channel; 0.00 ms should return to transparent behavior; changes should remain click-free. Also verify Processed / Reference / Delta and Global Bypass after exercising both stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }
}

private struct PR31NoiseHumValidationView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var mainsDiagnostics: RenderKernelDiagnostics?
    private let trackingTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private func mainsBinding<Value>(_ keyPath: WritableKeyPath<MainsNotchConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var regionBinding: Binding<MainsRegion> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.region },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.selectRegion(value)
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var trackingBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.continuousTracking },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.continuousTracking = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var harmonicCountBinding: Binding<Double> {
        Binding(
            get: { Double(engine.dynamicsConfiguration.mainsNotch.harmonicCount) },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicCount = Int(value.rounded())
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicDepthsDB[index] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var denoiserEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.enabled },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser.enabled = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var denoiserPresetBinding: Binding<SpectralDenoiserPreset> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.preset },
            set: { value in try? engine.applySpectralDenoiserPreset(value) }
        )
    }

    private func denoiserBinding<Value>(
        _ keyPath: WritableKeyPath<SpectralDenoiserConfiguration, Value>,
        marksCustom: Bool = true
    ) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser[keyPath: keyPath] = value
                if marksCustom { updated.spectralDenoiser.markCustom() }
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let enabled = mainsBinding(\.enabled)
        let region = regionBinding
        let q = mainsBinding(\.q)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR31 Noise / Hum Validation")
                    .font(.title2.bold())
                Text("PR31 now includes mains-frequency detection/tracking plus the new clean-room spectral denoiser. The denoiser is deliberately conservative: linked-stereo WOLA processing, threshold-gated adaptive learning, explicit noise Capture, protected bands, and measurable latency.")
                    .foregroundStyle(.secondary)

                GroupBox("Mains Hum Notch") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Mains Hum Notch", isOn: enabled).toggleStyle(.switch)

                        Picker("Region", selection: region) {
                            ForEach(MainsRegion.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        HStack(spacing: 12) {
                            Text("Harmonics").frame(width: 90, alignment: .leading)
                            Slider(value: harmonicCountBinding, in: 1...16, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicCount)")
                                .monospacedDigit().frame(width: 36)
                        }

                        HStack(spacing: 12) {
                            Text("Q").frame(width: 90, alignment: .leading)
                            Slider(value: q, in: MainsNotchConfiguration.qRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.q, specifier: "%.0f")")
                                .monospacedDigit().frame(width: 48)
                        }

                        Divider()
                        Text("Per-harmonic depth")
                            .font(.subheadline.bold())
                        ForEach(0..<engine.dynamicsConfiguration.mainsNotch.harmonicCount, id: \.self) { index in
                            HStack(spacing: 12) {
                                let frequency = engine.dynamicsConfiguration.mainsNotch.fundamentalHz * Double(index + 1)
                                Text("H\(index + 1)  \(frequency, specifier: "%.0f") Hz")
                                    .frame(width: 105, alignment: .leading)
                                Slider(value: harmonicDepthBinding(index), in: MainsNotchConfiguration.depthRange, step: 1)
                                Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index], specifier: "%.0f") dB")
                                    .monospacedDigit().frame(width: 70)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Detection / Tracking") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button("Detect") {
                                _ = try? engine.applyDetectedMainsHum()
                                mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                            }
                            Toggle("Continuous Tracking", isOn: trackingBinding).toggleStyle(.switch)
                        }
                        let detected = mainsDiagnostics?.mainsDetectedFrequencyHz ?? 0
                        let confidence = mainsDiagnostics?.mainsDetectionConfidence ?? 0
                        Text("Detected: \(detected, specifier: "%.2f") Hz   Confidence: \(confidence * 100, specifier: "%.0f")%")
                            .monospacedDigit()
                        Text("Active notch fundamental: \(engine.dynamicsConfiguration.mainsNotch.fundamentalHz, specifier: "%.2f") Hz")
                            .monospacedDigit()
                        Text("Detector searches ±3 Hz around the selected 50/60 Hz region. One-shot Detect applies the latest confident estimate; Continuous Tracking only republishes bounded, confident changes and the realtime notch crossfades old/new coefficients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Spectral Denoising") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Spectral Denoiser", isOn: denoiserEnabledBinding)
                            .toggleStyle(.switch)

                        Picker("Preset", selection: denoiserPresetBinding) {
                            ForEach(SpectralDenoiserPreset.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text("Reduction").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\.reductionAmount), in: SpectralDenoiserConfiguration.reductionRange, step: 0.01)
                            Text("\(engine.dynamicsConfiguration.spectralDenoiser.reductionAmount * 100, specifier: "%.0f")%")
                                .monospacedDigit().frame(width: 58)
                        }

                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\.thresholdDBFS), in: SpectralDenoiserConfiguration.thresholdRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.spectralDenoiser.thresholdDBFS, specifier: "%.0f") dBFS")
                                .monospacedDigit().frame(width: 78)
                        }

                        Picker("Quality", selection: denoiserBinding(\.quality)) {
                            ForEach(SpectralDenoiserQuality.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)

                        Toggle("Protect Frequency Range", isOn: denoiserBinding(\.protectedRangeEnabled))
                            .toggleStyle(.switch)

                        if engine.dynamicsConfiguration.spectralDenoiser.protectedRangeEnabled {
                            let rate = mainsDiagnostics?.sampleRate ?? 48_000
                            let maximum = max(200.0, min(20_000.0, rate * 0.5 - 1.0))
                            HStack(spacing: 12) {
                                Text("Protected Low").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\.protectedLowHz), in: 0...maximum, step: 10)
                                Text("\(engine.dynamicsConfiguration.spectralDenoiser.protectedLowHz, specifier: "%.0f") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                            HStack(spacing: 12) {
                                Text("Protected High").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\.protectedHighHz), in: 0...maximum, step: 10)
                                Text("\(engine.dynamicsConfiguration.spectralDenoiser.protectedHighHz, specifier: "%.0f") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                        }

                        Divider()
                        HStack(spacing: 12) {
                            Button("Capture Noise Profile") { try? engine.captureSpectralNoiseProfile() }
                            Button("Reset Profile") { try? engine.resetSpectralNoiseProfile() }
                        }
                        Text("Capture listens for about one second. Use a noise-only passage if possible. Reset returns to conservative adaptive learning. Learned profile/configuration state is preserved while bypassed; ordinary disabled playback parks the spectral FFT path until the denoiser or an explicit profile capture is enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Denoiser Telemetry") {
                    let diagnostics = mainsDiagnostics
                    let status: String = {
                        if diagnostics?.denoiserCaptureActive == true { return "Capturing" }
                        if diagnostics?.denoiserCapturedProfile == true { return "Captured Profile" }
                        if diagnostics?.denoiserProfileReady == true { return "Adaptive Ready" }
                        return "Learning"
                    }()
                    let rate = diagnostics?.sampleRate ?? 0
                    let denoiserFrames = diagnostics?.denoiserLatencyFrames ?? 0
                    let denoiserMS = rate > 0 ? Double(denoiserFrames) * 1000.0 / rate : 0
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text("Profile state").foregroundStyle(.secondary); Text(status) }
                        GridRow { Text("Capture progress").foregroundStyle(.secondary); Text("\((diagnostics?.denoiserCaptureProgress ?? 0) * 100, specifier: "%.0f")%") }
                        GridRow { Text("Estimated noise").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserEstimatedNoiseDBFS ?? -120, specifier: "%.1f") dBFS") }
                        GridRow { Text("Mean suppression").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserMeanSuppressionDB ?? 0, specifier: "%.2f") dB") }
                        GridRow { Text("Max suppression").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserMaxSuppressionDB ?? 0, specifier: "%.2f") dB") }
                        GridRow { Text("FFT / hop").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserFFTSize ?? 0) / \(diagnostics?.denoiserHopSize ?? 0) frames") }
                        GridRow { Text("Denoiser latency").foregroundStyle(.secondary); Text("\(denoiserFrames) frames  (\(denoiserMS, specifier: "%.2f") ms)") }
                        GridRow { Text("Total DSP latency").foregroundStyle(.secondary); Text("\(diagnostics?.latencyFrames ?? 0) frames") }
                        GridRow { Text("Spectral frames").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserSpectralFramesProcessed ?? 0)") }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                }

                Text("Denoiser acceptance focus: start with Natural or Standard. Listen for real noise-floor reduction without pumping, chirping/musical-noise artifacts, softened transients, vocal smearing, or stereo-image movement. Compare Capture against adaptive learning, exercise the protected range, and compare Quality / High / Ultra. Reference and Delta must remain latency aligned. Aggressive is intentionally the stress case, not the default recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
        .onAppear { mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics }
        .onReceive(trackingTimer) { _ in
            guard engine.lifecycleState == .running else { return }
            mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
            if engine.dynamicsConfiguration.mainsNotch.continuousTracking {
                engine.pollMainsHumTracking()
            }
        }
    }
}

private struct EngineeringValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        TabView {
            ContentView(engine: engine)
                .tabItem { Label("Main Validation", systemImage: "slider.horizontal.3") }

            PR27ProtectionValidationView(engine: engine)
                .tabItem { Label("PR27 Protection", systemImage: "waveform.path.ecg") }

            PR28AdvancedDynamicsValidationView(engine: engine)
                .tabItem { Label("PR28 Advanced Dynamics", systemImage: "waveform.badge.plus") }

            PR30PhaseTimeValidationView(engine: engine)
                .tabItem { Label("PR30 Phase / Time", systemImage: "timeline.selection") }

            PR31NoiseHumValidationView(engine: engine)
                .tabItem { Label("PR31 Noise / Hum", systemImage: "waveform.slash") }
        }
        .frame(minWidth: 900, minHeight: 720)
    }
}

#endif

enum ApplicationAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum ApplicationPresenceMode: String, CaseIterable, Identifiable {
    case dock
    case tray
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dock: return "Dock"
        case .tray: return "Menu Bar"
        case .both: return "Both"
        }
    }
}

/// The volume-key step size. Raw values are persisted: positive ones are
/// slider fractions (1/16 …), negative ones are dB steps in tenths of a dB.
enum ApplicationVolumeStepResolution: Int, CaseIterable, Identifiable {
    case standard = 16
    case fine = 32
    case precision = 64
    case halfDecibel = -5
    case oneDecibel = -10
    case oneAndHalfDecibels = -15
    case threeDecibels = -30

    var id: Int { rawValue }

    static let fractions: [Self] = [.standard, .fine, .precision]
    /// ⅙, ⅓, ½ and 1 stop of power (1 stop = 3 dB), all on a 0.5 dB grid.
    static let decibelSteps: [Self] = [.halfDecibel, .oneDecibel, .oneAndHalfDecibels, .threeDecibels]

    /// Reads a stored raw value. The first dB build offered 2 and 4 dB
    /// (−20, −40); those map to the nearest current steps rather than
    /// falling back to 1/16.
    init?(storedValue: Int) {
        switch storedValue {
        case -20: self = .oneAndHalfDecibels
        case -40: self = .threeDecibels
        default: self.init(rawValue: storedValue)
        }
    }

    var usesDecibels: Bool { rawValue < 0 }

    /// Steps that land on .5 values keep one decimal in every readout, so
    /// the menu bar text never changes width.
    var readoutShowsTenths: Bool { usesDecibels && rawValue % 10 != 0 }

    var keyStep: MasterVolumeKeyStep {
        usesDecibels
            ? .decibels(Double(-rawValue) / 10)
            : .fraction(denominator: rawValue)
    }

    var displayName: String {
        switch self {
        case .standard: return "1/16"
        case .fine: return "1/32"
        case .precision: return "1/64"
        case .halfDecibel: return "0.5 dB"
        case .oneDecibel: return "1 dB"
        case .oneAndHalfDecibels: return "1.5 dB"
        case .threeDecibels: return "3 dB"
        }
    }
}

enum VolumeFeedbackPresentation {
    static func percentage(_ level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return Int((min(max(level, 0.0), 1.0) * 100.0).rounded())
    }

    /// With `decibels`, the software taper's attenuation: "−12 dB" climbing
    /// to "0 dB" at full scale, and "−∞ dB" at silence.
    /// `alwaysTenths` keeps one decimal ("−27.0 dB") so a 0.5 dB step
    /// never changes the readout's width in the menu bar.
    static func readout(
        level: Double,
        muted: Bool,
        decibels: Bool = false,
        alwaysTenths: Bool = false
    ) -> String {
        if muted { return "Muted" }
        guard decibels else { return "\(percentage(level))%" }
        return decibelReadout(
            MasterVolumeConfiguration.softwareTaperDB(forLevel: level),
            alwaysTenths: alwaysTenths
        )
    }

    /// Marks on the fader in the percent step modes, where position is the
    /// level itself and the readout is a percentage.
    static let faderTickPercents: [Int] = [0, 25, 50, 75, 100]

    /// Marks on the dB-linear fader: evenly spaced, since position is dB.
    static let decibelFaderTickDecibels: [Double] = [0, -10, -20, -30, -40, -50, -60, -70]

    static func faderTickLabel(_ decibels: Double?) -> String {
        guard let decibels else { return "−∞" }
        return decibels == 0 ? "0" : "−\(Int(-decibels))"
    }

    /// The widest strings `readout` can return in one mode, with 8 standing
    /// in for any digit (digits are tabular, so all share one width).
    /// The menu bar reserves the widest of these so the readout never
    /// changes its width as the level moves.
    static func readoutWidthTemplates(decibels: Bool, alwaysTenths: Bool) -> [String] {
        guard decibels else { return ["100%", "Muted"] }
        return [alwaysTenths ? "−88.8 dB" : "−88 dB", "−∞ dB", "Muted"]
    }

    static func decibelReadout(_ decibels: Double?, alwaysTenths: Bool = false) -> String {
        guard let decibels else { return "−∞ dB" }
        let tenths = (decibels * 10).rounded()
        guard tenths < 0 else { return alwaysTenths ? "0.0 dB" : "0 dB" }
        let magnitude = -tenths / 10
        let number = magnitude.rounded() == magnitude && !alwaysTenths
            ? String(format: "%.0f", magnitude)
            : String(format: "%.1f", magnitude)
        return "−\(number) dB"
    }
}

enum VolumeFeedbackPopupPosition: String, CaseIterable, Identifiable {
    case bottomCenter
    case topRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .topRight: return "Follow macOS Popup"
        }
    }
}

/// Where macOS draws its own volume popup. Measured on macOS 27 from the
/// on-screen window list (owner MenuBarAgent, level 101): a 352 × 149 pt
/// window flush under the menu bar, 87 pt in from the screen's right edge,
/// shown for about 1.44 s per key press. The window frame includes its
/// transparent shadow margin, so covering the whole frame covers the popup.
enum SystemVolumePopupGeometry {
    static let size = CGSize(width: 352, height: 149)
    static let trailingInset: CGFloat = 87
    static let windowLevel = NSWindow.Level.popUpMenu
    static let displayDuration: TimeInterval = 1.44

    static func frame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - trailingInset - size.width,
            y: visibleFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// While another app is full screen, macOS moves its popup to the top
    /// centre of that screen. UNMEASURED: assumes the same window size, centred
    /// on the full screen frame and flush with its top edge. Replace with the
    /// bench measurement (docs/epics/E5.md, "Bench checks").
    static func fullScreenFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// Whether the frontmost app is full screen on a given display, from the
/// public on-screen window list (owner, layer and bounds need no Screen
/// Recording permission). Checked once per popup, never polled.
enum FullScreenAppDetector {
    /// `windows` is `CGWindowListCopyWindowInfo` output, whose bounds are in
    /// global top-left coordinates; `primaryScreenHeight` converts them to
    /// AppKit's bottom-left space. Full screen means a normal-layer window of
    /// `ownerPID` covering `screenFrame` exactly, menu bar area included.
    static func isFullScreen(
        windows: [[String: Any]],
        ownerPID: pid_t,
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> Bool {
        let tolerance: CGFloat = 1
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return false }
            let appKitBounds = CGRect(
                x: bounds.minX,
                y: primaryScreenHeight - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
            return abs(appKitBounds.minX - screenFrame.minX) <= tolerance
                && abs(appKitBounds.minY - screenFrame.minY) <= tolerance
                && abs(appKitBounds.width - screenFrame.width) <= tolerance
                && abs(appKitBounds.height - screenFrame.height) <= tolerance
        }
    }

    @MainActor
    static func frontmostAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return false }
        return isFullScreen(
            windows: windows,
            ownerPID: pid,
            screenFrame: screen.frame,
            primaryScreenHeight: primary.frame.height
        )
    }
}

enum VolumeFeedbackPopupStyle: Equatable {
    /// Translucent Liquid Glass.
    case glass
    /// Opaque base under a glass rim, so a covered system popup cannot show through.
    case solidGlass
}

/// Frame, style, window level and display time of Notch Sixty's popup.
struct VolumeFeedbackPopupLayout: Equatable {
    static let standardSize = CGSize(width: 264, height: 88)
    /// Cover mode spans the system popup's full width but not its full
    /// height: that frame includes a transparent shadow margin, and our
    /// one-row content looked empty in it. The panel sits just under the menu
    /// bar, where the visible system popup starts.
    static let coverHeight: CGFloat = 104
    static let coverTopInset: CGFloat = 6
    static let gapBesideSystemPopup: CGFloat = 8

    let frame: CGRect
    let style: VolumeFeedbackPopupStyle
    let level: NSWindow.Level
    let displayDuration: TimeInterval

    /// Covering applies only with Follow macOS Popup. `fullScreenFrame` is the
    /// screen's full frame when another app is full screen there; the popup
    /// then follows the system one to the top centre.
    static func make(
        position: VolumeFeedbackPopupPosition,
        coverSystemPopup: Bool,
        visibleFrame: CGRect,
        fullScreenFrame: CGRect? = nil
    ) -> VolumeFeedbackPopupLayout {
        let size = standardSize
        switch position {
        case .bottomCenter:
            return VolumeFeedbackPopupLayout(
                frame: CGRect(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.minY + 84,
                    width: size.width,
                    height: size.height
                ),
                style: .glass,
                level: .floating,
                displayDuration: 1.4
            )
        case .topRight:
            let system = fullScreenFrame.map(SystemVolumePopupGeometry.fullScreenFrame(in:))
                ?? SystemVolumePopupGeometry.frame(in: visibleFrame)
            if coverSystemPopup {
                // One level above the system popup, and up longer than it, so
                // it never peeks out before or after ours.
                return VolumeFeedbackPopupLayout(
                    frame: CGRect(
                        x: system.minX,
                        y: system.maxY - coverTopInset - coverHeight,
                        width: system.width,
                        height: coverHeight
                    ),
                    style: .solidGlass,
                    level: NSWindow.Level(
                        rawValue: SystemVolumePopupGeometry.windowLevel.rawValue + 1
                    ),
                    displayDuration: SystemVolumePopupGeometry.displayDuration + 0.4
                )
            }
            // Beside the system popup: to its left, centred on it vertically.
            return VolumeFeedbackPopupLayout(
                frame: CGRect(
                    x: system.minX - gapBesideSystemPopup - size.width,
                    y: system.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                style: .glass,
                level: .floating,
                displayDuration: 1.4
            )
        }
    }
}

// Presentation only: no audio callback, key interception, driver, or system
// HUD manipulation. Cover mode draws a window above the system popup; it
// never hides, moves or alters it.
@MainActor
private final class VolumeFeedbackHUDController {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(
        _ configuration: MasterVolumeConfiguration,
        position: VolumeFeedbackPopupPosition,
        coverSystemPopup: Bool,
        decibels: Bool,
        alwaysTenths: Bool
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let followsFullScreen = position == .topRight
            && FullScreenAppDetector.frontmostAppIsFullScreen(on: screen)
        let layout = VolumeFeedbackPopupLayout.make(
            position: position,
            coverSystemPopup: coverSystemPopup,
            visibleFrame: screen.visibleFrame,
            fullScreenFrame: followsFullScreen ? screen.frame : nil
        )
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            window = NSPanel(
                contentRect: layout.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            panel = window
        }

        window.level = layout.level
        window.contentView = NSHostingView(
            rootView: VolumeFeedbackHUDView(
                configuration: configuration,
                style: layout.style,
                decibels: decibels,
                alwaysTenths: alwaysTenths
            )
            .frame(width: layout.frame.width, height: layout.frame.height)
        )
        window.setFrame(layout.frame, display: true)
        window.orderFrontRegardless()
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(layout.displayDuration))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }
}

private struct VolumeFeedbackHUDView: View {
    let configuration: MasterVolumeConfiguration
    let style: VolumeFeedbackPopupStyle
    let decibels: Bool
    let alwaysTenths: Bool

    private var readout: String {
        VolumeFeedbackPresentation.readout(
            level: configuration.level,
            muted: configuration.muted,
            decibels: decibels,
            alwaysTenths: alwaysTenths
        )
    }

    /// The slider position, which on the loudness taper is also the
    /// relative loudness, in both readout modes.
    private var barPosition: Double {
        if configuration.muted { return 0 }
        return min(max(configuration.level, 0), 1)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style == .solidGlass ? 28 : 22)
    }

    var body: some View {
        content
            .padding(.horizontal, style == .solidGlass ? 28 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: shape)
            .background {
                // Glass over an opaque base: the rim and highlight stay, but
                // nothing behind the window (the system popup) shows through.
                if style == .solidGlass {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Notch Sixty volume " + readout
            )
    }

    private var content: some View {
        HStack(spacing: style == .solidGlass ? 18 : 14) {
            Image(
                systemName: configuration.muted
                    ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(style == .solidGlass ? .largeTitle : .title2)
            .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("NOTCH SIXTY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(readout)
                    .font(style == .solidGlass ? .title3.weight(.semibold) : .headline)
                    .monospacedDigit()
                }
                ProgressView(value: barPosition)
                .tint(.orange)
            }
        }
    }
}

private struct MenuBarVolumeLabel: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var preferences: ApplicationPreferences

    private var readout: String {
        VolumeFeedbackPresentation.readout(
            level: engine.masterVolumeConfiguration.level,
            muted: engine.masterVolumeConfiguration.muted,
            decibels: preferences.showsDecibelReadout(for: engine),
            alwaysTenths: preferences.decibelReadoutShowsTenths
        )
    }

    @Environment(\.displayScale) private var displayScale

    private var widthTemplates: [String] {
        VolumeFeedbackPresentation.readoutWidthTemplates(
            decibels: preferences.showsDecibelReadout(for: engine),
            alwaysTenths: preferences.decibelReadoutShowsTenths
        )
    }

    /// The status item ignores most layout modifiers, so the label is drawn
    /// to a template image. The readout sits in a slot as wide as the widest
    /// string the current mode can show, so the item's width, and every
    /// menu-bar item beside it, stays put as the digits change.
    private var labelImage: NSImage? {
        let label = HStack(spacing: 5) {
            Image("TrayIcon")
                .renderingMode(.template)
            if preferences.showVolumeInMenuBar {
                ZStack(alignment: .leading) {
                    ForEach(widthTemplates, id: \.self) { Text($0).hidden() }
                    Text(readout)
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: label)
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let labelImage {
                Image(nsImage: labelImage)
            } else {
                Image("TrayIcon").renderingMode(.template)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Notch Sixty" + (
                preferences.showVolumeInMenuBar
                ? ", volume " + readout : ""
            )
        )
    }
}

@MainActor
final class ApplicationPreferences: ObservableObject {
    private typealias Key = PreferenceKeys.Application

    private let defaults: UserDefaults
    private weak var audioEngine: AudioIOEngine?

    @Published var appearance: ApplicationAppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var presence: ApplicationPresenceMode {
        didSet {
            defaults.set(presence.rawValue, forKey: Key.presence)
            applyActivationPolicy()
        }
    }

    @Published var volumeStepResolution: ApplicationVolumeStepResolution {
        didSet {
            defaults.set(volumeStepResolution.rawValue, forKey: Key.volumeStepResolution)
            audioEngine?.setSoftwareVolumeKeyStep(volumeStepResolution.keyStep)
        }
    }

    @Published var showVolumeInMenuBar: Bool {
        didSet { defaults.set(showVolumeInMenuBar, forKey: Key.showVolumeInMenuBar) }
    }

    @Published var showVolumePopup: Bool {
        didSet {
            defaults.set(showVolumePopup, forKey: Key.showVolumePopup)
            if !showVolumePopup { volumeHUD.dismiss() }
        }
    }

    @Published var volumePopupPosition: VolumeFeedbackPopupPosition {
        didSet { defaults.set(volumePopupPosition.rawValue, forKey: Key.volumePopupPosition) }
    }

    /// The stored choice; it only takes effect with Follow macOS Popup.
    @Published var coverSystemVolumePopup: Bool {
        didSet { defaults.set(coverSystemVolumePopup, forKey: Key.coverSystemVolumePopup) }
    }

    var coversSystemVolumePopup: Bool {
        coverSystemVolumePopup && volumePopupPosition == .topRight
    }

    private let volumeHUD = VolumeFeedbackHUDController()
    private var volumeFeedbackObservation: AnyCancellable?

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    private var appearanceObservation: NSKeyValueObservation?
    private var didApplyInitialPreferences = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = ApplicationAppearanceMode(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .system
        presence = ApplicationPresenceMode(
            rawValue: defaults.string(forKey: Key.presence) ?? ""
        ) ?? .both
        volumeStepResolution = ApplicationVolumeStepResolution(
            storedValue: defaults.integer(forKey: Key.volumeStepResolution)
        ) ?? .standard
        showVolumeInMenuBar = defaults.object(forKey: Key.showVolumeInMenuBar) as? Bool ?? true
        showVolumePopup = defaults.bool(forKey: Key.showVolumePopup)
        volumePopupPosition = VolumeFeedbackPopupPosition(
            rawValue: defaults.string(forKey: Key.volumePopupPosition) ?? ""
        ) ?? .bottomCenter
        coverSystemVolumePopup = defaults.bool(forKey: Key.coverSystemVolumePopup)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginError = nil
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyApplicationIcon()
            }
        }
    }

    var isTrayInserted: Bool { presence != .dock }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval in System Settings"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func setTrayInserted(_ inserted: Bool) {
        if inserted {
            if presence == .dock { presence = .both }
        } else if presence != .dock {
            // Never strand a tray-only app with no visible app surface.
            presence = .dock
        }
    }

    /// dB readouts follow a dB step size, but only on the software volume,
    /// whose taper defines the dB value; device-mode volume stays in percent.
    func showsDecibelReadout(for engine: AudioIOEngine) -> Bool {
        volumeStepResolution.usesDecibels
            && engine.masterVolumeCapabilities.controlMode == .softwareDSP
    }

    var decibelReadoutShowsTenths: Bool { volumeStepResolution.readoutShowsTenths }

    func apply(to audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
        audioEngine.setSoftwareVolumeKeyStep(volumeStepResolution.keyStep)
        guard !didApplyInitialPreferences else { return }
        didApplyInitialPreferences = true
        volumeFeedbackObservation = audioEngine.$masterVolumeConfiguration
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] configuration in
                guard let self, self.showVolumePopup else { return }
                self.volumeHUD.show(
                    configuration,
                    position: self.volumePopupPosition,
                    coverSystemPopup: self.coversSystemVolumePopup,
                    decibels: self.showsDecibelReadout(for: audioEngine),
                    alwaysTenths: self.decibelReadoutShowsTenths
                )
            }
        applyAppearance()
        applyActivationPolicy()
    }


    func makeBackupSnapshot() -> NotchSixtyBackupPreferences {
        NotchSixtyBackupPreferences(
            appearance: appearance.rawValue,
            presence: presence.rawValue,
            volumeStepResolution: volumeStepResolution.rawValue,
            showVolumeInMenuBar: showVolumeInMenuBar,
            showVolumePopup: showVolumePopup,
            volumePopupPosition: volumePopupPosition.rawValue,
            coverSystemVolumePopup: coverSystemVolumePopup
        )
    }

    /// Restores only portable app-owned preferences. macOS permission grants
    /// and Launch at Login are intentionally excluded from the backup format.
    func restoreBackupSnapshot(
        _ snapshot: NotchSixtyBackupPreferences
    ) throws {
        try snapshot.validate()
        guard let appearance =
                ApplicationAppearanceMode(rawValue: snapshot.appearance),
              let presence =
                ApplicationPresenceMode(rawValue: snapshot.presence),
              let resolution =
                ApplicationVolumeStepResolution(
                    storedValue: snapshot.volumeStepResolution
                ) else {
            throw NotchSixtyBackupError.invalidPreferences
        }

        self.appearance = appearance
        self.presence = presence
        self.volumeStepResolution = resolution
        if let show = snapshot.showVolumeInMenuBar { showVolumeInMenuBar = show }
        if let show = snapshot.showVolumePopup { showVolumePopup = show }
        if let position = snapshot.volumePopupPosition.flatMap(
            VolumeFeedbackPopupPosition.init(rawValue:)
        ) {
            volumePopupPosition = position
        }
        if let cover = snapshot.coverSystemVolumePopup { coverSystemVolumePopup = cover }
    }

    private func applyAppearance() {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        applyApplicationIcon()
    }

    private func applyApplicationIcon() {
        let useDarkIcon: Bool
        switch appearance {
        case .light:
            useDarkIcon = false
        case .dark:
            useDarkIcon = true
        case .system:
            useDarkIcon = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let assetName = NSImage.Name(useDarkIcon ? "DockIconDark" : "DockIconLight")
        if let icon = NSImage(named: assetName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = presence == .tray ? .accessory : .regular
        _ = NSApplication.shared.setActivationPolicy(policy)
    }
}

private struct ProductionMenuBarView: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    @ObservedObject private var engine: AudioIOEngine
    @Environment(\.openWindow) private var openWindow
    @State private var commandError: String?

    init(product: ProductController) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        _engine = ObservedObject(wrappedValue: product.audioEngine)
    }

    private var presetSelection: Binding<UUID?> {
        Binding(
            get: { profiles.selectedContentPresetID },
            set: { id in
                guard let id else { return }
                Task { @MainActor in
                    do {
                        try await product.selectContentPreset(id)
                        commandError = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                }
            }
        )
    }

    private var processingActive: Bool {
        switch engine.lifecycleState {
        case .starting, .running, .reconfiguring, .recoveringOutput:
            return true
        default:
            return false
        }
    }

    private var canToggleProcessing: Bool {
        guard !product.recovery.safeLaunchActive else {
            return false
        }
        switch engine.lifecycleState {
        case .idle, .running, .reconfiguring, .recoveringOutput, .failed:
            return true
        default:
            return false
        }
    }

    private var processingBinding: Binding<Bool> {
        Binding(
            get: { processingActive },
            set: { enabled in
                Task { @MainActor in
                    await Task.yield()
                    if enabled {
                        if engine.lifecycleState == .failed { engine.stop() }
                        guard engine.lifecycleState == .idle else { return }
                        do {
                            try await product.startProcessing()
                            commandError = nil
                        } catch {
                            commandError = error.localizedDescription
                        }
                    } else {
                        engine.stop()
                        commandError = nil
                    }
                }
            }
        )
    }

    private var statusLabel: String {
        if product.recovery.safeLaunchActive {
            return "Safe Launch"
        }
        switch engine.lifecycleState {
        case .idle: return "Stopped"
        case .running: return "Processing"
        case .failed: return "Failed"
        case .requestingPermission: return "Requesting Permission"
        case .creatingTap, .creatingAggregate, .openingOutput, .starting: return "Starting"
        case .reconfiguring: return "Reconfiguring"
        case .recoveringOutput: return "Recovering Output"
        case .stopping: return "Stopping"
        }
    }

    private var statusSymbol: String {
        if product.recovery.safeLaunchActive {
            return "lifepreserver.fill"
        }
        switch engine.lifecycleState {
        case .running: return "waveform.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "stop.circle"
        default: return "arrow.triangle.2.circlepath.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOTCH SIXTY")
                        .font(.headline)
                    Label(statusLabel, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(
                            product.recovery.safeLaunchActive
                                ? .orange
                                : engine.lifecycleState == .failed
                                    ? .red
                                    : .secondary
                        )
                }
                Spacer(minLength: 16)
            }

            Divider()

            Toggle("Processing", isOn: processingBinding)
                .toggleStyle(.switch)
                .disabled(!canToggleProcessing)

            HStack(spacing: 8) {
                Label("Preset", systemImage: "music.note.list")
                    .fixedSize()

                Picker("", selection: presetSelection) {
                    ForEach(profiles.contentPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            if profiles.selectedContentPresetIsDirty {
                Text("Current preset has unsaved changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Notch Sixty", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(role: .destructive) {
                    product.shutdownForTermination()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.red)
                .help("Quit Notch Sixty")
            }
        }
        .padding(14)
        .frame(width: 300)
        .alert(
            "Processing Error",
            isPresented: Binding(
                get: { commandError != nil },
                set: { if !$0 { commandError = nil } }
            )
        ) {
            Button("OK") { commandError = nil }
        } message: {
            Text(commandError ?? "")
        }
    }
}

private struct ProductionSettingsView: View {
    @ObservedObject var preferences: ApplicationPreferences
    @ObservedObject var product: ProductController
    @ObservedObject var featureFlags: FeatureFlags
    @State private var backupMessage: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    @AppStorage(ProductionProfileToolbarPolicy.abComparisonEnabledKey)
    private var abComparisonEnabled = false

    @AppStorage(PreferenceKeys.Application.showDeveloperTools)
    private var showDeveloperTools = false

    private var diagnosticsReport: String {
        product.diagnosticsReport(
            version: version,
            build: build
        )
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }


    private func saveBackup() {
        let panel = NSSavePanel()
        panel.title = "Save Notch Sixty Backup"
        panel.prompt = "Save Backup"
        panel.nameFieldStringValue = "Notch-Sixty-Backup.n60backup"
        panel.allowedFileTypes = ["n60backup"]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try product.backup.exportData(
                preferences: preferences.makeBackupSnapshot(),
                appVersion: version,
                appBuild: build
            )
            try data.write(to: url, options: .atomic)
            let bundle = try product.backup.inspect(data)
            backupMessage =
                "Backup saved: \(bundle.profiles.contentPresets.count) presets · "
                + "\(bundle.profiles.systemProfiles.count) playback systems · "
                + "\(bundle.roomCorrectionProjects.count) room projects · "
                + "\(bundle.measurementLabSessions.count) lab sessions · "
                + "\(bundle.binauralAssets.count) binaural profiles."
        } catch {
            backupMessage =
                "Backup failed: \(error.localizedDescription)"
        }
    }

    private func restoreBackup() {
        guard product.audioEngine.lifecycleState == .idle else {
            backupMessage =
                "Stop audio processing before restoring a backup."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Restore Notch Sixty Backup"
        panel.prompt = "Review Backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["n60backup"]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let bundle = try product.backup.inspect(data)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Restore this Notch Sixty backup?"
            alert.informativeText =
                "This will replace saved Content Presets and Playback Systems "
                + "and restore \(bundle.roomCorrectionProjects.count) Room Correction "
                + "projects, \(bundle.measurementLabSessions.count) Measurement Lab "
                + "sessions, and \(bundle.binauralAssets.count) binaural profiles. "
                + "Hardware bindings that are not available on this Mac will be "
                + "marked Needs Mapping and cannot activate until reviewed."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }

            product.abComparison.clearAll()
            let restored = try product.backup.restore(data)
            try preferences.restoreBackupSnapshot(
                restored.preferences
            )
            product.roomCorrectionProjects.prepareForUse()

            var message =
                "Restore complete: \(restored.report.contentPresetCount) presets · "
                + "\(restored.report.playbackSystemCount) playback systems · "
                + "\(restored.report.roomCorrectionProjectCount) room projects · "
                + "\(restored.report.measurementLabSessionCount) lab sessions · "
                + "\(restored.report.binauralAssetCount) binaural profiles"
            if restored.report.hardwareMappingRequiredCount > 0 {
                message +=
                    " · \(restored.report.hardwareMappingRequiredCount) systems need hardware mapping"
            }
            backupMessage = message + "."
        } catch {
            backupMessage =
                "Restore failed: \(error.localizedDescription)"
        }
    }

    var body: some View {
        generalSettings
            .task {
                preferences.apply(to: product.audioEngine)
                preferences.refreshLaunchAtLoginStatus()
            }
            .navigationTitle("Settings")
            .frame(
                minWidth: 520,
                idealWidth: 560,
                minHeight: 520,
                idealHeight: 720
            )
    }

    private var generalSettings: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "About", systemImage: "info.circle") {
                        LabeledContent("Version") {
                            Text(version).monospacedDigit()
                        }
                        LabeledContent("Build") {
                            Text(build).monospacedDigit()
                        }
                    }

                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        HStack(spacing: 10) {
                            Text("Appearance")
                            Picker("", selection: $preferences.appearance) {
                                ForEach(ApplicationAppearanceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }

                    settingsCard(title: "Volume & Feedback", systemImage: "speaker.wave.2") {
                        HStack(spacing: 10) {
                            Text("Step size")
                            Spacer()
                            Picker("Volume key step size", selection: $preferences.volumeStepResolution) {
                                Section("Fraction of range") {
                                    ForEach(ApplicationVolumeStepResolution.fractions) { resolution in
                                        Text(resolution.displayName).tag(resolution)
                                    }
                                }
                                Section("Decibels") {
                                    ForEach(ApplicationVolumeStepResolution.decibelSteps) { resolution in
                                        Text(resolution.displayName).tag(resolution)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        Text("Controls Notch Sixty's software master-volume change for each intercepted volume-key press. Fractions move the slider by 1/16, 1/32 or 1/64 of its range. dB steps change the level by a fixed amount, down to −80 dB and then silence, and show the volume in dB (0 dB at full volume) in the menu bar and popup. The physical output-device volume is not stepped by this setting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Show volume in menu bar", isOn: $preferences.showVolumeInMenuBar)
                            .disabled(preferences.presence == .dock)
                        Text("Show Notch Sixty's master-volume percentage beside the tray icon. Requires Menu Bar or Both in App Presence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Show volume popup", isOn: $preferences.showVolumePopup)
                        HStack(spacing: 10) {
                            Text("Popup position")
                            Spacer()
                            Picker("Volume popup position", selection: $preferences.volumePopupPosition) {
                                ForEach(VolumeFeedbackPopupPosition.allCases) { position in
                                    Text(position.displayName).tag(position)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                        .disabled(!preferences.showVolumePopup)
                        Text("Briefly display Notch Sixty's volume when it changes. Follow macOS Popup appears beside the macOS volume indicator, at the top right or, while another app is full screen, the top centre. macOS gives sandboxed apps no public way to hide its indicator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Cover the macOS volume popup", isOn: $preferences.coverSystemVolumePopup)
                            .disabled(
                                !preferences.showVolumePopup
                                    || preferences.volumePopupPosition != .topRight
                            )
                        Text("Follow macOS Popup only. Draws Notch Sixty's popup over the macOS one, with a solid glass style so it does not show through. The macOS popup still appears underneath and may flash briefly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        HStack(spacing: 10) {
                            Text("Show Notch Sixty in")
                            Picker("", selection: $preferences.presence) {
                                ForEach(ApplicationPresenceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Presets", systemImage: "music.note.list") {
                        Toggle("Show A/B comparison in the toolbar", isOn: $abComparisonEnabled)
                        Text("Adds the A/B controls beside the Content Preset menu for capturing and auditioning two content-DSP states. While an A/B audition is running the controls stay visible until you exit it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Startup", systemImage: "power") {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { preferences.launchAtLoginEnabled },
                                set: { preferences.setLaunchAtLogin($0) }
                            )
                        )

                        LabeledContent("Status") {
                            Text(preferences.launchAtLoginStatusDescription)
                                .foregroundStyle(.secondary)
                        }

                        if let error = preferences.launchAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }

                        Text("Launch at Login is optional and does not automatically start audio processing. Processing remains an explicit user action in v1.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Permissions", systemImage: "lock.shield") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Audio")
                                .font(.subheadline.weight(.medium))
                            Text("Requested by macOS when processing needs system-audio capture.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Measurement Microphone")
                                .font(.subheadline.weight(.medium))
                            Text("Requested only when you start a microphone-based measurement or calibration workflow.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    settingsCard(
                        title: "Backup & Restore",
                        systemImage: "externaldrive.badge.timemachine"
                    ) {
                        HStack(spacing: 10) {
                            Button {
                                saveBackup()
                            } label: {
                                Label(
                                    "Save Backup…",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .buttonStyle(.glass)

                            Button {
                                restoreBackup()
                            } label: {
                                Label(
                                    "Restore Backup…",
                                    systemImage: "square.and.arrow.down"
                                )
                            }
                            .buttonStyle(.glass)
                            .disabled(
                                product.audioEngine.lifecycleState != .idle
                            )
                        }

                        Text(
                            "The .n60backup bundle includes saved presets and "
                            + "Playback Systems, Room Correction projects, "
                            + "Measurement Lab sessions, binaural profiles, "
                            + "and portable app preferences. Launch at Login, "
                            + "macOS permissions, and physical acceptance "
                            + "authority are never changed by restore."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(
                            "Restored hardware bindings are never silently "
                            + "reassigned. Systems that reference unavailable "
                            + "devices are marked Needs Mapping and remain "
                            + "blocked from activation until reviewed."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let backupMessage {
                            Text(backupMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    settingsCard(title: "Developer Tools", systemImage: "wrench.adjustable") {
                        Toggle("Show developer tools", isOn: $showDeveloperTools)
                        Text("Adds a Developer menu with Hardware Acceptance and Acoustic Research, the bench and research workspaces used to qualify a system.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    #if DEBUG
                    developerSettings
                    #endif

                    settingsCard(title: "Support", systemImage: "wrench.and.screwdriver") {
                        Button {
                            copyDiagnostics()
                        } label: {
                            Label("Copy Diagnostics", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)

                        Text("Copies app/build, macOS, audio device/rate, active preset/system, bypass state, and DSP latency. It does not include captured audio or room-measurement samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
    }

    #if DEBUG
    /// Debug builds only: switch unfinished features on for local testing.
    private var developerSettings: some View {
        settingsCard(title: "Developer", systemImage: "hammer") {
            if featureFlags.known.isEmpty {
                Text("No features are in development behind a flag.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(featureFlags.known) { flag in
                    Toggle(
                        "\(flag.title) (\(flag.epic))",
                        isOn: Binding(
                            get: { featureFlags.isEnabled(flag) },
                            set: { featureFlags.setEnabled($0, for: flag) }
                        )
                    )
                    .disabled(featureFlags.isForcedByLaunchArgument(flag))
                }
                Button("Reset to Defaults") { featureFlags.resetOverrides() }
                    .buttonStyle(.glass)
            }
            Text("Unfinished epics merge behind these flags, off by default. Release builds ignore these switches; testers can enable flags with the launch argument \(FeatureFlags.launchArgument) id1,id2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

}

private struct ProductionHelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Notch Sixty Help") {
            openWindow(id: ProductionReferenceNavigator.windowID)
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}

/// The Developer menu: bench and research workspaces kept out of the sidebar.
/// Shown only when the user has turned on "Show developer tools" in Settings.
private struct ProductionDeveloperCommands: Commands {
    @ObservedObject var navigation: ProductionNavigation
    @AppStorage(PreferenceKeys.Application.showDeveloperTools)
    private var showDeveloperTools = false

    var body: some Commands {
        if showDeveloperTools {
            CommandMenu("Developer") {
                ProductionDeveloperMenuItems(navigation: navigation)
            }
        }
    }
}

private struct ProductionDeveloperMenuItems: View {
    @ObservedObject var navigation: ProductionNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(ProductionSection.developerTools) { section in
            Button(section.title) {
                openWindow(id: "main")
                navigation.selection = section
            }
        }
    }
}

private final class NotchSixtyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension View {
    /// Notch Sixty uses switches, never checkboxes. Applied at each window's
    /// root; the style is inherited, so every Toggle below it, including
    /// those in Forms, renders as a switch without a per-call modifier.
    func productionToggleStyle() -> some View {
        toggleStyle(.switch)
    }

    /// Settings' rows are compact, so its switches are two sizes down.
    func productionCompactToggleStyle() -> some View {
        toggleStyle(CompactSwitchToggleStyle())
    }
}

private struct CompactSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

@main
struct NotchSixtyApp: App {
    @NSApplicationDelegateAdaptor(NotchSixtyAppDelegate.self) private var appDelegate
    @StateObject private var product: ProductController
    @StateObject private var preferences: ApplicationPreferences
    @StateObject private var featureFlags: FeatureFlags
    @StateObject private var navigation = ProductionNavigation()

    /// Held until the process exits; see `ProductInstanceLock`.
    private static var instanceLock: ProductInstanceLock?

    init() {
        Self.claimSingleInstance()
        _product = StateObject(wrappedValue: ProductController())
        _preferences = StateObject(wrappedValue: ApplicationPreferences())
        _featureFlags = StateObject(wrappedValue: FeatureFlags())
    }

    /// A second process (another copy of the app with the same bundle
    /// identifier, or a relaunch while one is still alive) hands focus to
    /// the running instance and exits before it creates any audio or
    /// recovery state. XCTest hosts are exempt and use in-memory recovery.
    private static func claimSingleInstance() {
        guard !ProductProcessEnvironment.isHostingTests else { return }
        switch ProductInstanceLock.acquire() {
        case .acquired(let lock):
            instanceLock = lock
        case .heldByAnotherInstance:
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let bundleID = Bundle.main.bundleIdentifier {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID)
                    .first { $0.processIdentifier != ownPID }?
                    .activate()
            }
            exit(EXIT_SUCCESS)
        case .unavailable:
            // Without the lock, fall back to the recovery record alone
            // rather than refusing to launch.
            break
        }
    }

    private var trayInserted: Binding<Bool> {
        Binding(
            get: { preferences.isTrayInserted },
            set: { preferences.setTrayInserted($0) }
        )
    }

    var body: some Scene {
        Window("Notch Sixty", id: "main") {
            ProductionRootView(product: product, navigation: navigation)
                .environmentObject(featureFlags)
                .productionToggleStyle()
                .task {
                    product.prepareForUse()
                    preferences.apply(to: product.audioEngine)
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            ProductionDeveloperCommands(navigation: navigation)
        }

        MenuBarExtra(isInserted: trayInserted) {
            ProductionMenuBarView(product: product)
                .environmentObject(featureFlags)
                .productionToggleStyle()
                .task {
                    product.prepareForUse()
                    preferences.apply(to: product.audioEngine)
                }
        } label: {
            MenuBarVolumeLabel(engine: product.audioEngine, preferences: preferences)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ProductionSettingsView(
                preferences: preferences,
                product: product,
                featureFlags: featureFlags
            )
            .productionCompactToggleStyle()
        }

        Window("Notch Sixty Help", id: ProductionReferenceNavigator.windowID) {
            ProductionHelpView(navigator: product.reference)
                .productionToggleStyle()
        }
        .defaultSize(width: 960, height: 720)
        .commands {
            CommandGroup(replacing: .help) {
                ProductionHelpMenuCommand()
            }
        }

        #if DEBUG
        Window("Engineering Validation", id: "engineering-validation") {
            EngineeringValidationView(engine: product.audioEngine)
                .productionToggleStyle()
                .task { product.prepareForUse() }
        }
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}
