import Foundation

enum SpeakerOptimizerCommissioningCandidateKind: String, Codable, Equatable, Sendable {
    case peq
    case linearPhaseFIR
}

enum SpeakerOptimizerDeploymentStageStatus: String, Codable, Equatable, Sendable {
    case availableDedicatedSpeakerOptimizerPEQStage
    case availableDedicatedSpeakerOptimizerFIRStage
    case blockedPEQCandidateNotRepresentable
    case blockedFIRCandidateNotRepresentable
    /// Retained as a fail-closed legacy checkpoint value; new PEQ proposals use
    /// the separately owned stage introduced in PR105 Slice 7.
    case blockedDedicatedSpeakerOptimizerPEQStageUnavailable
    /// There is currently no dedicated per-speaker FIR stage in PlaybackSystemState.
    case blockedDedicatedSpeakerOptimizerFIRStageUnavailable

    var canInstall: Bool {
        self == .availableDedicatedSpeakerOptimizerPEQStage
            || self == .availableDedicatedSpeakerOptimizerFIRStage
    }

    var explanation: String {
        switch self {
        case .availableDedicatedSpeakerOptimizerPEQStage:
            return "A separately owned cut-only Speaker Optimizer PEQ stage is available and compiles after ordinary Speaker Calibration sections."
        case .availableDedicatedSpeakerOptimizerFIRStage:
            return "A separately owned Speaker Optimizer FIR stage is available with explicit per-role taps, automatic headroom reserve, and exact latency/coherence accounting."
        case .blockedPEQCandidateNotRepresentable:
            return "The PEQ candidate cannot fit the bounded cut-only optimizer stage without violating band, source, sample-rate, or aggregate lane-section limits."
        case .blockedFIRCandidateNotRepresentable:
            return "The FIR candidate cannot fit the dedicated optimizer stage without violating source, tap, linear-phase, sample-rate, headroom, or latency limits."
        case .blockedDedicatedSpeakerOptimizerPEQStageUnavailable:
            return "A separately owned Speaker Optimizer PEQ stage is required; existing Speaker Calibration EQ bands must not be overwritten or double-used."
        case .blockedDedicatedSpeakerOptimizerFIRStageUnavailable:
            return "A dedicated per-speaker FIR stage with declared latency/headroom ownership is required before optimizer FIR taps can be installed."
        }
    }
}

struct SpeakerOptimizerCommissioningSource: Codable, Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var candidateKind: SpeakerOptimizerCommissioningCandidateKind
    var candidateFingerprint: String
    var stageStatus: SpeakerOptimizerDeploymentStageStatus
    var modeledCorrectionPresent: Bool
}

struct SpeakerOptimizerRollbackSnapshot: Codable, Equatable, Sendable {
    var playbackSystemID: UUID
    var routingSignature: String
    var playbackSystemState: PlaybackSystemState
}

struct SpeakerOptimizerCommissioningProposal: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var playbackSystemID: UUID
    var baselineMeasurementSetID: UUID
    var characterizationMeasurementSetID: UUID
    var routingSignature: String
    var sampleRate: Double
    var sources: [SpeakerOptimizerCommissioningSource]
    var rollbackSnapshot: SpeakerOptimizerRollbackSnapshot

    var approvalRequired: Bool { true }
    var rollbackRequired: Bool { true }
    var isMeasuredVerification: Bool { false }
    var canApply: Bool {
        !sources.isEmpty
            && sources.allSatisfy {
                $0.modeledCorrectionPresent && $0.stageStatus.canInstall
            }
    }
}

struct SpeakerOptimizerApplyApproval: Codable, Equatable, Sendable {
    var proposalID: UUID
    var aggregateCandidateFingerprint: String
    var approvedAt: Date
    /// Approval objects may only be minted from an explicit UI/user action.
    /// This field is intentionally required rather than defaulted.
    var userInitiated: Bool
}

enum SpeakerOptimizerCommissioningError: Error, Equatable, LocalizedError {
    case profileIdentityMismatch
    case candidateIdentityMismatch
    case candidateNotPreviewOnly
    case candidateHasNoModeledCorrection
    case invalidApproval
    case deploymentStageUnavailable

