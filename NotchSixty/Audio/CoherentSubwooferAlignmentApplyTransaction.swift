import Foundation

@MainActor
protocol CoherentSubwooferAlignmentProfileMutating: AnyObject {
    var coherentAlignmentSelectedSystemProfile:
        PlaybackSystemProfile? { get }
    var coherentAlignmentLifecycleState:
        AudioLifecycleState { get }

    func coherentAlignmentReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws
}

extension ProductProfileController:
    CoherentSubwooferAlignmentProfileMutating {
    var coherentAlignmentSelectedSystemProfile:
        PlaybackSystemProfile? {
        selectedSystemProfile
    }

    var coherentAlignmentLifecycleState:
        AudioLifecycleState {
        engine.lifecycleState
    }

    func coherentAlignmentReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        try replaceSelectedSystemOutputDeviceProfile(
            configuration
        )
    }
}

struct CoherentSubwooferAlignmentApplyReceipt:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var appliedAt: Date
    var proposalID: UUID
    var playbackSystemID: UUID
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var candidate: CoherentSubwooferAlignmentCandidate
    var rollbackSnapshot:
        CoherentSubwooferAlignmentRollbackSnapshot
    var expectedAppliedState: PlaybackSystemState

    var requiresMeasuredVerification: Bool { true }
    var isMeasuredVerification: Bool { false }
}

struct CoherentSubwooferAlignmentRollbackReceipt:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var playbackSystemID: UUID
    var rolledBackAt: Date
    var restoredState: PlaybackSystemState
}

enum CoherentSubwooferAlignmentApplyError:
    Error, Equatable, LocalizedError {
    case lifecycleMustBeIdle(AudioLifecycleState)
    case selectedProfileRequired
    case selectedProfileIdentityMismatch
    case currentStateDrift
    case outputDeviceProfileRequired
    case targetSubwooferUnavailable(UInt32)
    case calibrationMutationInvalid
    case applyMutationFailed
    case postApplyVerificationFailed
    case rollbackStateDrift
    case rollbackMutationFailed
    case rollbackVerificationFailed

    var errorDescription: String? {
        switch self {
        case .lifecycleMustBeIdle(let state):
            return "Stop DSP playback before coherent Sub alignment Apply or rollback. The engine is currently \(state.rawValue)."
        case .selectedProfileRequired:
            return "Select the commissioned Playback System before coherent Sub alignment Apply or rollback."
        case .selectedProfileIdentityMismatch:
            return "The selected Playback System does not match the coherent Sub alignment proposal."
        case .currentStateDrift:
            return "The Playback System changed after coherent Sub alignment review. Regenerate the proposal before Apply."
        case .outputDeviceProfileRequired:
            return "The commissioned Playback System no longer has an enabled Output Device Profile."
        case .targetSubwooferUnavailable(let index):
            return "Physical Sub \(index + 1) is no longer assigned in the Output Device Profile."
        case .calibrationMutationInvalid:
            return "The proposed speaker/Sub delay or polarity update no longer fits the calibrated realtime limits."
        case .applyMutationFailed:
            return "Coherent Sub alignment could not be installed atomically; the prior Output Device Profile was restored when possible."
        case .postApplyVerificationFailed:
            return "Coherent Sub alignment was written but the resulting Playback System did not exactly match the expected transactional state."
        case .rollbackStateDrift:
            return "Rollback was blocked because the Playback System changed after coherent Sub alignment Apply."
        case .rollbackMutationFailed:
            return "Coherent Sub alignment rollback could not restore the prior Output Device Profile."
        case .rollbackVerificationFailed:
            return "Rollback wrote state but the restored Playback System does not exactly match the commissioning snapshot."
        }
    }
}

/// PR108 Slice 3: engine-idle transactional mutation of only timing/polarity
/// fields already owned by speaker/subwoofer calibration.
///
/// No crossover, gain, EQ, Room Correction or Speaker Optimizer state changes.
/// Negative relative Sub delay is materialized as a common positive delay added
/// to every non-LFE speaker calibration.
@MainActor
struct CoherentSubwooferAlignmentApplyTransaction {
    private let commissioning =
        CoherentSubwooferAlignmentCommissioningPlanner()

