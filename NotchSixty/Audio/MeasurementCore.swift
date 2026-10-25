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

// MARK: - E11 S3: harmonic distortion and decay times

/// Why a distortion or decay analysis could not produce a result.
enum MeasurementAnalysisError: Error, Equatable {
    case invalidArguments
    case allocationFailed
}

extension MeasurementCore {
    struct DistortionResult: Equatable, Sendable {
        var frequencyHz: [Double]
        var fundamentalDB: [Double]
        /// Index 0 is H2 ... index 3 is H5; `noDataDB` where k f lies above the sweep band.
        var harmonicDB: [[Double]]
        var thdDB: [Double]
        var minSweepSeconds: Double
        var cleanSeparation: Bool

        static let noDataDB = -999.0
    }

    struct DecayBand: Equatable, Sendable {
        var centreHz: Double
        var edtSeconds: Double
        var t20Seconds: Double
        var t30Seconds: Double
        var rt60Seconds: Double
        var decayRangeDB: Double
        var noiseFloorDB: Double
        var flags: UInt32
    }

    private static func analysisError(_ status: Int32) -> MeasurementAnalysisError {
        status == N60_MEASURE_ERR_ALLOC ? .allocationFailed : .invalidArguments
    }

    /// Harmonic distortion curves from the circular deconvolved response of a synchronised sweep.
    static func analyzeDistortion(
        response: [Float], sampleRate: Double, sweep: SweepInfo,
        startFrequencyHz: Double, endFrequencyHz: Double
    ) throws -> DistortionResult {
        var info = n60_measure_ess_info(
            frame_count: UInt64(sweep.frameCount), sweep_rate_seconds: sweep.sweepRateSeconds,
            duration_seconds: sweep.durationSeconds)
        var params = n60_measure_distortion_params()
        n60_measure_distortion_defaults(sampleRate, &info, startFrequencyHz, endFrequencyHz, &params)
        let capacity = max(1, Int((log2(endFrequencyHz / startFrequencyHz) * Double(params.points_per_octave)).rounded(.up)) + 2)
        var frequency = [Double](repeating: 0, count: capacity)
        var fundamental = [Double](repeating: 0, count: capacity)
        var h2 = [Double](repeating: 0, count: capacity)
        var h3 = h2, h4 = h2, h5 = h2
        var thd = [Double](repeating: 0, count: capacity)
        var out = n60_measure_distortion_info()
        let status = h2.withUnsafeMutableBufferPointer { p2 in
            h3.withUnsafeMutableBufferPointer { p3 in
                h4.withUnsafeMutableBufferPointer { p4 in
                    h5.withUnsafeMutableBufferPointer { p5 in
                        var table: [UnsafeMutablePointer<Double>?] = [
                            p2.baseAddress, p3.baseAddress, p4.baseAddress, p5.baseAddress]
                        return table.withUnsafeMutableBufferPointer { tablePointer in
                            response.withUnsafeBufferPointer { r in
                                n60_measure_distortion_analyze(
                                    &params, r.baseAddress, UInt64(r.count), &frequency, &fundamental,
                                    tablePointer.baseAddress, &thd, UInt32(capacity), &out)
                            }
                        }
                    }
                }
            }
        }
        guard status == N60_MEASURE_OK else { throw analysisError(status) }
        let count = Int(out.point_count)
        return DistortionResult(
            frequencyHz: Array(frequency.prefix(count)),
            fundamentalDB: Array(fundamental.prefix(count)),
            harmonicDB: [h2, h3, h4, h5].map { Array($0.prefix(count)) },
            thdDB: Array(thd.prefix(count)),
            minSweepSeconds: out.min_sweep_seconds,
            cleanSeparation: out.clean_separation != 0)
    }

    /// EDT, T20, T30 and RT60 per octave or third-octave band (63 Hz to 8 kHz).
    static func analyzeDecay(
        impulseResponse: [Float], sampleRate: Double, bandsPerOctave: Int = 3,
        minCentreHz: Double = 63, maxCentreHz: Double = 8_000
    ) throws -> [DecayBand] {
        var bands = [n60_measure_decay_band](repeating: n60_measure_decay_band(), count: 40)
        var count: UInt32 = 0
        let status = impulseResponse.withUnsafeBufferPointer {
            n60_measure_decay_analyze(
                $0.baseAddress, UInt64($0.count), sampleRate, UInt32(bandsPerOctave), minCentreHz, maxCentreHz,
                &bands, UInt32(bands.count), &count)
        }
        guard status == N60_MEASURE_OK else { throw analysisError(status) }
        return bands.prefix(Int(count)).map {
            DecayBand(
                centreHz: $0.centre_hz, edtSeconds: $0.edt_seconds, t20Seconds: $0.t20_seconds,
                t30Seconds: $0.t30_seconds, rt60Seconds: $0.rt60_seconds, decayRangeDB: $0.decay_range_db,
                noiseFloorDB: $0.noise_floor_db, flags: $0.flags)
        }
    }
}

