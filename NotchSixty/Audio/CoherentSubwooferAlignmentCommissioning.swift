import Foundation

struct CoherentSubwooferAlignmentRollbackSnapshot:
    Codable, Equatable, Sendable {
    var playbackSystemID: UUID
    var playbackSystemState: PlaybackSystemState
}

struct CoherentSubwooferAlignmentCommissioningProposal:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var crossoverFrequencyHz: Double
    var subwooferIndex: UInt32
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var candidate: CoherentSubwooferAlignmentCandidate
    var rollbackSnapshot:
        CoherentSubwooferAlignmentRollbackSnapshot

    var approvalRequired: Bool { true }
    var readyForApproval: Bool {
        candidate.acceptedForPreview
            && candidate.previewOnly
            && !candidate.canDeploy
    }
    /// The raw Slice 1 candidate remains preview-only. Once the dedicated
    /// transactional stage exists, this fingerprint-bound proposal is eligible
    /// for explicit Apply.
    var canApply: Bool { readyForApproval }
    var canDeploy: Bool { canApply }
}

struct CoherentSubwooferAlignmentApproval:
    Codable, Equatable, Sendable {
    var proposalID: UUID
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var approvedAt: Date
    var userInitiated: Bool
}

enum CoherentSubwooferAlignmentCommissioningError:
    Error, Equatable, LocalizedError {
    case candidateNotReviewable
    case playbackSystemIdentityMismatch
    case outputDeviceProfileRequired
    case bassManagementMismatch
    case evidenceOrCandidateDrift
    case invalidApproval

    var errorDescription: String? {
        switch self {
        case .candidateNotReviewable:
            return "Only an accepted preview-only coherent Sub alignment candidate can enter commissioning."
        case .playbackSystemIdentityMismatch:
            return "The coherent Sub alignment candidate does not belong to the selected Playback System."
        case .outputDeviceProfileRequired:
            return "The selected Playback System needs an enabled Output Device Profile for coherent Sub alignment."
        case .bassManagementMismatch:
            return "Bass-management state or crossover frequency changed after the coherent alignment candidate was designed."
        case .evidenceOrCandidateDrift:
            return "Coherent measurement evidence or the derived alignment candidate changed after review; regenerate the proposal."
        case .invalidApproval:
            return "Coherent Sub alignment approval is missing, stale, or was not explicitly user initiated."
        }
    }
}

