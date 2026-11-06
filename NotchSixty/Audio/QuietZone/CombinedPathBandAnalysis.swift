import Foundation

// E26 S2: per-band analysis of a measured combined path (feed to microphone, through the app splitter or the
// receiver). Pure control-plane maths: nothing here touches the engine, arms or enables anything. A later slice (S5)
// feeds the results to `SubAwareAncReadiness`.
//
// Method: for the impulse response h[n], the group delay at angular frequency w is
//   tau(w) = Re( DFT{n h[n]}(w) / DFT{h}(w) ) / fs,
// which needs no filter, so a narrow band (20 Hz is about 4.6 Hz wide) has no filter delay to subtract. A band's delay
// is the |H|^2-weighted mean of tau over the band's edge-to-edge frequencies. It includes the sub's low-pass group
// delay, any app all-pass and the receiver's processing, which is the delay the anti-noise really sees. Specified in
// seconds and hertz, so the answer is the same at every device rate.

struct CombinedPathBand: Equatable, Sendable {
    var centerHz: Double
    var lowHz: Double
    var highHz: Double
    /// Mean path magnitude over the band, linear (the impulse response is in feed units per microphone unit).
    var gain: Double
    /// Anti-noise delay for the band, seconds. nil when the sweep put too little energy in the band.
    var delaySeconds: Double?

    var gainDB: Double { 20 * log10(max(gain, 1e-12)) }
}

enum CombinedPathBandAnalyzer {
    /// Third-octave centres 20-500 Hz (design 5).
    static let centersHz: [Double] = (0...28).map { 20.0 * pow(10.0, Double($0) / 10.0) }
        .filter { $0 <= 505.0 }
    /// A band more than this far below the strongest band has no usable delay.
    static let silenceFloorDB = -50.0
    static let frequenciesPerBand = 9

    static func analyze(impulseResponse h: [Float], sampleRate: Double) -> [CombinedPathBand] {
        guard sampleRate > 0, sampleRate.isFinite, !h.isEmpty, h.allSatisfy(\.isFinite) else { return [] }
        let edge = pow(2.0, 1.0 / 6.0)
        var bands: [CombinedPathBand] = []
        var energies: [Double] = []
        var delays: [Double] = []
        for center in centersHz {
            let low = center / edge, high = center * edge
            var weightSum = 0.0, weightedDelay = 0.0, magSum = 0.0
            for k in 0..<frequenciesPerBand {
                let f = low + (high - low) * Double(k) / Double(frequenciesPerBand - 1)
                let (h0, h1) = dft(h, frequency: f, sampleRate: sampleRate)
                let power = h0.re * h0.re + h0.im * h0.im
                guard power > 0 else { continue }
                // Re(H1 / H0) = (H1 . conj(H0)) / |H0|^2, where H1 is the DFT of n * h[n].
                let tau = (h1.re * h0.re + h1.im * h0.im) / power / sampleRate
                weightSum += power
                weightedDelay += power * tau
                magSum += power.squareRoot()
            }
            let meanPower = weightSum / Double(frequenciesPerBand)
            energies.append(meanPower)
            delays.append(weightSum > 0 ? weightedDelay / weightSum : 0)
            bands.append(CombinedPathBand(
                centerHz: center, lowHz: low, highHz: high, gain: magSum / Double(frequenciesPerBand), delaySeconds: nil))
        }
        guard let peak = energies.max(), peak > 0 else { return bands }
        let floor = peak * pow(10.0, silenceFloorDB / 10.0)
        for i in bands.indices where energies[i] >= floor { bands[i].delaySeconds = delays[i] }
        return bands
    }

    private struct Complex { var re = 0.0, im = 0.0 }

