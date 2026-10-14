import Foundation

/// Batch 2: one read-only priority list across existing independent acoustic
/// evidence owners. No DSP graph, configuration mutation, hardware command,
/// playback change, measurement trigger or implied deployment permission.
enum UnifiedAcousticRemedy: String, Codable, Equatable, Sendable {
    case measureMore
    case speakerPlacement
    case passiveTreatment
    case bassAlignmentReview
    case speakerCorrectionReview
    case roomCorrectionReview
    case noAction

    var priority: Int {
        switch self {
        case .measureMore: return 0
        case .speakerPlacement: return 1
        case .passiveTreatment: return 2
        case .bassAlignmentReview: return 3
        case .speakerCorrectionReview: return 4
        case .roomCorrectionReview: return 5
        case .noAction: return 6
        }
    }
}

struct UnifiedAcousticEvidenceIdentity: Equatable, Sendable {
    var projectID: UUID
    var playbackSystemID: UUID?
    var routingSignature: String?
    var sampleRate: Double?
    var baselineMeasurementSetID: UUID?

    var hasBoundHardwareIdentity: Bool {
        playbackSystemID != nil
            && routingSignature?.isEmpty == false
            && sampleRate?.isFinite == true
            && (sampleRate ?? 0) > 0
    }
}

struct UnifiedAcousticAdvice: Identifiable, Equatable, Sendable {
    var id: String
    var remedy: UnifiedAcousticRemedy
    var title: String
    var rationale: String
    var evidenceSource: String
    var blockers: [String]
    var modeledOnly: Bool

    var canApply: Bool { false }
    var canDeploy: Bool { false }
}

struct UnifiedAcousticIntelligenceReport: Equatable, Sendable {
    var projectID: UUID
    var includedPositionCount: Int
    var advice: [UnifiedAcousticAdvice]
    var warnings: [String]

    var previewOnly: Bool { true }
    var canApply: Bool { false }
    var canDeploy: Bool { false }
    var hardwareVerified: Bool { false }
}

