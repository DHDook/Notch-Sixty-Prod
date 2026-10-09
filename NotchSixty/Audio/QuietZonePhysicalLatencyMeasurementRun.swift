import Foundation

/// Explicit physical endpoints for each of the four latency segments.
/// An electrical DAC loopback is NOT an acoustic speaker-to-seat witness.
enum QuietZoneLatencyWitnessMethod: String, Equatable, Sendable {
    case acousticReferenceToADCReady
    case adcReadyToAntiNoiseCommand
    case commandToAnalogDACOutput
    case analogSpeakerOutputToListenerMic

    var stage: QuietZonePhysicalLatencyStage {
        switch self {
        case .acousticReferenceToADCReady: return .referenceADC
        case .adcReadyToAntiNoiseCommand: return .referenceProcessing
        case .commandToAnalogDACOutput: return .outputDAC
        case .analogSpeakerOutputToListenerMic: return .speakerToSeat
        }
    }
}

/// One unique, independently instrumented repetition. The caller must have
/// actually measured both physical endpoints on the same cross-calibrated
/// host clock. A UI button, system tap, electrical round-trip *total*, or
/// self-declared timing correction is not sufficient physical attestation.
struct QuietZonePhysicalLatencyRepetition: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let method: QuietZoneLatencyWitnessMethod
    let eventID: String
    let measuredAt: Date
    let startHostSeconds: Double
    let endHostSeconds: Double
    /// Correction for the measurement chain at the endpoint. For the acoustic
    /// speaker-to-seat stage, this must remove the *seat measurement mic* ADC
    /// delay, measured separately from the upstream reference ADC.
    let calibratedEndpointCorrectionSeconds: Double
    let startClockUncertaintySeconds: Double
    let endClockUncertaintySeconds: Double
    let correctionUncertaintySeconds: Double
    let worstSchedulingJitterSeconds: Double
    let clockCalibrationVerified: Bool
    let endpointCorrectionVerified: Bool
    let origin: QuietZonePhysicalLatencyOrigin
}

enum QuietZoneLatencyMeasurementError: Error, Equatable, LocalizedError {
    case incompatibleRoute
    case unsuitableWitness
    case missingClockCalibration
    case invalidTimestamp
    case implausibleDuration
    case replayedEvent
    case outOfOrderCapture
    case staleCapture
    case missingRepetitions
    case tooManyRepetitions

    var errorDescription: String? {
        switch self {
        case .incompatibleRoute: return "Microphone, output lease or host clock does not match the active calibration rig."
        case .unsuitableWitness: return "This latency stage needs independently measured physical endpoints, not a cable-loopback total or synthetic estimate."
        case .missingClockCalibration: return "The host clocks and endpoint measurement-path correction have not been independently calibrated."
        case .invalidTimestamp: return "The observed host-clock timestamps or measured uncertainties are invalid."
        case .implausibleDuration: return "The corrected physical latency is zero, negative, or outside safe measurement bounds."
        case .replayedEvent: return "A hardware measurement event ID was already used."
        case .outOfOrderCapture: return "The physical measurement timestamps reversed or overlapped an earlier repetition."
        case .staleCapture: return "The measurement does not belong to the current hardware-calibration session."
        case .missingRepetitions: return "At least three independent measurements are needed for every physical latency stage."
        case .tooManyRepetitions: return "The instrumented measurement buffer has reached its bounded capacity."
        }
    }
}

/// Control-thread-only staged measurement assembler. It has no Core Audio
/// callback, speaker output, persistence, ANC bypass or hardware arming path.
/// The witnessed endpoints are supplied by a separate physical instrument.
struct QuietZonePhysicalLatencyMeasurementRun: Sendable {
    static let maximumRepetitionsPerStage = 20
    static let maximumStageTimingUncertaintySeconds = 0.001
    static let maximumPerEventJitterSeconds = 0.01
    static let maximumCorrectionSeconds = 0.25
    static let minimumInterEventSeconds = 0.005