    var errorDescription: String? {
        switch self {
        case .profileIdentityMismatch:
            return "Speaker Optimizer commissioning snapshot does not match the selected Playback System or routing."
        case .candidateIdentityMismatch:
            return "Speaker Optimizer candidate identity does not match its measured classification evidence."
        case .candidateNotPreviewOnly:
            return "Only a preview-only, non-deployed Speaker Optimizer candidate can enter commissioning review."
        case .candidateHasNoModeledCorrection:
            return "Speaker Optimizer commissioning requires at least one modeled correction candidate."
        case .invalidApproval:
            return "Speaker Optimizer Apply approval is missing, stale, or not explicitly user-initiated."
        case .deploymentStageUnavailable:
            return "Speaker Optimizer Apply remains blocked until a separately owned deployment stage exists for every selected candidate."
        }
    }
}

/// Creates immutable review/rollback metadata. This type DOES NOT mutate
/// ProductProfileController, AudioIOEngine, routing, calibration or DSP.
struct SpeakerOptimizerCommissioningPlanner: Sendable {
    func proposal(
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        createdAt: Date = Date()
    ) throws -> SpeakerOptimizerCommissioningProposal {
        guard plan.previewOnly, !plan.canDeploy,
              plan.candidate.previewOnly,
              !plan.candidate.isMeasuredVerification else {
            throw SpeakerOptimizerCommissioningError.candidateNotPreviewOnly
        }
        try validateIdentity(
            profile: profile,
            classification: plan.classification,
            baselineID: plan.candidate.baselineMeasurementSetID,
            playbackSystemID: plan.candidate.playbackSystemID,
            routingSignature: plan.candidate.routingSignature,
            sampleRate: plan.candidate.sampleRate
        )

        let sources = plan.candidate.sources.compactMap { candidate
            -> SpeakerOptimizerCommissioningSource? in
            guard !candidate.bands.isEmpty else { return nil }
            return SpeakerOptimizerCommissioningSource(
                source: candidate.source,
                candidateKind: .peq,
                candidateFingerprint: fingerprintPEQ(candidate),
                stageStatus: peqStageStatus(
                    candidate,
                    profile: profile,
                    sampleRate: plan.candidate.sampleRate
                ),
                modeledCorrectionPresent: true
            )
        }
        guard !sources.isEmpty else {
            throw SpeakerOptimizerCommissioningError
                .candidateHasNoModeledCorrection
        }
        return makeProposal(
            profile: profile,
            classification: plan.classification,
            baselineID: plan.candidate.baselineMeasurementSetID,
            routingSignature: plan.candidate.routingSignature,
            sampleRate: plan.candidate.sampleRate,
            sources: sources,
            createdAt: createdAt
        )
    }

    func proposal(
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        createdAt: Date = Date()
    ) throws -> SpeakerOptimizerCommissioningProposal {
        guard plan.previewOnly, !plan.canDeploy,
              plan.candidate.previewOnly, !plan.candidate.canDeploy,
              !plan.candidate.isMeasuredVerification else {
            throw SpeakerOptimizerCommissioningError.candidateNotPreviewOnly
        }
        try validateIdentity(
            profile: profile,
            classification: plan.classification,
            baselineID: plan.candidate.baselineMeasurementSetID,
            playbackSystemID: plan.candidate.playbackSystemID,
            routingSignature: plan.candidate.routingSignature,
            sampleRate: plan.candidate.sampleRate
        )

        let sources = plan.candidate.sources.compactMap { candidate
            -> SpeakerOptimizerCommissioningSource? in
            guard candidate.acceptedForPreview, !candidate.taps.isEmpty else {
                return nil
            }
            return SpeakerOptimizerCommissioningSource(
                source: candidate.source,
                candidateKind: .linearPhaseFIR,
                candidateFingerprint: fingerprintFIR(candidate),
                stageStatus: firStageStatus(
                    candidate,
                    plan: plan,
                    profile: profile
                ),
                modeledCorrectionPresent: true
            )
        }
        guard !sources.isEmpty else {
            throw SpeakerOptimizerCommissioningError
                .candidateHasNoModeledCorrection
        }
        return makeProposal(
            profile: profile,
            classification: plan.classification,
            baselineID: plan.candidate.baselineMeasurementSetID,
            routingSignature: plan.candidate.routingSignature,
            sampleRate: plan.candidate.sampleRate,
            sources: sources,
            createdAt: createdAt
        )
    }

