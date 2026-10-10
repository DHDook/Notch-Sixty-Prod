import Foundation

/// PR98 hardware acceptance is a read-only review of externally obtained
/// measurement records. It NEVER emits a stimulus, configures an output,
/// arms ANC or grants a live-output permit.
enum QuietZoneHardwareAcceptanceFault: Error, Equatable, LocalizedError {
    case missingMeasurement
    case wrongCalibrationRig
    case replayedSource
    case invalidSequence
    case expiredEvidence
    case invalidSpectrum
    case unrepeatableNoise
    case poorCoherence
    case unsafeSignal
    case insufficientAttenuation
    case acousticRegression
    case unverifiedFaultShutdown

    var errorDescription: String? {
        switch self {
        case .missingMeasurement: return "Three ordered listener captures and five distinct fault probes are required."
        case .wrongCalibrationRig: return "The calibration session, speaker output, source, microphone or clock changed."
        case .replayedSource: return "Independent measurement launches must have unique identifiers."
        case .invalidSequence: return "The external source must be measured OFF–TEST–OFF in order at the same listener position."
        case .expiredEvidence: return "Acceptance measurements are outside this calibration session."
        case .invalidSpectrum: return "SPL frequency bins, calibration or measured amplitude are invalid."
        case .unrepeatableNoise: return "The independent baseline measurements disagree."
        case .poorCoherence: return "The source-to-seat measurement is insufficiently coherent."
        case .unsafeSignal: return "Source level, digital output headroom or clipping protection failed."
        case .insufficientAttenuation: return "The recorded listener reduction did not reach the provisional target."
        case .acousticRegression: return "At least one coherent frequency band became louder beyond the allowed regression."
        case .unverifiedFaultShutdown: return "The external shutdown probe was too slow, loud, ambiguous or auto-rearmed."
        }
    }
}

enum QuietZoneSeatAcceptancePhase: Int, CaseIterable, Sendable {
    case baselineBefore
    case experimentalTreatment
    case baselineAfter
}

/// Calibration-instrument power-level measurement (dB SPL) per coherent,
/// aligned narrow band. Values are source-only, not ambient-party speech.
struct QuietZoneSeatPowerBand: Sendable {
    let frequencyHz: Double
    let levelDBSPL: Double
}

struct QuietZoneSeatAcceptanceCapture: Sendable {
    let sessionID: UUID
    let rig: QuietZoneHardwareCalibrationRig
    let phase: QuietZoneSeatAcceptancePhase
    let launchID: String
    let independentSourceID: String
    let instrumentCalibrationID: String
    let listenerPositionID: String
    let measuredAt: Date
    let measuredCoherence: Double
    let bands: [QuietZoneSeatPowerBand]
    let maximumSeatLevelDBSPL: Double
    let speakerOutputClipped: Bool
    /// Upper observed normalized PCM peaks, from instrumented DAC path.
    let maximumLeftSamplePeak: Double
    let maximumRightSamplePeak: Double
}

enum QuietZoneHardwareFaultProbeType: String, CaseIterable, Sendable {
    case outputRouteLost
    case inputMicrophoneLost
    case clockDiscontinuity
    case referenceRingOverflow
    case antiNoiseOutputOverload
}

/// External witness: real hardware mute / fade latency and residual analog
/// output must be independently measured; user-supplied flags are NOT proof.
struct QuietZoneHardwareFaultShutdownWitness: Sendable {
    let sessionID: UUID
    let rig: QuietZoneHardwareCalibrationRig
    let fault: QuietZoneHardwareFaultProbeType
    let launchID: String
    let instrumentCalibrationID: String
    let measuredAt: Date
    let detectedAtHostSeconds: Double
    let physicalMuteReachedAtHostSeconds: Double
    /// Post-shutdown output relative to full-scale verified by instrument.
    let outputResidualDBFS: Double
    let noAutomaticRearmObserved: Bool
}

struct QuietZoneHardwareAcceptanceCriteria: Sendable {
    /// Engineering *bench* thresholds only, not proven real-world performance.
    static let minimumCoherence = 0.85
    static let maximumBaselineDifferenceDB = 1.5
    static let minimumIntegratedReductionDB = 1.0
    static let maximumSingleBandRegressionDB = 1.0
    static let maximumSeatTestPeakDBSPL = 85.0
    static let maximumIndividualSamplePeak = 0.06309573444801933
    static let maximumStereoSumPeak = 0.10
    static let maximumMeasuredMuteSeconds = 0.100
    static let maximumResidualLevelDBFS = -60.0
    static let minimumBandFrequencyHz = 20.0
    static let maximumBandFrequencyHz = 150.0
    static let maximumSessionAgeSeconds: TimeInterval = 360
    static let minimumBetweenCapturesSeconds: TimeInterval = 0.25
}

