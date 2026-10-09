import Foundation

/// The electrical cable-loopback total MUST NOT be interpreted as an ADC
/// component, a DAC component, or an acoustic speaker-to-seat flight time.
/// Each stage needs separate, correctly instrumented physical measurements.
enum QuietZonePhysicalLatencyStage: String, CaseIterable, Sendable {
    case referenceADC
    case referenceProcessing
    case outputDAC
    case speakerToSeat
}

enum QuietZonePhysicalLatencyOrigin: Equatable, Sendable {
    case instrumentedHardware
    case syntheticFixture
    case unverifiedEstimate
}

/// Control-plane, measurement-device-origin metadata. Claims about the source
/// are not cryptographic hardware attestations. Physical commissioning and an
/// independent acceptance protocol must still verify them on the actual Mac.
struct QuietZonePhysicalLatencyEvidence: Sendable {
    let stage: QuietZonePhysicalLatencyStage
    let origin: QuietZonePhysicalLatencyOrigin
    let microphoneDeviceID: String
    let microphoneChannel: Int
    let outputDeviceID: String
    let routeLeaseID: String
    let synchronizedClockID: String
    let sampleRate: Double
    let capturedAt: Date
    let independentLaunchIDs: [String]

    /// Median from independently witnessed, repeatable stage measurements.
    let measuredLatencySeconds: Double
    /// Conservative measured upper bound, before uncertainty and jitter.
    let measuredUpperBoundSeconds: Double
    /// Instrument-derived one-sigma timebase uncertainty, never assumed zero.
    let oneSigmaUncertaintySeconds: Double
    /// Worst observed callback/scheduler variation, not an average.
    let worstCaseJitterSeconds: Double
}

enum QuietZonePhysicalLatencyError: Error, Equatable, LocalizedError {
    case missingStage
    case duplicateStage
    case untrustedEvidence
    case incompatibleProvenance
    case staleEvidence
    case invalidTiming
    case reusedMeasurement
    case missingSurvey

    var errorDescription: String? {
        switch self {
        case .missingStage: return "ADC, processing, DAC and speaker-to-seat delays each require independently measured timing."
        case .duplicateStage: return "A latency stage was supplied more than once."
        case .untrustedEvidence: return "Synthetic or estimated latency cannot qualify the physical timing budget."
        case .incompatibleProvenance: return "The physical route, microphone, synchronized clock or sample rate changed."
        case .staleEvidence: return "Latency evidence must belong to the current calibration session."
        case .invalidTiming: return "A latency bound, jitter estimate or timebase uncertainty is invalid."
        case .reusedMeasurement: return "Each latency-stage repetition needs a distinct physical capture event."
        case .missingSurvey: return "Complete the synchronized listener–upstream–listener survey before evaluating the physical timing budget."
        }
    }
}

/// A diagnostic only: predicted timing reserve is NOT expected attenuation,
/// acoustic coherence, per-frequency ANC feasibility, or live authorization.
struct QuietZonePhysicalLatencyReport: Sendable {
    let stageEvidence: [QuietZonePhysicalLatencyEvidence]
    let nominalPathSeconds: Double
    let upperBoundPathSeconds: Double
    let lowerBoundNoiseLeadSeconds: Double
    let conservativeReserveSeconds: Double
    let requiredSafetyReserveSeconds: Double
    let readiness: QuietZoneFeedForwardReadiness
    let budget: QuietZoneFeedForwardBudget
    let geometryAndTimingEvaluated: Bool = true
    let frequencyResponseVerified: Bool = false
    let cancellationMeasured: Bool = false
    let liveANCQualified: Bool = false

    var spareAfterSafetyReserveSeconds: Double {
        conservativeReserveSeconds - requiredSafetyReserveSeconds
    }
}

/// Reuses the PR96 causal evaluator, but only after verifying that all four
/// physical path segments are independently measured in the same session.
/// Critical: do not ADD the electrical loopback total to these four segments;
/// the loopback is separate diagnostic evidence, not a decomposable path.
struct QuietZonePhysicalLatencyBudgetAnalyzer: Sendable {
    static let minimumIndependentRepetitions = 3
    static let maximumEvidenceAgeSeconds: TimeInterval = 360
    static let maximumSingleLatencySeconds = 0.25
    static let maximumStageUncertaintySeconds = 0.001

