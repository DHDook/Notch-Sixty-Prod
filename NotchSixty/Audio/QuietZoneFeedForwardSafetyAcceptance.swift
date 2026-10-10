import Foundation

/// PR98's output-readiness review deliberately cannot grant speaker access.
/// Software tests, synthetic timestamps and caller-supplied leakage data are
/// diagnostics, not a substitute for independent physical acoustic acceptance.
enum QuietZoneFeedForwardAcceptanceGate: String, CaseIterable, Sendable {
    case perSpeakerGain
    case combinedStereoHeadroom
    case synchronizedClock
    case realTimeDeadline
    case referenceFeedbackBound
    case echoContaminationModel
    case faultToBypassSimulation
    case independentHardwareReview
    case measuredSeatAttenuation
    case liveOutputAuthorization

    var title: String {
        switch self {
        case .perSpeakerGain: return "Causal FIR per-speaker gain"
        case .combinedStereoHeadroom: return "Combined stereo output headroom"
        case .synchronizedClock: return "HAL clock continuity"
        case .realTimeDeadline: return "Unconnected output-deadline diagnostics"
        case .referenceFeedbackBound: return "Speaker-reference loop bound"
        case .echoContaminationModel: return "Offline echo contamination model"
        case .faultToBypassSimulation: return "Simulated fault-to-bypass"
        case .independentHardwareReview: return "Independent timing and microphone calibration"
        case .measuredSeatAttenuation: return "Measured listener acoustic benefit and stability"
        case .liveOutputAuthorization: return "Separate live-output safety approval"
        }
    }
}

enum QuietZoneFeedForwardAcceptanceStatus: String, Sendable {
    case diagnosticPassed
    case missing
    case blocked
    case independentPhysicalReviewRequired
}

struct QuietZoneFeedForwardAcceptanceItem: Sendable {
    let gate: QuietZoneFeedForwardAcceptanceGate
    let status: QuietZoneFeedForwardAcceptanceStatus
    let detail: String
}

struct QuietZoneFeedForwardAcceptanceReport: Sendable {
    let items: [QuietZoneFeedForwardAcceptanceItem]
    let diagnosticPassCount: Int
    let blockingOrMissingCount: Int
    let physicalReviewRequiredCount: Int

    /// No PR98 path may infer safe speaker operation from this report.
    let speakerOutputConnected: Bool = false
    let independentlyCommissioned: Bool = false
    let acousticAttenuationVerified: Bool = false
    let liveANCQualified: Bool = false

    func status(_ gate: QuietZoneFeedForwardAcceptanceGate)
        -> QuietZoneFeedForwardAcceptanceStatus? {
        items.first(where: { $0.gate == gate })?.status
    }
}

struct QuietZoneFeedForwardSafetyAcceptanceEvaluator: Sendable {
    static let maximumCombinedStereoPeak = 0.10

