import Foundation

@MainActor
protocol SpeakerOptimizerPEQProfileMutating: AnyObject {
    var speakerOptimizerSelectedSystemProfile: PlaybackSystemProfile? { get }
    var speakerOptimizerLifecycleState: AudioLifecycleState { get }

    func speakerOptimizerReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws
}

extension ProductProfileController: SpeakerOptimizerPEQProfileMutating {
    var speakerOptimizerSelectedSystemProfile: PlaybackSystemProfile? {
        selectedSystemProfile
    }

    var speakerOptimizerLifecycleState: AudioLifecycleState {
        engine.lifecycleState
    }

    func speakerOptimizerReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        try replaceSelectedSystemOutputDeviceProfile(configuration)
    }
}

struct SpeakerOptimizerPEQApplyReceipt:
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
    var deployment: SpeakerOptimizerPEQDeploymentConfiguration
    var rollbackSnapshot: SpeakerOptimizerRollbackSnapshot
    var expectedAppliedState: PlaybackSystemState

    /// Applying coefficients is not proof that they improved the acoustic
    /// result. A fresh microphone verification campaign remains mandatory.
    var requiresMeasuredVerification: Bool { true }
    var isMeasuredVerification: Bool { false }
}

struct SpeakerOptimizerPEQRollbackReceipt:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var playbackSystemID: UUID
    var rolledBackAt: Date
    var restoredState: PlaybackSystemState
}

enum SpeakerOptimizerPEQApplyTransactionError:
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
            return "Stop DSP playback before Speaker Optimizer Apply or rollback. The engine is currently \(state.rawValue)."
        case .selectedProfileRequired:
            return "Select the commissioned Playback System before Speaker Optimizer Apply or rollback."
        case .selectedProfileIdentityMismatch:
            return "The selected Playback System does not match the commissioned Speaker Optimizer proposal."
        case .rollbackSnapshotMismatch:
            return "The commissioning rollback snapshot is invalid or does not match the proposal routing identity."
        case .currentStateDrift:
            return "The Playback System changed after commissioning review. Regenerate the proposal before applying Speaker Optimizer PEQ."
        case .outputDeviceProfileRequired:
            return "The commissioned Playback System no longer has an enabled Output Device Profile."
        case .applyMutationFailed:
            return "Speaker Optimizer PEQ could not be installed atomically; the previous Output Device Profile was restored when possible."
        case .postApplyVerificationFailed:
            return "Speaker Optimizer PEQ was written but the resulting Playback System did not exactly match the expected transactional state."
        case .rollbackStateDrift:
            return "Rollback was blocked because the Playback System changed after Speaker Optimizer Apply; unrelated edits will not be overwritten."
        case .rollbackMutationFailed:
            return "Speaker Optimizer rollback could not restore the previous Output Device Profile."
        case .rollbackVerificationFailed:
            return "Speaker Optimizer rollback completed a write but the restored Playback System does not exactly match the captured rollback snapshot."
        }
    }
}

/// First live Speaker Optimizer mutation path.
///
/// The transaction remains deliberately PEQ-only. FIR stays blocked until a
/// separately owned per-speaker FIR stage with explicit latency/headroom
/// coordination exists.
///
/// Apply and rollback are restricted to engine-idle state because changing the
/// semantic output profile requires a live N-channel restart. The proposal's
/// complete PlaybackSystemState is used as an optimistic-concurrency snapshot:
/// any drift before Apply blocks the write. Rollback likewise refuses to
/// overwrite later unrelated edits.
@MainActor
struct SpeakerOptimizerPEQApplyTransaction {
    private let planner = SpeakerOptimizerCommissioningPlanner()