    let rig: QuietZoneHardwareCalibrationRig
    let startedAt: Date
    private var samplesByStage: [
        QuietZonePhysicalLatencyStage: [QuietZonePhysicalLatencyRepetition]
    ] = [:]
    private var seenIDs = Set<String>()

    init(rig: QuietZoneHardwareCalibrationRig, now: Date = Date()) throws {
        guard !rig.microphoneID.isEmpty, rig.microphoneChannel >= 0,
              !rig.outputDeviceID.isEmpty, !rig.routeID.isEmpty,
              !rig.clockID.isEmpty, !rig.triggerID.isEmpty,
              rig.sampleRate.isFinite, (8_000...192_000).contains(rig.sampleRate)
        else { throw QuietZoneLatencyMeasurementError.incompatibleRoute }
        self.rig = rig
        self.startedAt = now
    }

    func count(_ stage: QuietZonePhysicalLatencyStage) -> Int {
        samplesByStage[stage]?.count ?? 0
    }

    var completedStages: Int {
        QuietZonePhysicalLatencyStage.allCases.filter {
            count($0) >= QuietZonePhysicalLatencyBudgetAnalyzer
                .minimumIndependentRepetitions
        }.count
    }

    var isComplete: Bool {
        completedStages == QuietZonePhysicalLatencyStage.allCases.count
    }

    mutating func add(
        _ sample: QuietZonePhysicalLatencyRepetition,
        now: Date = Date()
    ) throws {
        guard sample.rig == rig else {
            throw QuietZoneLatencyMeasurementError.incompatibleRoute
        }
        guard sample.origin == .instrumentedHardware else {
            throw QuietZoneLatencyMeasurementError.unsuitableWitness
        }
        guard sample.clockCalibrationVerified,
              sample.endpointCorrectionVerified else {
            throw QuietZoneLatencyMeasurementError.missingClockCalibration
        }
        let age = now.timeIntervalSince(sample.measuredAt)
        let fromStart = sample.measuredAt.timeIntervalSince(startedAt)
        guard age.isFinite, fromStart.isFinite,
              age >= 0, fromStart >= 0,
              age <= QuietZonePhysicalLatencyBudgetAnalyzer
                  .maximumEvidenceAgeSeconds,
              fromStart <= QuietZonePhysicalLatencyBudgetAnalyzer
                  .maximumEvidenceAgeSeconds
        else { throw QuietZoneLatencyMeasurementError.staleCapture }

        guard !sample.eventID.isEmpty, !seenIDs.contains(sample.eventID) else {
            throw QuietZoneLatencyMeasurementError.replayedEvent
        }
        let prior = samplesByStage[sample.method.stage] ?? []
        guard prior.count < Self.maximumRepetitionsPerStage else {
            throw QuietZoneLatencyMeasurementError.tooManyRepetitions
        }
        let values = [
            sample.startHostSeconds, sample.endHostSeconds,
            sample.calibratedEndpointCorrectionSeconds,
            sample.startClockUncertaintySeconds,
            sample.endClockUncertaintySeconds,
            sample.correctionUncertaintySeconds,
            sample.worstSchedulingJitterSeconds
        ]
        guard values.allSatisfy(\.isFinite),
              sample.startHostSeconds > 0,
              sample.endHostSeconds > sample.startHostSeconds,
              sample.calibratedEndpointCorrectionSeconds >= 0,
              sample.calibratedEndpointCorrectionSeconds
                <= Self.maximumCorrectionSeconds,
              sample.startClockUncertaintySeconds > 0,
              sample.endClockUncertaintySeconds > 0,
              sample.correctionUncertaintySeconds > 0,
              sample.worstSchedulingJitterSeconds >= 0
        else { throw QuietZoneLatencyMeasurementError.invalidTimestamp }

        let uncertainty = sample.startClockUncertaintySeconds
            + sample.endClockUncertaintySeconds
            + sample.correctionUncertaintySeconds
        guard uncertainty <= Self.maximumStageTimingUncertaintySeconds,
              sample.worstSchedulingJitterSeconds
                  <= Self.maximumPerEventJitterSeconds else {
            throw QuietZoneLatencyMeasurementError.invalidTimestamp
        }
        let adjusted = sample.endHostSeconds - sample.startHostSeconds
            - sample.calibratedEndpointCorrectionSeconds
        guard adjusted.isFinite, adjusted > 0,
              adjusted <= QuietZonePhysicalLatencyBudgetAnalyzer
                  .maximumSingleLatencySeconds
        else { throw QuietZoneLatencyMeasurementError.implausibleDuration }
        if let previous = prior.last {
            guard sample.startHostSeconds >
                previous.endHostSeconds + Self.minimumInterEventSeconds,
                sample.measuredAt > previous.measuredAt else {
                throw QuietZoneLatencyMeasurementError.outOfOrderCapture
            }
        }
        // Atomic append: invalid or replayed evidence leaves the run intact.
        samplesByStage[sample.method.stage, default: []].append(sample)
        seenIDs.insert(sample.eventID)
    }

