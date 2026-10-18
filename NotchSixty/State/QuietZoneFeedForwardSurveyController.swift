import Combine
import Foundation

typealias QuietZoneFeedForwardPairCaptureFactory = (
    AudioInputDevice, _ referenceChannel: Int, _ errorChannel: Int
) throws -> QuietZoneFeedForwardPairCapturing

/// E4 S9b2: the pure decisions behind the survey flow, kept apart so they can
/// be tested without hardware.
enum QuietZoneFeedForwardSurveyRules {
    /// The reference must be another channel of the seat microphone's device
    /// (the capture checks that the device has it).
    static func validateReferenceChannel(_ reference: Int?, errorChannel: Int) throws -> Int {
        guard let reference else { throw QuietZoneFeedForwardSurveyError.referenceChannelMissing }
        guard reference >= 0 else { throw QuietZoneFeedForwardSurveyError.referenceChannelUnavailable(reference) }
        guard reference != errorChannel else { throw QuietZoneFeedForwardSurveyError.referenceIsErrorChannel }
        return reference
    }

    /// A finished noise survey, keeping an earlier leakage measurement made
    /// with the same inputs.
    static func survey(
        projectID: UUID, microphoneStableID: String, errorChannel: Int, referenceChannel: Int,
        sampleRate: Double, bands: [QuietZoneFeedForwardSurveyBand], segments: Int,
        previous: QuietZoneFeedForwardDesignSurvey?, now: Date
    ) throws -> QuietZoneFeedForwardDesignSurvey {
        guard segments >= QuietZoneFeedForwardSurveyGrid.minimumSegments else {
            throw QuietZoneFeedForwardSurveyError.notEnoughSegments(segments)
        }
        var survey = QuietZoneFeedForwardDesignSurvey(
            projectID: projectID, microphoneStableID: microphoneStableID,
            errorChannel: errorChannel, referenceChannel: referenceChannel,
            sampleRate: sampleRate, capturedAt: now, segments: segments, bands: bands
        )
        if let previous, previous.sameInputs(as: survey) { survey.leakage = previous.leakage }
        return survey
    }

    enum DesignOutcome: Equatable {
        case design(QuietZoneVirtualSeatDesign, QuietZoneFeedForwardBandAssembler.Result)
        case bandsOnly(QuietZoneFeedForwardBandAssembler.Result, reason: String)
        case unavailable(reason: String)
    }

    /// The design is computed only when the timing budget allows it; until
    /// then the bands still show (S9c seeds the shadow from them).
    static func design(
        survey: QuietZoneFeedForwardDesignSurvey?,
        position: RoomCorrectionMeasurementPosition?,
        budget: QuietZoneFeedForwardBudget
    ) -> DesignOutcome {
        guard let survey else { return .unavailable(reason: "Measure the reference to seat transfer.") }
        guard let position else {
            return .unavailable(reason: QuietZoneFeedForwardSurveyError.positionModelMissing.localizedDescription)
        }
        let assembled: QuietZoneFeedForwardBandAssembler.Result
        do {
            assembled = try QuietZoneFeedForwardBandAssembler().assemble(survey: survey, position: position)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
        do {
            let design = try QuietZoneVirtualSeatDesigner().design(measurements: assembled.bands, budget: budget)
            return .design(design, assembled)
        } catch {
            return .bandsOnly(assembled, reason: error.localizedDescription)
        }
    }
}

/// E4 S9b2: runs the feed-forward design measurement (flag `e4.adaptive-anc`)
/// and publishes the bands and, once the timing budget allows, the design.
@MainActor
final class QuietZoneFeedForwardSurveyController: ObservableObject {
    enum Activity: Equatable {
        case idle
        case surveying(progress: Double)
        case measuringLeakage(progress: Double)
        case analyzing
    }

    static let pollNanoseconds: UInt64 = 100_000_000

    @Published private(set) var referenceChannel: Int?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var survey: QuietZoneFeedForwardDesignSurvey?
    @Published private(set) var assembled: QuietZoneFeedForwardBandAssembler.Result?
    @Published private(set) var design: QuietZoneVirtualSeatDesign?
    @Published private(set) var message = "Measure the reference to seat transfer."

    let quietZone: ActiveQuietZoneController
    let calibration: RoomCorrectionCalibrationController
    private let defaults: UserDefaults
    private let captureFactory: QuietZoneFeedForwardPairCaptureFactory
    private let transportFactory: RoomCorrectionCalibrationTransportFactory
    private let analysisOperation: RoomCorrectionMeasurementAnalysisOperation
    private var task: Task<Void, Never>?
    private var run: QuietZoneFeedForwardNoiseSurveyRun?
    private var leakageTransport: (any RoomCorrectionCalibrationTransporting)?

