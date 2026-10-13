import Foundation
import Combine

struct HeadroomAssistantBoundary: Equatable, Sendable {
    let selectedContentPresetID: UUID?
    let selectedSystemProfileID: UUID?
    let contentState: ContentPresetState
    let systemState: PlaybackSystemState

    @MainActor
    init(profiles: ProductProfileController) {
        selectedContentPresetID = profiles.selectedContentPresetID
        selectedSystemProfileID = profiles.selectedSystemProfileID
        contentState = profiles.captureContentState()
        systemState = profiles.captureSystemState()
    }

    @MainActor
    func matches(
        _ profiles: ProductProfileController,
        expectedHeadroomAttenuationDB: Double? = nil
    ) -> Bool {
        var expectedContent = contentState
        if let expectedHeadroomAttenuationDB {
            expectedContent.headroomAttenuationDB =
                expectedHeadroomAttenuationDB
        }
        return selectedContentPresetID == profiles.selectedContentPresetID
            && selectedSystemProfileID == profiles.selectedSystemProfileID
            && expectedContent == profiles.captureContentState()
            && systemState == profiles.captureSystemState()
    }
}

struct HeadroomAssistantEvidence: Equatable, Sendable {
    static let minimumObservationSeconds = 10.0
    static let recommendedObservationSeconds = 30.0
    static let minimumAudiblePeakDBTP = -60.0

    var observationSeconds = 0.0
    var sampleCount = 0
    var maximumPreRiderTruePeakDBTP: Double?
    var maximumMeasuredInputTruePeakDBTP: Double?
    var maximumOutputTruePeakDBTP: Double?
    var maximumLimiterGainReductionDB = 0.0
    var maximumSustainedLimiterGainReductionDB = 0.0
    var maximumGainRiderAttenuationDB = 0.0
    var safetyClampSamples: UInt64 = 0
    var truePeakGuardObserved = false

    var hasProgramEvidence: Bool {
        guard let peak = maximumPreRiderTruePeakDBTP else {
            return false
        }
        return peak > Self.minimumAudiblePeakDBTP
    }

    var isSufficientForRecommendation: Bool {
        observationSeconds >= Self.minimumObservationSeconds
            && sampleCount >= 10
            && hasProgramEvidence
            && truePeakGuardObserved
    }

    mutating func ingest(
        inputTruePeakLinear: Float,
        outputTruePeakLinear: Float,
        limiterGainReductionDB: Float,
        sustainedLimiterGainReductionDB: Float,
        gainRiderAttenuationDB: Float,
        truePeakGuardActive: Bool,
        cumulativeSafetyClampSamples: UInt64,
        initialSafetyClampSamples: UInt64,
        elapsedSeconds: Double
    ) {
        guard elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            return
        }
        observationSeconds = max(observationSeconds, elapsedSeconds)
        truePeakGuardObserved =
            truePeakGuardObserved || truePeakGuardActive

        let rider = max(
            gainRiderAttenuationDB.isFinite
                ? Double(gainRiderAttenuationDB)
                : 0,
            0
        )
        maximumGainRiderAttenuationDB =
            max(maximumGainRiderAttenuationDB, rider)

        if let measured = Self.decibels(inputTruePeakLinear) {
            sampleCount += 1
            maximumMeasuredInputTruePeakDBTP = maxOptional(
                maximumMeasuredInputTruePeakDBTP,
                measured
            )
            // Gain Rider attenuation is applied before the protection
            // detector. Add it back so static-headroom advice reflects the
            // upstream peak that the rider is currently helping to contain.
            maximumPreRiderTruePeakDBTP = maxOptional(
                maximumPreRiderTruePeakDBTP,
                measured + rider
            )
        }

        if let output = Self.decibels(outputTruePeakLinear) {
            maximumOutputTruePeakDBTP = maxOptional(
                maximumOutputTruePeakDBTP,
                output
            )
        }

        if limiterGainReductionDB.isFinite {
            maximumLimiterGainReductionDB = max(
                maximumLimiterGainReductionDB,
                max(Double(limiterGainReductionDB), 0)
            )
        }
        if sustainedLimiterGainReductionDB.isFinite {
            maximumSustainedLimiterGainReductionDB = max(
                maximumSustainedLimiterGainReductionDB,
                max(Double(sustainedLimiterGainReductionDB), 0)
            )
        }

