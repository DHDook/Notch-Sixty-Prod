import Combine
import CoreAudio
import Foundation

protocol AmbientMonitorTransporting: AnyObject {
    var sampleRate: Double { get }
    func start() throws
    func stop()
    func readAvailableFrames(maximumFrames: Int) throws -> [Float]
    /// E4 S18b: as `readAvailableFrames`, also giving the host-time anchor of the first frame.
    func readAvailableFramesWithAnchor(
        maximumFrames: Int
    ) throws -> (samples: [Float], anchor: AmbientMonitorTransport.ReadAnchor?)
    func discardBufferedFrames()
}

extension AmbientMonitorTransporting {
    /// Transports without host-time anchors (test doubles) read unanchored.
    func readAvailableFramesWithAnchor(
        maximumFrames: Int
    ) throws -> (samples: [Float], anchor: AmbientMonitorTransport.ReadAnchor?) {
        (try readAvailableFrames(maximumFrames: maximumFrames), nil)
    }
}

extension AmbientMonitorTransport: AmbientMonitorTransporting {}

typealias AmbientMonitorTransportFactory = (
    AudioInputDevice,
    Int
) throws -> any AmbientMonitorTransporting

enum AmbientCompensationMonitorStatus: String, Equatable, Sendable {
    case stopped
    case observing
    case compensating
    case held
    case failed

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .observing: return "Observing"
        case .compensating: return "Compensating"
        case .held: return "Hold"
        case .failed: return "Fault"
        }
    }
}

enum AmbientCompensationControllerError:
    Error, Equatable, LocalizedError
{
    case playbackSystemRequired
    case microphonePermissionRequired
    case microphoneRequired
    case roomModelRequired
    case roomModelMicrophoneMismatch
    case roomModelSampleRateMismatch(
        measurement: Double,
        monitor: Double
    )
    case playbackReferenceSampleRateMismatch(
        playback: Double,
        monitor: Double
    )
    case insufficientBaselineEvidence

    var errorDescription: String? {
        switch self {
        case .playbackSystemRequired:
            return "Select a Playback System before configuring Ambient Compensation."
        case .microphonePermissionRequired:
            return "Microphone access is required for Ambient Compensation."
        case .microphoneRequired:
            return "Select an ambient/measurement microphone before starting Ambient Compensation."
        case .roomModelRequired:
            return "Choose a retained Room Correction position to model the loudspeakers at the ambient microphone."
        case .roomModelMicrophoneMismatch:
            return "The selected ambient microphone or input channel does not match the microphone used by this Room Correction project."
        case .roomModelSampleRateMismatch(let measurement, let monitor):
            return "The selected room model was measured at \(measurement) Hz but the ambient microphone is running at \(monitor) Hz."
        case .playbackReferenceSampleRateMismatch(let playback, let monitor):
            return "The playback reference is \(playback) Hz but the ambient microphone is \(monitor) Hz; automatic compensation is held."
        case .insufficientBaselineEvidence:
            return "A quiet baseline can be captured only from microphone-only observation or a high-confidence separated ambient estimate."
        }
    }
}

