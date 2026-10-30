import Combine
import Foundation

struct ActiveQuietZoneToneTelemetry:
    Identifiable, Equatable, Sendable
{
    var frequencyHz: Double
    var disturbanceLevelDBFS: Double
    var residualLevelDBFS: Double
    var measuredReductionDB: Double
    var predictedReductionDB: Double
    var leftSourceLevelDBFS: Double
    var rightSourceLevelDBFS: Double

    var id: Double { frequencyHz }
}

enum ActiveQuietZoneControllerError:
    Error, Equatable, LocalizedError
{
    case playbackSystemRequired
    case ambientSensorUnavailable
    case acousticModelRequired
    case acousticModelSampleRateMismatch(
        measurement: Double,
        analysis: Double
    )
    case phaseReferenceUnavailable(Double)
    case frequencySetChanged
    case runtimeTargetLost
    case verificationRegression

    var errorDescription: String? {
        switch self {
        case .playbackSystemRequired:
            return "Select a Playback System before configuring Active Quiet Zone."
        case .ambientSensorUnavailable:
            return "Active Quiet Zone requires a fresh trusted ambient error-microphone observation."
        case .acousticModelRequired:
            return "Active Quiet Zone requires a matching retained Room Correction speaker-to-microphone model."
        case .acousticModelSampleRateMismatch(
            let measurement,
            let analysis
        ):
            return "The Quiet Zone acoustic model was measured at \(measurement) Hz but the live error microphone is running at \(analysis) Hz."
        case .phaseReferenceUnavailable(let frequency):
            return "The realtime anti-noise phase reference is not measurable at \(frequency) Hz."
        case .frequencySetChanged:
            return "The stable cancellation-frequency set changed and must be re-armed from silence."
        case .runtimeTargetLost:
            return "The realtime Quiet Zone target was removed by a route or headroom safety gate."
        case .verificationRegression:
            return "The physical error microphone measured a cancellation regression, so Active Quiet Zone was fault-faded and latched."
        }
    }
}

@MainActor
final class ActiveQuietZoneController: ObservableObject {
    static let pollIntervalNanoseconds: UInt64 = 250_000_000
    static let maximumProbeVerificationWindows = 8
    static let maximumWeakActiveWindows = 4

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let ambient: AmbientCompensationController
    /// The Quiet Zone ARM switch. Disarmed on every launch; live output runs only while armed.
    let arm = LiveTreatmentArm(feature: .quietZone)
    /// Engine arm token captured at arming and stamped on every active target.
    private var armedGeneration: UInt64?
    private var lastMicrophoneRevision: UInt64 = 0

    private let planner = ActiveQuietZonePlanner()
    private let spatialPlanner = ActiveQuietZoneSpatialPlanner()
    private let spatialSurveyBuilder = ActiveQuietZoneSpatialSurveyBuilder()
    private var surveyCaptures: [ActiveQuietZoneSpatialPhaseCapture] = []
    private var surveyToneHz: Double?
    private var lastSurveyCaptureRevision: UInt64 = 0
    private var task: Task<Void, Never>?
    private var activeSystemID: UUID?
    private var lastAnalysisRevision: UInt64 = 0
    private var persistence: [PersistenceState] = []
    private var stage: Stage = .observing
    private var weakActiveWindows = 0
    private var faultLatched = false

    @Published private(set) var configuration =
        ActiveQuietZoneConfiguration()
    @Published private(set) var status:
        ActiveQuietZoneStatus = .observe
    @Published private(set) var holdReason:
        ActiveQuietZoneHoldReason? = .disabled
    @Published private(set) var controlledFrequenciesHz: [Double] = []
    @Published private(set) var toneTelemetry:
        [ActiveQuietZoneToneTelemetry] = [] {
        didSet {
            if toneTelemetry.isEmpty { adaptiveSeeds = [] }
        }
    }
    /// E4 S6: the offline design per controlled tone, for the adaptive shadow.
    @Published private(set) var adaptiveSeeds: [AdaptiveQuietZoneSeed] = []
    @Published private(set) var availableInjectionPeak: Double = 0
    /// E4 S16: what the seat microphone verifies while armed, for example
    /// "\u{2212}12 dB at 43 Hz, verified". Nil until a reduction is verified.
    @Published private(set) var verifiedReadout: String?
    private var doNoHarm = DoNoHarmVerifier()
    /// E4 S17: the last 60 s of safety events, in plain language. Text only, no audio.
    private(set) var flightRecorder = SafetyFlightRecorder()
    /// E4 S18b (`e4.adaptive-tonal-live`): the adaptive tonal canceller's control plane. Nil with
    /// the flag off, in which case nothing below runs and the controller behaves as before.
    private(set) var adaptiveLive: AdaptiveTonalLiveCoordinator?

    func attachAdaptiveLive(_ coordinator: AdaptiveTonalLiveCoordinator?) {
        adaptiveLive = coordinator
        coordinator?.onEvent = { [weak self] kind, message in
            self?.flightRecorder.record(kind, message)
        }
    }
    /// E4 S20 (`e4.earned-cap`): the earned anti-noise cap. Nil with the flag off (or without the
    /// adaptive canceller), in which case the cap is the fixed -40 dBFS as before.
    private(set) var earnedCap: EarnedCapPolicy?

    func attachEarnedCap(_ policy: EarnedCapPolicy?) {
        earnedCap = policy
        policy?.onEvent = { [weak self] kind, message in
            self?.flightRecorder.record(kind, message)
        }
    }

    /// "Anti-noise limit -31 dBFS (earned)" while the earned cap is on; nil otherwise.
    var earnedCapStatus: String? { arm.isArmed ? earnedCap?.statusText : nil }

    private func earnedBinding(_ environment: LiveTreatmentEnvironment) -> EarnedCapBinding? {
        guard let output = environment.outputDeviceUID, let rate = environment.sampleRate else { return nil }
        return EarnedCapBinding(
            outputDeviceUID: output,
            inputDeviceUID: environment.inputDeviceUID ?? "",
            sampleRate: rate
        )
    }

    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var spatialCalibration:
        ActiveQuietZoneSpatialCalibration?
    @Published private(set) var spatialReadinessMessage:
        String = "Select a measurement project and at least two included positions."
    @Published private(set) var spatialPredictions:
        [ActiveQuietZoneSpatialSeatPrediction] = []
    @Published private(set) var spatialSurveyActive = false
    @Published private(set) var spatialSurveyProgress = 0
    @Published private(set) var spatialSurveyMessage =
        "Speaker-path positions must be prepared before a live noise survey."
    @Published var requestedSpatialSurveyFrequencyHz: Double = 60
    @Published private(set) var feedForwardCalibration:
        QuietZoneFeedForwardCalibration?
    @Published private(set) var feedForwardBudget:
        QuietZoneFeedForwardBudget = .missing
    @Published private(set) var feedForwardMessage =
        "A low-latency feed-forward path must be calibrated and hardware-verified before ANC can operate."