/// PR108 Slice 2: immutable commissioning identity only.
///
/// The proposal deliberately snapshots the complete PlaybackSystemState so a
/// later Apply transaction can use optimistic concurrency and exact rollback.
/// It also re-runs Slice 1 from the supplied coherent evidence rather than
/// trusting a caller-provided candidate.
struct CoherentSubwooferAlignmentCommissioningPlanner:
    Sendable {
    func proposal(
        profile: PlaybackSystemProfile,
        reports: [SpeakerMeasurementLabCoherentTimingReport],
        candidate: CoherentSubwooferAlignmentCandidate,
        options: CoherentSubwooferAlignmentOptions = .init(),
        createdAt: Date = Date()
    ) throws -> CoherentSubwooferAlignmentCommissioningProposal {
        guard candidate.acceptedForPreview,
              candidate.previewOnly,
              !candidate.canDeploy else {
            throw CoherentSubwooferAlignmentCommissioningError
                .candidateNotReviewable
        }
        guard profile.id == candidate.playbackSystemID else {
            throw CoherentSubwooferAlignmentCommissioningError
                .playbackSystemIdentityMismatch
        }
        guard let output = profile.state.outputDeviceProfile,
              output.enabled else {
            throw CoherentSubwooferAlignmentCommissioningError
                .outputDeviceProfileRequired
        }
        let bass = profile.state.bassManagement
        guard bass.enabled,
              abs(bass.frequencyHz
                    - candidate.crossoverFrequencyHz) < 1.0e-9 else {
            throw CoherentSubwooferAlignmentCommissioningError
                .bassManagementMismatch
        }

        let regenerated = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: reports,
                profile: output,
                bassManagementEnabled: bass.enabled,
                crossoverFrequencyHz: bass.frequencyHz,
                options: options
            )
        guard regenerated == candidate else {
            throw CoherentSubwooferAlignmentCommissioningError
                .evidenceOrCandidateDrift
        }

        let evidenceFingerprint = fingerprintReports(reports)
        let candidateFingerprint = fingerprintCandidate(candidate)
        return CoherentSubwooferAlignmentCommissioningProposal(
            createdAt: createdAt,
            playbackSystemID: profile.id,
            routingSignature: candidate.routingSignature,
            sampleRate: candidate.sampleRate,
            crossoverFrequencyHz:
                candidate.crossoverFrequencyHz,
            subwooferIndex: candidate.subwooferIndex,
            evidenceFingerprint: evidenceFingerprint,
            candidateFingerprint: candidateFingerprint,
            candidate: candidate,
            rollbackSnapshot:
                CoherentSubwooferAlignmentRollbackSnapshot(
                    playbackSystemID: profile.id,
                    playbackSystemState: profile.state
                )
        )
    }

    func makeExplicitApproval(
        proposal: CoherentSubwooferAlignmentCommissioningProposal,
        approvedAt: Date = Date(),
        userInitiated: Bool
    ) throws -> CoherentSubwooferAlignmentApproval {
        guard proposal.readyForApproval, userInitiated else {
            throw CoherentSubwooferAlignmentCommissioningError
                .invalidApproval
        }
        return CoherentSubwooferAlignmentApproval(
            proposalID: proposal.id,
            evidenceFingerprint: proposal.evidenceFingerprint,
            candidateFingerprint: proposal.candidateFingerprint,
            approvedAt: approvedAt,
            userInitiated: true
        )
    }

    func validateApproval(
        _ approval: CoherentSubwooferAlignmentApproval,
        for proposal: CoherentSubwooferAlignmentCommissioningProposal
    ) throws {
        guard proposal.readyForApproval,
              approval.userInitiated,
              approval.proposalID == proposal.id,
              approval.evidenceFingerprint
                == proposal.evidenceFingerprint,
              approval.candidateFingerprint
                == proposal.candidateFingerprint else {
            throw CoherentSubwooferAlignmentCommissioningError
                .invalidApproval
        }
    }

    func fingerprintReports(
        _ reports: [SpeakerMeasurementLabCoherentTimingReport]
    ) -> String {
        var digest = PR108StableDigest64()
        digest.add("pr108-coherent-evidence-v1")
        for report in reports.sorted(by: {
            sourceKey($0.main) < sourceKey($1.main)
        }) {
            digest.add(report.sessionID.uuidString)
            digest.add(report.coherentPairID.uuidString)
            digest.add(report.playbackSystemID.uuidString)
            digest.add(report.routingSignature)
            digest.add(report.microphone.deviceUID)
            digest.add(UInt64(report.microphone.inputChannelIndex))
            digest.add(report.microphone.calibrationFingerprint ?? "")
            digest.add(sourceKey(report.main))
            digest.add(sourceKey(report.subwoofer))
            digest.add(report.sampleRate.bitPattern)
            digest.add(
                report.relativeArrivalMilliseconds.bitPattern
            )
            digest.add(report.evidenceConfidence.bitPattern)
            for value in report.frequenciesHz {
                digest.add(value.bitPattern)
            }
            for value in report.relativeMagnitudeDB {
                digest.add(value.bitPattern)
            }
            for value in report.wrappedRelativePhaseRadians {
                digest.add(value.bitPattern)
            }
        }
        return digest.hex
    }

    func fingerprintCandidate(
        _ candidate: CoherentSubwooferAlignmentCandidate
    ) -> String {
        var digest = PR108StableDigest64()
        digest.add("pr108-coherent-candidate-v1")
        digest.add(candidate.playbackSystemID.uuidString)
        digest.add(candidate.routingSignature)
        digest.add(candidate.microphone.deviceUID)
        digest.add(UInt64(candidate.microphone.inputChannelIndex))
        digest.add(
            candidate.microphone.calibrationFingerprint ?? ""
        )
        digest.add(candidate.sampleRate.bitPattern)
        digest.add(UInt64(candidate.subwooferIndex))
        for role in candidate.mainRoles.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            digest.add(role.rawValue)
        }
        digest.add(candidate.crossoverFrequencyHz.bitPattern)
        digest.add(
            UInt64(candidate.analyzedFrequencyCount)
        )
        digest.add(
            candidate.signedRelativeDelayAdjustmentMilliseconds
                .bitPattern
        )
        digest.add(
            candidate.subwooferDelayAdjustmentMilliseconds
                .bitPattern
        )
        digest.add(
            candidate.speakerCommonDelayAdjustmentMilliseconds
                .bitPattern
        )
        digest.add(candidate.toggleSubwooferPolarity ? 1 : 0)
        digest.add(
            candidate.resultingSubwooferPolarityInverted ? 1 : 0
        )
        digest.add(
            candidate.predictedCoherenceBeforeDB.bitPattern
        )
        digest.add(
            candidate.predictedCoherenceAfterDB.bitPattern
        )
        digest.add(candidate.predictedImprovementDB.bitPattern)
        digest.add(candidate.evidenceConfidence.bitPattern)
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

private struct PR108StableDigest64 {
    private var value: UInt64 =
        14_695_981_039_346_656_037
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
