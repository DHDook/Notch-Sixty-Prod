import Foundation

enum CoherentMultiSubwooferAlignmentDeploymentError:
    Error, Equatable, LocalizedError {
    case invalidRecord

    var errorDescription: String? {
        "Persisted coordinated multi-Sub alignment provenance is invalid or no longer matches the live speaker/Sub calibration."
    }
}

struct CoherentMultiSubwooferAlignmentVerificationRecord:
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
        deployment:
            CoherentMultiSubwooferAlignmentDeploymentRecord
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && applyReceiptID == deployment.applyReceiptID
            && verifiedAt >= deployment.appliedAt
            && evidenceConfidence.isFinite
            && (0...1).contains(evidenceConfidence)
            && sourceCount
                == deployment.mainRoles.count
                    * deployment.subwoofers.count
            && sourceCount >= 2
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

struct CoherentMultiSubwooferAlignmentSubDeploymentRecord:
    Codable, Equatable, Sendable {
    var subwooferIndex: UInt32
    var signedRelativeDelayAdjustmentMilliseconds: Double
    var subwooferDelayAdjustmentMilliseconds: Double
    var resultingSubwooferPolarityInverted: Bool
    var expectedSubwooferDelayMilliseconds: Double
    var expectedSubwooferPolarityInverted: Bool
}

/// Persistent provenance for one atomic coordinated multi-Sub Apply.
///
/// Realtime ownership remains the ordinary speaker/Sub calibration fields.
/// This record proves which exact timing/polarity values belong to the
/// provisional coordinated PR108 transaction across relaunch.
struct CoherentMultiSubwooferAlignmentDeploymentRecord:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var applyReceiptID: UUID
    var proposalID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var crossoverFrequencyHz: Double
    var mainRoles: [OutputProgramRole]
    var evidenceFingerprint: String
    var candidateFingerprint: String
    var appliedAt: Date
    var speakerCommonDelayAdjustmentMilliseconds: Double
    var expectedSpeakerDelays:
        [CoherentSubwooferAlignmentSpeakerDelayRecord]
    var subwoofers:
        [CoherentMultiSubwooferAlignmentSubDeploymentRecord]
    var verification:
        CoherentMultiSubwooferAlignmentVerificationRecord? = nil

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
              speakerCommonDelayAdjustmentMilliseconds.isFinite,
              speakerCommonDelayAdjustmentMilliseconds >= 0,
              subwoofers.count >= 2,
              Set(subwoofers.map(\.subwooferIndex)).count
                == subwoofers.count,
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

        let liveSubIndices =
            Set(profile.subwooferAssignments.map(\.index))
        guard Set(subwoofers.map(\.subwooferIndex))
                == liveSubIndices else {
            return false
        }

        for record in subwoofers {
            guard record
                    .signedRelativeDelayAdjustmentMilliseconds
                    .isFinite,
                  record
                    .subwooferDelayAdjustmentMilliseconds
                    .isFinite,
                  record.subwooferDelayAdjustmentMilliseconds >= 0,
                  abs(
                    (
                        record
                            .subwooferDelayAdjustmentMilliseconds
                        - speakerCommonDelayAdjustmentMilliseconds
                    )
                        - record
                            .signedRelativeDelayAdjustmentMilliseconds
                  ) <= 0.001,
                  record.expectedSubwooferDelayMilliseconds
                    .isFinite,
                  PhysicalSubwooferCalibration
                    .delayRangeMilliseconds
                    .contains(
                        record
                            .expectedSubwooferDelayMilliseconds
                    ),
                  let live =
                    profile.subwooferAssignments.first(
                        where: {
                            $0.index == record.subwooferIndex
                        }
                    ),
                  abs(
                    (live.calibration?
                        .delayMilliseconds ?? 0)
                        - record
                            .expectedSubwooferDelayMilliseconds
                  ) <= 1.0e-8,
                  (live.calibration?
                    .polarityInverted ?? false)
                    == record
                        .expectedSubwooferPolarityInverted,
                  record
                    .resultingSubwooferPolarityInverted
                    == record
                        .expectedSubwooferPolarityInverted else {
                return false
            }
        }
        if let verification {
            return verification.validate(deployment: self)
        }
        return true
    }

    static func capture(
        applyReceiptID: UUID,
        proposal:
            CoherentMultiSubwooferAlignmentCommissioningProposal,
        appliedAt: Date,
        output: OutputDeviceProfileConfiguration
    ) throws -> CoherentMultiSubwooferAlignmentDeploymentRecord {
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

        var subRecords:
            [CoherentMultiSubwooferAlignmentSubDeploymentRecord] = []
        for plan in proposal.candidate.subwoofers.sorted(by: {
            $0.subwooferIndex < $1.subwooferIndex
        }) {
            guard let live =
                    output.subwooferAssignments.first(where: {
                        $0.index == plan.subwooferIndex
                    }) else {
                throw CoherentMultiSubwooferAlignmentDeploymentError
                    .invalidRecord
            }
            subRecords.append(
                CoherentMultiSubwooferAlignmentSubDeploymentRecord(
                    subwooferIndex: plan.subwooferIndex,
                    signedRelativeDelayAdjustmentMilliseconds:
                        plan
                            .signedRelativeDelayAdjustmentMilliseconds,
                    subwooferDelayAdjustmentMilliseconds:
                        plan
                            .subwooferDelayAdjustmentMilliseconds,
                    resultingSubwooferPolarityInverted:
                        plan
                            .resultingSubwooferPolarityInverted,
                    expectedSubwooferDelayMilliseconds:
                        live.calibration?.delayMilliseconds ?? 0,
                    expectedSubwooferPolarityInverted:
                        live.calibration?.polarityInverted ?? false
                )
            )
        }

        let record =
            CoherentMultiSubwooferAlignmentDeploymentRecord(
                applyReceiptID: applyReceiptID,
                proposalID: proposal.id,
                playbackSystemID: proposal.playbackSystemID,
                routingSignature: proposal.routingSignature,
                sampleRate: proposal.sampleRate,
                crossoverFrequencyHz:
                    proposal.crossoverFrequencyHz,
                mainRoles: proposal.candidate.mainRoles,
                evidenceFingerprint:
                    proposal.evidenceFingerprint,
                candidateFingerprint:
                    proposal.candidateFingerprint,
                appliedAt: appliedAt,
                speakerCommonDelayAdjustmentMilliseconds:
                    proposal.candidate
                        .speakerCommonDelayAdjustmentMilliseconds,
                expectedSpeakerDelays: speakerDelays,
                subwoofers: subRecords
            )
        guard record.validate(profile: output) else {
            throw CoherentMultiSubwooferAlignmentDeploymentError
                .invalidRecord
        }
        return record
    }
}