    func aggregateCandidateFingerprint(
        _ proposal: SpeakerOptimizerCommissioningProposal
    ) -> String {
        var digest = StableDigest64()
        digest.add("proposal-candidates-v1")
        digest.add(proposal.playbackSystemID.uuidString)
        digest.add(proposal.baselineMeasurementSetID.uuidString)
        digest.add(proposal.characterizationMeasurementSetID.uuidString)
        digest.add(proposal.routingSignature)
        for source in proposal.sources.sorted(by: {
            sourceKey($0.source) < sourceKey($1.source)
        }) {
            digest.add(sourceKey(source.source))
            digest.add(source.candidateKind.rawValue)
            digest.add(source.candidateFingerprint)
        }
        return digest.hex
    }

    func makeExplicitApproval(
        proposal: SpeakerOptimizerCommissioningProposal,
        approvedAt: Date = Date(),
        userInitiated: Bool
    ) throws -> SpeakerOptimizerApplyApproval {
        guard userInitiated else {
            throw SpeakerOptimizerCommissioningError.invalidApproval
        }
        return SpeakerOptimizerApplyApproval(
            proposalID: proposal.id,
            aggregateCandidateFingerprint:
                aggregateCandidateFingerprint(proposal),
            approvedAt: approvedAt,
            userInitiated: true
        )
    }

    /// Approval is necessary but deliberately not sufficient in this slice.
    /// A later live deployment adapter must also prove stage availability,
    /// snapshot identity, headroom/latency and post-apply measurement gates.
    func validateApproval(
        _ approval: SpeakerOptimizerApplyApproval,
        for proposal: SpeakerOptimizerCommissioningProposal
    ) throws {
        guard approval.userInitiated,
              approval.proposalID == proposal.id,
              approval.aggregateCandidateFingerprint
                == aggregateCandidateFingerprint(proposal) else {
            throw SpeakerOptimizerCommissioningError.invalidApproval
        }
        guard proposal.canApply else {
            throw SpeakerOptimizerCommissioningError.deploymentStageUnavailable
        }
    }

    func makePEQDeploymentConfiguration(
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval
    ) throws -> SpeakerOptimizerPEQDeploymentConfiguration {
        try validateApproval(approval, for: proposal)
        guard proposal.playbackSystemID == profile.id,
              proposal.baselineMeasurementSetID
                == plan.candidate.baselineMeasurementSetID,
              proposal.characterizationMeasurementSetID
                == plan.classification.characterizationMeasurementSetID,
              proposal.routingSignature == plan.candidate.routingSignature,
              abs(proposal.sampleRate - plan.candidate.sampleRate) < 0.5,
              let outputProfile = profile.state.outputDeviceProfile,
              outputProfile.enabled else {
            throw SpeakerOptimizerCommissioningError
                .candidateIdentityMismatch
        }

        let proposalBySource = Dictionary(
            uniqueKeysWithValues: proposal.sources.map {
                (sourceKey($0.source), $0)
            }
        )
        var deployments: [SpeakerOptimizerPEQSourceDeployment] = []
        for candidate in plan.candidate.sources where !candidate.bands.isEmpty {
            guard case .speaker(let role) = candidate.source,
                  role != .lowFrequencyEffects,
                  let sourceProposal =
                    proposalBySource[sourceKey(candidate.source)],
                  sourceProposal.candidateKind == .peq,
                  sourceProposal.stageStatus.canInstall,
                  sourceProposal.candidateFingerprint
                    == fingerprintPEQ(candidate) else {
                throw SpeakerOptimizerCommissioningError
                    .candidateIdentityMismatch
            }
            deployments.append(
                SpeakerOptimizerPEQSourceDeployment(
                    role: role,
                    bands: candidate.bands.map {
                        SpeakerOptimizerDeployedPEQBand(
                            frequencyHz: $0.centerHz,
                            gainDB: $0.gainDB,
                            q: $0.q
                        )
                    }
                )
            )
        }
        guard deployments.count == proposal.sources.count else {
            throw SpeakerOptimizerCommissioningError
                .candidateIdentityMismatch
        }

        let configuration = SpeakerOptimizerPEQDeploymentConfiguration(
            proposalID: proposal.id,
            baselineMeasurementSetID:
                proposal.baselineMeasurementSetID,
            characterizationMeasurementSetID:
                proposal.characterizationMeasurementSetID,
            routingSignature: proposal.routingSignature,
            sampleRate: proposal.sampleRate,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            approvedAt: approval.approvedAt,
            sources: deployments
        )
        try configuration.validate(profile: outputProfile)
        return configuration
    }

