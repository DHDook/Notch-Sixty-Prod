import Combine
import Foundation

typealias QuietZoneFeedForwardPairCaptureFactory = (
    AudioInputDevice, _ referenceChannel: Int, _ errorChannel: Int
) throws -> QuietZoneFeedForwardPairCapturing

/// E26 S7c: the multi-output transport for a class A pass: the route plan, the available outputs, the seat input and
/// channel, the dry program, the primary output channel and its signal, and the other outputs played beside it.
typealias SubPathMultibusTransportFactory = (
    LiveNChannelOutputRoutePlan, [AudioOutputDevice], AudioInputDevice, Int, RoomCorrectionSweepProgram, UInt32,
    [Float], [MultichannelLaneProgram]
) throws -> any MultichannelCalibrationTransporting

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
        if let previous, previous.sameInputs(as: survey) {
            survey.leakage = previous.leakage
            survey.echoModel = previous.echoModel
            survey.echoBassFingerprint = previous.echoBassFingerprint
        }
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
        budget: QuietZoneFeedForwardBudget,
        bassConditioning: Bool = false
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
            var designer = QuietZoneVirtualSeatDesigner()
            designer.bassConditioning = bassConditioning
            let design = try designer.design(measurements: assembled.bands, budget: budget)
            return .design(design, assembled)
        } catch {
            return .bandsOnly(assembled, reason: error.localizedDescription)
        }
    }
}

