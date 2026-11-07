import Foundation

/// E27 S2: what the Equalizer's filters do beyond magnitude, as plain value types that read
/// the same compiled sections the engine is given. Nothing here touches the audio path.
///
/// - Minimum phase: the cascade of `EQBand.compiledSections` (the graph's own source).
/// - Mixed phase: the same cascade plus the all-pass correction `N60MixedPhaseDesign` returns,
///   exactly as `StereoEQConfiguration.makeGraphSnapshot` appends it.
/// - Linear phase: the taps `N60LinearPhaseEQDesign` produces from `linearPhaseBands`; the phase
///   view shows the residual after the constant (N - 1) / 2 sample delay.
///
/// Phase and group delay follow the standard definitions for a rational H(e^jw): phase is the
/// sum of each section's arg(num) - arg(den), unwrapped section by section along the grid, and
/// group delay is tau(w) = -dphi/dw = Re[sum k c_k e^-jwk / sum c_k e^-jwk] for the numerator
/// minus the same for the denominator (Oppenheim and Schafer, "Discrete-Time Signal
/// Processing", group delay of a rational system).

// MARK: Views

enum EQGraphView: String, CaseIterable, Identifiable, Sendable {
    case magnitude
    case phase
    case groupDelay
    case impulse
    case step

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .magnitude: return "Magnitude"
        case .phase: return "Phase"
        case .groupDelay: return "Group delay"
        case .impulse: return "Impulse"
        case .step: return "Step"
        }
    }

    /// Frequency-axis views honour the x zoom; impulse and step run on a time axis.
    var isFrequencyDomain: Bool {
        switch self {
        case .magnitude, .phase, .groupDelay: return true
        case .impulse, .step: return false
        }
    }
}

/// One curve ready to draw: x is hertz (frequency views) or milliseconds (time views).
struct EQAnalysisSeries: Equatable, Sendable {
    let view: EQGraphView
    let xs: [Double]
    let ys: [Double]
    let unit: String
    /// Shown under the graph, for example the constant delay of a linear-phase design.
    let note: String?

    /// The y range that shows the whole curve, padded and rounded to a readable step.
    var autoRange: ClosedRange<Double> {
        EQAxisScale.niceRange(minimum: ys.min() ?? 0, maximum: ys.max() ?? 1)
    }
}

enum EQAxisScale {
    /// 1, 2 or 5 times a power of ten at or above `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let exponent = floor(log10(raw))
        let fraction = raw / pow(10, exponent)
        let nice: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
        return nice * pow(10, exponent)
    }

    /// A padded range that always has non-zero height and includes zero when the data is
    /// within a factor of ten of it (a flat line then sits mid-graph, not on the edge).
    static func niceRange(minimum: Double, maximum: Double) -> ClosedRange<Double> {
        guard minimum.isFinite, maximum.isFinite else { return -1...1 }
        var low = min(minimum, maximum)
        var high = max(minimum, maximum)
        if low > 0, low < high * 0.1 || high - low < abs(high) * 0.02 { low = min(low, 0) }
        if high < 0, high > low * 0.1 || high - low < abs(low) * 0.02 { high = max(high, 0) }
        var span = high - low
        if span < 1.0e-12 {
            let pad = max(abs(high) * 0.1, 1.0e-9)
            low -= pad
            high += pad
            span = high - low
        }
        let step = niceStep(span / 4)
        low = floor((low - span * 0.05) / step) * step
        high = ceil((high + span * 0.05) / step) * step
        return low...high
    }

    /// Tick values inside `range`, about `target` of them, on a 1-2-5 step.
    static func ticks(in range: ClosedRange<Double>, target: Int = 5) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, target > 0 else { return [] }
        let step = niceStep(span / Double(target))
        var value = ceil(range.lowerBound / step) * step
        var result: [Double] = []
        while value <= range.upperBound + step * 1.0e-9, result.count < 64 {
            result.append(abs(value) < step * 1.0e-9 ? 0 : value)
            value += step
        }
        return result
    }
}

// MARK: Analysis

struct EQFilterAnalysis: Sendable {
    enum Realisation: Equatable, Sendable {
        case minimum
        case mixed
        case linear
    }