    private var feedForwardStore: QuietZoneFeedForwardStore {
        QuietZoneFeedForwardStore(roomStore: ambient.projects.store)
    }

    private var spatialStore: ActiveQuietZoneSpatialStore {
        ActiveQuietZoneSpatialStore(
            roomStore: ambient.projects.store
        )
    }

    private struct PersistenceState {
        var candidate: ActiveQuietZoneCandidateTone
        var count: Int
    }

    private enum Stage {
        case observing
        case phaseCalibration(
            target: ActiveQuietZoneRuntimeTarget,
            startRevision: UInt64
        )
        case cancellationProbe(
            target: ActiveQuietZoneRuntimeTarget,
            startRevision: UInt64,
            verificationWindows: Int
        )
        case active(
            target: ActiveQuietZoneRuntimeTarget,
            startRevision: UInt64
        )

        var target: ActiveQuietZoneRuntimeTarget? {
            switch self {
            case .observing:
                return nil
            case .phaseCalibration(let target, _),
                 .cancellationProbe(let target, _, _),
                 .active(let target, _):
                return target
            }
        }
    }

    private struct Evaluation {
        var desiredTarget: ActiveQuietZoneRuntimeTarget
        var telemetry: [ActiveQuietZoneToneTelemetry]
        var decisions: [ActiveQuietZoneVerification.Decision]
    }

