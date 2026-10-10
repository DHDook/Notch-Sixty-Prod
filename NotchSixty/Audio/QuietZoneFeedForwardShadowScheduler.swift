import Foundation

/// PR98 time references come from a separately calibrated instrument.
/// A HAL callback timestamp is NOT proof of acoustic launch or DAC arrival.
struct QuietZoneFeedForwardOutputClockAnchor: Sendable {
    let outputDeviceID: String
    let routeLeaseID: String
    let synchronizedClockID: String
    let sampleRate: Double
    let firstOutputSampleFrame: Double
    let firstOutputSampleHostSeconds: Double
    let observedAtHostSeconds: Double
}

struct QuietZoneFeedForwardReferenceDeadlineEvent: Sendable {
    let referenceSampleFrame: Double
    let referenceAcousticHostSeconds: Double
    let referenceAvailableHostSeconds: Double
    let evaluatedAtHostSeconds: Double
    let microphoneSample: Float
}

enum QuietZoneFeedForwardSchedulingError: Error, Equatable, LocalizedError {
    case invalidPlan, nonCausal, wrongRoute, invalidReference
    case staleOutputClock, discontinuity, missedDeadline, disabled

    var errorDescription: String? {
        switch self {
        case .invalidPlan: return "The physical timing plan and FIR are incompatible."
        case .nonCausal: return "Conservative measured lead cannot meet the safety reserve."
        case .wrongRoute: return "The selected output device, clock or route lease changed."
        case .invalidReference: return "Reference frame or acquisition time is not credible."
        case .staleOutputClock: return "The output callback clock witness is invalid or stale."
        case .discontinuity: return "The input stream or output frame timeline skipped or reversed."
        case .missedDeadline: return "The required physical output command deadline has passed."
        case .disabled: return "The shadow scheduler is stopped."
        }
    }
}

/// A planned command deadline, never a control authorization or DAC command.
struct QuietZoneFeedForwardSchedulingPlan: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let conservativeNoiseLeadSeconds: Double
    let acquisitionLatencySeconds: Double
    let processingLatencySeconds: Double
    let commandToSeatLatencySeconds: Double
    let deadlineGuardSeconds: Double
    var liveDeploymentAuthorized: Bool { false }

    init(
        rig: QuietZoneHardwareCalibrationRig,
        report: QuietZonePhysicalLatencyReport
    ) throws {
        guard report.readiness == .physicallyPlausible,
              report.lowerBoundNoiseLeadSeconds.isFinite,
              report.lowerBoundNoiseLeadSeconds > 0,
              report.spareAfterSafetyReserveSeconds.isFinite,
              report.spareAfterSafetyReserveSeconds >= 0,
              report.stageEvidence.count == 4,
              rig.sampleRate.isFinite, rig.sampleRate >= 8_000 else {
            throw QuietZoneFeedForwardSchedulingError.nonCausal
        }
        var byStage: [QuietZonePhysicalLatencyStage: QuietZonePhysicalLatencyEvidence] = [:]
        for stage in report.stageEvidence {
            guard byStage[stage.stage] == nil,
                  stage.microphoneDeviceID == rig.microphoneID,
                  stage.microphoneChannel == rig.microphoneChannel,
                  stage.outputDeviceID == rig.outputDeviceID,
                  stage.routeLeaseID == rig.routeID,
                  stage.synchronizedClockID == rig.clockID,
                  stage.sampleRate.isFinite,
                  abs(stage.sampleRate - rig.sampleRate) < 0.5,
                  stage.measuredLatencySeconds.isFinite,
                  stage.measuredLatencySeconds > 0 else {
                throw QuietZoneFeedForwardSchedulingError.invalidPlan
            }
            byStage[stage.stage] = stage
        }
        guard let adc = byStage[.referenceADC],
              let dsp = byStage[.referenceProcessing],
              let dac = byStage[.outputDAC],
              let acoustic = byStage[.speakerToSeat],
              report.nominalPathSeconds.isFinite,
              report.upperBoundPathSeconds.isFinite,
              report.requiredSafetyReserveSeconds.isFinite,
              report.upperBoundPathSeconds >= report.nominalPathSeconds,
              report.requiredSafetyReserveSeconds > 0,
              abs(report.nominalPathSeconds
                  - adc.measuredLatencySeconds - dsp.measuredLatencySeconds
                  - dac.measuredLatencySeconds - acoustic.measuredLatencySeconds
              ) < 1.0e-8 else {
            throw QuietZoneFeedForwardSchedulingError.invalidPlan
        }
        // PR97's upper-minus-nominal path ALREADY includes worst-case jitter
        // and 3σ uncertainty. Charge it exactly once plus required safety.
        let guardTime = report.requiredSafetyReserveSeconds
            + report.upperBoundPathSeconds - report.nominalPathSeconds
        let seat = dac.measuredLatencySeconds + acoustic.measuredLatencySeconds
        guard guardTime.isFinite, guardTime >= 0,
              report.lowerBoundNoiseLeadSeconds
                > adc.measuredLatencySeconds + dsp.measuredLatencySeconds
                + seat + guardTime else {
            throw QuietZoneFeedForwardSchedulingError.nonCausal
        }
        self.rig = rig
        conservativeNoiseLeadSeconds = report.lowerBoundNoiseLeadSeconds
        acquisitionLatencySeconds = adc.measuredLatencySeconds
        processingLatencySeconds = dsp.measuredLatencySeconds
        commandToSeatLatencySeconds = seat
        deadlineGuardSeconds = guardTime
    }
}

