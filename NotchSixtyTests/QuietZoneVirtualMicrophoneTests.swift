import XCTest
@testable import NotchSixty

/// E4 S26a: a free-field twin. A plane-wave noise tone and a point-source anti-noise speaker are
/// synthesised as real time-domain signals at each device rate, demodulated against the canceller
/// oscillator, and the virtual-microphone output is compared with one solved from a real microphone
/// at the ear 15 cm from the monitor.
final class QuietZoneVirtualMicrophoneTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let c = 343.0

    private func phasor(_ f: Double, fs: Double, amp: Double, delay: Double, noiseJitter: Double = 0) -> ActiveQuietZoneComplex {
        let n = Int(fs * 0.1)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            x[i] = Float(amp * cos(2 * .pi * f * (Double(i) / fs - delay) + noiseJitter))
        }
        return QuietZoneTonePhasor.measure(samples: x, frequencyHz: f, sampleRate: fs)!
    }

    /// Plane-wave noise from x = -inf: phase lag k*x; speaker at origin is a point source 1/r.
    private func noise(at x: Double, f: Double, fs: Double) -> ActiveQuietZoneComplex {
        phasor(f, fs: fs, amp: 1, delay: x / c)
    }

    private func speaker(distance r: Double, f: Double, fs: Double) -> ActiveQuietZoneComplex {
        phasor(f, fs: fs, amp: 0.2 / r, delay: r / c)
    }

    func testPhasorMeasurementIsExactAtEveryRate() {
        for fs in rates {
            let p = phasor(200, fs: fs, amp: 0.5, delay: 0.001)
            XCTAssertEqual(p.magnitude, 0.5, accuracy: 0.005, "fs \(fs)")
            XCTAssertEqual(p.phaseRadians, -2 * .pi * 200 * 0.001, accuracy: 0.01, "fs \(fs)")
        }
    }

    func testVirtualEarWithin3dBOfARealMicrophoneAtEightRates() throws {
        let f = 100.0
        // Monitor at 1.0 m from the speaker on the noise axis, ear 15 cm beyond it, same side.
        let monX = 1.0, earX = 1.15
        for fs in rates {
            let dMon = noise(at: monX, f: f, fs: fs), dEar = noise(at: earX, f: f, fs: fs)
            let sMon = speaker(distance: monX, f: f, fs: fs), sEar = speaker(distance: earX, f: f, fs: fs)
            let repeatsMon = (0..<4).map { _ in dMon }
            let repeatsEar = (0..<4).map { _ in dEar }
            let mic = try QuietZoneVirtualMicrophone.survey(
                monitor: [.init(frequencyHz: f, phasors: repeatsMon)],
                ear: [.init(frequencyHz: f, phasors: repeatsEar)],
                monitorSecondary: [sMon], earSecondary: [sEar])
            let yVirtual = mic.solve(toneIndex: 0, uncancelledMonitorNoise: dMon)
            // A real error microphone at the ear would solve the damped one-tone problem directly.
            let yReal = -(sEar.conjugate * dEar) / (sEar.magnitude * sEar.magnitude * 1.035)
            let residualVirtual = (dEar + sEar * yVirtual).magnitude
            let residualReal = (dEar + sEar * yReal).magnitude
            let gapDB = 20 * log10(max(residualVirtual, 1e-9) / max(residualReal, 1e-9))
            XCTAssertLessThan(gapDB, 3, "fs \(fs)")
            // The virtual error equals the true ear error when the paths are exact.
            let eMon = dMon + sMon * yVirtual
            let virt = mic.virtualError(toneIndex: 0, monitorError: eMon, output: yVirtual,
                                        monitorSecondary: sMon, earSecondary: sEar)
            XCTAssertEqual(virt.magnitude, residualVirtual, accuracy: 1e-6, "fs \(fs)")
        }
    }

    func testUnsteadyNoiseIsRefused() {
        let f = 100.0, fs = 48_000.0
        let jittery = (0..<4).map { phasor(f, fs: fs, amp: 1, delay: 0, noiseJitter: Double($0) * 1.2) }
        let steady = [ActiveQuietZoneComplex](repeating: phasor(f, fs: fs, amp: 1, delay: 0), count: 4)
        let s = ActiveQuietZoneComplex(real: 0.1, imaginary: 0.02)
        XCTAssertThrowsError(try QuietZoneVirtualMicrophone.survey(
            monitor: [.init(frequencyHz: f, phasors: jittery)], ear: [.init(frequencyHz: f, phasors: steady)],
            monitorSecondary: [s], earSecondary: [s])) {
            XCTAssertEqual($0 as? QuietZoneVirtualMicError, .unsteadyNoise(frequencyHz: f))
        }
    }

    func testTooFewRepeatsAndImplausibleRatioAndNoAuthority() {
        let f = 100.0
        let one = ActiveQuietZoneComplex(real: 1, imaginary: 0)
        let s = ActiveQuietZoneComplex(real: 0.1, imaginary: 0)
        XCTAssertThrowsError(try QuietZoneVirtualMicrophone.survey(
            monitor: [.init(frequencyHz: f, phasors: [one, one])], ear: [.init(frequencyHz: f, phasors: [one, one])],
            monitorSecondary: [s], earSecondary: [s])) {
            XCTAssertEqual($0 as? QuietZoneVirtualMicError, .tooFewRepeats)
        }
        let loud = ActiveQuietZoneComplex(real: 10, imaginary: 0)
        XCTAssertThrowsError(try QuietZoneVirtualMicrophone.survey(
            monitor: [.init(frequencyHz: f, phasors: [one, one, one])], ear: [.init(frequencyHz: f, phasors: [loud, loud, loud])],
            monitorSecondary: [s], earSecondary: [s])) {
            XCTAssertEqual($0 as? QuietZoneVirtualMicError, .implausibleRatio(frequencyHz: f))
        }
        // Ear and monitor see the speaker alike with ratio 1: effective path vanishes.
        XCTAssertThrowsError(try QuietZoneVirtualMicrophone.survey(
            monitor: [.init(frequencyHz: f, phasors: [one, one, one])], ear: [.init(frequencyHz: f, phasors: [one, one, one])],
            monitorSecondary: [s], earSecondary: [s])) {
            XCTAssertEqual($0 as? QuietZoneVirtualMicError, .noAuthorityAtEar(frequencyHz: f))
        }
    }
}