        safetyClampSamples =
            cumulativeSafetyClampSamples >= initialSafetyClampSamples
                ? cumulativeSafetyClampSamples
                    - initialSafetyClampSamples
                : cumulativeSafetyClampSamples
    }

    private static func decibels(_ linear: Float) -> Double? {
        guard linear.isFinite, linear > 0 else { return nil }
        return 20.0 * log10(Double(linear))
    }

    private func maxOptional(
        _ lhs: Double?,
        _ rhs: Double
    ) -> Double {
        max(lhs ?? -Double.infinity, rhs)
    }
}

enum HeadroomAssistantDisposition:
    String, Equatable, Sendable {
    case insufficientEvidence
    case currentReserveSufficient
    case recommendAdditionalAttenuation
    case rangeLimited
}

struct HeadroomAssistantRecommendation: Equatable, Sendable {
    static let defaultTargetPeakDBTP = -1.0
    static let targetPeakRange = -6.0 ... -0.5
    static let toleratedSustainedLimiterReductionDB = 0.5
    static let safetyClampReserveDB = 0.5
    static let quantizationStepDB = 0.1

    let disposition: HeadroomAssistantDisposition
    let targetPeakDBTP: Double
    let currentHeadroomAttenuationDB: Double
    let recommendedHeadroomAttenuationDB: Double
    let additionalAttenuationDB: Double
    let peakDrivenAttenuationDB: Double
    let sustainedLimiterDrivenAttenuationDB: Double
    let safetyClampReserveDB: Double
    let rangeLimited: Bool
    let evidence: HeadroomAssistantEvidence

    var canApply: Bool {
        evidence.isSufficientForRecommendation
            && additionalAttenuationDB > 0
            && recommendedHeadroomAttenuationDB
                < currentHeadroomAttenuationDB
    }

    static func make(
        evidence: HeadroomAssistantEvidence,
        currentHeadroomAttenuationDB: Double,
        targetPeakDBTP: Double =
            HeadroomAssistantRecommendation.defaultTargetPeakDBTP
    ) -> Self {
        let safeTarget = min(
            max(
                targetPeakDBTP,
                targetPeakRange.lowerBound
            ),
            targetPeakRange.upperBound
        )
        let current = min(
            max(
                currentHeadroomAttenuationDB,
                DSPGainConfiguration.headroomAttenuationRange.lowerBound
            ),
            DSPGainConfiguration.headroomAttenuationRange.upperBound
        )

        guard evidence.isSufficientForRecommendation,
              let peak = evidence.maximumPreRiderTruePeakDBTP else {
            return Self(
                disposition: .insufficientEvidence,
                targetPeakDBTP: safeTarget,
                currentHeadroomAttenuationDB: current,
                recommendedHeadroomAttenuationDB: current,
                additionalAttenuationDB: 0,
                peakDrivenAttenuationDB: 0,
                sustainedLimiterDrivenAttenuationDB: 0,
                safetyClampReserveDB: 0,
                rangeLimited: false,
                evidence: evidence
            )
        }

        let peakNeed = max(peak - safeTarget, 0)
        let limiterNeed = max(
            evidence.maximumSustainedLimiterGainReductionDB
                - toleratedSustainedLimiterReductionDB,
            0
        )
        let clampReserve =
            evidence.safetyClampSamples > 0
                ? safetyClampReserveDB
                : 0

        // The two primary signals describe the same missing reserve from
        // different perspectives, so take the larger rather than summing
        // them. A safety-clamp event adds a small explicit reserve because it
        // means the protection path had to use its final hard clamp.
        let rawAdditional =
            max(peakNeed, limiterNeed) + clampReserve
        let quantizedAdditional =
            quantizeUp(rawAdditional)
        let unclampedRecommendation =
            current - quantizedAdditional
        let recommended = max(
            unclampedRecommendation,
            DSPGainConfiguration.headroomAttenuationRange.lowerBound
        )
        let actualAdditional =
            max(current - recommended, 0)
        let limited =
            unclampedRecommendation
                < DSPGainConfiguration.headroomAttenuationRange.lowerBound

        let disposition: HeadroomAssistantDisposition
        if actualAdditional <= 0 {
            disposition = .currentReserveSufficient
        } else if limited {
            disposition = .rangeLimited
        } else {
            disposition = .recommendAdditionalAttenuation
        }

        return Self(
            disposition: disposition,
            targetPeakDBTP: safeTarget,
            currentHeadroomAttenuationDB: current,
            recommendedHeadroomAttenuationDB: recommended,
            additionalAttenuationDB: actualAdditional,
            peakDrivenAttenuationDB: peakNeed,
            sustainedLimiterDrivenAttenuationDB: limiterNeed,
            safetyClampReserveDB: clampReserve,
            rangeLimited: limited,
            evidence: evidence
        )
    }

