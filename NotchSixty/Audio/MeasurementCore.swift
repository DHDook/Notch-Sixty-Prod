import Foundation

/// Swift face of the portable measurement core (`n60/measure.h`, E11 S1).
///
/// Offline only: every call may allocate and is made from an analysis task, never from an
/// audio callback. The maths lives in libn60core; this type marshals arrays and maps core
/// status codes to the analyser's errors.
enum MeasurementCore {
    static var abiVersion: UInt32 { n60_measure_abi_version() }

    struct SweepInfo: Equatable, Sendable {
        var frameCount: Int
        /// Sweep rate L in seconds: instantaneous frequency is `start * exp(t / L)`.
        var sweepRateSeconds: Double
        /// Actual duration, `L * ln(end / start)`.
        var durationSeconds: Double

        /// Seconds by which the k-th harmonic impulse precedes the linear impulse.
        func harmonicLeadSeconds(_ harmonic: Int) -> Double {
            sweepRateSeconds * log(Double(max(harmonic, 1)))
        }
    }

    static func makeSweep(
        sampleRate: Double,
        startFrequencyHz: Double,
        endFrequencyHz: Double,
        durationSeconds: Double,
        levelDBFS: Double,
        fadeSeconds: Double,
        synchronised: Bool
    ) throws -> (samples: [Float], info: SweepInfo) {
        var params = n60_measure_ess_params(
            sample_rate: sampleRate,
            start_hz: startFrequencyHz,
            end_hz: endFrequencyHz,
            duration_seconds: durationSeconds,
            level_dbfs: levelDBFS,
            fade_seconds: fadeSeconds,
            synchronised: synchronised ? 1 : 0
        )
        var info = n60_measure_ess_info()
        guard n60_measure_ess_describe(&params, &info) == N60_MEASURE_OK else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
        var samples = [Float](repeating: 0, count: Int(info.frame_count))
        let status = samples.withUnsafeMutableBufferPointer {
            n60_measure_ess_generate(&params, $0.baseAddress, UInt64($0.count), &info)
        }
        guard status == N60_MEASURE_OK else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
        return (
            samples,
            SweepInfo(
                frameCount: Int(info.frame_count),
                sweepRateSeconds: info.sweep_rate_seconds,
                durationSeconds: info.duration_seconds
            )
        )
    }

    /// Full circular regularised deconvolution; the result has the transform size.
    static func deconvolve(
        excitation: [Float],
        observed: [Float],
        regularizationRatio: Double
    ) throws -> [Float] {
        var size: UInt64 = 0
        let sizeStatus = n60_measure_transform_size(UInt64(observed.count), &size)
        guard sizeStatus == N60_MEASURE_OK else {
            throw RoomCorrectionMeasurementAnalysisError.transformTooLarge(required: observed.count)
        }
        var output = [Float](repeating: 0, count: Int(size))
        var produced: UInt64 = 0
        let status = excitation.withUnsafeBufferPointer { x in
            observed.withUnsafeBufferPointer { y in
                output.withUnsafeMutableBufferPointer { out in
                    n60_measure_deconvolve(
                        x.baseAddress, UInt64(x.count),
                        y.baseAddress, UInt64(y.count),
                        regularizationRatio,
                        out.baseAddress, UInt64(out.count), &produced
                    )
                }
            }
        }
        switch status {
        case N60_MEASURE_OK:
            return Array(output.prefix(Int(produced)))
        case N60_MEASURE_ERR_UNUSABLE_EXCITATION:
            throw RoomCorrectionMeasurementAnalysisError.unusableExcitation
        case N60_MEASURE_ERR_SIZE:
            throw RoomCorrectionMeasurementAnalysisError.transformTooLarge(required: observed.count)
        default:
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
    }
}

// MARK: - E11 S2: timing reference and repeat averaging

/// Why a timing or averaging step could not produce a result.
enum MeasurementTimingError: Error, Equatable {
    case invalidArguments
    /// The matched-filter peak was too weak to trust (tier a or b reference).
    case weakReference
    /// Every repeat failed the coherence or level gate.
    case noAcceptedRepeats
    case allocationFailed
}

extension MeasurementCore {
    /// Reference-timing tiers recorded with each measurement (`N60_MEASURE_TIMING_*`).
    enum TimingTier: Int32, Sendable {
        case loopback = 1
        case acousticChirp = 2
        case none = 3
    }

    struct Arrival: Equatable, Sendable {
        var frames: Double
        var peakToNeighbourhoodDB: Double
    }

    struct AverageResult: Equatable, Sendable {
        var samples: [Float]
        var acceptedCount: Int
        var rejectedRepeats: [Int]
        var driftPPM: Double
        var driftWarning: Bool
        var coherence: [Double]
        var levelDB: [Double]
    }

