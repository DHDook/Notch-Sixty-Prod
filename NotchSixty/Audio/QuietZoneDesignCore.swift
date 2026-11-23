import Foundation

/// Swift face of the ANC design maths in `libn60core` (`n60/anc_design.h`, E21 S10a): the Quiet Zone virtual seat designer,
/// the causal FIR compiler, the HAL clock analysis and the upstream survey.
///
/// Offline only: every call allocates and runs on a design or survey task, never from an audio callback. The callers reach
/// it when `e21.core-designers` is on; off, the Swift maths they hold runs unchanged (the parity reference, deleted in S14).
/// Readiness, evidence capture and value types stay in Swift. Nothing here arms or enables live ANC: the results are the same
/// previews and diagnostics the Swift maths produced (`safePreviewOnly`, `liveDeploymentAuthorized == false`).
enum QuietZoneDesignCore {
    static func complex(_ z: ActiveQuietZoneComplex) -> n60_anc_complex { n60_anc_complex(re: z.real, im: z.imaginary) }
    static func complex(_ z: n60_anc_complex) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: z.re, imaginary: z.im) }

    static func coreBand(_ band: QuietZoneVirtualSeatBand) -> n60_anc_seat_band {
        n60_anc_seat_band(
            frequencyHz: band.frequencyHz, sourceToReference: complex(band.sourceToReference),
            sourceToListener: complex(band.sourceToListener), leftSecondaryAtListener: complex(band.leftSecondaryAtListener),
            rightSecondaryAtListener: complex(band.rightSecondaryAtListener),
            leftLeakageAtReference: complex(band.leftLeakageAtReference),
            rightLeakageAtReference: complex(band.rightLeakageAtReference), measuredCoherence: band.measuredCoherence)
    }

    /// The conservative reserve the budget allows, NaN when the budget is not physically plausible (the core refuses it).
    static func reserve(_ budget: QuietZoneFeedForwardBudget) -> Double {
        guard budget.readiness == .physicallyPlausible, let reserve = budget.conservativeReserveSeconds else { return .nan }
        return reserve
    }

    /// The bass path watch tolerance that divides the leakage limit in shared-sub bands.
    static var pathChangeToleranceDB: Double { BassPathWatch.gainToleranceDB }

    // MARK: Virtual seat designer

    static func seatError(_ code: Int32) -> QuietZoneVirtualSeatError {
        switch code {
        case N60_ANC_SEAT_ERR_MEASUREMENTS: return .inadequateMeasurements
        case N60_ANC_SEAT_ERR_COHERENCE: return .insufficientCoherence
        case N60_ANC_SEAT_ERR_AUTHORITY: return .insufficientActuatorAuthority
        case N60_ANC_SEAT_ERR_LEAKAGE: return .excessiveReferenceLeakage
        case N60_ANC_SEAT_ERR_BENEFIT: return .insufficientExpectedBenefit
        case N60_ANC_SEAT_ERR_BUDGET: return .budgetUnavailable
        default: return .invalidAcousticModel
        }
    }

    /// `configuration` must already be validated (the Swift designer validates before calling).
    static func design(
        measurements: [QuietZoneVirtualSeatBand], budget: QuietZoneFeedForwardBudget,
        configuration: ActiveQuietZoneConfiguration, bassConditioning: Bool
    ) throws -> QuietZoneVirtualSeatDesign {
        let bands = measurements.map(coreBand)
        var options = n60_anc_seat_options()
        options.structSize = UInt32(MemoryLayout<n60_anc_seat_options>.size)
        options.reserveSeconds = reserve(budget)
        options.minimumFrequencyHz = configuration.minimumFrequencyHz
        options.maximumFrequencyHz = configuration.maximumFrequencyHz
        options.maximumPerSourceTonePeakDBFS = configuration.maximumPerSourceTonePeakDBFS
        options.maximumAggregateSourcePeakDBFS = configuration.maximumAggregateSourcePeakDBFS
        options.bassConditioning = bassConditioning ? 1 : 0
        options.pathChangeToleranceDB = pathChangeToleranceDB
        var results = [n60_anc_seat_band_result](repeating: n60_anc_seat_band_result(), count: max(bands.count, 1))
        var worst = 0.0
        var coherence = 0.0
        let code = bands.withUnsafeBufferPointer { b in
            n60_anc_virtual_seat_design(b.baseAddress, UInt32(bands.count), &options, &results, &worst, &coherence)
        }
        guard code == 0 else { throw seatError(code) }
        return QuietZoneVirtualSeatDesign(
            bands: results.prefix(bands.count).map {
                QuietZoneVirtualSeatBandResult(
                    frequencyHz: $0.frequencyHz, disturbanceTransfer: complex($0.disturbanceTransfer),
                    leftFilter: complex($0.leftFilter), rightFilter: complex($0.rightFilter),
                    predictedResidual: complex($0.predictedResidual), modeledReductionDB: $0.modeledReductionDB,
                    predictedReferenceLeakageFraction: $0.predictedReferenceLeakageFraction)
            },
            worstModeledReductionDB: worst, minimumMeasuredCoherence: coherence)
    }

    // MARK: Causal FIR compiler

    static func firError(_ code: Int32) -> QuietZoneCausalFIRError {
        switch code {
        case N60_ANC_FIR_ERR_CLOCK: return .invalidReferenceClock
        case N60_ANC_FIR_ERR_RANK: return .rankDeficient
        case N60_ANC_FIR_ERR_GAIN: return .excessiveGain
        case N60_ANC_FIR_ERR_NONCAUSAL: return .nonCausalTarget
        case N60_ANC_FIR_ERR_REDUCTION: return .inadequateModeledReduction
        default: return .invalidModel
        }
    }

    static func compile(
        design: QuietZoneVirtualSeatDesign, measurements: [QuietZoneVirtualSeatBand], budget: QuietZoneFeedForwardBudget,
        sampleRate: Double, tapCount: Int, bassConditioning: Bool
    ) throws -> QuietZoneCausalFIRCandidate {
        let bands = measurements.sorted { $0.frequencyHz < $1.frequencyHz }.map(coreBand)
        let targets = design.bands.sorted { $0.frequencyHz < $1.frequencyHz }.map {
            n60_anc_seat_band_result(
                frequencyHz: $0.frequencyHz, disturbanceTransfer: complex($0.disturbanceTransfer),
                leftFilter: complex($0.leftFilter), rightFilter: complex($0.rightFilter),
                predictedResidual: complex($0.predictedResidual), modeledReductionDB: $0.modeledReductionDB,
                predictedReferenceLeakageFraction: $0.predictedReferenceLeakageFraction)
        }
        var options = n60_anc_fir_options()
        options.structSize = UInt32(MemoryLayout<n60_anc_fir_options>.size)
        options.reserveSeconds = reserve(budget)
        options.sampleRate = sampleRate
        options.tapCount = UInt32(clamping: max(tapCount, 0))
        options.bassConditioning = bassConditioning ? 1 : 0
        options.pathChangeToleranceDB = pathChangeToleranceDB
        var result = n60_anc_fir_result()
        let code = bands.withUnsafeBufferPointer { b in
            targets.withUnsafeBufferPointer { t in
                n60_anc_causal_fir_compile(b.baseAddress, t.baseAddress, UInt32(bands.count), &options, &result)
            }
        }
        guard code == 0 else { throw firError(code) }
        let count = Int(result.tapCount)
        let left = withUnsafeBytes(of: &result.leftTaps) { Array($0.bindMemory(to: Float.self).prefix(count)) }
        let right = withUnsafeBytes(of: &result.rightTaps) { Array($0.bindMemory(to: Float.self).prefix(count)) }
        return QuietZoneCausalFIRCandidate(
            sampleRate: sampleRate, leftTaps: left, rightTaps: right,
            worstPredictedReductionDB: result.worstPredictedReductionDB,
            maximumRelativeFitError: result.maximumRelativeFitError,
            maximumReferenceEchoFraction: result.maximumReferenceEchoFraction)
    }

    // MARK: HAL clock analysis

    static func clockError(_ code: Int32) -> QuietZoneHALClockError {
        switch code {
        case N60_ANC_CLOCK_ERR_INSUFFICIENT: return .insufficientObservation
        case N60_ANC_CLOCK_ERR_DISCONTINUITY: return .clockDiscontinuity
        case N60_ANC_CLOCK_ERR_DRIFT: return .excessiveDrift
        case N60_ANC_CLOCK_ERR_JITTER: return .excessiveJitter
        default: return .invalidTimebase
        }
    }

    static func analyzeClock(_ trace: QuietZoneHALClockTrace) throws -> QuietZoneHALClockHealth {
        let input = trace.inputObservations.map { n60_anc_clock_observation(hostTimeSeconds: $0.hostTimeSeconds, sampleFrame: $0.sampleFrame) }
        let output = trace.outputObservations.map { n60_anc_clock_observation(hostTimeSeconds: $0.hostTimeSeconds, sampleFrame: $0.sampleFrame) }
        var health = n60_anc_clock_health()
        let code = input.withUnsafeBufferPointer { i in
            output.withUnsafeBufferPointer { o in
                n60_anc_hal_clock_analyze(trace.nominalSampleRate, i.baseAddress, UInt32(input.count), o.baseAddress,
                                          UInt32(output.count), &health)
            }
        }
        guard code == 0 else { throw clockError(code) }
        return QuietZoneHALClockHealth(
            measuredInputRateHz: health.measuredInputRateHz, measuredOutputRateHz: health.measuredOutputRateHz,
            relativeDriftPPM: health.relativeDriftPPM, worstInputResidualSeconds: health.worstInputResidualSeconds,
            worstOutputResidualSeconds: health.worstOutputResidualSeconds,
            observationDurationSeconds: health.observationDurationSeconds, qualifiedForLoopbackBench: true)
    }

    // MARK: Upstream survey

    /// Owns a core lead estimator. Control plane only; one queue.
    final class LeadHandle {
        let pointer: OpaquePointer
        let decimation: Int

        init?(sampleRate: Double) {
            guard let pointer = n60_anc_upstream_lead_create(sampleRate) else { return nil }
            self.pointer = pointer
            decimation = Int(n60_anc_upstream_lead_decimation(pointer))
        }

        deinit { n60_anc_upstream_lead_destroy(pointer) }

        func markDiscontinuity() { n60_anc_upstream_lead_mark_discontinuity(pointer) }

        /// Set when a core ingest failed (allocation): the streams may be truncated, so `estimate()` fails closed (nil).
        private(set) var failed = false

        func ingest(reference: [Float], error: [Float]) {
            if n60_anc_upstream_lead_ingest(pointer, reference, error, UInt32(min(reference.count, error.count))) != 0 { failed = true }
        }

        var decimatedCount: Int { Int(n60_anc_upstream_lead_decimated_count(pointer)) }

        func decimated() -> (reference: [Float], error: [Float]) {
            let count = decimatedCount
            var r = [Float](repeating: 0, count: count)
            var e = [Float](repeating: 0, count: count)
            _ = n60_anc_upstream_lead_decimated(pointer, &r, &e, UInt32(count))
            return (r, e)
        }

        func estimate() -> QuietZoneUpstreamLeadEstimator.Estimate? {
            var out = n60_anc_upstream_estimate()
            guard !failed, n60_anc_upstream_lead_estimate(pointer, &out) == 1 else { return nil }
            return QuietZoneUpstreamLeadEstimator.Estimate(
                leadSeconds: out.leadSeconds, peakCorrelation: out.peakCorrelation, resolutionSeconds: out.resolutionSeconds)
        }
    }

    static func verdict(_ code: Int32) -> QuietZoneUpstreamVerdict {
        switch code {
        case N60_ANC_UPSTREAM_MOVE_FURTHER_OUT: return .moveFurtherOut
        case N60_ANC_UPSTREAM_LOW_COHERENCE: return .lowCoherence
        case N60_ANC_UPSTREAM_NO_COMMON_NOISE: return .noCommonNoise
        default: return .suitable
        }
    }

    static func assess(
        estimate: QuietZoneUpstreamLeadEstimator.Estimate?, bands survey: [QuietZoneFeedForwardSurveyBand],
        latencySeconds: Double, flightSeconds: Double, clockOffsetErrorSeconds: Double,
        referenceKind: QuietZoneReferenceInputKind
    ) -> QuietZoneUpstreamAssessment {
        let rows = survey.map { n60_anc_upstream_survey_band(frequencyHz: $0.frequencyHz, coherence: $0.coherence) }
        var bands = [n60_anc_upstream_survey_band](repeating: n60_anc_upstream_survey_band(), count: max(rows.count, 1))
        var bounds = [Double](repeating: 0, count: max(rows.count, 1))
        var out = n60_anc_upstream_assessment()
        var core = estimate.map {
            n60_anc_upstream_estimate(leadSeconds: $0.leadSeconds, peakCorrelation: $0.peakCorrelation, resolutionSeconds: $0.resolutionSeconds)
        }
        if var value = core {
            n60_anc_upstream_assess(&value, rows, UInt32(rows.count), latencySeconds, flightSeconds, clockOffsetErrorSeconds,
                                    &bands, &bounds, &out)
            core = value
        } else {
            n60_anc_upstream_assess(nil, rows, UInt32(rows.count), latencySeconds, flightSeconds, clockOffsetErrorSeconds,
                                    &bands, &bounds, &out)
        }
        let used = Int(out.bandCount)
        return QuietZoneUpstreamAssessment(
            verdict: verdict(out.verdict), leadSeconds: out.leadSeconds, leadUncertaintySeconds: out.leadUncertaintySeconds,
            budgetSeconds: out.budgetSeconds, meanCoherence: out.meanCoherence,
            bands: (0..<used).map {
                QuietZoneUpstreamAssessment.Band(
                    frequencyHz: bands[$0].frequencyHz, coherence: bands[$0].coherence, predictedReductionDB: bounds[$0])
            },
            predictedReductionDB: out.hasPrediction != 0 ? out.predictedReductionDB : nil, referenceKind: referenceKind)
    }
}