    private static func quantizeUp(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return ceil(value / quantizationStepDB)
            * quantizationStepDB
    }
}


enum HeadroomAssistantPhase: String, Equatable, Sendable {
    case idle
    case observing
    case review
    case applied
    case invalidated
}

enum HeadroomAssistantError: Error, LocalizedError, Equatable {
    case processingRequired
    case authoritativeTruePeakUnavailable
    case abComparisonActive
    case stateChanged
    case noApplicableRecommendation
    case appliedRecommendationPendingDecision
    case noAppliedRecommendationToRevert

    var errorDescription: String? {
        switch self {
        case .processingRequired:
            return "Start processing before beginning a Headroom Assistant observation."
        case .authoritativeTruePeakUnavailable:
            return "Authoritative true-peak telemetry is unavailable. Enable the limiter True Peak Guard and start a new observation."
        case .abComparisonActive:
            return "Exit the active A/B audition and restore its baseline before using Headroom Assistant."
        case .stateChanged:
            return "The Content Preset or Playback System changed during the observation. Start a new Headroom Assistant observation for the current state."
        case .noApplicableRecommendation:
            return "There is no additional headroom attenuation to apply from this observation."
        case .appliedRecommendationPendingDecision:
            return "Undo Applied Headroom or choose Keep & Clear before starting a new observation."
        case .noAppliedRecommendationToRevert:
            return "There is no unchanged Headroom Assistant Apply transaction to revert."
        }
    }
}

@MainActor
final class HeadroomAssistantController: ObservableObject {
    private let engine: AudioIOEngine
    private let profiles: ProductProfileController
    private let abComparison: ContentABComparisonController?
    private var observationTask: Task<Void, Never>?
    private var boundary: HeadroomAssistantBoundary?
    private var startedAt: Date?
    private var initialSafetyClampSamples: UInt64 = 0
    private var startingHeadroomAttenuationDB = 0.0
    private var appliedHeadroomAttenuationDB: Double?

