import Foundation

/// A separate speaker excitation is required for each repeated reference
/// microphone leakage measurement. Any supplied samples remain UNATTESTED
/// until the physical rig and witness instrument are independently reviewed.
enum QuietZoneLeakageSpeaker: String, Codable, Sendable {
    case left, right
}

struct QuietZoneReferenceLeakageCapture: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let speaker: QuietZoneLeakageSpeaker
    let sourceFixtureID: String
    let launchID: String
    let capturedAt: Date
    let measuredCoherence: Double
    let impulseResponse: [Double]
    /// A separately estimated 1σ amplitude bound for EACH FIR tap.
    let oneSigmaError: [Double]
}

enum QuietZoneReferenceLeakageError: Error, Equatable, LocalizedError {
    case invalidCandidate
    case incompleteRepetitions
    case untrustedRoute
    case staleEvidence
    case invalidMeasurements
    case insufficientCoherence
    case inconsistentCaptures
    case excessiveFeedbackBound

    var errorDescription: String? {
        switch self {
        case .invalidCandidate:
            return "The causal FIR candidate is invalid or exceeds the output budget."
        case .incompleteRepetitions:
            return "Three independent speaker-to-reference captures per channel are required."
        case .untrustedRoute:
            return "The input microphone, DAC, fixture, clock or output lease differs from the calibration rig."
        case .staleEvidence:
            return "Leakage captures are expired, out of session, or in the future."
        case .invalidMeasurements:
            return "Leakage impulse responses, repeat uncertainties or coherence are invalid."
        case .insufficientCoherence:
            return "Repeated speaker leakage measurements are not coherent enough."
        case .inconsistentCaptures:
            return "Speaker leakage changed too much between independent repetitions."
        case .excessiveFeedbackBound:
            return "The worst-case coupled speaker-to-reference loop exceeds the conservative safety cap."
        }
    }
}

struct QuietZoneReferenceLeakageStabilityReport: Sendable {
    let leftPathUpperL1Gain: Double
    let rightPathUpperL1Gain: Double
    let candidateLeftL1Gain: Double
    let candidateRightL1Gain: Double
    let conservativeFeedbackLoopL1: Double
    let conservativeSmallGainMargin: Double
    let minimumCoherence: Double
    let uniquePhysicalLaunchCount: Int
    let worstRepeatDeviation: Double
    let capturesFromRig: QuietZoneHardwareCalibrationRig

    // An L1 small-gain test is a sufficient stability bound for an LTI model
    // ONLY IF its impulse responses and uncertainty covers reality.
    // No signed report, physical installation or live control is certified.
    let echoCancellerEnabled: Bool = false
    let acousticFeedbackVerified: Bool = false
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false

    var reviewText: String {
        [
            "PR98 — reference microphone feedback stability preflight",
            String(format: "Left path conservative L1: %.6f", leftPathUpperL1Gain),
            String(format: "Right path conservative L1: %.6f", rightPathUpperL1Gain),
            String(format: "Worst-case coupled loop L1: %.6f", conservativeFeedbackLoopL1),
            String(format: "Small-gain margin: %.6f", conservativeSmallGainMargin),
            String(format: "Minimum repeated coherence: %.4f", minimumCoherence),
            "Independent launches: \(uniquePhysicalLaunchCount)",
            "Software model: within conservative stability bound",
            "Independent physical acoustic verification: NOT COMPLETE",
            "Echo cancellation: DISABLED",
            "Live speaker anti-noise: DISABLED"
        ].joined(separator: "\n")
    }
}

/// Offline small-gain stability check for feedback through the upstream
/// reference mic. L1 norms give an upper bound on an unmodeled *causal* LTI
/// loop without trusting a frequency-grid-only estimate. It is conservative:
/// if the measured path is not repeatable, refuse rather than extrapolate.
struct QuietZoneReferenceLeakageStabilityAnalyzer: Sendable {
    static let repetitionsPerSpeaker = 3
    static let maximumImpulseTaps = 128
    static let maximumCaptureAge: TimeInterval = 300
    static let maximumCaptureSpan: TimeInterval = 120
    static let minimumMeasuredCoherence = 0.85
    static let maximumRepeatDeviation = 0.10
    static let maximumConservativeLoopGain = 0.10
    static let errorSigmaMultiplier = 3.0

