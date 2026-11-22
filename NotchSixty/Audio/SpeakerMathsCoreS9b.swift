import Foundation

/// Swift face of the S9b speaker maths in `libn60core` (`n60/speaker.h` v2): crossover feasibility, the cross-domain
/// classifier, the early-window magnitude and the design-engine preview scoring. Offline only, on design tasks; the
/// callers reach it when `e21.core-designers` is on and otherwise run their unchanged Swift maths (the parity reference,
/// deleted in S14). Evidence qualification, identities and value types stay in Swift.
extension SpeakerMathsCore {
    /// Calls `body` with a base pointer for each array, all alive for the duration. Empty arrays get a dummy pointer.
    private static func withPointers<R>(_ arrays: [[Double]], _ body: ([UnsafePointer<Double>]) -> R) -> R {
        var dummy = 0.0
        return withUnsafePointer(to: &dummy) { zero in
            func go(_ index: Int, _ acc: [UnsafePointer<Double>]) -> R {
                if index == arrays.count { return body(acc) }
                return arrays[index].withUnsafeBufferPointer { go(index + 1, acc + [$0.baseAddress ?? zero]) }
            }
            return go(0, [])
        }
    }

    // MARK: Crossover feasibility

    static func coreOptions(_ options: SpeakerOptimizerCrossoverOptions) -> n60_speaker_crossover_options {
        n60_speaker_crossover_options(
            center_hz: options.centerHz, band_width_octaves: options.bandWidthOctaves,
            frequency_point_count: UInt32(options.frequencyPointCount),
            maximum_additional_delay_ms: options.maximumAdditionalDelayMs, delay_step_ms: options.delayStepMs,
            maximum_arrival_gap_ms: options.maximumArrivalGapMs, maximum_seat_regression_db: options.maximumSeatRegressionDB,
            minimum_aggregate_improvement_db: options.minimumAggregateImprovementDB,
            maximum_modeled_sum_above_strongest_db: options.maximumModeledSumAboveStrongestSourceDB)
    }

    /// Per-seat complex responses of both sources on the analysis grid, row-major `[seat][point]`.
    struct CrossoverEvidence {
        var sampleRate: Double
        var frequenciesHz: [Double]
        var weights: [Double]
        var mainReal: [Double], mainImag: [Double], subReal: [Double], subImag: [Double]
    }

    private static func withCrossoverProblem<R>(
        _ evidence: CrossoverEvidence, options: SpeakerOptimizerCrossoverOptions, _ body: (inout n60_speaker_crossover_problem) -> R
    ) -> R {
        let points = evidence.frequenciesHz.count
        return withPointers([evidence.frequenciesHz, evidence.mainReal, evidence.mainImag, evidence.subReal, evidence.subImag,
                             evidence.weights]) { p in
            var problem = n60_speaker_crossover_problem()
            problem.struct_size = UInt32(MemoryLayout<n60_speaker_crossover_problem>.size)
            problem.seat_count = UInt32(evidence.weights.count)
            problem.point_count = UInt32(points)
            problem.sample_rate = evidence.sampleRate
            problem.frequency_hz = p[0]
            problem.main_real = p[1]; problem.main_imag = p[2]; problem.sub_real = p[3]; problem.sub_imag = p[4]
            problem.seat_weight = p[5]
            problem.options = coreOptions(options)
            return body(&problem)
        }
    }

    /// The analysis grid (`frequency_point_count` log-spaced values across the band).
    static func crossoverFrequencies(_ options: SpeakerOptimizerCrossoverOptions) -> [Double]? {
        var core = coreOptions(options)
        var out = [Double](repeating: 0, count: options.frequencyPointCount)
        guard n60_speaker_crossover_frequencies(&core, &out, UInt32(out.count)) == 0 else { return nil }
        return out
    }

    /// One source's complex response at `frequencies` (mean of the interpolated captures rotated by the arrival delay).
    static func crossoverResponse(
        grid: [Double], magnitudes: [[Double]], phases: [[Double]], arrival: Double, frequencies: [Double]
    ) -> (real: [Double], imag: [Double])? {
        guard !magnitudes.isEmpty, magnitudes.count == phases.count,
              magnitudes.allSatisfy({ $0.count == grid.count }), phases.allSatisfy({ $0.count == grid.count }) else { return nil }
        var re = [Double](repeating: 0, count: frequencies.count)
        var im = re
        let flatMagnitude = magnitudes.flatMap { $0 }, flatPhase = phases.flatMap { $0 }
        let status = n60_speaker_crossover_response(
            grid, UInt32(grid.count), UInt32(magnitudes.count), flatMagnitude, flatPhase, arrival, frequencies,
            UInt32(frequencies.count), &re, &im)
        return status == 0 ? (re, im) : nil
    }

    struct CrossoverSearch {
        var accepted: Bool
        var delayMs: Double
        var invertSubPolarity: Bool
        var improvementDB: Double
        var baselineLevelsDB: [Double]
        var selectedLevelsDB: [Double]
        var selectedPeakAboveDB: [Double]
    }

