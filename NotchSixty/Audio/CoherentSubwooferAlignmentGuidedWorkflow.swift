import Combine
import Foundation

enum CoherentSubwooferAlignmentGuidedState:
    String, Equatable, Sendable {
    case idle
    case reviewReady
    case appliedPendingVerification
    case measuredAccepted
    case measuredRejected
    case rolledBack
    case failed
}

enum CoherentSubwooferAlignmentGuidedMode:
    Equatable, Sendable {
    case singleSubwoofer(UInt32)
    case coordinatedMultiSubwoofer([UInt32])

    var displayName: String {
        switch self {
        case .singleSubwoofer(let index):
            return "Sub \(index + 1)"
        case .coordinatedMultiSubwoofer(let indices):
            return "Coordinated \(indices.count)-Sub"
        }
    }
}

enum CoherentSubwooferAlignmentGuidedError:
    Error, Equatable, LocalizedError {
    case reviewRequired
    case applyRequired
    case playbackSystemRequired
    case outputDeviceProfileRequired
    case coherentEvidenceRequired
    case coherentEvidenceShapeMismatch
    case activeDeploymentRequiresResolution
    case verificationReceiptMismatch

    var errorDescription: String? {
        switch self {
        case .reviewRequired:
            return "Generate and review a coherent physical Sub alignment proposal first."
        case .applyRequired:
            return "Apply the reviewed coherent Sub alignment before measured verification."
        case .playbackSystemRequired:
            return "Select a Playback System before coherent Sub alignment."
        case .outputDeviceProfileRequired:
            return "The selected Playback System needs an enabled Output Device Profile with physical Sub assignments."
        case .coherentEvidenceRequired:
            return "Complete reference-authenticated coherent Main/Sub Measurement Lab pairs before generating an alignment proposal."
        case .coherentEvidenceShapeMismatch:
            return "The coherent Measurement Lab evidence does not cover the exact Main/Sub set required by the selected Playback System."
        case .activeDeploymentRequiresResolution:
            return "Verify or roll back the current coherent Sub alignment before generating another proposal."
        case .verificationReceiptMismatch:
            return "The measured verification evidence does not belong to the current coherent Sub alignment Apply receipt."
        }
    }
}

