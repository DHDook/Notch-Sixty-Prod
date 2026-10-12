import Combine
import Foundation

typealias SpeakerMeasurementLabProtectedTransportFactory = (
    LiveNChannelOutputRoutePlan,
    [AudioOutputDevice],
    AudioInputDevice,
    Int,
    RoomCorrectionSweepProgram,
    UInt32,
    [Float]
) throws -> any MultichannelCalibrationTransporting

enum SpeakerMeasurementLabControllerError:
    Error, Equatable, LocalizedError {
    case playbackSystemRequired
    case outputDeviceProfileRequired
    case playbackMustBeIdle(AudioLifecycleState)
    case microphonePermissionRequired
    case measurementInputRequired
    case outputRequired
    case protocolsRequired
    case sessionRequired
    case sessionEnvironmentChanged
    case measurementAlreadyActive
    case measurementNotActive
    case transportBlocked(String)

    var errorDescription: String? {
        switch self {
        case .playbackSystemRequired:
            return "Select a Playback System before starting the Advanced Speaker Measurement Lab."
        case .outputDeviceProfileRequired:
            return "Enable and configure an Output Device Profile before starting the Advanced Speaker Measurement Lab."
        case .playbackMustBeIdle(let state):
            return "Stop normal DSP playback before a lab sweep. The playback engine is currently \(state.rawValue)."
        case .microphonePermissionRequired:
            return "Microphone access is required before an Advanced Speaker Measurement Lab sweep."
        case .measurementInputRequired:
            return "Select a measurement microphone before starting the lab."
        case .outputRequired:
            return "Select the commissioned Playback System output before starting the lab."
        case .protocolsRequired:
            return "Add at least one supported lab measurement protocol."
        case .sessionRequired:
            return "Start or resume an Advanced Speaker Measurement Lab session first."
        case .sessionEnvironmentChanged:
            return "Playback System, physical routing, microphone identity, or sample rate changed after this lab session was created."
        case .measurementAlreadyActive:
            return "An Advanced Speaker Measurement Lab sweep is already active."
        case .measurementNotActive:
            return "No Advanced Speaker Measurement Lab sweep is active."
        case .transportBlocked(let reason):
            return "Advanced Speaker Measurement Lab sweep is blocked: \(reason)"
        }
    }
}

/// Live acquisition bridge for PR106 safe lab modes.
///
/// This controller deliberately reuses MultichannelCalibrationTransport and
/// RoomCorrectionMeasurementAnalyzer. Before EVERY sweep it re-runs the PR106
/// capability planner against the current Playback System state. A protocol
/// that was safe when persisted therefore cannot bypass a later active
/// crossover or limiter configuration.
@MainActor
final class SpeakerMeasurementLabController: ObservableObject {
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    private let store: SpeakerMeasurementLabSessionStore
    private let transportFactory: MultichannelCalibrationTransportFactory
    private let protectedTransportFactory:
        SpeakerMeasurementLabProtectedTransportFactory
    private let analysisOperation: MultichannelCalibrationAnalysisOperation
    private let capabilityPlanner =
        SpeakerMeasurementLabCapabilityPlanner()
    private let captureBuilder = SpeakerMeasurementLabCaptureBuilder()
    private let orchestrator = SpeakerMeasurementLabSessionOrchestrator()
    private let sweepGenerator = RoomCorrectionSweepGenerator()
    private let protectedExcitationCompiler =
        SpeakerMeasurementLabProtectedExcitationCompiler()
    private let protectedRoutePlanner =
        SpeakerMeasurementLabProtectedDriverRoutePlanner()

    private var activeTransport:
        (any MultichannelCalibrationTransporting)?
    private var activeProgram: RoomCorrectionSweepProgram?
    private var activeStep: SpeakerMeasurementLabSessionStep?
    private var activeProtectedProvenance:
        SpeakerMeasurementLabProtectedDriverCaptureProvenance?
    private var analysisGeneration: UInt64 = 0

