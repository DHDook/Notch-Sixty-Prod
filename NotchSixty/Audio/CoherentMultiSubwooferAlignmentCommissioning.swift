import Foundation

struct CoherentMultiSubwooferAlignmentCommissioningProposal:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var crossoverFrequencyHz: Double
    var subwooferIndices: [UInt32]
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var candidate: CoherentMultiSubwooferAlignmentCandidate
    var rollbackSnapshot:
        CoherentSubwooferAlignmentRollbackSnapshot

    var approvalRequired: Bool { true }
    var readyForApproval: Bool {
        candidate.acceptedForPreview
            && candidate.previewOnly
            && !candidate.canDeploy
            && subwooferIndices.count >= 2
    }
    /// Slice 7 is commissioning-only. A dedicated coordinated transaction must
    /// exist before a multi-Sub proposal can become Apply-capable.
    var canApply: Bool { false }
    var canDeploy: Bool { false }
}

struct CoherentMultiSubwooferAlignmentApproval:
    Codable, Equatable, Sendable {
    var proposalID: UUID
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var approvedAt: Date
    var userInitiated: Bool
}

enum CoherentMultiSubwooferAlignmentCommissioningError:
    Error, Equatable, LocalizedError {
    case candidateNotReviewable
    case playbackSystemIdentityMismatch
    case outputDeviceProfileRequired
    case bassManagementMismatch
    case conflictingSingleSubProvenance
    case evidenceOrCandidateDrift
    case invalidApproval

    var errorDescription: String? {
        switch self {
        case .candidateNotReviewable:
            return "Only an accepted coordinated multi-Sub preview can enter commissioning."
        case .playbackSystemIdentityMismatch:
            return "The coordinated multi-Sub candidate does not belong to the selected Playback System."
        case .outputDeviceProfileRequired:
            return "The selected Playback System needs an enabled Output Device Profile for coordinated multi-Sub alignment."
        case .bassManagementMismatch:
            return "Bass-management state or crossover frequency changed after the coordinated candidate was designed."
        case .conflictingSingleSubProvenance:
            return "Clear or rollback existing single-Sub coherent-alignment provenance before coordinated multi-Sub commissioning."
        case .evidenceOrCandidateDrift:
            return "Coherent multi-Sub evidence or the derived coordinated candidate changed after review; regenerate the proposal."
        case .invalidApproval:
            return "Coordinated multi-Sub approval is missing, stale, or was not explicitly user initiated."
        }
    }
}

