import Foundation

/// PR104 Slice 5: source-level comparison of bounded PEQ, linear-phase FIR,
/// and bypass predictions, NEVER an executable audio/preset/A-B transport.
enum SpeakerOptimizerComparisonError: Error, Equatable {
    case invalidOptions
    case inconsistentEvidence
    case sourceUnavailable
    case alternativeUnavailable
}

enum SpeakerOptimizerAlternativeKind: String, Codable, CaseIterable, Sendable {
    case bypass
    case peq
    case fir
}

struct SpeakerOptimizerComparisonOptions: Equatable, Sendable {
    var maximumRequiredHeadroomDB = 3.5
    var maximumFIRDelayMilliseconds = 30.0
    var minimumModeledImprovementDB = 0.05
    var maximumSeatDegradationDB = 0.25
    var headroomPenaltyPerDB = 0.1
    var firLatencyPenaltyPerMillisecond = 0.005
    var complexityPenaltyPerBand = 0.015
    var firComplexityPenalty = 0.04

    func valid() -> Bool {
        maximumRequiredHeadroomDB.isFinite && (0...6).contains(maximumRequiredHeadroomDB)
            && maximumFIRDelayMilliseconds.isFinite
            && (0...100).contains(maximumFIRDelayMilliseconds)
            && minimumModeledImprovementDB.isFinite
            && (0...0.5).contains(minimumModeledImprovementDB)
            && maximumSeatDegradationDB.isFinite
            && (0...1).contains(maximumSeatDegradationDB)
            && headroomPenaltyPerDB.isFinite && (0...1).contains(headroomPenaltyPerDB)
            && firLatencyPenaltyPerMillisecond.isFinite
            && (0...0.1).contains(firLatencyPenaltyPerMillisecond)
            && complexityPenaltyPerBand.isFinite
            && (0...0.1).contains(complexityPenaltyPerBand)
            && firComplexityPenalty.isFinite && (0...0.5).contains(firComplexityPenalty)
    }
}

struct SpeakerOptimizerAlternative: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var kind: SpeakerOptimizerAlternativeKind
    var eligibleForVisualPreview: Bool
    var rankingScore: Double?
    var predictedImprovementDB: Double
    var predictedWeightedRMSEAfterDB: Double
    var worstSeatRegressionDB: Double
    var requiredHeadroomDB: Double
    /// FIR has a known fixed group delay. PEQ adds frequency-dependent phase
    /// delay but no separately quantified fixed FIR delay here.
    var fixedGroupDelayMilliseconds: Double?
    var filterCount: Int
    var frequenciesHz: [Double]
    var correctionDB: [Double]
    var blockingReasons: [String]
}

struct SpeakerOptimizerSourceComparison: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var weightedRMSEBeforeDB: Double
    /// Eligible alternatives sorted by deterministic preview score first.
    /// Rejected alternatives are retained and ranked last for transparency.
    var alternatives: [SpeakerOptimizerAlternative]
    var topVisualPreviewKind: SpeakerOptimizerAlternativeKind
}

struct SpeakerOptimizerComparisonPlan: Equatable, Sendable {
    var baselineMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var evidenceConfidence: Double
    var sources: [SpeakerOptimizerSourceComparison]
    var warnings: [String]
    var previewOnly: Bool { true }
    var isMeasuredVerification: Bool { false }
    var canDeploy: Bool { false }
    var canSwitchLiveAudio: Bool { false }
}

struct SpeakerOptimizerVisualAB: Equatable, Sendable {
    var measurementSetID: UUID
    var source: MultichannelCalibrationSource
    var a: SpeakerOptimizerAlternativeKind
    var b: SpeakerOptimizerAlternativeKind
    var frequenciesHz: [Double]
    var aCorrectionDB: [Double]
    var bCorrectionDB: [Double]
    var differenceBMinusADB: [Double]
    var predictedAErrorDB: Double
    var predictedBErrorDB: Double
    var visualOnly: Bool { true }
    var canSwitchLiveAudio: Bool { false }
}

