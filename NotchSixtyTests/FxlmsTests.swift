import Foundation
import XCTest
@testable import NotchSixty

/// E4 S5: the adaptive ANC core as the app links it. The full scenario set
/// (Wiener, tracking, maximum step, caps, gaps) runs in ci/harness_e4_fxlms.c;
/// these cover the main behaviour at every standard rate through the bridging
/// header.
final class FxlmsTests: XCTestCase {
    private let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]
    private let buffer = 256

    /// Speaker to microphone: gain 0.5, 1 ms delay, 800 Hz one-pole low-pass.
    private struct Plant {
        let rate: Double
        let delay: Int
        let a: Double
        var line: [Float]
        var position = 0
        var state = 0.0
        var frame = 0
        var tones: [(hz: Double, re: Double, im: Double)] = []
        var noise = 0.0
        var rng: UInt64 = 0x1234_5678

        init(rate: Double) {
            self.rate = rate
            delay = Int((0.001 * rate).rounded())
            a = exp(-2 * .pi * 800 / rate)
            line = [Float](repeating: 0, count: delay + 1)
        }

        /// Response at hz, including the one-buffer I/O delay.
        func path(_ hz: Double, extra: Int) -> (re: Double, im: Double) {
            let w = 2 * Double.pi * hz / rate
            let d = Double(delay + extra)
            let nr = 0.5 * (1 - a) * cos(-w * d), ni = 0.5 * (1 - a) * sin(-w * d)
            let dr = 1 - a * cos(w), di = a * sin(w)
            let m = dr * dr + di * di
            return ((nr * dr + ni * di) / m, (ni * dr - nr * di) / m)
        }

        mutating func step(_ y: Float) -> Float {
            line[position] = y
            position = (position + 1) % line.count
            state = a * state + (1 - a) * Double(line[position])
            var mic = 0.5 * state
            let t = Double(frame) / rate
            for tone in tones {
                let ph = 2 * Double.pi * tone.hz * t
                mic += tone.re * cos(ph) - tone.im * sin(ph)
            }
            if noise > 0 {
                rng ^= rng << 13
                rng ^= rng >> 7
                rng ^= rng << 17
                mic += noise * (Double(rng >> 11) / Double(1 << 53) * 2 - 1) * 3.0.squareRoot()
            }
            frame += 1
            return Float(mic)
        }
    }

    private func run(_ core: OpaquePointer, _ plant: inout Plant, seconds: Double) {
        var played = [Float](repeating: 0, count: buffer)
        var out = [Float](repeating: 0, count: buffer)
        var err = [Float](repeating: 0, count: buffer)
        for _ in 0..<Int((seconds * plant.rate / Double(buffer)).rounded(.up)) {
            for n in 0..<buffer { err[n] = plant.step(played[n]) }
            N60AdaptiveTonalProcess(core, err, &out, UInt32(buffer))
            N60AdaptiveTonalService(core)
            swap(&played, &out)
        }
    }

    func testTonalCancellerConvergesToItsFixedPointAtEveryRate() throws {
        for rate in rates {
            var plant = Plant(rate: rate)
            plant.tones = [(60, 0.02 * cos(0.7), 0.02 * sin(0.7))]
            let s = plant.path(60, extra: buffer)
            var config = N60AdaptiveTonalConfigDefault(rate)
            config.toneCount = 1
            config.toneHz.0 = 60
            config.toneSeed.0 = N60AncComplex(re: Float(s.re), im: Float(s.im))
            let core = try XCTUnwrap(N60AdaptiveTonalCreate(&config), "\(rate) Hz")
            defer { N60AdaptiveTonalDestroy(core) }
            run(core, &plant, seconds: 2)

            // W = -D / (S (1 + lambda tau)) with an exact path estimate.
            let scale = 1 + config.leakagePerSecond * config.convergenceSeconds
            let m = s.re * s.re + s.im * s.im
            let dRe = plant.tones[0].re, dIm = plant.tones[0].im
            let wantRe = -(dRe * s.re + dIm * s.im) / m / scale
            let wantIm = -(dIm * s.re - dRe * s.im) / m / scale
            let status = N60AdaptiveTonalReadStatus(core)
            let w = status.weight.0
            let error = hypot(Double(w.re) - wantRe, Double(w.im) - wantIm) / hypot(wantRe, wantIm)
            XCTAssertLessThan(error, 0.01, "\(rate) Hz")
            XCTAssertTrue(status.adapting.0, "\(rate) Hz")
        }
    }

    func testProbeLearnsTheSecondaryPathAtEveryRate() throws {
        for rate in rates {
            var plant = Plant(rate: rate)
            plant.tones = [(60, 0.02, 0)]
            plant.noise = 3e-4
            var config = N60AdaptiveTonalConfigDefault(rate)
            config.toneCount = 1
            config.toneHz.0 = 60
            config.probeEnabled = true
            let core = try XCTUnwrap(N60AdaptiveTonalCreate(&config), "\(rate) Hz")
            defer { N60AdaptiveTonalDestroy(core) }
            XCTAssertFalse(N60AdaptiveTonalReadStatus(core).adapting.0, "no path yet")
            run(core, &plant, seconds: 2.5)

            let s = plant.path(60, extra: buffer)
            let p = N60AdaptiveTonalReadStatus(core).path.0
            let gainDB = 20 * log10(hypot(Double(p.re), Double(p.im)) / hypot(s.re, s.im))
            let phase = (atan2(Double(p.im), Double(p.re)) - atan2(s.im, s.re))
                .remainder(dividingBy: 2 * .pi) * 180 / .pi
            XCTAssertLessThan(abs(gainDB), 0.5, "\(rate) Hz")
            XCTAssertLessThan(abs(phase), 3, "\(rate) Hz")
        }
    }

    func testBlockFxlmsLeaksWithNoReference() throws {
        for rate in rates {
            let fd = rate / Double(N60AncDecimationFactor(rate))
            var config = N60BlockFxlmsConfigDefault(fd)
            config.taps = 8
            config.blockFrames = 16
            config.leakagePerSecond = 0.5
            let fxlms = try XCTUnwrap(N60BlockFxlmsCreate(&config), "\(rate) Hz")
            defer { N60BlockFxlmsDestroy(fxlms) }
            let seed: [Float] = [0.5, -0.25, 0.125, 0, 0, 0, 0, 0.1]
            N60BlockFxlmsSetWeights(fxlms, seed, 8)
            let reference = [Float](repeating: 0, count: 16)
            let error = (0..<16).map { Float(sin(Double($0))) * 0.01 }
            let blocks = Int(2 * fd / 16)
            for _ in 0..<blocks { N60BlockFxlmsUpdate(fxlms, reference, error, 16) }
            var weights = [Float](repeating: 0, count: 8)
            N60BlockFxlmsCopyWeights(fxlms, &weights, 8)
            let decay = pow(1 - 0.5 * 16 / fd, Double(blocks))
            for k in 0..<8 {
                XCTAssertEqual(Double(weights[k]), Double(seed[k]) * decay, accuracy: 1e-6, "\(rate) Hz")
            }
        }
    }

    func testDecimatorFactorAndDelay() {
        for rate in rates {
            let d = N60AncDecimationFactor(rate)
            XCTAssertEqual(d, UInt32(rate / 4000), "\(rate) Hz")
            XCTAssertEqual(N60AncDecimatorDelayFrames(rate), 8 * d, "\(rate) Hz")
            let fd = rate / Double(d)
            XCTAssertTrue(fd >= 4000 && fd < 4010, "\(rate) Hz: fd \(fd)")
        }
    }

    func testInvalidConfigurationsAreRejected() {
        var config = N60AdaptiveTonalConfigDefault(48_000)
        config.toneCount = 1
        config.toneHz.0 = 60
        XCTAssertTrue(N60AdaptiveTonalConfigIsValid(&config))
        config.convergenceSeconds = 0.05
        XCTAssertNil(N60AdaptiveTonalCreate(&config), "step above the documented maximum")
        config = N60AdaptiveTonalConfigDefault(48_000)
        config.probeLevelDBFS = -30
        XCTAssertNil(N60AdaptiveTonalCreate(&config), "probe louder than -40 dBFS")
        config = N60AdaptiveTonalConfigDefault(1_000_000)
        XCTAssertNil(N60AdaptiveTonalCreate(&config), "rate above 768 kHz")
        var block = N60BlockFxlmsConfigDefault(4_000)
        block.step = 0.6
        XCTAssertNil(N60BlockFxlmsCreate(&block), "block step above 0.5")
    }
}