struct QuietZoneFeedForwardScheduledPreview: Sendable {
    let referenceFrame: Double
    let plannedOutputFrame: Int64
    let latestCommandHostSeconds: Double
    let processingSlackSeconds: Double
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false
}

struct QuietZoneFeedForwardShadowSnapshot: Sendable {
    let scheduledReferenceFrames: Int
    let lastPlannedOutputFrame: Int64?
    let minimumProcessingSlackSeconds: Double?
    let faults: Int
    let stopped: Bool
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false
}

/// Standalone **control-plane** output-deadline simulator. The FIR is reused
/// from PR96, but its stereo samples are discarded; neither they nor the
/// planned frame indices are submitted to production playback.
final class QuietZoneFeedForwardShadowScheduler {
    static let maximumClockAgeSeconds = 0.050
    static let maximumAnchorDifferenceSeconds = 0.050
    static let maximumAcquisitionResidualSeconds = 0.002
    static let maximumOutputFrame = 1_000_000_000_000.0
    static let frameContinuityTolerance = 0.05

    private let plan: QuietZoneFeedForwardSchedulingPlan
    private var fir: OpaquePointer?
    private var previousInputFrame: Double?
    private var previousAcousticHostSeconds: Double?
    private var previousOutputFrame: Int64?
    private var previousEvaluation: Double?
    private var minimumSlack: Double?
    private var accepted = 0
    private var faultCount = 0
    private var stopped = false

    init(
        plan: QuietZoneFeedForwardSchedulingPlan,
        candidate: QuietZoneCausalFIRCandidate
    ) throws {
        guard candidate.sampleRate.isFinite,
              abs(candidate.sampleRate - plan.rig.sampleRate) < 0.5,
              !candidate.leftTaps.isEmpty,
              candidate.leftTaps.count == candidate.rightTaps.count,
              candidate.leftTaps.count <= QuietZoneCausalFIRCompiler.maximumTaps else {
            throw QuietZoneFeedForwardSchedulingError.invalidPlan
        }
        guard let engine = N60FeedForwardPreviewFIRCreate() else {
            throw QuietZoneFeedForwardSchedulingError.invalidPlan
        }
        let configured = candidate.leftTaps.withUnsafeBufferPointer { l in
            candidate.rightTaps.withUnsafeBufferPointer { r in
                N60FeedForwardPreviewFIRConfigure(
                    engine, l.baseAddress!, r.baseAddress!, UInt32(l.count)
                )
            }
        }
        guard configured else {
            N60FeedForwardPreviewFIRDestroy(engine)
            throw QuietZoneFeedForwardSchedulingError.invalidPlan
        }
        self.plan = plan
        self.fir = engine
    }

    deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let fir {
            N60FeedForwardPreviewFIRReset(fir)
            N60FeedForwardPreviewFIRDestroy(fir)
            self.fir = nil
        }
    }

    private func fail(_ error: QuietZoneFeedForwardSchedulingError) throws -> Never {
        faultCount += 1
        stop()
        throw error
    }

    /// Call ONLY off the audio callback. Every timestamp must already be
    /// translated to the same physical host-second timebase. The active
    /// system does not yet provide that translation or attest its accuracy.
    func schedule(
        _ event: QuietZoneFeedForwardReferenceDeadlineEvent,
        output: QuietZoneFeedForwardOutputClockAnchor
    ) throws -> QuietZoneFeedForwardScheduledPreview {
        guard !stopped, let fir else {
            throw QuietZoneFeedForwardSchedulingError.disabled
        }
        let sr = plan.rig.sampleRate
        guard output.outputDeviceID == plan.rig.outputDeviceID,
              output.routeLeaseID == plan.rig.routeID,
              output.synchronizedClockID == plan.rig.clockID,
              output.sampleRate.isFinite,
              abs(output.sampleRate - sr) < 0.5 else {
            try fail(.wrongRoute)
        }
        let times = [
            event.referenceSampleFrame, event.referenceAcousticHostSeconds,
            event.referenceAvailableHostSeconds, event.evaluatedAtHostSeconds,
            output.firstOutputSampleFrame,
            output.firstOutputSampleHostSeconds,
            output.observedAtHostSeconds
        ]
        guard times.allSatisfy(\.isFinite),
              event.referenceSampleFrame >= 0,
              event.referenceAcousticHostSeconds >= 0,
              event.referenceAvailableHostSeconds >= event.referenceAcousticHostSeconds,
              event.evaluatedAtHostSeconds >= event.referenceAvailableHostSeconds,
              event.microphoneSample.isFinite,
              abs(event.microphoneSample) <= 1 else {
            try fail(.invalidReference)
        }
        guard event.referenceAvailableHostSeconds
                - event.referenceAcousticHostSeconds
                <= plan.acquisitionLatencySeconds
                    + Self.maximumAcquisitionResidualSeconds else {
            try fail(.invalidReference)
        }
        guard event.evaluatedAtHostSeconds >= output.observedAtHostSeconds,
              event.evaluatedAtHostSeconds - output.observedAtHostSeconds
                <= Self.maximumClockAgeSeconds,
              abs(output.firstOutputSampleHostSeconds
                    - output.observedAtHostSeconds)
                <= Self.maximumAnchorDifferenceSeconds,
              output.firstOutputSampleFrame >= 0,
              output.firstOutputSampleFrame <= Self.maximumOutputFrame else {
            try fail(.staleOutputClock)
        }
        if let previousFrame = previousInputFrame,
           let previousTime = previousAcousticHostSeconds {
            guard abs(event.referenceSampleFrame - previousFrame - 1)
                    <= Self.frameContinuityTolerance,
                  abs((event.referenceAcousticHostSeconds - previousTime) * sr - 1)
                    <= Self.frameContinuityTolerance,
                  previousEvaluation.map({
                      event.evaluatedAtHostSeconds >= $0
                  }) ?? false else {
                try fail(.discontinuity)
            }
        }

        let deadline = event.referenceAcousticHostSeconds
            + plan.conservativeNoiseLeadSeconds
            - plan.commandToSeatLatencySeconds
            - plan.deadlineGuardSeconds
        let earliestCompletion = max(
            event.evaluatedAtHostSeconds,
            event.referenceAvailableHostSeconds + plan.processingLatencySeconds
        )
        guard deadline.isFinite, deadline > earliestCompletion else {
            try fail(.missedDeadline)
        }
        // Floor to a sample frame no later than the conservatively safe
        // command deadline. A rounding step must not consume processing slack.
        let mapped = output.firstOutputSampleFrame
            + floor((deadline - output.firstOutputSampleHostSeconds) * sr)
        guard mapped.isFinite, mapped >= 0,
              mapped <= Self.maximumOutputFrame else {
            try fail(.staleOutputClock)
        }
        let frame = Int64(mapped)
        let actualFrameTime = output.firstOutputSampleHostSeconds
            + (mapped - output.firstOutputSampleFrame) / sr
        guard actualFrameTime <= deadline,
              actualFrameTime >= earliestCompletion,
              previousOutputFrame.map({ frame > $0 }) ?? true else {
            try fail(.missedDeadline)
        }

        var discardedLeft: Float = 0
        var discardedRight: Float = 0
        N60FeedForwardPreviewFIRProcessFrame(
            fir, event.microphoneSample, &discardedLeft, &discardedRight
        )
        guard discardedLeft.isFinite, discardedRight.isFinite else {
            try fail(.invalidReference)
        }
        let slack = actualFrameTime - earliestCompletion
        accepted += 1
        minimumSlack = min(minimumSlack ?? slack, slack)
        previousInputFrame = event.referenceSampleFrame
        previousAcousticHostSeconds = event.referenceAcousticHostSeconds
        previousOutputFrame = frame
        previousEvaluation = event.evaluatedAtHostSeconds
        return .init(
            referenceFrame: event.referenceSampleFrame,
            plannedOutputFrame: frame,
            latestCommandHostSeconds: actualFrameTime,
            processingSlackSeconds: slack
        )
    }

    func snapshot() -> QuietZoneFeedForwardShadowSnapshot {
        .init(
            scheduledReferenceFrames: accepted,
            lastPlannedOutputFrame: previousOutputFrame,
            minimumProcessingSlackSeconds: minimumSlack,
            faults: faultCount,
            stopped: stopped
        )
    }
}
