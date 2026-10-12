import Combine
import Foundation

enum SpeakerOptimizerGuidedPEQState:
    String, Equatable, Sendable {
    case idle
    case reviewReady
    case appliedPendingVerification
    case measuredAccepted
    case measuredRejected
    case rolledBack
    case failed
}

enum SpeakerOptimizerGuidedPEQError:
    Error, Equatable, LocalizedError {
    case reviewRequired
    case applyRequired
    case activeDeploymentRequiresResolution
    case verificationReceiptMismatch

    var errorDescription: String? {
        switch self {
        case .reviewRequired:
            return "Generate and review a Speaker Optimizer PEQ proposal first."
        case .applyRequired:
            return "Apply the reviewed Speaker Optimizer PEQ before starting measured verification."
        case .activeDeploymentRequiresResolution:
            return "The current Speaker Optimizer deployment must be verified or rolled back before generating another proposal."
        case .verificationReceiptMismatch:
            return "The measured verification report does not belong to the current Speaker Optimizer Apply receipt."
        }
    }
}

typealias SpeakerOptimizerGuidedPEQDesignOperation = (
    SpeakerOptimizerCharacterizationMeasurementSet,
    SpeakerOptimizerMeasurementSet
) throws -> SpeakerOptimizerClassificationAwarePEQPlan

/// UI-facing commissioning state machine. Explicit approval is still a method
/// argument with no default, so tests/callers cannot accidentally mint approval
/// without passing the user-action fact.
@MainActor
final class SpeakerOptimizerGuidedPEQController: ObservableObject {
    private let profileStore: any SpeakerOptimizerPEQProfileMutating
    private let designOperation: SpeakerOptimizerGuidedPEQDesignOperation
    private let planner = SpeakerOptimizerCommissioningPlanner()
    private let transaction = SpeakerOptimizerPEQApplyTransaction()

    @Published private(set) var state: SpeakerOptimizerGuidedPEQState = .idle
    @Published private(set) var plan:
        SpeakerOptimizerClassificationAwarePEQPlan?
    @Published private(set) var proposal:
        SpeakerOptimizerCommissioningProposal?
    @Published private(set) var approval:
        SpeakerOptimizerApplyApproval?
    @Published private(set) var applyReceipt:
        SpeakerOptimizerPEQApplyReceipt?
    @Published private(set) var verificationReport:
        SpeakerOptimizerPostApplyVerificationReport?
    @Published private(set) var rollbackReceipt:
        SpeakerOptimizerPEQRollbackReceipt?
    @Published private(set) var verificationFinalizationReceipt:
        SpeakerOptimizerPEQVerificationFinalizationReceipt?
    @Published private(set) var lastErrorDescription: String?

    init(
        profileStore: any SpeakerOptimizerPEQProfileMutating,
        designOperation: @escaping SpeakerOptimizerGuidedPEQDesignOperation = {
            characterization, baseline in
            try SpeakerOptimizerClassificationAwareCandidateDesigner()
                .designPEQ(
                    characterization: characterization,
                    listeningBaseline: baseline
                )
        }
    ) {
        self.profileStore = profileStore
        self.designOperation = designOperation
    }

    var candidateBandCount: Int {
        plan?.candidate.sources.reduce(0) {
            $0 + $1.bands.count
        } ?? 0
    }

    var canApproveAndApply: Bool {
        state == .reviewReady
            && proposal?.canApply == true
            && profileStore.speakerOptimizerLifecycleState == .idle
    }

    var canRollback: Bool {
        applyReceipt != nil
            && state != .rolledBack
            && profileStore.speakerOptimizerLifecycleState == .idle
    }

    func prepareReview(
        baseline: SpeakerOptimizerMeasurementSet,
        characterization:
            SpeakerOptimizerCharacterizationMeasurementSet
    ) throws {
        guard applyReceipt == nil || state == .rolledBack else {
            throw SpeakerOptimizerGuidedPEQError
                .activeDeploymentRequiresResolution
        }
        guard let profile =
                profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerPEQApplyTransactionError
                .selectedProfileRequired
        }