    let sampleRate: Double
    let realisation: Realisation
    /// The minimum-phase cascade; for mixed phase it includes the all-pass correction.
    let sections: [N60BiquadCoefficients]
    /// The linear-phase FIR taps; empty unless `realisation == .linear`.
    let linearTaps: [Float]
    /// Why the requested phase mode could not be shown exactly (the cascade is shown instead).
    let fallbackNote: String?

    init(bands: [EQBand], phaseMode: EQPhaseMode, sampleRate: Double) {
        self.sampleRate = sampleRate
        let eligible = bands.filter { $0.type != .fir }
        let cascade = ProductionEQResponseMath.compile(bands: eligible, sampleRate: sampleRate)
        var chosenSections = cascade
        var chosenTaps: [Float] = []
        var chosenRealisation = Realisation.minimum
        var note: String?

        let valid = sampleRate.isFinite && sampleRate > 0
        switch phaseMode {
        case .minimumPhase:
            break
        case .mixedPhase where valid:
            var source: [N60BiquadBandSnapshot] = []
            var hasAllPass = false
            for band in eligible where band.enabled {
                guard let compiled = try? band.compiledSections(sampleRate: sampleRate) else { continue }
                if band.type == .allPass { hasAllPass = true }
                source.append(contentsOf: compiled)
            }
            var design = N60MixedPhaseDesignInfo()
            let designed = !hasAllPass && source.withUnsafeBufferPointer { buffer in
                N60MixedPhaseDesign(sampleRate, buffer.baseAddress, UInt32(buffer.count), &design)
            }
            if designed {
                for index in 0..<design.sectionCount {
                    chosenSections.append(N60MixedPhaseDesignSectionAt(&design, index).coefficients)
                }
                chosenRealisation = .mixed
            } else {
                note = hasAllPass ? "All-pass bands need minimum phase; showing minimum phase." : "Mixed phase could not be designed; showing minimum phase."
            }
        case .linearPhase where valid:
            let configuration = StereoEQConfiguration(
                channelMode: .linked, editChannel: .linked, phaseMode: .linearPhase, linkedBands: eligible
            )
            if let cBands = try? configuration.linearPhaseBands(for: .linked, sampleRate: sampleRate) {
                let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
                var taps = [Float](repeating: 0, count: tapCount)
                var info = N60LinearPhaseEQDesignInfo()
                let designed = tapCount > 0 && taps.withUnsafeMutableBufferPointer { out in
                    cBands.withUnsafeBufferPointer { input in
                        N60LinearPhaseEQDesign(
                            sampleRate, input.baseAddress, UInt32(input.count),
                            out.baseAddress, UInt32(out.count), &info
                        )
                    }
                }
                if designed {
                    chosenTaps = taps
                    chosenRealisation = .linear
                } else {
                    note = "The linear-phase filter could not be designed; showing minimum phase."
                }
            } else {
                note = "All-pass bands need minimum phase; showing minimum phase."
            }
        default:
            break
        }
        sections = chosenSections
        linearTaps = chosenTaps
        realisation = chosenRealisation
        fallbackNote = note
    }

    /// The constant delay of a linear-phase design in samples, (N - 1) / 2; zero otherwise.
    var linearDelaySamples: Double {
        realisation == .linear ? Double(linearTaps.count - 1) / 2 : 0
    }

    // MARK: Magnitude

    /// The same math the graph draws today (`ProductionEQResponseMath`).
    func magnitudeDB(at frequencyHz: Double) -> Double {
        ProductionEQResponseMath.responseDB(program: sections, sampleRate: sampleRate, frequencyHz: frequencyHz)
    }

    /// Gain at DC as a linear factor.
    var dcGain: Double {
        if realisation == .linear { return linearTaps.reduce(0.0) { $0 + Double($1) } }
        return sections.reduce(1.0) { partial, c in
            let denominator = 1 + Double(c.a1) + Double(c.a2)
            guard abs(denominator) > 1.0e-30 else { return partial }
            return partial * (Double(c.b0) + Double(c.b1) + Double(c.b2)) / denominator
        }
    }

    // MARK: Phase

