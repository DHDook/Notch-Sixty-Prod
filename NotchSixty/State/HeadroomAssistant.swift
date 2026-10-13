import Foundation

struct HeadroomAssistantBoundary: Equatable, Sendable {
    let selectedContentPresetID: UUID?
    let selectedSystemProfileID: UUID?
    let contentState: ContentPresetState
    let systemState: PlaybackSystemState

    init(profiles: ProductProfileController) {
        selectedContentPresetID = profiles.selectedContentPresetID
        selectedSystemProfileID = profiles.selectedSystemProfileID
        contentState = profiles.captureContentState()
        systemState = profiles.captureSystemState()
    }

    func matches(_ profiles: ProductProfileController) -> Bool {
        selectedContentPresetID == profiles.selectedContentPresetID
            && selectedSystemProfileID == profiles.selectedSystemProfileID
            && contentState == profiles.captureContentState()
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