        do {
            let freshPlan = try designOperation(
                characterization,
                baseline
            )
            let freshProposal = try planner.proposal(
                profile: profile,
                plan: freshPlan
            )
            plan = freshPlan
            proposal = freshProposal
            approval = nil
            applyReceipt = nil
            verificationReport = nil
            rollbackReceipt = nil
            verificationFinalizationReceipt = nil
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
        guard let plan, let proposal else {
            throw SpeakerOptimizerGuidedPEQError.reviewRequired
        }
        do {
            let freshApproval = try planner.makeExplicitApproval(
                proposal: proposal,
                approvedAt: approvedAt,
                userInitiated: userInitiated
            )
            let receipt = try transaction.apply(
                profileStore: profileStore,
                plan: plan,
                proposal: proposal,
                approval: freshApproval,
                appliedAt: appliedAt
            )
            approval = freshApproval
            applyReceipt = receipt
            verificationReport = nil
            rollbackReceipt = nil
            verificationFinalizationReceipt = nil
            state = .appliedPendingVerification
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func recordVerification(
        _ report: SpeakerOptimizerPostApplyVerificationReport
    ) throws {
        guard let receipt = applyReceipt else {
            throw SpeakerOptimizerGuidedPEQError.applyRequired
        }
        guard report.applyReceiptID == receipt.id,
              report.baselineMeasurementSetID
                == receipt.baselineMeasurementSetID,
              report.playbackSystemID == receipt.playbackSystemID,
              report.routingSignature == receipt.routingSignature else {
            throw SpeakerOptimizerGuidedPEQError
                .verificationReceiptMismatch
        }
        verificationReport = report
        if report.accepted {
            do {
                let finalized = try transaction.finalizeVerified(
                    report,
                    receipt: receipt,
                    profileStore: profileStore
                )
                verificationFinalizationReceipt = finalized
                rollbackReceipt = nil
                state = .measuredAccepted
                lastErrorDescription = nil
            } catch {
                state = .failed
                lastErrorDescription = error.localizedDescription
                throw error
            }
        } else {
            state = .measuredRejected
            do {
                let rolledBack = try transaction.rollback(
                    receipt,
                    profileStore: profileStore
                )
                rollbackReceipt = rolledBack
                verificationFinalizationReceipt = nil
                state = .rolledBack
                lastErrorDescription = nil
            } catch {
                lastErrorDescription = error.localizedDescription
                throw error
            }
        }
    }

    func rollback(rolledBackAt: Date = Date()) throws {
        guard let receipt = applyReceipt else {
            throw SpeakerOptimizerGuidedPEQError.applyRequired
        }
        do {
            let result = try transaction.rollback(
                receipt,
                profileStore: profileStore,
                rolledBackAt: rolledBackAt
            )
            rollbackReceipt = result
            state = .rolledBack
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }
}

enum SpeakerOptimizerGuidedFIRState:
    String, Equatable, Sendable {
    case idle
    case reviewReady
    case appliedPendingVerification
    case measuredAccepted
    case measuredRejected
    case rolledBack
    case failed
}

enum SpeakerOptimizerGuidedFIRError:
    Error, Equatable, LocalizedError {
    case reviewRequired
    case applyRequired
    case activeDeploymentRequiresResolution
    case verificationReceiptMismatch
    case avSyncApprovalRequired

    var errorDescription: String? {
        switch self {
        case .reviewRequired:
            return "Generate and review a Speaker Optimizer FIR proposal first."
        case .applyRequired:
            return "Apply the reviewed Speaker Optimizer FIR before starting measured verification."
        case .activeDeploymentRequiresResolution:
            return "The current Speaker Optimizer FIR deployment must be verified or rolled back before generating another proposal."
        case .verificationReceiptMismatch:
            return "The measured verification report does not belong to the current Speaker Optimizer FIR Apply receipt."
        case .avSyncApprovalRequired:
            return "Choose an A/V synchronization context that can support the reported FIR audio-path latency before Apply."
        }
    }
}

typealias SpeakerOptimizerGuidedFIRDesignOperation = (
    SpeakerOptimizerCharacterizationMeasurementSet,
    SpeakerOptimizerMeasurementSet
) throws -> SpeakerOptimizerClassificationAwareFIRPlan

/// UI-facing PR107 FIR commissioning state machine.
///
/// Review always carries exact headroom/latency disclosure. Synchronized-video
/// Apply is blocked unless the caller declares an external video-delay path with
/// enough capacity; Notch Sixty itself does not claim to delay system video.
@MainActor
final class SpeakerOptimizerGuidedFIRController: ObservableObject {
    private let profileStore: any SpeakerOptimizerFIRProfileMutating
    private let designOperation: SpeakerOptimizerGuidedFIRDesignOperation
    private let planner = SpeakerOptimizerCommissioningPlanner()
    private let transaction = SpeakerOptimizerFIRApplyTransaction()
    private let latencyPlanner = SpeakerOptimizerFIRLatencyPlanner()
    private let avPolicy = SpeakerOptimizerFIRAVSyncPolicy()

    @Published private(set) var state:
        SpeakerOptimizerGuidedFIRState = .idle
    @Published private(set) var plan:
        SpeakerOptimizerClassificationAwareFIRPlan?
    @Published private(set) var proposal:
        SpeakerOptimizerCommissioningProposal?
    @Published private(set) var approval:
        SpeakerOptimizerApplyApproval?
    @Published private(set) var applyReceipt:
        SpeakerOptimizerFIRApplyReceipt?
    @Published private(set) var verificationReport:
        SpeakerOptimizerPostApplyVerificationReport?
    @Published private(set) var rollbackReceipt:
        SpeakerOptimizerFIRRollbackReceipt?
    @Published private(set) var verificationFinalizationReceipt:
        SpeakerOptimizerFIRVerificationFinalizationReceipt?
    @Published private(set) var latencyPlan:
        SpeakerOptimizerFIRLatencyPlan?
    @Published private(set) var avSyncDecision:
        SpeakerOptimizerFIRAVSyncDecision?
    @Published private(set) var lastErrorDescription: String?

    init(
        profileStore: any SpeakerOptimizerFIRProfileMutating,
        designOperation:
            @escaping SpeakerOptimizerGuidedFIRDesignOperation = {
                characterization, baseline in
                try SpeakerOptimizerClassificationAwareCandidateDesigner()
                    .designFIR(
                        characterization: characterization,
                        listeningBaseline: baseline
                    )
            }
    ) {
        self.profileStore = profileStore
        self.designOperation = designOperation
    }

    var candidateTapCount: Int {
        plan?.candidate.requestedTapCount ?? 0
    }

    var requiredHeadroomDB: Double {
        plan?.candidate.sources
            .filter { $0.acceptedForPreview }
            .map(\.recommendedHeadroomDB)
            .max() ?? 0
    }

    var addedFIRLatencyMilliseconds: Double {
        avSyncDecision?.incrementalFIRLatencyMilliseconds ?? 0
    }

    var programPathLatencyMilliseconds: Double {
        avSyncDecision?.requiredVideoDelayMilliseconds ?? 0
    }

    var canApproveAndApply: Bool {
        state == .reviewReady
            && proposal?.canApply == true
            && avSyncDecision?.canUseFIRForContext == true
            && profileStore.speakerOptimizerLifecycleState == .idle
    }

    var canRollback: Bool {
        applyReceipt != nil
            && state != .rolledBack
            && profileStore.speakerOptimizerLifecycleState == .idle
    }

    func prepareReview(
        baseline: SpeakerOptimizerMeasurementSet,
        characterization:
            SpeakerOptimizerCharacterizationMeasurementSet,
        avSyncContext: SpeakerOptimizerFIRAVSyncContext
    ) throws {
        guard applyReceipt == nil || state == .rolledBack else {
            throw SpeakerOptimizerGuidedFIRError
                .activeDeploymentRequiresResolution
        }
        guard let profile =
                profileStore.speakerOptimizerSelectedSystemProfile else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileRequired
        }

        do {
            let freshPlan = try designOperation(
                characterization,
                baseline
            )
            let freshProposal = try planner.proposal(
                profile: profile,
                plan: freshPlan
            )
            let latency: SpeakerOptimizerFIRLatencyPlan?
            let av: SpeakerOptimizerFIRAVSyncDecision?
            if freshProposal.canApply,
               let output =
                    profile.state.outputDeviceProfile {
                let roles = freshPlan.candidate.sources.compactMap {
                    candidate -> OutputProgramRole? in
                    guard candidate.acceptedForPreview,
                          !candidate.taps.isEmpty,
                          case .speaker(let role) =
                            candidate.source else {
                        return nil
                    }
                    return role
                }
                let planned = try latencyPlanner.plan(
                    profile: output,
                    bassManagementEnabled:
                        profile.state.bassManagement.enabled,
                    sampleRate:
                        freshPlan.candidate.sampleRate,
                    tapCount:
                        freshPlan.candidate.requestedTapCount,
                    declaredGroupDelayFrames:
                        UInt32(
                            freshPlan.candidate
                                .declaredGroupDelayFrames
                        ),
                    correctedRoles: roles
                )
                latency = planned
                av = try avPolicy.assess(
                    plan: planned,
                    context: avSyncContext
                )
            } else {
                latency = nil
                av = nil
            }

            plan = freshPlan
            proposal = freshProposal
            approval = nil
            applyReceipt = nil
            verificationReport = nil
            rollbackReceipt = nil
            verificationFinalizationReceipt = nil
            latencyPlan = latency
            avSyncDecision = av
            state = .reviewReady
            lastErrorDescription = nil
        } catch {
            state = .failed
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func updateAVSyncContext(
        _ context: SpeakerOptimizerFIRAVSyncContext
    ) throws {
        guard let latencyPlan else {
            throw SpeakerOptimizerGuidedFIRError.reviewRequired
        }
        do {
            avSyncDecision = try avPolicy.assess(
                plan: latencyPlan,
                context: context
            )
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func approveAndApply(
        userInitiated: Bool,
        approvedAt: Date = Date(),
        appliedAt: Date = Date()
    ) throws {
        guard let plan, let proposal else {
            throw SpeakerOptimizerGuidedFIRError.reviewRequired
        }
        guard avSyncDecision?.canUseFIRForContext == true else {
            throw SpeakerOptimizerGuidedFIRError
                .avSyncApprovalRequired
        }
        do {
            let freshApproval = try planner.makeExplicitApproval(
                proposal: proposal,
                approvedAt: approvedAt,
                userInitiated: userInitiated
            )
            let receipt = try transaction.apply(
                profileStore: profileStore,
                plan: plan,
                proposal: proposal,
                approval: freshApproval,
                appliedAt: appliedAt
            )
            approval = freshApproval
            applyReceipt = receipt
            verificationReport = nil
            rollbackReceipt = nil
            verificationFinalizationReceipt = nil
            state = .appliedPendingVerification
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func recordVerification(
        _ report: SpeakerOptimizerPostApplyVerificationReport
    ) throws {
        guard let receipt = applyReceipt else {
            throw SpeakerOptimizerGuidedFIRError.applyRequired
        }
        guard report.applyReceiptID == receipt.id,
              report.baselineMeasurementSetID
                == receipt.baselineMeasurementSetID,
              report.playbackSystemID
                == receipt.playbackSystemID,
              report.routingSignature
                == receipt.routingSignature else {
            throw SpeakerOptimizerGuidedFIRError
                .verificationReceiptMismatch
        }
        verificationReport = report
        if report.accepted {
            do {
                let finalized = try transaction.finalizeVerified(
                    report,
                    receipt: receipt,
                    profileStore: profileStore
                )
                verificationFinalizationReceipt = finalized
                rollbackReceipt = nil
                state = .measuredAccepted
                lastErrorDescription = nil
            } catch {
                state = .failed
                lastErrorDescription = error.localizedDescription
                throw error
            }
        } else {
            state = .measuredRejected
            do {
                let rolledBack = try transaction.rollback(
                    receipt,
                    profileStore: profileStore
                )
                rollbackReceipt = rolledBack
                verificationFinalizationReceipt = nil
                state = .rolledBack
                lastErrorDescription = nil
            } catch {
                lastErrorDescription = error.localizedDescription
                throw error
            }
        }
    }

    func rollback(
        rolledBackAt: Date = Date()
    ) throws {
        guard let receipt = applyReceipt else {
            throw SpeakerOptimizerGuidedFIRError.applyRequired
        }
        do {
            let result = try transaction.rollback(
                receipt,
                profileStore: profileStore,
                rolledBackAt: rolledBackAt
            )
            rollbackReceipt = result
            state = .rolledBack
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }
}

struct SpeakerOptimizerVerificationCampaignArchive:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var applyReceiptID: UUID
    var baselineMeasurementSetID: UUID
    var measurementSet: SpeakerOptimizerMeasurementSet
}

enum SpeakerOptimizerVerificationSessionError:
    Error, Equatable, LocalizedError {
    case invalidArchive
    case baselineRequired
    case baselineUnqualified
    case appliedStateRequired
    case microphoneIdentityMismatch
    case outputRequired
    case sessionRequired
    case measurementAlreadyActive
    case measurementNotActive
    case playbackMustBeIdle(AudioLifecycleState)
    case transportBlocked(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "Stored Speaker Optimizer verification evidence does not match this Apply receipt and baseline."
        case .baselineRequired:
            return "An optimizer-ready baseline bound to this Apply receipt is required."
        case .baselineUnqualified:
            return "The original Speaker Optimizer baseline is no longer optimizer-ready."
        case .appliedStateRequired:
            return "The selected Playback System no longer exactly matches the provisional Speaker Optimizer Apply state."
        case .microphoneIdentityMismatch:
            return "Use the same calibrated measurement microphone and input channel as the baseline."
        case .outputRequired:
            return "Select the commissioned Playback System output before verification."
        case .sessionRequired:
            return "Start or resume post-Apply verification first."
        case .measurementAlreadyActive:
            return "A post-Apply verification measurement is already active."
        case .measurementNotActive:
            return "No post-Apply verification measurement is active."
        case .playbackMustBeIdle(let state):
            return "Stop normal DSP playback before verification. The engine is currently \(state.rawValue)."
        case .transportBlocked(let reason):
            return "Post-Apply verification is blocked: \(reason)"
        }
    }
}

struct SpeakerOptimizerVerificationCampaignStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func url(for applyReceiptID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(applyReceiptID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ archive: SpeakerOptimizerVerificationCampaignArchive) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(archive).write(
            to: url(for: archive.applyReceiptID),
            options: .atomic
        )
    }

    func load(
        applyReceiptID: UUID
    ) throws -> SpeakerOptimizerVerificationCampaignArchive? {
        let path = url(for: applyReceiptID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            SpeakerOptimizerVerificationCampaignArchive.self,
            from: Data(contentsOf: path)
        )
    }

    func delete(applyReceiptID: UUID) throws {
        let path = url(for: applyReceiptID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }
        try FileManager.default.removeItem(at: path)
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent(
                "Speaker Optimizer Verification",
                isDirectory: true
            )
    }
}

struct SpeakerOptimizerVerificationSessionFactory: Sendable {
    func fresh(
        baseline: SpeakerOptimizerMeasurementSet,
        receipt: SpeakerOptimizerPEQApplyReceipt,
        createdAt: Date = Date()
    ) throws -> SpeakerOptimizerVerificationCampaignArchive {
        guard baseline.role == .baseline,
              baseline.id == receipt.baselineMeasurementSetID,
              baseline.playbackSystemID == receipt.playbackSystemID,
              baseline.routingSignature == receipt.routingSignature,
              abs(baseline.sampleRate - receipt.deployment.sampleRate) < 0.5
        else {
            throw SpeakerOptimizerVerificationSessionError.baselineRequired
        }
        let set = SpeakerOptimizerMeasurementSet(
            role: .verification,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            microphone: baseline.microphone,
            sampleRate: baseline.sampleRate,
            positions: baseline.positions,
            plannedSources: baseline.plannedSources,
            captures: [],
            createdAt: createdAt,
            modifiedAt: createdAt
        )
        try set.validatePersistenceStructure()
        return SpeakerOptimizerVerificationCampaignArchive(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID: baseline.id,
            measurementSet: set
        )
    }

    func validate(
        _ archive: SpeakerOptimizerVerificationCampaignArchive,
        baseline: SpeakerOptimizerMeasurementSet,
        receipt: SpeakerOptimizerPEQApplyReceipt
    ) throws {
        let set = archive.measurementSet
        guard archive.schemaVersion
                == SpeakerOptimizerVerificationCampaignArchive
                    .currentSchemaVersion,
              archive.applyReceiptID == receipt.id,
              archive.baselineMeasurementSetID == baseline.id,
              set.role == .verification,
              set.id != baseline.id,
              set.playbackSystemID == baseline.playbackSystemID,
              set.routingSignature == baseline.routingSignature,
              set.microphone == baseline.microphone,
              abs(set.sampleRate - baseline.sampleRate) < 0.5,
              set.positions == baseline.positions,
              set.plannedSources == baseline.plannedSources else {
            throw SpeakerOptimizerVerificationSessionError.invalidArchive
        }
        try set.validatePersistenceStructure()
        let baselineCaptureIDs = Set(baseline.captures.map(\.id))
        guard set.captures.allSatisfy({
            $0.capturedAt > receipt.appliedAt
                && !baselineCaptureIDs.contains($0.id)
        }) else {
            throw SpeakerOptimizerVerificationSessionError.invalidArchive
        }
    }


    func fresh(
        baseline: SpeakerOptimizerMeasurementSet,
        receipt: SpeakerOptimizerFIRApplyReceipt,
        createdAt: Date = Date()
    ) throws -> SpeakerOptimizerVerificationCampaignArchive {
        guard baseline.role == .baseline,
              baseline.id == receipt.baselineMeasurementSetID,
              baseline.playbackSystemID == receipt.playbackSystemID,
              baseline.routingSignature == receipt.routingSignature,
              abs(
                baseline.sampleRate
                    - receipt.deployment.sampleRate
              ) < 0.5 else {
            throw SpeakerOptimizerVerificationSessionError
                .baselineRequired
        }
        let set = SpeakerOptimizerMeasurementSet(
            role: .verification,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            microphone: baseline.microphone,
            sampleRate: baseline.sampleRate,
            positions: baseline.positions,
            plannedSources: baseline.plannedSources,
            captures: [],
            createdAt: createdAt,
            modifiedAt: createdAt
        )
        try set.validatePersistenceStructure()
        return SpeakerOptimizerVerificationCampaignArchive(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID: baseline.id,
            measurementSet: set
        )
    }

    func validate(
        _ archive: SpeakerOptimizerVerificationCampaignArchive,
        baseline: SpeakerOptimizerMeasurementSet,
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) throws {
        let set = archive.measurementSet
        guard archive.schemaVersion
                == SpeakerOptimizerVerificationCampaignArchive
                    .currentSchemaVersion,
              archive.applyReceiptID == receipt.id,
              archive.baselineMeasurementSetID == baseline.id,
              set.role == .verification,
              set.id != baseline.id,
              set.playbackSystemID
                == baseline.playbackSystemID,
              set.routingSignature
                == baseline.routingSignature,
              set.microphone == baseline.microphone,
              abs(
                set.sampleRate - baseline.sampleRate
              ) < 0.5,
              set.positions == baseline.positions,
              set.plannedSources
                == baseline.plannedSources else {
            throw SpeakerOptimizerVerificationSessionError
                .invalidArchive
        }
        try set.validatePersistenceStructure()
        let baselineCaptureIDs =
            Set(baseline.captures.map(\.id))
        guard set.captures.allSatisfy({
            $0.capturedAt > receipt.appliedAt
                && !baselineCaptureIDs.contains($0.id)
        }) else {
            throw SpeakerOptimizerVerificationSessionError
                .invalidArchive
        }
    }
}

/// Guided fresh-capture controller for the provisional PEQ Apply receipt.
@MainActor
final class SpeakerOptimizerVerificationController: ObservableObject {
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    private let store: SpeakerOptimizerVerificationCampaignStore
    private let transportFactory: MultichannelCalibrationTransportFactory
    private let analysisOperation: MultichannelCalibrationAnalysisOperation
    private let transportPlanner =
        SpeakerOptimizerMeasurementTransportPlanner()
    private let evaluator = SpeakerOptimizerMeasurementEvidenceEvaluator()
    private let verifier = SpeakerOptimizerPostApplyVerifier()
    private let sweepGenerator = RoomCorrectionSweepGenerator()
    private let orchestrator =
        SpeakerOptimizerMeasurementSessionOrchestrator.standard
    private let sessionFactory =
        SpeakerOptimizerVerificationSessionFactory()

    private var baseline: SpeakerOptimizerMeasurementSet?
    private var plan: SpeakerOptimizerClassificationAwarePEQPlan?
    private var receipt: SpeakerOptimizerPEQApplyReceipt?
    private var activeTransport:
        (any MultichannelCalibrationTransporting)?
    private var activeProgram: RoomCorrectionSweepProgram?
    private var activeStep: SpeakerOptimizerMeasurementSessionStep?
    private var analysisGeneration: UInt64 = 0

    @Published private(set) var state:
        SpeakerOptimizerMeasurementControllerState = .idle
    @Published private(set) var measurementSet:
        SpeakerOptimizerMeasurementSet?
    @Published private(set) var evidenceReport:
        SpeakerOptimizerMeasurementEvidenceReport?
    @Published private(set) var verificationReport:
        SpeakerOptimizerPostApplyVerificationReport?
    @Published private(set) var activeTransportPlan:
        SpeakerOptimizerMeasurementTransportPlan?
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        store: SpeakerOptimizerVerificationCampaignStore =
            SpeakerOptimizerVerificationCampaignStore(),
        transportFactory:
            @escaping MultichannelCalibrationTransportFactory = {
                routePlan, outputs, input, inputChannel, program,
                physicalOutput in
                try MultichannelCalibrationTransport(
                    routePlan: routePlan,
                    availableOutputs: outputs,
                    input: input,
                    inputChannelIndex: inputChannel,
                    program: program,
                    physicalOutputChannelIndex: physicalOutput
                )
            },
        analysisOperation:
            @escaping MultichannelCalibrationAnalysisOperation = {
                capture, program, microphoneCalibration in
                try await Task.detached(priority: .userInitiated) {
                    try RoomCorrectionMeasurementAnalyzer()
                        .analyzeSingleChannel(
                            rawCapture: capture.samples,
                            program: program,
                            microphoneCalibration:
                                microphoneCalibration
                        )
                }.value
            }
    ) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.store = store
        self.transportFactory = transportFactory
        self.analysisOperation = analysisOperation
    }

    var progress: SpeakerOptimizerMeasurementSessionProgress? {
        guard let measurementSet else { return nil }
        return try? orchestrator.progress(for: measurementSet)
    }

    var activeOrNextStep: SpeakerOptimizerMeasurementSessionStep? {
        activeStep ?? {
            guard let measurementSet else { return nil }
            return try? orchestrator.nextPendingStep(
                for: measurementSet
            )
        }()
    }

    var activeMeasurementProgress: Double {
        guard let snapshot = activeTransport?.snapshot(),
              snapshot.totalFrameCount > 0 else {
            return 0
        }
        return min(
            max(
                Double(snapshot.frameCursor)
                    / Double(snapshot.totalFrameCount),
                0
            ),
            1
        )
    }

    var canBeginMeasurement: Bool {
        guard state == .ready || state == .reviewing,
              let measurementSet,
              (try? orchestrator.nextPendingStep(
                  for: measurementSet
              )) != nil else {
            return false
        }
        return engine.lifecycleState == .idle
            && microphone.permissionStatus == .authorized
            && microphone.selectedInputDevice != nil
            && engine.selectedOutputDevice != nil
            && activeTransport == nil
    }

    func startOrResume(
        baseline: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        receipt: SpeakerOptimizerPEQApplyReceipt
    ) throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerVerificationSessionError
                .measurementAlreadyActive
        }
        let baselineEvidence = try evaluator.evaluate(baseline)
        guard baselineEvidence.optimizerReady else {
            throw SpeakerOptimizerVerificationSessionError
                .baselineUnqualified
        }
        guard let profile = profiles.selectedSystemProfile,
              profile.id == receipt.playbackSystemID,
              profile.state == receipt.expectedAppliedState,
              profile.state.outputDeviceProfile?
                .speakerOptimizerPEQ == receipt.deployment else {
            throw SpeakerOptimizerVerificationSessionError
                .appliedStateRequired
        }
        guard let output = engine.selectedOutputDevice else {
            throw SpeakerOptimizerVerificationSessionError.outputRequired
        }
        guard microphone.permissionStatus == .authorized,
              let input = microphone.selectedInputDevice else {
            throw SpeakerOptimizerVerificationSessionError
                .microphoneIdentityMismatch
        }
        let currentMic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: input.uid,
            inputChannelIndex: microphone.selectedInputChannelIndex,
            calibrationFingerprint:
                microphone.microphoneCalibration?.sourceName
        )
        guard currentMic == baseline.microphone,
              abs(output.nominalSampleRate - baseline.sampleRate) < 0.5
        else {
            throw SpeakerOptimizerVerificationSessionError
                .microphoneIdentityMismatch
        }

        let archive: SpeakerOptimizerVerificationCampaignArchive
        if let stored = try store.load(applyReceiptID: receipt.id) {
            try sessionFactory.validate(
                stored,
                baseline: baseline,
                receipt: receipt
            )
            archive = stored
        } else {
            archive = try sessionFactory.fresh(
                baseline: baseline,
                receipt: receipt
            )
            try store.save(archive)
        }

        self.baseline = baseline
        self.plan = plan
        self.receipt = receipt
        measurementSet = archive.measurementSet
        try refreshDerivedState()
        lastErrorDescription = nil
    }

    func beginNextMeasurement() throws {
        guard activeTransport == nil else {
            throw SpeakerOptimizerVerificationSessionError
                .measurementAlreadyActive
        }
        guard engine.lifecycleState == .idle else {
            throw SpeakerOptimizerVerificationSessionError
                .playbackMustBeIdle(engine.lifecycleState)
        }
        guard let receipt,
              let profile = profiles.selectedSystemProfile,
              profile.id == receipt.playbackSystemID,
              profile.state == receipt.expectedAppliedState,
              let systemProfile = profiles.selectedSystemProfile,
              let outputProfile =
                systemProfile.state.outputDeviceProfile,
              outputProfile.enabled else {
            throw SpeakerOptimizerVerificationSessionError
                .appliedStateRequired
        }
        guard microphone.permissionStatus == .authorized,
              let input = microphone.selectedInputDevice,
              let output = engine.selectedOutputDevice,
              let selectedOutputUID =
                engine.routeConfiguration.selectedOutputUID else {
            throw SpeakerOptimizerVerificationSessionError.outputRequired
        }
        guard let set = measurementSet,
              let step = try orchestrator.nextPendingStep(for: set) else {
            throw SpeakerOptimizerVerificationSessionError.sessionRequired
        }

        let routePlan = try outputProfile.makeLivePlan(
            availableDevices: engine.outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: selectedOutputUID,
            bassManagementEnabled:
                systemProfile.state.bassManagement.enabled
        )
        let transportPlan = transportPlanner.plan(
            target: .acousticSource(step.source),
            routePlan: routePlan,
            multiOutputRouting: systemProfile.state.outputRouting,
            speakerDriverProcessing:
                systemProfile.state.speakerDriverProcessing
        )
        activeTransportPlan = transportPlan
        guard transportPlan.canStartMeasurement,
              let physicalOutput =
                transportPlan.physicalOutputChannelIndex else {
            state = .blocked
            let reason = transportPlan.blockReason?.message
                ?? "the measurement transport safety contract was not satisfied"
            let error =
                SpeakerOptimizerVerificationSessionError
                    .transportBlocked(reason)
            lastErrorDescription = error.localizedDescription
            throw error
        }

        let settings = RoomCorrectionSweepSettings(
            sampleRate: output.nominalSampleRate,
            startFrequencyHz: microphone.sweepStartFrequencyHz,
            endFrequencyHz: microphone.sweepEndFrequencyHz,
            durationSeconds: microphone.sweepDurationSeconds,
            levelDBFS: microphone.sweepLevelDBFS,
            leadInSeconds: microphone.sweepLeadInSeconds,
            tailSeconds: microphone.sweepTailSeconds,
            fadeSeconds: microphone.sweepFadeSeconds
        )
        let program = try sweepGenerator.makeProgram(settings: settings)
        let transport = try transportFactory(
            routePlan,
            engine.outputDevices,
            input,
            microphone.selectedInputChannelIndex,
            program,
            physicalOutput
        )
        analysisGeneration &+= 1
        activeTransport = transport
        activeProgram = program
        activeStep = step
        do {
            try transport.start()
            state = .measuring
            lastErrorDescription = nil
        } catch {
            transport.cancel()
            clearActive()
            recordFailure(error)
            throw error
        }
    }

    @discardableResult
    func finishMeasurementIfComplete() async throws -> Bool {
        guard state == .measuring,
              let transport = activeTransport else {
            return false
        }
        guard transport.snapshot()?.complete == true else {
            return false
        }
        let capture: MultichannelCalibrationCapture
        do {
            capture = try transport.finishAndMaterialize()
        } catch {
            clearActive()
            recordFailure(error)
            throw error
        }
        activeTransport = nil

        guard let program = activeProgram,
              let step = activeStep,
              var set = measurementSet else {
            clearActive()
            throw SpeakerOptimizerVerificationSessionError
                .measurementNotActive
        }
        activeProgram = nil
        state = .analyzing
        let generation = analysisGeneration

        do {
            let analyzed = try await analysisOperation(
                capture,
                program,
                microphone.microphoneCalibration
            )
            guard generation == analysisGeneration,
                  state == .analyzing else {
                return false
            }
            let measurement = MultichannelCalibrationMeasurement(
                seatID: step.position.id,
                source: step.source,
                sampleRate: program.sampleRate,
                channel: analyzed
            )
            let compact = try SpeakerOptimizerMeasurementCapture(
                compacting: measurement,
                playbackSystemID: set.playbackSystemID,
                routingSignature: set.routingSignature,
                microphone: set.microphone
            )
            set = try orchestrator.appending(
                compact,
                to: set,
                for: step
            )
            measurementSet = set
            try persistCurrent()
            activeStep = nil
            activeTransportPlan = nil
            try refreshDerivedState()
            lastErrorDescription = nil
            return true
        } catch {
            activeStep = nil
            activeTransportPlan = nil
            recordFailure(error)
            throw error
        }
    }

    func cancelMeasurement() {
        analysisGeneration &+= 1
        activeTransport?.cancel()
        clearActive()
        do {
            try refreshDerivedState()
        } catch {
            recordFailure(error)
        }
    }

    func resetVerification() throws {
        guard activeTransport == nil,
              let baseline,
              let receipt else {
            throw SpeakerOptimizerVerificationSessionError.sessionRequired
        }
        try store.delete(applyReceiptID: receipt.id)
        let fresh = try sessionFactory.fresh(
            baseline: baseline,
            receipt: receipt
        )
        try store.save(fresh)
        measurementSet = fresh.measurementSet
        verificationReport = nil
        try refreshDerivedState()
    }

    private func refreshDerivedState() throws {
        guard let set = measurementSet else {
            evidenceReport = nil
            verificationReport = nil
            state = .idle
            return
        }
        evidenceReport = try evaluator.evaluate(set)
        let progress = try orchestrator.progress(for: set)
        if progress.complete {
            state = .reviewing
            if evidenceReport?.optimizerReady == true,
               let baseline, let plan, let receipt {
                verificationReport = try verifier.verify(
                    baseline: baseline,
                    verification: set,
                    plan: plan,
                    receipt: receipt
                )
            } else {
                verificationReport = nil
            }
        } else {
            verificationReport = nil
            state = .ready
        }
    }

    private func persistCurrent() throws {
        guard let measurementSet, let receipt, let baseline else {
            throw SpeakerOptimizerVerificationSessionError.sessionRequired
        }
        let archive = SpeakerOptimizerVerificationCampaignArchive(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID: baseline.id,
            measurementSet: measurementSet
        )
        try sessionFactory.validate(
            archive,
            baseline: baseline,
            receipt: receipt
        )
        try store.save(archive)
    }

    private func clearActive() {
        activeTransport = nil
        activeProgram = nil
        activeStep = nil
        activeTransportPlan = nil
    }

    private func recordFailure(_ error: Error) {
        activeTransport?.cancel()
        clearActive()
        state = .failed
        lastErrorDescription = error.localizedDescription
    }
}