    static func crossoverSearch(evidence: CrossoverEvidence, options: SpeakerOptimizerCrossoverOptions) -> CrossoverSearch? {
        let seats = evidence.weights.count
        var baseline = [Double](repeating: 0, count: seats)
        var selected = baseline
        var peak = baseline
        var result = n60_speaker_crossover_result()
        let status: Int32 = baseline.withUnsafeMutableBufferPointer { b in
            selected.withUnsafeMutableBufferPointer { s in
                peak.withUnsafeMutableBufferPointer { k in
                    result.baseline_level_db = b.baseAddress
                    result.selected_level_db = s.baseAddress
                    result.selected_peak_above_db = k.baseAddress
                    return withCrossoverProblem(evidence, options: options) { n60_speaker_crossover_search(&$0, &result) }
                }
            }
        }
        guard status == 0 else { return nil }
        return CrossoverSearch(
            accepted: result.accepted != 0, delayMs: result.delay_ms, invertSubPolarity: result.invert_sub_polarity != 0,
            improvementDB: result.aggregate_improvement_db, baselineLevelsDB: baseline, selectedLevelsDB: selected,
            selectedPeakAboveDB: peak)
    }

    struct CrossoverSensitivity {
        var samples: [SpeakerOptimizerPhaseReferenceSensitivitySample]
        var worstImprovementDB: Double
        var worstSeatRegressionDB: Double
        var worstSumAboveStrongestDB: Double
        var reasons: UInt32
    }

    static func crossoverSensitivity(
        evidence: CrossoverEvidence, options: SpeakerOptimizerCrossoverOptions, delayMs: Double, invert: Bool,
        sensitivity: SpeakerOptimizerPhaseReferenceSensitivityOptions
    ) -> CrossoverSensitivity? {
        var core = n60_speaker_sensitivity_options(
            maximum_clock_offset_ms: sensitivity.maximumUnknownClockOffsetMs, sample_count: UInt32(sensitivity.sampleCount),
            minimum_worst_improvement_db: sensitivity.minimumWorstCaseImprovementDB,
            maximum_worst_seat_regression_db: sensitivity.maximumWorstSeatRegressionDB,
            maximum_sum_above_strongest_db: sensitivity.maximumSummedAboveStrongestSourceDB)
        var samples = [n60_speaker_sensitivity_sample](repeating: n60_speaker_sensitivity_sample(), count: sensitivity.sampleCount)
        var summary = n60_speaker_sensitivity_summary()
        let status = withCrossoverProblem(evidence, options: options) {
            n60_speaker_crossover_sensitivity(&$0, delayMs, invert ? 1 : 0, &core, &samples, &summary)
        }
        guard status == 0 else { return nil }
        return CrossoverSensitivity(
            samples: samples.map {
                SpeakerOptimizerPhaseReferenceSensitivitySample(
                    assumedSubClockOffsetMs: $0.clock_offset_ms, aggregateModeledImprovementDB: $0.improvement_db,
                    worstSeatRegressionDB: $0.seat_regression_db, maximumSummedAboveStrongestSourceDB: $0.sum_above_strongest_db)
            },
            worstImprovementDB: summary.worst_improvement_db, worstSeatRegressionDB: summary.worst_seat_regression_db,
            worstSumAboveStrongestDB: summary.worst_sum_above_strongest_db, reasons: summary.reasons)
    }

    // MARK: Cross-domain classifier

    static func meanInterpolated(grid: [Double], magnitudes: [[Double]], at frequencies: [Double]) -> [Double]? {
        guard !magnitudes.isEmpty, magnitudes.allSatisfy({ $0.count == grid.count }) else { return nil }
        var out = [Double](repeating: 0, count: frequencies.count)
        let status = n60_speaker_mean_interpolated(
            grid, UInt32(grid.count), magnitudes.flatMap { $0 }, UInt32(magnitudes.count), frequencies,
            UInt32(frequencies.count), &out)
        return status == 0 ? out : nil
    }

    static func classifyCrossDomain(
        frequencies: [Double], characterization: [Double], seats: [[Double]], options: SpeakerOptimizerCrossDomainOptions
    ) -> [SpeakerOptimizerCrossDomainPoint]? {
        let count = frequencies.count
        guard count > 0, characterization.count == count, !seats.isEmpty, seats.allSatisfy({ $0.count == count }) else { return nil }
        var problem = n60_speaker_cross_domain_problem()
        problem.struct_size = UInt32(MemoryLayout<n60_speaker_cross_domain_problem>.size)
        problem.point_count = UInt32(count)
        problem.seat_count = UInt32(seats.count)
        problem.options = n60_speaker_classify_options(
            smoothing_octaves: options.smoothingOctaves, significant_deviation_db: options.significantDeviationDB,
            near_speaker_flat_tolerance_db: options.nearSpeakerFlatToleranceDB,
            speaker_agreement_tolerance_db: options.speakerAgreementToleranceDB,
            maximum_persistent_seat_spread_db: options.maximumPersistentSeatSpreadDB,
            room_seat_spread_threshold_db: options.roomSeatSpreadThresholdDB,
            minimum_point_count: UInt32(options.minimumPointCount))
        var points = [n60_speaker_cross_domain_point](repeating: n60_speaker_cross_domain_point(), count: count)
        let status: Int32 = withPointers([frequencies, characterization, seats.flatMap { $0 }]) { p in
            problem.frequency_hz = p[0]; problem.characterization_db = p[1]; problem.seat_db = p[2]
            return n60_speaker_cross_domain_classify(&problem, &points)
        }
        guard status == 0 else { return nil }
        return zip(frequencies, points).map { frequency, point in
            let label: SpeakerOptimizerDeviationClassification
            switch point.classification {
            case UInt32(N60_SPEAKER_CLASS_PERSISTENT): label = .speakerPersistent
            case UInt32(N60_SPEAKER_CLASS_ROOM_SEAT): label = .roomSeatDependent
            case UInt32(N60_SPEAKER_CLASS_NO_DEVIATION): label = .noMaterialDeviation
            default: label = .ambiguous
            }
            return SpeakerOptimizerCrossDomainPoint(
                frequencyHz: frequency, characterizationResidualDB: point.characterization_residual_db,
                listeningMeanResidualDB: point.listening_mean_residual_db, listeningSeatSpreadDB: point.listening_seat_spread_db,
                classification: label)
        }
    }