    func assess(
        candidate: QuietZoneCausalFIRCandidate,
        rig: QuietZoneHardwareCalibrationRig,
        captures: [QuietZoneReferenceLeakageCapture],
        now: Date = Date()
    ) throws -> QuietZoneReferenceLeakageStabilityReport {
        guard candidate.sampleRate.isFinite,
              rig.sampleRate.isFinite,
              abs(candidate.sampleRate - rig.sampleRate) < 0.5,
              (8_000...192_000).contains(rig.sampleRate),
              !candidate.leftTaps.isEmpty,
              candidate.leftTaps.count == candidate.rightTaps.count,
              candidate.leftTaps.count <= QuietZoneCausalFIRCompiler.maximumTaps,
              candidate.worstPredictedReductionDB.isFinite,
              candidate.worstPredictedReductionDB >=
                  QuietZoneVirtualSeatDesigner.minimumModeledReductionDB,
              candidate.maximumRelativeFitError.isFinite,
              candidate.maximumRelativeFitError <=
                  QuietZoneCausalFIRCompiler.maximumRelativeFitError,
              candidate.maximumReferenceEchoFraction.isFinite,
              candidate.maximumReferenceEchoFraction >= 0,
              candidate.maximumReferenceEchoFraction <=
                  QuietZoneVirtualSeatDesigner.maximumLeakageFraction,
              !rig.microphoneID.isEmpty, rig.microphoneChannel >= 0,
              !rig.outputDeviceID.isEmpty, !rig.routeID.isEmpty,
              !rig.clockID.isEmpty, !rig.triggerID.isEmpty else {
            throw QuietZoneReferenceLeakageError.invalidCandidate
        }

        func norm(_ taps: [Float]) throws -> Double {
            guard taps.allSatisfy(\.isFinite) else {
                throw QuietZoneReferenceLeakageError.invalidCandidate
            }
            let total = taps.reduce(0.0) { $0 + abs(Double($1)) }
            guard total.isFinite,
                  total <= QuietZoneCausalFIRCompiler.peakGainLimit else {
                throw QuietZoneReferenceLeakageError.invalidCandidate
            }
            return total
        }
        let leftFIR = try norm(candidate.leftTaps)
        let rightFIR = try norm(candidate.rightTaps)
        guard captures.count == 2 * Self.repetitionsPerSpeaker else {
            throw QuietZoneReferenceLeakageError.incompleteRepetitions
        }
        guard now.timeIntervalSince1970.isFinite else {
            throw QuietZoneReferenceLeakageError.staleEvidence
        }
        var launches = Set<String>()
        var coherence = 1.0
        var oldest = now
        var newest = Date(timeIntervalSince1970: 0)
        for item in captures {
            guard item.rig == rig,
                  item.sourceFixtureID == rig.triggerID,
                  !item.launchID.isEmpty else {
                throw QuietZoneReferenceLeakageError.untrustedRoute
            }
            guard launches.insert(item.launchID).inserted else {
                throw QuietZoneReferenceLeakageError.incompleteRepetitions
            }
            let age = now.timeIntervalSince(item.capturedAt)
            guard age.isFinite, age >= 0,
                  age <= Self.maximumCaptureAge else {
                throw QuietZoneReferenceLeakageError.staleEvidence
            }
            oldest = min(oldest, item.capturedAt)
            newest = max(newest, item.capturedAt)
            guard !item.impulseResponse.isEmpty,
                  item.impulseResponse.count <= Self.maximumImpulseTaps,
                  item.oneSigmaError.count == item.impulseResponse.count,
                  item.impulseResponse.allSatisfy(\.isFinite),
                  item.oneSigmaError.allSatisfy({
                      $0.isFinite && $0 >= 0
                  }),
                  item.measuredCoherence.isFinite,
                  item.measuredCoherence >= 0,
                  item.measuredCoherence <= 1 else {
                throw QuietZoneReferenceLeakageError.invalidMeasurements
            }
            guard item.measuredCoherence >= Self.minimumMeasuredCoherence else {
                throw QuietZoneReferenceLeakageError.insufficientCoherence
            }
            coherence = min(coherence, item.measuredCoherence)
        }
        guard newest.timeIntervalSince(oldest) <= Self.maximumCaptureSpan else {
            throw QuietZoneReferenceLeakageError.staleEvidence
        }
        var worstDeviation = 0.0

        func pathBound(_ side: QuietZoneLeakageSpeaker) throws -> Double {
            let group = captures.filter { $0.speaker == side }
            guard group.count == Self.repetitionsPerSpeaker,
                  let tapCount = group.first?.impulseResponse.count,
                  group.allSatisfy({
                      $0.impulseResponse.count == tapCount
                  }) else {
                throw QuietZoneReferenceLeakageError.incompleteRepetitions
            }
            var normUpper = 0.0
            var nominalNorm = 0.0
            var absoluteDeviation = 0.0
            for t in 0..<tapCount {
                let mean = group.reduce(0.0) {
                    $0 + $1.impulseResponse[t]
                } / Double(Self.repetitionsPerSpeaker)
                let deviation = group.map {
                    abs($0.impulseResponse[t] - mean)
                }.max() ?? 0
                let sigma = group.map {
                    $0.oneSigmaError[t]
                }.max() ?? 0
                nominalNorm += abs(mean)
                absoluteDeviation += deviation
                normUpper += abs(mean) + deviation
                    + Self.errorSigmaMultiplier * sigma
            }
            guard normUpper.isFinite, nominalNorm.isFinite,
                  absoluteDeviation.isFinite else {
                throw QuietZoneReferenceLeakageError.invalidMeasurements
            }
            let relativeDeviation = absoluteDeviation
                / max(nominalNorm, 1.0e-9)
            guard relativeDeviation <= Self.maximumRepeatDeviation else {
                throw QuietZoneReferenceLeakageError.inconsistentCaptures
            }
            worstDeviation = max(worstDeviation, relativeDeviation)
            return normUpper
        }
        let left = try pathBound(.left)
        let right = try pathBound(.right)
        // Sufficient, deliberately strict BIBO feedback test for a bounded
        // LTI convolution loop: ||L*F_L + R*F_R||_1 is no greater than this
        // sum of *uncertainty-inflated* path L1 × filter L1 products.
        let loopGain = left * leftFIR + right * rightFIR
        guard loopGain.isFinite,
              loopGain <= Self.maximumConservativeLoopGain else {
            throw QuietZoneReferenceLeakageError.excessiveFeedbackBound
        }
        return .init(
            leftPathUpperL1Gain: left,
            rightPathUpperL1Gain: right,
            candidateLeftL1Gain: leftFIR,
            candidateRightL1Gain: rightFIR,
            conservativeFeedbackLoopL1: loopGain,
            conservativeSmallGainMargin: 1.0 - loopGain,
            minimumCoherence: coherence,
            uniquePhysicalLaunchCount: launches.count,
            worstRepeatDeviation: worstDeviation,
            capturesFromRig: rig
        )
    }
}