    func review(
        rig: QuietZoneHardwareCalibrationRig,
        candidate: QuietZoneCausalFIRCandidate?,
        clock: QuietZoneFeedForwardClockStatus?,
        shadow: N60FFDeadlineSnapshot?,
        leakage: QuietZoneReferenceLeakageStabilityReport?,
        echo: QuietZoneReferenceEchoModel?,
        commissioning: QuietZoneCommissioningChecklist? = nil
    ) -> QuietZoneFeedForwardAcceptanceReport {
        func item(
            _ gate: QuietZoneFeedForwardAcceptanceGate,
            _ status: QuietZoneFeedForwardAcceptanceStatus,
            _ detail: String
        ) -> QuietZoneFeedForwardAcceptanceItem {
            .init(gate: gate, status: status, detail: detail)
        }
        let left: Double? = candidate.map {
            $0.leftTaps.reduce(0.0) { $0 + abs(Double($1)) }
        }
        let right: Double? = candidate.map {
            $0.rightTaps.reduce(0.0) { $0 + abs(Double($1)) }
        }
        let validCoefficients: Bool
        if let candidate, let left, let right {
            validCoefficients =
                candidate.sampleRate.isFinite
                && rig.sampleRate.isFinite
                && abs(candidate.sampleRate - rig.sampleRate) < 0.5
                && !candidate.leftTaps.isEmpty
                && candidate.leftTaps.count == candidate.rightTaps.count
                && candidate.leftTaps.count <= QuietZoneCausalFIRCompiler.maximumTaps
                && left.isFinite && right.isFinite
                && candidate.leftTaps.allSatisfy(\.isFinite)
                && candidate.rightTaps.allSatisfy(\.isFinite)
                && left <= QuietZoneCausalFIRCompiler.peakGainLimit
                && right <= QuietZoneCausalFIRCompiler.peakGainLimit
        } else { validCoefficients = false }

        let clockGood = clock.map {
            $0.firstFault == nil
            && $0.relativeDriftPPM.isFinite
            && $0.relativeDriftPPM <= QuietZoneHALClockAnalyzer.maximumRelativeDriftPPM
            && $0.observationCount >= QuietZoneHALClockAnalyzer.minimumObservations
            && $0.inputRateHz.isFinite && $0.outputRateHz.isFinite
        } ?? false

        let diagnosticDeadlineGood = shadow.map {
            !$0.halted && $0.acceptedRecords > 0
            && $0.firstFault.rawValue == 0
        } ?? false

        let leakageGood = leakage.map {
            $0.capturesFromRig == rig
            && $0.uniquePhysicalLaunchCount == 6
            && $0.minimumCoherence >=
                QuietZoneReferenceLeakageStabilityAnalyzer.minimumMeasuredCoherence
            && $0.conservativeFeedbackLoopL1.isFinite
            && $0.conservativeFeedbackLoopL1 >= 0
            && $0.conservativeFeedbackLoopL1 <=
                QuietZoneReferenceLeakageStabilityAnalyzer.maximumConservativeLoopGain
        } ?? false

        let echoGood: Bool
        if let echo, let candidate, let leakage {
            echoGood = echo.rig == rig
                && echo.candidate == candidate
                && echo.stability.capturesFromRig == leakage.capturesFromRig
                && echo.stability.conservativeFeedbackLoopL1
                    == leakage.conservativeFeedbackLoopL1
                && echo.independentSourceLaunchIDs.count == 6
                && echo.leftSpeakerToReference.count > 0
                && echo.rightSpeakerToReference.count > 0
        } else { echoGood = false }

        let bypassSimulated = shadow.map {
            $0.halted && $0.faultFadeFramesRemaining == 0
            && $0.simulatedFaultFadeGain == 0
            && $0.simulatedBypassReached
        } ?? false

        let check = commissioning?.item(.independentHardwareReview)
        let acoustic = commissioning?.item(.acousticAcceptance)
        // PR97 checklist statuses intentionally cannot mark physical review
        // COMPLETE. A report of "capturedUnverified" remains unverified.
        let badHardware = check?.status == .invalid
        let badAcoustic = acoustic?.status == .invalid

        let rows: [QuietZoneFeedForwardAcceptanceItem] = [
            item(.perSpeakerGain,
                 candidate == nil ? .missing
                    : (validCoefficients ? .diagnosticPassed : .blocked),
                 "Both FIR L1 gains must fit the -24 dBFS individual cap."),
            item(.combinedStereoHeadroom,
                 candidate == nil || shadow == nil ? .missing
                    : (validCoefficients
                       && (left ?? .infinity) + (right ?? .infinity)
                            <= Self.maximumCombinedStereoPeak
                       && shadow!.maximumObservedStereoSumMicro <= 100_000
                       ? .diagnosticPassed : .blocked),
                 "Both channels share a 0.10 peak-sum cap, checked again for each shadow FIR frame."),
            item(.synchronizedClock, clock == nil ? .missing
                 : (clockGood ? .diagnosticPassed : .blocked),
                 "Monotonic HAL clock traces remain a diagnostic, not ADC/DAC acoustic timing."),
            item(.realTimeDeadline, shadow == nil ? .missing
                 : (diagnosticDeadlineGood ? .diagnosticPassed : .blocked),
                 "A valid shadow-frame deadline cannot establish real-time callback scheduling."),
            item(.referenceFeedbackBound, leakage == nil ? .missing
                 : (leakageGood ? .diagnosticPassed : .blocked),
                 "Uncertainty-inflated stereo small-gain model; physical plant remains unverified."),
            item(.echoContaminationModel, echo == nil ? .missing
                 : (echoGood ? .diagnosticPassed : .blocked),
                 "Predicted subtraction is offline, not an installed microphone echo canceller."),
            item(.faultToBypassSimulation, shadow == nil ? .missing
                 : (bypassSimulated ? .diagnosticPassed : .missing),
                 "Only the simulated fade counter can reach zero; hardware mute remains untested."),
            item(.independentHardwareReview,
                 badHardware ? .blocked : .independentPhysicalReviewRequired,
                 "A calibrated external instrument must substantiate all four latency stages."),
            item(.measuredSeatAttenuation,
                 badAcoustic ? .blocked : .independentPhysicalReviewRequired,
                 "Requires independent seat SPL, coherence, headroom and stability acceptance."),
            item(.liveOutputAuthorization, .independentPhysicalReviewRequired,
                 "No live ANC speaker injection or authorization is implemented in PR98.")
        ]
        let ready = rows.filter { $0.status == .diagnosticPassed }.count
        let blocked = rows.filter {
            $0.status == .blocked || $0.status == .missing
        }.count
        let external = rows.filter {
            $0.status == .independentPhysicalReviewRequired
        }.count
        return .init(
            items: rows, diagnosticPassCount: ready,
            blockingOrMissingCount: blocked, physicalReviewRequiredCount: external
        )
    }
}
