import XCTest
@testable import NotchSixty

/// E4 S27: free-field twin with two point-source speakers and two zones, one near each speaker.
/// Tone phasors are synthesised as real signals at each device rate and demodulated.
final class QuietZoneZonesTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let c = 343.0
    private let f = 100.0

    private func phasor(fs: Double, amp: Double, delay: Double) -> ActiveQuietZoneComplex {
        let n = Int(fs * 0.1)
        let x = (0..<n).map { Float(amp * cos(2 * .pi * f * (Double($0) / fs - delay))) }
        return QuietZoneTonePhasor.measure(samples: x, frequencyHz: f, sampleRate: fs)!
    }

    private func point(x: Double, y: Double, fs: Double) -> QuietZoneZoneTone {
        // Plane-wave noise travelling along +x; speakers at (0, -0.9) left and (0, 0.9) right.
        let noise = phasor(fs: fs, amp: 1, delay: x / c)
        func path(_ sy: Double) -> ActiveQuietZoneComplex {
            let r = max(hypot(x, y - sy), 0.05)
            return phasor(fs: fs, amp: 0.2 / r, delay: r / c)
        }
        return QuietZoneZoneTone(uncancelled: noise, leftPath: path(-0.9), rightPath: path(0.9))
    }

    func testTwoZonesEachMeetTargetMinus5dBAtEightRates() throws {
        for fs in rates {
            let zoneA = point(x: 0.4, y: -0.6, fs: fs), zoneB = point(x: 0.4, y: 0.6, fs: fs)
            let s = try QuietZoneTwoZoneSolver().solve(zones: [zoneA, zoneB])
            XCTAssertFalse(s.rejected, "fs \(fs)")
            for p in s.zones {
                XCTAssertGreaterThan(p.reductionDB, QuietZoneQualificationTargets.quietZoneTonalReductionDB - 5, "fs \(fs)")
            }
            // The predicted reduction equals the one recomputed from the paths.
            let r = zoneA.residual(left: s.left, right: s.right).magnitude
            XCTAssertEqual(-20 * log10(r / zoneA.uncancelled.magnitude), s.zones[0].reductionDB, accuracy: 1e-6)
        }
    }

    func testOtherSeatRegressionIsHeldToLimit() throws {
        for fs in rates {
            let zoneA = point(x: 0.4, y: -0.6, fs: fs), zoneB = point(x: 0.4, y: 0.6, fs: fs)
            let third = point(x: 0.7, y: 0.0, fs: fs)
            let s = try QuietZoneTwoZoneSolver().solve(zones: [zoneA, zoneB], others: [third])
            XCTAssertLessThanOrEqual(s.otherPointIncreaseDB[0], QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB + 1e-6, "fs \(fs)")
        }
    }

    func testOtherSeatRegressionDisarmsWhenZonesCannotImprove() throws {
        // An outside point that the anti-noise always makes much louder forces the scale to zero.
        let zone = QuietZoneZoneTone(uncancelled: .init(real: 1, imaginary: 0), leftPath: .init(real: 1, imaginary: 0), rightPath: .init(real: 0.5, imaginary: 0.5))
        let zone2 = QuietZoneZoneTone(uncancelled: .init(real: 0.8, imaginary: 0.2), leftPath: .init(real: 0.4, imaginary: -0.3), rightPath: .init(real: 1, imaginary: 0))
        let other = QuietZoneZoneTone(uncancelled: .init(real: 0.01, imaginary: 0), leftPath: .init(real: 3, imaginary: 0), rightPath: .init(real: 3, imaginary: 0))
        let s = try QuietZoneTwoZoneSolver().solve(zones: [zone, zone2], others: [other])
        XCTAssertLessThanOrEqual(s.appliedScale, 0.05)
        XCTAssertTrue(s.rejected)
    }

    func testOutputCapScalesSolution() throws {
        let zoneA = point(x: 0.4, y: -0.6, fs: 48_000), zoneB = point(x: 0.4, y: 0.6, fs: 48_000)
        var solver = QuietZoneTwoZoneSolver()
        solver.maximumOutputMagnitude = 0.1
        let s = try solver.solve(zones: [zoneA, zoneB])
        XCTAssertLessThanOrEqual(max(s.left.magnitude, s.right.magnitude), 0.1 + 1e-12)
        XCTAssertLessThan(s.appliedScale, 1)
    }

    func testIdenticalPathsAreRejectedAsIllConditioned() {
        let p = QuietZoneZoneTone(uncancelled: .init(real: 1, imaginary: 0), leftPath: .init(real: 1, imaginary: 0), rightPath: .init(real: 1, imaginary: 0))
        XCTAssertThrowsError(try QuietZoneTwoZoneSolver().solve(zones: [p, p])) {
            XCTAssertEqual($0 as? QuietZoneZoneError, .illConditioned)
        }
    }

    func testSingleZoneUsesSameCore() throws {
        let zone = point(x: 0.4, y: -0.6, fs: 48_000)
        let s = try QuietZoneTwoZoneSolver().solve(zones: [zone])
        XCTAssertGreaterThan(s.zones[0].reductionDB, 15)
    }

    func testPlanMakesEverySurveyedPointOutsideTheZonesAnOtherSeat() throws {
        let ids = (0..<5).map { _ in UUID() }
        let plan = try QuietZoneZonePlan(mode: .twoZones, surveyedPointIDs: ids, zonePointIDs: [ids[0], ids[3]])
        XCTAssertEqual(Set(plan.otherSeatPointIDs), Set([ids[1], ids[2], ids[4]]))
        XCTAssertThrowsError(try QuietZoneZonePlan(mode: .twoZones, surveyedPointIDs: ids, zonePointIDs: [ids[0]]))
        XCTAssertThrowsError(try QuietZoneZonePlan(mode: .fixedSeat, surveyedPointIDs: ids, zonePointIDs: [UUID()]))
    }

    func testModeChangeWhileArmedRequiresRearmAndNewBinding() throws {
        let ids = (0..<3).map { _ in UUID() }
        let fixed = try QuietZoneZonePlan(mode: .fixedSeat, surveyedPointIDs: ids, zonePointIDs: [ids[0]])
        let two = try QuietZoneZonePlan(mode: .twoZones, surveyedPointIDs: ids, zonePointIDs: [ids[0], ids[1]])
        XCTAssertTrue(fixed.requiresRearm(comparedTo: two))
        XCTAssertFalse(fixed.requiresRearm(comparedTo: fixed))
        let a = EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000)
        let b = EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000, zoneMode: .twoZones)
        XCTAssertNotEqual(a, b)
    }

    func testBindingStoredBeforeS27DecodesAsFixedSeat() throws {
        let json = #"{"outputDeviceUID":"o","inputDeviceUID":"i","sampleRate":48000}"#
        let b = try JSONDecoder().decode(EarnedCapBinding.self, from: Data(json.utf8))
        XCTAssertEqual(b.zoneMode, .fixedSeat)
        let round = try JSONDecoder().decode(EarnedCapBinding.self, from: JSONEncoder().encode(EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 96_000, zoneMode: .follow)))
        XCTAssertEqual(round.zoneMode, .follow)
    }
}
