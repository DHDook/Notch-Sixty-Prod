import Foundation

/// Swift face of the speaker maths in `libn60core` (`n60/speaker.h`, E21 S9a).
///
/// Offline only: every call allocates and runs on a design task, never from an audio callback. The callers reach it when
/// `e21.core-designers` is on; off, the Swift and legacy C maths they hold runs unchanged. Evidence gathering, masks,
/// previews and value types stay in Swift.
enum SpeakerMathsCore {
    /// Log-frequency interpolation of `values` over ascending `frequencies` (the calibration designer's `interpolate`).
    static func interpolate(frequencies: [Double], values: [Double], at frequency: Double) -> Double? {
        var out = 0.0
        guard frequencies.count == values.count,
              n60_speaker_interpolate_log(frequencies, values, UInt32(frequencies.count), frequency, &out) == 0
        else { return nil }
        return out
    }

    /// The target curve's gain at `frequency` (the calibration designer's `targetGainDB`); 0 for fewer than two points.
    static func targetGainDB(_ target: RoomCorrectionTargetCurve?, at frequency: Double) -> Double {
        guard let target, target.points.count >= 2 else { return 0 }
        return n60_speaker_target_gain_db(
            target.points.map(\.frequencyHz), target.points.map(\.gainDB), UInt32(target.points.count), frequency)
    }

    // MARK: Speaker correction designer (multichannel calibration)

