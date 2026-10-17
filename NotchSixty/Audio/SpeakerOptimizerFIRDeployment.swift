import Foundation

enum SpeakerOptimizerFIRLatencyPlanningError:
    Error, Equatable, LocalizedError {
    case profileInvalid
    case invalidSampleRate
    case invalidTapCount(Int)
    case invalidDeclaredGroupDelay(expected: UInt32, actual: UInt32)
    case correctedRoleRequired
    case duplicateCorrectedRole(OutputProgramRole)
    case unsupportedCorrectedRole(OutputProgramRole)
    case delayCapacityExceeded(role: OutputProgramRole)

    var errorDescription: String? {
        switch self {
        case .profileInvalid:
            return "Speaker Optimizer FIR latency planning requires a valid enabled Output Device Profile."
        case .invalidSampleRate:
            return "Speaker Optimizer FIR latency planning requires a finite positive sample rate."
        case .invalidTapCount(let count):
            return "Speaker Optimizer FIR deployment requires an odd tap count inside the realtime convolution limit; received \(count)."
        case .invalidDeclaredGroupDelay(let expected, let actual):
            return "Linear-phase FIR group delay must equal (tapCount - 1) / 2; expected \(expected) frames, received \(actual)."
        case .correctedRoleRequired:
            return "Speaker Optimizer FIR deployment requires at least one whole-speaker program role."
        case .duplicateCorrectedRole(let role):
            return "Speaker Optimizer FIR deployment contains duplicate role \(role.displayName)."
        case .unsupportedCorrectedRole(let role):
            return "Speaker Optimizer FIR deployment cannot target \(role.displayName); only mapped whole-speaker program roles are supported."
        case .delayCapacityExceeded(let role):
            return "Speaker Optimizer FIR latency compensation plus existing calibration delay exceeds the realtime lane delay budget for \(role.displayName)."
        }
    }
}

struct SpeakerOptimizerFIRRoleLatencyPlan:
    Equatable, Sendable {
    var role: OutputProgramRole
    var firApplied: Bool
    /// Algorithmic latency physically incurred before the semantic program lane.
    var upstreamProcessingLatencyFrames: UInt32
    /// Delay inserted into a faster, non-FIR lane so all program channels retain
    /// the same DSP time origin before user calibration delay is applied.
    var coherenceCompensationFrames: UInt32
    /// Existing intentional speaker-calibration delay. This is not normalized
    /// away by FIR coherence compensation.
    var userCalibrationDelayFrames: UInt32
    /// Delay executed by the existing program-lane delay buffer.
    var effectiveLaneDelayFrames: UInt32
    /// Total latency from this PR107 stage plus the lane delay for the role.
    var endToEndProgramLatencyFrames: UInt32
}

struct SpeakerOptimizerFIRLatencyPlan:
    Equatable, Sendable {
    var sampleRate: Double
    var tapCount: Int
    var declaredGroupDelayFrames: UInt32
    var convolutionEngineLatencyFrames: UInt32
    /// Fixed added latency of the FIR stage itself:
    /// partitioned-convolver block latency + linear-phase group delay.
    var addedFIRLatencyFrames: UInt32
    /// Maximum upstream FIR latency used by N60ProgramLaneGraphFinalize to
    /// compensate channels that do not run a Speaker Optimizer FIR.
    var coherenceLatencyFrames: UInt32
    var rolePlans: [SpeakerOptimizerFIRRoleLatencyPlan]
    var maximumEndToEndProgramLatencyFrames: UInt32

    var addedFIRLatencyMilliseconds: Double {
        Double(addedFIRLatencyFrames) / sampleRate * 1_000
    }

    var maximumEndToEndProgramLatencyMilliseconds: Double {
        Double(maximumEndToEndProgramLatencyFrames) / sampleRate * 1_000
    }

    /// The audio path is intentionally delayed whenever this stage is active.
    /// PR107 must surface this value to later A/V policy/UI work rather than
    /// silently pretending video has been delayed by the audio engine.
    var requiresAVSyncCoordination: Bool {
        addedFIRLatencyFrames > 0
    }

    var canInstallLiveFIR: Bool {
        // The dedicated sparse runtime, persistent ownership, automatic
        // headroom reserve and transactional Apply path now exist. Candidate
        // identity/headroom/approval gates are still enforced by commissioning.
        true
    }
}