/// Integrates existing domain reports without confusing their distinct
/// objectives: room-treatment diagnostics, speaker magnitude error, and
/// *coherent* physical multi-Sub timing cannot be collapsed into one score.
struct UnifiedAcousticIntelligenceCoordinator: Sendable {
    func summarize(
        room: RoomTreatmentAdvisorReport,
        identity: UnifiedAcousticEvidenceIdentity,
        speaker: SpeakerOptimizerComparisonPlan? = nil,
        multiSub: CoherentMultiSubwooferAlignmentCandidate? = nil,
        physicalSub: RoomAdvancedSubPlacementComparison? = nil
    ) -> UnifiedAcousticIntelligenceReport {
        guard room.projectID == identity.projectID else {
            return UnifiedAcousticIntelligenceReport(
                projectID: identity.projectID,
                includedPositionCount: 0,
                advice: [],
                warnings: ["Room Advisor project identity differs from the selected acoustic project. No proposals were combined."]
            )
        }

        let multipleSeats = room.includedMeasurementCount >= 2
        let qualityWarnings = room.qualityWarnings
        var warnings = qualityWarnings
        if !multipleSeats {
            warnings.append("Multi-seat claims require at least two included measurements.")
        }
        var advice: [UnifiedAcousticAdvice] = []
        for finding in room.findings {
            let remedy: UnifiedAcousticRemedy
            switch finding.primaryRemedy {
            case .measureMore: remedy = .measureMore
            case .placement: remedy = .speakerPlacement
            case .passiveTreatment: remedy = .passiveTreatment
            case .dspCorrection: remedy = .roomCorrectionReview
            case .activeRoomTreatment, .activeQuietZone:
                remedy = .roomCorrectionReview
            case .noAction: remedy = .noAction
            }

            var blockers: [String] = []
            if remedy == .roomCorrectionReview
                && (!multipleSeats || !qualityWarnings.isEmpty) {
                blockers.append("Measurement coverage or quality is insufficient for a multi-seat DSP recommendation.")
            }
            if !finding.confidence.isFinite
                || !(0.0...1.0).contains(finding.confidence) {
                blockers.append("Room Advisor evidence weight is invalid.")
            }
            advice.append(UnifiedAcousticAdvice(
                id: "room-" + finding.id,
                remedy: remedy,
                title: finding.title,
                rationale: finding.interpretation,
                evidenceSource: "RoomTreatmentAdvisor",
                blockers: blockers,
                modeledOnly: true
            ))
        }

        if let speaker {
            let matchesContext = identity.hasBoundHardwareIdentity
                && identity.baselineMeasurementSetID == speaker.baselineMeasurementSetID
                && identity.playbackSystemID == speaker.playbackSystemID
                && identity.routingSignature == speaker.routingSignature
                && identity.sampleRate.map {
                    abs($0 - speaker.sampleRate) < 0.5
                } == true

            if !matchesContext {
                warnings.append("Speaker Optimizer proposal identity does not match the selected measurement/hardware context; omitted.")
            } else {
                for source in speaker.sources {
                    guard let candidate = source.alternatives.first(where: {
                        $0.kind == source.topVisualPreviewKind
                    }) else { continue }
                    // A selected bypass is evidence *against* adding a
                    // correction. Do not mislabel it as an EQ recommendation.
                    if candidate.kind == .bypass {
                        advice.append(UnifiedAcousticAdvice(
                            id: "speaker-" + source.source.displayName,
                            remedy: .noAction,
                            title: "Keep " + source.source.displayName + " unchanged",
                            rationale: "The existing independent comparison prefers bypass over PEQ or FIR for this source. Do not add a correction to improve a score.",
                            evidenceSource: "SpeakerOptimizerCandidateComparison",
                            blockers: [],
                            modeledOnly: true
                        ))
                        continue
                    }
                    var blockers = candidate.blockingReasons
                    if !candidate.eligibleForVisualPreview {
                        blockers.append("Existing speaker comparison rejects this alternative.")
                    }
                    if !multipleSeats || !qualityWarnings.isEmpty {
                        blockers.append("Insufficient repeatable multi-seat evidence.")
                    }
                    if !candidate.worstSeatRegressionDB.isFinite
                        || candidate.worstSeatRegressionDB > 0.25 {
                        blockers.append("Predicted target-error regression at an individual seat exceeds the conservative limit.")
                    }
                    if !candidate.requiredHeadroomDB.isFinite
                        || candidate.requiredHeadroomDB > 3.5 {
                        blockers.append("Modeled headroom requirement exceeds the conservative review budget.")
                    }
                    advice.append(UnifiedAcousticAdvice(
                        id: "speaker-" + source.source.displayName,
                        remedy: .speakerCorrectionReview,
                        title: "Review " + source.source.displayName + " speaker correction",
                        rationale: "A source-specific magnitude correction candidate exists, but predicted improvement is not measured verification.",
                        evidenceSource: "SpeakerOptimizerCandidateComparison",
                        blockers: blockers,
                        modeledOnly: true
                    ))
                }
            }
        }

        if let multiSub {
            let contextMatches = identity.hasBoundHardwareIdentity
                && identity.playbackSystemID == multiSub.playbackSystemID
                && identity.routingSignature == multiSub.routingSignature
                && identity.sampleRate.map {
                    abs($0 - multiSub.sampleRate) < 0.5
                } == true
            if !contextMatches {
                warnings.append("Multi-Sub timing proposal does not match the selected Playback System and route; omitted.")
            } else {
                var blockers = multiSub.blockingReasons
                if !multipleSeats || !qualityWarnings.isEmpty {
                    blockers.append("Multi-position measurement quality is insufficient.")
                }
                if !multiSub.acceptedForPreview {
                    blockers.append("Existing coherent multi-Sub planner rejected this preview.")
                }
                if multiSub.subwoofers.count < 2 {
                    blockers.append("Multi-Sub optimization needs independently addressable physical Subs.")
                }
                blockers.append(
                    "A common coherent clock and independent Sub output mapping still require owner hardware verification."
                )
                if !multiSub.evidenceConfidence.isFinite
                    || !(0.0...1.0).contains(multiSub.evidenceConfidence) {
                    blockers.append("Invalid coherence evidence weight.")
                }
                advice.append(UnifiedAcousticAdvice(
                    id: "coherent-multisub",
                    remedy: .bassAlignmentReview,
                    title: "Review coherent multi-subwoofer alignment",
                    rationale: "Phase-referenced physical Sub hypotheses must be verified in the actual room; they cannot be ranked against speaker magnitude RMSE.",
                    evidenceSource: "CoherentMultiSubwooferAlignment",
                    blockers: blockers,
                    modeledOnly: true
                ))
            }
        }

        // This report is independently qualified by the existing physical
        // Sub A/B analyzer (same source, microphone, route, positions and
        // user-confirmed physical setup). Do not confuse its relative LF
        // seat spread with absolute SPL, room target error or coherence.
        if let physicalSub {
            var blockers: [String] = []
            if physicalSub.seatCount < 2
                || !physicalSub.reductionInInterseatSpreadDB.isFinite
                || !physicalSub.evidenceConfidence.isFinite
                || !(0...1).contains(physicalSub.evidenceConfidence) {
                blockers.append("Physical Sub evidence needs valid repeated multi-seat measurements.")
            }
            if physicalSub.reductionInInterseatSpreadDB <= 0 {
                blockers.append("The physical Sub move did not reduce measured inter-seat bass variation.")
            }
            blockers.append(
                "Only 35–160 Hz measured seat-spread variation is known; target-response, SPL, headroom, decay, coherent timing and latency require separate evidence."
            )
            advice.append(UnifiedAcousticAdvice(
                id: "physical-sub-placement",
                remedy: .speakerPlacement,
                title: "Review measured physical Sub placement",
                rationale: "The qualified physical before/after captures changed low-frequency inter-seat RMS spread by "
                    + String(format: "%.2f", physicalSub.reductionInInterseatSpreadDB)
                    + " dB across "
                    + String(physicalSub.seatCount)
                    + " positions. A positive value means lower spread, not guaranteed better bass at each seat.",
                evidenceSource: "RoomAdvancedSubPlacementComparison",
                blockers: blockers,
                modeledOnly: false
            ))
        }

        // Prioritize physical/measurement remedies over DSP. A stable sort
        // ensures deterministic ordering within the same remedy category.
        advice = advice.enumerated().sorted { lhs, rhs in
            if lhs.element.remedy.priority != rhs.element.remedy.priority {
                return lhs.element.remedy.priority < rhs.element.remedy.priority
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }

        return UnifiedAcousticIntelligenceReport(
            projectID: identity.projectID,
            includedPositionCount: room.includedMeasurementCount,
            advice: advice,
            warnings: warnings
        )
    }
}


/// Bounded, deterministic *hypothesis* review for candidate correction at
/// multiple seats. No microphone or sample stream is read. The uncertainty
/// range is supplied by qualified measurement evidence, not learned or
/// estimated from these synthetic values.
enum UnifiedAcousticCandidateDomain: String, Sendable {
    case speaker
    case room
    case multiSub
}

struct UnifiedAcousticSeatCandidate: Sendable {
    var domain: UnifiedAcousticCandidateDomain
    var sampleRate: Double
    var seatWeights: [Double]
    var baselineTargetErrorDB: [Double]
    var candidateTargetErrorDB: [Double]
    var absoluteMeasurementUncertaintyDB: Double
    var additionalHeadroomDB: Double
    var fixedLatencyFrames: Int
    var physicalSubwooferOutputCount: Int
    var coherentClockAuthenticated: Bool
    /// Seats excluded from fitting/ranking, checked only for degradation.
    var heldOutSeatIndices: [Int] = []
}

struct UnifiedAcousticRobustnessReview: Sendable {
    var nominalWeightedSquaredErrorImprovementDB2: Double
    var worstCaseWeightedSquaredErrorImprovementDB2: Double
    var worstSeatTargetErrorRegressionDB: Double
    var latencyMilliseconds: Double
    var blockingReasons: [String]
    var heldOutSeatWorstRegressionDB: Double? = nil

