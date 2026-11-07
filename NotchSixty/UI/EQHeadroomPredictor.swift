import Foundation

// E27 S3a: how far the EQ can raise a full-scale sine, the badge that says whether the preamp
// covers it, and the auto-preamp rule. Plain value types so they can be tested without a view.
// Swift only; nothing here runs on the audio thread.

/// The predicted worst-case steady-state sine gain of the EQ.
struct EQHeadroomPrediction: Equatable, Sendable {
    /// The largest gain, in dB, over the grid. Negative when the EQ only cuts.
    var peakGainDB: Double
    /// Where that gain occurs.
    var frequencyHz: Double
    /// True when an enabled imported-FIR band exists: its magnitude is not in the prediction.
    var omitsFIRBands: Bool

    /// The boost the preamp has to absorb: never negative.
    var boostDB: Double { max(0, peakGainDB) }

    static let none = EQHeadroomPrediction(peakGainDB: 0, frequencyHz: 0, omitsFIRBands: false)
}

enum EQHeadroomPredictor {
    /// Grid density: 1/48 octave, plus every enabled band centre.
    static let pointsPerOctave = 48.0
    static let lowestFrequency = 20.0

    /// Steady-state worst-case sine gain per output over a 1/48-octave grid plus band centres.
    ///
    /// - Linked and Independent: the lane's |H|, largest of the lanes in use.
    /// - Mid/Side with M = (L + R) / 2 and S = (L - R) / 2: each output is
    ///   `(H_M + H_S) / 2 * a + (H_M - H_S) / 2 * b` for input sines a and b of at most unit
    ///   amplitude and any phase, so its worst case is `(|H_M + H_S| + |H_M - H_S|) / 2`.
    /// - Dynamic peaking bands are taken at their upward limit: the static gain plus the maximum
    ///   boost when the direction allows boosting (an assumption that the boost adds to the
    ///   static gain), the static gain otherwise.
    /// - Phase mode does not change the magnitude, so the minimum-phase cascade stands for all
    ///   three; the linear-phase FIR is a finite approximation of the same target.
    /// - A sine prediction, not an inter-sample-peak bound.
    static func predict(configuration: StereoEQConfiguration, sampleRate: Double) -> EQHeadroomPrediction {
        guard sampleRate.isFinite, sampleRate > 0, !configuration.bypassed else { return .none }

        let lanes: [[EQBand]]
        switch configuration.channelMode {
        case .linked: lanes = [configuration.linkedBands]
        case .independent: lanes = [configuration.leftBands, configuration.rightBands]
        case .midSide: lanes = [configuration.midBands, configuration.sideBands]
        }
        let omitsFIR = lanes.contains { $0.contains { $0.enabled && $0.type == .fir } }
        let compiled = lanes.map { sections(for: $0, sampleRate: sampleRate) }
        let centres = lanes.flatMap { $0.filter { $0.enabled && $0.type != .fir }.map(\.frequencyHz) }

        var best = -Double.infinity
        var bestFrequency = 0.0
        for frequency in grid(sampleRate: sampleRate, bandCentres: centres) {
            let gain: Double
            switch configuration.channelMode {
            case .linked:
                gain = response(compiled[0], sampleRate: sampleRate, frequency: frequency).magnitude
            case .independent:
                gain = max(
                    response(compiled[0], sampleRate: sampleRate, frequency: frequency).magnitude,
                    response(compiled[1], sampleRate: sampleRate, frequency: frequency).magnitude
                )
            case .midSide:
                let mid = response(compiled[0], sampleRate: sampleRate, frequency: frequency)
                let side = response(compiled[1], sampleRate: sampleRate, frequency: frequency)
                gain = ((mid + side).magnitude + (mid - side).magnitude) / 2
            }
            if gain > best {
                best = gain
                bestFrequency = frequency
            }
        }
        guard best.isFinite, best > 0 else { return EQHeadroomPrediction(peakGainDB: 0, frequencyHz: 0, omitsFIRBands: omitsFIR) }
        return EQHeadroomPrediction(
            peakGainDB: 20 * log10(best),
            frequencyHz: bestFrequency,
            omitsFIRBands: omitsFIR
        )
    }

    /// The band as the engine could drive it at its upward limit.
    static func upwardLimit(of band: EQBand) -> EQBand {
        guard band.dynamic.enabled, band.type == .peaking, band.dynamic.direction != .cutOnly else { return band }
        var limit = band
        limit.gainDB = min(
            max(band.gainDB + band.dynamic.maxBoostDB, StereoEQConfiguration.bandGainRange.lowerBound),
            StereoEQConfiguration.bandGainRange.upperBound
        )
        return limit
    }

    static func grid(sampleRate: Double, bandCentres: [Double]) -> [Double] {
        let upper = sampleRate * 0.49
        guard upper > lowestFrequency else { return [] }
        let steps = Int((log2(upper / lowestFrequency) * pointsPerOctave).rounded(.up))
        var frequencies = (0...steps).map { min(upper, lowestFrequency * pow(2, Double($0) / pointsPerOctave)) }
        frequencies.append(contentsOf: bandCentres.filter { $0 >= lowestFrequency && $0 <= upper })
        return frequencies
    }

