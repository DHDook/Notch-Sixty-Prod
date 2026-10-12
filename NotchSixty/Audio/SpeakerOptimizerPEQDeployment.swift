import Foundation

struct SpeakerOptimizerDeployedPEQBand: Codable, Equatable, Sendable {
    static let gainRangeDB = -12.0...0.0
    static let qRange = 0.25...10.0

    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              frequencyHz.isFinite,
              frequencyHz >= 20,
              frequencyHz < sampleRate * 0.49,
              gainDB.isFinite,
              Self.gainRangeDB.contains(gainDB),
              q.isFinite,
              Self.qRange.contains(q) else {
            throw SpeakerOptimizerPEQDeploymentError.invalidBand
        }
    }
}

struct SpeakerOptimizerPEQSourceDeployment: Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var bands: [SpeakerOptimizerDeployedPEQBand]
}

struct SpeakerOptimizerPEQVerificationRecord:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var applyReceiptID: UUID
    var verificationMeasurementSetID: UUID
    var verifiedAt: Date
    var evidenceConfidence: Double
    var sourceCount: Int
    var worstFilterTrackingRMSDB: Double
    var minimumPersistentImprovementDB: Double
    var worstPersistentSeatRegressionDB: Double
    var maximumProtectedRegressionDB: Double

    func validate(
        deployment: SpeakerOptimizerPEQDeploymentConfiguration
    ) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && verificationMeasurementSetID
                != deployment.baselineMeasurementSetID
            && evidenceConfidence.isFinite
            && (0...1).contains(evidenceConfidence)
            && sourceCount == deployment.sources.count
            && sourceCount > 0
            && worstFilterTrackingRMSDB.isFinite
            && worstFilterTrackingRMSDB >= 0
            && minimumPersistentImprovementDB.isFinite
            && worstPersistentSeatRegressionDB.isFinite
            && maximumProtectedRegressionDB.isFinite
    }
}

struct SpeakerOptimizerPEQDeploymentConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumBandsPerSource = 10

    var schemaVersion: Int = currentSchemaVersion
    var enabled: Bool = true
    var proposalID: UUID
    var baselineMeasurementSetID: UUID
    var characterizationMeasurementSetID: UUID
    var routingSignature: String
    var sampleRate: Double
    var aggregateCandidateFingerprint: String
    var approvedAt: Date
    var sources: [SpeakerOptimizerPEQSourceDeployment]
    /// Optional so pre-PR105 persisted Output Device Profiles decode unchanged.
    /// Presence means fresh post-Apply microphone verification passed.
    var verification: SpeakerOptimizerPEQVerificationRecord? = nil

    var bandsByRole: [OutputProgramRole: [SpeakerOptimizerDeployedPEQBand]] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.role, $0.bands) })
    }

    func validate(profile: OutputDeviceProfileConfiguration) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              enabled,
              sampleRate.isFinite, sampleRate > 0,
              !routingSignature.isEmpty,
              !aggregateCandidateFingerprint.isEmpty,
              routingSignature == profile.multichannelCalibrationRoutingSignature,
              profile.speakerOptimizerFIR == nil,
              !sources.isEmpty,
              Set(sources.map(\.role)).count == sources.count else {
            throw SpeakerOptimizerPEQDeploymentError.invalidConfiguration
        }

        if let verification,
           !verification.validate(deployment: self) {
            throw SpeakerOptimizerPEQDeploymentError
                .invalidVerificationRecord
        }

        let allowedRoles = Set(
            profile.programLayout.roles.filter {
                $0 != .lowFrequencyEffects
            }
        )
        for source in sources {
            guard allowedRoles.contains(source.role),
                  !source.bands.isEmpty,
                  source.bands.count <= Self.maximumBandsPerSource else {
                throw SpeakerOptimizerPEQDeploymentError.invalidSource
            }
            for band in source.bands {
                try band.validate(sampleRate: sampleRate)
            }
            let ordinaryCount = profile.speakerAssignments
                .first(where: { $0.role == source.role })?
                .calibration?.eqBands.count ?? 0
            guard ordinaryCount + source.bands.count
                    <= Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS) else {
                throw SpeakerOptimizerPEQDeploymentError
                    .laneSectionCapacityExceeded(
                        role: source.role,
                        ordinary: ordinaryCount,
                        optimizer: source.bands.count
                    )
            }
        }
    }
}

enum SpeakerOptimizerPEQDeploymentError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidSource
    case invalidBand
    case invalidVerificationRecord
    case laneSectionCapacityExceeded(
        role: OutputProgramRole,
        ordinary: Int,
        optimizer: Int
    )

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Speaker Optimizer PEQ deployment metadata is invalid or stale."
        case .invalidSource:
            return "Speaker Optimizer PEQ deployment contains an unsupported or empty whole-speaker source."
        case .invalidBand:
            return "Speaker Optimizer live PEQ currently accepts finite cut-only peaking bands inside the supported sample-rate range."
        case .invalidVerificationRecord:
            return "Speaker Optimizer verification metadata is invalid or does not match the deployed PEQ."
        case .laneSectionCapacityExceeded(let role, let ordinary, let optimizer):
            return "\(role.displayName) needs \(ordinary) Speaker Calibration plus \(optimizer) Speaker Optimizer PEQ sections, exceeding the live lane ceiling of \(Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS))."
        }
    }
}