    private var armChange: AnyCancellable?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        ambient: AmbientCompensationController
    ) {
        self.engine = engine
        self.profiles = profiles
        self.ambient = ambient
        arm.onDisarm = { [weak self] reason in self?.applyDisarm(reason) }
        armChange = arm.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Observers hold self weakly, so a released controller leaves only a no-op closure.
        _ = engine.addTransportTeardownObserver { [weak self] cause in
            self?.arm.transportTornDown(cause)
        }
    }

    deinit {
        task?.cancel()
    }

    func prepareForUse() {
        do {
            try synchronizeSelectedPlaybackSystem()
            refreshSpatialCalibration()
            refreshFeedForwardCalibration()
            if configuration.enabled {
                try start()
            } else {
                status = .observe
                holdReason = .disabled
            }
            lastErrorDescription = nil
        } catch {
            fault(error, reason: .ambientEvidenceUnavailable)
        }
    }

    /// Prepares an Advisor-style diagnostics sidecar. This is NOT a feed-forward
    /// runtime arm operation, and it deliberately creates no fake probe data.
    func prepareFeedForwardPlan() throws {
        guard let project = ambient.projects.project,
              let position = ambient.selectedModelPosition,
              project.playbackSystemID == profiles.selectedSystemProfileID,
              ambient.roomProjectMatchesSelectedMicrophone,
              let stableID = project.microphone?.stableID,
              !stableID.isEmpty
        else { throw QuietZoneFeedForwardError.incompatibleProject }
        let draft = QuietZoneFeedForwardCalibration(
            projectID: project.id,
            playbackSystemID: project.playbackSystemID,
            listenerPositionID: position.id,
            upstreamLabel: "Upstream doorway",
            microphoneStableID: stableID
        )
        try feedForwardStore.save(draft, project: project)
        feedForwardCalibration = draft
        feedForwardBudget = .missing
        feedForwardMessage =
            "Plan saved. Real trigger-synchronized listener → upstream → listener arrivals and a measured ADC/DSP/DAC/seat path are still required."
    }

    func refreshFeedForwardCalibration() {
        guard let project = ambient.projects.project,
              project.playbackSystemID == profiles.selectedSystemProfileID,
              ambient.roomProjectMatchesSelectedMicrophone else {
            feedForwardCalibration = nil
            feedForwardBudget = .missing
            feedForwardMessage = "Choose a matching Room Correction project and microphone."
            return
        }
        do {
            feedForwardCalibration = try feedForwardStore.load(for: project)
            if let calibration = feedForwardCalibration {
                feedForwardBudget = try QuietZoneFeedForwardBudgetAnalyzer()
                    .analyze(calibration, project: project)
                feedForwardMessage = feedForwardBudget.explanation
            } else {
                feedForwardBudget = .missing
                feedForwardMessage = "Create an upstream-reference diagnostic plan to begin."
            }
        } catch {
            feedForwardCalibration = nil
            feedForwardBudget = .missing
            feedForwardMessage = error.localizedDescription
        }
    }

    /// Keep timing capture ingestion explicit and provenance-gated.
    /// No ordinary Room Correction sweep can silently create such records.
    func importMeasuredFeedForwardCalibration(
        _ calibration: QuietZoneFeedForwardCalibration
    ) throws {
        guard let project = ambient.projects.project,
              project.playbackSystemID == profiles.selectedSystemProfileID,
              ambient.roomProjectMatchesSelectedMicrophone
        else { throw QuietZoneFeedForwardError.incompatibleProject }
        let budget = try QuietZoneFeedForwardBudgetAnalyzer()
            .analyze(calibration, project: project)
        try feedForwardStore.save(calibration, project: project)
        feedForwardCalibration = calibration
        feedForwardBudget = budget
        feedForwardMessage = budget.explanation
        // No runtime target, no arm and no change to the active profile.
    }

    /// Saves a draft spatial measurement plan. This does not fabricate the
    /// common-phase disturbance survey required for actual spatial ANC.
    func prepareSpatialPositions() throws {
        guard let project = ambient.projects.project,
              let anchor = ambient.selectedModelPosition,
              project.playbackSystemID == profiles.selectedSystemProfileID,
              ambient.roomProjectMatchesSelectedMicrophone,
              let microphone = project.microphone,
              let uid = microphone.stableID, !uid.isEmpty
        else {
            throw ActiveQuietZoneSpatialError.incompatibleMeasurement
        }
        let included = project.measurements.filter {
            $0.included && $0.weight > 0
        }
        guard (2...5).contains(included.count),
              included.contains(where: { $0.id == anchor.id })
        else {
            throw ActiveQuietZoneSpatialError.insufficientPositions
        }
        let plan = ActiveQuietZoneSpatialCalibration(
            projectID: project.id,
            playbackSystemID: project.playbackSystemID,
            anchorPositionID: anchor.id,
            microphoneStableID: uid,
            microphoneInputChannelIndex: microphone.inputChannelIndex,
            sampleRate: anchor.sampleRate,
            positions: included.map {
                ActiveQuietZoneSpatialPosition(
                    id: $0.id,
                    weight: min(1, max(0.05, $0.weight))
                )
            }
        )
        try spatialStore.save(plan, for: project)
        spatialCalibration = plan
        spatialReadinessMessage =
            "Speaker-path survey ready. A common-phase environmental tone survey and physical multi-seat verification are still required."
    }

    func refreshSpatialCalibration() {
        guard let project = ambient.projects.project,
              project.playbackSystemID == profiles.selectedSystemProfileID else {
            spatialCalibration = nil
            spatialReadinessMessage = "A matching Room Correction project is required."
            return
        }
        do {
            spatialCalibration = try spatialStore.load(for: project)
            if spatialCalibration == nil {
                spatialReadinessMessage = "Configure 2–5 included Room Correction positions and choose the live mic anchor."
            } else if spatialCalibration?.surveys.isEmpty == true {
                spatialReadinessMessage = "Spatial positions saved, but no common-phase disturbance survey is available. Spatial ANC cannot arm."
            } else {
                spatialReadinessMessage = "Coherent survey retained. A spatial candidate still requires a physical probe and measured re-verification."
            }
        } catch {
            spatialCalibration = nil
            spatialReadinessMessage = error.localizedDescription
        }
    }

    private var spatialSurveyOrder: [UUID] {
        guard let calibration = spatialCalibration else { return [] }
        let other = calibration.positions.map(\.id).filter {
            $0 != calibration.anchorPositionID
        }
        let perVisit = [calibration.anchorPositionID] + other
            + [calibration.anchorPositionID]
        return perVisit.flatMap { [$0, $0] }
    }

    var nextSpatialSurveyPositionName: String? {
        guard spatialSurveyActive,
              surveyCaptures.count < spatialSurveyOrder.count,
              let project = ambient.projects.project
        else { return nil }
        let id = spatialSurveyOrder[surveyCaptures.count]
        let name = project.measurements.first(where: {
            $0.id == id
        })?.name ?? "Measured seat"
        return "\(name) · sample \(surveyCaptures.count % 2 + 1) of 2"
    }

    /// A quiet, uninterrupted input session is mandatory. The mic can move,
    /// but the Mac must not play music or antinoise during this phase survey.
    func beginSpatialSurvey() throws {
        guard !configuration.enabled,
              engine.lifecycleState != .running,
              let calibration = spatialCalibration,
              let project = ambient.projects.project,
              calibration.anchorPositionID == ambient.selectedModelPosition?.id,
              ambient.roomProjectMatchesSelectedMicrophone
        else { throw ActiveQuietZoneSpatialError.mismatchedAnchor }
        _ = try calibration.validated(against: project)
        guard (20...150).contains(requestedSpatialSurveyFrequencyHz)
        else { throw ActiveQuietZoneSpatialError.invalidSurvey }
        try ambient.setQuietZoneObservationDemand(true)
        surveyCaptures = []
        spatialSurveyProgress = 0
        surveyToneHz = requestedSpatialSurveyFrequencyHz
        lastSurveyCaptureRevision = 0
        spatialSurveyActive = true
        spatialSurveyMessage =
            "With playback stopped, keep the external LF tone steady. Move the mic to the displayed position, allow the input window to settle, then capture twice."
    }

    func captureSpatialSurveyWindow() throws {
        guard spatialSurveyActive,
              let calibration = spatialCalibration,
              let project = ambient.projects.project,
              let frequency = surveyToneHz,
              surveyCaptures.count < spatialSurveyOrder.count,
              engine.lifecycleState != .running,
              let observation = ambient.phaseReferencedMicWindow(),
              observation.revision != lastSurveyCaptureRevision,
              abs(observation.sampleRate - calibration.sampleRate) < 0.5
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }

        let closestTone = observation.toneCandidates.min(by: {
            abs($0.frequencyHz - frequency)
                < abs($1.frequencyHz - frequency)
        })
        guard let closestTone,
              abs(closestTone.frequencyHz - frequency) <= 2.0 else {
            throw ActiveQuietZoneSpatialError.inadequatePhaseReference
        }
        let measuredFrequency = try spatialSurveyBuilder
            .refinedToneFrequency(
                samples: observation.samples,
                sampleRate: observation.sampleRate,
                near: closestTone.frequencyHz
            )
        // First capture locks the shared frequency estimate. Later captures
        // must agree independently or the survey cannot be finalized.
        let referenceFrequency = surveyCaptures.isEmpty
            ? measuredFrequency : frequency
        guard abs(measuredFrequency - referenceFrequency)
                <= calibration.settings.maximumFrequencyDriftHz
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
        if surveyCaptures.isEmpty {
            surveyToneHz = referenceFrequency
        }
        let positionID = spatialSurveyOrder[surveyCaptures.count]
        let captured = try spatialSurveyBuilder.capture(
            positionID: positionID,
            epoch: observation.epoch,
            firstSampleIndex: observation.firstSampleIndex,
            samples: observation.samples,
            sampleRate: observation.sampleRate,
            frequencyHz: referenceFrequency,
            detectedFrequencyHz: measuredFrequency,
            tonalProminenceDB: closestTone.prominenceDB,
            stationaryScore: observation.stationarity
        )
        if let first = surveyCaptures.first,
           first.epoch != captured.epoch {
            throw ActiveQuietZoneSpatialError.inadequatePhaseReference
        }
        if let last = surveyCaptures.last,
           captured.firstSampleIndex <= last.firstSampleIndex {
            throw ActiveQuietZoneSpatialError.inadequatePhaseReference
        }
        surveyCaptures.append(captured)
        lastSurveyCaptureRevision = observation.revision
        spatialSurveyProgress = surveyCaptures.count
        if surveyCaptures.count == spatialSurveyOrder.count {
            do {
                let result = try spatialSurveyBuilder.finish(
                    calibration: calibration,
                    captures: surveyCaptures
                )
                var updated = calibration
                updated.surveys.removeAll {
                    abs($0.frequencyHz - result.frequencyHz) < 0.1
                }
                updated.surveys.append(result)
                try spatialStore.save(updated, for: project)
                spatialCalibration = updated
                spatialSurveyMessage =
                    "Phase-closure survey accepted. Return the microphone to the anchor to use physical live verification. Sequential spatial reductions are still predictions until remeasured."
                spatialSurveyActive = false
                surveyToneHz = nil
                surveyCaptures.removeAll()
                try? ambient.setQuietZoneObservationDemand(false)
                refreshSpatialCalibration()
            } catch {
                cancelSpatialSurvey()
                throw error
            }
        }
    }

    func cancelSpatialSurvey() {
        spatialSurveyActive = false
        spatialSurveyProgress = 0
        surveyToneHz = nil
        surveyCaptures.removeAll()
        lastSurveyCaptureRevision = 0
        if !configuration.enabled {
            try? ambient.setQuietZoneObservationDemand(false)
        }
        spatialSurveyMessage =
            "Spatial survey cancelled or rejected. No phase coefficients were saved."
    }

    func setSpatialEnabled(_ enabled: Bool) throws {
        guard let project = ambient.projects.project,
              var calibration = spatialCalibration else {
            throw ActiveQuietZoneSpatialError.incompatibleMeasurement
        }
        _ = try calibration.validated(against: project)
        if enabled {
            guard !calibration.surveys.isEmpty else {
                throw ActiveQuietZoneSpatialError.inadequatePhaseReference
            }
        }
        if engine.activeQuietZoneRuntimeTarget.active {
            try engine.clearActiveQuietZoneRuntimeTarget(
                fadeMilliseconds: configuration.faultFadeMilliseconds
            )
        }
        resetRuntimeState()
        calibration.settings.enabled = enabled
        try spatialStore.save(calibration, for: project)
        spatialCalibration = calibration
        spatialPredictions = []
        refreshSpatialCalibration()
    }

    /// The ARM switch. `true` arms (one explicit user action) and starts the ramped-in canceller;
    /// `false` disarms with a ramped stop. The armed state is never persisted.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // E4 S15: a trip latched in an earlier arm must not keep the new one silent.
            engine.rearmHowlGuard()
            try arm.arm(environment: liveTreatmentEnvironment())
            flightRecorder.recordArm()
            armedGeneration = engine.liveTreatmentGeneration
            adaptiveLive?.reset()
            if let earned = earnedCap {
                let environment = liveTreatmentEnvironment()
                if let binding = earnedBinding(environment) {
                    earned.beginArm(binding: binding, outputGainDB: environment.outputGainDB)
                }
                engine.earnedCapInitialLinear = Float(earned.capLinear)
            }
            do {
                var updated = configuration
                updated.enabled = true
                try persist(updated)
                syncLowLatencyOutputProfile()
                faultLatched = false
                try start()
            } catch {
                arm.disarm(.user)
                throw error
            }
        } else {
            arm.disarm(.user)
            if configuration.enabled { applyDisarm(.user) }
        }
    }

    /// E4 S18b: runs the adaptive coordinator for this window. False when it disarmed.
    private func pollAdaptiveLive(_ snapshot: AmbientAnalysisSnapshot, verdict: DoNoHarmVerdict) -> Bool {
        guard let adaptive = adaptiveLive else { return true }
        var rampedIn = false
        if case .active = stage { rampedIn = true }
        let requests = adaptive.poll(AdaptiveTonalLivePollInput(
            now: ProcessInfo.processInfo.systemUptime,
            armed: arm.isArmed,
            controllerGeneration: armedGeneration,
            engineGeneration: engine.liveTreatmentGeneration,
            targetRampedIn: rampedIn,
            hasBaseline: doNoHarm.hasBaseline,
            verdict: verdict,
            measurement: doNoHarm.measure(snapshot),
            seeds: adaptiveSeeds,
            plannedPeakLinear: availableInjectionPeak,
            earnedCapActive: earnedCap != nil,
            leaseRequired: engine.activeQuietZoneLeaseEnabled,
            leaseRenewed: engine.activeQuietZoneLeaseHealthy
        ))
        if let earned = earnedCap {
            let facts = adaptive.earnedCapFacts
            let measurement = doNoHarm.measure(snapshot)
            earned.poll(EarnedCapPollFacts(
                now: ProcessInfo.processInfo.systemUptime,
                adapting: facts.adapting,
                verdict: verdict,
                measurement: measurement,
                guardOrHold: facts.guardTripped,
                playedPeakLinear: facts.playedPeakLinear,
                moveRecovering: adaptive.isCapRecovering
            ))
        }
        for request in requests {
            switch request {
            case .beginRebaseline:
                doNoHarm.beginRebaseline()
            case .disarm(let reason):
                arm.disarm(reason)
                return false
            }
        }
        return true
    }

    /// Environment the arm switch guards; observed with each controller poll.
    private func liveTreatmentEnvironment() -> LiveTreatmentEnvironment {
        var level: Double?
        let revision = ambient.analysisRevision
        if revision != lastMicrophoneRevision {
            lastMicrophoneRevision = revision
            level = ambient.latestAnalysis?.microphoneLevelDBFS
        }
        return LiveTreatmentEnvironment(
            outputDeviceUID: engine.routeConfiguration.selectedOutputUID,
            sampleRate: engine.liveTreatmentSampleRate,
            engineRunning: engine.lifecycleState == .running,
            inputAvailable: ambient.monitorStatus != .failed,
            microphoneLevelDBFS: level,
            inputDeviceUID: ambient.selectedInputDeviceUID,
            outputGainDB: engine.liveTreatmentOutputGainDB,
            microphoneSignalFault: ambient.microphoneSignalFault,
            howlGuardTripCount: engine.liveTreatmentHowlTripCount
        )
    }

    /// Called once per armed-to-disarmed transition: ramps the anti-noise out and returns the
    /// controller to the disabled state. The persisted configuration is already disabled.
    private func applyDisarm(_ reason: LiveTreatmentDisarmReason) {
        flightRecorder.recordDisarm(reason)
        adaptiveLive?.reset()
        earnedCap?.noteDisarm(reason)
        engine.earnedCapInitialLinear = 0
        // Revoke the engine arm token first: nothing built under this arm can play again.
        armedGeneration = nil
        engine.revokeLiveTreatmentArm()
        var updated = configuration
        updated.enabled = false
        configuration = updated
        syncLowLatencyOutputProfile()
        stop(fadeMilliseconds: LiveTreatmentSafeguards.rampMilliseconds(for: reason))
        if let message = reason.message { lastErrorDescription = message }
    }

    /// E4 S7: while armed, Quiet Zone uses the lowest-latency output buffer; disarming
    /// restores it. Always on (the former feature flag is gone).
    private func syncLowLatencyOutputProfile() {
        engine.setLowLatencyOutputProfile(configuration.enabled)
    }

    /// Arm ramp: never shorter than the always-on start ramp.
    private var startRampMilliseconds: Double {
        max(configuration.armRampMilliseconds, LiveTreatmentSafeguards.startRampMilliseconds)
    }

    func replaceConfiguration(
        _ rawConfiguration: ActiveQuietZoneConfiguration
    ) throws {
        var validated = try rawConfiguration.validated()
        // Only the ARM switch can turn live output on.
        validated.enabled = arm.isArmed
        if engine.activeQuietZoneRuntimeTarget.active {
            try engine.clearActiveQuietZoneRuntimeTarget(
                fadeMilliseconds:
                    configuration.faultFadeMilliseconds
            )
        }
        try persist(validated)
        resetRuntimeState()
        if validated.enabled {
            try start()
        } else {
            stop()
        }
    }

    func start() throws {
        try synchronizeSelectedPlaybackSystem()
        guard configuration.enabled else { return }

        try ambient.setQuietZoneObservationDemand(true)
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds:
                        ActiveQuietZoneController
                            .pollIntervalNanoseconds
                )
                guard !Task.isCancelled else { break }
                await self?.pollOnce()
            }
        }
        if engine.lifecycleState == .running,
           engine.activeQuietZoneStereoSpeakerRuntimeAvailable {
            status = .observe
            holdReason = nil
        } else {
            status = .hold
            holdReason = .unsupportedRoute
        }
        lastErrorDescription = nil
    }

    func stop(fadeMilliseconds: Double? = nil) {
        if spatialSurveyActive { cancelSpatialSurvey() }
        task?.cancel()
        task = nil
        try? engine.clearActiveQuietZoneRuntimeTarget(
            fadeMilliseconds:
                fadeMilliseconds
                ?? configuration.faultFadeMilliseconds
        )
        try? ambient.setQuietZoneObservationDemand(false)
        resetRuntimeState()
        status = .observe
        holdReason = .disabled
        lastErrorDescription = nil
    }

    func pollNowForTesting() async {
        await pollOnce()
    }

    private func pollOnce() async {
        do {
            try synchronizeSelectedPlaybackSystem()
            guard configuration.enabled else { return }
            let environment = liveTreatmentEnvironment()
            earnedCap?.observe(binding: earnedBinding(environment), outputGainDB: environment.outputGainDB)
            arm.observe(environment)
            guard arm.isArmed, configuration.enabled else { return }
            guard !faultLatched else { return }

            guard engine.lifecycleState == .running,
                  engine.activeQuietZoneStereoSpeakerRuntimeAvailable else {
                hold(.unsupportedRoute)
                return
            }

            availableInjectionPeak =
                LiveTreatmentSafeguards.limitedInjectionPeak(
                    try planner.availableInjectionPeak(
                        headroomAttenuationDB:
                            engine.gainConfiguration
                                .headroomAttenuationDB,
                        ambientLevelRecoveryDB:
                            ambient.appliedTarget.levelDB,
                        configuration: configuration
                    ),
                    capDBFS: earnedCap?.capDBFS ?? LiveTreatmentSafeguards.defaultPeakCapDBFS
                )
            guard availableInjectionPeak > 1.0e-7 else {
                hold(.insufficientOutputHeadroom)
                return
            }

            let revision = ambient.analysisRevision
            guard revision != 0,
                  revision != lastAnalysisRevision,
                  let detailed =
                    ambient.latestDetailedAnalysis else {
                return
            }
            lastAnalysisRevision = revision

            let snapshot = detailed.snapshot
            // E4 S16: the seat microphone is the judge. Runs before the trust checks so an
            // unstable-looking window cannot hide a regression.
            var verdict: DoNoHarmVerdict = .baselining
            var isObserving = false
            if case .observing = stage { isObserving = true }
            let rebaselining = adaptiveLive?.isRebaselining == true
            if (isObserving || rebaselining), !doNoHarm.hasBaseline {
                doNoHarm.captureBaseline(snapshot)
            } else {
                verdict = doNoHarm.evaluate(snapshot, now: Date())
                if case .harm = verdict {
                    verifiedReadout = nil
                    arm.reportSeatRegression()
                    return
                }
            }
            verifiedReadout = doNoHarm.readout
            if let readout = verifiedReadout { flightRecorder.record(.verifier, "Verified: \(readout)") }
            if !pollAdaptiveLive(snapshot, verdict: verdict) { return }
            guard trusted(snapshot) else {
                hold(
                    snapshot.separationMode
                        == .playbackModelUnavailable
                        ? .playbackSeparationUntrusted
                        : .noiseNotStationary
                )
                return
            }

            switch stage {
            case .observing:
                try observeForEligibility(
                    detailed: detailed,
                    revision: revision
                )

            case .phaseCalibration(
                let target,
                let startRevision
            ):
                guard runtimeStillOwns(target) else {
                    throw ActiveQuietZoneControllerError
                        .runtimeTargetLost
                }
                if revision - startRevision
                    >= UInt64(settleWindows) {
                    let evaluation = try evaluate(
                        scheduledTarget: target,
                        detailed: detailed
                    )
                    let probe = try probeTarget(
                        from: evaluation.desiredTarget
                    )
                    try engine
                        .replaceActiveQuietZoneRuntimeTarget(
                            probe
                        )
                    stage = .cancellationProbe(
                        target: probe,
                        startRevision: revision,
                        verificationWindows: 0
                    )
                    toneTelemetry = evaluation.telemetry
                    status = .probing
                    holdReason = .verificationPending
                }

            case .cancellationProbe(
                let target,
                let startRevision,
                let verificationWindows
            ):
                guard runtimeStillOwns(target) else {
                    throw ActiveQuietZoneControllerError
                        .runtimeTargetLost
                }
                guard revision - startRevision
                    >= UInt64(settleWindows) else {
                    return
                }

                let evaluation = try evaluate(
                    scheduledTarget: target,
                    detailed: detailed
                )
                toneTelemetry = evaluation.telemetry

                if evaluation.decisions.contains(
                    .faultRegression
                ) || evaluation.decisions.contains(.invalid) {
                    fault(
                        ActiveQuietZoneControllerError
                            .verificationRegression,
                        reason: .verificationRegression
                    )
                    return
                }

                if evaluation.decisions.allSatisfy({
                    $0 == .accept
                }) {
                    try engine
                        .replaceActiveQuietZoneRuntimeTarget(
                            evaluation.desiredTarget
                        )
                    stage = .active(
                        target: evaluation.desiredTarget,
                        startRevision: revision
                    )
                    weakActiveWindows = 0
                    status = .cancelling
                    holdReason = nil
                    return
                }

                let nextCount = verificationWindows + 1
                if nextCount
                    >= Self.maximumProbeVerificationWindows {
                    hold(.verificationPending)
                    return
                }

                // Rephase the same bounded probe only while physical evidence is
                // non-regressive. It cannot increase beyond probe amplitude.
                let refreshedProbe = try probeTarget(
                    from: evaluation.desiredTarget
                )
                try engine
                    .replaceActiveQuietZoneRuntimeTarget(
                        refreshedProbe
                    )
                stage = .cancellationProbe(
                    target: refreshedProbe,
                    startRevision: revision,
                    verificationWindows: nextCount
                )
                status = .probing
                holdReason = .verificationPending

            case .active(
                let target,
                let startRevision
            ):
                guard runtimeStillOwns(target) else {
                    throw ActiveQuietZoneControllerError
                        .runtimeTargetLost
                }
                guard revision - startRevision
                    >= UInt64(settleWindows) else {
                    return
                }

                let evaluation = try evaluate(
                    scheduledTarget: target,
                    detailed: detailed
                )
                toneTelemetry = evaluation.telemetry

                if evaluation.decisions.contains(
                    .faultRegression
                ) || evaluation.decisions.contains(.invalid) {
                    fault(
                        ActiveQuietZoneControllerError
                            .runtimeTargetLost,
                        reason: .protectionActive
                    )
                    return
                }

                if evaluation.decisions.allSatisfy({
                    $0 == .accept
                }) {
                    // A fresh measured improvement authorizes the next bounded
                    // coefficient update. No successful measurement, no gain-up.
                    try engine
                        .replaceActiveQuietZoneRuntimeTarget(
                            evaluation.desiredTarget
                        )
                    stage = .active(
                        target: evaluation.desiredTarget,
                        startRevision: revision
                    )
                    weakActiveWindows = 0
                    status = .cancelling
                    holdReason = nil
                } else {
                    weakActiveWindows += 1
                    if weakActiveWindows
                        >= Self.maximumWeakActiveWindows {
                        hold(.verificationPending)
                    }
                }
            }
        } catch {
            fault(
                error,
                reason: .ambientEvidenceUnavailable
            )
        }
    }

    private func observeForEligibility(
        detailed: AmbientAnalysisDetailedResult,
        revision: UInt64
    ) throws {
        guard let position = ambient.selectedModelPosition else {
            hold(.acousticModelRequired)
            return
        }
        if spatialCalibration?.settings.enabled == true {
            guard let calibration = spatialCalibration,
                  let project = ambient.projects.project,
                  calibration.projectID == project.id,
                  calibration.playbackSystemID
                    == profiles.selectedSystemProfileID,
                  calibration.anchorPositionID == position.id,
                  ambient.roomProjectMatchesSelectedMicrophone,
                  (try? calibration.validated(against: project)) != nil,
                  calibration.surveys.contains(where: {
                      let age = Date().timeIntervalSince(
                          $0.capturedAt
                      )
                      return age >= 0 && age < 1800
                          && $0.commonPhaseReferenceValidated
                  })
            else {
                hold(.phaseReferenceUnavailable)
                return
            }
        }
        guard abs(
            position.sampleRate
                - detailed.snapshot.sampleRate
        ) < 0.5 else {
            throw ActiveQuietZoneControllerError
                .acousticModelSampleRateMismatch(
                    measurement: position.sampleRate,
                    analysis: detailed.snapshot.sampleRate
                )
        }

        let eligible = try planner.eligibleTones(
            snapshot: detailed.snapshot,
            allowMicrophoneOnly: true,
            configuration: configuration
        )
        guard !eligible.isEmpty else {
            persistence.removeAll()
            status = .observe
            holdReason = .noEligibleTone
            controlledFrequenciesHz = []
            toneTelemetry = []
            return
        }

        let stable = updatePersistence(eligible)
        guard !stable.isEmpty else {
            status = .eligible
            holdReason = .toneNotPersistent
            return
        }

        let target = try phaseCalibrationTarget(
            candidates: stable
        )
        try engine.replaceActiveQuietZoneRuntimeTarget(
            target
        )
        engine.setActiveQuietZoneReferenceDemand(true)
        engine.discardActiveQuietZoneReferenceFrames()

        controlledFrequenciesHz =
            target.tones.map(\.frequencyHz)
        stage = .phaseCalibration(
            target: target,
            startRevision: revision
        )
        status = .probing
        holdReason = .verificationPending
    }

    private func updatePersistence(
        _ candidates: [ActiveQuietZoneCandidateTone]
    ) -> [ActiveQuietZoneCandidateTone] {
        var unused = persistence
        var updated: [PersistenceState] = []

        for candidate in candidates {
            if let index = unused.indices.min(by: {
                abs(
                    unused[$0].candidate.frequencyHz
                        - candidate.frequencyHz
                )
                < abs(
                    unused[$1].candidate.frequencyHz
                        - candidate.frequencyHz
                )
            }),
               abs(
                    unused[index].candidate.frequencyHz
                        - candidate.frequencyHz
               ) <= configuration.stableFrequencyToleranceHz {
                let old = unused.remove(at: index)
                updated.append(
                    PersistenceState(
                        candidate: candidate,
                        count: old.count + 1
                    )
                )
            } else {
                updated.append(
                    PersistenceState(
                        candidate: candidate,
                        count: 1
                    )
                )
            }
        }

        persistence = updated
        return updated
            .filter {
                $0.count >= configuration.requiredStableWindows
            }
            .map(\.candidate)
            .sorted { $0.levelDBFS > $1.levelDBFS }
            .prefix(configuration.maximumToneCount)
            .map { $0 }
            .sorted { $0.frequencyHz < $1.frequencyHz }
    }

    private func phaseCalibrationTarget(
        candidates: [ActiveQuietZoneCandidateTone]
    ) throws -> ActiveQuietZoneRuntimeTarget {
        // The ambient FFT peak is a coarse bin center. A validated PR95
        // survey provides the finer stationary oscillator frequency. Choose
        // only one spatial tone so the per-seat predictions correspond to
        // the eventual PR90 aggregate headroom-limited output.
        let selected: [ActiveQuietZoneCandidateTone]
        if let calibration = spatialCalibration,
           calibration.settings.enabled {
            let matching = candidates.compactMap {
                candidate -> (
                    ActiveQuietZoneCandidateTone,
                    ActiveQuietZoneSpatialToneSurvey
                )? in
                guard let survey = calibration.surveys.first(where: {
                    abs($0.frequencyHz - candidate.frequencyHz) <= 2.0
                        && Date().timeIntervalSince($0.capturedAt) >= 0
                        && Date().timeIntervalSince($0.capturedAt) < 1800
                        && (try? calibration.validatedSurvey(
                            for: $0.frequencyHz
                        )) != nil
                }) else {
                    return nil
                }
                return (candidate, survey)
            }
            guard let match = matching.max(by: {
                $0.0.levelDBFS < $1.0.levelDBFS
            }) else {
                throw ActiveQuietZoneSpatialError.inadequatePhaseReference
            }
            let (candidate, survey) = match
            selected = [
                ActiveQuietZoneCandidateTone(
                    frequencyHz: survey.frequencyHz,
                    levelDBFS: candidate.levelDBFS,
                    prominenceDB: candidate.prominenceDB
                )
            ]
        } else {
            selected = candidates
        }
        let probePeak = pow(
            10,
            configuration.probePeakDBFS / 20
        )
        let count = max(selected.count, 1)
        let aggregateShare =
            availableInjectionPeak / Double(count) * 0.75
        let amplitude = min(probePeak, aggregateShare)
        guard amplitude > 1.0e-8 else {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        let target = ActiveQuietZoneRuntimeTarget(
            tones: selected.map {
                ActiveQuietZoneRuntimeTone(
                    frequencyHz: $0.frequencyHz,
                    leftOutput: ActiveQuietZoneComplex(
                        real: amplitude,
                        imaginary: 0
                    ),
                    rightOutput: .zero
                )
            },
            transitionMilliseconds:
                startRampMilliseconds,
            armGeneration: armedGeneration
        )
        return try target.validated(
            configuration: configuration
        )
    }

    private func probeTarget(
        from fullTarget: ActiveQuietZoneRuntimeTarget
    ) throws -> ActiveQuietZoneRuntimeTarget {
        let probeMaximum = pow(
            10,
            configuration.probePeakDBFS / 20
        )
        let largestTone = fullTarget.tones.reduce(0.0) {
            max(
                $0,
                max(
                    $1.leftOutput.magnitude,
                    $1.rightOutput.magnitude
                )
            )
        }
        let aggregate = fullTarget.maximumSourceMagnitude
        let scale = min(
            1,
            probeMaximum / max(largestTone, 1.0e-15),
            availableInjectionPeak / max(aggregate, 1.0e-15)
        )

        let target = ActiveQuietZoneRuntimeTarget(
            tones: fullTarget.tones.map {
                ActiveQuietZoneRuntimeTone(
                    frequencyHz: $0.frequencyHz,
                    leftOutput: $0.leftOutput * scale,
                    rightOutput: $0.rightOutput * scale
                )
            },
            transitionMilliseconds:
                startRampMilliseconds,
            armGeneration: armedGeneration
        )
        return try target.validated(
            configuration: configuration
        )
    }

    private func evaluate(
        scheduledTarget: ActiveQuietZoneRuntimeTarget,
        detailed: AmbientAnalysisDetailedResult
    ) throws -> Evaluation {
        guard let model = ambient.selectedModelPosition else {
            throw ActiveQuietZoneControllerError
                .acousticModelRequired
        }
        guard abs(model.sampleRate - detailed.snapshot.sampleRate) < 0.5 else {
            throw ActiveQuietZoneControllerError
                .acousticModelSampleRateMismatch(
                    measurement: model.sampleRate,
                    analysis: detailed.snapshot.sampleRate
                )
        }
        guard let reference =
                ambient
                    .quietZoneReferenceAlignedToLatestAnalysis(),
              reference.left.count
                == detailed.separatedResidualSamples.count,
              reference.right.count
                == detailed.separatedResidualSamples.count else {
            throw ActiveQuietZoneControllerError
                .ambientSensorUnavailable
        }

        let sampleRate = detailed.snapshot.sampleRate
        let spatial = spatialCalibration?.settings.enabled == true
        if spatial {
            guard let calibration = spatialCalibration,
                  let project = ambient.projects.project,
                  calibration.projectID == project.id,
                  calibration.playbackSystemID == profiles.selectedSystemProfileID,
                  calibration.anchorPositionID == model.id,
                  ambient.roomProjectMatchesSelectedMicrophone
            else { throw ActiveQuietZoneSpatialError.mismatchedAnchor }
            _ = try calibration.validated(against: project)
        }
        var desiredTones: [ActiveQuietZoneRuntimeTone] = []
        var latestSpatialPredictions:
            [ActiveQuietZoneSpatialSeatPrediction] = []
        var telemetry: [ActiveQuietZoneToneTelemetry] = []
        var seeds: [AdaptiveQuietZoneSeed] = []
        var decisions:
            [ActiveQuietZoneVerification.Decision] = []

        for scheduled in scheduledTarget.tones {
            let frequency = scheduled.frequencyHz
            let leftReference = try planner.tonePhasor(
                samples: reference.left,
                frequencyHz: frequency,
                sampleRate: sampleRate
            )
            let rightReference = try planner.tonePhasor(
                samples: reference.right,
                frequencyHz: frequency,
                sampleRate: sampleRate
            )

            let basis: ActiveQuietZoneComplex
            if scheduled.leftOutput.magnitude
                    >= scheduled.rightOutput.magnitude,
               scheduled.leftOutput.magnitude > 1.0e-8,
               leftReference.magnitude > 1.0e-8 {
                basis = try planner.oscillatorPhaseBasis(
                    observedSourcePhasor: leftReference,
                    scheduledCoefficient:
                        scheduled.leftOutput
                )
            } else if scheduled.rightOutput.magnitude > 1.0e-8,
                      rightReference.magnitude > 1.0e-8 {
                basis = try planner.oscillatorPhaseBasis(
                    observedSourcePhasor: rightReference,
                    scheduledCoefficient:
                        scheduled.rightOutput
                )
            } else {
                throw ActiveQuietZoneControllerError
                    .phaseReferenceUnavailable(frequency)
            }

            let errorPhasor = try planner.tonePhasor(
                samples: detailed.separatedResidualSamples,
                frequencyHz: frequency,
                sampleRate: sampleRate
            )
            let leftPath = try planner.secondaryPath(
                impulseResponse: model.left.impulseResponse,
                frequencyHz: frequency,
                sampleRate: sampleRate
            )
            let rightPath = try planner.secondaryPath(
                impulseResponse: model.right.impulseResponse,
                frequencyHz: frequency,
                sampleRate: sampleRate
            )

            let disturbance =
                errorPhasor
                - leftPath * leftReference
                - rightPath * rightReference
            let outputLeft: ActiveQuietZoneComplex
            let outputRight: ActiveQuietZoneComplex
            let predictedDB: Double
            if spatial {
                guard let calibration = spatialCalibration,
                      let project = ambient.projects.project,
                      let survey = try? calibration.validatedSurvey(
                        for: frequency
                      ),
                      Date().timeIntervalSince(survey.capturedAt) < 1800,
                      Date().timeIntervalSince(survey.capturedAt) >= 0
                else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
                let candidate = try spatialPlanner.solve(
                    calibration: calibration,
                    project: project,
                    frequencyHz: frequency,
                    liveAnchorDisturbance: disturbance,
                    availableInjectionPeak: availableInjectionPeak,
                    quietZoneConfiguration: configuration
                )
                outputLeft = candidate.leftOutput
                outputRight = candidate.rightOutput
                predictedDB = candidate.weightedReductionDB
                latestSpatialPredictions = candidate.predictions
            } else {
                let solution = try planner.solveStereo(
                    frequencyHz: frequency,
                    disturbance: disturbance,
                    leftSecondaryPath: leftPath,
                    rightSecondaryPath: rightPath,
                    availableInjectionPeak:
                        availableInjectionPeak,
                    configuration: configuration
                )
                outputLeft = solution.leftOutput
                outputRight = solution.rightOutput
                predictedDB = solution.predictedReductionDB
            }

            let desiredLeft =
                try planner.runtimeCoefficient(
                    sourcePhasorInMicrophoneBasis:
                        outputLeft,
                    oscillatorPhaseBasis: basis
                )
            let desiredRight =
                try planner.runtimeCoefficient(
                    sourcePhasorInMicrophoneBasis:
                        outputRight,
                    oscillatorPhaseBasis: basis
                )
            desiredTones.append(
                ActiveQuietZoneRuntimeTone(
                    frequencyHz: frequency,
                    leftOutput: desiredLeft,
                    rightOutput: desiredRight
                )
            )
            seeds.append(
                AdaptiveQuietZoneSeed(
                    frequencyHz: frequency,
                    leftPath: leftPath,
                    rightPath: rightPath,
                    leftOutput: outputLeft,
                    rightOutput: outputRight
                )
            )

            let verification = try planner.verify(
                beforeLevelDBFS:
                    disturbance.magnitudeDB,
                afterLevelDBFS:
                    errorPhasor.magnitudeDB,
                configuration: configuration
            )
            decisions.append(verification.decision)
            telemetry.append(
                ActiveQuietZoneToneTelemetry(
                    frequencyHz: frequency,
                    disturbanceLevelDBFS:
                        disturbance.magnitudeDB,
                    residualLevelDBFS:
                        errorPhasor.magnitudeDB,
                    measuredReductionDB:
                        verification.measuredReductionDB,
                    predictedReductionDB:
                        predictedDB,
                    leftSourceLevelDBFS:
                        desiredLeft.magnitudeDB,
                    rightSourceLevelDBFS:
                        desiredRight.magnitudeDB
                )
            )
        }

        spatialPredictions = latestSpatialPredictions
        adaptiveSeeds = seeds
        let desired = try aggregateLimitedTarget(
            tones: desiredTones
        )
        return Evaluation(
            desiredTarget: desired,
            telemetry: telemetry,
            decisions: decisions
        )
    }

    private func aggregateLimitedTarget(
        tones: [ActiveQuietZoneRuntimeTone]
    ) throws -> ActiveQuietZoneRuntimeTarget {
        let aggregate = max(
            tones.reduce(0.0) {
                $0 + $1.leftOutput.magnitude
            },
            tones.reduce(0.0) {
                $0 + $1.rightOutput.magnitude
            }
        )
        let hardAggregate = pow(
            10,
            configuration
                .maximumAggregateSourcePeakDBFS / 20
        )
        let permitted = min(
            hardAggregate,
            availableInjectionPeak
        )
        let scale =
            aggregate > permitted && aggregate > 0
                ? permitted / aggregate
                : 1

        let target = ActiveQuietZoneRuntimeTarget(
            tones: tones.map {
                ActiveQuietZoneRuntimeTone(
                    frequencyHz: $0.frequencyHz,
                    leftOutput: $0.leftOutput * scale,
                    rightOutput: $0.rightOutput * scale
                )
            },
            transitionMilliseconds:
                startRampMilliseconds,
            armGeneration: armedGeneration
        )
        return try target.validated(
            configuration: configuration
        )
    }

    private func trusted(
        _ snapshot: AmbientAnalysisSnapshot
    ) -> Bool {
        guard snapshot.stationarityScore
                >= configuration.minimumStationarity,
              snapshot.character != .nonstationary else {
            return false
        }
        switch snapshot.separationMode {
        case .modeledPlaybackSubtraction:
            return snapshot.separationConfidence
                >= configuration.minimumSeparationConfidence
        case .microphoneOnly:
            return true
        case .playbackModelUnavailable:
            return false
        }
    }

    private var settleWindows: Int {
        max(
            3,
            Int(
                ceil(
                    startRampMilliseconds
                        / 250.0
                )
            ) + 2
        )
    }

    private func runtimeStillOwns(
        _ target: ActiveQuietZoneRuntimeTarget
    ) -> Bool {
        let actual = engine.activeQuietZoneRuntimeTarget
        return actual.active
            && actual.sameFrequencies(as: target)
    }

    private func persist(
        _ rawConfiguration: ActiveQuietZoneConfiguration
    ) throws {
        guard profiles.selectedSystemProfileID != nil else {
            throw ActiveQuietZoneControllerError
                .playbackSystemRequired
        }
        let validated = try rawConfiguration.validated()
        // The armed state is never persisted as on.
        var stored = validated
        stored.enabled = false
        try profiles.replaceSelectedSystemActiveQuietZone(
            stored
        )
        configuration = validated
        activeSystemID = profiles.selectedSystemProfileID
        lastErrorDescription = nil
    }

    private func synchronizeSelectedPlaybackSystem() throws {
        guard let systemID = profiles.selectedSystemProfileID else {
            throw ActiveQuietZoneControllerError
                .playbackSystemRequired
        }
        guard activeSystemID != systemID else { return }

        arm.disarm(.outputDeviceChanged)
        if engine.activeQuietZoneRuntimeTarget.active {
            try? engine.clearActiveQuietZoneRuntimeTarget(
                fadeMilliseconds:
                    configuration.faultFadeMilliseconds
            )
        }
        try? ambient.setQuietZoneObservationDemand(false)
        resetRuntimeState()
        configuration =
            profiles.selectedSystemProfile?.state
                .activeQuietZone
            ?? ActiveQuietZoneConfiguration()
        _ = try configuration.validated()
        // Armed state is never restored: a stored "enabled" from an older build is ignored.
        configuration.enabled = false
        spatialCalibration = nil
        spatialPredictions = []
        feedForwardCalibration = nil
        feedForwardBudget = .missing
        feedForwardMessage = "Playback System changed; review reference timing before any future use."
        if spatialSurveyActive { cancelSpatialSurvey() }
        activeSystemID = systemID
        if configuration.enabled {
            try ambient.setQuietZoneObservationDemand(true)
        } else {
            task?.cancel()
            task = nil
        }
    }

    private func hold(
        _ reason: ActiveQuietZoneHoldReason
    ) {
        if engine.activeQuietZoneRuntimeTarget.active {
            try? engine.clearActiveQuietZoneRuntimeTarget(
                fadeMilliseconds:
                    configuration.faultFadeMilliseconds
            )
        }
        stage = .observing
        controlledFrequenciesHz = []
        toneTelemetry = []
        persistence.removeAll()
        weakActiveWindows = 0
        status = .hold
        holdReason = reason
    }

    private func fault(
        _ error: Error,
        reason: ActiveQuietZoneHoldReason
    ) {
        if engine.activeQuietZoneRuntimeTarget.active {
            try? engine.clearActiveQuietZoneRuntimeTarget(
                fadeMilliseconds:
                    configuration.faultFadeMilliseconds
            )
        }
        stage = .observing
        controlledFrequenciesHz = []
        persistence.removeAll()
        weakActiveWindows = 0
        faultLatched = true
        status = .fault
        holdReason = reason
        lastErrorDescription = error.localizedDescription
    }

    private func resetRuntimeState() {
        stage = .observing
        persistence.removeAll()
        controlledFrequenciesHz = []
        toneTelemetry = []
        spatialPredictions = []
        availableInjectionPeak = 0
        lastAnalysisRevision = 0
        weakActiveWindows = 0
        faultLatched = false
        doNoHarm.reset()
        verifiedReadout = nil
    }
}
