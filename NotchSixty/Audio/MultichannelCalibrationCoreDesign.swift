import Foundation

/// Swift face of the multichannel calibration alignment maths in `libn60core` (`n60/correct.h` section 8, E21 S7a).
///
/// Offline only: every call allocates and runs on a design task, never from an audio callback. `MultichannelCalibrationDesigner`
/// reaches it when `e21.core-designers` is on; off, the Swift and legacy C maths runs unchanged. Orchestration (seat and
/// measurement selection, matrix assembly, the speaker PEQ and sub optimiser calls, value types) stays in Swift.
enum MultichannelCalibrationCore {
    struct AlignmentSource: Equatable {
        var valid: Bool
        var polarityInverted: Bool
        var delayFrames: UInt32
        var trimDB: Float
        var weightedArrivalFrame: Float
        var weightedLevelDB: Float
        var seatVarianceDBSquared: Float
    }

    struct Alignment: Equatable {
        var referenceArrivalFrame: UInt32
        var commonLevelDB: Float
        var sources: [AlignmentSource]
    }

    static func grid(minimumHz: Double, maximumHz: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(count, 0))
        guard count > 1, n60_correct_calib_grid(minimumHz, maximumHz, UInt32(count), &out) == 0 else { return [] }
        return out
    }

    static func directPolarity(impulse: [Float], arrivalFrame: Int) -> Int8 {
        Int8(n60_correct_calib_direct_polarity(impulse, UInt64(impulse.count), UInt64(max(0, arrivalFrame))))
    }

    static func broadbandLevelDB(frequencies: [Float], magnitudes: [Float], source: MultichannelCalibrationSource) -> Float {
        let count = min(frequencies.count, magnitudes.count)
        var isSub: Int32 = 0
        if case .subwoofer = source { isSub = 1 }
        return n60_correct_calib_broadband_level_db(frequencies, magnitudes, UInt32(count), isSub)
    }

    /// `weights` are per seat, 0 for an excluded seat. `arrival`, `polarity` and `level` are `[source][seat]` flattened.
    static func align(
        weights: [Float], isSpeaker: [Bool], arrival: [UInt32], polarity: [Int8], level: [Float]
    ) -> Alignment? {
        let speaker = isSpeaker.map { UInt8($0 ? 1 : 0) }
        var sources = [n60_correct_calib_align_source](
            repeating: n60_correct_calib_align_source(), count: speaker.count)
        var reference: UInt32 = 0
        var common: Float = 0
        let status: Int32 = weights.withUnsafeBufferPointer { w in
            speaker.withUnsafeBufferPointer { s in
                arrival.withUnsafeBufferPointer { a in
                    polarity.withUnsafeBufferPointer { p in
                        level.withUnsafeBufferPointer { l in
                            sources.withUnsafeMutableBufferPointer { out in
                                var problem = n60_correct_calib_align_problem(
                                    struct_size: UInt32(MemoryLayout<n60_correct_calib_align_problem>.size),
                                    seat_count: UInt32(w.count), source_count: UInt32(s.count),
                                    seat_weight: w.baseAddress, source_is_speaker: s.baseAddress,
                                    arrival_frame: a.baseAddress, polarity: p.baseAddress, level_db: l.baseAddress)
                                var result = n60_correct_calib_align_result(
                                    reference_arrival_frame: 0, common_level_db: 0, sources: out.baseAddress)
                                let status = n60_correct_calib_align(&problem, &result)
                                reference = result.reference_arrival_frame
                                common = result.common_level_db
                                return status
                            }
                        }
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        return Alignment(
            referenceArrivalFrame: reference, commonLevelDB: common,
            sources: sources.map {
                AlignmentSource(
                    valid: $0.valid != 0, polarityInverted: $0.polarity_inverted != 0, delayFrames: $0.delay_frames,
                    trimDB: $0.trim_db, weightedArrivalFrame: $0.weighted_arrival_frame,
                    weightedLevelDB: $0.weighted_level_db, seatVarianceDBSquared: $0.seat_variance_db2)
            })
    }

    /// `arrival` is `[sub][seat]` flattened.
    static func timingOffsets(
        weights: [Float], arrival: [UInt32], additionalDelayMS: [Float], speakerReferenceFrame: UInt32, sampleRate: Double
    ) -> (speakerMS: Double, subMS: Double)? {
        var speaker = 0.0
        var sub = 0.0
        let status: Int32 = weights.withUnsafeBufferPointer { w in
            arrival.withUnsafeBufferPointer { a in
                additionalDelayMS.withUnsafeBufferPointer { d in
                    var problem = n60_correct_calib_timing_problem(
                        struct_size: UInt32(MemoryLayout<n60_correct_calib_timing_problem>.size),
                        seat_count: UInt32(w.count), sub_count: UInt32(d.count), sample_rate: sampleRate,
                        speaker_reference_arrival_frame: speakerReferenceFrame, seat_weight: w.baseAddress,
                        arrival_frame: a.baseAddress, additional_delay_ms: d.baseAddress)
                    return n60_correct_calib_timing_offsets(&problem, &speaker, &sub)
                }
            }
        }
        return status == 0 ? (speaker, sub) : nil
    }

    static func subEQFit(frequencies: [Float], targetDB: [Float], maximumBands: Int) -> [OutputCalibrationEQBand] {
        let count = min(frequencies.count, targetDB.count)
        guard count > 0, maximumBands > 0 else { return [] }
        var f = [Double](repeating: 0, count: maximumBands)
        var g = f
        var q = f
        var produced: UInt32 = 0
        let status = n60_correct_calib_sub_eq_fit(
            frequencies, targetDB, UInt32(count), Float(MultichannelCalibrationDesigner.minimumFrequencyHz),
            Float(MultichannelCalibrationDesigner.subwooferMaximumFrequencyHz), UInt32(maximumBands), &f, &g, &q, &produced)
        guard status == 0 else { return [] }
        return (0..<Int(produced)).map { OutputCalibrationEQBand(frequencyHz: f[$0], gainDB: g[$0], q: q[$0]) }
    }

    /// The multi-sub optimiser (`n60_correct_multisub_optimise`, E21 S7b) over the sub sources of `matrix`, in the legacy
    /// `N60MultiSubOptimize` result shape so the designer's materialisation is unchanged. Nil on any failure.
    /// Standalone: not merged with the bass optimiser (E21 Q5 unanswered).
    static func optimiseSubs(
        matrix: inout N60MultichannelCalibrationMatrix, subCount: Int, targetDB: [Float], settings: N60MultiSubOptimizationSettings
    ) -> N60MultiSubOptimizationResult? {
        let bins = Int(matrix.frequencyCount)
        let seats = Int(matrix.seatCount)
        guard subCount > 0, subCount <= Int(N60_CALIBRATION_MAX_SUBWOOFERS), targetDB.count >= bins else { return nil }
        var sources: [Int] = []
        for sub in 0..<subCount {
            let index = N60MultichannelCalibrationSourceIndexForSubwoofer(&matrix, UInt32(sub))
            guard index >= 0 else { return nil }
            sources.append(Int(index))
        }
        let weights = (0..<seats).map { Float(max(0, MultichannelCalibrationDesigner.seatWeight(matrix: &matrix, index: $0))) }
        var magnitude: [Float] = []
        var phase: [Float] = []
        var arrival: [UInt32] = []
        var valid: [UInt8] = []
        for source in sources {
            for seat in 0..<seats {
                var response = MultichannelCalibrationDesigner.measuredResponse(matrix: &matrix, sourceIndex: source, seatIndex: seat)
                arrival.append(response.directArrivalFrame)
                valid.append(response.valid ? 1 : 0)
                withUnsafePointer(to: &response.magnitudeDB) { tuple in
                    tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)) {
                        magnitude.append(contentsOf: UnsafeBufferPointer(start: $0, count: bins))
                    }
                }
                withUnsafePointer(to: &response.phaseRadians) { tuple in
                    tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)) {
                        phase.append(contentsOf: UnsafeBufferPointer(start: $0, count: bins))
                    }
                }
            }
        }
        let frequencies: [Float] = withUnsafePointer(to: &matrix.frequenciesHz) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)) {
                Array(UnsafeBufferPointer(start: $0, count: bins))
            }
        }
        var core = n60_correct_multisub_opt_settings()
        core.minimum_gain_db = settings.minimumGainDB
        core.maximum_gain_db = settings.maximumGainDB
        core.gain_step_db = settings.gainStepDB
        core.maximum_additional_delay_ms = settings.maximumAdditionalDelayMs
        core.delay_step_ms = settings.delayStepMs
        core.coordinate_passes = settings.coordinatePasses
        core.target_error_weight = settings.targetErrorWeight
        core.seat_variance_weight = settings.seatVarianceWeight
        core.boost_regularisation = settings.boostRegularization
        core.minimum_eq_db = settings.minimumEQDB
        core.maximum_eq_db = settings.maximumEQDB
        core.eq_step_db = settings.eqStepDB
        core.eq_passes = settings.eqPasses
        core.eq_regularisation = settings.eqRegularization
        core.eq_smoothness = settings.eqSmoothness
        core.search_starts = settings.searchStarts
        core.search_rounds = settings.searchRounds
        core.search_evaluation_budget = settings.searchEvaluationBudget
        core.maximum_eq_slope_db_per_octave = settings.maximumEQSlopeDBPerOctave
        core.eq_search_rounds = settings.eqSearchRounds
        core.eq_search_evaluation_budget = settings.eqSearchEvaluationBudget

        var out = n60_correct_multisub_opt_result()
        let status: Int32 = frequencies.withUnsafeBufferPointer { f in
            targetDB.withUnsafeBufferPointer { t in
                weights.withUnsafeBufferPointer { w in
                    magnitude.withUnsafeBufferPointer { m in
                        phase.withUnsafeBufferPointer { ph in
                            arrival.withUnsafeBufferPointer { a in
                                valid.withUnsafeBufferPointer { v in
                                    var problem = n60_correct_multisub_opt_problem()
                                    problem.struct_size = UInt32(MemoryLayout<n60_correct_multisub_opt_problem>.size)
                                    problem.sub_count = UInt32(subCount)
                                    problem.seat_count = UInt32(seats)
                                    problem.bin_count = UInt32(bins)
                                    problem.sample_rate = matrix.sampleRate
                                    problem.frequency_hz = f.baseAddress
                                    problem.target_db = t.baseAddress
                                    problem.seat_weight = w.baseAddress
                                    problem.magnitude_db = m.baseAddress
                                    problem.phase_rad = ph.baseAddress
                                    problem.arrival_frame = a.baseAddress
                                    problem.valid = v.baseAddress
                                    problem.settings = core
                                    out.struct_size = UInt32(MemoryLayout<n60_correct_multisub_opt_result>.size)
                                    return n60_correct_multisub_optimise(&problem, &out)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard status == 0 else { return nil }

        var result = N60MultiSubOptimizationResult()
        result.subwooferCount = UInt32(subCount)
        result.frequencyCount = UInt32(bins)
        withUnsafeMutablePointer(to: &result.gainDB) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { dst in
                withUnsafePointer(to: &out.gain_db) {
                    $0.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { src in
                        for i in 0..<subCount { dst[i] = src[i] }
                    }
                }
            }
        }
        withUnsafeMutablePointer(to: &result.additionalDelayMs) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { dst in
                withUnsafePointer(to: &out.additional_delay_ms) {
                    $0.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { src in
                        for i in 0..<subCount { dst[i] = src[i] }
                    }
                }
            }
        }
        withUnsafeMutablePointer(to: &result.polarityInverted) { tuple in
            tuple.withMemoryRebound(to: Bool.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { dst in
                withUnsafePointer(to: &out.polarity_inverted) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS)) { src in
                        for i in 0..<subCount { dst[i] = src[i] != 0 }
                    }
                }
            }
        }
        withUnsafeMutablePointer(to: &result.perSubEQTargetDB) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS * N60_CALIBRATION_MAX_FREQUENCY_BINS)) { dst in
                withUnsafePointer(to: &out.eq_target_db) {
                    $0.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_SUBWOOFERS * N60_CALIBRATION_MAX_FREQUENCY_BINS)) { src in
                        let stride = Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)
                        for sub in 0..<subCount { for bin in 0..<bins { dst[sub * stride + bin] = src[sub * stride + bin] } }
                    }
                }
            }
        }
        result.objective = out.objective
        result.weightedTargetErrorDBSquared = out.weighted_target_error_db2
        result.seatVarianceDBSquared = out.seat_variance_db2
        result.searchEvaluations = out.search_evaluations
        result.searchStartsRun = out.search_starts_run
        result.searchBudgetExhausted = out.search_budget_exhausted != 0
        result.eqSearchEvaluations = out.eq_search_evaluations
        result.eqSearchBudgetExhausted = out.eq_search_budget_exhausted != 0
        return result
    }
}
