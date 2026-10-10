import Foundation

/// PR98: offline reference-microphone echo reconstruction from separately
/// captured L/R speaker-to-microphone impulse responses. This code neither
/// reads Core Audio callbacks nor writes into an audio output path.
enum QuietZoneReferenceEchoError: Error, Equatable, LocalizedError {
    case incompatibleRig
    case invalidCapture
    case expiredModel
    case frameDiscontinuity
    case implausibleEcho
    case invalidProbe
    case updateExceedsEnvelope
    case noValidationImprovement
    case stopped

    var errorDescription: String? {
        switch self {
        case .incompatibleRig: return "The reference, playback route or candidate changed."
        case .invalidCapture: return "Offline microphone or speaker samples are invalid."
        case .expiredModel: return "The speaker-to-reference measurements have expired."
        case .frameDiscontinuity: return "Speaker and microphone sample frames are not aligned."
        case .implausibleEcho: return "The reconstructed echo is not consistent with the reference."
        case .invalidProbe: return "Adaptive proposals require two independent, isolated speaker-only probes."
        case .updateExceedsEnvelope: return "The proposed speaker path exceeds a measured uncertainty or feedback bound."
        case .noValidationImprovement: return "A model update did not improve independent probe validation."
        case .stopped: return "This offline echo simulation stopped permanently."
        }
    }
}

struct QuietZoneReferenceEchoModel: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let candidate: QuietZoneCausalFIRCandidate
    let stability: QuietZoneReferenceLeakageStabilityReport
    let leftSpeakerToReference: [Double]
    let rightSpeakerToReference: [Double]
    /// Maximum admissible deviation from EACH nominal impulse tap.
    let leftTapDeviationBounds: [Double]
    let rightTapDeviationBounds: [Double]
    let capturedAt: Date
    let independentSourceLaunchIDs: Set<String>
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false
}

struct QuietZoneReferenceEchoModelBuilder: Sendable {
    func build(
        candidate: QuietZoneCausalFIRCandidate,
        rig: QuietZoneHardwareCalibrationRig,
        captures: [QuietZoneReferenceLeakageCapture],
        now: Date
    ) throws -> QuietZoneReferenceEchoModel {
        let report = try QuietZoneReferenceLeakageStabilityAnalyzer().assess(
            candidate: candidate, rig: rig, captures: captures, now: now
        )
        func compile(_ side: QuietZoneLeakageSpeaker)
            -> (taps: [Double], bounds: [Double]) {
            let series = captures.filter { $0.speaker == side }
            let count = series[0].impulseResponse.count
            var taps = [Double](repeating: 0, count: count)
            var bounds = [Double](repeating: 0, count: count)
            for t in 0..<count {
                let mean = series.reduce(0) {
                    $0 + $1.impulseResponse[t]
                } / Double(series.count)
                let deviation = series.map {
                    abs($0.impulseResponse[t] - mean)
                }.max() ?? 0
                let sigma = series.map { $0.oneSigmaError[t] }.max() ?? 0
                taps[t] = mean
                bounds[t] = deviation
                    + QuietZoneReferenceLeakageStabilityAnalyzer.errorSigmaMultiplier
                    * sigma
            }
            return (taps, bounds)
        }
        let left = compile(.left)
        let right = compile(.right)
        return .init(
            rig: rig, candidate: candidate, stability: report,
            leftSpeakerToReference: left.taps,
            rightSpeakerToReference: right.taps,
            leftTapDeviationBounds: left.bounds,
            rightTapDeviationBounds: right.bounds,
            capturedAt: captures.map(\.capturedAt).max() ?? now,
            independentSourceLaunchIDs: Set(captures.map(\.launchID))
        )
    }
}

struct QuietZoneReferenceEchoOfflineBlock: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let capturedAt: Date
    /// Physical sample indices must already be translated to ONE calibrated
    /// common clock. These fields alone DO NOT establish synchronization.
    let microphoneStartFrame: Int64
    let speakerStartFrame: Int64
    let microphone: [Float]
    let leftSpeaker: [Float]
    let rightSpeaker: [Float]
}

