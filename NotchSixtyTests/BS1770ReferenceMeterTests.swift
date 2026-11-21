import XCTest
@testable import NotchSixty

/// Self-test of the lab-case loudness meter against known BS.1770-4 and Tech 3341/3342 reference values, at the eight rates.
final class BS1770ReferenceMeterTests: XCTestCase {
    let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func sine(_ db: Double, rate: Double, seconds: Double, hz: Double = 997) -> [Float] {
        let a = pow(10, db / 20)
        return (0..<Int(rate * seconds)).map { Float(a * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    func testKWeightingMatchesThePublishedCoefficientsAt48kHz() {
        let stages = BS1770ReferenceMeter.kWeightingStages(rate: 48_000)
        XCTAssertEqual(stages[0].b0, 1.53512485958697, accuracy: 1e-8)
        XCTAssertEqual(stages[0].b1, -2.69169618940638, accuracy: 1e-8)
        XCTAssertEqual(stages[0].b2, 1.19839281085285, accuracy: 1e-8)
        XCTAssertEqual(stages[0].a1, -1.69065929318241, accuracy: 1e-8)
        XCTAssertEqual(stages[0].a2, 0.73248077421585, accuracy: 1e-8)
        XCTAssertEqual(stages[1].a1, -1.99004745483398, accuracy: 1e-8)
        XCTAssertEqual(stages[1].a2, 0.99007225036621, accuracy: 1e-8)
    }

    /// Tech 3341: a stereo 997 Hz sine at -23 dBFS reads -23.0 LUFS; one channel alone reads 3.01 LU lower.
    func testStereoSineReadsItsLevelAtEveryRate() {
        for rate in rates {
            let s = sine(-23, rate: rate, seconds: 5)
            XCTAssertEqual(BS1770ReferenceMeter.integratedLoudness([s, s], rate: rate), -23.0, accuracy: 0.1, "stereo at \(rate)")
            XCTAssertEqual(BS1770ReferenceMeter.integratedLoudness([s], rate: rate), -26.01, accuracy: 0.1, "one channel at \(rate)")
        }
    }

    /// The absolute gate drops near-silence and the relative gate drops a section 20 LU below the loud one.
    func testGatesAtEveryRate() {
        for rate in rates {
            let loud = sine(-23, rate: rate, seconds: 5)
            for (quiet, label) in [(-80.0, "absolute"), (-43.0, "relative")] {
                let s = loud + sine(quiet, rate: rate, seconds: 5)
                XCTAssertEqual(BS1770ReferenceMeter.integratedLoudness([s, s], rate: rate), -23.0, accuracy: 0.3, "\(label) gate at \(rate)")
            }
        }
    }

    /// Loudness range: alternating 6 s sections 10 LU apart read about 10 LU (the 3 s window transitions fall between).
    func testLoudnessRangeOfTwoLevelsAtEveryRate() {
        for rate in rates {
            let s = (0..<4).flatMap { sine($0 % 2 == 0 ? -23 : -33, rate: rate, seconds: 6) }
            XCTAssertEqual(BS1770ReferenceMeter.loudnessRange([s, s], rate: rate), 10, accuracy: 1.0, "LRA at \(rate)")
            let steady = sine(-23, rate: rate, seconds: 12)
            XCTAssertLessThan(BS1770ReferenceMeter.loudnessRange([steady, steady], rate: rate), 0.2, "steady tone has no range at \(rate)")
        }
    }
}