    @Published private(set) var state:
        SpeakerOptimizerMeasurementControllerState = .idle
    @Published private(set) var session: SpeakerMeasurementLabSession?
    @Published private(set) var activeCapabilityPlan:
        SpeakerMeasurementLabPlan?
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        store: SpeakerMeasurementLabSessionStore =
            SpeakerMeasurementLabSessionStore(),
        transportFactory:
            @escaping MultichannelCalibrationTransportFactory = {
                routePlan, outputs, input, inputChannel,
                program, physicalOutput in
                try MultichannelCalibrationTransport(
                    routePlan: routePlan,
                    availableOutputs: outputs,
                    input: input,
                    inputChannelIndex: inputChannel,
                    program: program,
                    physicalOutputChannelIndex: physicalOutput
                )
            },
        protectedTransportFactory:
            @escaping SpeakerMeasurementLabProtectedTransportFactory = {
                routePlan, outputs, input, inputChannel,
                program, physicalOutput, outputSamples in
                try MultichannelCalibrationTransport(
                    routePlan: routePlan,
                    availableOutputs: outputs,
                    input: input,
                    inputChannelIndex: inputChannel,
                    program: program,
                    physicalOutputChannelIndex: physicalOutput,
                    outputSweepSamples: outputSamples
                )
            },
        analysisOperation:
            @escaping MultichannelCalibrationAnalysisOperation = {
                capture, program, microphoneCalibration in
                try await Task.detached(priority: .userInitiated) {
                    try RoomCorrectionMeasurementAnalyzer()
                        .analyzeSingleChannel(
                            rawCapture: capture.samples,
                            program: program,
                            microphoneCalibration:
                                microphoneCalibration
                        )
                }.value
            }
    ) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.store = store
        self.transportFactory = transportFactory
        self.protectedTransportFactory = protectedTransportFactory
        self.analysisOperation = analysisOperation
    }

    var progress: SpeakerMeasurementLabSessionProgress? {
        guard let session else { return nil }
        return try? orchestrator.progress(for: session)
    }

    var nextStep: SpeakerMeasurementLabSessionStep? {
        guard let session else { return nil }
        return try? orchestrator.nextPendingStep(for: session)
    }

    var activeOrNextStep: SpeakerMeasurementLabSessionStep? {
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

    var canBeginMeasurement: Bool {
        guard state == .ready || state == .reviewing,
              session != nil,
              nextStep != nil else {
            return false
        }
        return engine.lifecycleState == .idle
            && microphone.permissionStatus == .authorized
            && microphone.selectedInputDevice != nil
            && engine.selectedOutputDevice != nil
            && activeTransport == nil
    }

    func startNewSession(
        protocols: [SpeakerMeasurementLabProtocol],
        sharedClockReferenceConfiguration:
            SpeakerMeasurementLabSharedClockReferenceConfiguration? = nil,
        createdAt: Date = Date()
    ) throws {
        guard activeTransport == nil else {
            throw SpeakerMeasurementLabControllerError
                .measurementAlreadyActive
        }
        guard !protocols.isEmpty else {
            throw SpeakerMeasurementLabControllerError.protocolsRequired
        }
        for labProtocol in protocols {
            try labProtocol.validateForAcquisition()
        }

        guard let systemID = profiles.selectedSystemProfileID else {
            throw SpeakerMeasurementLabControllerError
                .playbackSystemRequired
        }
        guard let systemProfile = profiles.selectedSystemProfile,
              let profile =
                systemProfile.state.outputDeviceProfile,
              profile.enabled else {
            throw SpeakerMeasurementLabControllerError
                .outputDeviceProfileRequired
        }
        guard let output = engine.selectedOutputDevice else {
            throw SpeakerMeasurementLabControllerError.outputRequired
        }
        guard microphone.permissionStatus == .authorized else {
            throw SpeakerMeasurementLabControllerError
                .microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw SpeakerMeasurementLabControllerError
                .measurementInputRequired
        }

        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: input.uid,
            inputChannelIndex:
                microphone.selectedInputChannelIndex,
            calibrationFingerprint:
                microphone.microphoneCalibration?.sourceName
        )
        let fresh = SpeakerMeasurementLabSession(
            playbackSystemID: systemID,
            routingSignature:
                profile.multichannelCalibrationRoutingSignature,
            microphone: mic,
            microphoneCalibration: microphone.microphoneCalibration,
            sharedClockReferenceConfiguration:
                sharedClockReferenceConfiguration,
            sampleRate: output.nominalSampleRate,
            protocols: protocols,
            captures: [],
            createdAt: createdAt,
            modifiedAt: createdAt
        )
        try fresh.validateStructure()
        try store.save(fresh)
        session = fresh
        activeCapabilityPlan = nil
        state = .ready
        lastErrorDescription = nil
    }

    func resumeSession(_ sessionID: UUID) throws {
        guard activeTransport == nil else {
            throw SpeakerMeasurementLabControllerError
                .measurementAlreadyActive
        }
        guard let stored = try store.load(sessionID) else {
            throw SpeakerMeasurementLabControllerError.sessionRequired
        }
        try validateCurrentEnvironment(for: stored)
        session = stored
        activeCapabilityPlan = nil
        state = try orchestrator.progress(for: stored).complete
            ? .reviewing : .ready
        lastErrorDescription = nil
    }

    func beginNextMeasurement() throws {
        guard activeTransport == nil else {
            throw SpeakerMeasurementLabControllerError
                .measurementAlreadyActive
        }
        guard engine.lifecycleState == .idle else {
            throw SpeakerMeasurementLabControllerError
                .playbackMustBeIdle(engine.lifecycleState)
        }
        guard microphone.permissionStatus == .authorized else {
            throw SpeakerMeasurementLabControllerError
                .microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw SpeakerMeasurementLabControllerError
                .measurementInputRequired
        }
        guard let output = engine.selectedOutputDevice,
              let selectedOutputUID =
                engine.routeConfiguration.selectedOutputUID else {
            throw SpeakerMeasurementLabControllerError.outputRequired
        }
        guard let systemProfile = profiles.selectedSystemProfile,
              let profile =
                systemProfile.state.outputDeviceProfile,
              profile.enabled else {
            throw SpeakerMeasurementLabControllerError
                .outputDeviceProfileRequired
        }
        guard let session,
              let step = try orchestrator.nextPendingStep(
                  for: session
              ) else {
            throw SpeakerMeasurementLabControllerError.sessionRequired
        }
        try validateCurrentEnvironment(for: session)

        let routePlan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: selectedOutputUID,
            bassManagementEnabled:
                systemProfile.state.bassManagement.enabled
        )
        let capability = try capabilityPlanner.plan(
            step.labProtocol.request,
            routePlan: routePlan,
            multiOutputRouting: systemProfile.state.outputRouting,
            speakerDriverProcessing:
                systemProfile.state.speakerDriverProcessing,
            bassManagementConfiguration:
                systemProfile.state.bassManagement
        )
        activeCapabilityPlan = capability
        guard capability.canStartMeasurement else {
            state = .blocked
            let reason = capability.blockReasons
                .map(\.message)
                .joined(separator: " ")
            let error = SpeakerMeasurementLabControllerError
                .transportBlocked(
                    reason.isEmpty
                        ? "the measurement safety contract was not satisfied"
                        : reason
                )
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let settings = RoomCorrectionSweepSettings(
            sampleRate: output.nominalSampleRate,
            startFrequencyHz: microphone.sweepStartFrequencyHz,
            endFrequencyHz: microphone.sweepEndFrequencyHz,
            durationSeconds: microphone.sweepDurationSeconds,
            levelDBFS: step.labProtocol.resolvedExcitationLevelDBFS(
                default: microphone.sweepLevelDBFS
            ),
            leadInSeconds: microphone.sweepLeadInSeconds,
            tailSeconds: microphone.sweepTailSeconds,
            fadeSeconds: microphone.sweepFadeSeconds
        )
        let program = try sweepGenerator.makeProgram(
            settings: settings
        )

        let transport: any MultichannelCalibrationTransporting
        let analysisProgram: RoomCorrectionSweepProgram
        var protectedProvenance:
            SpeakerMeasurementLabProtectedDriverCaptureProvenance? = nil

        if let targetBus = capability.protectedDriverBus {
            guard let routing = systemProfile.state.outputRouting,
                  let driverProcessing =
                    systemProfile.state.speakerDriverProcessing else {
                throw SpeakerMeasurementLabControllerError
                    .transportBlocked(
                        "Protected-driver crossover routing and limiter processing are required."
                    )
            }
            let excitation = try protectedExcitationCompiler.compile(
                monoSamples: program.sweepSamples,
                sampleRate: program.sampleRate,
                targetBus: targetBus,
                bassManagement: systemProfile.state.bassManagement,
                driverProcessing: driverProcessing
            )
            let binding = try protectedRoutePlanner.plan(
                targetBus: targetBus,
                routing: routing,
                bassManagement: systemProfile.state.bassManagement,
                driverProcessing: driverProcessing,
                availableOutputs: engine.outputDevices,
                sampleRate: output.nominalSampleRate,
                selectedOutputUID: selectedOutputUID
            )
            protectedProvenance = try excitation
                .makeCaptureProvenance(binding: binding)
            analysisProgram = try excitation.makeAnalysisProgram(
                from: program
            )
            transport = try protectedTransportFactory(
                binding.carrierRoutePlan,
                engine.outputDevices,
                input,
                microphone.selectedInputChannelIndex,
                program,
                binding.physicalOutputChannelIndex,
                excitation.renderedSamples
            )

            // Re-read the selected Playback System immediately before hardware
            // start. A route/crossover/limiter change after compilation must
            // cancel rather than play a stale protected waveform.
            try validateProtectedStateImmediatelyBeforeStart(
                session: session,
                binding: binding,
                excitation: excitation
            )
        } else {
            guard capability.delegatedTransportPlans.count == 1,
                  let physicalOutput =
                    capability.delegatedTransportPlans[0]
                        .physicalOutputChannelIndex else {
                throw SpeakerMeasurementLabControllerError
                    .transportBlocked(
                        "Ordinary Lab acquisition did not resolve one safe physical output."
                    )
            }
            analysisProgram = program
            if let reference =
                    session.sharedClockReferenceConfiguration {
                guard reference.inputDeviceUID == input.uid,
                      reference.outputReferenceDeviceUID
                        == routePlan.referenceDeviceUID else {
                    throw SpeakerMeasurementLabControllerError
                        .sessionEnvironmentChanged
                }
                transport = try MultichannelCalibrationTransport(
                    routePlan: routePlan,
                    availableOutputs: engine.outputDevices,
                    input: input,
                    inputChannelIndex:
                        microphone.selectedInputChannelIndex,
                    referenceInputChannelIndex:
                        reference.inputChannelIndex,
                    program: program,
                    physicalOutputChannelIndex: physicalOutput
                )
            } else {
                transport = try transportFactory(
                    routePlan,
                    engine.outputDevices,
                    input,
                    microphone.selectedInputChannelIndex,
                    program,
                    physicalOutput
                )
            }
        }

        analysisGeneration &+= 1
        activeTransport = transport
        activeProgram = analysisProgram
        activeProtectedProvenance = protectedProvenance
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

        let materialized: MultichannelCalibrationCapture
        do {
            materialized = try transport.finishAndMaterialize()
        } catch {
            clearActiveMeasurement()
            recordFailure(error)
            throw error
        }
        activeTransport = nil

        guard let program = activeProgram,
              let step = activeStep,
              var session else {
            clearActiveMeasurement()
            let error = SpeakerMeasurementLabControllerError
                .measurementNotActive
            recordFailure(error)
            throw error
        }
        activeProgram = nil
        state = .analyzing
        let generation = analysisGeneration

        do {
            let analyzed = try await analysisOperation(
                materialized,
                program,
                microphone.microphoneCalibration
            )
            guard generation == analysisGeneration,
                  state == .analyzing else {
                return false
            }

            var referenceEvidence:
                SpeakerMeasurementLabSharedClockReferenceEvidence? = nil
            if let referenceSamples = materialized.referenceSamples,
               let referenceConfiguration =
                    session.sharedClockReferenceConfiguration {
                let referenceAnalyzed =
                    try RoomCorrectionMeasurementAnalyzer()
                        .analyzeSingleChannel(
                            rawCapture: referenceSamples,
                            program: program,
                            microphoneCalibration: nil
                        )
                referenceEvidence =
                    try SpeakerMeasurementLabSharedClockReferenceEvaluator()
                        .build(
                            analyzed: referenceAnalyzed,
                            configuration: referenceConfiguration,
                            microphone: session.microphone,
                            sampleRate: session.sampleRate
                        )
            } else if session.sharedClockReferenceConfiguration != nil {
                throw SpeakerMeasurementLabSessionError
                    .sharedClockReferenceUnqualified
            }

            let capture = try captureBuilder.build(
                analyzed: analyzed,
                session: session,
                step: step,
                excitationLevelDBFS: program.settings.levelDBFS,
                protectedDriverProvenance:
                    activeProtectedProvenance,
                sharedClockReference: referenceEvidence
            )
            session = try orchestrator.appending(
                capture,
                to: session,
                for: step
            )
            self.session = session
            try store.save(session)
            activeStep = nil
            activeCapabilityPlan = nil
            activeProtectedProvenance = nil
            state = try orchestrator.progress(for: session).complete
                ? .reviewing : .ready
            lastErrorDescription = nil
            return true
        } catch {
            activeStep = nil
            activeCapabilityPlan = nil
            recordFailure(error)
            throw error
        }
    }

    func cancelMeasurement() {
        analysisGeneration &+= 1
        activeTransport?.cancel()
        clearActiveMeasurement()
        if let session {
            state = (try? orchestrator.progress(for: session).complete)
                == true ? .reviewing : .ready
        } else {
            state = .idle
        }
    }

    func retryLatestCapture(protocolID: UUID) throws {
        guard activeTransport == nil,
              let session else {
            throw SpeakerMeasurementLabControllerError.sessionRequired
        }
        let updated = try orchestrator.retryLatestCapture(
            in: session,
            protocolID: protocolID
        )
        self.session = updated
        try store.save(updated)
        state = .ready
        lastErrorDescription = nil
    }

    private func validateCurrentEnvironment(
        for session: SpeakerMeasurementLabSession
    ) throws {
        guard profiles.selectedSystemProfileID
                == session.playbackSystemID,
              let systemProfile = profiles.selectedSystemProfile,
              let profile =
                systemProfile.state.outputDeviceProfile,
              profile.enabled,
              profile.multichannelCalibrationRoutingSignature
                == session.routingSignature,
              let output = engine.selectedOutputDevice,
              abs(output.nominalSampleRate - session.sampleRate)
                < 0.5,
              let input = microphone.selectedInputDevice else {
            throw SpeakerMeasurementLabControllerError
                .sessionEnvironmentChanged
        }

        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: input.uid,
            inputChannelIndex:
                microphone.selectedInputChannelIndex,
            calibrationFingerprint:
                microphone.microphoneCalibration?.sourceName
        )
        guard mic == session.microphone else {
            throw SpeakerMeasurementLabControllerError
                .sessionEnvironmentChanged
        }
    }

    private func validateProtectedStateImmediatelyBeforeStart(
        session: SpeakerMeasurementLabSession,
        binding: SpeakerMeasurementLabProtectedDriverRouteBinding,
        excitation: SpeakerMeasurementLabProtectedExcitation
    ) throws {
        guard profiles.selectedSystemProfileID
                == session.playbackSystemID,
              let current = profiles.selectedSystemProfile,
              current.state.outputRouting
                == binding.routingConfiguration,
              current.state.bassManagement
                == excitation.bassManagementConfiguration,
              current.state.speakerDriverProcessing
                == excitation.driverProcessingConfiguration,
              engine.routeConfiguration.selectedOutputUID
                == binding.carrierRoutePlan.referenceDeviceUID,
              binding.matchesCurrentState(
                  routing: current.state.outputRouting,
                  bassManagement: current.state.bassManagement,
                  driverProcessing:
                      current.state.speakerDriverProcessing
              ) else {
            throw SpeakerMeasurementLabControllerError
                .sessionEnvironmentChanged
        }
    }

    private func clearActiveMeasurement() {
        activeTransport = nil
        activeProgram = nil
        activeStep = nil
        activeCapabilityPlan = nil
        activeProtectedProvenance = nil
    }

    private func recordFailure(_ error: Error) {
        activeTransport?.cancel()
        clearActiveMeasurement()
        state = .failed
        lastErrorDescription = error.localizedDescription
    }
}