    init(
        quietZone: ActiveQuietZoneController,
        calibration: RoomCorrectionCalibrationController,
        defaults: UserDefaults = .standard,
        captureFactory: @escaping QuietZoneFeedForwardPairCaptureFactory = { device, reference, error in
            try FeedForwardReferenceTransport(
                microphone: device, inputChannelIndex: reference, errorChannelIndex: error
            )
        },
        transportFactory: @escaping RoomCorrectionCalibrationTransportFactory = { output, input, channel, plan in
            try RoomCorrectionCalibrationTransport(
                output: output, input: input, inputChannelIndex: channel, plan: plan
            )
        },
        analysisOperation: @escaping RoomCorrectionMeasurementAnalysisOperation = { capture, plan, _ in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyze(
                    capture: capture, plan: plan, microphoneCalibration: nil
                )
            }.value
        }
    ) {
        self.quietZone = quietZone
        self.calibration = calibration
        self.defaults = defaults
        self.captureFactory = captureFactory
        self.transportFactory = transportFactory
        self.analysisOperation = analysisOperation
        referenceChannel = defaults.object(forKey: PreferenceKeys.quietZoneFeedForwardReferenceChannel) as? Int
    }

    deinit { task?.cancel() }

    private var ambient: AmbientCompensationController { quietZone.ambient }
    private var store: QuietZoneFeedForwardDesignSurveyStore {
        QuietZoneFeedForwardDesignSurveyStore(roomStore: ambient.projects.store)
    }

    /// The seat microphone: the project microphone on the selected input.
    private func seat() throws -> (project: RoomCorrectionProject, device: AudioInputDevice, channel: Int) {
        guard let project = ambient.projects.project,
              ambient.roomProjectMatchesSelectedMicrophone,
              let device = ambient.microphone.selectedInputDevice,
              let channel = project.microphone?.inputChannelIndex
        else { throw QuietZoneFeedForwardSurveyError.incompatibleProject }
        return (project, device, channel)
    }

    var errorChannel: Int? { ambient.projects.project?.microphone?.inputChannelIndex }

    /// What the feed-forward shadow (S9c) runs on, or why it cannot run yet.
    /// Nothing while a measurement runs, so the shadow never hears a sweep.
    func shadowInputs() -> (inputs: QuietZoneFeedForwardShadowInputs?, reason: String) {
        guard activity == .idle else { return (nil, "Paused while a feed-forward measurement runs.") }
        guard let survey, let assembled else { return (nil, "Measure the feed-forward design first.") }
        guard let seat = try? seat() else {
            return (nil, QuietZoneFeedForwardSurveyError.incompatibleProject.localizedDescription)
        }
        guard survey.projectID == seat.project.id, survey.microphoneStableID == seat.device.uid,
              survey.errorChannel == seat.channel, survey.referenceChannel == referenceChannel
        else { return (nil, QuietZoneFeedForwardSurveyError.noiseSurveyMissing.localizedDescription) }
        guard let position = ambient.selectedModelPosition else {
            return (nil, QuietZoneFeedForwardSurveyError.positionModelMissing.localizedDescription)
        }
        return (QuietZoneFeedForwardShadowInputs(
            device: seat.device, referenceChannel: survey.referenceChannel, errorChannel: seat.channel,
            bands: assembled.bands, design: design, budget: quietZone.feedForwardBudget, position: position
        ), "")
    }

    func setReferenceChannel(_ channel: Int?) {
        referenceChannel = channel
        defaults.set(channel, forKey: PreferenceKeys.quietZoneFeedForwardReferenceChannel)
    }

    func refresh() {
        do {
            let seat = try seat()
            survey = try store.load(for: seat.project)
        } catch {
            survey = nil
        }
        recomputeDesign()
    }

