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
        multiSub: CoherentMultiSubwooferAlignmentCandidate? = nil
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