/// E4 S9b2: runs the feed-forward design measurement
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
    /// E4 S22b2: sweeps per speaker. The run is audible and about three times as long as before.
    static let leakageRepeats = FeedForwardEchoModel.minimumRepeats

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
    private let multibusTransportFactory: SubPathMultibusTransportFactory
    private let multibusAnalysisOperation: MultichannelCalibrationAnalysisOperation
    private let settlingSecondsOverride: Double?
    private var multibusTransport: (any MultichannelCalibrationTransporting)?
    /// E26 S7c: the per-output leakage records of the last class A leakage measurement.
    @Published private(set) var leakageRecords: [CombinedAncPathRecord] = []

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
        },
        multibusTransportFactory: @escaping SubPathMultibusTransportFactory = {
            routePlan, outputs, input, channel, program, physicalOutput, samples, lanes in
            try MultichannelCalibrationTransport(
                routePlan: routePlan, availableOutputs: outputs, input: input, inputChannelIndex: channel,
                program: program, physicalOutputChannelIndex: physicalOutput, outputSweepSamples: samples,
                laneProgramsForOutputs: lanes)
        },
        multibusAnalysisOperation: @escaping MultichannelCalibrationAnalysisOperation = { capture, program, calibration in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(
                    rawCapture: capture.samples, program: program, microphoneCalibration: calibration)
            }.value
        },
        settlingSecondsOverride: Double? = nil
    ) {
        self.multibusTransportFactory = multibusTransportFactory
        self.multibusAnalysisOperation = multibusAnalysisOperation
        self.settlingSecondsOverride = settlingSecondsOverride
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

    /// E26 S7c: the plant the design and the shadow use. On a direct multi-output rig with a fresh sub-path report it is
    /// the measured combined seat path per feed (the Room Correction position, when there is one, supplies the rest);
    /// everywhere else it is the selected Room Correction position, unchanged.
    func planningPosition() -> RoomCorrectionMeasurementPosition? {
        let base = ambient.selectedModelPosition
        guard quietZone.subAwareAncEnabled, quietZone.ancBassPathState.path == .subOutput,
              let report = quietZone.freshSubSweepReport, let left = report.seatLeft, let right = report.seatRight
        else { return base }
        var position = base ?? RoomCorrectionMeasurementPosition(
            name: "Quiet Zone sub path", sampleRate: report.sampleRate, left: left, right: right)
        position.left = left
        position.right = right
        position.sampleRate = report.sampleRate
        position.ancBassFingerprint = report.fingerprint
        position.outputGainDBAtMeasurement = quietZone.currentOutputGainDB
        return position
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
        guard let position = planningPosition() else {
            return (nil, QuietZoneFeedForwardSurveyError.positionModelMissing.localizedDescription)
        }
        // E26 S2c: the secondary path (the Room Correction position) must describe today's bass setup.
        if quietZone.subAwareAncEnabled,
           case .stale(let message) = quietZone.ancBassPathState.freshness(of: position.ancBassFingerprint) {
            return (nil, message)
        }
        return (QuietZoneFeedForwardShadowInputs(
            device: seat.device, referenceChannel: survey.referenceChannel, errorChannel: seat.channel,
            bands: assembled.bands, design: design, budget: quietZone.feedForwardBudget, position: position,
            echoModel: survey.echoModelOrLegacy,
            bassPath: quietZone.subAwareAncEnabled ? quietZone.ancBassPathState : nil,
            echoBassFingerprint: survey.echoBassFingerprint,
            bassConditioning: quietZone.bassConditioningActive
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
            // E26 S2b: with the flag on and a sub in the path, sweep from 15 Hz, longer, with a longer tail.
            let bassPath = quietZone.subAwareAncEnabled ? quietZone.ancBassPathState : nil
            let baseSettings = RoomCorrectionSweepSettings(
                sampleRate: output.nominalSampleRate,
                startFrequencyHz: calibration.sweepStartFrequencyHz,
                endFrequencyHz: calibration.sweepEndFrequencyHz,
                durationSeconds: calibration.sweepDurationSeconds,
                levelDBFS: calibration.sweepLevelDBFS,
                leadInSeconds: calibration.sweepLeadInSeconds,
                tailSeconds: calibration.sweepTailSeconds,
                fadeSeconds: calibration.sweepFadeSeconds
            )
            let sweepSettings = bassPath.map {
                ThroughFeedSweepPlanner.settings(
                    base: baseSettings, path: $0.path, sampleRate: output.nominalSampleRate)
            } ?? baseSettings
            var program = try RoomCorrectionSweepGenerator().makeProgram(settings: sweepSettings)
            if let bassPath, bassPath.path == .subOutput, quietZone.bassConditioningActive {
                try startClassALeakagePasses(
                    output: output, seat: seat, survey: survey, program: program, bassPath: bassPath)
                return
            }
            // E26 S6b: with a sub in the path the leakage is the combined leakage, so the sweep plays through the splitter.
            if quietZone.bassConditioningActive {
                program = try SubSweepAnalyzer.renderedProgram(program, bass: quietZone.engine.bassManagementConfiguration)
            }
            let plan = try RoomCorrectionMeasurementPlan(
                program: program, settlingSeconds: calibration.interPassSettlingSeconds
            )
            let transport = try transportFactory(output, seat.device, survey.referenceChannel, plan)
            try transport.start()
            leakageTransport = transport
            activity = .measuringLeakage(progress: 0)
            message = "Playing \(Self.leakageRepeats) sweeps on each speaker; the reference microphone records them."
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    var lefts: [[Float]] = [], rights: [[Float]] = []
                    var rate = output.nominalSampleRate
                    var current = transport
                    for index in 0..<Self.leakageRepeats {
                        if index > 0 {
                            current = try self.transportFactory(output, seat.device, survey.referenceChannel, plan)
                            try current.start()
                            self.leakageTransport = current
                        }
                        let capture = try await self.pollLeakage(current, repeatIndex: index)
                        self.activity = .analyzing
                        let analysis = try await self.analysisOperation(capture, plan, nil)
                        lefts.append(analysis.left.impulseResponse)
                        rights.append(analysis.right.impulseResponse)
                        rate = analysis.sampleRate
                    }
                    let model = try FeedForwardEchoModelBuilder.build(
                        left: lefts, right: rights, nativeSampleRate: rate, capturedAt: Date()
                    )
                    var updated = survey
                    updated.echoModel = model
                    updated.leakage = model.asLeakage()
                    updated.echoBassFingerprint = bassPath?.fingerprint
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

    /// E26 S6b: the seat sweep through the combined path ("Measure with your subwoofer"). The sweep is rendered through
    /// the app's splitter, played on each feed, and analysed per band: the open-preout check (G3), per-band feed-forward
    /// eligibility (G4) and the splitter-render verification (G2) go to the controller as one `SubSweepReport`. With
    /// `thenLeakage` the combined leakage sweep follows. Audible; needs playback idle.
    func measureSubPath(thenLeakage: Bool = false) {
        do {
            guard quietZone.bassConditioningActive else { throw QuietZoneFeedForwardSurveyError.subPathNotNeeded }
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
            guard let arrangement = quietZone.arrangement else { throw QuietZoneFeedForwardSurveyError.subPathNotNeeded }
            let seat = try seat()
            let pathState = quietZone.ancBassPathState
            let bass = quietZone.engine.bassManagementConfiguration
            let preview = quietZone.feedForwardBudget.conservativePreviewSeconds
            let baseSettings = RoomCorrectionSweepSettings(
                sampleRate: output.nominalSampleRate,
                startFrequencyHz: calibration.sweepStartFrequencyHz,
                endFrequencyHz: calibration.sweepEndFrequencyHz,
                durationSeconds: calibration.sweepDurationSeconds,
                levelDBFS: calibration.sweepLevelDBFS,
                leadInSeconds: calibration.sweepLeadInSeconds,
                tailSeconds: calibration.sweepTailSeconds,
                fadeSeconds: calibration.sweepFadeSeconds
            )
            let settings = ThroughFeedSweepPlanner.settings(
                base: baseSettings, path: pathState.path, sampleRate: output.nominalSampleRate)
            if pathState.path == .subOutput {
                try startClassASeatPasses(
                    output: output, seat: seat, settings: settings, bass: bass, pathState: pathState,
                    arrangement: arrangement, preview: preview, thenLeakage: thenLeakage)
                return
            }
            let program = try SubSweepAnalyzer.renderedProgram(
                try RoomCorrectionSweepGenerator().makeProgram(settings: settings), bass: bass)
            let plan = try RoomCorrectionMeasurementPlan(
                program: program, settlingSeconds: calibration.interPassSettlingSeconds)
            let transport = try transportFactory(output, seat.device, seat.channel, plan)
            try transport.start()
            leakageTransport = transport
            activity = .measuringLeakage(progress: 0)
            message = "Playing the sweep through your bass path on each speaker; the seat microphone records it."
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let capture = try await self.pollLeakage(transport, repeatIndex: 0)
                    self.activity = .analyzing
                    let analysis = try await self.analysisOperation(capture, plan, nil)
                    let rate = analysis.sampleRate
                    let left = analysis.left.impulseResponse, right = analysis.right.impulseResponse
                    let report = try await Task.detached(priority: .userInitiated) {
                        try SubSweepAnalyzer.analyze(
                            leftImpulse: left, rightImpulse: right, sampleRate: rate, bass: bass, path: pathState,
                            arrangement: arrangement, conservativePreviewSeconds: preview)
                    }.value
                    self.quietZone.setSubSweepReport(report)
                    self.activity = .idle
                    self.message = Self.subPathSummary(report)
                    if thenLeakage { self.measureLeakage() }
                } catch {
                    self.leakageTransport?.cancel()
                    self.leakageTransport = nil
                    self.activity = .idle
                    if !(error is CancellationError) { self.message = error.localizedDescription }
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// One plain sentence for the card after a sub-path measurement.
    static func subPathSummary(_ report: SubSweepReport) -> String {
        if let unverified = report.renderUnverifiedMessage { return unverified }
        if !report.openPreoutRefusal.isEmpty { return report.openPreoutRefusal }
        let count = report.feedForwardBandCount
        return count == 0
            ? "Bass path measured. No band has enough lead for feed-forward; tonal Quiet Zone can still run."
            : "Bass path measured. Feed-forward can run in \(count) of \(report.eligibility.bands.count) bands."
    }

    func cancel() {
        task?.cancel()
        task = nil
        run?.cancel()
        run = nil
        leakageTransport?.cancel()
        leakageTransport = nil
        multibusTransport?.cancel()
        multibusTransport = nil
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
        _ transport: any RoomCorrectionCalibrationTransporting, repeatIndex: Int
    ) async throws -> RoomCorrectionCalibrationCapture {
        while true {
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
            guard let snapshot = transport.snapshot() else { throw QuietZoneFeedForwardSurveyError.captureFault }
            if snapshot.totalFrameCount > 0 {
                activity = .measuringLeakage(
                    progress: (Double(repeatIndex) + min(Double(snapshot.frameCursor) / Double(snapshot.totalFrameCount), 1))
                        / Double(Self.leakageRepeats)
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
            survey: survey, position: planningPosition(), budget: quietZone.feedForwardBudget,
            bassConditioning: quietZone.bassConditioningActive
        ) {
        case .design(let design, let result):
            self.design = design
            assembled = result
            quietZone.measuredOutputGainDB = planningPosition()?.outputGainDBAtMeasurement
            quietZone.setBassPlant(BassPlantMap(bands: result.bands), fingerprint: planningPosition()?.ancBassFingerprint)
            message = "Design ready: \(result.bands.count) bands, worst modelled reduction "
                + String(format: "%.1f dB.", design.worstModeledReductionDB)
        case .bandsOnly(let result, let reason):
            design = nil
            assembled = result
            quietZone.measuredOutputGainDB = planningPosition()?.outputGainDBAtMeasurement
            quietZone.setBassPlant(BassPlantMap(bands: result.bands), fingerprint: planningPosition()?.ancBassFingerprint)
            message = "\(result.bands.count) bands measured. No design yet: \(reason)"
        case .unavailable(let reason):
            design = nil
            assembled = nil
            quietZone.setBassPlant(BassPlantMap(bands: []), fingerprint: nil)
            message = reason
        }
    }
}

// E26 S7c: class A (direct multi-output): two mains and one sub, each on its own hardware output.
extension QuietZoneFeedForwardSurveyController {
    private struct ClassARoute {
        var plan: LiveNChannelOutputRoutePlan
        var map: SubActuatorOutputMap
        var outputs: [AudioOutputDevice]
    }

    private func classARoute(output: AudioOutputDevice) throws -> ClassARoute {
        let engine = quietZone.engine
        guard let profile = quietZone.profiles.selectedSystemOutputDeviceProfile, profile.enabled,
              let uid = engine.routeConfiguration.selectedOutputUID
        else { throw QuietZoneFeedForwardSurveyError.outputProfileRequired }
        let plan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices, sampleRate: output.nominalSampleRate,
            selectedOutputUID: uid, bassManagementEnabled: true)
        return ClassARoute(plan: plan, map: try SubPathMeasurement.outputMap(routePlan: plan), outputs: engine.outputDevices)
    }

    /// One pass: `primary` plays as the sweep on its output, `lanes` beside it; the capture is analysed against the
    /// dry sweep, so the result carries each output's bus content.
    private func runMultibusPass(
        route: ClassARoute, seat input: AudioInputDevice, channel: Int, program: RoomCorrectionSweepProgram,
        primary: SubActuatorOutputSignal, lanes: [MultichannelLaneProgram], progress: (Double) -> Activity
    ) async throws -> RoomCorrectionChannelMeasurement {
        let transport = try multibusTransportFactory(
            route.plan, route.outputs, input, channel, program, primary.outputChannel, primary.samples, lanes)
        try transport.start()
        multibusTransport = transport
        while true {
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
            guard let snapshot = transport.snapshot() else { throw QuietZoneFeedForwardSurveyError.captureFault }
            if snapshot.totalFrameCount > 0 {
                activity = progress(min(Double(snapshot.frameCursor) / Double(snapshot.totalFrameCount), 1))
            }
            if snapshot.complete { break }
        }
        let capture = try transport.finishAndMaterialize()
        multibusTransport = nil
        activity = .analyzing
        return try await multibusAnalysisOperation(capture, program, nil)
    }

    private var settlingNanoseconds: UInt64 {
        UInt64(max(0, settlingSecondsOverride ?? calibration.interPassSettlingSeconds) * 1_000_000_000)
    }

    fileprivate func startClassASeatPasses(
        output: AudioOutputDevice,
        seat: (project: RoomCorrectionProject, device: AudioInputDevice, channel: Int),
        settings: RoomCorrectionSweepSettings, bass: BassManagementConfiguration, pathState: AncBassPathState,
        arrangement: SystemArrangement, preview: Double?, thenLeakage: Bool
    ) throws {
        guard arrangement.isTwoMainsOneSub else { throw SubPathMeasurement.PlanError.unsupportedShape }
        let route = try classARoute(output: output)
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        let passes = try SubPathMeasurement.seatPasses(
            program: program, bass: bass, map: route.map, outputChannelCount: Int(route.plan.physicalChannelCount))
        activity = .measuringLeakage(progress: 0)
        message = "Playing the sweep through your bass path on each speaker; the seat microphone records it."
        let device = seat.device, channel = seat.channel
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var irs: [RoomCorrectionChannelMeasurement] = []
                for (index, pass) in passes.enumerated() {
                    if index > 0 { try await Task.sleep(nanoseconds: self.settlingNanoseconds) }
                    let count = Double(passes.count)
                    irs.append(try await self.runMultibusPass(
                        route: route, seat: device, channel: channel, program: program, primary: pass.plan.primary,
                        lanes: pass.plan.laneProgramsForTransport(leadInFrames: program.leadInFrames),
                        progress: { .measuringLeakage(progress: (Double(index) + $0) / count) }))
                }
                guard irs.count == 2 else { throw QuietZoneFeedForwardSurveyError.captureFault }
                let rate = program.sampleRate
                let left = irs[0], right = irs[1]
                var report = try await Task.detached(priority: .userInitiated) {
                    try SubSweepAnalyzer.analyze(
                        leftImpulse: left.impulseResponse, rightImpulse: right.impulseResponse, sampleRate: rate,
                        bass: bass, path: pathState, arrangement: arrangement, conservativePreviewSeconds: preview)
                }.value
                report.seatLeft = left
                report.seatRight = right
                report.records = SubPathMeasurement.records(
                    seatLeft: left.impulseResponse, seatRight: right.impulseResponse, leftMain: [], rightMain: [], sub: [],
                    map: route.map, sampleRate: rate, fingerprint: pathState.fingerprint)
                self.quietZone.setSubSweepReport(report)
                self.activity = .idle
                self.message = Self.subPathSummary(report)
                if self.survey != nil { self.recomputeDesign() }
                if thenLeakage { self.measureLeakage() }
            } catch {
                self.multibusTransport?.cancel()
                self.multibusTransport = nil
                self.activity = .idle
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
    }

    fileprivate func startClassALeakagePasses(
        output: AudioOutputDevice,
        seat: (project: RoomCorrectionProject, device: AudioInputDevice, channel: Int),
        survey: QuietZoneFeedForwardDesignSurvey, program: RoomCorrectionSweepProgram, bassPath: AncBassPathState
    ) throws {
        let route = try classARoute(output: output)
        let bass = quietZone.engine.bassManagementConfiguration
        let passes = try SubPathMeasurement.seatPasses(
            program: program, bass: bass, map: route.map, outputChannelCount: Int(route.plan.physicalChannelCount))
        let signals = try SubPathMeasurement.leakageSignals(passes: passes)
        let repeats = SubPathMeasurement.leakageRepeats
        let total = Double(signals.count * repeats)
        activity = .measuringLeakage(progress: 0)
        message = "Playing \(SubPathMeasurement.leakagePassCount) sweeps, one speaker or subwoofer at a time; the reference microphone records them."
        let reference = survey.referenceChannel, device = seat.device
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var results = [[[Float]]](repeating: [], count: signals.count)
                var index = 0
                for _ in 0..<repeats {
                    for (o, signal) in signals.enumerated() {
                        if index > 0 { try await Task.sleep(nanoseconds: self.settlingNanoseconds) }
                        let base = Double(index)
                        let measurement = try await self.runMultibusPass(
                            route: route, seat: device, channel: reference, program: program, primary: signal, lanes: [],
                            progress: { .measuringLeakage(progress: (base + $0) / total) })
                        results[o].append(measurement.impulseResponse)
                        index += 1
                    }
                }
                let rate = program.sampleRate
                let map = route.map
                let model = try SubPathMeasurement.echoModel(
                    leftMain: results[0], rightMain: results[1], sub: results[2], map: map, nativeSampleRate: rate,
                    capturedAt: Date())
                let records = SubPathMeasurement.records(
                    seatLeft: [], seatRight: [], leftMain: results[0], rightMain: results[1], sub: results[2], map: map,
                    sampleRate: rate, fingerprint: bassPath.fingerprint)
                var updated = survey
                updated.echoModel = model
                updated.leakage = model.asLeakage()
                updated.echoBassFingerprint = bassPath.fingerprint
                try self.store.save(updated, project: seat.project)
                self.survey = updated
                self.leakageRecords = records
                self.activity = .idle
                if self.survey != nil { self.recomputeDesign() }
            } catch {
                self.multibusTransport?.cancel()
                self.multibusTransport = nil
                self.activity = .idle
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
    }
}