struct QuietZoneHardwareAcceptanceReview: Sendable {
    let sessionID: UUID
    let worstCoherence: Double
    let integratedReductionDB: Double
    let worstFrequencyReductionDB: Double
    let maxBaselineDriftDB: Double
    let worstPhysicalMuteSeconds: Double
    let maximumTestLevelDBSPL: Double
    let acceptedProbeCount: Int
    let provisionalBenchCriteriaMet: Bool = true

    // IMPORTANT: Passing this numerical review never authenticates the
    // instrument, proves physical ANC stability or authorizes a speaker.
    let physicalAcousticEvidenceIndependentlyVerified: Bool = false
    let emergencyMuteHardwareVerified: Bool = false
    let liveSpeakerConnectionAuthorized: Bool = false
    let liveANCQualified: Bool = false

    var reviewText: String {
        [
            "PR98 physical ANC commissioning: UNVERIFIED numerical preflight",
            String(format: "Average coherent-band reduction: %.2f dB",
                   integratedReductionDB),
            String(format: "Worst-band reduction: %.2f dB",
                   worstFrequencyReductionDB),
            String(format: "Largest OFF/OFF drift: %.2f dB",
                   maxBaselineDriftDB),
            String(format: "Worst measured shutdown: %.1f ms",
                   worstPhysicalMuteSeconds * 1_000),
            "Fault probe categories: \(acceptedProbeCount) / 5",
            "Bench numerical criteria: satisfied by supplied records",
            "Physical instrument and capture provenance: NOT VERIFIED",
            "Actual live speaker mute: NOT VERIFIED",
            "Live ANC output: DISCONNECTED"
        ].joined(separator: "\n")
    }
}