struct QuietZoneReferenceEchoOfflineResult: Sendable {
    let firstFrame: Int64
    let predictedSpeakerEcho: [Float]
    let previewDecontaminatedReference: [Float]
    let rawReferenceMeanSquare: Double
    let residualMeanSquare: Double
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false
}

/// Single-owner, offline-only convolution, isolated from the realtime path.
/// Failures revoke the session, never returning partial cleaned microphone
/// data. There is no adaptive model update or speaker output in process().
final class QuietZoneReferenceEchoOfflineSimulator {
    static let maximumFramesPerBlock = 4_096
    private let model: QuietZoneReferenceEchoModel
    private var lastFrame: Int64?
    private var leftHistory: [Double]
    private var rightHistory: [Double]
    private var leftCursor = 0
    private var rightCursor = 0
    private(set) var stopped = false

    init(model: QuietZoneReferenceEchoModel) {
        self.model = model
        leftHistory = .init(repeating: 0, count: model.leftSpeakerToReference.count)
        rightHistory = .init(repeating: 0, count: model.rightSpeakerToReference.count)
    }

    func close() {
        stopped = true
        lastFrame = nil
        leftHistory = .init(repeating: 0, count: leftHistory.count)
        rightHistory = .init(repeating: 0, count: rightHistory.count)
    }

    private func fail(_ error: QuietZoneReferenceEchoError) throws -> Never {
        close()
        throw error
    }

    func process(
        _ block: QuietZoneReferenceEchoOfflineBlock
    ) throws -> QuietZoneReferenceEchoOfflineResult {
        guard !stopped else { throw QuietZoneReferenceEchoError.stopped }
        guard block.rig == model.rig else { try fail(.incompatibleRig) }
        let age = block.capturedAt.timeIntervalSince(model.capturedAt)
        guard age.isFinite, age >= 0,
              age <= QuietZoneReferenceLeakageStabilityAnalyzer.maximumCaptureAge
        else { try fail(.expiredModel) }
        let n = block.microphone.count
        guard n > 0, n <= Self.maximumFramesPerBlock,
              block.leftSpeaker.count == n,
              block.rightSpeaker.count == n,
              block.microphone.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              block.leftSpeaker.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              block.rightSpeaker.allSatisfy({ $0.isFinite && abs($0) <= 1 })
        else { try fail(.invalidCapture) }
        guard block.microphoneStartFrame >= 0,
              block.speakerStartFrame == block.microphoneStartFrame,
              block.microphoneStartFrame <= Int64.max - Int64(n),
              lastFrame.map({ block.microphoneStartFrame == $0 }) ?? true
        else { try fail(.frameDiscontinuity) }

        var predicted = [Float]()
        var cleaned = [Float]()
        predicted.reserveCapacity(n)
        cleaned.reserveCapacity(n)
        var rawEnergy = 0.0
        var residualEnergy = 0.0
        for i in 0..<n {
            leftHistory[leftCursor] = Double(block.leftSpeaker[i])
            rightHistory[rightCursor] = Double(block.rightSpeaker[i])
            var echo = 0.0
            for t in model.leftSpeakerToReference.indices {
                let idx = (leftCursor + leftHistory.count - t) % leftHistory.count
                echo += leftHistory[idx] * model.leftSpeakerToReference[t]
            }
            for t in model.rightSpeakerToReference.indices {
                let idx = (rightCursor + rightHistory.count - t) % rightHistory.count
                echo += rightHistory[idx] * model.rightSpeakerToReference[t]
            }
            guard echo.isFinite, abs(echo) <= 1 else {
                try fail(.implausibleEcho)
            }
            let residual = Double(block.microphone[i]) - echo
            guard residual.isFinite, abs(residual) <= 1 else {
                try fail(.implausibleEcho)
            }
            predicted.append(Float(echo))
            cleaned.append(Float(residual))
            rawEnergy += Double(block.microphone[i]) * Double(block.microphone[i])
            residualEnergy += residual * residual
            leftCursor = (leftCursor + 1) % leftHistory.count
            rightCursor = (rightCursor + 1) % rightHistory.count
        }
        lastFrame = block.microphoneStartFrame + Int64(n)
        return .init(
            firstFrame: block.microphoneStartFrame,
            predictedSpeakerEcho: predicted,
            previewDecontaminatedReference: cleaned,
            rawReferenceMeanSquare: rawEnergy / Double(n),
            residualMeanSquare: residualEnergy / Double(n)
        )
    }

