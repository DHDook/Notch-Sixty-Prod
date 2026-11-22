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
}