/// PR107 Slice 1: exact latency accounting for a future separately-owned,
/// per-whole-speaker FIR stage.
///
/// The existing N-channel lane engine already supports
/// upstreamProcessingLatencyFrames and automatically adds compensation to
/// faster lanes. This planner proves that a proposed FIR fits that contract
/// without modifying DSP state or pretending that audio latency also delays
/// system video.
///
/// Important: declaredGroupDelayFrames is the FIR's linear-phase group delay.
/// The realtime partitioned convolver also contributes a fixed engine latency;
/// both must be counted exactly once.
struct SpeakerOptimizerFIRLatencyPlanner: Sendable {
    static let convolutionEngineLatencyFrames =
        UInt32(N60_CONVOLUTION_PARTITION_FRAMES)

    func plan(
        profile: OutputDeviceProfileConfiguration,
        bassManagementEnabled: Bool,
        sampleRate: Double,
        tapCount: Int,
        declaredGroupDelayFrames: UInt32,
        correctedRoles: [OutputProgramRole]
    ) throws -> SpeakerOptimizerFIRLatencyPlan {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerOptimizerFIRLatencyPlanningError.invalidSampleRate
        }
        guard tapCount >= 3,
              tapCount <= Int(N60_PROGRAM_FIR_MAX_TAPS),
              tapCount % 2 == 1 else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .invalidTapCount(tapCount)
        }

        let expectedGroupDelay = UInt32((tapCount - 1) / 2)
        guard declaredGroupDelayFrames == expectedGroupDelay else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .invalidDeclaredGroupDelay(
                    expected: expectedGroupDelay,
                    actual: declaredGroupDelayFrames
                )
        }

        do {
            try profile.validateStructure(
                bassManagementEnabled: bassManagementEnabled
            )
        } catch {
            throw SpeakerOptimizerFIRLatencyPlanningError.profileInvalid
        }
        guard profile.enabled else {
            throw SpeakerOptimizerFIRLatencyPlanningError.profileInvalid
        }
        guard !correctedRoles.isEmpty else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .correctedRoleRequired
        }

        var unique: [OutputProgramRole] = []
        for role in correctedRoles {
            if unique.contains(role) {
                throw SpeakerOptimizerFIRLatencyPlanningError
                    .duplicateCorrectedRole(role)
            }
            unique.append(role)
            guard role != .lowFrequencyEffects,
                  profile.programLayout.roles.contains(role),
                  profile.speakerAssignments.contains(where: {
                      $0.role == role
                  }) else {
                throw SpeakerOptimizerFIRLatencyPlanningError
                    .unsupportedCorrectedRole(role)
            }
        }

        let engine = Self.convolutionEngineLatencyFrames
        guard declaredGroupDelayFrames
                <= UInt32.max - engine else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .delayCapacityExceeded(role: unique[0])
        }
        let upstream = engine + declaredGroupDelayFrames
        guard upstream <= UInt32(N60_PROGRAM_LANE_MAX_DELAY_FRAMES) else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .delayCapacityExceeded(role: unique[0])
        }

        var rolePlans: [SpeakerOptimizerFIRRoleLatencyPlan] = []
        rolePlans.reserveCapacity(profile.programLayout.roles.count)
        var maximumEndToEnd: UInt32 = 0

        for role in profile.programLayout.roles {
            let firApplied = unique.contains(role)
            let userDelay = try calibrationDelayFrames(
                role: role,
                profile: profile,
                sampleRate: sampleRate
            )
            let compensation: UInt32 = firApplied ? 0 : upstream
            guard userDelay
                    <= UInt32(N60_PROGRAM_LANE_MAX_DELAY_FRAMES)
                        - compensation else {
                throw SpeakerOptimizerFIRLatencyPlanningError
                    .delayCapacityExceeded(role: role)
            }

            let effectiveLaneDelay = userDelay + compensation
            let physicallyIncurredUpstream = firApplied ? upstream : 0
            guard effectiveLaneDelay
                    <= UInt32.max - physicallyIncurredUpstream else {
                throw SpeakerOptimizerFIRLatencyPlanningError
                    .delayCapacityExceeded(role: role)
            }
            let endToEnd =
                physicallyIncurredUpstream + effectiveLaneDelay
            maximumEndToEnd = max(maximumEndToEnd, endToEnd)

            rolePlans.append(
                SpeakerOptimizerFIRRoleLatencyPlan(
                    role: role,
                    firApplied: firApplied,
                    upstreamProcessingLatencyFrames:
                        physicallyIncurredUpstream,
                    coherenceCompensationFrames: compensation,
                    userCalibrationDelayFrames: userDelay,
                    effectiveLaneDelayFrames: effectiveLaneDelay,
                    endToEndProgramLatencyFrames: endToEnd
                )
            )
        }

        return SpeakerOptimizerFIRLatencyPlan(
            sampleRate: sampleRate,
            tapCount: tapCount,
            declaredGroupDelayFrames: declaredGroupDelayFrames,
            convolutionEngineLatencyFrames: engine,
            addedFIRLatencyFrames: upstream,
            coherenceLatencyFrames: upstream,
            rolePlans: rolePlans,
            maximumEndToEndProgramLatencyFrames: maximumEndToEnd
        )
    }

    private func calibrationDelayFrames(
        role: OutputProgramRole,
        profile: OutputDeviceProfileConfiguration,
        sampleRate: Double
    ) throws -> UInt32 {
        let delayMilliseconds =
            profile.speakerAssignments.first(where: { $0.role == role })?
                .calibration?.delayMilliseconds ?? 0
        let frames = delayMilliseconds * sampleRate / 1_000
        guard frames.isFinite, frames >= 0,
              frames <= Double(N60_PROGRAM_LANE_MAX_DELAY_FRAMES) else {
            throw SpeakerOptimizerFIRLatencyPlanningError
                .delayCapacityExceeded(role: role)
        }
        return UInt32(frames.rounded())
    }
}