/// Validates a proposed external lab session. No Core Audio calls or IOProc
/// path exist here. A successful result is NOT an independent physical audit.
struct QuietZoneHardwareAcceptanceAnalyzer: Sendable {
    func analyze(
        rig: QuietZoneHardwareCalibrationRig,
        sessionID: UUID,
        sessionStartedAt: Date,
        captures: [QuietZoneSeatAcceptanceCapture],
        faultProbes: [QuietZoneHardwareFaultShutdownWitness],
        now: Date
    ) throws -> QuietZoneHardwareAcceptanceReview {
        guard captures.count == 3,
              faultProbes.count == QuietZoneHardwareFaultProbeType.allCases.count
        else { throw QuietZoneHardwareAcceptanceFault.missingMeasurement }
        let elapsed = now.timeIntervalSince(sessionStartedAt)
        guard elapsed.isFinite, elapsed >= 0,
              elapsed <= QuietZoneHardwareAcceptanceCriteria.maximumSessionAgeSeconds
        else { throw QuietZoneHardwareAcceptanceFault.expiredEvidence }

        var seenIDs = Set<String>()
        var time = sessionStartedAt
        var expectedInstrumentID: String?
        var expectedSourceID: String?
        var expectedPosition: String?
        let phaseOrder = QuietZoneSeatAcceptancePhase.allCases
        var worstCoherence = 1.0
        var highestLevel = -Double.infinity

        for (index, capture) in captures.enumerated() {
            guard capture.sessionID == sessionID, capture.rig == rig,
                  !capture.instrumentCalibrationID.isEmpty,
                  !capture.independentSourceID.isEmpty,
                  !capture.listenerPositionID.isEmpty
            else { throw QuietZoneHardwareAcceptanceFault.wrongCalibrationRig }
            guard !capture.launchID.isEmpty,
                  seenIDs.insert(capture.launchID).inserted
            else { throw QuietZoneHardwareAcceptanceFault.replayedSource }
            guard capture.phase == phaseOrder[index],
                  expectedInstrumentID.map({
                      $0 == capture.instrumentCalibrationID
                  }) ?? true,
                  expectedSourceID.map({
                      $0 == capture.independentSourceID
                  }) ?? true,
                  expectedPosition.map({
                      $0 == capture.listenerPositionID
                  }) ?? true
            else { throw QuietZoneHardwareAcceptanceFault.invalidSequence }
            expectedInstrumentID = capture.instrumentCalibrationID
            expectedSourceID = capture.independentSourceID
            expectedPosition = capture.listenerPositionID
            let delay = capture.measuredAt.timeIntervalSince(time)
            guard delay.isFinite,
                  delay >= QuietZoneHardwareAcceptanceCriteria
                    .minimumBetweenCapturesSeconds,
                  capture.measuredAt <= now
            else { throw QuietZoneHardwareAcceptanceFault.expiredEvidence }
            time = capture.measuredAt
            guard capture.measuredCoherence.isFinite,
                  capture.measuredCoherence >=
                    QuietZoneHardwareAcceptanceCriteria.minimumCoherence,
                  capture.measuredCoherence <= 1
            else { throw QuietZoneHardwareAcceptanceFault.poorCoherence }
            worstCoherence = min(worstCoherence, capture.measuredCoherence)
            guard !capture.speakerOutputClipped,
                  capture.maximumSeatLevelDBSPL.isFinite,
                  (0...QuietZoneHardwareAcceptanceCriteria.maximumSeatTestPeakDBSPL)
                    .contains(capture.maximumSeatLevelDBSPL),
                  capture.maximumLeftSamplePeak.isFinite,
                  capture.maximumRightSamplePeak.isFinite,
                  capture.maximumLeftSamplePeak >= 0,
                  capture.maximumRightSamplePeak >= 0,
                  capture.maximumLeftSamplePeak <=
                    QuietZoneHardwareAcceptanceCriteria.maximumIndividualSamplePeak,
                  capture.maximumRightSamplePeak <=
                    QuietZoneHardwareAcceptanceCriteria.maximumIndividualSamplePeak,
                  capture.maximumLeftSamplePeak
                    + capture.maximumRightSamplePeak <=
                    QuietZoneHardwareAcceptanceCriteria.maximumStereoSumPeak
            else { throw QuietZoneHardwareAcceptanceFault.unsafeSignal }

            guard (3...32).contains(capture.bands.count) else {
                throw QuietZoneHardwareAcceptanceFault.invalidSpectrum
            }
            for (j, band) in capture.bands.enumerated() {
                guard band.frequencyHz.isFinite,
                      band.levelDBSPL.isFinite,
                      (0...150).contains(band.levelDBSPL),
                      (QuietZoneHardwareAcceptanceCriteria.minimumBandFrequencyHz
                       ...QuietZoneHardwareAcceptanceCriteria.maximumBandFrequencyHz)
                        .contains(band.frequencyHz),
                      j == 0
                        || band.frequencyHz > capture.bands[j - 1].frequencyHz,
                      index == 0
                        || capture.bands[j].frequencyHz ==
                           captures[0].bands[j].frequencyHz
                else { throw QuietZoneHardwareAcceptanceFault.invalidSpectrum }
            }
            if index > 0 && capture.bands.count != captures[0].bands.count {
                throw QuietZoneHardwareAcceptanceFault.invalidSpectrum
            }
            highestLevel = max(highestLevel, capture.maximumSeatLevelDBSPL)
        }

        var powerOff = 0.0
        var powerOn = 0.0
        var worstBand = Double.infinity
        var maximumDrift = 0.0
        for i in captures[0].bands.indices {
            let before = captures[0].bands[i].levelDBSPL
            let on = captures[1].bands[i].levelDBSPL
            let after = captures[2].bands[i].levelDBSPL
            let drift = abs(after - before)
            guard drift <=
                  QuietZoneHardwareAcceptanceCriteria.maximumBaselineDifferenceDB
            else { throw QuietZoneHardwareAcceptanceFault.unrepeatableNoise }
            maximumDrift = max(maximumDrift, drift)
            // Power-average the two OFF baselines, never average dB directly.
            let baselinePower = 0.5 * (pow(10, before / 10)
                                        + pow(10, after / 10))
            let onPower = pow(10, on / 10)
            let reduction = 10 * log10(baselinePower / onPower)
            guard baselinePower.isFinite, onPower.isFinite,
                  reduction.isFinite else {
                throw QuietZoneHardwareAcceptanceFault.invalidSpectrum
            }
            guard reduction >=
                    -QuietZoneHardwareAcceptanceCriteria.maximumSingleBandRegressionDB
            else { throw QuietZoneHardwareAcceptanceFault.acousticRegression }
            worstBand = min(worstBand, reduction)
            powerOff += baselinePower
            powerOn += onPower
        }
        let improvement = 10 * log10(powerOff / powerOn)
        guard improvement.isFinite,
              improvement >=
                QuietZoneHardwareAcceptanceCriteria.minimumIntegratedReductionDB
        else { throw QuietZoneHardwareAcceptanceFault.insufficientAttenuation }

        var worstMute = 0.0
        var types = Set<QuietZoneHardwareFaultProbeType>()
        for probe in faultProbes {
            guard probe.sessionID == sessionID, probe.rig == rig,
                  probe.instrumentCalibrationID == expectedInstrumentID
            else { throw QuietZoneHardwareAcceptanceFault.wrongCalibrationRig }
            guard !probe.launchID.isEmpty,
                  seenIDs.insert(probe.launchID).inserted,
                  types.insert(probe.fault).inserted
            else { throw QuietZoneHardwareAcceptanceFault.replayedSource }
            let age = now.timeIntervalSince(probe.measuredAt)
            guard age.isFinite, age >= 0,
                  probe.measuredAt >= sessionStartedAt,
                  age <= QuietZoneHardwareAcceptanceCriteria.maximumSessionAgeSeconds
            else { throw QuietZoneHardwareAcceptanceFault.expiredEvidence }
            let delay = probe.physicalMuteReachedAtHostSeconds
                - probe.detectedAtHostSeconds
            guard probe.detectedAtHostSeconds.isFinite,
                  probe.physicalMuteReachedAtHostSeconds.isFinite,
                  delay.isFinite, delay >= 0,
                  delay <= QuietZoneHardwareAcceptanceCriteria
                    .maximumMeasuredMuteSeconds,
                  probe.outputResidualDBFS.isFinite,
                  probe.outputResidualDBFS <=
                    QuietZoneHardwareAcceptanceCriteria.maximumResidualLevelDBFS,
                  probe.noAutomaticRearmObserved
            else { throw QuietZoneHardwareAcceptanceFault.unverifiedFaultShutdown }
            worstMute = max(worstMute, delay)
        }
        guard types.count == QuietZoneHardwareFaultProbeType.allCases.count
        else { throw QuietZoneHardwareAcceptanceFault.missingMeasurement }
        return .init(
            sessionID: sessionID, worstCoherence: worstCoherence,
            integratedReductionDB: improvement,
            worstFrequencyReductionDB: worstBand,
            maxBaselineDriftDB: maximumDrift,
            worstPhysicalMuteSeconds: worstMute,
            maximumTestLevelDBSPL: highestLevel,
            acceptedProbeCount: types.count
        )
    }
}

