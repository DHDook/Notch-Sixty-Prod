import Combine
import Foundation

enum SpeakerOptimizerCharacterizationControllerError: Error, Equatable, LocalizedError {
    case listeningBaselineRequired
    case listeningBaselineUnqualified
    case playbackSystemRequired
    case outputDeviceProfileRequired
    case playbackMustBeIdle(AudioLifecycleState)
    case microphonePermissionRequired
    case measurementInputRequired
    case outputRequired
    case noWholeSpeakerSources
    case sessionRequired
    case measurementAlreadyActive
    case measurementNotActive
    case transportBlocked(String)

    var errorDescription: String? {
        switch self {
        case .listeningBaselineRequired:
            return "Complete the Speaker Optimizer listening-position baseline before speaker characterization."
        case .listeningBaselineUnqualified:
            return "The listening-position baseline must be optimizer-ready before speaker characterization can be paired to it."
        case .playbackSystemRequired:
            return "Select a Playback System before speaker characterization."
        case .outputDeviceProfileRequired:
            return "Enable and configure an Output Device Profile before speaker characterization."
        case .playbackMustBeIdle(let state):
            return "Stop normal DSP playback before speaker characterization. The playback engine is currently \(state.rawValue)."
        case .microphonePermissionRequired:
            return "Microphone access is required before speaker characterization."
        case .measurementInputRequired:
            return "Select a measurement microphone before speaker characterization."
        case .outputRequired:
            return "Select the Playback System output before speaker characterization."
        case .noWholeSpeakerSources:
            return "The selected Playback System has no whole-speaker sources available for characterization."
        case .sessionRequired:
            return "Start or resume the paired speaker-characterization session first."
        case .measurementAlreadyActive:
            return "A speaker-characterization measurement is already active."
        case .measurementNotActive:
            return "No speaker-characterization measurement is active."
        case .transportBlocked(let reason):
            return "Speaker characterization is blocked: \(reason)"
        }
    }
}

extension SpeakerOptimizerCharacterizationSetStore {
    func currentURL(for playbackSystemID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(playbackSystemID.uuidString.lowercased())-baseline.json",
            isDirectory: false
        )
    }

    func saveCurrent(
        _ set: SpeakerOptimizerCharacterizationMeasurementSet
    ) throws {
        try set.validateStructure()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(set).write(
            to: currentURL(for: set.playbackSystemID),
            options: .atomic
        )
    }

    func loadCurrent(
        playbackSystemID: UUID
    ) throws -> SpeakerOptimizerCharacterizationMeasurementSet? {
        let path = currentURL(for: playbackSystemID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let set = try decoder.decode(
            SpeakerOptimizerCharacterizationMeasurementSet.self,
            from: Data(contentsOf: path)
        )
        guard set.playbackSystemID == playbackSystemID else {
            throw SpeakerOptimizerCharacterizationError
                .persistenceIdentityMismatch
        }
        try set.validateStructure()
        return set
    }

    func deleteCurrent(playbackSystemID: UUID) throws {
        let path = currentURL(for: playbackSystemID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }
        try FileManager.default.removeItem(at: path)
    }
}

struct SpeakerOptimizerCrossDomainSummary: Equatable, Sendable {
    var speakerPersistentPointCount: Int
    var roomSeatDependentPointCount: Int
    var ambiguousPointCount: Int
    var noMaterialDeviationPointCount: Int
    var sourceCount: Int

    init(report: SpeakerOptimizerCrossDomainReport) {
        let points = report.sources.flatMap(\.points)
        speakerPersistentPointCount = points.filter {
            $0.classification == .speakerPersistent
        }.count
        roomSeatDependentPointCount = points.filter {
            $0.classification == .roomSeatDependent
        }.count
        ambiguousPointCount = points.filter {
            $0.classification == .ambiguous
        }.count
        noMaterialDeviationPointCount = points.filter {
            $0.classification == .noMaterialDeviation
        }.count
        sourceCount = report.sources.count
    }
}

/// Guided whole-speaker characterization controller.
///
/// It deliberately reuses the same safe targeted calibration transport as the
/// listening-position campaign. The distinctive step is after deconvolution:
/// early-window evidence is derived from the in-memory impulse BEFORE compact
/// persistence discards the raw/impulse buffers.
@MainActor
final class SpeakerOptimizerCharacterizationController: ObservableObject {
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    private let store: SpeakerOptimizerCharacterizationSetStore
    private let transportFactory: MultichannelCalibrationTransportFactory
    private let analysisOperation: MultichannelCalibrationAnalysisOperation
    private let planner = SpeakerOptimizerMeasurementTransportPlanner()
    private let evaluator = SpeakerOptimizerCharacterizationEvidenceEvaluator()
    private let captureBuilder = SpeakerOptimizerCharacterizationCaptureBuilder()
    private let sweepGenerator = RoomCorrectionSweepGenerator()
    private let orchestrator: SpeakerOptimizerCharacterizationSessionOrchestrator

