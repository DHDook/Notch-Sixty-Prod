import XCTest
@testable import NotchSixty

/// E10 S1: the core minimum-phase designer matches the Swift designer (0.01 dB, 0.5 degrees), and
/// the grid and ABI are what the design note fixes.
final class RoomCorrectionCoreTests: XCTestCase {
    func testAbiAndGrid() throws {
        XCTAssertEqual(RoomCorrectionCore.abiVersion, 1)
        let grid = try RoomCorrectionCore.gridFrequencies()
        XCTAssertEqual(grid.count, 479)
        XCTAssertEqual(grid[0], 20, accuracy: 1e-9)
        XCTAssertEqual(grid[48], 40, accuracy: 1e-9)
        XCTAssertLessThan(grid.last ?? 0, 20_000)
    }

    func testMinimumPhaseParityWithSwiftDesigner() throws {
        let curveFrequencies: [Double] = [20, 50, 100, 200, 400, 1000, 2500, 6000, 12000, 20000]
        let curveGain: [Double] = [0, -4, 3, -6, 2, 0, -3, 2, -1, 0]
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: curveFrequencies, magnitudeDB: curveGain, phaseRadians: nil)
        for sampleRate in [44_100.0, 48_000, 96_000, 192_000] {
            let taps = Int(8192 * sampleRate / 48_000)
            let swiftTaps = try RoomCorrectionFIRDesigner().minimumPhaseTaps(
                desiredCorrection: response, effectiveLowHz: 20, effectiveHighHz: 20_000,
                sampleRate: sampleRate, tapCount: taps)
            let coreTaps = try RoomCorrectionCore.minimumPhaseTaps(
                sampleRate: sampleRate, tapCount: taps, frequenciesHz: curveFrequencies, gainDB: curveGain,
                lowHz: 20, highHz: 20_000)
            for frequency in [30.0, 60, 100, 150, 250, 500, 1000, 2000, 4000, 8000] {
                let s = Self.response(swiftTaps, frequency, sampleRate)
                let c = Self.response(coreTaps, frequency, sampleRate)
                let dB = 20 * log10(hypot(c.0, c.1) / hypot(s.0, s.1))
                var dPhase = atan2(c.1, c.0) - atan2(s.1, s.0)
                while dPhase > .pi { dPhase -= 2 * .pi }
                while dPhase < -.pi { dPhase += 2 * .pi }
                XCTAssertEqual(dB, 0, accuracy: 0.01, "magnitude at \(frequency) Hz, \(sampleRate)")
                XCTAssertEqual(dPhase * 180 / .pi, 0, accuracy: 0.5, "phase at \(frequency) Hz, \(sampleRate)")
            }
        }
    }

    private static func response(_ taps: [Float], _ frequency: Double, _ sampleRate: Double) -> (Double, Double) {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * frequency / sampleRate
        for (n, tap) in taps.enumerated() {
            re += Double(tap) * cos(w * Double(n))
            im -= Double(tap) * sin(w * Double(n))
        }
        return (re, im)
    }
}