/// PREVIEW-ONLY admission to the PR98 native shadow session. This interface
/// requires the full repeated-speaker leakage check *before* allocating the
/// underlying clock-guarded diagnostic bridge. It has no audio output API.
final class QuietZoneLeakageGuardedShadowSession {
    let leakage: QuietZoneReferenceLeakageStabilityReport
    private let clocked: QuietZoneClockGuardedShadowTransport

    init(
        plan: QuietZoneFeedForwardSchedulingPlan,
        candidate: QuietZoneCausalFIRCandidate,
        captures: [QuietZoneReferenceLeakageCapture],
        leakageReviewedAt: Date,
        initialTrace: QuietZoneHALClockTrace,
        route: QuietZoneHardwareClockRouteLease,
        routeLeaseToken: UInt64,
        synchronizedClockToken: UInt64,
        clockObservedAtSeconds: Double
    ) throws {
        // No independent physical attestation is implied: this only checks
        // typed, caller-provided measured data against conservative limits.
        leakage = try QuietZoneReferenceLeakageStabilityAnalyzer().assess(
            candidate: candidate, rig: plan.rig,
            captures: captures, now: leakageReviewedAt
        )
        clocked = try .init(
            plan: plan, candidate: candidate,
            initialTrace: initialTrace, route: route,
            routeLeaseToken: routeLeaseToken,
            synchronizedClockToken: synchronizedClockToken,
            now: clockObservedAtSeconds
        )
    }

    func observe(
        input: QuietZoneHALClockObservation,
        output: QuietZoneHALClockObservation,
        route: QuietZoneHardwareClockRouteLease,
        now: Double
    ) throws -> QuietZoneFeedForwardClockStatus {
        try clocked.observe(
            input: input, output: output, route: route, now: now
        )
    }

    func ingest(
        referenceFrame: N60FeedForwardReferenceFrame,
        witnessed: QuietZoneFeedForwardReferenceDeadlineEvent,
        output: N60FFDeadlineOutputWitness,
        route: QuietZoneHardwareClockRouteLease
    ) throws {
        try clocked.ingest(
            referenceFrame: referenceFrame, witnessed: witnessed,
            output: output, route: route
        )
    }

    func readDiagnostics() -> [N60FFDeadlineRecord] {
        clocked.readDiagnostics()
    }

    func snapshot() -> N60FFDeadlineSnapshot {
        clocked.snapshot()
    }

    func close() { clocked.close() }
    var echoCancellerEnabled: Bool { false }
    var outputConnected: Bool { false }
    var liveANCQualified: Bool { false }
}