    // MARK: Complex response

    private struct Complex {
        var re: Double
        var im: Double
        static func + (l: Complex, r: Complex) -> Complex { Complex(re: l.re + r.re, im: l.im + r.im) }
        static func - (l: Complex, r: Complex) -> Complex { Complex(re: l.re - r.re, im: l.im - r.im) }
        static func * (l: Complex, r: Complex) -> Complex {
            Complex(re: l.re * r.re - l.im * r.im, im: l.re * r.im + l.im * r.re)
        }
        func divided(by d: Complex) -> Complex {
            let n = d.re * d.re + d.im * d.im
            return Complex(re: (re * d.re + im * d.im) / n, im: (im * d.re - re * d.im) / n)
        }
        var magnitude: Double { hypot(re, im) }
    }

    private static func sections(for bands: [EQBand], sampleRate: Double) -> [N60BiquadCoefficients] {
        ProductionEQResponseMath.compile(bands: bands.map(upwardLimit(of:)), sampleRate: sampleRate)
    }

    private static func response(_ sections: [N60BiquadCoefficients], sampleRate: Double, frequency: Double) -> Complex {
        let omega = 2 * Double.pi * frequency / sampleRate
        let z1 = Complex(re: cos(omega), im: -sin(omega))
        let z2 = z1 * z1
        var total = Complex(re: 1, im: 0)
        for section in sections {
            let numerator = Complex(
                re: Double(section.b0) + Double(section.b1) * z1.re + Double(section.b2) * z2.re,
                im: Double(section.b1) * z1.im + Double(section.b2) * z2.im
            )
            let denominator = Complex(
                re: 1 + Double(section.a1) * z1.re + Double(section.a2) * z2.re,
                im: Double(section.a1) * z1.im + Double(section.a2) * z2.im
            )
            total = total * numerator.divided(by: denominator)
        }
        return total
    }
}

/// The post-EQ meter evidence that turns the badge red: the over-range count rose, or a peak
/// reached -0.1 dBFS, within the last two seconds.
struct EQClipMonitor: Equatable, Sendable {
    static let holdSeconds = 2.0
    static let peakThresholdDB = -0.1

    private var lastOverRange: UInt64?
    private var lastEventTime: Double?

    /// - Parameter overRangeIsDelta: the unified graph reports over-range samples since the
    ///   previous read; the frozen legacy kernel reports a running total.
    mutating func ingest(
        peakLinear: Float,
        overRangeSamples: UInt64,
        overRangeIsDelta: Bool,
        at time: Double
    ) {
        let peakDB = peakLinear > 0 ? 20 * log10(Double(peakLinear)) : -Double.infinity
        let overRangeRose = overRangeIsDelta
            ? overRangeSamples > 0
            : overRangeSamples > (lastOverRange ?? overRangeSamples)
        lastOverRange = overRangeSamples
        if overRangeRose || peakDB >= Self.peakThresholdDB {
            lastEventTime = time
        }
    }

    func isTripped(at time: Double) -> Bool {
        guard let lastEventTime else { return false }
        return time - lastEventTime <= Self.holdSeconds
    }

    mutating func reset() {
        lastOverRange = nil
        lastEventTime = nil
    }
}

enum EQHeadroomBadge: Equatable, Sendable {
    /// The preamp plus headroom attenuation covers the predicted boost.
    case covered(boostDB: Double, marginDB: Double)
    /// It does not: `shortfallDB` more cut would.
    case uncovered(boostDB: Double, shortfallDB: Double)
    /// The post-EQ meter clipped in the last two seconds.
    case clipped

    static let tolerance = 0.05

    static func evaluate(
        boostDB: Double,
        preampDB: Double,
        headroomAttenuationDB: Double,
        clipTripped: Bool
    ) -> EQHeadroomBadge {
        if clipTripped { return .clipped }
        let margin = -(boostDB + preampDB + headroomAttenuationDB)
        if margin >= -tolerance { return .covered(boostDB: boostDB, marginDB: max(0, margin)) }
        return .uncovered(boostDB: boostDB, shortfallDB: -margin)
    }
}

/// The auto-preamp rule: preamp = trim - boost, the boost rounded up to 0.1 dB.
enum EQAutoPreamp {
    static let quantisationDB = 0.1

    static func attenuationDB(forBoost boostDB: Double) -> Double {
        let boost = max(0, boostDB)
        guard boost.isFinite else { return 0 }
        return (boost / quantisationDB - 1e-9).rounded(.up) * quantisationDB
    }

    static func preampDB(trimDB: Double, boostDB: Double) -> Double {
        let range = DSPGainConfiguration.inputPreampRange
        let raw = trimDB - attenuationDB(forBoost: boostDB)
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}
