import Foundation

struct CoherentMultiSubwooferAlignmentApplyReceipt:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var appliedAt: Date
    var proposalID: UUID
    var playbackSystemID: UUID
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var candidate: CoherentMultiSubwooferAlignmentCandidate
    var rollbackSnapshot:
        CoherentSubwooferAlignmentRollbackSnapshot
    var expectedAppliedState: PlaybackSystemState

    var requiresMeasuredVerification: Bool { true }
    var isMeasuredVerification: Bool { false }
}

struct CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var playbackSystemID: UUID
    var verifiedAt: Date
    var expectedVerifiedState: PlaybackSystemState
}

struct CoherentMultiSubwooferAlignmentRollbackReceipt:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var playbackSystemID: UUID
    var rolledBackAt: Date
    var restoredState: PlaybackSystemState
}

enum CoherentMultiSubwooferAlignmentApplyError:
    Error, Equatable, LocalizedError {
    case lifecycleMustBeIdle(AudioLifecycleState)
    case selectedProfileRequired
    case selectedProfileIdentityMismatch
    case currentStateDrift
    case outputDeviceProfileRequired
    case conflictingAlignmentProvenance
    case targetSubwooferUnavailable(UInt32)
    case calibrationMutationInvalid
    case applyMutationFailed
    case postApplyVerificationFailed
    case verificationReportRejected
    case verificationReceiptMismatch
    case verificationStateDrift
    case verificationMutationFailed
    case verificationWriteFailed
    case rollbackStateDrift
    case rollbackMutationFailed
    case rollbackVerificationFailed

    var errorDescription: String? {
        switch self {
        case .lifecycleMustBeIdle(let state):
            return "Stop DSP playback before coordinated multi-Sub alignment Apply or rollback. The engine is currently \(state.rawValue)."
        case .selectedProfileRequired:
            return "Select the commissioned Playback System before coordinated multi-Sub Apply or rollback."
        case .selectedProfileIdentityMismatch:
            return "The selected Playback System does not match the coordinated multi-Sub proposal."
        case .currentStateDrift:
            return "The Playback System changed after coordinated multi-Sub review. Regenerate the proposal before Apply."
        case .outputDeviceProfileRequired:
            return "The commissioned Playback System no longer has an enabled Output Device Profile."
        case .conflictingAlignmentProvenance:
            return "Existing coherent-alignment provenance conflicts with the coordinated multi-Sub transaction."
        case .targetSubwooferUnavailable(let index):
            return "Physical Sub \(index + 1) is no longer assigned in the Output Device Profile."
        case .calibrationMutationInvalid:
            return "The coordinated speaker/Sub timing or polarity update no longer fits the calibrated realtime limits."
        case .applyMutationFailed:
            return "Coordinated multi-Sub alignment could not be installed atomically; the prior Output Device Profile was restored when possible."
        case .postApplyVerificationFailed:
            return "Coordinated multi-Sub alignment was written but the resulting Playback System did not exactly match the expected transaction state."
        case .verificationReportRejected:
            return "Only an accepted fresh coordinated verification report can finalize multi-Sub alignment."
        case .verificationReceiptMismatch:
            return "The coordinated verification report does not belong to this Apply receipt."
        case .verificationStateDrift:
            return "The Playback System changed after provisional coordinated Apply; verification finalization is blocked."
        case .verificationMutationFailed:
            return "The verified coordinated provenance record could not be persisted."
        case .verificationWriteFailed:
            return "Verified coordinated provenance was written but the Playback System did not match the expected verified state."
        case .rollbackStateDrift:
            return "Rollback was blocked because the Playback System changed after coordinated multi-Sub Apply."
        case .rollbackMutationFailed:
            return "Coordinated multi-Sub rollback could not restore the prior Output Device Profile."
        case .rollbackVerificationFailed:
            return "Coordinated multi-Sub rollback wrote state but the restored Playback System does not exactly match the commissioning snapshot."
        }
    }
}

/// PR108 Slice 8: one engine-idle transaction for the complete physical Sub set.
///
/// The common speaker delay is applied exactly once. Every physical Sub is then
/// updated in the same Output Device Profile write. No gain, EQ, crossover,
/// Room Correction, Speaker Optimizer, or unrelated calibration field changes.
@MainActor
struct CoherentMultiSubwooferAlignmentApplyTransaction {
    private let commissioning =
        CoherentMultiSubwooferAlignmentCommissioningPlanner()