// MARK: - E11 S4: waterfall (CSD) and spectrogram

extension MeasurementCore {
    /// Cumulative spectral decay: `levelsDB[slice][point]`, loudest cell 0 dB, `noDataDB` where a slice is past the response.
    struct Waterfall: Equatable, Sendable {
        var frequencyHz: [Double]
        var sliceTimesSeconds: [Double]
        var levelsDB: [[Double]]
        static let noDataDB = -999.0
    }

    /// STFT magnitude: `levelsDB[frame][bin]`, loudest cell 0 dB, floor -200 dB.
    struct Spectrogram: Equatable, Sendable {
        var frameTimesSeconds: [Double]  // window centres
        var binFrequenciesHz: [Double]
        var levelsDB: [[Double]]
    }

    /// `room` selects the room preset (20 ms x 30) instead of the speaker preset (0.3 ms x 40).
    static func analyzeWaterfall(
        impulseResponse: [Float], sampleRate: Double, room: Bool = false, arrivalIndex: Int? = nil
    ) throws -> Waterfall {
        var params = n60_measure_waterfall_params()
        n60_measure_waterfall_defaults(sampleRate, room ? 1 : 0, &params)
        if let arrivalIndex { params.arrival_index = UInt64(max(0, arrivalIndex)) }
        var info = n60_measure_waterfall_info()
        guard n60_measure_waterfall_describe(&params, &info) == N60_MEASURE_OK else { throw MeasurementAnalysisError.invalidArguments }
        let points = Int(info.point_count), slices = Int(info.slice_count)
        var frequency = [Double](repeating: 0, count: points)
        var cells = [Double](repeating: 0, count: points * slices)
        let status = impulseResponse.withUnsafeBufferPointer { ir in
            n60_measure_waterfall_analyze(
                &params, ir.baseAddress, UInt64(ir.count), &frequency, &cells, UInt64(cells.count), &info)
        }
        guard status == N60_MEASURE_OK else { throw analysisError(status) }
        return Waterfall(
            frequencyHz: frequency,
            sliceTimesSeconds: (0..<slices).map { Double($0) * params.step_seconds },
            levelsDB: (0..<slices).map { Array(cells[($0 * points)..<(($0 + 1) * points)]) })
    }

    static func analyzeSpectrogram(
        impulseResponse: [Float], sampleRate: Double, windowSeconds: Double = 0.01, maxFrequencyHz: Double = 0
    ) throws -> Spectrogram {
        var params = n60_measure_spectrogram_params()
        n60_measure_spectrogram_defaults(sampleRate, &params)
        params.window_seconds = windowSeconds
        params.max_hz = maxFrequencyHz
        var info = n60_measure_spectrogram_info()
        guard n60_measure_spectrogram_describe(&params, UInt64(impulseResponse.count), &info) == N60_MEASURE_OK else {
            throw MeasurementAnalysisError.invalidArguments
        }
        let frames = Int(info.frame_count), bins = Int(info.bin_count)
        var cells = [Double](repeating: 0, count: frames * bins)
        let status = impulseResponse.withUnsafeBufferPointer { ir in
            n60_measure_spectrogram_analyze(
                &params, ir.baseAddress, UInt64(ir.count), &cells, UInt64(cells.count), &info)
        }
        guard status == N60_MEASURE_OK else { throw analysisError(status) }
        let hop = Double(info.hop_frames), half = Double(info.window_frames) / 2
        return Spectrogram(
            frameTimesSeconds: (0..<frames).map { (Double($0) * hop + half) / sampleRate },
            binFrequenciesHz: (0..<bins).map { Double($0) * info.hz_per_bin },
            levelsDB: (0..<frames).map { Array(cells[($0 * bins)..<(($0 + 1) * bins)]) })
    }
}