    func measurements(now: Date = Date())
        throws -> [QuietZonePhysicalLatencyEvidence] {
        guard isComplete else {
            throw QuietZoneLatencyMeasurementError.missingRepetitions
        }
        var output: [QuietZonePhysicalLatencyEvidence] = []
        for stage in QuietZonePhysicalLatencyStage.allCases {
            let observations = samplesByStage[stage] ?? []
            guard observations.count >= QuietZonePhysicalLatencyBudgetAnalyzer
                .minimumIndependentRepetitions else {
                throw QuietZoneLatencyMeasurementError.missingRepetitions
            }
            // Check freshness again at publication. An otherwise-valid run
            // must not be replayed after its physical route has aged out.
            guard observations.allSatisfy({
                let age = now.timeIntervalSince($0.measuredAt)
                return age.isFinite && age >= 0 &&
                    age <= QuietZonePhysicalLatencyBudgetAnalyzer
                        .maximumEvidenceAgeSeconds
            }) else { throw QuietZoneLatencyMeasurementError.staleCapture }

            let durations = observations.map {
                $0.endHostSeconds - $0.startHostSeconds
                    - $0.calibratedEndpointCorrectionSeconds
            }.sorted()
            let middle = durations.count / 2
            let median = durations.count.isMultiple(of: 2)
                ? (durations[middle - 1] + durations[middle]) / 2
                : durations[middle]
            let worstJitter = observations.map(\.worstSchedulingJitterSeconds)
                .max() ?? 0
            let uncertainty = observations.map {
                $0.startClockUncertaintySeconds
                    + $0.endClockUncertaintySeconds
                    + $0.correctionUncertaintySeconds
            }.max() ?? 0
            output.append(QuietZonePhysicalLatencyEvidence(
                stage: stage,
                origin: .instrumentedHardware,
                microphoneDeviceID: rig.microphoneID,
                microphoneChannel: rig.microphoneChannel,
                outputDeviceID: rig.outputDeviceID,
                routeLeaseID: rig.routeID,
                synchronizedClockID: rig.clockID,
                sampleRate: rig.sampleRate,
                capturedAt: observations[observations.count - 1].measuredAt,
                independentLaunchIDs: observations.map(\.eventID),
                measuredLatencySeconds: median,
                measuredUpperBoundSeconds: durations[durations.count - 1],
                oneSigmaUncertaintySeconds: uncertainty,
                worstCaseJitterSeconds: worstJitter
            ))
        }
        return output
    }

    /// Never propagates a live-arm grant. Source labels are still caller
    /// supplied and MUST be independently checked in a physical acceptance.
    var liveANCQualified: Bool { false }
}