/// Crossover feasibility uses a different objective (conditional coherent
/// summed band energy), so it MUST NOT be ranked numerically against an
/// individual speaker's magnitude RMSE. It remains an isolated diagnostic.
struct SpeakerOptimizerCrossoverVisualAB: Equatable, Sendable {
    var measurementSetID: UUID
    var speaker: MultichannelCalibrationSource
    var subwoofer: MultichannelCalibrationSource
    var baselineSeatLevelsDB: [Double]
    var candidateSeatLevelsDB: [Double]
    var hypotheticalRelativeDelayMs: Double
    var hypotheticalInvertSubPolarity: Bool
    var acceptedForConditionalPreview: Bool
    var warnings: [String]
    var visualOnly: Bool { true }
    var phaseReferenceAuthenticated: Bool { false }
    var canDeploy: Bool { false }
}

/// Regenerates every contender from the exact same qualified PR103 baseline,
/// target, listening-position weights and routing identity. Predictive scores
/// are presentation choices, NOT acoustic verification or deployment approval.
struct SpeakerOptimizerCandidateComparisonDesigner: Sendable {
    func compare(
        baseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        designOptions: SpeakerOptimizerDesignOptions = .init(),
        peqConstraints: SpeakerOptimizerPEQConstraints = .init(),
        firConstraints: SpeakerOptimizerFIRConstraints = .init(),
        comparisonOptions: SpeakerOptimizerComparisonOptions = .init()
    ) throws -> SpeakerOptimizerComparisonPlan {
        guard comparisonOptions.valid() else { throw SpeakerOptimizerComparisonError.invalidOptions }
        let reference = try SpeakerOptimizerDesignEngine().design(
            baseline: baseline, seatWeights: seatWeights, options: designOptions
        )
        let peq = try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: baseline, seatWeights: seatWeights, options: designOptions,
            constraints: peqConstraints
        )
        let fir = try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, seatWeights: seatWeights, options: designOptions,
            constraints: firConstraints
        )
        guard reference.baselineMeasurementSetID == baseline.id,
              peq.baselineMeasurementSetID == baseline.id,
              fir.baselineMeasurementSetID == baseline.id,
              reference.playbackSystemID == baseline.playbackSystemID,
              peq.playbackSystemID == baseline.playbackSystemID,
              fir.playbackSystemID == baseline.playbackSystemID,
              reference.routingSignature == baseline.routingSignature,
              peq.routingSignature == baseline.routingSignature,
              fir.routingSignature == baseline.routingSignature,
              peq.sampleRate == baseline.sampleRate,
              fir.sampleRate == baseline.sampleRate else {
            throw SpeakerOptimizerComparisonError.inconsistentEvidence
        }
        var sources: [SpeakerOptimizerSourceComparison] = []
        for raw in reference.sources {
            guard let peqSource = peq.sources.first(where: { $0.source == raw.source }),
                  let firSource = fir.sources.first(where: { $0.source == raw.source }),
                  sameGrid(raw.frequenciesHz, peqSource.frequenciesHz),
                  sameGrid(raw.frequenciesHz, firSource.frequenciesHz),
                  abs(raw.weightedRMSEBeforeDB - peqSource.weightedRMSEBeforeDB) <= 0.01,
                  abs(raw.weightedRMSEBeforeDB - firSource.weightedRMSEBeforeDB) <= 0.01 else {
                throw SpeakerOptimizerComparisonError.inconsistentEvidence
            }
            let zero = Array(repeating: 0.0, count: raw.frequenciesHz.count)
            let before = raw.weightedRMSEBeforeDB
            var entries = [SpeakerOptimizerAlternative(
                source: raw.source,
                kind: .bypass,
                eligibleForVisualPreview: true, rankingScore: 0,
                predictedImprovementDB: 0, predictedWeightedRMSEAfterDB: before,
                worstSeatRegressionDB: 0, requiredHeadroomDB: 0,
                fixedGroupDelayMilliseconds: 0, filterCount: 0,
                frequenciesHz: raw.frequenciesHz, correctionDB: zero,
                blockingReasons: []
            )]
            let peqEligible = !peqSource.bands.isEmpty
                && peqSource.predictedWeightedRMSEAfterDB.isFinite
                && peqSource.recommendedHeadroomDB <= comparisonOptions.maximumRequiredHeadroomDB
                && peqSource.worstSeatRegressionDB <= comparisonOptions.maximumSeatDegradationDB
                && before - peqSource.predictedWeightedRMSEAfterDB
                    >= comparisonOptions.minimumModeledImprovementDB
            entries.append(makeAlternative(
                source: raw.source, kind: .peq, eligible: peqEligible,
                before: before, after: peqSource.predictedWeightedRMSEAfterDB,
                worst: peqSource.worstSeatRegressionDB,
                headroom: peqSource.recommendedHeadroomDB,
                fixedDelay: nil, count: peqSource.bands.count,
                grid: raw.frequenciesHz, corrections: peqSource.modeledFilterMagnitudeDB,
                constraints: comparisonOptions,
                rejection: "PEQ has no qualifying filter, insufficient modeled benefit, excessive headroom or seat regression."
            ))
            let firEligible = firSource.acceptedForPreview && !firSource.taps.isEmpty
                && fir.declaredGroupDelayMilliseconds <= comparisonOptions.maximumFIRDelayMilliseconds
                && firSource.recommendedHeadroomDB <= comparisonOptions.maximumRequiredHeadroomDB
                && firSource.worstSeatRegressionDB <= comparisonOptions.maximumSeatDegradationDB
                && before - firSource.predictedWeightedRMSEAfterDB
                    >= comparisonOptions.minimumModeledImprovementDB
            entries.append(makeAlternative(
                source: raw.source, kind: .fir, eligible: firEligible,
                before: before, after: firSource.predictedWeightedRMSEAfterDB,
                worst: firSource.worstSeatRegressionDB,
                headroom: firSource.recommendedHeadroomDB,
                fixedDelay: fir.declaredGroupDelayMilliseconds,
                count: firSource.taps.count,
                grid: raw.frequenciesHz, corrections: firSource.modeledFilterMagnitudeDB,
                constraints: comparisonOptions,
                rejection: firSource.blockingReasons.joined(separator: "; ").isEmpty
                    ? "FIR has insufficient modeled benefit, excessive latency/headroom or seat regression."
                    : firSource.blockingReasons.joined(separator: "; ")
            ))
            entries.sort {
                if $0.eligibleForVisualPreview != $1.eligibleForVisualPreview {
                    return $0.eligibleForVisualPreview
                }
                let left = $0.rankingScore ?? -.infinity
                let right = $1.rankingScore ?? -.infinity
                if abs(left - right) > 1e-10 { return left > right }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            sources.append(SpeakerOptimizerSourceComparison(
                source: raw.source, weightedRMSEBeforeDB: before,
                alternatives: entries,
                topVisualPreviewKind: entries.first?.kind ?? .bypass
            ))
        }
        return SpeakerOptimizerComparisonPlan(
            baselineMeasurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            microphone: baseline.microphone,
            sampleRate: baseline.sampleRate,
            evidenceConfidence: reference.evidenceConfidence,
            sources: sources,
            warnings: [
                "Ranking compares model predictions, not verified acoustic improvements.",
                "No safe audio A/B, live filter switch, DSP mutation, crossover adjustment, or approved speaker deployment exists.",
                "FIR adds declared constant delay; PEQ changes phase frequency-dependently. Compare latency before any later application.",
                "Headroom estimates are per acoustic source, not aggregate device/limiter certification."
            ]
        )
    }

    func visualAB(
        in plan: SpeakerOptimizerComparisonPlan,
        source: MultichannelCalibrationSource,
        a: SpeakerOptimizerAlternativeKind,
        b: SpeakerOptimizerAlternativeKind
    ) throws -> SpeakerOptimizerVisualAB {
        guard let selection = plan.sources.first(where: { $0.source == source }) else {
            throw SpeakerOptimizerComparisonError.sourceUnavailable
        }
        guard let first = selection.alternatives.first(where: {
            $0.kind == a && $0.eligibleForVisualPreview
        }), let second = selection.alternatives.first(where: {
            $0.kind == b && $0.eligibleForVisualPreview
        }), sameGrid(first.frequenciesHz, second.frequenciesHz),
            first.correctionDB.count == first.frequenciesHz.count,
            second.correctionDB.count == second.frequenciesHz.count else {
            throw SpeakerOptimizerComparisonError.alternativeUnavailable
        }
        return SpeakerOptimizerVisualAB(
            measurementSetID: plan.baselineMeasurementSetID, source: source,
            a: a, b: b, frequenciesHz: first.frequenciesHz,
            aCorrectionDB: first.correctionDB,
            bCorrectionDB: second.correctionDB,
            differenceBMinusADB: zip(first.correctionDB, second.correctionDB)
                .map { $0.1 - $0.0 },
            predictedAErrorDB: first.predictedWeightedRMSEAfterDB,
            predictedBErrorDB: second.predictedWeightedRMSEAfterDB
        )
    }

    func crossoverVisualAB(
        baseline: SpeakerOptimizerMeasurementSet,
        speaker: MultichannelCalibrationSource,
        subwoofer: MultichannelCalibrationSource,
        seatWeights: [UUID: Double]? = nil,
        crossoverOptions: SpeakerOptimizerCrossoverOptions = .init()
    ) throws -> SpeakerOptimizerCrossoverVisualAB {
        // Always calculate this independent phase/timing hypothesis anew.
        let prediction = try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: speaker, subwoofer: subwoofer,
            seatWeights: seatWeights, options: crossoverOptions
        )
        return SpeakerOptimizerCrossoverVisualAB(
            measurementSetID: prediction.measurementSetID,
            speaker: speaker, subwoofer: subwoofer,
            baselineSeatLevelsDB: prediction.seatPredictions.map(\.baselineSummedLevelDB),
            candidateSeatLevelsDB: prediction.seatPredictions.map(\.candidateSummedLevelDB),
            hypotheticalRelativeDelayMs: prediction.previewRelativeDelayMs,
            hypotheticalInvertSubPolarity: prediction.previewInvertSubPolarity,
            acceptedForConditionalPreview: prediction.acceptedForPreview,
            warnings: prediction.warnings
        )
    }

    private func makeAlternative(
        source: MultichannelCalibrationSource, kind: SpeakerOptimizerAlternativeKind,
        eligible: Bool, before: Double, after: Double, worst: Double,
        headroom: Double, fixedDelay: Double?, count: Int,
        grid: [Double], corrections: [Double],
        constraints: SpeakerOptimizerComparisonOptions, rejection: String
    ) -> SpeakerOptimizerAlternative {
        let sane = eligible && after.isFinite && before.isFinite
            && headroom.isFinite && headroom >= 0
            && worst.isFinite && corrections.count == grid.count
            && corrections.allSatisfy(\.isFinite)
            && (fixedDelay == nil || (fixedDelay!.isFinite && fixedDelay! >= 0))
        let improvement = sane ? max(0, before - after) : 0
        let score = improvement
            - headroom * constraints.headroomPenaltyPerDB
            - (kind == .peq ? Double(count) * constraints.complexityPenaltyPerBand
               : constraints.firComplexityPenalty
                    + (fixedDelay ?? 0) * constraints.firLatencyPenaltyPerMillisecond)
            - max(0, worst) * 0.5
        return SpeakerOptimizerAlternative(
            source: source, kind: kind, eligibleForVisualPreview: sane,
            rankingScore: sane ? score : nil,
            predictedImprovementDB: improvement,
            predictedWeightedRMSEAfterDB: sane ? after : before,
            worstSeatRegressionDB: sane ? worst : 0,
            requiredHeadroomDB: sane ? headroom : 0,
            fixedGroupDelayMilliseconds: fixedDelay,
            filterCount: sane ? count : 0,
            frequenciesHz: grid,
            correctionDB: sane ? corrections : Array(repeating: 0, count: grid.count),
            blockingReasons: sane ? [] : [rejection]
        )
    }

    private func sameGrid(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy { pair in
                abs(pair.0 - pair.1) <= max(1e-6, abs(pair.0) * 1e-9)
            }
    }
}