    /// Phase in radians along `frequencies` (ascending). Unwrapped from the first point;
    /// linear phase returns the residual after removing the constant delay.
    func phaseRadians(frequencies: [Double]) -> [Double] {
        guard !frequencies.isEmpty, sampleRate > 0 else { return [] }
        if realisation == .linear { return linearResidualPhase(frequencies: frequencies) }
        var total = [Double](repeating: 0, count: frequencies.count)
        for coefficients in sections {
            var previous = 0.0
            var offset = 0.0
            for (index, frequency) in frequencies.enumerated() {
                let omega = 2 * Double.pi * frequency / sampleRate
                let response = Self.sectionResponse(coefficients, omega: omega)
                let raw = atan2(response.numerator.imaginary, response.numerator.real)
                    - atan2(response.denominator.imaginary, response.denominator.real)
                var value = raw + offset
                if index > 0 {
                    while value - previous > Double.pi { offset -= 2 * Double.pi; value -= 2 * Double.pi }
                    while value - previous < -Double.pi { offset += 2 * Double.pi; value += 2 * Double.pi }
                }
                previous = value
                total[index] += value
            }
        }
        return total
    }

    private func linearResidualPhase(frequencies: [Double]) -> [Double] {
        let delay = linearDelaySamples
        var result: [Double] = []
        result.reserveCapacity(frequencies.count)
        var previous = 0.0
        var offset = 0.0
        for (index, frequency) in frequencies.enumerated() {
            let omega = 2 * Double.pi * frequency / sampleRate
            // H(w) = sum h[n] e^-jwn, evaluated by rotating a unit phasor (no trig per tap).
            let step = (cos(omega), -sin(omega))
            var phasor = (1.0, 0.0)
            var real = 0.0
            var imaginary = 0.0
            for tap in linearTaps {
                let value = Double(tap)
                real += value * phasor.0
                imaginary += value * phasor.1
                phasor = (phasor.0 * step.0 - phasor.1 * step.1, phasor.0 * step.1 + phasor.1 * step.0)
            }
            let raw = atan2(imaginary, real) + omega * delay
            var value = raw + offset
            if index > 0 {
                while value - previous > Double.pi { offset -= 2 * Double.pi; value -= 2 * Double.pi }
                while value - previous < -Double.pi { offset += 2 * Double.pi; value += 2 * Double.pi }
            }
            previous = value
            result.append(value)
        }
        return result
    }

    // MARK: Group delay

    /// Group delay in seconds along `frequencies`. Linear phase is the constant (N - 1) / 2.
    func groupDelaySeconds(frequencies: [Double]) -> [Double] {
        guard sampleRate > 0 else { return [] }
        if realisation == .linear {
            return [Double](repeating: linearDelaySamples / sampleRate, count: frequencies.count)
        }
        return frequencies.map { frequency in
            let omega = 2 * Double.pi * frequency / sampleRate
            var samples = 0.0
            for coefficients in sections {
                samples += Self.polynomialDelay([Double(coefficients.b0), Double(coefficients.b1), Double(coefficients.b2)], omega: omega)
                    - Self.polynomialDelay([1, Double(coefficients.a1), Double(coefficients.a2)], omega: omega)
            }
            return samples / sampleRate
        }
    }

    /// Re[sum k c_k e^-jwk / sum c_k e^-jwk]; zero where the polynomial vanishes.
    private static func polynomialDelay(_ coefficients: [Double], omega: Double) -> Double {
        var valueReal = 0.0
        var valueImaginary = 0.0
        var weightedReal = 0.0
        var weightedImaginary = 0.0
        for (k, c) in coefficients.enumerated() {
            let re = c * cos(omega * Double(k))
            let im = -c * sin(omega * Double(k))
            valueReal += re
            valueImaginary += im
            weightedReal += Double(k) * re
            weightedImaginary += Double(k) * im
        }
        let power = valueReal * valueReal + valueImaginary * valueImaginary
        guard power > 1.0e-24 else { return 0 }
        return (weightedReal * valueReal + weightedImaginary * valueImaginary) / power
    }

    // MARK: Time domain

    /// The response to a unit impulse, `length` samples, in double precision (the cascade) or
    /// the FIR taps (linear phase).
    func impulse(length: Int) -> [Double] {
        guard length > 0 else { return [] }
        if realisation == .linear {
            var taps = linearTaps.prefix(length).map(Double.init)
            if taps.count < length { taps += [Double](repeating: 0, count: length - taps.count) }
            return taps
        }
        var signal = [Double](repeating: 0, count: length)
        signal[0] = 1
        for coefficients in sections {
            let b0 = Double(coefficients.b0), b1 = Double(coefficients.b1), b2 = Double(coefficients.b2)
            let a1 = Double(coefficients.a1), a2 = Double(coefficients.a2)
            var z1 = 0.0, z2 = 0.0
            for index in 0..<length {
                let input = signal[index]
                let output = b0 * input + z1
                z1 = b1 * input - a1 * output + z2
                z2 = b2 * input - a2 * output
                signal[index] = output
            }
        }
        return signal
    }