/// PR108 Slice 7: immutable coordinated multi-Sub commissioning identity.
///
/// All physical Subs are bound as one proposal. A caller cannot commission one
/// Sub at a time or swap evidence groups after review.
struct CoherentMultiSubwooferAlignmentCommissioningPlanner:
    Sendable {
    func proposal(
        profile: PlaybackSystemProfile,
        evidenceGroups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup],
        candidate: CoherentMultiSubwooferAlignmentCandidate,
        options: CoherentSubwooferAlignmentOptions = .init(),
        createdAt: Date = Date()
    ) throws
        -> CoherentMultiSubwooferAlignmentCommissioningProposal {
        guard candidate.acceptedForPreview,
              candidate.previewOnly,
              !candidate.canDeploy,
              candidate.subwoofers.count >= 2 else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .candidateNotReviewable
        }
        guard profile.id == candidate.playbackSystemID else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .playbackSystemIdentityMismatch
        }
        guard let output = profile.state.outputDeviceProfile,
              output.enabled else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .outputDeviceProfileRequired
        }
        guard output.coherentSubwooferAlignment == nil else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .conflictingSingleSubProvenance
        }
        let bass = profile.state.bassManagement
        guard bass.enabled,
              abs(
                bass.frequencyHz
                    - candidate.crossoverFrequencyHz
              ) < 1.0e-9 else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .bassManagementMismatch
        }

        let regenerated =
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: evidenceGroups,
                    profile: output,
                    bassManagementEnabled: bass.enabled,
                    crossoverFrequencyHz: bass.frequencyHz,
                    options: options
                )
        guard regenerated == candidate else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .evidenceOrCandidateDrift
        }

        let assigned = output.subwooferAssignments
            .map(\.index)
            .sorted()
        guard assigned
                == candidate.subwoofers
                    .map(\.subwooferIndex)
                    .sorted() else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .evidenceOrCandidateDrift
        }

        return CoherentMultiSubwooferAlignmentCommissioningProposal(
            createdAt: createdAt,
            playbackSystemID: profile.id,
            routingSignature: candidate.routingSignature,
            sampleRate: candidate.sampleRate,
            crossoverFrequencyHz:
                candidate.crossoverFrequencyHz,
            subwooferIndices: assigned,
            evidenceFingerprint:
                fingerprintEvidenceGroups(evidenceGroups),
            candidateFingerprint:
                fingerprintCandidate(candidate),
            candidate: candidate,
            rollbackSnapshot:
                CoherentSubwooferAlignmentRollbackSnapshot(
                    playbackSystemID: profile.id,
                    playbackSystemState: profile.state
                )
        )
    }

    func makeExplicitApproval(
        proposal:
            CoherentMultiSubwooferAlignmentCommissioningProposal,
        approvedAt: Date = Date(),
        userInitiated: Bool
    ) throws -> CoherentMultiSubwooferAlignmentApproval {
        guard proposal.readyForApproval, userInitiated else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .invalidApproval
        }
        return CoherentMultiSubwooferAlignmentApproval(
            proposalID: proposal.id,
            evidenceFingerprint: proposal.evidenceFingerprint,
            candidateFingerprint: proposal.candidateFingerprint,
            approvedAt: approvedAt,
            userInitiated: true
        )
    }

    func validateApproval(
        _ approval: CoherentMultiSubwooferAlignmentApproval,
        for proposal:
            CoherentMultiSubwooferAlignmentCommissioningProposal
    ) throws {
        guard proposal.readyForApproval,
              approval.userInitiated,
              approval.proposalID == proposal.id,
              approval.evidenceFingerprint
                == proposal.evidenceFingerprint,
              approval.candidateFingerprint
                == proposal.candidateFingerprint else {
            throw CoherentMultiSubwooferAlignmentCommissioningError
                .invalidApproval
        }
    }

    func fingerprintEvidenceGroups(
        _ groups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup]
    ) -> String {
        let single =
            CoherentSubwooferAlignmentCommissioningPlanner()
        var digest = PR108StableDigest64()
        digest.add("pr108-coordinated-multisub-evidence-v1")
        for group in groups.sorted(by: {
            $0.subwooferIndex < $1.subwooferIndex
        }) {
            digest.add(UInt64(group.subwooferIndex))
            digest.add(single.fingerprintReports(group.reports))
        }
        return digest.hex
    }

    func fingerprintCandidate(
        _ candidate: CoherentMultiSubwooferAlignmentCandidate
    ) -> String {
        var digest = PR108StableDigest64()
        digest.add("pr108-coordinated-multisub-candidate-v1")
        digest.add(candidate.playbackSystemID.uuidString)
        digest.add(candidate.routingSignature)
        digest.add(candidate.microphone.deviceUID)
        digest.add(UInt64(candidate.microphone.inputChannelIndex))
        digest.add(
            candidate.microphone.calibrationFingerprint ?? ""
        )
        digest.add(candidate.sampleRate.bitPattern)
        digest.add(candidate.crossoverFrequencyHz.bitPattern)
        for role in candidate.mainRoles.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            digest.add(role.rawValue)
        }
        digest.add(
            candidate
                .speakerCommonDelayAdjustmentMilliseconds
                .bitPattern
        )
        for sub in candidate.subwoofers.sorted(by: {
            $0.subwooferIndex < $1.subwooferIndex
        }) {
            digest.add(UInt64(sub.subwooferIndex))
            digest.add(
                sub.signedRelativeDelayAdjustmentMilliseconds
                    .bitPattern
            )
            digest.add(
                sub.subwooferDelayAdjustmentMilliseconds
                    .bitPattern
            )
            digest.add(sub.toggleSubwooferPolarity ? 1 : 0)
            digest.add(
                sub.resultingSubwooferPolarityInverted ? 1 : 0
            )
            digest.add(
                sub.predictedCoherenceBeforeDB.bitPattern
            )
            digest.add(
                sub.predictedCoherenceAfterDB.bitPattern
            )
            digest.add(sub.predictedImprovementDB.bitPattern)
        }
        digest.add(candidate.predictedCoherenceBeforeDB.bitPattern)
        digest.add(candidate.predictedCoherenceAfterDB.bitPattern)
        digest.add(candidate.predictedImprovementDB.bitPattern)
        digest.add(candidate.evidenceConfidence.bitPattern)
        return digest.hex
    }
}
