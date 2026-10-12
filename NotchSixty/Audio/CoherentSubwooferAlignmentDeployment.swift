import Foundation

enum CoherentSubwooferAlignmentDeploymentError:
    Error, Equatable, LocalizedError {
    case invalidRecord

    var errorDescription: String? {
        "Persisted coherent Sub alignment provenance is invalid or no longer matches the live speaker/Sub calibration."
    }
}

struct CoherentSubwooferAlignmentSpeakerDelayRecord:
    Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var delayMilliseconds: Double
}

struct CoherentSubwooferAlignmentVerificationRecord:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var applyReceiptID: UUID
    var verificationSessionID: UUID
    var verifiedAt: Date
    var evidenceConfidence: Double
    var sourceCount: Int
    var worstPhaseTrackingRMSRadians: Double
    var worstMagnitudeTrackingRMSDB: Double
    var coherenceBeforeDB: Double
    var coherenceAfterDB: Double
    var measuredImprovementDB: Double

    func validate(
        deployment: CoherentSubwooferAlignmentDeploymentRecord
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && applyReceiptID == deployment.applyReceiptID
            && verifiedAt >= deployment.appliedAt
            && evidenceConfidence.isFinite
            && (0...1).contains(evidenceConfidence)
            && sourceCount == deployment.mainRoles.count
            && sourceCount > 0
            && worstPhaseTrackingRMSRadians.isFinite
            && worstPhaseTrackingRMSRadians >= 0
            && worstMagnitudeTrackingRMSDB.isFinite
            && worstMagnitudeTrackingRMSDB >= 0
            && coherenceBeforeDB.isFinite
            && coherenceAfterDB.isFinite
            && coherenceAfterDB <= 1.0e-6
            && measuredImprovementDB.isFinite
            && measuredImprovementDB >= 0
            && abs(
                (coherenceAfterDB - coherenceBeforeDB)
                    - measuredImprovementDB
            ) <= 1.0e-6
    }
}