    /// The running sum of the impulse response.
    func step(length: Int) -> [Double] {
        var sum = 0.0
        return impulse(length: length).map { sum += $0; return sum }
    }

    /// How long the time views run: 100 ms for the cascade; the whole filter plus 10 percent
    /// for linear phase.
    var timeWindowSeconds: Double {
        if realisation == .linear, sampleRate > 0 { return Double(linearTaps.count) * 1.1 / sampleRate }
        return 0.1
    }

    // MARK: Series

    /// Log-spaced frequencies from `lower` to `upper`.
    static func frequencyGrid(lower: Double, upper: Double, count: Int) -> [Double] {
        guard count > 1, lower > 0, upper > lower else { return [lower] }
        let ratio = log(upper / lower)
        return (0..<count).map { lower * exp(ratio * Double($0) / Double(count - 1)) }
    }

    /// The curve for `view`. Magnitude uses the frequency grid; phase and group delay too;
    /// impulse and step ignore it and use `timePoints` samples spread over the time window,
    /// decimated for display (the first sample of each group of peak magnitude is kept).
    func series(for view: EQGraphView, frequencies: [Double], timePoints: Int = 400) -> EQAnalysisSeries {
        switch view {
        case .magnitude:
            return EQAnalysisSeries(
                view: view, xs: frequencies, ys: frequencies.map(magnitudeDB(at:)), unit: "dB", note: fallbackNote
            )
        case .phase:
            let degrees = phaseRadians(frequencies: frequencies).map { $0 * 180 / Double.pi }
            var note = fallbackNote
            if realisation == .linear {
                let milliseconds = linearDelaySamples / sampleRate * 1_000
                note = String(format: "Linear phase: constant delay %.2f ms plus the residual phase shown.", milliseconds)
            }
            return EQAnalysisSeries(view: view, xs: frequencies, ys: degrees, unit: "deg", note: note)
        case .groupDelay:
            let milliseconds = groupDelaySeconds(frequencies: frequencies).map { $0 * 1_000 }
            var note = fallbackNote
            if realisation == .linear {
                note = String(format: "Linear phase: constant %.0f samples (%.2f ms).", linearDelaySamples, linearDelaySamples / sampleRate * 1_000)
            }
            return EQAnalysisSeries(view: view, xs: frequencies, ys: milliseconds, unit: "ms", note: note)
        case .impulse, .step:
            let length = max(2, Int((timeWindowSeconds * sampleRate).rounded()))
            let samples = view == .impulse ? impulse(length: length) : step(length: length)
            let points = min(max(timePoints, 2), length)
            var xs: [Double] = []
            var ys: [Double] = []
            xs.reserveCapacity(points)
            ys.reserveCapacity(points)
            for point in 0..<points {
                let lower = point * length / points
                let upper = max(lower + 1, (point + 1) * length / points)
                var best = samples[lower]
                for index in lower..<min(upper, length) where abs(samples[index]) > abs(best) { best = samples[index] }
                xs.append(Double(lower) / sampleRate * 1_000)
                ys.append(best)
            }
            return EQAnalysisSeries(view: view, xs: xs, ys: ys, unit: "", note: fallbackNote)
        }
    }

    // MARK: Section response

    private struct Complex {
        var real: Double
        var imaginary: Double
    }

    private static func sectionResponse(
        _ c: N60BiquadCoefficients,
        omega: Double
    ) -> (numerator: Complex, denominator: Complex) {
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)
        let b0 = Double(c.b0), b1 = Double(c.b1), b2 = Double(c.b2)
        let a1 = Double(c.a1), a2 = Double(c.a2)
        return (
            Complex(real: b0 + b1 * cos1 + b2 * cos2, imaginary: -b1 * sin1 - b2 * sin2),
            Complex(real: 1 + a1 * cos1 + a2 * cos2, imaginary: -a1 * sin1 - a2 * sin2)
        )
    }
}