/// Operator-facing runbook only. All stages use PR97's existing measurement
/// types; descriptions are review prompts, not actions that play sound.
struct QuietZoneCommissioningRunbookStep: Sendable {
    let number: Int
    let title: String
    let instruction: String
}

struct QuietZonePhysicalCommissioningRunbook: Sendable {
    let steps: [QuietZoneCommissioningRunbookStep]
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false

    static func make() -> QuietZonePhysicalCommissioningRunbook {
        let details: [(String, String)] = [
            ("Lock route and instrument identity",
             "Record exact microphone channel, DAC UID, sample rate, route lease and independently calibrated instrument ID; establish stop/mute independently before any energised experiment."),
            ("Qualify simultaneous input/output host clocks",
             "Use PR97's running HAL clock trace and independent clock conversion; abort on drift, route changes, discontinuities and stale observations."),
            ("Electrical loopback and movable-mic A/B/A survey",
             "Record three independent cable loopbacks, then listener → doorway → listener controlled source arrivals using one moved mic; no uncontrolled speech."),
            ("Instrument four physical latency endpoints",
             "Witness separately reference ADC, processing, DAC analog output and speaker-to-seat flight; apply calibrated endpoint corrections; do not substitute a cable total."),
            ("Run disconnected DSP, echo and leakage checks",
             "Verify exact-head PR98 shadow scheduler, conservative lead, FIR bounds, six distinct L/R leakage launches, and offline held-out echo model."),
            ("Prepare isolated low-level external acoustic trial",
             "Only with qualified external interlocks and an independent test harness: controlled coherent low-frequency source; cap seat test level at 85 dB SPL and combined anti-noise sample sum at 0.10."),
            ("Capture listener OFF–TEST–OFF",
             "With an externally verified test fixture, record three separate source launches at the identical seat using the same instrument, clock, frequency grid and fixture."),
            ("Witness five emergency shutdown scenarios",
             "Independently measure loss of output route, reference mic, clock, ring capacity and output headroom; require ≤100 ms to at most −60 dBFS and no auto-rearm."),
            ("Review independently before any live-output PR",
             "Inspect instrument calibration, signed packet, coherence, repeatability, mean acoustic benefit, worst-frequency regression and fault traces. Numeric pass is never output authorization.")
        ]
        return .init(steps: details.enumerated().map { i, entry in
            .init(number: i + 1, title: entry.0, instruction: entry.1)
        })
    }
}
