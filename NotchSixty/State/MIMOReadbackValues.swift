import Foundation

/// E19 S8: Swift access to the fixed arrays of `n60_mimo_readback` (imported as tuples) and the held-readback merge.
extension n60_mimo_readback {
    typealias EightFloats = (Float, Float, Float, Float, Float, Float, Float, Float)

    static func values(_ tuple: EightFloats) -> [Float] {
        [tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7]
    }

    static func maxMerged(_ a: EightFloats, _ b: EightFloats) -> EightFloats {
        (max(a.0, b.0), max(a.1, b.1), max(a.2, b.2), max(a.3, b.3), max(a.4, b.4), max(a.5, b.5), max(a.6, b.6), max(a.7, b.7))
    }

    /// Worst delta over program power ratio per source, linear.
    var boundRatios: [Float] { Self.values(boundRatioMax) }
    /// Peak |delta| per source.
    var deltaPeaks: [Float] { Self.values(deltaPeak) }
}