    func makeFIRDeploymentConfiguration(
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval
    ) throws -> SpeakerOptimizerFIRDeploymentConfiguration {
        try validateApproval(approval, for: proposal)
        guard proposal.playbackSystemID == profile.id,
              proposal.baselineMeasurementSetID
                == plan.candidate.baselineMeasurementSetID,
              proposal.characterizationMeasurementSetID
                == plan.classification.characterizationMeasurementSetID,
              proposal.routingSignature == plan.candidate.routingSignature,
              abs(proposal.sampleRate - plan.candidate.sampleRate) < 0.5,
              let outputProfile = profile.state.outputDeviceProfile,
              outputProfile.enabled,
              outputProfile.speakerOptimizerPEQ == nil else {
            throw SpeakerOptimizerCommissioningError
                .candidateIdentityMismatch
        }

        let proposalBySource = Dictionary(
            uniqueKeysWithValues: proposal.sources.map {
                (sourceKey($0.source), $0)
            }
        )
        var deployments: [SpeakerOptimizerFIRSourceDeployment] = []
        for candidate in plan.candidate.sources
        where candidate.acceptedForPreview && !candidate.taps.isEmpty {
            guard case .speaker(let role) = candidate.source,
                  role != .lowFrequencyEffects,
                  let sourceProposal =
                    proposalBySource[sourceKey(candidate.source)],
                  sourceProposal.candidateKind == .linearPhaseFIR,
                  sourceProposal.stageStatus
                    == .availableDedicatedSpeakerOptimizerFIRStage,
                  sourceProposal.candidateFingerprint
                    == fingerprintFIR(candidate) else {
                throw SpeakerOptimizerCommissioningError
                    .candidateIdentityMismatch
            }
            deployments.append(
                SpeakerOptimizerFIRSourceDeployment(
                    role: role,
                    candidateFingerprint:
                        sourceProposal.candidateFingerprint,
                    taps: candidate.taps,
                    maximumPositiveGainDB:
                        candidate.maximumPositiveGainDB,
                    recommendedHeadroomDB:
                        candidate.recommendedHeadroomDB
                )
            )
        }
        guard deployments.count == proposal.sources.count else {
            throw SpeakerOptimizerCommissioningError
                .candidateIdentityMismatch
        }

        let requiredHeadroom = deployments
            .map(\.recommendedHeadroomDB).max() ?? 0
        let configuration =
            SpeakerOptimizerFIRDeploymentConfiguration(
                proposalID: proposal.id,
                baselineMeasurementSetID:
                    proposal.baselineMeasurementSetID,
                characterizationMeasurementSetID:
                    proposal.characterizationMeasurementSetID,
                routingSignature: proposal.routingSignature,
                sampleRate: proposal.sampleRate,
                aggregateCandidateFingerprint:
                    approval.aggregateCandidateFingerprint,
                approvedAt: approval.approvedAt,
                tapCount: plan.candidate.requestedTapCount,
                declaredGroupDelayFrames:
                    plan.candidate.declaredGroupDelayFrames,
                requiredHeadroomDB: requiredHeadroom,
                sources: deployments
            )
        try configuration.validate(profile: outputProfile)
        _ = try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: outputProfile,
            bassManagementEnabled:
                profile.state.bassManagement.enabled,
            sampleRate: configuration.sampleRate,
            tapCount: configuration.tapCount,
            declaredGroupDelayFrames:
                UInt32(configuration.declaredGroupDelayFrames),
            correctedRoles: configuration.correctedRoles
        )
        return configuration
    }

    private func peqStageStatus(
        _ candidate: SpeakerOptimizerPEQSourceCandidate,
        profile: PlaybackSystemProfile,
        sampleRate: Double
    ) -> SpeakerOptimizerDeploymentStageStatus {
        guard case .speaker(let role) = candidate.source,
              role != .lowFrequencyEffects,
              let outputProfile = profile.state.outputDeviceProfile,
              outputProfile.enabled,
              outputProfile.programLayout.roles.contains(role),
              !candidate.bands.isEmpty,
              candidate.bands.count
                <= SpeakerOptimizerPEQDeploymentConfiguration
                    .maximumBandsPerSource else {
            return .blockedPEQCandidateNotRepresentable
        }

        let ordinaryCount = outputProfile.speakerAssignments
            .first(where: { $0.role == role })?
            .calibration?.eqBands.count ?? 0
        guard ordinaryCount + candidate.bands.count
                <= Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS) else {
            return .blockedPEQCandidateNotRepresentable
        }
        for band in candidate.bands {
            let deployed = SpeakerOptimizerDeployedPEQBand(
                frequencyHz: band.centerHz,
                gainDB: band.gainDB,
                q: band.q
            )
            guard (try? deployed.validate(sampleRate: sampleRate)) != nil else {
                return .blockedPEQCandidateNotRepresentable
            }
        }
        return .availableDedicatedSpeakerOptimizerPEQStage
    }

    private func firStageStatus(
        _ candidate: SpeakerOptimizerFIRSourceCandidate,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        profile: PlaybackSystemProfile
    ) -> SpeakerOptimizerDeploymentStageStatus {
        guard case .speaker(let role) = candidate.source,
              role != .lowFrequencyEffects,
              candidate.acceptedForPreview,
              !candidate.taps.isEmpty,
              let outputProfile = profile.state.outputDeviceProfile,
              outputProfile.enabled,
              outputProfile.speakerOptimizerPEQ == nil,
              outputProfile.programLayout.roles.contains(role),
              outputProfile.speakerAssignments.contains(where: {
                  $0.role == role
              }) else {
            return .blockedFIRCandidateNotRepresentable
        }

        let source = SpeakerOptimizerFIRSourceDeployment(
            role: role,
            candidateFingerprint: fingerprintFIR(candidate),
            taps: candidate.taps,
            maximumPositiveGainDB:
                candidate.maximumPositiveGainDB,
            recommendedHeadroomDB:
                candidate.recommendedHeadroomDB
        )
        let candidateConfiguration =
            SpeakerOptimizerFIRDeploymentConfiguration(
                proposalID: UUID(),
                baselineMeasurementSetID:
                    plan.candidate.baselineMeasurementSetID,
                characterizationMeasurementSetID:
                    plan.classification
                        .characterizationMeasurementSetID,
                routingSignature:
                    plan.candidate.routingSignature,
                sampleRate: plan.candidate.sampleRate,
                aggregateCandidateFingerprint:
                    "commissioning-representability-check",
                approvedAt: Date(timeIntervalSince1970: 0),
                tapCount: plan.candidate.requestedTapCount,
                declaredGroupDelayFrames:
                    plan.candidate.declaredGroupDelayFrames,
                requiredHeadroomDB:
                    candidate.recommendedHeadroomDB,
                sources: [source]
            )
        do {
            try candidateConfiguration.validate(
                profile: outputProfile
            )
            _ = try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: outputProfile,
                bassManagementEnabled:
                    profile.state.bassManagement.enabled,
                sampleRate: plan.candidate.sampleRate,
                tapCount: plan.candidate.requestedTapCount,
                declaredGroupDelayFrames:
                    UInt32(
                        plan.candidate.declaredGroupDelayFrames
                    ),
                correctedRoles: [role]
            )
        } catch {
            return .blockedFIRCandidateNotRepresentable
        }
        return .availableDedicatedSpeakerOptimizerFIRStage
    }

    private func makeProposal(
        profile: PlaybackSystemProfile,
        classification: SpeakerOptimizerCrossDomainReport,
        baselineID: UUID,
        routingSignature: String,
        sampleRate: Double,
        sources: [SpeakerOptimizerCommissioningSource],
        createdAt: Date
    ) -> SpeakerOptimizerCommissioningProposal {
        SpeakerOptimizerCommissioningProposal(
            createdAt: createdAt,
            playbackSystemID: profile.id,
            baselineMeasurementSetID: baselineID,
            characterizationMeasurementSetID:
                classification.characterizationMeasurementSetID,
            routingSignature: routingSignature,
            sampleRate: sampleRate,
            sources: sources,
            rollbackSnapshot: SpeakerOptimizerRollbackSnapshot(
                playbackSystemID: profile.id,
                routingSignature: routingSignature,
                playbackSystemState: profile.state
            )
        )
    }

    private func validateIdentity(
        profile: PlaybackSystemProfile,
        classification: SpeakerOptimizerCrossDomainReport,
        baselineID: UUID,
        playbackSystemID: UUID,
        routingSignature: String,
        sampleRate: Double
    ) throws {
        guard profile.id == playbackSystemID,
              classification.listeningMeasurementSetID == baselineID,
              classification.playbackSystemID == playbackSystemID,
              classification.routingSignature == routingSignature else {
            throw SpeakerOptimizerCommissioningError
                .candidateIdentityMismatch
        }
        guard let outputProfile = profile.state.outputDeviceProfile,
              outputProfile.enabled,
              outputProfile.multichannelCalibrationRoutingSignature
                == routingSignature,
              sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerOptimizerCommissioningError.profileIdentityMismatch
        }
    }

    private func fingerprintPEQ(
        _ candidate: SpeakerOptimizerPEQSourceCandidate
    ) -> String {
        var digest = StableDigest64()
        digest.add("peq-v1")
        digest.add(sourceKey(candidate.source))
        for band in candidate.bands {
            digest.add(band.centerHz.bitPattern)
            digest.add(band.q.bitPattern)
            digest.add(band.gainDB.bitPattern)
            digest.add(band.b0.bitPattern)
            digest.add(band.b1.bitPattern)
            digest.add(band.b2.bitPattern)
            digest.add(band.a1.bitPattern)
            digest.add(band.a2.bitPattern)
        }
        return digest.hex
    }

    private func fingerprintFIR(
        _ candidate: SpeakerOptimizerFIRSourceCandidate
    ) -> String {
        var digest = StableDigest64()
        digest.add("linear-fir-v1")
        digest.add(sourceKey(candidate.source))
        digest.add(UInt64(candidate.taps.count))
        for tap in candidate.taps {
            digest.add(UInt64(tap.bitPattern))
        }
        return digest.hex
    }

    private func sourceKey(
        _ source: MultichannelCalibrationSource
    ) -> String {
        switch source {
        case .speaker(let role):
            return "speaker:\(role.rawValue)"
        case .subwoofer(let index):
            return "subwoofer:\(index)"
        }
    }
}

private struct StableDigest64 {
    private var value: UInt64 = 14_695_981_039_346_656_037
    private let prime: UInt64 = 1_099_511_628_211

    mutating func add(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* prime
        }
        add(UInt64(0xff))
    }

    mutating func add(_ number: UInt64) {
        var little = number.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            for byte in bytes {
                value ^= UInt64(byte)
                value = value &* prime
            }
        }
    }

    var hex: String {
        String(format: "%016llx", value)
    }
}