@MainActor
final class AmbientCompensationController: ObservableObject {
    static let pollIntervalNanoseconds: UInt64 = 250_000_000
    static let maximumHistoryFrames = 131_072
    static let preferredAnalysisFrames = 32_768
    /// E4 S30c (G4): the analysis window must span a whole poll or the speech history sees a gap each time (and the
    /// microphone ring drops frames). At 48 kHz a poll is 12,000 frames; at 384 kHz it is 96,000. The window is 1.2
    /// polls, never less than the preferred 32,768 frames, and the read limit is two polls, capped at `maximumHistoryFrames` (at 384 kHz that is about 1.4 polls, still more than one).
    static func analysisFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return preferredAnalysisFrames }
        let poll = sampleRate * Double(pollIntervalNanoseconds) / 1_000_000_000
        return min(max(preferredAnalysisFrames, Int((poll * 1.2).rounded(.up))), maximumHistoryFrames)
    }
    static func readLimitFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return preferredAnalysisFrames }
        let poll = sampleRate * Double(pollIntervalNanoseconds) / 1_000_000_000
        return min(max(preferredAnalysisFrames, Int((poll * 2).rounded(.up))), maximumHistoryFrames)
    }
    static let minimumAnalysisFrames = 4_096
    static let maximumImpulseTaps = 8_192

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let projects: RoomCorrectionProjectController

    private let transportFactory: AmbientMonitorTransportFactory
    private let planner = AmbientCompensationPlanner()
    private let conversationPlanner =
        ConversationPreservationPlanner()
    private var envelope = AmbientCompensationEnvelope()
    private var monitor: (any AmbientMonitorTransporting)?
    private var pollTask: Task<Void, Never>?
    private var microphoneHistory: [Float] = []
    /// Monotonic count of frames pulled from this uninterrupted monitor session.
    /// A monitor reset changes epoch; never phase-compare across epochs.
    private var spatialMicrophoneFrameEnd: UInt64 = 0
    private var spatialMicrophoneEpoch: UUID = UUID()
    private var spatialLatestWindowEndFrame: UInt64 = 0
    private var playbackLeftHistory: [Float] = []
    private var playbackRightHistory: [Float] = []
    private var quietZoneLeftHistory: [Float] = []
    private var quietZoneRightHistory: [Float] = []
    private var latestQuietZoneRawLeft: [Float] = []
    private var latestQuietZoneRawRight: [Float] = []
    private var activeSystemID: UUID?
    private var quietZoneObservationDemand = false
    /// E4 S30b (`e4.conversation-unmasking`, set by the app shell; off by default). On: each poll feeds the
    /// 4 s speech-envelope history, passes its confidence to the Conversation Focus planner (which then skips
    /// the non-stationary hold for speech), and plans per-band cuts into `latestUnmasking`. Nothing is sent to
    /// the engine until S30c.
    var unmaskingInputsEnabled = false
    private var speechHistory = SpeechEnvelopeHistory()
    /// The quiet-room spectrum captured with the quiet baseline. Held in memory only (the persisted baseline is
    /// a single level); until S30c persists it, the planner falls back when it is missing.
    private var quietBaselineSpectrum: [AmbientSpectrumBand]?
    /// Positive dB cut per SII band that is currently in the playback reference. Nothing applies cuts until
    /// S30c, which sets this from the cuts it sends.
    private(set) var unmaskingAppliedCutsDB = [Double](
        repeating: 0, count: SpeechIntelligibilityBands.centersHz.count
    )
    /// E4 S30c: rate-limits the planned cuts and releases them (see `ConversationUnmaskingGovernor`).
    private var unmaskingGovernor = ConversationUnmaskingGovernor()
    /// True while the target carries the cut trailer, so a poll with nothing to cut does not flip the graph topology.
    private var unmaskingTrailerSent = false
    private(set) var latestUnmasking: ConversationUnmaskingEvaluation?
    /// E4 S30c: the Conversation Focus card, refreshed each poll; nil with the flag off or outside Conversation Focus.
    @Published private(set) var unmaskingCard: ConversationUnmaskingCardModel?
    /// E4 S6: receives every block of error-microphone frames this controller
    /// reads (frames, sample rate, monitor epoch, and whether frames were
    /// skipped since the previous block). The adaptive Quiet Zone shadow uses
    /// it; it must not retain or modify anything here.
    var microphoneFramesObserver: (([Float], Double, UUID, Bool) -> Void)?
    /// E4 S18b: as `microphoneFramesObserver`, with the host time (mach ticks) of the first frame
    /// (nil when no anchor covers it). While set, reads use the anchored path; unset (the default,
    /// flag off) reads exactly as before.
    var anchoredMicrophoneFramesObserver: (([Float], Double, UUID, Bool, UInt64?) -> Void)?
    /// Set when a poll returns without reading, so the next block is marked
    /// as following a gap.
    private var microphoneFramesSkipped = false
    /// E4 S12: the latest raw-signal fault seen in the error microphone's frames, cleared by
    /// the next clean block. Read by the live-treatment arm switch.
    private(set) var microphoneSignalFault: MicrophoneSignalFault?

    /// Stable UID of the selected measurement microphone, for the arm switch.
    var selectedInputDeviceUID: String? { microphone.selectedInputDevice?.uid }

    @Published private(set) var configuration =
        AmbientCompensationConfiguration()
    @Published private(set) var monitorStatus:
        AmbientCompensationMonitorStatus = .stopped
    @Published private(set) var latestAnalysis:
        AmbientAnalysisSnapshot?
    /// Shared control observation for PR90. Kept out of @Published because the
    /// residual sample window is control data, not UI state.
    private(set) var latestDetailedAnalysis:
        AmbientAnalysisDetailedResult?
    private(set) var analysisRevision: UInt64 = 0

    struct PhaseReferencedMicWindow: Sendable {
        var epoch: UUID
        var revision: UInt64
        var firstSampleIndex: UInt64
        var sampleRate: Double
        var samples: [Float]
        var stationarity: Double
        var toneCandidates: [AmbientTonalComponent]
    }

    /// Only live microphone-only observation. Playing audio through the
    /// speakers while moving the mic invalidates the shared-phase survey.
    func phaseReferencedMicWindow() -> PhaseReferencedMicWindow? {
        guard engine.lifecycleState != .running,
              let detailed = latestDetailedAnalysis,
              detailed.snapshot.separationMode == .microphoneOnly,
              detailed.snapshot.stationarityScore >= 0.85,
              spatialLatestWindowEndFrame
                >= UInt64(detailed.separatedResidualSamples.count)
        else { return nil }
        return PhaseReferencedMicWindow(
            epoch: spatialMicrophoneEpoch,
            revision: analysisRevision,
            firstSampleIndex: spatialLatestWindowEndFrame
                - UInt64(detailed.separatedResidualSamples.count),
            sampleRate: detailed.snapshot.sampleRate,
            samples: detailed.separatedResidualSamples,
            stationarity: detailed.snapshot.stationarityScore,
            toneCandidates: detailed.snapshot.tonalComponents
        )
    }
    @Published private(set) var appliedTarget =
        AmbientCompensationTarget.unity
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        projects: RoomCorrectionProjectController,
        transportFactory: @escaping AmbientMonitorTransportFactory = {
            input, channel in
            try AmbientMonitorTransport(
                input: input,
                inputChannelIndex: channel
            )
        }
    ) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.projects = projects
        self.transportFactory = transportFactory
        // E4 S30d (G14): a transport teardown (rebuild, rate change, device change) drops the graph that held the
        // unmasking cuts, so the governor, the applied-cuts record and the speech history restart with the new session.
        // The observer holds self weakly.
        _ = engine.addTransportTeardownObserver { [weak self] _ in
            self?.resetAnalysisHistory()
        }
    }

    /// E4 S30d: whether the live graph can realise unmasking cuts. The engine's answer unless a test injects one.
    var unmaskingRuntimeAvailableProvider: (() -> Bool)?
    private var unmaskingRuntimeAvailable: Bool {
        unmaskingRuntimeAvailableProvider?() ?? engine.ambientUnmaskingRuntimeAvailable
    }

    /// Test seams (E4 S30d, G13): the planner result of the latest poll, and the configuration, without a monitor.
    func setUnmaskingEvaluationForTesting(_ evaluation: ConversationUnmaskingEvaluation?) {
        latestUnmasking = evaluation
    }
    func installConfigurationForTesting(_ configuration: AmbientCompensationConfiguration) {
        self.configuration = configuration
    }

    var availableModelPositions: [RoomCorrectionMeasurementPosition] {
        guard roomProjectMatchesSelectedMicrophone else { return [] }
        return projects.positions.filter {
            !$0.left.impulseResponse.isEmpty
                && !$0.right.impulseResponse.isEmpty
        }
    }

    var roomProjectMatchesSelectedMicrophone: Bool {
        guard let selected = microphone.selectedInputDevice,
              let projectMic = projects.project?.microphone else {
            return false
        }
        return projectMic.stableID == selected.uid
            && projectMic.inputChannelIndex
                == microphone.selectedInputChannelIndex
            && projectMic.calibration
                == microphone.microphoneCalibration
    }

    var selectedModelPosition: RoomCorrectionMeasurementPosition? {
        guard let id = configuration.playbackModelPositionID else {
            return nil
        }
        return availableModelPositions.first { $0.id == id }
    }

    var currentAmbientDisplayDB: Double? {
        latestAnalysis?.ambientLevelDBSPL
            ?? latestAnalysis?.ambientLevelDBFS
    }

    var currentAmbientDisplayUsesSPL: Bool {
        latestAnalysis?.ambientLevelDBSPL != nil
    }

    var playbackAdaptationMode:
        ActiveAcousticsPlaybackAdaptationMode {
        configuration.effectivePlaybackAdaptationMode
    }

    var playbackAdaptationActive: Bool {
        playbackAdaptationMode != .off
    }

    func prepareForUse() {
        do {
            try synchronizeSelectedPlaybackSystem()
            if (playbackAdaptationActive
                    || quietZoneObservationDemand),
               microphone.permissionStatus == .authorized,
               microphone.selectedInputDevice != nil {
                try startMonitoring()
            } else {
                try engine.clearAmbientCompensationRuntimeTarget()
                monitorStatus = .stopped
            }
            lastErrorDescription = nil
        } catch {
            fail(error)
        }
    }

    /// Legacy PR89 compatibility. New UI should select an explicit playback
    /// adaptation mode instead of toggling Ambient Compensation directly.
    func setEnabled(_ enabled: Bool) throws {
        try setPlaybackAdaptationMode(
            enabled ? .musicFocus : .off
        )
    }

    func setPlaybackAdaptationMode(
        _ mode: ActiveAcousticsPlaybackAdaptationMode
    ) throws {
        guard mode != playbackAdaptationMode else { return }

        var updated = configuration
        updated.playbackAdaptationMode = mode
        // Keep the legacy bit coherent for older exported/system-profile
        // readers while the optional mode is the authoritative PR91 value.
        updated.enabled = mode != .off
        try persist(updated)

        envelope.reset()
        appliedTarget = .unity
        try? engine.clearAmbientCompensationRuntimeTarget()
        resetAnalysisHistory()

        if mode != .off {
            try startMonitoring()
        } else if quietZoneObservationDemand {
            try startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func setQuietZoneObservationDemand(
        _ enabled: Bool
    ) throws {
        quietZoneObservationDemand = enabled
        if enabled {
            try startMonitoring()
        } else if !playbackAdaptationActive {
            stopMonitoring()
        }
    }

    func setStrength(_ strength: Double) throws {
        var updated = configuration
        updated.strength = strength
        try persist(updated)
    }

    func setLevelCompensationEnabled(_ enabled: Bool) throws {
        var updated = configuration
        updated.levelCompensationEnabled = enabled
        try persist(updated)
    }

    func setMaximumLevelCompensationDB(_ value: Double) throws {
        var updated = configuration
        updated.maximumLevelCompensationDB = value
        try persist(updated)
    }

    func setTiming(
        attackSeconds: Double,
        releaseSeconds: Double
    ) throws {
        var updated = configuration
        updated.attackSeconds = attackSeconds
        updated.releaseSeconds = releaseSeconds
        try persist(updated)
    }

    func setMinimumSeparationConfidence(_ value: Double) throws {
        var updated = configuration
        updated.minimumSeparationConfidence = value
        try persist(updated)
    }

    func setPlaybackModelPosition(_ id: UUID?) throws {
        var updated = configuration
        updated.playbackModelPositionID = id
        try persist(updated)
        resetAnalysisHistory()
    }

    func setOptionalSPLReference(_ value: Double?) throws {
        var updated = configuration
        updated.optionalDBSPLAt0DBFS = value
        try persist(updated)
    }

    func captureQuietBaseline() throws {
        guard let analysis = latestAnalysis else {
            throw AmbientCompensationControllerError
                .insufficientBaselineEvidence
        }
        let trusted: Bool
        switch analysis.separationMode {
        case .microphoneOnly:
            trusted = engine.lifecycleState != .running
        case .modeledPlaybackSubtraction:
            trusted = analysis.separationConfidence
                >= configuration.minimumSeparationConfidence
        case .playbackModelUnavailable:
            trusted = false
        }
        guard trusted,
              analysis.character != .nonstationary else {
            throw AmbientCompensationControllerError
                .insufficientBaselineEvidence
        }

        var updated = configuration
        updated.baselineAmbientLevelDBFS =
            analysis.ambientLevelDBFS
        try persist(updated)
        quietBaselineSpectrum = analysis.spectrum
    }

    func clearQuietBaseline() throws {
        var updated = configuration
        updated.baselineAmbientLevelDBFS = nil
        try persist(updated)
        quietBaselineSpectrum = nil
    }

    func startMonitoring() throws {
        try synchronizeSelectedPlaybackSystem()
        guard playbackAdaptationActive
                || quietZoneObservationDemand else {
            return
        }
        guard microphone.permissionStatus == .authorized else {
            throw AmbientCompensationControllerError
                .microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw AmbientCompensationControllerError.microphoneRequired
        }

        if monitor != nil {
            return
        }

        let created = try transportFactory(
            input,
            microphone.selectedInputChannelIndex
        )
        try created.start()
        created.discardBufferedFrames()
        monitor = created
        resetAnalysisHistory()
        engine.discardAmbientPlaybackReferenceFrames()
        engine.discardActiveQuietZoneReferenceFrames()
        engine.setAmbientPlaybackReferenceDemand(
            engine.ambientPlaybackReferenceAvailable
        )
        engine.setActiveQuietZoneReferenceDemand(
            engine.activeQuietZoneReferenceAvailable
        )
        monitorStatus = .observing
        lastErrorDescription = nil

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds:
                        AmbientCompensationController
                            .pollIntervalNanoseconds
                )
                guard !Task.isCancelled else { break }
                await self?.pollOnce()
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        monitor?.stop()
        monitor = nil
        engine.setAmbientPlaybackReferenceDemand(false)
        engine.setActiveQuietZoneReferenceDemand(false)
        engine.discardAmbientPlaybackReferenceFrames()
        engine.discardActiveQuietZoneReferenceFrames()
        resetAnalysisHistory()
        envelope.reset()
        appliedTarget = .unity
        try? engine.clearAmbientCompensationRuntimeTarget()
        monitorStatus = .stopped
        lastErrorDescription = nil
    }

    func pollNowForTesting() async {
        await pollOnce()
    }

    private func pollOnce() async {
        do {
            try synchronizeSelectedPlaybackSystem()
            guard playbackAdaptationActive
                    || quietZoneObservationDemand,
                  let monitor else {
                microphoneFramesSkipped = true
                return
            }

            let newlyCaptured: [Float]
            var firstFrameHostTime: UInt64?
            if anchoredMicrophoneFramesObserver != nil {
                let read = try monitor.readAvailableFramesWithAnchor(
                    maximumFrames: Self.readLimitFrames(sampleRate: monitor.sampleRate)
                )
                newlyCaptured = read.samples
                if let anchor = read.anchor, monitor.sampleRate > 0 {
                    let offsetSeconds = Double(anchor.frameOffset) / monitor.sampleRate
                    firstFrameHostTime = anchor.hostTime
                        &+ AudioConvertNanosToHostTime(UInt64((offsetSeconds * 1.0e9).rounded()))
                }
            } else {
                newlyCaptured = try monitor.readAvailableFrames(
                    maximumFrames: Self.readLimitFrames(sampleRate: monitor.sampleRate)
                )
            }
            spatialMicrophoneFrameEnd &+= UInt64(newlyCaptured.count)
            if !newlyCaptured.isEmpty {
                microphoneSignalFault = MicrophoneSignalCheck.assess(newlyCaptured)
                microphoneFramesObserver?(
                    newlyCaptured,
                    monitor.sampleRate,
                    spatialMicrophoneEpoch,
                    microphoneFramesSkipped
                )
                anchoredMicrophoneFramesObserver?(
                    newlyCaptured,
                    monitor.sampleRate,
                    spatialMicrophoneEpoch,
                    microphoneFramesSkipped,
                    firstFrameHostTime
                )
                microphoneFramesSkipped = false
            }
            Self.appendCapped(
                newlyCaptured,
                to: &microphoneHistory
            )

            let referenceAvailable =
                engine.ambientPlaybackReferenceAvailable
            engine.setAmbientPlaybackReferenceDemand(
                referenceAvailable
            )
            if referenceAvailable {
                let frames =
                    engine.readAmbientPlaybackReferenceFrames(
                        maximumFrames:
                            Self.readLimitFrames(sampleRate: monitor.sampleRate)
                    )
                if !frames.isEmpty {
                    Self.appendCapped(
                        frames.map(\.left),
                        to: &playbackLeftHistory
                    )
                    Self.appendCapped(
                        frames.map(\.right),
                        to: &playbackRightHistory
                    )
                }

                let quietFrames =
                    engine.readActiveQuietZoneReferenceFrames(
                        maximumFrames:
                            Self.readLimitFrames(sampleRate: monitor.sampleRate)
                    )
                if !quietFrames.isEmpty {
                    Self.appendCapped(
                        quietFrames.map(\.left),
                        to: &quietZoneLeftHistory
                    )
                    Self.appendCapped(
                        quietFrames.map(\.right),
                        to: &quietZoneRightHistory
                    )
                }
            } else {
                playbackLeftHistory.removeAll(
                    keepingCapacity: true
                )
                playbackRightHistory.removeAll(
                    keepingCapacity: true
                )
                quietZoneLeftHistory.removeAll(
                    keepingCapacity: true
                )
                quietZoneRightHistory.removeAll(
                    keepingCapacity: true
                )
            }

            guard microphoneHistory.count
                    >= Self.minimumAnalysisFrames else {
                return
            }

            let running = engine.lifecycleState == .running
            if running,
               referenceAvailable,
               min(
                    playbackLeftHistory.count,
                    playbackRightHistory.count
               ) < Self.minimumAnalysisFrames {
                let held = AmbientCompensationTarget(
                    activity: appliedTarget.activity,
                    levelDB: 0,
                    lowSupportDB: 0,
                    presenceSupportDB: 0,
                    detailSupportDB: 0,
                    confidence: 0,
                    ambientDeltaDB: appliedTarget.ambientDeltaDB,
                    holdReason: .invalidEvidence,
                    mode: playbackAdaptationMode
                )
                var smoothed = try envelope.update(
                    toward: held,
                    configuration: configuration,
                    elapsedSeconds:
                        Double(Self.pollIntervalNanoseconds)
                            / 1_000_000_000
                )
                attachUnmaskingCuts(to: &smoothed, mode: playbackAdaptationMode, freshAnalysis: false)
                try engine
                    .replaceAmbientCompensationRuntimeTarget(
                        smoothed
                    )
                appliedTarget = smoothed
                unmaskingCutsWereSent(smoothed)
                monitorStatus = .held
                lastErrorDescription = nil
                return
            }

            let detailed = try await makeAnalysis(
                monitorSampleRate: monitor.sampleRate,
                playbackRunning: running,
                playbackReferenceAvailable: referenceAvailable
            )
            let analysis = detailed.snapshot
            latestDetailedAnalysis = detailed
            latestAnalysis = analysis
            spatialLatestWindowEndFrame = spatialMicrophoneFrameEnd
            analysisRevision &+= 1

            let mode = playbackAdaptationMode
            let speechConfidence = updateUnmaskingInputs(
                detailed: detailed, mode: mode, running: running
            )
            let planned: AmbientCompensationTarget
            if mode == .off {
                planned = .unity
                monitorStatus = .observing
            } else if !running {
                planned = AmbientCompensationTarget(
                    activity: .quiet,
                    levelDB: 0,
                    lowSupportDB: 0,
                    presenceSupportDB: 0,
                    detailSupportDB: 0,
                    confidence: analysis.separationConfidence,
                    ambientDeltaDB: 0,
                    holdReason: nil,
                    mode: mode
                )
                monitorStatus = .observing
            } else if !referenceAvailable
                        || analysis.separationMode
                            == .microphoneOnly {
                // Running playback must never use a microphone-only
                // estimate for automatic adaptation. This also covers
                // startup windows where the independent rendered
                // reference ring has not accumulated enough frames yet.
                planned = heldTarget(
                    reason: .playbackModelRequired,
                    analysis: analysis
                )
            } else {
                switch mode {
                case .off:
                    planned = .unity
                case .musicFocus:
                    planned = try planner.plan(
                        snapshot: analysis,
                        configuration: configuration,
                        availableHeadroomDB:
                            engine
                                .ambientCompensationAvailableHeadroomDB,
                        previousActivity: appliedTarget.activity
                    )
                case .conversationFocus:
                    let broad = try conversationPlanner.plan(
                        snapshot: analysis,
                        configuration: configuration,
                        previousActivity: appliedTarget.activity,
                        speechModulationConfidence: speechConfidence
                    )
                    // E4 S30c: with a complete per-band plan, Conversation Focus sends the unmasking cuts only
                    // (level and the three bands at 0). Missing inputs keep today's broad cut.
                    if unmaskingInputsEnabled, unmaskingRuntimeAvailable,
                       case .planned(let plan)? = latestUnmasking?.status {
                        planned = AmbientCompensationTarget(
                            activity: broad.activity,
                            levelDB: 0,
                            lowSupportDB: 0,
                            presenceSupportDB: 0,
                            detailSupportDB: 0,
                            confidence: broad.confidence,
                            ambientDeltaDB: broad.ambientDeltaDB,
                            holdReason: nil,
                            mode: .conversationFocus,
                            conversationEvidence: speechConfidence ?? broad.conversationEvidence,
                            estimatedClearanceDB: max(-plan.overallChangeDB, 0)
                        )
                    } else {
                        planned = broad
                    }
                }
            }

            var smoothed = try envelope.update(
                toward: planned,
                configuration: configuration,
                elapsedSeconds:
                    Double(Self.pollIntervalNanoseconds)
                        / 1_000_000_000
            )
            attachUnmaskingCuts(to: &smoothed, mode: mode, freshAnalysis: true)
            try engine.replaceAmbientCompensationRuntimeTarget(
                smoothed
            )
            appliedTarget = smoothed
            unmaskingCutsWereSent(smoothed)
            if smoothed.holdReason != nil {
                monitorStatus = .held
            } else if smoothed.active {
                monitorStatus = .compensating
            } else {
                monitorStatus = .observing
            }
            lastErrorDescription = nil
        } catch {
            fail(error)
        }
    }

    private func makeAnalysis(
        monitorSampleRate: Double,
        playbackRunning: Bool,
        playbackReferenceAvailable: Bool
    ) async throws -> AmbientAnalysisDetailedResult {
        var analysisConfiguration =
            AmbientAnalysisConfiguration.production
        analysisConfiguration.optionalDBSPLAt0DBFS =
            configuration.optionalDBSPLAt0DBFS
        let windowFrames = Self.analysisFrames(sampleRate: monitorSampleRate)
        analysisConfiguration.maximumAnalysisFrames = max(analysisConfiguration.maximumAnalysisFrames, windowFrames)
        let analyzer = AmbientFieldAnalyzer(
            configuration: analysisConfiguration
        )

        if !playbackRunning {
            let count = min(
                microphoneHistory.count,
                windowFrames
            )
            let microphoneWindow =
                Array(microphoneHistory.suffix(count))
            return try await Task.detached(
                priority: .utility
            ) {
                try analyzer.analyzeDetailed(
                    microphone: microphoneWindow,
                    playbackSources: [],
                    sampleRate: monitorSampleRate
                )
            }.value
        }

        guard playbackReferenceAvailable,
              let playbackRate =
                engine.ambientPlaybackReferenceSampleRate else {
            let count = min(
                microphoneHistory.count,
                windowFrames
            )
            let microphoneWindow =
                Array(microphoneHistory.suffix(count))
            return try await Task.detached(
                priority: .utility
            ) {
                try analyzer.analyzeDetailed(
                    microphone: microphoneWindow,
                    playbackSources: [],
                    sampleRate: monitorSampleRate
                )
            }.value
        }
        guard abs(playbackRate - monitorSampleRate) < 0.5 else {
            throw AmbientCompensationControllerError
                .playbackReferenceSampleRateMismatch(
                    playback: playbackRate,
                    monitor: monitorSampleRate
                )
        }

        let quietReferenceRequired =
            engine.activeQuietZoneRuntimeTarget.active
        let quietCount =
            quietReferenceRequired
                ? min(
                    quietZoneLeftHistory.count,
                    quietZoneRightHistory.count
                )
                : Int.max
        let count = min(
            microphoneHistory.count,
            playbackLeftHistory.count,
            playbackRightHistory.count,
            quietCount,
            windowFrames
        )
        guard count >= Self.minimumAnalysisFrames else {
            throw AmbientAnalysisError.insufficientSamples(
                minimum: Self.minimumAnalysisFrames,
                actual: count
            )
        }

        let mic = Array(microphoneHistory.suffix(count))
        let renderedLeft =
            Array(playbackLeftHistory.suffix(count))
        let renderedRight =
            Array(playbackRightHistory.suffix(count))
        let quietLeft =
            quietZoneLeftHistory.count >= count
                ? Array(quietZoneLeftHistory.suffix(count))
                : [Float](repeating: 0, count: count)
        let quietRight =
            quietZoneRightHistory.count >= count
                ? Array(quietZoneRightHistory.suffix(count))
                : [Float](repeating: 0, count: count)

        // PR90 verification must observe the physical d + anti-noise residual.
        // Model/subtract program playback only; never subtract the anti-noise
        // contribution from the error microphone.
        let left = zip(renderedLeft, quietLeft).map {
            $0.0 - $0.1
        }
        let right = zip(renderedRight, quietRight).map {
            $0.0 - $0.1
        }
        latestQuietZoneRawLeft = quietLeft
        latestQuietZoneRawRight = quietRight

        let sourceModel = try acousticModel(
            monitorSampleRate: monitorSampleRate
        )

        let sources: [AmbientPlaybackSourceReference]
        if let sourceModel {
            sources = [
                AmbientPlaybackSourceReference(
                    id: "left-speaker",
                    samples: left,
                    acousticImpulseResponse:
                        sourceModel.leftImpulse
                ),
                AmbientPlaybackSourceReference(
                    id: "right-speaker",
                    samples: right,
                    acousticImpulseResponse:
                        sourceModel.rightImpulse
                ),
            ]
        } else {
            // Preserve the actual playback references but omit the
            // impulse responses. AmbientFieldAnalyzer will explicitly
            // return playbackModelUnavailable when the playback is
            // audible instead of relabeling it as room noise.
            sources = [
                AmbientPlaybackSourceReference(
                    id: "left-speaker",
                    samples: left
                ),
                AmbientPlaybackSourceReference(
                    id: "right-speaker",
                    samples: right
                ),
            ]
        }

        return try await Task.detached(
            priority: .utility
        ) {
            try analyzer.analyzeDetailed(
                microphone: mic,
                playbackSources: sources,
                sampleRate: monitorSampleRate
            )
        }.value
    }

    private struct AcousticModel: Sendable {
        var leftImpulse: [Float]
        var rightImpulse: [Float]
    }

    private func acousticModel(
        monitorSampleRate: Double
    ) throws -> AcousticModel? {
        guard configuration.playbackModelPositionID != nil else {
            return nil
        }
        guard roomProjectMatchesSelectedMicrophone else {
            throw AmbientCompensationControllerError
                .roomModelMicrophoneMismatch
        }
        guard let position = selectedModelPosition else {
            throw AmbientCompensationControllerError
                .roomModelRequired
        }
        guard abs(position.sampleRate - monitorSampleRate) < 0.5 else {
            throw AmbientCompensationControllerError
                .roomModelSampleRateMismatch(
                    measurement: position.sampleRate,
                    monitor: monitorSampleRate
                )
        }
        let left = Array(
            position.left.impulseResponse.prefix(
                Self.maximumImpulseTaps
            )
        )
        let right = Array(
            position.right.impulseResponse.prefix(
                Self.maximumImpulseTaps
            )
        )
        guard !left.isEmpty,
              !right.isEmpty,
              left.allSatisfy({ $0.isFinite }),
              right.allSatisfy({ $0.isFinite }) else {
            throw AmbientCompensationControllerError
                .roomModelRequired
        }
        return AcousticModel(
            leftImpulse: left,
            rightImpulse: right
        )
    }

    private func persist(
        _ rawConfiguration: AmbientCompensationConfiguration
    ) throws {
        guard profiles.selectedSystemProfileID != nil else {
            throw AmbientCompensationControllerError
                .playbackSystemRequired
        }
        let validated = try rawConfiguration.validated()
        try profiles.replaceSelectedSystemAmbientCompensation(
            validated
        )
        configuration = validated
        activeSystemID = profiles.selectedSystemProfileID
        lastErrorDescription = nil
    }

    private func synchronizeSelectedPlaybackSystem() throws {
        guard let systemID = profiles.selectedSystemProfileID else {
            throw AmbientCompensationControllerError
                .playbackSystemRequired
        }
        guard activeSystemID != systemID else { return }

        monitor?.stop()
        monitor = nil
        pollTask?.cancel()
        pollTask = nil
        engine.setAmbientPlaybackReferenceDemand(false)
        engine.setActiveQuietZoneReferenceDemand(false)
        try? engine.clearAmbientCompensationRuntimeTarget()
        envelope.reset()
        resetAnalysisHistory()
        quietBaselineSpectrum = nil
        appliedTarget = .unity
        configuration =
            profiles.selectedSystemProfile?.state
                .ambientCompensation
            ?? AmbientCompensationConfiguration()
        _ = try configuration.validated()
        activeSystemID = systemID
        monitorStatus = .stopped
    }

    /// E4 G23 test seam: installs the control observation a live window would leave (the detailed analysis and the
    /// raw rendered reference) so `ActiveQuietZoneController.evaluate` can be driven without a microphone. It only
    /// stores the values the live path stores; nothing else changes.
    func installQuietZoneObservationForTesting(
        detailed: AmbientAnalysisDetailedResult, rawLeft: [Float], rawRight: [Float]
    ) {
        latestDetailedAnalysis = detailed
        latestQuietZoneRawLeft = rawLeft
        latestQuietZoneRawRight = rawRight
        analysisRevision &+= 1
    }

    func quietZoneReferenceAlignedToLatestAnalysis()
        -> (left: [Float], right: [Float])? {
        guard let detailed = latestDetailedAnalysis else {
            return nil
        }
        let count = detailed.separatedResidualSamples.count
        guard count > 0,
              latestQuietZoneRawLeft.count == count,
              latestQuietZoneRawRight.count == count else {
            return nil
        }
        let lag = detailed.playbackAlignmentLagFrames ?? 0

        func aligned(_ source: [Float]) -> [Float] {
            var result = [Float](repeating: 0, count: count)
            for index in result.indices {
                let sourceIndex = index - lag
                if sourceIndex >= 0,
                   sourceIndex < source.count {
                    result[index] = source[sourceIndex]
                }
            }
            return result
        }

        return (
            aligned(latestQuietZoneRawLeft),
            aligned(latestQuietZoneRawRight)
        )
    }

    /// Feeds the speech-envelope history and refreshes `latestUnmasking`. Returns the speech confidence for the
    /// planners, or nil with the flag off (today's behaviour exactly).
    private func updateUnmaskingInputs(
        detailed: AmbientAnalysisDetailedResult,
        mode: ActiveAcousticsPlaybackAdaptationMode,
        running: Bool
    ) -> Double? {
        guard unmaskingInputsEnabled else {
            speechHistory.reset()
            unmaskingGovernor.reset()
            latestUnmasking = nil
            return nil
        }
        speechHistory.append(
            window: detailed.separatedResidualSamples,
            endFrame: spatialMicrophoneFrameEnd,
            sampleRate: detailed.snapshot.sampleRate,
            epoch: spatialMicrophoneEpoch,
            microphoneID: microphone.selectedInputDevice?.uid
        )
        let confidence = speechHistory.confidence
        latestUnmasking = ConversationUnmaskingEvaluator.evaluate(
            mode: mode,
            running: running,
            detailed: detailed,
            quietBaseline: quietBaselineSpectrum,
            envelopeSeconds: speechHistory.seconds,
            speechConfidence: confidence,
            appliedCutsDB: unmaskingAppliedCutsDB,
            minimumSeparationConfidence: configuration.minimumSeparationConfidence
        )
        return confidence
    }

    /// E4 S30c: puts the governed cuts on the target about to be sent, or none. Cuts go out only with the flag on, in
    /// Conversation Focus, and where the live graph can realise them (not the legacy kernel); otherwise the governor
    /// is cleared at once (flag off, mode change) and the target carries none.
    func attachUnmaskingCuts(
        to target: inout AmbientCompensationTarget,
        mode: ActiveAcousticsPlaybackAdaptationMode,
        freshAnalysis: Bool
    ) {
        let elapsed = Double(Self.pollIntervalNanoseconds) / 1_000_000_000
        guard unmaskingInputsEnabled, mode == .conversationFocus, unmaskingRuntimeAvailable else {
            unmaskingGovernor.reset()
            unmaskingTrailerSent = false
            return
        }
        let cuts = freshAnalysis
            ? unmaskingGovernor.update(evaluation: latestUnmasking, elapsedSeconds: elapsed)
            : unmaskingGovernor.noAnalysis(elapsedSeconds: elapsed)
        var planned = false
        if freshAnalysis, case .planned? = latestUnmasking?.status { planned = true }
        guard unmaskingGovernor.isEngaged || planned || (unmaskingTrailerSent && !freshAnalysis) else {
            unmaskingTrailerSent = false
            return
        }
        target.unmaskingCutsDB = cuts
        // A transient hold resolves to a default target mode; the engine accepts cuts only in Conversation Focus.
        target.mode = .conversationFocus
    }

    /// The engine accepted `target`: the cuts it carried are now in the playback reference (G7).
    func unmaskingCutsWereSent(_ target: AmbientCompensationTarget) {
        unmaskingAppliedCutsDB = target.unmaskingCutsDB
            ?? [Double](repeating: 0, count: SpeechIntelligibilityBands.centersHz.count)
        unmaskingTrailerSent = target.unmaskingCutsDB != nil
        refreshUnmaskingCard()
    }

    private func refreshUnmaskingCard() {
        guard unmaskingInputsEnabled, playbackAdaptationMode == .conversationFocus,
              let evaluation = latestUnmasking, let rate = latestAnalysis?.sampleRate else {
            if unmaskingCard != nil { unmaskingCard = nil }
            return
        }
        unmaskingCard = ConversationUnmaskingCardModel(
            evaluation: evaluation, appliedCutsDB: unmaskingAppliedCutsDB, sampleRate: rate)
    }

    func resetAnalysisHistory() {
        speechHistory.reset()
        unmaskingGovernor.reset()
        unmaskingTrailerSent = false
        unmaskingAppliedCutsDB = [Double](repeating: 0, count: SpeechIntelligibilityBands.centersHz.count)
        unmaskingCard = nil
        latestUnmasking = nil
        spatialMicrophoneEpoch = UUID()
        spatialMicrophoneFrameEnd = 0
        spatialLatestWindowEndFrame = 0
        microphoneHistory.removeAll(keepingCapacity: true)
        playbackLeftHistory.removeAll(keepingCapacity: true)
        playbackRightHistory.removeAll(keepingCapacity: true)
        quietZoneLeftHistory.removeAll(keepingCapacity: true)
        quietZoneRightHistory.removeAll(keepingCapacity: true)
        latestQuietZoneRawLeft.removeAll(keepingCapacity: true)
        latestQuietZoneRawRight.removeAll(keepingCapacity: true)
        latestAnalysis = nil
        latestDetailedAnalysis = nil
    }

    private static func appendCapped(
        _ new: [Float],
        to history: inout [Float]
    ) {
        guard !new.isEmpty else { return }
        history.append(contentsOf: new)
        if history.count > Self.maximumHistoryFrames {
            history.removeFirst(
                history.count - Self.maximumHistoryFrames
            )
        }
    }

    private func heldTarget(
        reason: AmbientCompensationHoldReason,
        analysis: AmbientAnalysisSnapshot
    ) -> AmbientCompensationTarget {
        AmbientCompensationTarget(
            activity: appliedTarget.activity,
            levelDB: 0,
            lowSupportDB: 0,
            presenceSupportDB: 0,
            detailSupportDB: 0,
            confidence: analysis.separationConfidence,
            ambientDeltaDB: max(
                analysis.ambientLevelDBFS
                    - (configuration
                        .baselineAmbientLevelDBFS
                        ?? analysis.ambientLevelDBFS),
                0
            ),
            holdReason: reason,
            mode: playbackAdaptationMode,
            conversationEvidence:
                appliedTarget.conversationEvidence,
            estimatedClearanceDB:
                appliedTarget.estimatedClearanceDB
        )
    }

    private func fail(_ error: Error) {
        pollTask?.cancel()
        pollTask = nil
        monitor?.stop()
        monitor = nil
        engine.setAmbientPlaybackReferenceDemand(false)
        engine.setActiveQuietZoneReferenceDemand(false)
        engine.discardAmbientPlaybackReferenceFrames()
        engine.discardActiveQuietZoneReferenceFrames()
        resetAnalysisHistory()
        lastErrorDescription = error.localizedDescription
        monitorStatus = .failed
        envelope.reset()
        appliedTarget = .unity
        try? engine.clearAmbientCompensationRuntimeTarget()
    }
}