    /// DFT of h[n] and of n*h[n] at one frequency, by rotation recurrence (no per-sample trigonometry).
    private static func dft(_ h: [Float], frequency: Double, sampleRate: Double) -> (Complex, Complex) {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cw = cos(w), sw = -sin(w)  // e^{-jw}
        var cr = 1.0, ci = 0.0
        var a = Complex(), b = Complex()
        for n in 0..<h.count {
            let x = Double(h[n])
            a.re += x * cr; a.im += x * ci
            let y = x * Double(n)
            b.re += y * cr; b.im += y * ci
            let nr = cr * cw - ci * sw
            ci = cr * sw + ci * cw
            cr = nr
            if n & 0x3FFF == 0x3FFF {  // renormalise against drift on long responses
                let m = (cr * cr + ci * ci).squareRoot()
                cr /= m; ci /= m
            }
        }
        return (a, b)
    }
}

/// Per-band feed-forward eligibility (design 5): a band runs feed-forward only where the reference lead covers the
/// band's anti-noise delay plus the required reserve. Bands that fail are left to the tonal canceller, which is
/// predictive and has no latency gate.
struct PerBandAncEligibility: Equatable, Sendable {
    struct Band: Equatable, Sendable {
        var centerHz: Double
        var delaySeconds: Double?
        var result: TwoChannelAncEligibility
        var isEligible: Bool { if case .eligible = result { return true } else { return false } }
    }

    var bands: [Band]
    var feedForwardBandsHz: [Double] { bands.filter(\.isEligible).map(\.centerHz) }
    /// Bands left to the tonal canceller, with the reason each was excluded.
    var tonalOnly: [(centerHz: Double, reason: String)] {
        bands.compactMap { b in
            if case .refused(let reason) = b.result { return (b.centerHz, reason) }
            return nil
        }
    }
    var anyFeedForward: Bool { bands.contains(where: \.isEligible) }

    static func evaluate(
        arrangement: SystemArrangement, bands: [CombinedPathBand], conservativePreviewSeconds: Double?,
        requiredReserveSeconds: Double = QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds
    ) -> PerBandAncEligibility {
        PerBandAncEligibility(bands: bands.map { band in
            guard let delay = band.delaySeconds else {
                return Band(
                    centerHz: band.centerHz, delaySeconds: nil,
                    result: .refused(reason: "The sweep put too little energy in this band to measure its delay."))
            }
            // The path's delay is the whole feed's latency for this band.
            let result = TwoChannelAncEligibility.evaluate(
                arrangement: arrangement, feedLatencyUpperBoundSeconds: max(0, delay),
                conservativePreviewSeconds: conservativePreviewSeconds, requiredReserveSeconds: requiredReserveSeconds)
            return Band(centerHz: band.centerHz, delaySeconds: delay, result: result)
        })
    }
}

/// The open-preout check (design 10a): the declaration says the receiver adds no crossover or timing, so the measured
/// path must match the path the app's own settings predict. `expected` is the same analysis of the app's own model
/// (its bass management rendered alone); the caller supplies it.
enum OpenPreoutCheck {
    static let refusal = "Your receiver seems to add its own crossover. Choose Calibrated LFE out, or turn its crossover off."
    static let gainToleranceDB = 3.0

    /// nil: the measured path is explained by the app's settings. Otherwise the refusal text. Compared over bands both
    /// analyses could measure; fewer than three shared bands cannot confirm the declaration, so it is refused.
    static func refusal(
        measured: [CombinedPathBand], expected: [CombinedPathBand], sampleRate: Double
    ) -> String? {
        // One fd sample: the drive rate of the E4 analysis, at most 48 kHz.
        let oneSample = sampleRate > 0 ? 1.0 / min(sampleRate, 48_000) : .infinity
        var shared = 0
        for (m, e) in zip(measured, expected) {
            guard let md = m.delaySeconds, let ed = e.delaySeconds else { continue }
            shared += 1
            if abs(m.gainDB - e.gainDB) > gainToleranceDB || abs(md - ed) > oneSample { return refusal }
        }
        return shared >= 3 ? nil : refusal
    }
}
