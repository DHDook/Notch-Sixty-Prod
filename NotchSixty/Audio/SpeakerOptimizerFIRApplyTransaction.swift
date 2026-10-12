import Foundation

/// PR107 FIR uses the same narrow profile-mutation surface as the proven PEQ
/// transaction. The alias keeps the ownership contract explicit without adding
/// a second ProductProfileController mutation API.
typealias SpeakerOptimizerFIRProfileMutating =
    SpeakerOptimizerPEQProfileMutating

struct SpeakerOptimizerFIRApplyReceipt:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var appliedAt: Date
    var proposalID: UUID
    var playbackSystemID: UUID
    var baselineMeasurementSetID: UUID
    var characterizationMeasurementSetID: UUID
    var routingSignature: String
    var aggregateCandidateFingerprint: String
    var deployment: SpeakerOptimizerFIRDeploymentConfiguration
    var rollbackSnapshot: SpeakerOptimizerRollbackSnapshot
    var expectedAppliedState: PlaybackSystemState

    /// FIR Apply is provisional until a fresh microphone campaign proves the
    /// deployed acoustic result.
    var requiresMeasuredVerification: Bool { true }
    var isMeasuredVerification: Bool { false }
}

struct SpeakerOptimizerFIRRollbackReceipt:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var playbackSystemID: UUID
    var rolledBackAt: Date
    var restoredState: PlaybackSystemState
}

enum SpeakerOptimizerFIRApplyTransactionError:
    Error, Equatable, LocalizedError {
    case lifecycleMustBeIdle(AudioLifecycleState)
    case selectedProfileRequired
    case selectedProfileIdentityMismatch
    case rollbackSnapshotMismatch
    case currentStateDrift
    case outputDeviceProfileRequired
    case applyMutationFailed
    case postApplyVerificationFailed
    case rollbackStateDrift
    case rollbackMutationFailed
    case rollbackVerificationFailed

    var errorDescription: String? {
        switch self {
        case .lifecycleMustBeIdle(let state):
            return "Stop DSP playback before Speaker Optimizer FIR Apply or rollback. The engine is currently \(state.rawValue)."
        case .selectedProfileRequired:
            return "Select the commissioned Playback System before Speaker Optimizer FIR Apply or rollback."
        case .selectedProfileIdentityMismatch:
            return "The selected Playback System does not match the commissioned Speaker Optimizer FIR proposal."
        case .rollbackSnapshotMismatch:
            return "The Speaker Optimizer FIR rollback snapshot is invalid or does not match the proposal routing identity."
        case .currentStateDrift:
            return "The Playback System changed after FIR commissioning review. Regenerate the proposal before applying."
        case .outputDeviceProfileRequired:
            return "The commissioned Playback System no longer has an enabled Output Device Profile."
        case .applyMutationFailed:
            return "Speaker Optimizer FIR could not be installed atomically; the previous Output Device Profile was restored when possible."
        case .postApplyVerificationFailed:
            return "Speaker Optimizer FIR was written but the resulting Playback System did not exactly match the expected transactional state."
        case .rollbackStateDrift:
            return "FIR rollback was blocked because the Playback System changed after Apply; unrelated edits will not be overwritten."
        case .rollbackMutationFailed:
            return "Speaker Optimizer FIR rollback could not restore the previous Output Device Profile."
        case .rollbackVerificationFailed:
            return "Speaker Optimizer FIR rollback completed a write but the restored Playback System does not exactly match the captured rollback snapshot."
        }
    }
}

/// Atomic control-plane Apply/rollback for the dedicated Speaker Optimizer FIR.
///
/// The transaction never edits ordinary Speaker Calibration, Room Correction,
/// Speaker IR, or Content Preset headroom. Required FIR headroom is owned by the
/// persisted FIR deployment and automatically enforced by the N-channel graph
/// compiler. Mutation is engine-idle only because the semantic bridge must be
/// rebuilt to install/remove immutable FIR runtime state.
@MainActor
struct SpeakerOptimizerFIRApplyTransaction {
    private let planner = SpeakerOptimizerCommissioningPlanner()

