import Foundation

enum SpeakerOptimizerFIRAVSyncContext:
    Equatable, Sendable {
    case audioOnly
    /// Notch Sixty does not delay system video. A synchronized-video workflow
    /// must explicitly declare how much video-delay capacity exists elsewhere
    /// (player, AVR, display, etc.). Nil means no verified compensation path.
    case synchronizedVideo(
        externalVideoDelayCapacityMilliseconds: Double?
    )
}

enum SpeakerOptimizerFIRAVSyncStatus:
    String, Codable, Equatable, Sendable {
    case audioOnlyAllowed
    case externalVideoDelayAvailable
    case externalVideoDelayRequired
    case externalVideoDelayInsufficient
}

struct SpeakerOptimizerFIRAVSyncDecision:
    Equatable, Sendable {
    var context: SpeakerOptimizerFIRAVSyncContext
    var status: SpeakerOptimizerFIRAVSyncStatus
    /// Program-path latency represented by the FIR/lane plan. A live transport
    /// may add further latency (Audio Units, adaptive SRC, room treatment, I/O).
    var programPathLatencyFrames: UInt64
    var incrementalFIRLatencyFrames: UInt64
    var sampleRate: Double
    /// Exact video delay needed to align video to this program-path latency.
    var requiredVideoDelayMilliseconds: Double
    var incrementalFIRLatencyMilliseconds: Double
    var externalVideoDelayCapacityMilliseconds: Double?

    var canUseFIRForContext: Bool {
        status == .audioOnlyAllowed
            || status == .externalVideoDelayAvailable
    }

    var requiresExternalVideoDelay: Bool {
        switch context {
        case .audioOnly:
            return false
        case .synchronizedVideo:
            return programPathLatencyFrames > 0
        }
    }

    var explanation: String {
        switch status {
        case .audioOnlyAllowed:
            return "Speaker Optimizer FIR is allowed for audio-only playback. No video synchronization claim is made."
        case .externalVideoDelayAvailable:
            return "Synchronized-video use is allowed only through the declared external video-delay path; configure it to the reported required delay."
        case .externalVideoDelayRequired:
            return "Speaker Optimizer FIR adds audio-path latency, and no verified external video-delay path was declared. Synchronized-video use remains blocked."
        case .externalVideoDelayInsufficient:
            return "The declared external video-delay capacity is smaller than the required audio-path delay. Synchronized-video use remains blocked."
        }
    }
}

enum SpeakerOptimizerFIRAVSyncError:
    Error, Equatable, LocalizedError {
    case invalidSampleRate
    case invalidLatency
    case invalidExternalVideoDelayCapacity

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "A/V synchronization assessment requires a finite positive sample rate."
        case .invalidLatency:
            return "A/V synchronization assessment received an invalid audio-path latency."
        case .invalidExternalVideoDelayCapacity:
            return "External video-delay capacity must be finite and nonnegative when supplied."
        }
    }
}

/// PR107 A/V boundary.
///
/// This policy never attempts to delay macOS/system video. It only reports the
/// exact program-path delay created by the FIR/lane contract and determines
/// whether an explicitly declared external video-delay path has enough range.
struct SpeakerOptimizerFIRAVSyncPolicy: Sendable {
    func assess(
        plan: SpeakerOptimizerFIRLatencyPlan,
        context: SpeakerOptimizerFIRAVSyncContext
    ) throws -> SpeakerOptimizerFIRAVSyncDecision {
        try assess(
            programPathLatencyFrames:
                UInt64(plan.maximumEndToEndProgramLatencyFrames),
            incrementalFIRLatencyFrames:
                UInt64(plan.addedFIRLatencyFrames),
            sampleRate: plan.sampleRate,
            context: context
        )
    }

    func assess(
        deployment: SpeakerOptimizerFIRDeploymentConfiguration,
        profile: OutputDeviceProfileConfiguration,
        bassManagementEnabled: Bool,
        context: SpeakerOptimizerFIRAVSyncContext
    ) throws -> SpeakerOptimizerFIRAVSyncDecision {
        let plan = try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: profile,
            bassManagementEnabled: bassManagementEnabled,
            sampleRate: deployment.sampleRate,
            tapCount: deployment.tapCount,
            declaredGroupDelayFrames:
                UInt32(deployment.declaredGroupDelayFrames),
            correctedRoles: deployment.correctedRoles
        )
        return try assess(plan: plan, context: context)
    }

    func assess(
        programPathLatencyFrames: UInt64,
        incrementalFIRLatencyFrames: UInt64,
        sampleRate: Double,
        context: SpeakerOptimizerFIRAVSyncContext
    ) throws -> SpeakerOptimizerFIRAVSyncDecision {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerOptimizerFIRAVSyncError
                .invalidSampleRate
        }
        guard incrementalFIRLatencyFrames
                <= programPathLatencyFrames else {
            throw SpeakerOptimizerFIRAVSyncError
                .invalidLatency
        }

        let programMilliseconds =
            Double(programPathLatencyFrames)
                / sampleRate * 1_000
        let firMilliseconds =
            Double(incrementalFIRLatencyFrames)
                / sampleRate * 1_000
        guard programMilliseconds.isFinite,
              firMilliseconds.isFinite else {
            throw SpeakerOptimizerFIRAVSyncError
                .invalidLatency
        }

        let status: SpeakerOptimizerFIRAVSyncStatus
        let externalCapacity: Double?
        switch context {
        case .audioOnly:
            status = .audioOnlyAllowed
            externalCapacity = nil

        case .synchronizedVideo(let supplied):
            if let supplied {
                guard supplied.isFinite, supplied >= 0 else {
                    throw SpeakerOptimizerFIRAVSyncError
                        .invalidExternalVideoDelayCapacity
                }
                externalCapacity = supplied
                status = supplied + 1.0e-9
                    >= programMilliseconds
                    ? .externalVideoDelayAvailable
                    : .externalVideoDelayInsufficient
            } else {
                externalCapacity = nil
                status = programPathLatencyFrames == 0
                    ? .externalVideoDelayAvailable
                    : .externalVideoDelayRequired
            }
        }

        return SpeakerOptimizerFIRAVSyncDecision(
            context: context,
            status: status,
            programPathLatencyFrames:
                programPathLatencyFrames,
            incrementalFIRLatencyFrames:
                incrementalFIRLatencyFrames,
            sampleRate: sampleRate,
            requiredVideoDelayMilliseconds:
                programMilliseconds,
            incrementalFIRLatencyMilliseconds:
                firMilliseconds,
            externalVideoDelayCapacityMilliseconds:
                externalCapacity
        )
    }
}