/// UI-facing PR108 commissioning state machine.
///
/// The controller intentionally reuses the PR106 Measurement Lab session as the
/// acquisition source. It creates no parallel measurement store and performs no
/// raw output mutation itself.
///
/// Raw candidates remain preview-only. Apply is available only after immutable
/// commissioning + explicit user approval. Fresh verification is re-analyzed
/// from the supplied post-Apply Lab session; accepted evidence is finalized,
/// rejected evidence is rolled back automatically.
@MainActor
final class CoherentSubwooferAlignmentGuidedController:
    ObservableObject {
    private let profileStore:
        any CoherentSubwooferAlignmentProfileMutating

    private let singlePlanner =
        CoherentSubwooferAlignmentPlanner()
    private let singleCommissioning =
        CoherentSubwooferAlignmentCommissioningPlanner()
    private let singleTransaction =
        CoherentSubwooferAlignmentApplyTransaction()
    private let singleVerifier =
        CoherentSubwooferAlignmentPostApplyVerifier()

    private let multiPlanner =
        CoherentMultiSubwooferAlignmentPlanner()
    private let multiCommissioning =
        CoherentMultiSubwooferAlignmentCommissioningPlanner()
    private let multiTransaction =
        CoherentMultiSubwooferAlignmentApplyTransaction()
    private let multiVerifier =
        CoherentMultiSubwooferAlignmentPostApplyVerifier()

    private let coherentAnalyzer =
        SpeakerMeasurementLabCoherentTimingAnalyzer()

    private var baselineSingleReports:
        [SpeakerMeasurementLabCoherentTimingReport] = []
    private var baselineMultiGroups:
        [CoherentMultiSubwooferAlignmentEvidenceGroup] = []

    @Published private(set) var state:
        CoherentSubwooferAlignmentGuidedState = .idle
    @Published private(set) var mode:
        CoherentSubwooferAlignmentGuidedMode?

    @Published private(set) var singleCandidate:
        CoherentSubwooferAlignmentCandidate?
    @Published private(set) var singleProposal:
        CoherentSubwooferAlignmentCommissioningProposal?
    @Published private(set) var singleApproval:
        CoherentSubwooferAlignmentApproval?
    @Published private(set) var singleApplyReceipt:
        CoherentSubwooferAlignmentApplyReceipt?
    @Published private(set) var singleVerificationReport:
        CoherentSubwooferAlignmentVerificationReport?
    @Published private(set) var singleFinalizationReceipt:
        CoherentSubwooferAlignmentVerificationFinalizationReceipt?
    @Published private(set) var singleRollbackReceipt:
        CoherentSubwooferAlignmentRollbackReceipt?

    @Published private(set) var multiCandidate:
        CoherentMultiSubwooferAlignmentCandidate?
    @Published private(set) var multiProposal:
        CoherentMultiSubwooferAlignmentCommissioningProposal?
    @Published private(set) var multiApproval:
        CoherentMultiSubwooferAlignmentApproval?
    @Published private(set) var multiApplyReceipt:
        CoherentMultiSubwooferAlignmentApplyReceipt?
    @Published private(set) var multiVerificationReport:
        CoherentMultiSubwooferAlignmentVerificationReport?
    @Published private(set) var multiFinalizationReceipt:
        CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt?
    @Published private(set) var multiRollbackReceipt:
        CoherentMultiSubwooferAlignmentRollbackReceipt?

    @Published private(set) var baselineSessionID: UUID?
    @Published private(set) var verificationSessionID: UUID?
    @Published private(set) var lastErrorDescription: String?

    init(
        profileStore:
            any CoherentSubwooferAlignmentProfileMutating
    ) {
        self.profileStore = profileStore
    }

    var canApproveAndApply: Bool {
        guard state == .reviewReady,
              profileStore.coherentAlignmentLifecycleState == .idle else {
            return false
        }
        switch mode {
        case .singleSubwoofer:
            return singleProposal?.canApply == true
        case .coordinatedMultiSubwoofer:
            return multiProposal?.canApply == true
        case .none:
            return false
        }
    }

    var canVerify: Bool {
        state == .appliedPendingVerification
            && profileStore.coherentAlignmentLifecycleState == .idle
    }

    var canRollback: Bool {
        let hasReceipt =
            singleApplyReceipt != nil
                || multiApplyReceipt != nil
        return hasReceipt
            && state != .rolledBack
            && profileStore.coherentAlignmentLifecycleState == .idle
    }

    var predictedImprovementDB: Double? {
        switch mode {
        case .singleSubwoofer:
            return singleCandidate?.predictedImprovementDB
        case .coordinatedMultiSubwoofer:
            return multiCandidate?.predictedImprovementDB
        case .none:
            return nil
        }
    }

    var speakerCommonDelayMilliseconds: Double? {
        switch mode {
        case .singleSubwoofer:
            return singleCandidate?
                .speakerCommonDelayAdjustmentMilliseconds
        case .coordinatedMultiSubwoofer:
            return multiCandidate?
                .speakerCommonDelayAdjustmentMilliseconds
        case .none:
            return nil
        }
    }

    var subwooferCount: Int {
        switch mode {
        case .singleSubwoofer:
            return 1
        case .coordinatedMultiSubwoofer(let indices):
            return indices.count
        case .none:
            return 0
        }
    }

    func prepareReview(
        baselineSession: SpeakerMeasurementLabSession
    ) throws {
        guard singleApplyReceipt == nil
                && multiApplyReceipt == nil
                || state == .rolledBack else {
            throw CoherentSubwooferAlignmentGuidedError
                .activeDeploymentRequiresResolution
        }
        guard let profile =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentSubwooferAlignmentGuidedError
                .playbackSystemRequired
        }
        guard let output = profile.state.outputDeviceProfile,
              output.enabled,
              !output.subwooferAssignments.isEmpty else {
            throw CoherentSubwooferAlignmentGuidedError
                .outputDeviceProfileRequired
        }

        do {
            let reports = try coherentReports(
                in: baselineSession
            )
            let groups = try evidenceGroups(
                reports: reports,
                expectedOutput: output
            )

            clearReviewAndReceipts()
            baselineSessionID = baselineSession.id

            if output.subwooferAssignments.count == 1 {
                let expectedIndex =
                    output.subwooferAssignments[0].index
                guard groups.count == 1,
                      groups[0].subwooferIndex
                        == expectedIndex else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .coherentEvidenceShapeMismatch
                }
                let candidate = try singlePlanner.propose(
                    reports: groups[0].reports,
                    profile: output,
                    bassManagementEnabled:
                        profile.state.bassManagement.enabled,
                    crossoverFrequencyHz:
                        profile.state.bassManagement.frequencyHz
                )
                let proposal =
                    try singleCommissioning.proposal(
                        profile: profile,
                        reports: groups[0].reports,
                        candidate: candidate
                    )

                mode = .singleSubwoofer(expectedIndex)
                baselineSingleReports = groups[0].reports
                baselineMultiGroups = []
                singleCandidate = candidate
                singleProposal = proposal
            } else {
                let candidate = try multiPlanner.propose(
                    evidenceGroups: groups,
                    profile: output,
                    bassManagementEnabled:
                        profile.state.bassManagement.enabled,
                    crossoverFrequencyHz:
                        profile.state.bassManagement.frequencyHz
                )
                let proposal =
                    try multiCommissioning.proposal(
                        profile: profile,
                        evidenceGroups: groups,
                        candidate: candidate
                    )

                let indices =
                    output.subwooferAssignments
                        .map(\.index)
                        .sorted()
                mode = .coordinatedMultiSubwoofer(indices)
                baselineSingleReports = []
                baselineMultiGroups = groups
                multiCandidate = candidate
                multiProposal = proposal
            }

            state = .reviewReady
            lastErrorDescription = nil
        } catch {
            state = .failed
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func approveAndApply(
        userInitiated: Bool,
        approvedAt: Date = Date(),
        appliedAt: Date = Date()
    ) throws {
        guard state == .reviewReady else {
            throw CoherentSubwooferAlignmentGuidedError
                .reviewRequired
        }

        do {
            switch mode {
            case .singleSubwoofer:
                guard let proposal = singleProposal else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .reviewRequired
                }
                let approval =
                    try singleCommissioning.makeExplicitApproval(
                        proposal: proposal,
                        approvedAt: approvedAt,
                        userInitiated: userInitiated
                    )
                let receipt = try singleTransaction.apply(
                    profileStore: profileStore,
                    proposal: proposal,
                    approval: approval,
                    appliedAt: appliedAt
                )
                singleApproval = approval
                singleApplyReceipt = receipt

            case .coordinatedMultiSubwoofer:
                guard let proposal = multiProposal else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .reviewRequired
                }
                let approval =
                    try multiCommissioning.makeExplicitApproval(
                        proposal: proposal,
                        approvedAt: approvedAt,
                        userInitiated: userInitiated
                    )
                let receipt = try multiTransaction.apply(
                    profileStore: profileStore,
                    proposal: proposal,
                    approval: approval,
                    appliedAt: appliedAt
                )
                multiApproval = approval
                multiApplyReceipt = receipt

            case .none:
                throw CoherentSubwooferAlignmentGuidedError
                    .reviewRequired
            }

            verificationSessionID = nil
            state = .appliedPendingVerification
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func verify(
        freshSession: SpeakerMeasurementLabSession
    ) throws {
        guard state == .appliedPendingVerification else {
            throw CoherentSubwooferAlignmentGuidedError
                .applyRequired
        }
        guard let currentProfile =
                profileStore.coherentAlignmentSelectedSystemProfile else {
            throw CoherentSubwooferAlignmentGuidedError
                .playbackSystemRequired
        }

        do {
            let reports = try coherentReports(in: freshSession)
            switch mode {
            case .singleSubwoofer(let subIndex):
                guard let receipt = singleApplyReceipt,
                      let candidate = singleCandidate else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .applyRequired
                }
                let matching = try matchingReports(
                    reports,
                    subwooferIndex: subIndex,
                    mainRoles: candidate.mainRoles
                )
                let report = try singleVerifier.verify(
                    baselineReports: baselineSingleReports,
                    verificationSession: freshSession,
                    verificationPairIDs:
                        matching.map(\.coherentPairID),
                    currentProfile: currentProfile,
                    receipt: receipt
                )
                try recordVerification(report)

            case .coordinatedMultiSubwoofer:
                guard let receipt = multiApplyReceipt,
                      let candidate = multiCandidate else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .applyRequired
                }
                var pairIDs: [UInt32: [UUID]] = [:]
                for sub in candidate.subwoofers {
                    let matching = try matchingReports(
                        reports,
                        subwooferIndex: sub.subwooferIndex,
                        mainRoles: candidate.mainRoles
                    )
                    pairIDs[sub.subwooferIndex] =
                        matching.map(\.coherentPairID)
                }
                let report = try multiVerifier.verify(
                    baselineEvidenceGroups:
                        baselineMultiGroups,
                    verificationSession: freshSession,
                    verificationPairIDsBySubwoofer: pairIDs,
                    currentProfile: currentProfile,
                    receipt: receipt
                )
                try recordVerification(report)

            case .none:
                throw CoherentSubwooferAlignmentGuidedError
                    .applyRequired
            }

            verificationSessionID = freshSession.id
            lastErrorDescription = nil
        } catch {
            if state != .rolledBack
                && state != .measuredAccepted {
                state = .failed
            }
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func recordVerification(
        _ report: CoherentSubwooferAlignmentVerificationReport
    ) throws {
        guard let receipt = singleApplyReceipt else {
            throw CoherentSubwooferAlignmentGuidedError
                .applyRequired
        }
        guard report.applyReceiptID == receipt.id,
              report.playbackSystemID
                == receipt.playbackSystemID,
              report.subwooferIndex
                == receipt.candidate.subwooferIndex else {
            throw CoherentSubwooferAlignmentGuidedError
                .verificationReceiptMismatch
        }
        singleVerificationReport = report
        if report.accepted {
            do {
                singleFinalizationReceipt =
                    try singleTransaction.finalizeVerified(
                        report,
                        receipt: receipt,
                        profileStore: profileStore
                    )
                singleRollbackReceipt = nil
                state = .measuredAccepted
            } catch {
                state = .failed
                throw error
            }
        } else {
            state = .measuredRejected
            do {
                singleRollbackReceipt =
                    try singleTransaction.rollback(
                        receipt,
                        profileStore: profileStore
                    )
                singleFinalizationReceipt = nil
                state = .rolledBack
            } catch {
                throw error
            }
        }
    }

    func recordVerification(
        _ report:
            CoherentMultiSubwooferAlignmentVerificationReport
    ) throws {
        guard let receipt = multiApplyReceipt else {
            throw CoherentSubwooferAlignmentGuidedError
                .applyRequired
        }
        guard report.applyReceiptID == receipt.id,
              report.playbackSystemID
                == receipt.playbackSystemID,
              report.subwooferIndices
                == receipt.candidate.subwoofers
                    .map(\.subwooferIndex)
                    .sorted() else {
            throw CoherentSubwooferAlignmentGuidedError
                .verificationReceiptMismatch
        }
        multiVerificationReport = report
        if report.accepted {
            do {
                multiFinalizationReceipt =
                    try multiTransaction.finalizeVerified(
                        report,
                        receipt: receipt,
                        profileStore: profileStore
                    )
                multiRollbackReceipt = nil
                state = .measuredAccepted
            } catch {
                state = .failed
                throw error
            }
        } else {
            state = .measuredRejected
            do {
                multiRollbackReceipt =
                    try multiTransaction.rollback(
                        receipt,
                        profileStore: profileStore
                    )
                multiFinalizationReceipt = nil
                state = .rolledBack
            } catch {
                throw error
            }
        }
    }

    func rollback(
        rolledBackAt: Date = Date()
    ) throws {
        do {
            if let receipt = singleApplyReceipt {
                singleRollbackReceipt =
                    try singleTransaction.rollback(
                        receipt,
                        profileStore: profileStore,
                        rolledBackAt: rolledBackAt
                    )
            } else if let receipt = multiApplyReceipt {
                multiRollbackReceipt =
                    try multiTransaction.rollback(
                        receipt,
                        profileStore: profileStore,
                        rolledBackAt: rolledBackAt
                    )
            } else {
                throw CoherentSubwooferAlignmentGuidedError
                    .applyRequired
            }
            state = .rolledBack
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func resetAfterRollback() {
        guard state == .rolledBack else { return }
        clearReviewAndReceipts()
        baselineSingleReports = []
        baselineMultiGroups = []
        baselineSessionID = nil
        verificationSessionID = nil
        mode = nil
        state = .idle
        lastErrorDescription = nil
    }

    private func coherentReports(
        in session: SpeakerMeasurementLabSession
    ) throws -> [SpeakerMeasurementLabCoherentTimingReport] {
        let pairIDs = Set(
            session.protocols.compactMap { labProtocol -> UUID? in
                guard labProtocol.request.mode
                        == .coherentMainsSubTiming else {
                    return nil
                }
                return labProtocol.coherentPairID
            }
        ).sorted {
            $0.uuidString < $1.uuidString
        }
        guard !pairIDs.isEmpty else {
            throw CoherentSubwooferAlignmentGuidedError
                .coherentEvidenceRequired
        }
        return try pairIDs.map {
            try coherentAnalyzer.analyze(
                session: session,
                coherentPairID: $0
            )
        }
    }

    private func evidenceGroups(
        reports: [SpeakerMeasurementLabCoherentTimingReport],
        expectedOutput: OutputDeviceProfileConfiguration
    ) throws -> [CoherentMultiSubwooferAlignmentEvidenceGroup] {
        var grouped:
            [UInt32: [SpeakerMeasurementLabCoherentTimingReport]] = [:]
        for report in reports {
            guard case .subwoofer(let index) =
                    report.subwoofer else {
                throw CoherentSubwooferAlignmentGuidedError
                    .coherentEvidenceShapeMismatch
            }
            grouped[index, default: []].append(report)
        }

        let expectedIndices = Set(
            expectedOutput.subwooferAssignments.map(\.index)
        )
        guard Set(grouped.keys) == expectedIndices else {
            throw CoherentSubwooferAlignmentGuidedError
                .coherentEvidenceShapeMismatch
        }

        return grouped.keys.sorted().map { index in
            CoherentMultiSubwooferAlignmentEvidenceGroup(
                subwooferIndex: index,
                reports: grouped[index]!.sorted {
                    mainRole(of: $0).rawValue
                        < mainRole(of: $1).rawValue
                }
            )
        }
    }

    private func matchingReports(
        _ reports: [SpeakerMeasurementLabCoherentTimingReport],
        subwooferIndex: UInt32,
        mainRoles: [OutputProgramRole]
    ) throws -> [SpeakerMeasurementLabCoherentTimingReport] {
        let expectedRoles = Set(mainRoles)
        let matching = reports.filter { report in
            guard report.subwoofer
                    == .subwoofer(subwooferIndex),
                  case .speaker(let role) = report.main else {
                return false
            }
            return expectedRoles.contains(role)
        }
        guard matching.count == expectedRoles.count,
              Set(matching.map { mainRole(of: $0) })
                == expectedRoles else {
            throw CoherentSubwooferAlignmentGuidedError
                .coherentEvidenceShapeMismatch
        }
        return matching.sorted {
            mainRole(of: $0).rawValue
                < mainRole(of: $1).rawValue
        }
    }

    private func mainRole(
        of report: SpeakerMeasurementLabCoherentTimingReport
    ) -> OutputProgramRole {
        guard case .speaker(let role) = report.main else {
            preconditionFailure(
                "Coherent PR108 evidence must use a whole-speaker Main."
            )
        }
        return role
    }

    private func clearReviewAndReceipts() {
        singleCandidate = nil
        singleProposal = nil
        singleApproval = nil
        singleApplyReceipt = nil
        singleVerificationReport = nil
        singleFinalizationReceipt = nil
        singleRollbackReceipt = nil

        multiCandidate = nil
        multiProposal = nil
        multiApproval = nil
        multiApplyReceipt = nil
        multiVerificationReport = nil
        multiFinalizationReceipt = nil
        multiRollbackReceipt = nil
    }
}
