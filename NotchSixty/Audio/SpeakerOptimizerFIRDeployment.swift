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
        // Slice 1 is planning/validation only. A later PR107 slice owns the
        // per-program-channel convolver runtime and transactional Apply path.
        false
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
              tapCount <= Int(N60_CONVOLUTION_MAX_TAPS),
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
