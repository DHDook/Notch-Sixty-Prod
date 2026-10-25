import Foundation

/// Swift face of the portable room-correction design core (`n60/correct.h`, E10 S1).
///
/// Offline only: every call allocates and runs on a design task, never from an audio callback.
/// S1 exposes the minimum-phase designer and the correction grid; later slices add the
/// multi-seat design and synthesis calls behind the `e10.mixed-phase-correction` flag.
enum RoomCorrectionCore {
    enum CoreError: Error, Equatable {
        case status(Int32)
    }

    static var abiVersion: UInt32 { n60_correct_abi_version() }

    /// The fixed 1/48-octave correction grid, independent of sample rate.
    static func gridFrequencies() throws -> [Double] {
        var frequencies = [Double](repeating: 0, count: Int(n60_correct_grid_size()))
        let status = frequencies.withUnsafeMutableBufferPointer {
            n60_correct_grid_frequencies($0.baseAddress, UInt32($0.count))
        }
        guard status == 0 else { throw CoreError.status(status) }
        return frequencies
    }

    /// Real-cepstrum minimum-phase FIR for a correction curve, evaluated in double precision.
    /// The curve applies strictly between `lowHz` and `highHz` and is 0 dB outside.
    static func minimumPhaseTaps(
        sampleRate: Double,
        tapCount: Int,
        frequenciesHz: [Double],
        gainDB: [Double],
        lowHz: Double,
        highHz: Double
    ) throws -> [Float] {
        precondition(frequenciesHz.count == gainDB.count)
        var params = n60_correct_minphase_params()
        n60_correct_minphase_defaults(sampleRate, UInt32(tapCount), &params)
        params.low_hz = lowHz
        params.high_hz = highHz
        var taps = [Float](repeating: 0, count: tapCount)
        let status = taps.withUnsafeMutableBufferPointer { out in
            frequenciesHz.withUnsafeBufferPointer { f in
                gainDB.withUnsafeBufferPointer { g in
                    n60_correct_minphase_synthesize(
                        &params, f.baseAddress, g.baseAddress, UInt32(f.count), out.baseAddress, UInt64(out.count))
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        return taps
    }
}