    func analyze(
        rig: QuietZoneHardwareCalibrationRig,
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        clock: QuietZoneHALClockTrace,
        stages: [QuietZonePhysicalLatencyEvidence],
        sessionStartedAt: Date,
        now: Date = Date()
    ) throws -> QuietZonePhysicalLatencyReport {
        guard plan.arrivals.count == 3 else {
            throw QuietZonePhysicalLatencyError.missingSurvey
        }
        guard clock.inputDeviceID == rig.microphoneID,
              clock.outputDeviceID == rig.outputDeviceID,
              abs(clock.nominalSampleRate - rig.sampleRate) < 0.5,
              plan.projectID == rig.projectID,
              plan.microphoneStableID == rig.microphoneID
        else { throw QuietZonePhysicalLatencyError.incompatibleProvenance }
        do { _ = try QuietZoneHALClockAnalyzer().analyze(clock) }
        catch { throw QuietZonePhysicalLatencyError.incompatibleProvenance }

        guard stages.count == QuietZonePhysicalLatencyStage.allCases.count else {
            throw QuietZonePhysicalLatencyError.missingStage
        }
        var byStage: [QuietZonePhysicalLatencyStage: QuietZonePhysicalLatencyEvidence] = [:]
        var eventIDs = Set<String>()
        for stage in stages {
            guard byStage[stage.stage] == nil else {
                throw QuietZonePhysicalLatencyError.duplicateStage
            }
            guard stage.origin == .instrumentedHardware else {
                throw QuietZonePhysicalLatencyError.untrustedEvidence
            }
            guard stage.microphoneDeviceID == rig.microphoneID,
                  stage.microphoneChannel == rig.microphoneChannel,
                  stage.outputDeviceID == rig.outputDeviceID,
                  stage.routeLeaseID == rig.routeID,
                  stage.synchronizedClockID == rig.clockID,
                  stage.sampleRate.isFinite,
                  abs(stage.sampleRate - rig.sampleRate) < 0.5
            else { throw QuietZonePhysicalLatencyError.incompatibleProvenance }
            let stageAge = now.timeIntervalSince(stage.capturedAt)
            let elapsed = stage.capturedAt.timeIntervalSince(sessionStartedAt)
            guard stageAge.isFinite, stageAge >= 0,
                  stageAge <= Self.maximumEvidenceAgeSeconds,
                  elapsed.isFinite, elapsed >= 0,
                  elapsed <= Self.maximumEvidenceAgeSeconds
            else { throw QuietZonePhysicalLatencyError.staleEvidence }
            guard stage.independentLaunchIDs.count >= Self.minimumIndependentRepetitions,
                  stage.independentLaunchIDs.count <= 20,
                  stage.independentLaunchIDs.allSatisfy({ !$0.isEmpty })
            else { throw QuietZonePhysicalLatencyError.reusedMeasurement }
            for event in stage.independentLaunchIDs {
                guard eventIDs.insert(event).inserted else {
                    throw QuietZonePhysicalLatencyError.reusedMeasurement
                }
            }
            let numeric = [
                stage.measuredLatencySeconds,
                stage.measuredUpperBoundSeconds,
                stage.oneSigmaUncertaintySeconds,
                stage.worstCaseJitterSeconds
            ]
            guard numeric.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  stage.measuredLatencySeconds > 0,
                  stage.measuredLatencySeconds <= Self.maximumSingleLatencySeconds,
                  stage.measuredUpperBoundSeconds >= stage.measuredLatencySeconds,
                  stage.measuredUpperBoundSeconds <= Self.maximumSingleLatencySeconds,
                  stage.oneSigmaUncertaintySeconds
                      <= Self.maximumStageUncertaintySeconds,
                  stage.worstCaseJitterSeconds <= 0.01
            else { throw QuietZonePhysicalLatencyError.invalidTiming }
            byStage[stage.stage] = stage
        }
        guard let adc = byStage[.referenceADC],
              let processing = byStage[.referenceProcessing],
              let dac = byStage[.outputDAC],
              let acoustic = byStage[.speakerToSeat]
        else { throw QuietZonePhysicalLatencyError.missingStage }

        let ordered = [adc, processing, dac, acoustic]
        let nominal = ordered.reduce(0.0) {
            $0 + $1.measuredLatencySeconds
        }
        let stageUpperExcess = ordered.reduce(0.0) {
            $0 + $1.measuredUpperBoundSeconds - $1.measuredLatencySeconds
        }
        let jitter = ordered.reduce(0.0) {
            $0 + $1.worstCaseJitterSeconds
        }
        let sigma = ordered.reduce(0.0) {
            $0 + $1.oneSigmaUncertaintySeconds
        }
        // Worst segment bounds plus independent jitter and conservative 3σ.
        // PR96 takes the conservative lower bound of the measured noise lead.
        let path = QuietZoneFeedForwardTimingPath(
            synchronizedClockID: rig.clockID,
            microphoneDeviceID: rig.microphoneID,
            microphoneChannel: rig.microphoneChannel,
            routeFingerprint: rig.routeID,
            sampleRate: rig.sampleRate,
            referenceAcquisitionSeconds: adc.measuredLatencySeconds,
            referenceProcessingSeconds: processing.measuredLatencySeconds,
            commandToSeatSeconds:
                dac.measuredLatencySeconds + acoustic.measuredLatencySeconds,
            totalWorstCaseJitterSeconds: stageUpperExcess + jitter,
            timingUncertaintySeconds: sigma,
            // A measured offline latency path is not proof that PR98's
            // continuous realtime scheduling and feedback control are safe.
            lowLatencyTransportVerified: false
        )
        var assessed = plan
        assessed.timingPath = path
        assessed.halClockTrace = clock
        let budget = try QuietZoneFeedForwardBudgetAnalyzer().analyze(
            assessed, project: project, now: now
        )
        guard let lead = budget.conservativePreviewSeconds,
              let reserve = budget.conservativeReserveSeconds,
              let measuredPath = budget.antiNoisePathSeconds,
              abs(measuredPath - nominal) < 0.000000001 else {
            throw QuietZonePhysicalLatencyError.missingSurvey
        }
        return QuietZonePhysicalLatencyReport(
            stageEvidence: ordered,
            nominalPathSeconds: nominal,
            upperBoundPathSeconds: nominal + stageUpperExcess
                + jitter + 3 * sigma,
            lowerBoundNoiseLeadSeconds: lead,
            conservativeReserveSeconds: reserve,
            requiredSafetyReserveSeconds:
                QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds,
            readiness: budget.readiness,
            budget: budget
        )
    }
}
