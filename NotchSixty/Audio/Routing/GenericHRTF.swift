import Foundation

/// E13 S11: the built-in generic HRTF. The maths is `core/src/hrtf.cpp` (rigid-sphere arrival delay and Brown-Duda
/// head shadow, see `n60/hrtf.h`); this file lays it on a direction grid and wraps it as a `BinauralProfileAsset`.
/// It is generated natively at the requested rate (no resampling) off the audio thread, is deterministic, and ships
/// no measured third-party data. Imported SOFA files and captured BRIRs stay the upgrade.
enum GenericHRTF {
    /// The one asset identity every rate shares. `BinauralResampledAssetCache` and `BinauralProfileAssetStore` know it
    /// and never read a file for it.
    static let assetID = UUID(uuidString: "6E360000-0000-4000-8000-0000000048F7")!
    static let displayName = "Generic head model (built in)"
    /// Reference rate stored in a saved profile; the engine generates the real rate on demand.
    static let referenceSampleRate = 48_000.0

    static let azimuths: [Double] = stride(from: -180.0, through: 165.0, by: 15.0).map { $0 }
    static let elevations: [Double] = [-30, 0, 30, 60]

    static func isGeneric(_ reference: BinauralProfileReference) -> Bool { reference.assetID == assetID }

    /// The reference a profile stores. Its rate and taps are those of the 48 kHz asset; activation regenerates at the
    /// output rate.
    static var reference: BinauralProfileReference {
        let taps = Int(n60_hrtf_generic_taps(referenceSampleRate))
        return BinauralProfileReference(
            assetID: assetID, displayName: displayName, originalSourceName: nil,
            sampleRate: referenceSampleRate, tapCount: taps, hasElevationSets: true)
    }

    /// The asset at `sampleRate`, generated natively. `nil` for a rate the core refuses.
    static func asset(sampleRate: Double) -> BinauralProfileAsset? {
        let taps = Int(n60_hrtf_generic_taps(sampleRate))
        guard taps > 0, taps <= BinauralProfileAsset.maxTapCount(sampleRate: sampleRate) else { return nil }
        var measurements: [BinauralMeasurement] = []
        measurements.reserveCapacity(azimuths.count * elevations.count)
        var left = [Float](repeating: 0, count: taps)
        var right = [Float](repeating: 0, count: taps)
        for elevation in elevations {
            for azimuth in azimuths {
                let status = left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        n60_hrtf_generic_ir(sampleRate, azimuth, elevation, UInt32(taps), l.baseAddress, r.baseAddress)
                    }
                }
                guard status == N60_HRTF_OK else { return nil }
                measurements.append(BinauralMeasurement(
                    azimuthDegrees: azimuth, elevationDegrees: elevation, distanceMeters: 1.5,
                    leftIR: left, rightIR: right))
            }
        }
        return BinauralProfileAsset(
            id: assetID, displayName: displayName, originalSourceName: nil, sampleRate: sampleRate,
            tapCount: taps, declaredLatencyFrames: 0, kind: .hrtf, measurements: measurements)
    }
}