    @Published private(set) var phase: HeadroomAssistantPhase = .idle
    @Published private(set) var evidence = HeadroomAssistantEvidence()
    @Published private(set) var recommendation:
        HeadroomAssistantRecommendation?
    @Published private(set) var lastErrorDescription: String?
    @Published var targetPeakDBTP =
        HeadroomAssistantRecommendation.defaultTargetPeakDBTP {
        didSet {
            targetPeakDBTP = min(
                max(
                    targetPeakDBTP,
                    HeadroomAssistantRecommendation
                        .targetPeakRange.lowerBound
                ),
                HeadroomAssistantRecommendation
                    .targetPeakRange.upperBound
            )
            refreshRecommendation()
        }
    }

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        abComparison: ContentABComparisonController? = nil
    ) {
        self.engine = engine
        self.profiles = profiles
        self.abComparison = abComparison
    }

    var isObserving: Bool { phase == .observing }

    var observationProgress: Double {
        min(
            evidence.observationSeconds
                / HeadroomAssistantEvidence
                    .recommendedObservationSeconds,
            1
        )
    }

    func startObservation(now: Date = Date()) throws {
        guard !canRevertAppliedRecommendation else {
            throw HeadroomAssistantError
                .appliedRecommendationPendingDecision
        }
        guard !abAuditionSessionActive else {
            throw HeadroomAssistantError.abComparisonActive
        }
        guard engine.lifecycleState == .running else {
            throw HeadroomAssistantError.processingRequired
        }
        guard let diagnostics =
                engine.diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.truePeakGuardActive else {
            throw HeadroomAssistantError
                .authoritativeTruePeakUnavailable
        }

        observationTask?.cancel()
        boundary = HeadroomAssistantBoundary(profiles: profiles)
        startedAt = now
        initialSafetyClampSamples =
            diagnostics.limiterSafetyClampSamples
        startingHeadroomAttenuationDB =
            engine.gainConfiguration.headroomAttenuationDB
        appliedHeadroomAttenuationDB = nil
        evidence = HeadroomAssistantEvidence()
        recommendation = nil
        lastErrorDescription = nil
        phase = .observing

        sample(now: now)

        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: 125_000_000
                )
                guard let self, !Task.isCancelled else {
                    return
                }
                self.sample(now: Date())
                if self.phase != .observing {
                    return
                }
            }
        }
    }

    func stopObservation(now: Date = Date()) {
        guard phase == .observing else { return }
        sample(now: now)
        observationTask?.cancel()
        observationTask = nil
        if phase == .observing {
            phase = .review
            refreshRecommendation()
        }
    }

    func cancelObservation() {
        observationTask?.cancel()
        observationTask = nil
        boundary = nil
        startedAt = nil
        appliedHeadroomAttenuationDB = nil
        evidence = HeadroomAssistantEvidence()
        recommendation = nil
        lastErrorDescription = nil
        phase = .idle
    }

    func applyRecommendation() throws {
        guard phase == .review,
              let recommendation,
              recommendation.canApply else {
            throw HeadroomAssistantError
                .noApplicableRecommendation
        }
        guard let boundary,
              boundary.matches(profiles) else {
            invalidate(
                HeadroomAssistantError.stateChanged
            )
            throw HeadroomAssistantError.stateChanged
        }

        try engine.transitionHeadroomAttenuationDB(
            recommendation
                .recommendedHeadroomAttenuationDB
        )
        appliedHeadroomAttenuationDB =
            recommendation.recommendedHeadroomAttenuationDB
        observationTask?.cancel()
        observationTask = nil
        phase = .applied
        lastErrorDescription = nil
    }

    var canRevertAppliedRecommendation: Bool {
        phase == .applied
            && appliedHeadroomAttenuationDB != nil
            && boundary != nil
    }

    func revertAppliedRecommendation() throws {
        guard phase == .applied,
              let boundary,
              let appliedHeadroomAttenuationDB else {
            throw HeadroomAssistantError
                .noAppliedRecommendationToRevert
        }
        guard boundary.matches(
            profiles,
            expectedHeadroomAttenuationDB:
                appliedHeadroomAttenuationDB
        ) else {
            invalidate(HeadroomAssistantError.stateChanged)
            throw HeadroomAssistantError.stateChanged
        }

        try engine.transitionHeadroomAttenuationDB(
            startingHeadroomAttenuationDB
        )
        self.appliedHeadroomAttenuationDB = nil
        phase = .review
        lastErrorDescription = nil
        refreshRecommendation()
    }

    private func sample(now: Date) {
        guard phase == .observing,
              let startedAt,
              let boundary else {
            return
        }
        guard !abAuditionSessionActive else {
            invalidate(HeadroomAssistantError.abComparisonActive)
            return
        }
        guard boundary.matches(profiles) else {
            invalidate(HeadroomAssistantError.stateChanged)
            return
        }
        guard engine.lifecycleState == .running else {
            stopForProcessingEnd(now: now)
            return
        }
        guard let diagnostics =
                engine.diagnosticsSnapshot()
                    .renderKernelDiagnostics,
              diagnostics.truePeakGuardActive else {
            invalidate(
                HeadroomAssistantError
                    .authoritativeTruePeakUnavailable
            )
            return
        }

        evidence.ingest(
            inputTruePeakLinear:
                diagnostics.inputTruePeakLinear,
            outputTruePeakLinear:
                diagnostics.outputTruePeakLinear,
            limiterGainReductionDB:
                diagnostics.limiterGainReductionDB,
            sustainedLimiterGainReductionDB:
                diagnostics.sustainedLimiterGainReductionDB,
            gainRiderAttenuationDB:
                diagnostics.gainRiderAttenuationDB,
            truePeakGuardActive:
                diagnostics.truePeakGuardActive,
            cumulativeSafetyClampSamples:
                diagnostics.limiterSafetyClampSamples,
            initialSafetyClampSamples:
                initialSafetyClampSamples,
            elapsedSeconds:
                max(now.timeIntervalSince(startedAt), 0)
        )
        refreshRecommendation()
    }

    private func stopForProcessingEnd(now: Date) {
        if let startedAt {
            evidence.observationSeconds = max(
                evidence.observationSeconds,
                max(now.timeIntervalSince(startedAt), 0)
            )
        }
        observationTask?.cancel()
        observationTask = nil
        phase = .review
        refreshRecommendation()
    }

    private func refreshRecommendation() {
        guard phase == .observing
                || phase == .review
                || phase == .applied else {
            recommendation = nil
            return
        }
        recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB:
                    startingHeadroomAttenuationDB,
                targetPeakDBTP: targetPeakDBTP
            )
    }

    private var abAuditionSessionActive: Bool {
        guard let abComparison else { return false }
        return abComparison.sessionBaseline != nil
            || abComparison.activeSlot != nil
            || abComparison.isSwitching
    }

    private func invalidate(_ error: HeadroomAssistantError) {
        observationTask?.cancel()
        observationTask = nil
        phase = .invalidated
        recommendation = nil
        lastErrorDescription = error.localizedDescription
    }
}
