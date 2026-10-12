import Combine
import Foundation

/// Guided fresh-capture controller for a provisional Speaker Optimizer FIR
/// Apply receipt.
///
/// This intentionally remains separate from SpeakerOptimizerVerificationController
/// so the established PEQ verification path is not generalized or destabilized.
/// The transport/orchestration contract is identical: every verification sweep
/// is a fresh post-Apply acoustic capture using the same microphone, semantic
/// sources, positions, routing identity and sample rate as the baseline.
@MainActor
final class SpeakerOptimizerFIRVerificationController:
    ObservableObject {
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    private let store:
        SpeakerOptimizerVerificationCampaignStore
    private let transportFactory:
        MultichannelCalibrationTransportFactory
    private let analysisOperation:
        MultichannelCalibrationAnalysisOperation
    private let transportPlanner =
        SpeakerOptimizerMeasurementTransportPlanner()
    private let evaluator =
        SpeakerOptimizerMeasurementEvidenceEvaluator()
    private let verifier =
        SpeakerOptimizerFIRPostApplyVerifier()
    private let sweepGenerator =
        RoomCorrectionSweepGenerator()
    private let orchestrator =
        SpeakerOptimizerMeasurementSessionOrchestrator.standard
    private let sessionFactory =
        SpeakerOptimizerVerificationSessionFactory()

    private var baseline:
        SpeakerOptimizerMeasurementSet?
    private var plan:
        SpeakerOptimizerClassificationAwareFIRPlan?
    private var receipt:
        SpeakerOptimizerFIRApplyReceipt?
    private var activeTransport:
        (any MultichannelCalibrationTransporting)?
    private var activeProgram:
        RoomCorrectionSweepProgram?
    private var activeStep:
        SpeakerOptimizerMeasurementSessionStep?
    private var analysisGeneration: UInt64 = 0

    @Published private(set) var state:
        SpeakerOptimizerMeasurementControllerState = .idle
    @Published private(set) var measurementSet:
        SpeakerOptimizerMeasurementSet?
    @Published private(set) var evidenceReport:
        SpeakerOptimizerMeasurementEvidenceReport?
    @Published private(set) var verificationReport:
        SpeakerOptimizerPostApplyVerificationReport?
    @Published private(set) var activeTransportPlan:
        SpeakerOptimizerMeasurementTransportPlan?
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        store:
            SpeakerOptimizerVerificationCampaignStore =
                SpeakerOptimizerVerificationCampaignStore(),
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
                    physicalOutputChannelIndex:
                        physicalOutput
                )
            },
        analysisOperation:
            @escaping MultichannelCalibrationAnalysisOperation = {
                capture, program, microphoneCalibration in
                try await Task.detached(
                    priority: .userInitiated
                ) {
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
        self.analysisOperation = analysisOperation
    }

    var progress:
        SpeakerOptimizerMeasurementSessionProgress? {
        guard let measurementSet else { return nil }
        return try? orchestrator.progress(
            for: measurementSet
        )
    }

    var activeOrNextStep:
        SpeakerOptimizerMeasurementSessionStep? {
        activeStep ?? {
            guard let measurementSet else {
                return nil
            }
            return try? orchestrator.nextPendingStep(
                for: measurementSet
            )
        }()
    }

    var activeMeasurementProgress: Double {
        guard let snapshot =
                activeTransport?.snapshot(),
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
              let measurementSet,
              (try? orchestrator.nextPendingStep(
                  for: measurementSet
              )) != nil else {
            return false
        }
        return engine.lifecycleState == .idle
            && microphone.permissionStatus == .authorized
            && microphone.selectedInputDevice != nil
            && engine.selectedOutputDevice != nil
            && activeTransport == nil
    }

    func startOrResume(
        baseline: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerVerificationSessionError
                .measurementAlreadyActive
        }
        let baselineEvidence =
            try evaluator.evaluate(baseline)
        guard baselineEvidence.optimizerReady else {
            throw SpeakerOptimizerVerificationSessionError
                .baselineUnqualified
        }

        guard let profile =
                profiles.selectedSystemProfile,
              profile.id == receipt.playbackSystemID,
              profile.state
                == receipt.expectedAppliedState,
              profile.state.outputDeviceProfile?
                .speakerOptimizerFIR
                == receipt.deployment else {
            throw SpeakerOptimizerVerificationSessionError
                .appliedStateRequired
        }
        guard let output =
                engine.selectedOutputDevice else {
            throw SpeakerOptimizerVerificationSessionError
                .outputRequired
        }
        guard microphone.permissionStatus
                == .authorized,
              let input =
                microphone.selectedInputDevice else {
            throw SpeakerOptimizerVerificationSessionError
                .microphoneIdentityMismatch
        }

        let currentMic =
            SpeakerOptimizerMicrophoneIdentity(
                deviceUID: input.uid,
                inputChannelIndex:
                    microphone.selectedInputChannelIndex,
                calibrationFingerprint:
                    microphone.microphoneCalibration?
                        .sourceName
            )
        guard currentMic == baseline.microphone,
              abs(
                output.nominalSampleRate
                    - baseline.sampleRate
              ) < 0.5 else {
            throw SpeakerOptimizerVerificationSessionError
                .microphoneIdentityMismatch
        }

        let archive:
            SpeakerOptimizerVerificationCampaignArchive
        if let stored =
            try store.load(applyReceiptID: receipt.id) {
            try sessionFactory.validate(
                stored,
                baseline: baseline,
                receipt: receipt
            )
            archive = stored
        } else {
            archive = try sessionFactory.fresh(
                baseline: baseline,
                receipt: receipt
            )
            try store.save(archive)
        }

        self.baseline = baseline
        self.plan = plan
        self.receipt = receipt
        measurementSet = archive.measurementSet
        try refreshDerivedState()
        lastErrorDescription = nil
    }

    func beginNextMeasurement() throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerVerificationSessionError
                .measurementAlreadyActive
        }
        guard engine.lifecycleState == .idle else {
            throw SpeakerOptimizerVerificationSessionError
                .playbackMustBeIdle(
                    engine.lifecycleState
                )
        }
        guard let receipt,
              let profile =
                profiles.selectedSystemProfile,
              profile.id == receipt.playbackSystemID,
              profile.state
                == receipt.expectedAppliedState,
              profile.state.outputDeviceProfile?
                .speakerOptimizerFIR
                == receipt.deployment,
              let outputProfile =
                profile.state.outputDeviceProfile,
              outputProfile.enabled else {
            throw SpeakerOptimizerVerificationSessionError
                .appliedStateRequired
        }
        guard microphone.permissionStatus
                == .authorized,
              let input =
                microphone.selectedInputDevice,
              let output =
                engine.selectedOutputDevice,
              let selectedOutputUID =
                engine.routeConfiguration
                    .selectedOutputUID else {
            throw SpeakerOptimizerVerificationSessionError
                .outputRequired
        }
        guard let set = measurementSet,
              let step =
                try orchestrator.nextPendingStep(
                    for: set
                ) else {
            throw SpeakerOptimizerVerificationSessionError
                .sessionRequired
        }

        // makeLivePlan validates and carries the persisted FIR. Verification
        // sweeps therefore traverse the exact provisional FIR deployment under
        // test instead of silently bypassing it.
        let routePlan = try outputProfile.makeLivePlan(
            availableDevices: engine.outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: selectedOutputUID,
            bassManagementEnabled:
                profile.state.bassManagement.enabled
        )
        let transportPlan = transportPlanner.plan(
            target: .acousticSource(step.source),
            routePlan: routePlan,
            multiOutputRouting:
                profile.state.outputRouting,
            speakerDriverProcessing:
                profile.state.speakerDriverProcessing
        )
        activeTransportPlan = transportPlan
        guard transportPlan.canStartMeasurement,
              let physicalOutput =
                transportPlan
                    .physicalOutputChannelIndex else {
            state = .blocked
            let reason =
                transportPlan.blockReason?.message
                ?? "the measurement transport safety contract was not satisfied"
            let error =
                SpeakerOptimizerVerificationSessionError
                    .transportBlocked(reason)
            lastErrorDescription =
                error.localizedDescription
            throw error
        }

        let settings = RoomCorrectionSweepSettings(
            sampleRate: output.nominalSampleRate,
            startFrequencyHz:
                microphone.sweepStartFrequencyHz,
            endFrequencyHz:
                microphone.sweepEndFrequencyHz,
            durationSeconds:
                microphone.sweepDurationSeconds,
            levelDBFS: microphone.sweepLevelDBFS,
            leadInSeconds:
                microphone.sweepLeadInSeconds,
            tailSeconds: microphone.sweepTailSeconds,
            fadeSeconds: microphone.sweepFadeSeconds
        )
        let program =
            try sweepGenerator.makeProgram(
                settings: settings
            )
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
            clearActive()
            recordFailure(error)
            throw error
        }
    }

    @discardableResult
    func finishMeasurementIfComplete()
        async throws -> Bool {
        guard state == .measuring,
              let transport = activeTransport else {
            return false
        }
        guard transport.snapshot()?.complete
                == true else {
            return false
        }

        let capture:
            MultichannelCalibrationCapture
        do {
            capture =
                try transport.finishAndMaterialize()
        } catch {
            clearActive()
            recordFailure(error)
            throw error
        }
        activeTransport = nil

        guard let program = activeProgram,
              let step = activeStep,
              var set = measurementSet else {
            clearActive()
            throw SpeakerOptimizerVerificationSessionError
                .measurementNotActive
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
            let measurement =
                MultichannelCalibrationMeasurement(
                    seatID: step.position.id,
                    source: step.source,
                    sampleRate: program.sampleRate,
                    channel: analyzed
                )
            let compact =
                try SpeakerOptimizerMeasurementCapture(
                    compacting: measurement,
                    playbackSystemID:
                        set.playbackSystemID,
                    routingSignature:
                        set.routingSignature,
                    microphone: set.microphone
                )
            set = try orchestrator.appending(
                compact,
                to: set,
                for: step
            )
            measurementSet = set
            try persistCurrent()
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
        clearActive()
        do {
            try refreshDerivedState()
        } catch {
            recordFailure(error)
        }
    }

    func resetVerification() throws {
        guard activeTransport == nil,
              let baseline,
              let receipt else {
            throw SpeakerOptimizerVerificationSessionError
                .sessionRequired
        }
        try store.delete(
            applyReceiptID: receipt.id
        )
        let fresh = try sessionFactory.fresh(
            baseline: baseline,
            receipt: receipt
        )
        try store.save(fresh)
        measurementSet = fresh.measurementSet
        verificationReport = nil
        try refreshDerivedState()
    }

    private func refreshDerivedState() throws {
        guard let set = measurementSet else {
            evidenceReport = nil
            verificationReport = nil
            state = .idle
            return
        }
        evidenceReport =
            try evaluator.evaluate(set)
        let progress =
            try orchestrator.progress(for: set)
        if progress.complete {
            state = .reviewing
            if evidenceReport?.optimizerReady == true,
               let baseline,
               let plan,
               let receipt {
                verificationReport =
                    try verifier.verify(
                        baseline: baseline,
                        verification: set,
                        plan: plan,
                        receipt: receipt
                    )
            } else {
                verificationReport = nil
            }
        } else {
            verificationReport = nil
            state = .ready
        }
    }

    private func persistCurrent() throws {
        guard let measurementSet,
              let receipt,
              let baseline else {
            throw SpeakerOptimizerVerificationSessionError
                .sessionRequired
        }
        let archive =
            SpeakerOptimizerVerificationCampaignArchive(
                applyReceiptID: receipt.id,
                baselineMeasurementSetID:
                    baseline.id,
                measurementSet: measurementSet
            )
        try sessionFactory.validate(
            archive,
            baseline: baseline,
            receipt: receipt
        )
        try store.save(archive)
    }

    private func clearActive() {
        activeTransport = nil
        activeProgram = nil
        activeStep = nil
        activeTransportPlan = nil
    }

    private func recordFailure(
        _ error: Error
    ) {
        activeTransport?.cancel()
        clearActive()
        state = .failed
        lastErrorDescription =
            error.localizedDescription
    }
}