    var outputConnected: Bool { false }
    var liveANCQualified: Bool { false }
}

/// Isolated, source-silent speaker probe. A boolean claimed by a caller
/// does not itself attest no party speech; physical review remains required.
struct QuietZoneReferenceEchoAdaptationProbe: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let eventID: String
    let capturedAt: Date
    let sourceIsSilent: Bool
    let microphone: [Float]
    let leftSpeaker: [Float]
    let rightSpeaker: [Float]
}

struct QuietZoneReferenceEchoAdaptationProposal: Sendable {
    let leftTaps: [Double]
    let rightTaps: [Double]
    let baselineValidationMSE: Double
    let proposedValidationMSE: Double
    let proposedConservativeFeedbackL1: Double
    let validationImprovementFraction: Double
    let previewOnly: Bool = true
    let automaticallyApplied: Bool = false
    let liveANCQualified: Bool = false
}

/// Non-mutating coefficient PROPOSAL based on separate training/validation
/// bursts. Normalized, regularized block gradient with strict coefficient,
/// uncertainty and small-gain checks. No continuous NLMS in audio callbacks.
struct QuietZoneReferenceEchoAdaptationGuard: Sendable {
    static let maximumProbeFrames = 4_096
    static let maximumStepSize = 0.2
    static let maximumTotalTapAdjustment = 0.002
    static let minimumValidationImprovement = 0.01