struct SpeakerOptimizerFIRSourceDeployment:
    Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var candidateFingerprint: String
    var taps: [Float]
    var maximumPositiveGainDB: Double
    var recommendedHeadroomDB: Double
}

struct SpeakerOptimizerFIRRuntimePreparation:
    Equatable, Sendable {
    var activeChannelMask: UInt32
    /// Flattened [active semantic channel in ascending layout order][tap].
    var flattenedTaps: [Float]
    var tapCount: UInt32
    var declaredGroupDelayFrames: UInt32
    var requiredHeadroomDB: Double
}

enum SpeakerOptimizerFIRDeploymentError:
    Error, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidSource(OutputProgramRole)
    case invalidTaps(OutputProgramRole)
    case sampleRateMismatch(expected: Double, actual: Double)
    case runtimePreparationFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Speaker Optimizer FIR deployment metadata is invalid or stale."
        case .invalidSource(let role):
            return "Speaker Optimizer FIR deployment contains an unsupported or duplicate source: \(role.displayName)."
        case .invalidTaps(let role):
            return "Speaker Optimizer FIR taps for \(role.displayName) are invalid, non-finite, empty, or not symmetric linear-phase taps."
        case .sampleRateMismatch(let expected, let actual):
            return "Speaker Optimizer FIR was commissioned at \(expected) Hz but the live Playback System is running at \(actual) Hz."
        case .runtimePreparationFailed:
            return "Speaker Optimizer FIR could not be mapped onto the active semantic program layout."
        }
    }
}

/// Separately owned, versioned Playback-System state for a deployed
/// Speaker Optimizer linear-phase FIR.
///
/// This is intentionally distinct from Room Correction, Speaker IR and ordinary
/// Speaker Calibration. The required headroom reserve is part of the deployment
/// contract so a persisted FIR cannot depend on a Content Preset happening to
/// provide enough attenuation.
struct SpeakerOptimizerFIRVerificationRecord:
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
        deployment: SpeakerOptimizerFIRDeploymentConfiguration
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