    func startNoiseSurvey(durationSeconds: Double = QuietZoneFeedForwardSurveyGrid.defaultDurationSeconds) {
        do {
            guard activity == .idle else { throw QuietZoneFeedForwardSurveyError.alreadyRunning }
            guard calibration.permissionStatus == .authorized else {
                throw QuietZoneFeedForwardSurveyError.microphonePermissionRequired
            }
            let seat = try seat()
            let reference = try QuietZoneFeedForwardSurveyRules.validateReferenceChannel(
                referenceChannel, errorChannel: seat.channel
            )
            let capture: QuietZoneFeedForwardPairCapturing
            do {
                capture = try captureFactory(seat.device, reference, seat.channel)
            } catch FeedForwardReferenceTransportError.invalidInput {
                throw QuietZoneFeedForwardSurveyError.referenceChannelUnavailable(reference)
            }
            guard let core = QuietZoneFeedForwardNoiseSurvey(sampleRate: capture.sampleRate) else {
                capture.close()
                throw QuietZoneFeedForwardSurveyError.captureFault
            }
            let run = QuietZoneFeedForwardNoiseSurveyRun(capture: capture, survey: core, durationSeconds: durationSeconds)
            try run.start()
            self.run = run
            activity = .surveying(progress: 0)
            message = "Recording the noise on both microphones. Keep playback paused."
            task = Task { [weak self] in
                await self?.pollNoiseSurvey(run, project: seat.project, device: seat.device,
                                            errorChannel: seat.channel, referenceChannel: reference)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func measureLeakage() {
        do {
            guard activity == .idle else { throw QuietZoneFeedForwardSurveyError.alreadyRunning }
            guard calibration.permissionStatus == .authorized else {
                throw QuietZoneFeedForwardSurveyError.microphonePermissionRequired
            }
            guard RoomCorrectionCalibrationController.canClaimHardware(
                audioLifecycle: quietZone.engine.lifecycleState
            ) else { throw QuietZoneFeedForwardSurveyError.playbackMustBeIdle }
            guard let output = calibration.selectedOutputDevice else {
                throw QuietZoneFeedForwardSurveyError.noOutputSelected
            }
            let seat = try seat()
            // Leakage belongs to a noise survey made with the same channels.
            guard let survey, survey.projectID == seat.project.id,
                  survey.microphoneStableID == seat.device.uid,
                  survey.errorChannel == seat.channel,
                  survey.referenceChannel == referenceChannel
            else { throw QuietZoneFeedForwardSurveyError.noiseSurveyMissing }
            let program = try RoomCorrectionSweepGenerator().makeProgram(settings: RoomCorrectionSweepSettings(
                sampleRate: output.nominalSampleRate,
                startFrequencyHz: calibration.sweepStartFrequencyHz,
                endFrequencyHz: calibration.sweepEndFrequencyHz,
                durationSeconds: calibration.sweepDurationSeconds,
                levelDBFS: calibration.sweepLevelDBFS,
                leadInSeconds: calibration.sweepLeadInSeconds,
                tailSeconds: calibration.sweepTailSeconds,
                fadeSeconds: calibration.sweepFadeSeconds
            ))
            let plan = try RoomCorrectionMeasurementPlan(
                program: program, settlingSeconds: calibration.interPassSettlingSeconds
            )
            let transport = try transportFactory(output, seat.device, survey.referenceChannel, plan)
            try transport.start()
            leakageTransport = transport
            activity = .measuringLeakage(progress: 0)
            message = "Playing a sweep on each speaker; the reference microphone records it."
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let capture = try await self.pollLeakage(transport)
                    self.activity = .analyzing
                    let analysis = try await self.analysisOperation(capture, plan, nil)
                    var updated = survey
                    updated.leakage = QuietZoneFeedForwardLeakage(
                        sampleRate: analysis.sampleRate,
                        leftImpulseResponse: analysis.left.impulseResponse,
                        rightImpulseResponse: analysis.right.impulseResponse,
                        capturedAt: Date()
                    )
                    try self.store.save(updated, project: seat.project)
                    self.survey = updated
                    self.activity = .idle
                    self.recomputeDesign()
                } catch {
                    self.leakageTransport?.cancel()
                    self.leakageTransport = nil
                    self.activity = .idle
                    self.message = error.localizedDescription
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        run?.cancel()
        run = nil
        leakageTransport?.cancel()
        leakageTransport = nil
        activity = .idle
        message = "Measurement cancelled."
    }

    private func pollNoiseSurvey(
        _ run: QuietZoneFeedForwardNoiseSurveyRun, project: RoomCorrectionProject,
        device: AudioInputDevice, errorChannel: Int, referenceChannel: Int
    ) async {
        do {
            while true {
                try await Task.sleep(nanoseconds: Self.pollNanoseconds)
                let progress = try await Task.detached(priority: .userInitiated) { try run.pump() }.value
                activity = .surveying(progress: progress)
                if progress >= 1 { break }
            }
            let result = run.finish()
            self.run = nil
            let finished = try QuietZoneFeedForwardSurveyRules.survey(
                projectID: project.id, microphoneStableID: device.uid, errorChannel: errorChannel,
                referenceChannel: referenceChannel, sampleRate: run.sampleRate,
                bands: result.bands, segments: result.segments, previous: survey, now: Date()
            )
            try store.save(finished, project: project)
            survey = finished
            activity = .idle
            recomputeDesign()
        } catch {
            run.cancel()
            self.run = nil
            activity = .idle
            if !(error is CancellationError) { message = error.localizedDescription }
        }
    }

    private func pollLeakage(
        _ transport: any RoomCorrectionCalibrationTransporting
    ) async throws -> RoomCorrectionCalibrationCapture {
        while true {
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
            guard let snapshot = transport.snapshot() else { throw QuietZoneFeedForwardSurveyError.captureFault }
            if snapshot.totalFrameCount > 0 {
                activity = .measuringLeakage(
                    progress: min(Double(snapshot.frameCursor) / Double(snapshot.totalFrameCount), 1)
                )
            }
            if snapshot.complete { break }
        }
        let capture = try transport.finishAndMaterialize()
        leakageTransport = nil
        return capture
    }

    private func recomputeDesign() {
        switch QuietZoneFeedForwardSurveyRules.design(
            survey: survey, position: ambient.selectedModelPosition, budget: quietZone.feedForwardBudget
        ) {
        case .design(let design, let result):
            self.design = design
            assembled = result
            message = "Design ready: \(result.bands.count) bands, worst modelled reduction "
                + String(format: "%.1f dB.", design.worstModeledReductionDB)
        case .bandsOnly(let result, let reason):
            design = nil
            assembled = result
            message = "\(result.bands.count) bands measured. No design yet: \(reason)"
        case .unavailable(let reason):
            design = nil
            assembled = nil
            message = reason
        }
    }
}