    func apply(
        profileStore: any SpeakerOptimizerFIRProfileMutating,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval,
        appliedAt: Date = Date()
    ) throws -> SpeakerOptimizerFIRApplyReceipt {
        try requireIdle(profileStore)

        guard let current =
                profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileRequired
        }
        guard current.id == proposal.playbackSystemID,
              proposal.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileIdentityMismatch
        }
        guard proposal.rollbackSnapshot.routingSignature
                == proposal.routingSignature,
              proposal.rollbackSnapshot.playbackSystemState
                .outputDeviceProfile?
                .multichannelCalibrationRoutingSignature
                == proposal.routingSignature else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .rollbackSnapshotMismatch
        }
        guard current.state
                == proposal.rollbackSnapshot.playbackSystemState else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .currentStateDrift
        }

        let deployment =
            try planner.makeFIRDeploymentConfiguration(
                profile: current,
                plan: plan,
                proposal: proposal,
                approval: approval
            )

        guard var outputProfile =
                current.state.outputDeviceProfile,
              outputProfile.enabled else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .outputDeviceProfileRequired
        }
        outputProfile.speakerOptimizerFIR = deployment
        try outputProfile.validateStructure(
            bassManagementEnabled:
                current.state.bassManagement.enabled
        )

        var expectedAppliedState = current.state
        expectedAppliedState.outputDeviceProfile = outputProfile

        do {
            try profileStore
                .speakerOptimizerReplaceOutputDeviceProfile(
                    outputProfile
                )
        } catch {
            try? restoreOutputProfile(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw SpeakerOptimizerFIRApplyTransactionError
                .applyMutationFailed
        }

        guard let applied =
                profileStore.speakerOptimizerSelectedSystemProfile,
              applied.id == current.id,
              applied.state == expectedAppliedState else {
            try? restoreOutputProfile(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw SpeakerOptimizerFIRApplyTransactionError
                .postApplyVerificationFailed
        }

        return SpeakerOptimizerFIRApplyReceipt(
            appliedAt: appliedAt,
            proposalID: proposal.id,
            playbackSystemID: current.id,
            baselineMeasurementSetID:
                proposal.baselineMeasurementSetID,
            characterizationMeasurementSetID:
                proposal.characterizationMeasurementSetID,
            routingSignature: proposal.routingSignature,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            deployment: deployment,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expectedAppliedState
        )
    }

    func rollback(
        _ receipt: SpeakerOptimizerFIRApplyReceipt,
        profileStore: any SpeakerOptimizerFIRProfileMutating,
        rolledBackAt: Date = Date()
    ) throws -> SpeakerOptimizerFIRRollbackReceipt {
        try requireIdle(profileStore)

        guard let current =
                profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileRequired
        }
        guard current.id == receipt.playbackSystemID,
              receipt.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileIdentityMismatch
        }
        guard current.state == receipt.expectedAppliedState else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .rollbackStateDrift
        }

        do {
            try restoreOutputProfile(
                receipt.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
        } catch {
            throw SpeakerOptimizerFIRApplyTransactionError
                .rollbackMutationFailed
        }

        guard let restored =
                profileStore.speakerOptimizerSelectedSystemProfile,
              restored.id == receipt.playbackSystemID,
              restored.state
                == receipt.rollbackSnapshot.playbackSystemState else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .rollbackVerificationFailed
        }

        return SpeakerOptimizerFIRRollbackReceipt(
            applyReceiptID: receipt.id,
            playbackSystemID: receipt.playbackSystemID,
            rolledBackAt: rolledBackAt,
            restoredState: restored.state
        )
    }

    private func requireIdle(
        _ profileStore: any SpeakerOptimizerFIRProfileMutating
    ) throws {
        let state = profileStore.speakerOptimizerLifecycleState
        guard state == .idle else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .lifecycleMustBeIdle(state)
        }
    }

    private func restoreOutputProfile(
        _ configuration: OutputDeviceProfileConfiguration?,
        profileStore: any SpeakerOptimizerFIRProfileMutating
    ) throws {
        try profileStore
            .speakerOptimizerReplaceOutputDeviceProfile(
                configuration
            )
    }
}