    func apply(
        profileStore: any SpeakerOptimizerPEQProfileMutating,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval,
        appliedAt: Date = Date()
    ) throws -> SpeakerOptimizerPEQApplyReceipt {
        try requireIdle(profileStore)

        guard let current = profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerPEQApplyTransactionError.selectedProfileRequired
        }
        guard current.id == proposal.playbackSystemID,
              proposal.rollbackSnapshot.playbackSystemID == current.id else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .selectedProfileIdentityMismatch
        }
        guard proposal.rollbackSnapshot.routingSignature
                == proposal.routingSignature,
              proposal.rollbackSnapshot.playbackSystemState
                .outputDeviceProfile?
                .multichannelCalibrationRoutingSignature
                == proposal.routingSignature else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .rollbackSnapshotMismatch
        }

        // This is intentionally exact. Commissioning approval applies to one
        // immutable system snapshot, not "roughly the same" routing.
        guard current.state == proposal.rollbackSnapshot.playbackSystemState else {
            throw SpeakerOptimizerPEQApplyTransactionError.currentStateDrift
        }

        let deployment = try planner.makePEQDeploymentConfiguration(
            profile: current,
            plan: plan,
            proposal: proposal,
            approval: approval
        )

        guard var outputProfile = current.state.outputDeviceProfile,
              outputProfile.enabled else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .outputDeviceProfileRequired
        }
        outputProfile.speakerOptimizerPEQ = deployment
        try outputProfile.validateStructure(
            bassManagementEnabled: current.state.bassManagement.enabled
        )

        var expectedAppliedState = current.state
        expectedAppliedState.outputDeviceProfile = outputProfile

        do {
            try profileStore.speakerOptimizerReplaceOutputDeviceProfile(
                outputProfile
            )
        } catch {
            // ProductProfileController already rolls back engine + persisted
            // profile atomically. This extra attempt also protects alternate
            // conformers used by future integration layers.
            try? restoreOutputProfile(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw SpeakerOptimizerPEQApplyTransactionError
                .applyMutationFailed
        }

        guard let applied = profileStore.speakerOptimizerSelectedSystemProfile,
              applied.id == current.id,
              applied.state == expectedAppliedState else {
            try? restoreOutputProfile(
                proposal.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
            throw SpeakerOptimizerPEQApplyTransactionError
                .postApplyVerificationFailed
        }

        return SpeakerOptimizerPEQApplyReceipt(
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
        _ receipt: SpeakerOptimizerPEQApplyReceipt,
        profileStore: any SpeakerOptimizerPEQProfileMutating,
        rolledBackAt: Date = Date()
    ) throws -> SpeakerOptimizerPEQRollbackReceipt {
        try requireIdle(profileStore)
        guard receipt.schemaVersion
                == SpeakerOptimizerPEQApplyReceipt.currentSchemaVersion else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .rollbackSnapshotMismatch
        }
        guard let current = profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerPEQApplyTransactionError.selectedProfileRequired
        }
        guard current.id == receipt.playbackSystemID,
              receipt.rollbackSnapshot.playbackSystemID == current.id,
              receipt.rollbackSnapshot.routingSignature
                == receipt.routingSignature else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .selectedProfileIdentityMismatch
        }

        // Never roll back across an unrelated user/system edit. The user can
        // regenerate/review instead of losing work.
        guard current.state == receipt.expectedAppliedState else {
            throw SpeakerOptimizerPEQApplyTransactionError.rollbackStateDrift
        }

        do {
            try restoreOutputProfile(
                receipt.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
        } catch {
            throw SpeakerOptimizerPEQApplyTransactionError
                .rollbackMutationFailed
        }

        guard let restored = profileStore.speakerOptimizerSelectedSystemProfile,
              restored.id == current.id,
              restored.state
                == receipt.rollbackSnapshot.playbackSystemState else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .rollbackVerificationFailed
        }

        return SpeakerOptimizerPEQRollbackReceipt(
            applyReceiptID: receipt.id,
            playbackSystemID: receipt.playbackSystemID,
            rolledBackAt: rolledBackAt,
            restoredState: restored.state
        )
    }

    private func requireIdle(
        _ profileStore: any SpeakerOptimizerPEQProfileMutating
    ) throws {
        let state = profileStore.speakerOptimizerLifecycleState
        guard state == .idle else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .lifecycleMustBeIdle(state)
        }
    }

    private func restoreOutputProfile(
        _ configuration: OutputDeviceProfileConfiguration?,
        profileStore: any SpeakerOptimizerPEQProfileMutating
    ) throws {
        try profileStore.speakerOptimizerReplaceOutputDeviceProfile(
            configuration
        )
    }
}