    /// A calculation being fit for *visual* review is not measured playback
    /// verification, user-approved commissioning, or hardware authorization.
    var eligibleForVisualReview: Bool { blockingReasons.isEmpty }
    var canApply: Bool { false }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

struct UnifiedAcousticRobustnessEvaluator: Sendable {
    let maximumWorstSeatRegressionDB = 0.25
    let maximumAdditionalHeadroomDB = 3.5
    let maximumFixedLatencyMilliseconds = 30.0
    let minimumRobustImprovementDB2 = 0.25

    func evaluate(
        _ candidate: UnifiedAcousticSeatCandidate
    ) -> UnifiedAcousticRobustnessReview {
        var blockers: [String] = []
        let count = candidate.seatWeights.count
        let heldOut = Set(candidate.heldOutSeatIndices)
        guard (2...16).contains(count),
              heldOut.count == candidate.heldOutSeatIndices.count,
              candidate.heldOutSeatIndices.allSatisfy({ (0..<count).contains($0) }),
              count - heldOut.count >= 2,
              candidate.baselineTargetErrorDB.count == count,
              candidate.candidateTargetErrorDB.count == count,
              candidate.sampleRate.isFinite,
              (8_000...384_000).contains(candidate.sampleRate),
              candidate.absoluteMeasurementUncertaintyDB.isFinite,
              (0...12).contains(candidate.absoluteMeasurementUncertaintyDB),
              candidate.additionalHeadroomDB.isFinite,
              candidate.additionalHeadroomDB >= 0,
              candidate.fixedLatencyFrames >= 0,
              candidate.seatWeights.allSatisfy({
                  $0.isFinite && $0 > 0
              }),
              candidate.baselineTargetErrorDB.allSatisfy({
                  $0.isFinite && abs($0) <= 100
              }),
              candidate.candidateTargetErrorDB.allSatisfy({
                  $0.isFinite && abs($0) <= 100
              }) else {
            return UnifiedAcousticRobustnessReview(
                nominalWeightedSquaredErrorImprovementDB2: 0,
                worstCaseWeightedSquaredErrorImprovementDB2: 0,
                worstSeatTargetErrorRegressionDB: 0,
                latencyMilliseconds: 0,
                blockingReasons: [
                    "Invalid or mismatched seat count, response, uncertainty, weights, sample rate or timing."
                ]
            )
        }
        let totalWeight = candidate.seatWeights.enumerated().reduce(0.0) {
            $0 + (heldOut.contains($1.offset) ? 0.0 : $1.element)
        }
        guard totalWeight.isFinite, totalWeight > 0 else {
            return UnifiedAcousticRobustnessReview(
                nominalWeightedSquaredErrorImprovementDB2: 0,
                worstCaseWeightedSquaredErrorImprovementDB2: 0,
                worstSeatTargetErrorRegressionDB: 0,
                latencyMilliseconds: 0,
                blockingReasons: ["Seat weight sum is invalid."]
            )
        }

        // Worst case uses *independent* bounded errors on each capture:
        // baseline error may be as small as |b|-u; candidate as large
        // as |c|+u. This interval proof cannot manufacture statistical
        // confidence or assume repeat errors cancel between captures.
        var nominalBefore = 0.0
        var nominalAfter = 0.0
        var optimisticBeforeLower = 0.0
        var pessimisticAfterUpper = 0.0
        var worstSeat = -Double.infinity
        var heldOutWorst = -Double.infinity
        for i in 0..<count {
            let weight = heldOut.contains(i)
                ? 0.0 : candidate.seatWeights[i] / totalWeight
            let before = abs(candidate.baselineTargetErrorDB[i])
            let after = abs(candidate.candidateTargetErrorDB[i])
            let beforeLower = max(0, before - candidate.absoluteMeasurementUncertaintyDB)
            let afterUpper = after + candidate.absoluteMeasurementUncertaintyDB
            nominalBefore += weight * before * before
            nominalAfter += weight * after * after
            optimisticBeforeLower += weight * beforeLower * beforeLower
            pessimisticAfterUpper += weight * afterUpper * afterUpper
            worstSeat = max(worstSeat, afterUpper - beforeLower)
            if heldOut.contains(i) {
                heldOutWorst = max(heldOutWorst, afterUpper - beforeLower)
            }
        }
        let nominalImprovement = nominalBefore - nominalAfter
        let robustImprovement = optimisticBeforeLower - pessimisticAfterUpper
        let latencyMS = Double(candidate.fixedLatencyFrames) * 1_000
            / candidate.sampleRate

        if robustImprovement < minimumRobustImprovementDB2 {
            blockers.append("Modeled benefit does not survive the supplied independent measurement-error bounds.")
        }
        if worstSeat > maximumWorstSeatRegressionDB {
            blockers.append("At least one listening seat may regress under the supplied measurement uncertainty.")
        }
        if heldOutWorst > maximumWorstSeatRegressionDB {
            blockers.append("Held-out listening seat fails independent target-error regression protection.")
        }
        if candidate.additionalHeadroomDB > maximumAdditionalHeadroomDB {
            blockers.append("Additional headroom requirement exceeds the conservative review budget.")
        }
        if latencyMS > maximumFixedLatencyMilliseconds {
            blockers.append("Fixed processing latency exceeds the conservative 30 ms A/V review budget.")
        }
        if candidate.domain == .multiSub {
            if candidate.physicalSubwooferOutputCount < 2 {
                blockers.append("Coordinated multi-Sub optimization needs independently addressable physical outputs.")
            }
            if !candidate.coherentClockAuthenticated {
                blockers.append("Coherent timing evidence and a common clock are not authenticated.")
            }
        }
        return UnifiedAcousticRobustnessReview(
            nominalWeightedSquaredErrorImprovementDB2: nominalImprovement,
            worstCaseWeightedSquaredErrorImprovementDB2: robustImprovement,
            worstSeatTargetErrorRegressionDB: worstSeat,
            latencyMilliseconds: latencyMS,
            blockingReasons: blockers,
            heldOutSeatWorstRegressionDB: heldOut.isEmpty ? nil : heldOutWorst
        )
    }
}


// MARK: - Multi-objective bass hypothesis tradeoffs
// Physical-source response, phase coherence and room target error are
// distinct metrics. Rank only explicitly *comparable* hypothetical scenarios
// from the SAME measured base and route, and never authorize deployment.

struct UnifiedAcousticBassScenario: Equatable, Sendable {
    var id: String
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var baselineEvidenceID: UUID
    var seatSpreadRMSDB: Double
    var targetRMSEDB: Double
    var decaySeconds: Double
    var extraHeadroomDB: Double
    var extraLatencyFrames: Int
    var filterCount: Int
    var physicalSubOutputCount: Int
    var coherentClockAuthenticated: Bool
}

struct UnifiedAcousticBassTradeoff: Equatable, Sendable {
    var scenarioID: String
    var seatSpreadRMSDB: Double
    var targetRMSEDB: Double
    var decaySeconds: Double
    var headroomCostDB: Double
    var latencyMilliseconds: Double
    var filterCount: Int
    var paretoFrontier: Bool
    var blockers: [String]
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

struct UnifiedAcousticBassComparison: Equatable, Sendable {
    var baselineID: UUID
    var options: [UnifiedAcousticBassTradeoff]
    var warnings: [String]
    var previewOnly: Bool { true }
    var canApply: Bool { false }
    var canDeploy: Bool { false }
}

/// No weighted scalar "best bass" score: a 1-dB improvement in seating
/// uniformity cannot objectively be declared worth 10 ms latency or 2 dB
/// amplifier headroom. Show the non-dominated choices and transparent costs.
struct UnifiedAcousticBassTradeoffEvaluator: Sendable {
    func compare(
        baseline: UnifiedAcousticBassScenario,
        candidates: [UnifiedAcousticBassScenario]
    ) -> UnifiedAcousticBassComparison {
        let all = [baseline] + candidates
        let validContext = all.allSatisfy {
            $0.playbackSystemID == baseline.playbackSystemID
                && $0.routingSignature == baseline.routingSignature
                && $0.baselineEvidenceID == baseline.baselineEvidenceID
                && $0.sampleRate == baseline.sampleRate
        }
        let inputValid = !baseline.routingSignature.isEmpty
            && baseline.sampleRate.isFinite
            && (8_000...384_000).contains(baseline.sampleRate)
            && (1...16).contains(all.count)
            && Set(all.map(\.id)).count == all.count
            && all.allSatisfy {
                !$0.id.isEmpty
                    && $0.seatSpreadRMSDB.isFinite
                    && $0.seatSpreadRMSDB >= 0
                    && $0.targetRMSEDB.isFinite
                    && $0.targetRMSEDB >= 0
                    && $0.decaySeconds.isFinite
                    && $0.decaySeconds >= 0
                    && $0.extraHeadroomDB.isFinite
                    && $0.extraHeadroomDB >= 0
                    && $0.extraLatencyFrames >= 0
                    && (0...128).contains($0.filterCount)
                    && (0...16).contains($0.physicalSubOutputCount)
            }
        guard validContext && inputValid else {
            return UnifiedAcousticBassComparison(
                baselineID: baseline.baselineEvidenceID,
                options: [], warnings: [
                    "Bass scenario identities, sample rates, evidence baseline, unique IDs, or numeric objectives are inconsistent."
                ]
            )
        }

        func objectiveVector(_ scenario: UnifiedAcousticBassScenario) -> [Double] {
            [
                scenario.seatSpreadRMSDB,
                scenario.targetRMSEDB,
                scenario.decaySeconds,
                scenario.extraHeadroomDB,
                Double(scenario.extraLatencyFrames) / scenario.sampleRate,
                Double(scenario.filterCount)
            ]
        }
        func dominates(_ other: UnifiedAcousticBassScenario,
                       _ current: UnifiedAcousticBassScenario) -> Bool {
            let a = objectiveVector(other), b = objectiveVector(current)
            return zip(a, b).allSatisfy { pair in pair.0 <= pair.1 + 1e-9 }
                && zip(a, b).contains { pair in pair.0 < pair.1 - 1e-9 }
        }

        let options = all.map { scenario -> UnifiedAcousticBassTradeoff in
            let latencyMs = Double(scenario.extraLatencyFrames) * 1000
                / scenario.sampleRate
            var blockers: [String] = []
            if scenario.extraHeadroomDB > 3.5 {
                blockers.append("Extra headroom exceeds 3.5 dB.")
            }
            if latencyMs > 30 {
                blockers.append("Additional A/V latency exceeds 30 ms.")
            }
            if scenario.physicalSubOutputCount < 2 {
                blockers.append("True multi-Sub control needs independently addressable Sub outputs.")
            }
            if !scenario.coherentClockAuthenticated {
                blockers.append("Common-clock phase reference has not been authenticated.")
            }
            let onFrontier = !all.contains {
                $0.id != scenario.id && dominates($0, scenario)
            }
            return UnifiedAcousticBassTradeoff(
                scenarioID: scenario.id,
                seatSpreadRMSDB: scenario.seatSpreadRMSDB,
                targetRMSEDB: scenario.targetRMSEDB,
                decaySeconds: scenario.decaySeconds,
                headroomCostDB: scenario.extraHeadroomDB,
                latencyMilliseconds: latencyMs,
                filterCount: scenario.filterCount,
                paretoFrontier: onFrontier,
                blockers: blockers
            )
        }
        return UnifiedAcousticBassComparison(
            baselineID: baseline.baselineEvidenceID,
            options: options,
            warnings: [
                "These comparable modeled scenarios are not verified measurements, and a Pareto frontier is NOT permission to deploy.",
                "Multi-Sub output mapping, microphone timing and DSP headroom require verified source evidence and owner hardware tests."
            ]
        )
    }
}