struct SpeakerOptimizerFIRDeploymentConfiguration:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumHeadroomDB = 6.0

    var schemaVersion: Int = currentSchemaVersion
    var enabled: Bool = true
    var proposalID: UUID
    var baselineMeasurementSetID: UUID
    var characterizationMeasurementSetID: UUID
    var routingSignature: String
    var sampleRate: Double
    var aggregateCandidateFingerprint: String
    var approvedAt: Date
    var tapCount: Int
    var declaredGroupDelayFrames: Int
    /// Automatic whole-program reserve applied by the N-channel graph compiler.
    /// Positive dB here means that amount is subtracted from live program gain.
    var requiredHeadroomDB: Double
    var sources: [SpeakerOptimizerFIRSourceDeployment]
    /// Presence means a fresh post-Apply microphone verification campaign
    /// accepted this exact deployed FIR.
    var verification: SpeakerOptimizerFIRVerificationRecord? = nil

    var correctedRoles: [OutputProgramRole] {
        sources.map(\.role)
    }

    func validate(
        profile: OutputDeviceProfileConfiguration
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              enabled,
              sampleRate.isFinite, sampleRate > 0,
              !routingSignature.isEmpty,
              routingSignature
                == profile.multichannelCalibrationRoutingSignature,
              profile.speakerOptimizerPEQ == nil,
              !aggregateCandidateFingerprint.isEmpty,
              tapCount >= 257,
              tapCount <= Int(N60_PROGRAM_FIR_MAX_TAPS),
              tapCount % 2 == 1,
              declaredGroupDelayFrames == (tapCount - 1) / 2,
              requiredHeadroomDB.isFinite,
              (0...Self.maximumHeadroomDB)
                .contains(requiredHeadroomDB),
              !sources.isEmpty,
              Set(sources.map(\.role)).count == sources.count else {
            throw SpeakerOptimizerFIRDeploymentError
                .invalidConfiguration
        }

        if let verification,
           !verification.validate(deployment: self) {
            throw SpeakerOptimizerFIRDeploymentError
                .invalidConfiguration
        }

        let allowed = Set(
            profile.programLayout.roles.filter {
                $0 != .lowFrequencyEffects
            }
        )
        var maximumSourceReserve = 0.0
        for source in sources {
            guard allowed.contains(source.role),
                  profile.speakerAssignments.contains(where: {
                      $0.role == source.role
                  }),
                  !source.candidateFingerprint.isEmpty,
                  source.maximumPositiveGainDB.isFinite,
                  source.maximumPositiveGainDB >= 0,
                  source.maximumPositiveGainDB
                    <= Self.maximumHeadroomDB,
                  source.recommendedHeadroomDB.isFinite,
                  (0...Self.maximumHeadroomDB)
                    .contains(source.recommendedHeadroomDB),
                  source.recommendedHeadroomDB + 1.0e-8
                    >= source.maximumPositiveGainDB else {
                throw SpeakerOptimizerFIRDeploymentError
                    .invalidSource(source.role)
            }
            guard source.taps.count == tapCount,
                  source.taps.allSatisfy(\.isFinite),
                  source.taps.contains(where: {
                      abs($0) > 1.0e-12
                  }),
                  Self.isSymmetricLinearPhase(source.taps) else {
                throw SpeakerOptimizerFIRDeploymentError
                    .invalidTaps(source.role)
            }
            maximumSourceReserve = max(
                maximumSourceReserve,
                source.recommendedHeadroomDB
            )
        }
        guard abs(maximumSourceReserve - requiredHeadroomDB)
                <= 1.0e-8 else {
            throw SpeakerOptimizerFIRDeploymentError
                .invalidConfiguration
        }
    }

    func validateLiveSampleRate(_ actual: Double) throws {
        guard actual.isFinite, actual > 0,
              abs(actual - sampleRate) < 0.5 else {
            throw SpeakerOptimizerFIRDeploymentError
                .sampleRateMismatch(
                    expected: sampleRate,
                    actual: actual
                )
        }
    }

    func makeRuntimePreparation(
        programLayout: OutputProgramLayout
    ) throws -> SpeakerOptimizerFIRRuntimePreparation {
        let roles = programLayout.roles
        let byRole = Dictionary(
            uniqueKeysWithValues: sources.map { ($0.role, $0) }
        )
        var activeMask: UInt32 = 0
        var flattened: [Float] = []
        flattened.reserveCapacity(sources.count * tapCount)

        for (index, role) in roles.enumerated() {
            guard index < Int(N60_MAX_PROGRAM_CHANNELS) else {
                throw SpeakerOptimizerFIRDeploymentError
                    .runtimePreparationFailed
            }
            guard let source = byRole[role] else { continue }
            guard role != .lowFrequencyEffects else {
                throw SpeakerOptimizerFIRDeploymentError
                    .runtimePreparationFailed
            }
            activeMask |= UInt32(1) << UInt32(index)
            flattened.append(contentsOf: source.taps)
        }
        guard activeMask != 0,
              flattened.count == sources.count * tapCount else {
            throw SpeakerOptimizerFIRDeploymentError
                .runtimePreparationFailed
        }

        return SpeakerOptimizerFIRRuntimePreparation(
            activeChannelMask: activeMask,
            flattenedTaps: flattened,
            tapCount: UInt32(tapCount),
            declaredGroupDelayFrames:
                UInt32(declaredGroupDelayFrames),
            requiredHeadroomDB: requiredHeadroomDB
        )
    }

    private static func isSymmetricLinearPhase(
        _ taps: [Float]
    ) -> Bool {
        guard !taps.isEmpty else { return false }
        let peak = taps.reduce(Float.zero) {
            max($0, abs($1))
        }
        let tolerance = max(1.0e-6, peak * 2.0e-5)
        for index in 0..<(taps.count / 2) {
            if abs(taps[index] - taps[taps.count - 1 - index])
                > tolerance {
                return false
            }
        }
        return true
    }
}