    // MARK: Early window

    enum EarlyWindowFailure: Error { case settings, arrival, short, band, invalid }

    /// Gated DFT magnitude at the transfer-function frequencies kept by the gate; calibration is added by the caller.
    static func earlyWindow(
        impulse: [Float], sampleRate: Double, arrivalSeconds: Double, usableLowHz: Double, usableHighHz: Double,
        transferFrequenciesHz: [Double], settings: SpeakerOptimizerEarlyWindowSettings
    ) -> Result<(frequencies: [Double], magnitudesDB: [Double], preMs: Double, postMs: Double), EarlyWindowFailure> {
        var core = n60_speaker_early_window_settings(
            pre_arrival_ms: settings.preArrivalMilliseconds, post_arrival_ms: settings.postArrivalMilliseconds,
            fade_out_ms: settings.fadeOutMilliseconds, minimum_cycles: settings.minimumCyclesForReliableMagnitude)
        var magnitudes = [Double](repeating: 0, count: transferFrequenciesHz.count)
        var result = n60_speaker_early_window_result()
        let status = n60_speaker_early_window(
            impulse, UInt32(impulse.count), sampleRate, arrivalSeconds, usableLowHz, usableHighHz, transferFrequenciesHz,
            UInt32(transferFrequenciesHz.count), &core, &magnitudes, &result)
        switch status {
        case 0: break
        case N60_SPEAKER_ERR_SETTINGS: return .failure(.settings)
        case N60_SPEAKER_ERR_ARRIVAL: return .failure(.arrival)
        case N60_SPEAKER_ERR_SHORT: return .failure(.short)
        case N60_SPEAKER_ERR_BAND: return .failure(.band)
        default: return .failure(.invalid)
        }
        let range = Int(result.first_index)..<Int(result.first_index + result.count)
        return .success((Array(transferFrequenciesHz[range]), Array(magnitudes[range]),
                         result.retained_pre_arrival_ms, result.retained_post_arrival_ms))
    }

    // MARK: Design-engine preview

    struct PreviewScore {
        var targets: [Double]
        var correction: [Double]
        var rmseBefore: Double
        var rmseAfter: Double
        var reverted: Bool
    }

    static func designPreview(
        frequencies: [Double], perSeat: [[Double]], weights: [Double], options: SpeakerOptimizerDesignOptions
    ) -> PreviewScore? {
        let count = frequencies.count
        guard count > 0, !perSeat.isEmpty, perSeat.count == weights.count, perSeat.allSatisfy({ $0.count == count }) else { return nil }
        var problem = n60_speaker_preview_problem()
        problem.struct_size = UInt32(MemoryLayout<n60_speaker_preview_problem>.size)
        problem.bin_count = UInt32(count)
        problem.seat_count = UInt32(perSeat.count)
        problem.options = n60_speaker_preview_options(
            maximum_cut_db: options.maximumCutDB, maximum_boost_db: options.maximumBoostDB,
            smoothing_octaves: options.smoothingOctaves, target_tilt_db_per_octave: options.targetTiltDBPerOctave,
            maximum_seat_degradation_db: options.maximumSeatDegradationDB)
        var target = [Double](repeating: 0, count: count)
        var correction = target
        var result = n60_speaker_preview_result()
        let status: Int32 = target.withUnsafeMutableBufferPointer { t in
            correction.withUnsafeMutableBufferPointer { c in
                result.target_db = t.baseAddress
                result.correction_db = c.baseAddress
                return withPointers([frequencies, perSeat.flatMap { $0 }, weights]) { p in
                    problem.frequency_hz = p[0]; problem.seat_db = p[1]; problem.seat_weight = p[2]
                    return n60_speaker_design_preview(&problem, &result)
                }
            }
        }
        guard status == 0 else { return nil }
        return PreviewScore(targets: target, correction: correction, rmseBefore: result.rmse_before_db,
                            rmseAfter: result.rmse_after_db, reverted: result.reverted != 0)
    }
}