/// Separately owned provenance for PR108 timing/polarity calibration.
///
/// The actual live values remain in ordinary speaker/Sub calibration because
/// those are the production realtime owners of delay/polarity. This record does
/// not create a parallel DSP stage; it makes provisional-vs-verified PR108
/// ownership explicit across persistence/relaunch.
struct CoherentSubwooferAlignmentDeploymentRecord:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var applyReceiptID: UUID
    var proposalID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var crossoverFrequencyHz: Double
    var subwooferIndex: UInt32
    var mainRoles: [OutputProgramRole]
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var appliedAt: Date

    var signedRelativeDelayAdjustmentMilliseconds: Double
    var speakerCommonDelayAdjustmentMilliseconds: Double
    var subwooferDelayAdjustmentMilliseconds: Double
    var resultingSubwooferPolarityInverted: Bool

    /// Exact post-Apply calibration values. All non-LFE speaker delays are
    /// captured because a negative relative Sub adjustment is materialized as
    /// one common speaker delay across the semantic speaker field.
    var expectedSpeakerDelays:
        [CoherentSubwooferAlignmentSpeakerDelayRecord]
    var expectedSubwooferDelayMilliseconds: Double
    var expectedSubwooferPolarityInverted: Bool

    var verification:
        CoherentSubwooferAlignmentVerificationRecord? = nil

    var provisional: Bool { verification == nil }
    var verified: Bool { verification != nil }

    func validate(
        profile: OutputDeviceProfileConfiguration
    ) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              !routingSignature.isEmpty,
              routingSignature
                == profile.multichannelCalibrationRoutingSignature,
              sampleRate.isFinite, sampleRate > 0,
              crossoverFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange
                .contains(crossoverFrequencyHz),
              !mainRoles.isEmpty,
              Set(mainRoles).count == mainRoles.count,
              mainRoles.allSatisfy({
                  $0 != .lowFrequencyEffects
                    && profile.programLayout.roles.contains($0)
              }),
              !evidenceFingerprint.isEmpty,
              !candidateFingerprint.isEmpty,
              signedRelativeDelayAdjustmentMilliseconds.isFinite,
              speakerCommonDelayAdjustmentMilliseconds.isFinite,
              speakerCommonDelayAdjustmentMilliseconds >= 0,
              subwooferDelayAdjustmentMilliseconds.isFinite,
              subwooferDelayAdjustmentMilliseconds >= 0,
              abs(
                (
                    subwooferDelayAdjustmentMilliseconds
                    - speakerCommonDelayAdjustmentMilliseconds
                )
                    - signedRelativeDelayAdjustmentMilliseconds
              ) <= 0.001,
              expectedSubwooferDelayMilliseconds.isFinite,
              PhysicalSubwooferCalibration.delayRangeMilliseconds
                .contains(expectedSubwooferDelayMilliseconds),
              Set(expectedSpeakerDelays.map(\.role)).count
                == expectedSpeakerDelays.count else {
            return false
        }

        let expectedSpeakerRoles = Set(
            profile.speakerAssignments
                .filter { $0.role != .lowFrequencyEffects }
                .map(\.role)
        )
        guard Set(expectedSpeakerDelays.map(\.role))
                == expectedSpeakerRoles else {
            return false
        }

        let expectedByRole = Dictionary(
            uniqueKeysWithValues:
                expectedSpeakerDelays.map {
                    ($0.role, $0.delayMilliseconds)
                }
        )
        for assignment in profile.speakerAssignments
        where assignment.role != .lowFrequencyEffects {
            guard let expected = expectedByRole[assignment.role],
                  expected.isFinite,
                  SemanticSpeakerCalibration
                    .delayRangeMilliseconds.contains(expected),
                  abs(
                    (assignment.calibration?
                        .delayMilliseconds ?? 0)
                        - expected
                  ) <= 1.0e-8 else {
                return false
            }
        }

        guard let sub =
                profile.subwooferAssignments.first(where: {
                    $0.index == subwooferIndex
                }),
              abs(
                (sub.calibration?.delayMilliseconds ?? 0)
                    - expectedSubwooferDelayMilliseconds
              ) <= 1.0e-8,
              (sub.calibration?.polarityInverted ?? false)
                == expectedSubwooferPolarityInverted,
              resultingSubwooferPolarityInverted
                == expectedSubwooferPolarityInverted else {
            return false
        }

        if let verification {
            return verification.validate(deployment: self)
        }
        return true
    }

    static func capture(
        applyReceiptID: UUID,
        proposal:
            CoherentSubwooferAlignmentCommissioningProposal,
        appliedAt: Date,
        output: OutputDeviceProfileConfiguration
    ) throws -> CoherentSubwooferAlignmentDeploymentRecord {
        let candidate = proposal.candidate
        guard let sub =
                output.subwooferAssignments.first(where: {
                    $0.index == candidate.subwooferIndex
                }) else {
            throw CoherentSubwooferAlignmentApplyError
                .targetSubwooferUnavailable(
                    candidate.subwooferIndex
                )
        }

        let speakerDelays = output.speakerAssignments
            .filter { $0.role != .lowFrequencyEffects }
            .map {
                CoherentSubwooferAlignmentSpeakerDelayRecord(
                    role: $0.role,
                    delayMilliseconds:
                        $0.calibration?.delayMilliseconds ?? 0
                )
            }
            .sorted { $0.role.rawValue < $1.role.rawValue }

        let record = CoherentSubwooferAlignmentDeploymentRecord(
            applyReceiptID: applyReceiptID,
            proposalID: proposal.id,
            playbackSystemID: proposal.playbackSystemID,
            routingSignature: proposal.routingSignature,
            sampleRate: proposal.sampleRate,
            crossoverFrequencyHz:
                proposal.crossoverFrequencyHz,
            subwooferIndex: candidate.subwooferIndex,
            mainRoles: candidate.mainRoles,
            evidenceFingerprint:
                proposal.evidenceFingerprint,
            candidateFingerprint:
                proposal.candidateFingerprint,
            appliedAt: appliedAt,
            signedRelativeDelayAdjustmentMilliseconds:
                candidate
                    .signedRelativeDelayAdjustmentMilliseconds,
            speakerCommonDelayAdjustmentMilliseconds:
                candidate
                    .speakerCommonDelayAdjustmentMilliseconds,
            subwooferDelayAdjustmentMilliseconds:
                candidate
                    .subwooferDelayAdjustmentMilliseconds,
            resultingSubwooferPolarityInverted:
                candidate.resultingSubwooferPolarityInverted,
            expectedSpeakerDelays: speakerDelays,
            expectedSubwooferDelayMilliseconds:
                sub.calibration?.delayMilliseconds ?? 0,
            expectedSubwooferPolarityInverted:
                sub.calibration?.polarityInverted ?? false
        )
        guard record.validate(profile: output) else {
            throw CoherentSubwooferAlignmentApplyError
                .calibrationMutationInvalid
        }
        return record
    }
}
