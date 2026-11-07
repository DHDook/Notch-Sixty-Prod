import Foundation
import XCTest
@testable import NotchSixty

final class EQFilterAnalysisTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func peaking(_ frequency: Double = 1_000, gain: Double = 9, q: Double = 1.4) -> EQBand {
        EQBand(type: .peaking, frequencyHz: frequency, gainDB: gain, q: q)
    }

    private func butterworthHighPass(_ frequency: Double = 200) -> EQBand {
        EQBand(type: .highPass, frequencyHz: frequency, gainDB: 0, q: 0.7071067811865476, slope: .db12)
    }

    private func grid(_ rate: Double, count: Int = 120) -> [Double] {
        EQFilterAnalysis.frequencyGrid(lower: 20, upper: rate * 0.49, count: count)
    }

    // MARK: Independent references

    private struct Complex {
        var re: Double, im: Double
        static func + (l: Complex, r: Complex) -> Complex { Complex(re: l.re + r.re, im: l.im + r.im) }
        static func * (l: Complex, r: Complex) -> Complex { Complex(re: l.re * r.re - l.im * r.im, im: l.re * r.im + l.im * r.re) }
        static func - (l: Complex, r: Complex) -> Complex { Complex(re: l.re - r.re, im: l.im - r.im) }
        var abs: Double { hypot(re, im) }
        func scaled(_ k: Double) -> Complex { Complex(re: re * k, im: im * k) }
        func divided(by d: Complex) -> Complex {
            let n = d.re * d.re + d.im * d.im
            return Complex(re: (re * d.re + im * d.im) / n, im: (im * d.re - re * d.im) / n)
        }
        static func exp(_ angle: Double) -> Complex { Complex(re: cos(angle), im: sin(angle)) }
    }

    /// Roots of z^2 + p z + q, as the zeros (numerator, with b1/b0 and b2/b0) or poles of a section.
    private func roots(_ p: Double, _ q: Double) -> [Complex] {
        let disc = p * p - 4 * q
        if disc >= 0 {
            return [Complex(re: (-p + disc.squareRoot()) / 2, im: 0), Complex(re: (-p - disc.squareRoot()) / 2, im: 0)]
        }
        return [Complex(re: -p / 2, im: (-disc).squareRoot() / 2), Complex(re: -p / 2, im: -(-disc).squareRoot() / 2)]
    }

    /// Closed form from the pole-zero factorisation: H = b0 prod (1 - z_i e^-jw) / prod (1 - p_i e^-jw).
    private func closedForm(_ sections: [N60BiquadCoefficients], omega: Double) -> (phase: Double, delaySamples: Double) {
        var phase = 0.0
        var delay = 0.0
        let rotation = Complex.exp(-omega)
        for section in sections {
            let b0 = Double(section.b0)
            let zeros = roots(Double(section.b1) / b0, Double(section.b2) / b0)
            let poles = roots(Double(section.a1), Double(section.a2))
            if b0 < 0 { phase += Double.pi }
            for (root, sign) in zeros.map({ ($0, 1.0) }) + poles.map({ ($0, -1.0) }) {
                let factor = Complex(re: 1, im: 0) - root * rotation        // 1 - r e^-jw
                phase += sign * atan2(factor.im, factor.re)
                // d/dw of -arg(1 - r e^-jw) is Re[(-r e^-jw) / (1 - r e^-jw)] for the group delay.
                let term = (root * rotation).scaled(-1).divided(by: factor)
                delay += sign * term.re
            }
        }
        return (phase, delay)
    }

    private func wrapped(_ x: Double) -> Double {
        var value = x.truncatingRemainder(dividingBy: 2 * Double.pi)
        if value > Double.pi { value -= 2 * Double.pi }
        if value < -Double.pi { value += 2 * Double.pi }
        return value
    }

    private func complexResponse(_ sections: [N60BiquadCoefficients], omega: Double) -> Complex {
        var total = Complex(re: 1, im: 0)
        for c in sections {
            let z1 = Complex.exp(-omega), z2 = Complex.exp(-2 * omega)
            let num = Complex(re: Double(c.b0), im: 0) + z1.scaled(Double(c.b1)) + z2.scaled(Double(c.b2))
            let den = Complex(re: 1, im: 0) + z1.scaled(Double(c.a1)) + z2.scaled(Double(c.a2))
            total = total * num.divided(by: den)
        }
        return total
    }

    // MARK: Magnitude

    func testMagnitudeEqualsTodaysMathAtEveryRate() {
        let bands = [peaking(), butterworthHighPass(), EQBand(type: .highShelf, frequencyHz: 6_000, gainDB: -4, q: 0.7)]
        for rate in rates {
            let analysis = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: rate)
            let program = ProductionEQResponseMath.compile(bands: bands, sampleRate: rate)
            for frequency in grid(rate) {
                let today = ProductionEQResponseMath.responseDB(program: program, sampleRate: rate, frequencyHz: frequency)
                XCTAssertEqual(analysis.magnitudeDB(at: frequency), today, accuracy: 1e-9, "\(rate) \(frequency)")
                // And the complex-domain value agrees with the dB sum.
                let direct = 20 * log10(complexResponse(analysis.sections, omega: 2 * .pi * frequency / rate).abs)
                XCTAssertEqual(direct, today, accuracy: 1e-9, "\(rate) \(frequency)")
            }
            let series = analysis.series(for: .magnitude, frequencies: grid(rate))
            XCTAssertEqual(series.ys.count, 120)
        }
    }

    // MARK: Phase and group delay

    func testPhaseAndGroupDelayMatchClosedFormAtEveryRate() {
        for rate in rates {
            for band in [peaking(), butterworthHighPass()] {
                let analysis = EQFilterAnalysis(bands: [band], phaseMode: .minimumPhase, sampleRate: rate)
                let frequencies = grid(rate)
                let phase = analysis.phaseRadians(frequencies: frequencies)
                let delay = analysis.groupDelaySeconds(frequencies: frequencies)
                for (index, frequency) in frequencies.enumerated() {
                    let omega = 2 * Double.pi * frequency / rate
                    let reference = closedForm(analysis.sections, omega: omega)
                    XCTAssertEqual(wrapped(phase[index] - reference.phase), 0, accuracy: 1e-6, "\(rate) \(band.type) \(frequency)")
                    XCTAssertEqual(delay[index], reference.delaySamples / rate, accuracy: 1e-9, "\(rate) \(band.type) \(frequency)")
                }
            }
        }
    }

    func testButterworthHighPassMatchesTheAnalogPrototype() {
        // 2nd-order Butterworth through the bilinear transform: H(s) = s^2 / (s^2 + sqrt2 s + 1)
        // with s normalised and prewarped. The coefficients are single precision, so the
        // tolerance here is looser than the closed form on the realised coefficients above.
        for rate in rates {
            let f0 = 200.0
            let analysis = EQFilterAnalysis(bands: [butterworthHighPass(f0)], phaseMode: .minimumPhase, sampleRate: rate)
            for frequency in [50.0, 150, 200, 400, 2_000] {
                let omega = 2 * Double.pi * frequency / rate
                let omega0 = 2 * Double.pi * f0 / rate
                let w = tan(omega / 2) / tan(omega0 / 2)
                let theta = atan2(2.0.squareRoot() * w, 1 - w * w)
                let expectedPhase = Double.pi - theta
                let measured = analysis.phaseRadians(frequencies: [frequency])[0]
                XCTAssertEqual(wrapped(measured - expectedPhase), 0, accuracy: 6e-3, "\(rate) \(frequency)")
                let dTheta = 2.0.squareRoot() * (1 + w * w) / (1 + w * w * w * w)
                let dW = 1 / (2 * pow(cos(omega / 2), 2)) / tan(omega0 / 2)
                let expectedDelay = dTheta * dW / rate
                let delay = analysis.groupDelaySeconds(frequencies: [frequency])[0]
                XCTAssertEqual(delay, expectedDelay, accuracy: expectedDelay * 1e-2 + 1e-9, "\(rate) \(frequency)")
            }
        }
    }

    func testGroupDelayIsMinusPhaseDerivativeAtEveryRateAndMode() {
        let bands = [peaking(500, gain: 8, q: 2), butterworthHighPass(120), EQBand(type: .lowShelf, frequencyHz: 90, gainDB: 5, q: 0.7)]
        for rate in rates {
            for mode in [EQPhaseMode.minimumPhase, .mixedPhase] {
                let analysis = EQFilterAnalysis(bands: bands, phaseMode: mode, sampleRate: rate)
                XCTAssertEqual(analysis.realisation, mode == .mixedPhase ? .mixed : .minimum)
                for frequency in [60.0, 130, 500, 900, 4_000, 12_000] where frequency < rate * 0.45 {
                    let h = frequency * 1.0e-4
                    let pair = analysis.phaseRadians(frequencies: [frequency - h, frequency + h])
                    let derivative = (pair[1] - pair[0]) / (2 * Double.pi * 2 * h / rate)   // d phi / d omega
                    let delay = analysis.groupDelaySeconds(frequencies: [frequency])[0] * rate
                    XCTAssertEqual(delay, -derivative, accuracy: max(1.0e-4 * abs(delay), 1.0e-4), "\(rate) \(mode) \(frequency)")
                }
            }
        }
    }

    func testMixedPhaseAddsAllPassCorrectionWithUnchangedMagnitude() {
        let bands = [peaking(300, gain: 10, q: 3), butterworthHighPass(80)]
        let minimum = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: 48_000)
        let mixed = EQFilterAnalysis(bands: bands, phaseMode: .mixedPhase, sampleRate: 48_000)
        XCTAssertGreaterThan(mixed.sections.count, minimum.sections.count)
        for frequency in [30.0, 100, 300, 1_000, 10_000] {
            XCTAssertEqual(mixed.magnitudeDB(at: frequency), minimum.magnitudeDB(at: frequency), accuracy: 1e-4)
        }
        let allPass = EQBand(type: .allPass, frequencyHz: 800, gainDB: 0, q: 1)
        let blocked = EQFilterAnalysis(bands: [allPass], phaseMode: .mixedPhase, sampleRate: 48_000)
        XCTAssertEqual(blocked.realisation, .minimum)
        XCTAssertNotNil(blocked.fallbackNote)
    }

    // MARK: Linear phase

    func testLinearPhaseHasConstantDelayAndSmallResidualPhaseAtEveryRate() {
        let bands = [peaking(1_000, gain: 6, q: 1), EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 3, q: 0.7)]
        for rate in rates {
            let analysis = EQFilterAnalysis(bands: bands, phaseMode: .linearPhase, sampleRate: rate)
            XCTAssertEqual(analysis.realisation, .linear, "\(rate)")
            let taps = analysis.linearTaps.count
            XCTAssertEqual(taps % 2, 1)
            XCTAssertEqual(Int(N60LinearPhaseEQRecommendedTapCount(rate)), taps)
            let expectedDelay = Double(taps - 1) / 2
            XCTAssertEqual(analysis.linearDelaySamples, expectedDelay)

            let frequencies = [100.0, 300, 1_000, 3_000, 8_000]
            let delays = analysis.groupDelaySeconds(frequencies: frequencies)
            for delay in delays { XCTAssertEqual(delay, expectedDelay / rate, accuracy: 1e-12, "\(rate)") }

            let residual = analysis.phaseRadians(frequencies: frequencies)
            for (index, frequency) in frequencies.enumerated() where analysis.magnitudeDB(at: frequency) > -3 {
                XCTAssertEqual(wrapped(residual[index]), 0, accuracy: 1e-3, "\(rate) \(frequency)")
            }
        }
    }

    func testLinearPhaseFallsBackWithANoteForAllPass() {
        let allPass = EQBand(type: .allPass, frequencyHz: 800, gainDB: 0, q: 1)
        let analysis = EQFilterAnalysis(bands: [allPass], phaseMode: .linearPhase, sampleRate: 48_000)
        XCTAssertEqual(analysis.realisation, .minimum)
        XCTAssertNotNil(analysis.fallbackNote)
    }

    // MARK: Impulse and step

    private func dft(_ samples: [Double], frequency: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        let omega = 2 * Double.pi * frequency / rate
        for (n, value) in samples.enumerated() {
            re += value * cos(omega * Double(n))
            im -= value * sin(omega * Double(n))
        }
        return 20 * log10(hypot(re, im))
    }

    func testImpulseSpectrumMatchesTheResponseAtEveryRate() {
        let bands = [peaking(1_000, gain: 6, q: 1.2), EQBand(type: .highShelf, frequencyHz: 5_000, gainDB: -3, q: 0.7)]
        for rate in rates {
            let analysis = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: rate)
            let impulse = analysis.impulse(length: Int(rate * 0.25))
            for frequency in [100.0, 500, 1_000, 2_000, 7_000] {
                XCTAssertEqual(dft(impulse, frequency: frequency, rate: rate), analysis.magnitudeDB(at: frequency), accuracy: 0.01, "\(rate) \(frequency)")
            }
        }
    }

    func testLinearPhaseImpulseSpectrumMatchesItsTapsAtEveryRate() {
        let bands = [peaking(1_000, gain: 6, q: 1.2)]
        for rate in rates {
            let analysis = EQFilterAnalysis(bands: bands, phaseMode: .linearPhase, sampleRate: rate)
            let impulse = analysis.impulse(length: analysis.linearTaps.count)
            XCTAssertEqual(impulse.count, analysis.linearTaps.count)
            XCTAssertEqual(impulse[0], Double(analysis.linearTaps[0]))
            // The peak sits at the centre tap.
            let peak = impulse.indices.max { abs(impulse[$0]) < abs(impulse[$1]) }!
            XCTAssertEqual(Double(peak), analysis.linearDelaySamples)
            // The tap design is a finite approximation of the ideal response; it lands within
            // 0.02 dB here, so the bound is 0.05 dB rather than the 0.01 dB of the IIR cases.
            for frequency in [300.0, 1_000, 3_000] {
                XCTAssertEqual(dft(impulse, frequency: frequency, rate: rate), analysis.magnitudeDB(at: frequency), accuracy: 0.05, "\(rate) \(frequency)")
            }
        }
    }

    func testStepEndsAtDCGainAtEveryRate() {
        let lowShelf = EQBand(type: .lowShelf, frequencyHz: 200, gainDB: 6, q: 0.7)
        for rate in rates {
            for bands in [[lowShelf], [butterworthHighPass(100)], [peaking()]] {
                let analysis = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: rate)
                let section = analysis.sections
                let expected = section.reduce(1.0) { $0 * (Double($1.b0) + Double($1.b1) + Double($1.b2)) / (1 + Double($1.a1) + Double($1.a2)) }
                let step = analysis.step(length: Int(rate * 1.5))
                XCTAssertEqual(step.last!, expected, accuracy: 2e-4, "\(rate)")
                XCTAssertEqual(analysis.dcGain, expected, accuracy: 1e-12)
            }
        }
        let high = EQFilterAnalysis(bands: [butterworthHighPass(100)], phaseMode: .minimumPhase, sampleRate: 48_000)
        XCTAssertEqual(high.step(length: 72_000).last!, 0, accuracy: 1e-4)
        let shelf = EQFilterAnalysis(bands: [lowShelf], phaseMode: .minimumPhase, sampleRate: 48_000)
        XCTAssertEqual(shelf.dcGain, pow(10, 6.0 / 20), accuracy: 1e-5)
    }

    func testLinearPhaseStepEndsAtDCGain() {
        let analysis = EQFilterAnalysis(bands: [EQBand(type: .lowShelf, frequencyHz: 200, gainDB: 6, q: 0.7)], phaseMode: .linearPhase, sampleRate: 48_000)
        let step = analysis.step(length: analysis.linearTaps.count + 100)
        XCTAssertEqual(step.last!, analysis.dcGain, accuracy: 1e-9)
    }

    // MARK: Series

    func testSeriesShapesAndNotes() {
        let rate = 48_000.0
        let bands = [peaking()]
        let frequencies = grid(rate)
        let minimum = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: rate)
        for view in EQGraphView.allCases {
            let series = minimum.series(for: view, frequencies: frequencies)
            XCTAssertEqual(series.view, view)
            XCTAssertEqual(series.xs.count, series.ys.count)
            XCTAssertTrue(series.ys.allSatisfy(\.isFinite))
            let range = series.autoRange
            XCTAssertLessThan(range.lowerBound, range.upperBound)
            XCTAssertTrue(series.ys.allSatisfy { range.contains($0) })
        }
        let timeSeries = minimum.series(for: .impulse, frequencies: frequencies, timePoints: 100)
        XCTAssertEqual(timeSeries.xs.count, 100)
        XCTAssertEqual(timeSeries.xs.first, 0)
        XCTAssertEqual(timeSeries.xs.last!, 99 * 4800 / 100 / rate * 1_000, accuracy: 0.5)
        let linear = EQFilterAnalysis(bands: bands, phaseMode: .linearPhase, sampleRate: rate)
        XCTAssertTrue(linear.series(for: .groupDelay, frequencies: frequencies).note?.contains("Linear phase") == true)
        XCTAssertTrue(linear.series(for: .phase, frequencies: frequencies).note?.contains("residual") == true)
    }

    func testFlatEQHasZeroPhaseAndDelay() {
        let analysis = EQFilterAnalysis(bands: [], phaseMode: .minimumPhase, sampleRate: 48_000)
        let frequencies = grid(48_000, count: 20)
        XCTAssertTrue(analysis.phaseRadians(frequencies: frequencies).allSatisfy { $0 == 0 })
        XCTAssertTrue(analysis.groupDelaySeconds(frequencies: frequencies).allSatisfy { $0 == 0 })
        XCTAssertEqual(analysis.impulse(length: 4), [1, 0, 0, 0])
        XCTAssertEqual(analysis.series(for: .phase, frequencies: frequencies).autoRange.lowerBound < 0, true)
    }

    func testAxisScale() {
        XCTAssertEqual(EQAxisScale.niceStep(0.7), 1)
        XCTAssertEqual(EQAxisScale.niceStep(1.5), 2)
        XCTAssertEqual(EQAxisScale.niceStep(30), 50)
        let range = EQAxisScale.niceRange(minimum: -170, maximum: 12)
        XCTAssertLessThanOrEqual(range.lowerBound, -170)
        XCTAssertGreaterThanOrEqual(range.upperBound, 12)
        XCTAssertTrue(EQAxisScale.ticks(in: range).contains(0))
        XCTAssertEqual(EQAxisScale.niceRange(minimum: 3, maximum: 3).lowerBound < 3, true)
        XCTAssertEqual(EQAxisScale.ticks(in: 0...0), [])
    }
}
