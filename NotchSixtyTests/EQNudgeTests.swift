import Foundation
import XCTest
@testable import NotchSixty

final class EQNudgeTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testStepSelectionPrefersOption() {
        XCTAssertEqual(EQNudge.Step(shift: false, option: false), .normal)
        XCTAssertEqual(EQNudge.Step(shift: true, option: false), .coarse)
        XCTAssertEqual(EQNudge.Step(shift: false, option: true), .fine)
        XCTAssertEqual(EQNudge.Step(shift: true, option: true), .fine)
    }

    func testTables() {
        XCTAssertEqual(EQNudge.frequencyRatio(.normal), pow(2, 1.0 / 12), accuracy: 1e-12)
        XCTAssertEqual(EQNudge.frequencyRatio(.coarse), pow(2, 1.0 / 3), accuracy: 1e-12)
        XCTAssertEqual(EQNudge.frequencyRatio(.fine), pow(2, 1.0 / 96), accuracy: 1e-12)
        XCTAssertEqual(EQNudge.gainStep(.normal), 0.5)
        XCTAssertEqual(EQNudge.gainStep(.coarse), 3)
        XCTAssertEqual(EQNudge.gainStep(.fine), 0.1)
        XCTAssertEqual(EQNudge.qRatio(.normal), 1.1)
        XCTAssertEqual(EQNudge.qRatio(.coarse), 1.5)
        XCTAssertEqual(EQNudge.qRatio(.fine), 1.02)
    }

    func testFrequencyNudgesAndRoundTrip() {
        let range = 20.0...(48_000 * 0.49)
        let up = EQNudge.frequency(1_000, direction: .up, step: .normal, range: range)
        XCTAssertEqual(up, 1_000 * pow(2, 1.0 / 12), accuracy: 1e-9)
        XCTAssertEqual(EQNudge.frequency(up, direction: .down, step: .normal, range: range), 1_000, accuracy: 1e-9)
        // Twelve semitones is one octave.
        var value = 500.0
        for _ in 0..<12 { value = EQNudge.frequency(value, direction: .up, step: .normal, range: range) }
        XCTAssertEqual(value, 1_000, accuracy: 1e-6)
        // 96 fine steps is one octave.
        value = 500
        for _ in 0..<96 { value = EQNudge.frequency(value, direction: .up, step: .fine, range: range) }
        XCTAssertEqual(value, 1_000, accuracy: 1e-6)
    }

    func testFrequencyClampsAtTwentyHertzAndTheNyquistLimitAtEveryRate() {
        for rate in rates {
            let band = EQBand()
            let ceiling = rate * 0.49
            for step in [EQNudge.Step.normal, .coarse, .fine] {
                XCTAssertEqual(
                    EQNudge.nudged(20, field: .frequency, direction: .down, step: step, band: band, maximumFrequency: ceiling),
                    20, "floor, rate \(rate)"
                )
                XCTAssertEqual(
                    EQNudge.nudged(ceiling, field: .frequency, direction: .up, step: step, band: band, maximumFrequency: ceiling),
                    ceiling, "ceiling, rate \(rate)"
                )
                let nearTop = EQNudge.nudged(ceiling * 0.999, field: .frequency, direction: .up, step: step, band: band, maximumFrequency: ceiling)
                XCTAssertLessThanOrEqual(nearTop, ceiling, "rate \(rate)")
                XCTAssertGreaterThan(nearTop, ceiling * 0.999 - 1e-9, "rate \(rate)")
            }
            // Repeated steps from far below never pass the ceiling.
            var value = 20.0
            for _ in 0..<400 {
                value = EQNudge.nudged(value, field: .frequency, direction: .up, step: .coarse, band: band, maximumFrequency: ceiling)
            }
            XCTAssertEqual(value, ceiling, "rate \(rate)")
        }
    }

    func testDynamicBandFrequencyStaysInItsRange() {
        var band = EQBand()
        band.dynamic.enabled = true
        let value = EQNudge.nudged(
            20_000, field: .frequency, direction: .up, step: .coarse, band: band, maximumFrequency: 384_000 * 0.49
        )
        XCTAssertEqual(value, DynamicEQBandConfiguration.frequencyRange.upperBound)
    }

    func testGainNudgesClampAndDoNotDrift() {
        XCTAssertEqual(EQNudge.gain(0, direction: .up, step: .normal), 0.5)
        XCTAssertEqual(EQNudge.gain(0, direction: .down, step: .coarse), -3)
        var value = 0.0
        for _ in 0..<10 { value = EQNudge.gain(value, direction: .up, step: .fine) }
        XCTAssertEqual(value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.gain(23.8, direction: .up, step: .coarse), 24)
        XCTAssertEqual(EQNudge.gain(-23.8, direction: .down, step: .coarse), -24)
    }

    func testQNudgesClamp() {
        XCTAssertEqual(EQNudge.q(1, direction: .up, step: .normal), 1.1, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(1, direction: .down, step: .coarse), 1 / 1.5, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(19.9, direction: .up, step: .coarse), 20)
        XCTAssertEqual(EQNudge.q(0.11, direction: .down, step: .coarse), 0.1)
        var dynamic = EQBand()
        dynamic.dynamic.enabled = true
        XCTAssertEqual(
            EQNudge.nudged(8, field: .q, direction: .up, step: .normal, band: dynamic, maximumFrequency: 20_000),
            DynamicEQBandConfiguration.qRange.upperBound
        )
    }

    func testScrollAndPinchScaleQ() {
        let range = 0.1...20.0
        XCTAssertEqual(EQNudge.q(1, scrollNotches: 1, range: range), 1.05, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(1, scrollNotches: -2, range: range), 1 / (1.05 * 1.05), accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(19.5, scrollNotches: 5, range: range), 20)
        XCTAssertEqual(EQNudge.q(1, scrollNotches: 0, range: range), 1)
        XCTAssertEqual(EQNudge.q(1, magnification: 0.2, range: range), 1.2, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(1, magnification: -0.5, range: range), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EQNudge.q(1, magnification: -1, range: range), 1, "an impossible pinch changes nothing")
        XCTAssertEqual(EQNudge.q(1, magnification: .nan, range: range), 1)
    }

    func testScrollAccumulator() {
        var wheel = EQNudge.ScrollAccumulator()
        XCTAssertEqual(wheel.add(delta: 1, precise: false), 1)
        XCTAssertEqual(wheel.add(delta: -3, precise: false), -3)
        XCTAssertEqual(wheel.add(delta: 0.2, precise: false), 1, "a small wheel tick is still one notch")
        XCTAssertEqual(wheel.add(delta: 0, precise: false), 0)

        var pad = EQNudge.ScrollAccumulator()
        XCTAssertEqual(pad.add(delta: 3, precise: true), 0)
        XCTAssertEqual(pad.add(delta: 3, precise: true), 0)
        XCTAssertEqual(pad.add(delta: 3, precise: true), 1, "9 points is one notch, 1 carries over")
        XCTAssertEqual(pad.add(delta: 7, precise: true), 1)
        XCTAssertEqual(pad.add(delta: -17, precise: true), -2)
        pad.reset()
        XCTAssertEqual(pad.add(delta: 7, precise: true), 0)
    }
}
