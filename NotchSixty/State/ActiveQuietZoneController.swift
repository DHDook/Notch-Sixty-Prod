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

    private let planner = ActiveQuietZonePlanner()
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
        [ActiveQuietZoneToneTelemetry] = []
    @Published private(set) var availableInjectionPeak: Double = 0
    @Published private(set) var lastErrorDescription: String?

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

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        ambient: AmbientCompensationController
    ) {
        self.engine = engine
        self.profiles = profiles
        self.ambient = ambient
    }

    deinit {
        task?.cancel()
    }

    func prepareForUse() {
        do {
            try synchronizeSelectedPlaybackSystem()
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

    func setEnabled(_ enabled: Bool) throws {
        var updated = configuration
        updated.enabled = enabled
        try persist(updated)

        if enabled {
            faultLatched = false
            try start()
        } else {
            stop()
        }
    }

    func replaceConfiguration(
        _ rawConfiguration: ActiveQuietZoneConfiguration
    ) throws {
        let validated = try rawConfiguration.validated()
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

    func stop() {
        task?.cancel()
        task = nil
        try? engine.clearActiveQuietZoneRuntimeTarget(
            fadeMilliseconds:
                configuration.faultFadeMilliseconds
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
            guard !faultLatched else { return }

            guard engine.lifecycleState == .running,
                  engine.activeQuietZoneStereoSpeakerRuntimeAvailable else {
                hold(.unsupportedRoute)
                return
            }

            availableInjectionPeak =
                try planner.availableInjectionPeak(
                    headroomAttenuationDB:
                        engine.gainConfiguration
                            .headroomAttenuationDB,
                    ambientLevelRecoveryDB:
                        ambient.appliedTarget.levelDB,
                    configuration: configuration
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
        let probePeak = pow(
            10,
            configuration.probePeakDBFS / 20
        )
        let count = max(candidates.count, 1)
        let aggregateShare =
            availableInjectionPeak / Double(count) * 0.75
        let amplitude = min(probePeak, aggregateShare)
        guard amplitude > 1.0e-8 else {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        let target = ActiveQuietZoneRuntimeTarget(
            tones: candidates.map {
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
                configuration.armRampMilliseconds
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
                configuration.armRampMilliseconds
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
        var desiredTones: [ActiveQuietZoneRuntimeTone] = []
        var telemetry: [ActiveQuietZoneToneTelemetry] = []
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
            let solution = try planner.solveStereo(
                frequencyHz: frequency,
                disturbance: disturbance,
                leftSecondaryPath: leftPath,
                rightSecondaryPath: rightPath,
                availableInjectionPeak:
                    availableInjectionPeak,
                configuration: configuration
            )

            let desiredLeft =
                try planner.runtimeCoefficient(
                    sourcePhasorInMicrophoneBasis:
                        solution.leftOutput,
                    oscillatorPhaseBasis: basis
                )
            let desiredRight =
                try planner.runtimeCoefficient(
                    sourcePhasorInMicrophoneBasis:
                        solution.rightOutput,
                    oscillatorPhaseBasis: basis
                )
            desiredTones.append(
                ActiveQuietZoneRuntimeTone(
                    frequencyHz: frequency,
                    leftOutput: desiredLeft,
                    rightOutput: desiredRight
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
                        solution.predictedReductionDB,
                    leftSourceLevelDBFS:
                        desiredLeft.magnitudeDB,
                    rightSourceLevelDBFS:
                        desiredRight.magnitudeDB
                )
            )
        }

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
                configuration.armRampMilliseconds
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
                    configuration.armRampMilliseconds
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
        try profiles.replaceSelectedSystemActiveQuietZone(
            validated
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
        availableInjectionPeak = 0
        lastAnalysisRevision = 0
        weakActiveWindows = 0
        faultLatched = false
    }
}