    func propose(
        model: QuietZoneReferenceEchoModel,
        training: QuietZoneReferenceEchoAdaptationProbe,
        validation: QuietZoneReferenceEchoAdaptationProbe,
        stepSize: Double = 0.1,
        now: Date
    ) throws -> QuietZoneReferenceEchoAdaptationProposal {
        guard stepSize.isFinite, stepSize > 0,
              stepSize <= Self.maximumStepSize,
              training.rig == model.rig, validation.rig == model.rig,
              training.sourceIsSilent, validation.sourceIsSilent,
              !training.eventID.isEmpty, !validation.eventID.isEmpty,
              training.eventID != validation.eventID,
              !model.independentSourceLaunchIDs.contains(training.eventID),
              !model.independentSourceLaunchIDs.contains(validation.eventID),
              training.capturedAt < validation.capturedAt,
              now.timeIntervalSince(validation.capturedAt) >= 0,
              now.timeIntervalSince(training.capturedAt)
                <= QuietZoneReferenceLeakageStabilityAnalyzer.maximumCaptureAge,
              now.timeIntervalSince(model.capturedAt)
                <= QuietZoneReferenceLeakageStabilityAnalyzer.maximumCaptureAge
        else { throw QuietZoneReferenceEchoError.invalidProbe }

        func validate(_ p: QuietZoneReferenceEchoAdaptationProbe) throws {
            let n = p.microphone.count
            guard n >= 64, n <= Self.maximumProbeFrames,
                  p.leftSpeaker.count == n, p.rightSpeaker.count == n,
                  p.microphone.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
                  p.leftSpeaker.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
                  p.rightSpeaker.allSatisfy({ $0.isFinite && abs($0) <= 1 })
            else { throw QuietZoneReferenceEchoError.invalidProbe }
        }
        try validate(training)
        try validate(validation)

        func predicted(
            _ p: QuietZoneReferenceEchoAdaptationProbe,
            left: [Double], right: [Double]
        ) -> (residual: [Double], mse: Double) {
            var errors = [Double]()
            errors.reserveCapacity(p.microphone.count)
            var energy = 0.0
            for n in p.microphone.indices {
                var echo = 0.0
                for t in left.indices where t <= n {
                    echo += left[t] * Double(p.leftSpeaker[n - t])
                }
                for t in right.indices where t <= n {
                    echo += right[t] * Double(p.rightSpeaker[n - t])
                }
                let error = Double(p.microphone[n]) - echo
                errors.append(error)
                energy += error * error
            }
            return (errors, energy / Double(p.microphone.count))
        }

        let baseline = predicted(
            training, left: model.leftSpeakerToReference,
            right: model.rightSpeakerToReference
        )
        guard baseline.mse.isFinite else {
            throw QuietZoneReferenceEchoError.invalidProbe
        }

        func updated(
            speaker: [Float], original: [Double],
            permitted: [Double]
        ) throws -> [Double] {
            var proposed = original
            var total = 0.0
            for t in proposed.indices {
                var gradient = 0.0
                var energy = 1.0e-8
                for n in t..<speaker.count {
                    let x = Double(speaker[n - t])
                    gradient += x * baseline.residual[n]
                    energy += x * x
                }
                let change = stepSize * gradient / energy
                guard change.isFinite,
                      abs(change) <= Self.maximumTotalTapAdjustment,
                      abs(change) <= permitted[t] else {
                    throw QuietZoneReferenceEchoError.updateExceedsEnvelope
                }
                total += abs(change)
                proposed[t] += change
            }
            guard total <= Self.maximumTotalTapAdjustment else {
                throw QuietZoneReferenceEchoError.updateExceedsEnvelope
            }
            return proposed
        }
        let l = try updated(
            speaker: training.leftSpeaker,
            original: model.leftSpeakerToReference,
            permitted: model.leftTapDeviationBounds
        )
        let r = try updated(
            speaker: training.rightSpeaker,
            original: model.rightSpeakerToReference,
            permitted: model.rightTapDeviationBounds
        )
        let coupled = l.reduce(0) { $0 + abs($1) }
            * model.stability.candidateLeftL1Gain
            + r.reduce(0) { $0 + abs($1) }
            * model.stability.candidateRightL1Gain
        guard coupled.isFinite,
              coupled <= QuietZoneReferenceLeakageStabilityAnalyzer
                .maximumConservativeLoopGain,
              zip(l, model.leftSpeakerToReference).enumerated().allSatisfy {
                  abs($0.element.0 - $0.element.1)
                    <= model.leftTapDeviationBounds[$0.offset]
              },
              zip(r, model.rightSpeakerToReference).enumerated().allSatisfy {
                  abs($0.element.0 - $0.element.1)
                    <= model.rightTapDeviationBounds[$0.offset]
              }
        else { throw QuietZoneReferenceEchoError.updateExceedsEnvelope }

        let before = predicted(
            validation, left: model.leftSpeakerToReference,
            right: model.rightSpeakerToReference
        ).mse
        let after = predicted(validation, left: l, right: r).mse
        guard before.isFinite, after.isFinite, before > 1.0e-12,
              after >= 0, after <= before * (1 - Self.minimumValidationImprovement)
        else { throw QuietZoneReferenceEchoError.noValidationImprovement }
        // Includes the previously measured uncertainty envelope, rather
        // than granting fresh confidence to unreviewed adaptive coefficients.
        let inflated = model.stability.conservativeFeedbackLoopL1
            + zip(l, model.leftSpeakerToReference).reduce(0.0) {
                $0 + abs($1.0 - $1.1)
            } * model.stability.candidateLeftL1Gain
            + zip(r, model.rightSpeakerToReference).reduce(0.0) {
                $0 + abs($1.0 - $1.1)
            } * model.stability.candidateRightL1Gain
        guard inflated.isFinite,
              inflated <= QuietZoneReferenceLeakageStabilityAnalyzer
                .maximumConservativeLoopGain
        else { throw QuietZoneReferenceEchoError.updateExceedsEnvelope }
        return .init(
            leftTaps: l, rightTaps: r,
            baselineValidationMSE: before, proposedValidationMSE: after,
            proposedConservativeFeedbackL1: inflated,
            validationImprovementFraction: (before - after) / before
        )
    }
}