    private static func timingError(_ status: Int32) -> MeasurementTimingError {
        switch status {
        case N60_MEASURE_ERR_TIMING_REFERENCE: return .weakReference
        case N60_MEASURE_ERR_NO_ACCEPTED_REPEATS: return .noAcceptedRepeats
        case N60_MEASURE_ERR_ALLOC: return .allocationFailed
        default: return .invalidArguments
        }
    }

    /// The acoustic-timing reference chirp (tier b), 2 kHz up to 0.45 of the rate by default.
    static func makeReferenceChirp(sampleRate: Double, levelDBFS: Double = -12) throws -> [Float] {
        var params = n60_measure_chirp_params()
        n60_measure_chirp_defaults(sampleRate, &params)
        params.level_dbfs = levelDBFS
        var frames: UInt64 = 0
        let sizeStatus = n60_measure_chirp_length(&params, &frames)
        guard sizeStatus == N60_MEASURE_OK else { throw timingError(sizeStatus) }
        var out = [Float](repeating: 0, count: Int(frames))
        var produced: UInt64 = 0
        let status = out.withUnsafeMutableBufferPointer {
            n60_measure_chirp_generate(&params, $0.baseAddress, UInt64($0.count), &produced)
        }
        guard status == N60_MEASURE_OK else { throw timingError(status) }
        return Array(out.prefix(Int(produced)))
    }

    /// Sub-sample frame at which `template` begins inside `capture`.
    static func findArrival(
        template: [Float], in capture: [Float], sampleRate: Double, minimumPeakDB: Double = 20
    ) throws -> Arrival {
        var arrival = n60_measure_arrival()
        let status = template.withUnsafeBufferPointer { t in
            capture.withUnsafeBufferPointer { c in
                n60_measure_find_arrival(
                    t.baseAddress, UInt64(t.count), c.baseAddress, UInt64(c.count),
                    sampleRate, minimumPeakDB, &arrival
                )
            }
        }
        guard status == N60_MEASURE_OK else { throw timingError(status) }
        return Arrival(frames: arrival.arrival_frames, peakToNeighbourhoodDB: arrival.peak_to_neighbourhood_db)
    }

    /// Tier (c): sub-sample position of the largest magnitude in `range`.
    static func peakPosition(in data: [Float], range: Range<Int>) throws -> Double {
        var position = 0.0
        let status = data.withUnsafeBufferPointer {
            n60_measure_peak_position($0.baseAddress, UInt64($0.count), UInt64(range.lowerBound),
                                      UInt64(range.upperBound), &position)
        }
        guard status == N60_MEASURE_OK else { throw timingError(status) }
        return position
    }

    /// Aligns the repeats on their reference arrivals, rejects outliers, and averages coherently.
    static func averageRepeats(
        _ repeats: [[Float]], arrivals: [Double], sampleRate: Double, repeatPeriodFrames: Int
    ) throws -> AverageResult {
        guard let first = repeats.first, repeats.count == arrivals.count,
              repeats.count <= Int(N60_MEASURE_MAX_REPEATS), repeats.allSatisfy({ $0.count == first.count })
        else { throw MeasurementTimingError.invalidArguments }
        var params = n60_measure_average_params()
        n60_measure_average_defaults(sampleRate, &params)
        params.repeat_count = UInt32(repeats.count)
        params.length_frames = UInt64(first.count)
        params.repeat_period_frames = UInt64(repeatPeriodFrames)
        var out = [Float](repeating: 0, count: first.count)
        var result = n60_measure_average_result()
        // The pointers stay valid because the arrays are borrowed for the whole call.
        func run(_ index: Int, _ pointers: [UnsafePointer<Float>?]) -> Int32 {
            if index == repeats.count {
                return pointers.withUnsafeBufferPointer { table in
                    arrivals.withUnsafeBufferPointer { arr in
                        out.withUnsafeMutableBufferPointer { o in
                            n60_measure_average_repeats(&params, table.baseAddress, arr.baseAddress,
                                                        o.baseAddress, UInt64(o.count), &result)
                        }
                    }
                }
            }
            return repeats[index].withUnsafeBufferPointer { run(index + 1, pointers + [$0.baseAddress]) }
        }
        let status = run(0, [])
        guard status == N60_MEASURE_OK else { throw timingError(status) }
        return AverageResult(
            samples: out,
            acceptedCount: Int(result.accepted_count),
            rejectedRepeats: (0..<repeats.count).filter { result.rejected_mask & (1 << UInt32($0)) != 0 },
            driftPPM: result.drift_ppm,
            driftWarning: result.drift_warning != 0,
            coherence: withUnsafeBytes(of: result.coherence) { Array($0.bindMemory(to: Double.self).prefix(repeats.count)) },
            levelDB: withUnsafeBytes(of: result.level_db) { Array($0.bindMemory(to: Double.self).prefix(repeats.count)) }
        )
    }
}
