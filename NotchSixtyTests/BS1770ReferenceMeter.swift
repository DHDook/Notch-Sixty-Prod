import Foundation

/// E33 S11d (G69): an independent ITU-R BS.1770-4 loudness meter and an EBU Tech 3342 loudness range, written for the
/// lab cases only (it shares no code with the production meters). K-weighting is the two-stage filter of BS.1770-4
/// annex 1, with its coefficients derived at any rate from the analogue prototype (shelf: 1681.97 Hz, +4.0 dB, Q 0.7072;
/// high-pass: 38.135 Hz, Q 0.5003) by the bilinear transform. Channel weights are 1 (stereo, front pair).
/// Blocks are 400 ms with 75% overlap; the absolute gate is -70 LUFS and the relative gate 10 LU below the ungated mean.
/// Short-term loudness uses 3 s windows. The loudness range gates at -70 LUFS and 20 LU below the mean and takes the
/// 10th to 95th percentile of the short-term values (hop 100 ms).
enum BS1770ReferenceMeter {
    struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    /// The two K-weighting stages at `rate`.
    static func kWeightingStages(rate: Double) -> [Biquad] {
        let shelfF0 = 1_681.974450955533, shelfGain = 3.999843853973347, shelfQ = 0.7071752369554196
        var k = tan(Double.pi * shelfF0 / rate)
        let vh = pow(10, shelfGain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / shelfQ + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / shelfQ + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / shelfQ + k * k) / a0,
            a1: 2 * (k * k - 1) / a0, a2: (1 - k / shelfQ + k * k) / a0)
        let hpF0 = 38.13547087602444, hpQ = 0.5003270373238773
        k = tan(Double.pi * hpF0 / rate)
        a0 = 1 + k / hpQ + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / hpQ + k * k) / a0)
        return [shelf, highPass]
    }

    /// Per-sample sum over channels of the squared K-weighted signal.
    static func weightedPower(_ channels: [[Float]], rate: Double) -> [Double] {
        let stages = kWeightingStages(rate: rate)
        let frames = channels.map(\.count).min() ?? 0
        var power = [Double](repeating: 0, count: frames)
        for channel in channels {
            var state = [(Double, Double)](repeating: (0, 0), count: stages.count)   // transposed direct form II
            for n in 0..<frames {
                var x = Double(channel[n])
                for s in 0..<stages.count {
                    let c = stages[s]
                    let y = c.b0 * x + state[s].0
                    state[s].0 = c.b1 * x - c.a1 * y + state[s].1
                    state[s].1 = c.b2 * x - c.a2 * y
                    x = y
                }
                power[n] += x * x
            }
        }
        return power
    }

    /// Mean power over a sliding window, one value per hop (prefix sums).
    private static func windowedMeans(_ power: [Double], window: Int, hop: Int) -> [Double] {
        guard power.count >= window else { return [] }
        var prefix = [Double](repeating: 0, count: power.count + 1)
        for i in 0..<power.count { prefix[i + 1] = prefix[i] + power[i] }
        return stride(from: 0, through: power.count - window, by: hop).map { (prefix[$0 + window] - prefix[$0]) / Double(window) }
    }

    static func lufs(_ meanPower: Double) -> Double { -0.691 + 10 * log10(max(meanPower, 1e-30)) }

    /// Gated integrated loudness in LUFS (BS.1770-4 annex 2).
    static func integratedLoudness(_ channels: [[Float]], rate: Double) -> Double {
        let blocks = windowedMeans(weightedPower(channels, rate: rate), window: Int(rate * 0.4), hop: Int(rate * 0.1))
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return -.infinity }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Short-term loudness (3 s window, 100 ms hop) in LUFS.
    static func shortTerm(_ channels: [[Float]], rate: Double) -> [Double] {
        windowedMeans(weightedPower(channels, rate: rate), window: Int(rate * 3), hop: Int(rate * 0.1)).map(lufs)
    }

    /// Loudness range in LU (EBU Tech 3342): 95th minus 10th percentile of the gated short-term values.
    static func loudnessRange(_ channels: [[Float]], rate: Double) -> Double {
        let values = shortTerm(channels, rate: rate).filter { $0 > -70 }
        guard !values.isEmpty else { return 0 }
        let mean = lufs(values.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(values.count))
        let gated = values.filter { $0 > mean - 20 }.sorted()
        guard gated.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let position = p * Double(gated.count - 1)
            let lower = Int(position), upper = min(lower + 1, gated.count - 1)
            return gated[lower] + (gated[upper] - gated[lower]) * (position - Double(lower))
        }
        return percentile(0.95) - percentile(0.10)
    }
}
