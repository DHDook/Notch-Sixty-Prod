import Foundation

/// E33 S13 (graph ABI v45, behind `e33.page-enhancements`): the extra parameter values that take the LFE out of the compressor and
/// expander detectors and make the dialogue leveller centre-aware. Stereo and LFE-less sessions never get them, so their blocks
/// (and their output) are unchanged.
enum SurroundDetectorParams {
    /// Whether the session takes the surround behaviour.
    static func isOn() -> Bool { FeatureFlags.isEnabledProcessWide(.eqPageEnhancements) }

    /// The compressor block with the detector-excluded lane (index 16) appended, padding shorter blocks with the core defaults.
    static func compressor(_ params: [Float], excluding lfe: Int?) -> [Float] {
        guard let lfe, params.count == 10 || params.count == 15 || params.count == 16 else { return params }
        var out = params
        // [10] mix %, [11] link %, [12] detector (peak), [13] RMS window ms, [14] lookahead frames, [15] listen (off).
        if out.count == 10 { out += [100, 100, 0, 50, 0] }
        if out.count == 15 { out.append(0) }
        out.append(Float(lfe + 1))
        return out
    }

    /// The expander block with the detector-excluded lane (index 15) appended.
    static func expander(_ params: [Float], excluding lfe: Int?) -> [Float] {
        guard let lfe, [6, 13, 14, 15].contains(params.count) else { return params }
        var out = params
        // [6] hold ms, [7] knee dB, [8] detector, [9] RMS window ms, [10] side-chain high-pass Hz, [11] link %, [12] listen.
        if out.count == 6 { out += [0, 0, 0, 50, 0, 100, 0] }
        if out.count == 13 { out.append(0) }  // [13] lookahead frames
        if out.count == 14 { out.append(0) }  // [14] timing swap
        out.append(Float(lfe + 1))
        return out
    }

    /// The loudness block with the centre lane (index 32) appended when the leveller can follow a centre lane that is not in the pair.
    static func loudness(_ params: [Float], centre: Int?, pair: [Int]) -> [Float] {
        guard let centre, params.count == 32, !pair.contains(centre) else { return params }
        return params + [Float(centre + 1)]
    }
}
