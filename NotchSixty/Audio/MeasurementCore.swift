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