    func apply(
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating,
        proposal:
            CoherentSubwooferAlignmentCommissioningProposal,
        approval: CoherentSubwooferAlignmentApproval,
        appliedAt: Date = Date()
    ) throws -> CoherentSubwooferAlignmentApplyReceipt {
        try requireIdle(profileStore)
        try commissioning.validateApproval(
            approval,
            for: proposal
        )

        guard let current =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentSubwooferAlignmentApplyError
                .selectedProfileRequired
        }
        guard current.id == proposal.playbackSystemID,
              proposal.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw CoherentSubwooferAlignmentApplyError
                .selectedProfileIdentityMismatch
        }
        guard current.state
                == proposal.rollbackSnapshot.playbackSystemState else {
            throw CoherentSubwooferAlignmentApplyError
                .currentStateDrift
        }
        guard current.state.bassManagement.enabled,
              abs(current.state.bassManagement.frequencyHz
                    - proposal.crossoverFrequencyHz) < 1.0e-9,
              var output = current.state.outputDeviceProfile,
              output.enabled else {
            throw CoherentSubwooferAlignmentApplyError
                .outputDeviceProfileRequired
        }

        do {
            try materialize(
                candidate: proposal.candidate,
                output: &output
            )
            try output.validateStructure(
                bassManagementEnabled: true
            )
        } catch let error as CoherentSubwooferAlignmentApplyError {
            throw error
        } catch {
            throw CoherentSubwooferAlignmentApplyError
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
            throw CoherentSubwooferAlignmentApplyError
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
            throw CoherentSubwooferAlignmentApplyError
                .postApplyVerificationFailed
        }

        return CoherentSubwooferAlignmentApplyReceipt(
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

    func rollback(
        _ receipt: CoherentSubwooferAlignmentApplyReceipt,
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating,
        rolledBackAt: Date = Date()
    ) throws -> CoherentSubwooferAlignmentRollbackReceipt {
        try requireIdle(profileStore)
        guard let current =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentSubwooferAlignmentApplyError
                .selectedProfileRequired
        }
        guard current.id == receipt.playbackSystemID,
              receipt.rollbackSnapshot.playbackSystemID
                == current.id else {
            throw CoherentSubwooferAlignmentApplyError
                .selectedProfileIdentityMismatch
        }
        guard current.state == receipt.expectedAppliedState else {
            throw CoherentSubwooferAlignmentApplyError
                .rollbackStateDrift
        }

        do {
            try restore(
                receipt.rollbackSnapshot.playbackSystemState
                    .outputDeviceProfile,
                profileStore: profileStore
            )
        } catch {
            throw CoherentSubwooferAlignmentApplyError
                .rollbackMutationFailed
        }

        guard let restored =
                profileStore.coherentAlignmentSelectedSystemProfile,
              restored.id == current.id,
              restored.state
                == receipt.rollbackSnapshot.playbackSystemState else {
            throw CoherentSubwooferAlignmentApplyError
                .rollbackVerificationFailed
        }

        return CoherentSubwooferAlignmentRollbackReceipt(
            applyReceiptID: receipt.id,
            playbackSystemID: current.id,
            rolledBackAt: rolledBackAt,
            restoredState: restored.state
        )
    }

    private func materialize(
        candidate: CoherentSubwooferAlignmentCandidate,
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
                    throw CoherentSubwooferAlignmentApplyError
                        .calibrationMutationInvalid
                }
                output.speakerAssignments[index].calibration =
                    calibration
            }
        }

        guard let subPosition =
                output.subwooferAssignments.firstIndex(where: {
                    $0.index == candidate.subwooferIndex
                }) else {
            throw CoherentSubwooferAlignmentApplyError
                .targetSubwooferUnavailable(
                    candidate.subwooferIndex
                )
        }
        var subCalibration =
            output.subwooferAssignments[subPosition].calibration
            ?? PhysicalSubwooferCalibration()
        subCalibration.delayMilliseconds +=
            candidate.subwooferDelayAdjustmentMilliseconds
        subCalibration.polarityInverted =
            candidate.resultingSubwooferPolarityInverted
        do {
            try subCalibration.validate(
                sampleRate: candidate.sampleRate
            )
        } catch {
            throw CoherentSubwooferAlignmentApplyError
                .calibrationMutationInvalid
        }
        output.subwooferAssignments[subPosition].calibration =
            subCalibration
    }

    private func requireIdle(
        _ profileStore:
            any CoherentSubwooferAlignmentProfileMutating
    ) throws {
        let state =
            profileStore.coherentAlignmentLifecycleState
        guard state == .idle else {
            throw CoherentSubwooferAlignmentApplyError
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