    func apply(
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating,
        proposal:
            CoherentMultiSubwooferAlignmentCommissioningProposal,
        approval: CoherentMultiSubwooferAlignmentApproval,
        appliedAt: Date = Date()
    ) throws -> CoherentMultiSubwooferAlignmentApplyReceipt {
        try requireIdle(profileStore)
        try commissioning.validateApproval(
            approval,
            for: proposal
        )

        guard let current =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileRequired
        }
        guard current.id == proposal.playbackSystemID,
              proposal.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileIdentityMismatch
        }
        guard current.state
                == proposal.rollbackSnapshot.playbackSystemState else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .currentStateDrift
        }
        guard current.state.bassManagement.enabled,
              abs(
                current.state.bassManagement.frequencyHz
                    - proposal.crossoverFrequencyHz
              ) < 1.0e-9,
              var output = current.state.outputDeviceProfile,
              output.enabled else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .outputDeviceProfileRequired
        }
        guard output.coherentSubwooferAlignment == nil,
              output.coherentMultiSubwooferAlignment == nil else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .conflictingAlignmentProvenance
        }

        let receiptID = UUID()
        do {
            try materialize(
                candidate: proposal.candidate,
                output: &output
            )
            output.coherentMultiSubwooferAlignment =
                try CoherentMultiSubwooferAlignmentDeploymentRecord
                    .capture(
                        applyReceiptID: receiptID,
                        proposal: proposal,
                        appliedAt: appliedAt,
                        output: output
                    )
            try output.validateStructure(
                bassManagementEnabled: true
            )
        } catch let error
            as CoherentMultiSubwooferAlignmentApplyError {
            throw error
        } catch {
            throw CoherentMultiSubwooferAlignmentApplyError
                .calibrationMutationInvalid
        }

        var expected = current.state
        expected.outputDeviceProfile = output

        do {
            try profileStore
                .coherentAlignmentReplaceOutputDeviceProfile(
                    output
                )
        } catch {
            try? restore(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw CoherentMultiSubwooferAlignmentApplyError
                .applyMutationFailed
        }

        guard let applied =
                profileStore.coherentAlignmentSelectedSystemProfile,
              applied.id == current.id,
              applied.state == expected else {
            try? restore(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw CoherentMultiSubwooferAlignmentApplyError
                .postApplyVerificationFailed
        }

        return CoherentMultiSubwooferAlignmentApplyReceipt(
            id: receiptID,
            appliedAt: appliedAt,
            proposalID: proposal.id,
            playbackSystemID: current.id,
            evidenceFingerprint:
                proposal.evidenceFingerprint,
            candidateFingerprint:
                proposal.candidateFingerprint,
            candidate: proposal.candidate,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expected
        )
    }

    func finalizeVerified(
        _ report:
            CoherentMultiSubwooferAlignmentVerificationReport,
        receipt: CoherentMultiSubwooferAlignmentApplyReceipt,
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating,
        verifiedAt: Date = Date()
    ) throws
        -> CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt {
        try requireIdle(profileStore)
        guard report.accepted,
              !report.shouldRollback,
              !report.sources.isEmpty else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationReportRejected
        }
        guard report.applyReceiptID == receipt.id,
              report.playbackSystemID
                == receipt.playbackSystemID,
              report.routingSignature
                == receipt.candidate.routingSignature,
              report.subwooferIndices
                == receipt.candidate.subwoofers
                    .map(\.subwooferIndex)
                    .sorted(),
              abs(
                report.sampleRate
                    - receipt.candidate.sampleRate
              ) < 0.5 else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationReceiptMismatch
        }

        guard let current =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileRequired
        }
        guard current.id == receipt.playbackSystemID else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileIdentityMismatch
        }
        guard current.state == receipt.expectedAppliedState else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationStateDrift
        }
        guard var output = current.state.outputDeviceProfile,
              var deployment =
                output.coherentMultiSubwooferAlignment,
              deployment.applyReceiptID == receipt.id,
              deployment.proposalID == receipt.proposalID,
              deployment.evidenceFingerprint
                == receipt.evidenceFingerprint,
              deployment.candidateFingerprint
                == receipt.candidateFingerprint,
              deployment.verification == nil else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationStateDrift
        }

        let record =
            CoherentMultiSubwooferAlignmentVerificationRecord(
                applyReceiptID: receipt.id,
                verificationSessionID:
                    report.verificationSessionID,
                verifiedAt: verifiedAt,
                evidenceConfidence:
                    report.evidenceConfidence,
                sourceCount: report.sources.count,
                worstPhaseTrackingRMSRadians:
                    report.sources
                        .map(\.phaseTrackingRMSRadians)
                        .max() ?? .infinity,
                worstMagnitudeTrackingRMSDB:
                    report.sources
                        .map(\.magnitudeTrackingRMSDB)
                        .max() ?? .infinity,
                coherenceBeforeDB:
                    report.coherenceBeforeDB,
                coherenceAfterDB:
                    report.coherenceAfterDB,
                measuredImprovementDB:
                    report.measuredImprovementDB
            )
        guard record.validate(deployment: deployment) else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationReportRejected
        }

        deployment.verification = record
        output.coherentMultiSubwooferAlignment = deployment
        do {
            try output.validateStructure(
                bassManagementEnabled:
                    current.state.bassManagement.enabled
            )
        } catch {
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationReportRejected
        }

        var expectedVerified = current.state
        expectedVerified.outputDeviceProfile = output
        do {
            try profileStore
                .coherentAlignmentReplaceOutputDeviceProfile(
                    output
                )
        } catch {
            try? restore(
                receipt.expectedAppliedState.outputDeviceProfile,
                profileStore: profileStore
            )
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationMutationFailed
        }

        guard let verified =
                profileStore.coherentAlignmentSelectedSystemProfile,
              verified.id == current.id,
              verified.state == expectedVerified else {
            try? restore(
                receipt.expectedAppliedState.outputDeviceProfile,
                profileStore: profileStore
            )
            throw CoherentMultiSubwooferAlignmentApplyError
                .verificationWriteFailed
        }

        return CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt(
            applyReceiptID: receipt.id,
            playbackSystemID: current.id,
            verifiedAt: verifiedAt,
            expectedVerifiedState: expectedVerified
        )
    }

    func rollback(
        _ receipt: CoherentMultiSubwooferAlignmentApplyReceipt,
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating,
        rolledBackAt: Date = Date()
    ) throws -> CoherentMultiSubwooferAlignmentRollbackReceipt {
        try requireIdle(profileStore)
        guard let current =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileRequired
        }
        guard current.id == receipt.playbackSystemID,
              receipt.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .selectedProfileIdentityMismatch
        }
        guard rollbackSourceStateMatches(
            current.state,
            receipt: receipt
        ) else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .rollbackStateDrift
        }

        do {
            try restore(
                receipt.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
        } catch {
            throw CoherentMultiSubwooferAlignmentApplyError
                .rollbackMutationFailed
        }

        guard let restored =
                profileStore.coherentAlignmentSelectedSystemProfile,
              restored.id == current.id,
              restored.state
                == receipt.rollbackSnapshot.playbackSystemState else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .rollbackVerificationFailed
        }

        return CoherentMultiSubwooferAlignmentRollbackReceipt(
            applyReceiptID: receipt.id,
            playbackSystemID: current.id,
            rolledBackAt: rolledBackAt,
            restoredState: restored.state
        )
    }

    private func rollbackSourceStateMatches(
        _ state: PlaybackSystemState,
        receipt: CoherentMultiSubwooferAlignmentApplyReceipt
    ) -> Bool {
        if state == receipt.expectedAppliedState {
            return true
        }
        var normalized = state
        guard var output = normalized.outputDeviceProfile,
              var deployment =
                output.coherentMultiSubwooferAlignment,
              deployment.applyReceiptID == receipt.id,
              deployment.verification != nil else {
            return false
        }
        deployment.verification = nil
        output.coherentMultiSubwooferAlignment = deployment
        normalized.outputDeviceProfile = output
        return normalized == receipt.expectedAppliedState
    }

    private func materialize(
        candidate: CoherentMultiSubwooferAlignmentCandidate,
        output: inout OutputDeviceProfileConfiguration
    ) throws {
        let speakerIncrement =
            candidate.speakerCommonDelayAdjustmentMilliseconds
        if speakerIncrement > 0 {
            for index in output.speakerAssignments.indices
            where output.speakerAssignments[index].role
                    != .lowFrequencyEffects {
                var calibration =
                    output.speakerAssignments[index].calibration
                    ?? SemanticSpeakerCalibration()
                calibration.delayMilliseconds += speakerIncrement
                do {
                    try calibration.validate(
                        sampleRate: candidate.sampleRate
                    )
                } catch {
                    throw CoherentMultiSubwooferAlignmentApplyError
                        .calibrationMutationInvalid
                }
                output.speakerAssignments[index].calibration =
                    calibration
            }
        }

        for plan in candidate.subwoofers {
            guard let position =
                    output.subwooferAssignments.firstIndex(
                        where: {
                            $0.index == plan.subwooferIndex
                        }
                    ) else {
                throw CoherentMultiSubwooferAlignmentApplyError
                    .targetSubwooferUnavailable(
                        plan.subwooferIndex
                    )
            }
            var calibration =
                output.subwooferAssignments[position].calibration
                ?? PhysicalSubwooferCalibration()
            calibration.delayMilliseconds +=
                plan.subwooferDelayAdjustmentMilliseconds
            calibration.polarityInverted =
                plan.resultingSubwooferPolarityInverted
            do {
                try calibration.validate(
                    sampleRate: candidate.sampleRate
                )
            } catch {
                throw CoherentMultiSubwooferAlignmentApplyError
                    .calibrationMutationInvalid
            }
            output.subwooferAssignments[position].calibration =
                calibration
        }
    }

    private func requireIdle(
        _ profileStore:
            any CoherentSubwooferAlignmentProfileMutating
    ) throws {
        let state =
            profileStore.coherentAlignmentLifecycleState
        guard state == .idle else {
            throw CoherentMultiSubwooferAlignmentApplyError
                .lifecycleMustBeIdle(state)
        }
    }

    private func restore(
        _ configuration: OutputDeviceProfileConfiguration?,
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating
    ) throws {
        try profileStore
            .coherentAlignmentReplaceOutputDeviceProfile(
                configuration
            )
    }
}