    private var activeTransport: (any MultichannelCalibrationTransporting)?
    private var activeProgram: RoomCorrectionSweepProgram?
    private var activeStep: SpeakerOptimizerCharacterizationSessionStep?
    private var activeTransportPlan: SpeakerOptimizerMeasurementTransportPlan?
    private var analysisGeneration: UInt64 = 0

    @Published private(set) var state:
        SpeakerOptimizerMeasurementControllerState = .idle
    @Published private(set) var measurementSet:
        SpeakerOptimizerCharacterizationMeasurementSet?
    @Published private(set) var evidenceReport:
        SpeakerOptimizerCharacterizationEvidenceReport?
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        store: SpeakerOptimizerCharacterizationSetStore =
            SpeakerOptimizerCharacterizationSetStore(),
        transportFactory: @escaping MultichannelCalibrationTransportFactory = {
            routePlan, outputs, input, inputChannel, program, physicalOutput in
            try MultichannelCalibrationTransport(
                routePlan: routePlan,
                availableOutputs: outputs,
                input: input,
                inputChannelIndex: inputChannel,
                program: program,
                physicalOutputChannelIndex: physicalOutput
            )
        },
        analysisOperation: @escaping MultichannelCalibrationAnalysisOperation = {
            capture, program, microphoneCalibration in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(
                    rawCapture: capture.samples,
                    program: program,
                    microphoneCalibration: microphoneCalibration
                )
            }.value
        }
    ) throws {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.store = store
        self.transportFactory = transportFactory
        self.analysisOperation = analysisOperation
        self.orchestrator =
            try SpeakerOptimizerCharacterizationSessionOrchestrator()
    }

    var progress: SpeakerOptimizerCharacterizationProgress? {
        guard let measurementSet else { return nil }
        return try? orchestrator.progress(for: measurementSet)
    }

    var nextStep: SpeakerOptimizerCharacterizationSessionStep? {
        guard let measurementSet else { return nil }
        return try? orchestrator.nextPendingStep(for: measurementSet)
    }

    var activeOrNextStep: SpeakerOptimizerCharacterizationSessionStep? {
        activeStep ?? nextStep
    }

    var activeMeasurementProgress: Double {
        guard let snapshot = activeTransport?.snapshot(),
              snapshot.totalFrameCount > 0 else {
            return 0
        }
        return min(
            max(
                Double(snapshot.frameCursor)
                    / Double(snapshot.totalFrameCount),
                0
            ),
            1
        )
    }

    var earlyWindowEvidenceComplete: Bool {
        guard let measurementSet else { return false }
        let evidence = measurementSet.earlyWindowEvidence ?? []
        return !measurementSet.captures.isEmpty
            && evidence.count == measurementSet.captures.count
            && Set(evidence.map(\.captureID))
                == Set(measurementSet.captures.map(\.id))
    }

    var characterizationReady: Bool {
        progress?.complete == true
            && evidenceReport?.optimizerReady == true
            && earlyWindowEvidenceComplete
    }

    var canBeginMeasurement: Bool {
        guard state == .ready || state == .reviewing,
              measurementSet != nil,
              nextStep != nil else {
            return false
        }
        return engine.lifecycleState == .idle
            && microphone.permissionStatus == .authorized
            && microphone.selectedInputDevice != nil
            && engine.selectedOutputDevice != nil
            && activeTransport == nil
    }

    func startOrResumeSession(
        listeningBaseline: SpeakerOptimizerMeasurementSet
    ) throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerCharacterizationControllerError
                .measurementAlreadyActive
        }
        let listeningEvidence =
            try SpeakerOptimizerMeasurementEvidenceEvaluator()
                .evaluate(listeningBaseline)
        guard listeningBaseline.role == .baseline else {
            throw SpeakerOptimizerCharacterizationControllerError
                .listeningBaselineRequired
        }
        guard listeningEvidence.optimizerReady else {
            throw SpeakerOptimizerCharacterizationControllerError
                .listeningBaselineUnqualified
        }
        guard let systemID = profiles.selectedSystemProfileID,
              systemID == listeningBaseline.playbackSystemID else {
            throw SpeakerOptimizerCharacterizationControllerError
                .playbackSystemRequired
        }
        guard let systemProfile = profiles.selectedSystemProfile,
              let profile = systemProfile.state.outputDeviceProfile,
              profile.enabled else {
            throw SpeakerOptimizerCharacterizationControllerError
                .outputDeviceProfileRequired
        }
        guard let output = engine.selectedOutputDevice else {
            throw SpeakerOptimizerCharacterizationControllerError.outputRequired
        }
        guard microphone.permissionStatus == .authorized else {
            throw SpeakerOptimizerCharacterizationControllerError
                .microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw SpeakerOptimizerCharacterizationControllerError
                .measurementInputRequired
        }

        let sources = Self.sources(for: profile)
        guard !sources.isEmpty else {
            throw SpeakerOptimizerCharacterizationControllerError
                .noWholeSpeakerSources
        }
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: input.uid,
            inputChannelIndex: microphone.selectedInputChannelIndex,
            calibrationFingerprint:
                microphone.microphoneCalibration?.sourceName
        )
        let signature = profile.multichannelCalibrationRoutingSignature
        let sampleRate = output.nominalSampleRate
        guard listeningBaseline.routingSignature == signature,
              listeningBaseline.microphone == mic,
              abs(listeningBaseline.sampleRate - sampleRate) < 0.5 else {
            throw SpeakerOptimizerCharacterizationControllerError
                .listeningBaselineRequired
        }

        if let stored = try store.loadCurrent(playbackSystemID: systemID),
           stored.routingSignature == signature,
           stored.microphone == mic,
           abs(stored.sampleRate - sampleRate) < 0.5,
           stored.linkedListeningMeasurementSetID == listeningBaseline.id,
           stored.targets.map(\.source) == sources {
            measurementSet = stored
        } else {
            let targets = sources.map {
                SpeakerOptimizerCharacterizationTarget(
                    source: $0,
                    geometry: SpeakerOptimizerCharacterizationGeometry()
                )
            }
            let fresh = SpeakerOptimizerCharacterizationMeasurementSet(
                role: .baseline,
                playbackSystemID: systemID,
                routingSignature: signature,
                microphone: mic,
                sampleRate: sampleRate,
                linkedListeningMeasurementSetID: listeningBaseline.id,
                targets: targets,
                captures: [],
                earlyWindowEvidence: [],
                createdAt: Date(),
                modifiedAt: Date()
            )
            try fresh.validateCompatibility(with: listeningBaseline)
            try store.saveCurrent(fresh)
            measurementSet = fresh
        }

        try refreshDerivedState()
        lastErrorDescription = nil
    }

    func beginNextMeasurement() throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerCharacterizationControllerError
                .measurementAlreadyActive
        }
        guard engine.lifecycleState == .idle else {
            throw SpeakerOptimizerCharacterizationControllerError
                .playbackMustBeIdle(engine.lifecycleState)
        }
        guard microphone.permissionStatus == .authorized else {
            throw SpeakerOptimizerCharacterizationControllerError
                .microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw SpeakerOptimizerCharacterizationControllerError
                .measurementInputRequired
        }
        guard let output = engine.selectedOutputDevice,
              let selectedOutputUID =
                engine.routeConfiguration.selectedOutputUID else {
            throw SpeakerOptimizerCharacterizationControllerError.outputRequired
        }
        guard let systemProfile = profiles.selectedSystemProfile,
              let profile = systemProfile.state.outputDeviceProfile,
              profile.enabled else {
            throw SpeakerOptimizerCharacterizationControllerError
                .outputDeviceProfileRequired
        }
        guard let set = measurementSet,
              let step = try orchestrator.nextPendingStep(for: set) else {
            throw SpeakerOptimizerCharacterizationControllerError.sessionRequired
        }

        let routePlan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: selectedOutputUID,
            bassManagementEnabled: systemProfile.state.bassManagement.enabled
        )
        let plan = planner.plan(
            target: .acousticSource(step.target.source),
            routePlan: routePlan,
            multiOutputRouting: systemProfile.state.outputRouting,
            speakerDriverProcessing:
                systemProfile.state.speakerDriverProcessing
        )
        activeTransportPlan = plan
        guard plan.canStartMeasurement,
              let physicalOutput = plan.physicalOutputChannelIndex else {
            state = .blocked
            let reason = plan.blockReason?.message
                ?? "the measurement transport safety contract was not satisfied"
            let error =
                SpeakerOptimizerCharacterizationControllerError
                    .transportBlocked(reason)
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let settings = RoomCorrectionSweepSettings(
            sampleRate: output.nominalSampleRate,
            startFrequencyHz: microphone.sweepStartFrequencyHz,
            endFrequencyHz: microphone.sweepEndFrequencyHz,
            durationSeconds: microphone.sweepDurationSeconds,
            levelDBFS: microphone.sweepLevelDBFS,
            leadInSeconds: microphone.sweepLeadInSeconds,
            tailSeconds: microphone.sweepTailSeconds,
            fadeSeconds: microphone.sweepFadeSeconds
        )
        let program = try sweepGenerator.makeProgram(settings: settings)
        let transport = try transportFactory(
            routePlan,
            engine.outputDevices,
            input,
            microphone.selectedInputChannelIndex,
            program,
            physicalOutput
        )

        analysisGeneration &+= 1
        activeTransport = transport
        activeProgram = program
        activeStep = step
        do {
            try transport.start()
            state = .measuring
            lastErrorDescription = nil
        } catch {
            transport.cancel()
            clearActiveMeasurement()
            recordFailure(error)
            throw error
        }
    }

    @discardableResult
    func finishMeasurementIfComplete() async throws -> Bool {
        guard state == .measuring,
              let transport = activeTransport else {
            return false
        }
        guard transport.snapshot()?.complete == true else {
            return false
        }

        let capture: MultichannelCalibrationCapture
        do {
            capture = try transport.finishAndMaterialize()
        } catch {
            clearActiveMeasurement()
            recordFailure(error)
            throw error
        }
        activeTransport = nil

        guard let program = activeProgram,
              let step = activeStep,
              var set = measurementSet else {
            clearActiveMeasurement()
            let error =
                SpeakerOptimizerCharacterizationControllerError
                    .measurementNotActive
            recordFailure(error)
            throw error
        }
        activeProgram = nil
        state = .analyzing
        let generation = analysisGeneration

        do {
            let analyzed = try await analysisOperation(
                capture,
                program,
                microphone.microphoneCalibration
            )
            guard generation == analysisGeneration,
                  state == .analyzing else {
                return false
            }

            let measurement = MultichannelCalibrationMeasurement(
                seatID: step.target.id,
                source: step.target.source,
                sampleRate: program.sampleRate,
                channel: analyzed
            )
            let built = try captureBuilder.build(
                measurement: measurement,
                playbackSystemID: set.playbackSystemID,
                routingSignature: set.routingSignature,
                microphone: set.microphone,
                target: step.target,
                microphoneCalibration: microphone.microphoneCalibration
            )
            set = try orchestrator.appending(
                built.capture,
                to: set,
                for: step
            )
            set = try set.attachingEarlyWindowEvidence(
                built.earlyWindow
            )
            measurementSet = set
            try store.saveCurrent(set)
            activeStep = nil
            activeTransportPlan = nil
            try refreshDerivedState()
            lastErrorDescription = nil
            return true
        } catch {
            activeStep = nil
            activeTransportPlan = nil
            recordFailure(error)
            throw error
        }
    }

    func cancelMeasurement() {
        analysisGeneration &+= 1
        activeTransport?.cancel()
        clearActiveMeasurement()
        do {
            try refreshDerivedState()
        } catch {
            recordFailure(error)
        }
    }

    func retryLatestCapture(targetID: UUID) throws {
        guard activeTransport == nil,
              let set = measurementSet else {
            throw SpeakerOptimizerCharacterizationControllerError
                .sessionRequired
        }
        let updated = try orchestrator.retryLatestCapture(
            in: set,
            targetID: targetID
        )
        measurementSet = updated
        try store.saveCurrent(updated)
        try refreshDerivedState()
    }

    func resetSession(
        listeningBaseline: SpeakerOptimizerMeasurementSet
    ) throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerCharacterizationControllerError
                .measurementAlreadyActive
        }
        if let systemID = profiles.selectedSystemProfileID {
            try store.deleteCurrent(playbackSystemID: systemID)
        }
        measurementSet = nil
        evidenceReport = nil
        state = .idle
        try startOrResumeSession(listeningBaseline: listeningBaseline)
    }

    private func refreshDerivedState() throws {
        guard let set = measurementSet else {
            evidenceReport = nil
            state = .idle
            return
        }
        evidenceReport = try evaluator.evaluate(set)
        let progress = try orchestrator.progress(for: set)
        state = progress.complete ? .reviewing : .ready
    }

    private func clearActiveMeasurement() {
        activeTransport = nil
        activeProgram = nil
        activeStep = nil
        activeTransportPlan = nil
    }

    private func recordFailure(_ error: Error) {
        activeTransport?.cancel()
        clearActiveMeasurement()
        state = .failed
        lastErrorDescription = error.localizedDescription
    }

    private static func sources(
        for profile: OutputDeviceProfileConfiguration
    ) -> [MultichannelCalibrationSource] {
        profile.programLayout.roles
            .filter { $0 != .lowFrequencyEffects }
            .map(MultichannelCalibrationSource.speaker)
    }
}