    /// The legacy `N60SpeakerCorrectionDesignPlan` result shape, so the designer's materialisation is unchanged.
    /// `alignment` carries trim, delay and polarity per matrix source (from the core alignment). Nil on any failure.
    static func designCorrectionPlan(
        matrix: inout N60MultichannelCalibrationMatrix, alignment: N60SpeakerAlignmentPlan, targetDB: [Float],
        settings: N60SpeakerCorrectionSettings
    ) -> N60SpeakerCorrectionPlan? {
        let bins = Int(matrix.frequencyCount)
        let seats = Int(matrix.seatCount)
        guard bins > 0, seats > 0, targetDB.count >= bins else { return nil }
        let total = Int(matrix.sourceCount)
        var speakerSources: [Int] = []
        var roles: [N60ProgramChannelRole] = []
        withUnsafePointer(to: &matrix.sources) { tuple in
            tuple.withMemoryRebound(to: N60CalibrationSourceDescriptor.self, capacity: Int(N60_CALIBRATION_MAX_SOURCES)) { flat in
                for index in 0..<total where flat[index].kind == N60CalibrationSourceKindProgramSpeaker {
                    speakerSources.append(index)
                    roles.append(flat[index].role)
                }
            }
        }
        guard !speakerSources.isEmpty, speakerSources.count <= Int(N60_MAX_PROGRAM_CHANNELS) else { return nil }

        let weights = (0..<seats).map { Float(max(0, MultichannelCalibrationDesigner.seatWeight(matrix: &matrix, index: $0))) }
        var magnitude: [Float] = []
        var valid: [UInt8] = []
        for source in speakerSources {
            for seat in 0..<seats {
                var response = MultichannelCalibrationDesigner.measuredResponse(matrix: &matrix, sourceIndex: source, seatIndex: seat)
                valid.append(response.valid ? 1 : 0)
                withUnsafePointer(to: &response.magnitudeDB) { tuple in
                    tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)) {
                        magnitude.append(contentsOf: UnsafeBufferPointer(start: $0, count: bins))
                    }
                }
            }
        }
        let frequencies: [Float] = withUnsafePointer(to: &matrix.frequenciesHz) { tuple in
            tuple.withMemoryRebound(to: Float.self, capacity: Int(N60_CALIBRATION_MAX_FREQUENCY_BINS)) {
                Array(UnsafeBufferPointer(start: $0, count: bins))
            }
        }
        var trim: [Float] = []
        var delay: [UInt32] = []
        var inverted: [UInt8] = []
        var alignment = alignment
        withUnsafePointer(to: &alignment.sources) { tuple in
            tuple.withMemoryRebound(to: N60SpeakerAlignmentResult.self, capacity: Int(N60_CALIBRATION_MAX_SOURCES)) { flat in
                for source in speakerSources {
                    let item = flat[source]
                    let aligned = source < Int(alignment.sourceCount) && item.valid
                    trim.append(aligned ? item.trimDB : 0)
                    delay.append(aligned ? item.delayFrames : 0)
                    inverted.append(aligned && item.polarityInverted ? 1 : 0)
                }
            }
        }

        var core = n60_speaker_correction_settings(
            maximum_band_count: settings.maximumBandCount, maximum_boost_db: settings.maximumBoostDB,
            maximum_cut_db: settings.maximumCutDB, minimum_correction_hz: settings.minimumCorrectionHz,
            maximum_correction_hz: settings.maximumCorrectionHz, minimum_useful_error_db: settings.minimumUsefulErrorDB,
            correction_damping: settings.correctionDamping, default_q: settings.defaultQ,
            minimum_band_spacing_octaves: settings.minimumBandSpacingOctaves)
        var designed = [n60_speaker_correction_source](repeating: n60_speaker_correction_source(), count: speakerSources.count)
        let status: Int32 = frequencies.withUnsafeBufferPointer { f in
            targetDB.withUnsafeBufferPointer { t in
                weights.withUnsafeBufferPointer { w in
                    magnitude.withUnsafeBufferPointer { m in
                        valid.withUnsafeBufferPointer { v in
                            trim.withUnsafeBufferPointer { tr in
                                delay.withUnsafeBufferPointer { d in
                                    inverted.withUnsafeBufferPointer { inv in
                                        var problem = n60_speaker_correction_problem()
                                        problem.struct_size = UInt32(MemoryLayout<n60_speaker_correction_problem>.size)
                                        problem.source_count = UInt32(speakerSources.count)
                                        problem.seat_count = UInt32(seats)
                                        problem.bin_count = UInt32(bins)
                                        problem.sample_rate = matrix.sampleRate
                                        problem.frequency_hz = f.baseAddress
                                        problem.target_db = t.baseAddress
                                        problem.seat_weight = w.baseAddress
                                        problem.magnitude_db = m.baseAddress
                                        problem.response_valid = v.baseAddress
                                        problem.source_trim_db = tr.baseAddress
                                        problem.source_delay_frames = d.baseAddress
                                        problem.source_polarity_inverted = inv.baseAddress
                                        problem.settings = core
                                        return n60_speaker_correction_design(&problem, &designed)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        _ = core
        core = n60_speaker_correction_settings()
        guard status == 0 else { return nil }

        var plan = N60SpeakerCorrectionPlan()
        plan.sourceCount = UInt32(speakerSources.count)
        withUnsafeMutablePointer(to: &plan.sources) { tuple in
            tuple.withMemoryRebound(to: N60SpeakerCorrectionSourceDesign.self, capacity: Int(N60_MAX_PROGRAM_CHANNELS)) { out in
                for (index, item) in designed.enumerated() {
                    var design = N60SpeakerCorrectionSourceDesign()
                    design.valid = item.valid != 0
                    design.role = roles[index]
                    design.trimDB = item.trim_db
                    design.delayFrames = item.delay_frames
                    design.polarityInverted = item.polarity_inverted != 0
                    design.bandCount = item.band_count
                    design.preCorrectionRMSErrorDB = item.pre_rms_error_db
                    design.postCorrectionRMSErrorDB = item.post_rms_error_db
                    design.seatVarianceDBSquared = item.seat_variance_db2
                    var bandItems = item.bands
                    withUnsafePointer(to: &bandItems) { bandTuple in
                        bandTuple.withMemoryRebound(to: n60_speaker_band.self, capacity: Int(N60_SPEAKER_MAX_BANDS)) { src in
                            withUnsafeMutablePointer(to: &design.bands) { dstTuple in
                                dstTuple.withMemoryRebound(to: N60BiquadBandSnapshot.self, capacity: Int(N60_SPEAKER_CORRECTION_MAX_BANDS)) { dst in
                                    for band in 0..<Int(item.band_count) {
                                        var snapshot = N60BiquadBandSnapshot()
                                        snapshot.enabled = true
                                        snapshot.type = N60BiquadFilterTypePeaking
                                        snapshot.frequencyHz = src[band].frequency_hz
                                        snapshot.gainDB = src[band].gain_db
                                        snapshot.q = src[band].q
                                        snapshot.coefficients = N60BiquadCoefficients(
                                            b0: src[band].b0, b1: src[band].b1, b2: src[band].b2,
                                            a1: src[band].a1, a2: src[band].a2)
                                        dst[band] = snapshot
                                    }
                                }
                            }
                        }
                    }
                    out[index] = design
                }
            }
        }
        return plan
    }

    // MARK: Speaker Optimizer candidates

    struct CandidateEvidence {
        var sampleRate: Double
        var frequenciesHz: [Double]
        var targetDB: [Double]
        var desiredDB: [Double]
        /// Nil: every bin is authorised.
        var authorized: [Bool]?
        /// `[position][bin]` mean magnitude.
        var positions: [[Double]]
        /// Normalised, summing to 1.
        var weights: [Double]
        var maximumBoostDB: Double
        var maximumCutDB: Double
        var maximumSeatDegradationDB: Double
        /// Nil: no classification mask.
        var protectedLeakageDB: Double?
    }

    struct PEQResult {
        var bands: [(centerHz: Double, q: Double, gainDB: Double)]
        var auditRemovals: Int
        var correctionDB: [Double]
        var rmseBeforeDB: Double
        var rmseAfterDB: Double
        var worstSeatRegressionDB: Double
        var maximumPositiveGainDB: Double
        var recommendedHeadroomDB: Double
    }

    enum PEQFailure: Error { case invalid, peak }

    private static func withProblem<T>(
        _ evidence: CandidateEvidence, _ body: (inout n60_speaker_candidate_problem) -> T
    ) -> T {
        let flat = evidence.positions.flatMap { $0 }
        let authorized = evidence.authorized.map { $0.map { UInt8($0 ? 1 : 0) } }
        return evidence.frequenciesHz.withUnsafeBufferPointer { f in
            evidence.targetDB.withUnsafeBufferPointer { t in
                evidence.desiredDB.withUnsafeBufferPointer { d in
                    flat.withUnsafeBufferPointer { p in
                        evidence.weights.withUnsafeBufferPointer { w in
                            func run(_ a: UnsafePointer<UInt8>?) -> T {
                                var problem = n60_speaker_candidate_problem()
                                problem.struct_size = UInt32(MemoryLayout<n60_speaker_candidate_problem>.size)
                                problem.bin_count = UInt32(evidence.frequenciesHz.count)
                                problem.position_count = UInt32(evidence.positions.count)
                                problem.sample_rate = evidence.sampleRate
                                problem.frequency_hz = f.baseAddress
                                problem.target_db = t.baseAddress
                                problem.desired_db = d.baseAddress
                                problem.authorized = a
                                problem.position_db = p.baseAddress
                                problem.position_weight = w.baseAddress
                                problem.maximum_boost_db = evidence.maximumBoostDB
                                problem.maximum_cut_db = evidence.maximumCutDB
                                problem.maximum_seat_degradation_db = evidence.maximumSeatDegradationDB
                                problem.protected_leakage_db = evidence.protectedLeakageDB ?? -1
                                return body(&problem)
                            }
                            if let authorized { return authorized.withUnsafeBufferPointer { run($0.baseAddress) } }
                            return run(nil)
                        }
                    }
                }
            }
        }
    }

    static func designPEQ(evidence: CandidateEvidence, constraints: SpeakerOptimizerPEQConstraints) -> Result<PEQResult, PEQFailure> {
        let count = evidence.frequenciesHz.count
        guard evidence.positions.allSatisfy({ $0.count == count }), evidence.weights.count == evidence.positions.count else {
            return .failure(.invalid)
        }
        var core = n60_speaker_peq_constraints(
            maximum_bands: UInt32(constraints.maximumBands), minimum_q: constraints.minimumQ, maximum_q: constraints.maximumQ,
            maximum_band_gain_db: constraints.maximumBandGainMagnitudeDB, maximum_headroom_db: constraints.maximumHeadroomDB,
            maximum_out_of_band_db: constraints.maximumOutOfBandDeviationDB,
            minimum_improvement_db: constraints.minimumModeledImprovementDB)
        var correction = [Double](repeating: 0, count: count)
        var result = n60_speaker_peq_result()
        let status: Int32 = correction.withUnsafeMutableBufferPointer { buffer in
            result.correction_db = buffer.baseAddress
            return withProblem(evidence) { n60_speaker_peq_design(&$0, &core, &result) }
        }
        guard status == 0 else { return .failure(status == -7 ? .peak : .invalid) }
        var bandsOut = result.bands
        let bands: [(centerHz: Double, q: Double, gainDB: Double)] = withUnsafePointer(to: &bandsOut) { tuple in
            tuple.withMemoryRebound(to: n60_speaker_band.self, capacity: Int(N60_SPEAKER_MAX_BANDS)) { flat in
                (0..<Int(result.band_count)).map { (flat[$0].frequency_hz, flat[$0].q, flat[$0].gain_db) }
            }
        }
        return .success(PEQResult(
            bands: bands, auditRemovals: Int(result.audit_removals), correctionDB: correction,
            rmseBeforeDB: result.rmse_before_db, rmseAfterDB: result.rmse_after_db,
            worstSeatRegressionDB: result.worst_seat_regression_db, maximumPositiveGainDB: result.maximum_positive_gain_db,
            recommendedHeadroomDB: result.recommended_headroom_db))
    }

    struct FIRResult {
        var taps: [Float]
        var responseDB: [Double]
        var blockers: UInt32
        var rmseBeforeDB: Double
        var rmseAfterDB: Double
        var worstSeatRegressionDB: Double
        var maximumPositiveGainDB: Double
        var recommendedHeadroomDB: Double
    }

    enum FIRFailure: Error { case tooLong, nonFinite, grid, invalid }

    static func designFIR(
        evidence: CandidateEvidence, constraints: SpeakerOptimizerFIRConstraints, maximumTaps: Int, singleBandCap: UInt32
    ) -> Result<FIRResult, FIRFailure> {
        let count = evidence.frequenciesHz.count
        guard evidence.positions.allSatisfy({ $0.count == count }), evidence.weights.count == evidence.positions.count else {
            return .failure(.invalid)
        }
        var core = n60_speaker_fir_constraints(
            tap_count: UInt32(constraints.tapCount), maximum_taps: UInt32(maximumTaps), single_band_cap: singleBandCap,
            maximum_headroom_db: constraints.maximumHeadroomDB, maximum_out_of_band_db: constraints.maximumOutOfBandDeviationDB,
            maximum_seat_degradation_db: constraints.maximumSeatDegradationDB,
            minimum_improvement_db: constraints.minimumModeledImprovementDB,
            maximum_truncation_overshoot_db: constraints.maximumTruncationOvershootDB)
        var taps = [Float](repeating: 0, count: constraints.tapCount)
        var response = [Double](repeating: 0, count: count)
        var result = n60_speaker_fir_result()
        let status: Int32 = taps.withUnsafeMutableBufferPointer { tapBuffer in
            response.withUnsafeMutableBufferPointer { responseBuffer in
                result.taps = tapBuffer.baseAddress
                result.response_db = responseBuffer.baseAddress
                return withProblem(evidence) { n60_speaker_fir_design(&$0, &core, &result) }
            }
        }
        switch status {
        case 0: break
        case -5: return .failure(.tooLong)
        case -6: return .failure(.grid)
        case -3: return .failure(.nonFinite)
        default: return .failure(.invalid)
        }
        return .success(FIRResult(
            taps: taps, responseDB: response, blockers: result.blockers, rmseBeforeDB: result.rmse_before_db,
            rmseAfterDB: result.rmse_after_db, worstSeatRegressionDB: result.worst_seat_regression_db,
            maximumPositiveGainDB: result.maximum_positive_gain_db, recommendedHeadroomDB: result.recommended_headroom_db))
    }
}
