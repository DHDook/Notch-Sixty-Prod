import Combine
import Foundation

protocol AmbientMonitorTransporting: AnyObject {
    var sampleRate: Double { get }
    func start() throws
    func stop()
    func readAvailableFrames(maximumFrames: Int) throws -> [Float]
    func discardBufferedFrames()
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
    static let maximumHistoryFrames = 65_536
    static let preferredAnalysisFrames = 32_768
    static let minimumAnalysisFrames = 4_096
    static let maximumImpulseTaps = 8_192

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let projects: RoomCorrectionProjectController

    private let transportFactory: AmbientMonitorTransportFactory
    private let planner = AmbientCompensationPlanner()
    private var envelope = AmbientCompensationEnvelope()
    private var monitor: (any AmbientMonitorTransporting)?
    private var pollTask: Task<Void, Never>?
    private var microphoneHistory: [Float] = []
    private var playbackLeftHistory: [Float] = []
    private var playbackRightHistory: [Float] = []
    private var activeSystemID: UUID?

    @Published private(set) var configuration =
        AmbientCompensationConfiguration()
    @Published private(set) var monitorStatus:
        AmbientCompensationMonitorStatus = .stopped
    @Published private(set) var latestAnalysis:
        AmbientAnalysisSnapshot?
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

    func prepareForUse() {
        do {
            try synchronizeSelectedPlaybackSystem()
            if configuration.enabled,
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

    func setEnabled(_ enabled: Bool) throws {
        var updated = configuration
        updated.enabled = enabled
        try persist(updated)
        if enabled {
            try startMonitoring()
        } else {
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
    }

    func clearQuietBaseline() throws {
        var updated = configuration
        updated.baselineAmbientLevelDBFS = nil
        try persist(updated)
    }

    func startMonitoring() throws {
        try synchronizeSelectedPlaybackSystem()
        guard configuration.enabled else { return }
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
        engine.setAmbientPlaybackReferenceDemand(
            engine.ambientPlaybackReferenceAvailable
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
        engine.discardAmbientPlaybackReferenceFrames()
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
            guard configuration.enabled,
                  let monitor else {
                return
            }

            Self.appendCapped(
                try monitor.readAvailableFrames(
                    maximumFrames: Self.preferredAnalysisFrames
                ),
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
                            Self.preferredAnalysisFrames
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
            } else {
                playbackLeftHistory.removeAll(
                    keepingCapacity: true
                )
                playbackRightHistory.removeAll(
                    keepingCapacity: true
                )
            }

            guard microphoneHistory.count
                    >= Self.minimumAnalysisFrames else {
                return
            }

            let running = engine.lifecycleState == .running
            let analysis = try await makeAnalysis(
                monitorSampleRate: monitor.sampleRate,
                playbackRunning: running,
                playbackReferenceAvailable: referenceAvailable
            )
            latestAnalysis = analysis

            let planned: AmbientCompensationTarget
            if !running {
                planned = AmbientCompensationTarget(
                    activity: .quiet,
                    levelDB: 0,
                    lowSupportDB: 0,
                    presenceSupportDB: 0,
                    detailSupportDB: 0,
                    confidence: analysis.separationConfidence,
                    ambientDeltaDB: 0,
                    holdReason: nil
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
                planned = try planner.plan(
                    snapshot: analysis,
                    configuration: configuration,
                    availableHeadroomDB:
                        engine
                            .ambientCompensationAvailableHeadroomDB,
                    previousActivity: appliedTarget.activity
                )
            }

            let smoothed = try envelope.update(
                toward: planned,
                configuration: configuration,
                elapsedSeconds:
                    Double(Self.pollIntervalNanoseconds)
                        / 1_000_000_000
            )
            try engine.replaceAmbientCompensationRuntimeTarget(
                smoothed
            )
            appliedTarget = smoothed
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
    ) async throws -> AmbientAnalysisSnapshot {
        var analysisConfiguration =
            AmbientAnalysisConfiguration.production
        analysisConfiguration.optionalDBSPLAt0DBFS =
            configuration.optionalDBSPLAt0DBFS
        let analyzer = AmbientFieldAnalyzer(
            configuration: analysisConfiguration
        )

        if !playbackRunning {
            let count = min(
                microphoneHistory.count,
                Self.preferredAnalysisFrames
            )
            let microphoneWindow =
                Array(microphoneHistory.suffix(count))
            return try await Task.detached(
                priority: .utility
            ) {
                try analyzer.analyze(
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
                Self.preferredAnalysisFrames
            )
            let microphoneWindow =
                Array(microphoneHistory.suffix(count))
            return try await Task.detached(
                priority: .utility
            ) {
                try analyzer.analyze(
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

        let count = min(
            microphoneHistory.count,
            playbackLeftHistory.count,
            playbackRightHistory.count,
            Self.preferredAnalysisFrames
        )
        guard count >= Self.minimumAnalysisFrames else {
            let microphoneWindow = Array(
                microphoneHistory.suffix(
                    min(
                        microphoneHistory.count,
                        Self.preferredAnalysisFrames
                    )
                )
            )
            return try await Task.detached(
                priority: .utility
            ) {
                try analyzer.analyze(
                    microphone: microphoneWindow,
                    playbackSources: [],
                    sampleRate: monitorSampleRate
                )
            }.value
        }

        let mic = Array(microphoneHistory.suffix(count))
        let left = Array(playbackLeftHistory.suffix(count))
        let right = Array(playbackRightHistory.suffix(count))
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
            try analyzer.analyze(
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
        try? engine.clearAmbientCompensationRuntimeTarget()
        envelope.reset()
        resetAnalysisHistory()
        appliedTarget = .unity
        configuration =
            profiles.selectedSystemProfile?.state
                .ambientCompensation
            ?? AmbientCompensationConfiguration()
        _ = try configuration.validated()
        activeSystemID = systemID
        monitorStatus = .stopped
    }

    private func resetAnalysisHistory() {
        microphoneHistory.removeAll(keepingCapacity: true)
        playbackLeftHistory.removeAll(keepingCapacity: true)
        playbackRightHistory.removeAll(keepingCapacity: true)
        latestAnalysis = nil
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
            holdReason: reason
        )
    }

    private func fail(_ error: Error) {
        pollTask?.cancel()
        pollTask = nil
        monitor?.stop()
        monitor = nil
        engine.setAmbientPlaybackReferenceDemand(false)
        engine.discardAmbientPlaybackReferenceFrames()
        lastErrorDescription = error.localizedDescription
        monitorStatus = .failed
        envelope.reset()
        appliedTarget = .unity
        try? engine.clearAmbientCompensationRuntimeTarget()
    }
}
