import XCTest
@testable import NotchSixty

/// E4 S26b: head pose selects and interpolates surveyed virtual-microphone ratios. Free-field twin on the
/// noise axis (plane wave, point-source speaker) at each device rate; the pose fixture moves the zone.
final class QuietZoneHeadPositionTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let c = 343.0
    private let f = 100.0

    private func phasor(fs: Double, amp: Double, delay: Double) -> ActiveQuietZoneComplex {
        let n = Int(fs * 0.1)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = Float(amp * cos(2 * .pi * f * (Double(i) / fs - delay))) }
        return QuietZoneTonePhasor.measure(samples: x, frequencyHz: f, sampleRate: fs)!
    }
    private func noise(_ x: Double, _ fs: Double) -> ActiveQuietZoneComplex { phasor(fs: fs, amp: 1, delay: x / c) }
    private func speaker(_ x: Double, _ fs: Double) -> ActiveQuietZoneComplex { phasor(fs: fs, amp: 0.2 / x, delay: x / c) }

    private func mic(monX: Double, earX: Double, fs: Double) throws -> QuietZoneVirtualMicrophone {
        let dMon = noise(monX, fs), dEar = noise(earX, fs)
        return try QuietZoneVirtualMicrophone.survey(
            monitor: [.init(frequencyHz: f, phasors: Array(repeating: dMon, count: 4))],
            ear: [.init(frequencyHz: f, phasors: Array(repeating: dEar, count: 4))],
            monitorSecondary: [speaker(monX, fs)], earSecondary: [speaker(earX, fs)])
    }

    private func gapDB(_ m: QuietZoneVirtualMicrophone, earX: Double, monX: Double, fs: Double) -> Double {
        let dEar = noise(earX, fs), sEar = speaker(earX, fs)
        let y = m.solve(toneIndex: 0, uncancelledMonitorNoise: noise(monX, fs))
        let yReal = -(sEar.conjugate * dEar) / (sEar.magnitude * sEar.magnitude * 1.035)
        let rv = (dEar + sEar * y).magnitude, rr = (dEar + sEar * yReal).magnitude
        return 20 * log10(max(rv, 1e-9) / max(rr, 1e-9))
    }

    func testInterpolatedHeadBetweenSurveyedPointsWithin3dBAtEightRates() throws {
        let monX = 1.0
        for fs in rates {
            let survey = try QuietZoneHeadSurvey(points: [
                .init(x: 1.15, y: 0, z: 0, microphone: try mic(monX: monX, earX: 1.15, fs: fs)),
                .init(x: 1.35, y: 0, z: 0, microphone: try mic(monX: monX, earX: 1.35, fs: fs)),
            ])
            let pose = QuietZoneHeadPose(x: 1.25, y: 0, z: 0, confidence: 0.9, time: 0)
            let m = try XCTUnwrap(survey.microphone(at: pose), "fs \(fs)")
            XCTAssertLessThan(gapDB(m, earX: 1.25, monX: monX, fs: fs), 3, "fs \(fs)")
        }
    }

    func testPoseFixtureMovesTheZone() throws {
        let fs = 48_000.0
        let a = try mic(monX: 1.0, earX: 1.15, fs: fs), b = try mic(monX: 1.0, earX: 1.35, fs: fs)
        let survey = try QuietZoneHeadSurvey(points: [.init(x: 1.15, y: 0, z: 0, microphone: a),
                                                      .init(x: 1.35, y: 0, z: 0, microphone: b)])
        let atA = try XCTUnwrap(survey.microphone(at: .init(x: 1.15, y: 0, z: 0, confidence: 1, time: 0)))
        let atB = try XCTUnwrap(survey.microphone(at: .init(x: 1.35, y: 0, z: 0, confidence: 1, time: 0)))
        XCTAssertEqual(atA.tones[0].ratio, a.tones[0].ratio)
        XCTAssertEqual(atB.tones[0].ratio, b.tones[0].ratio)
        XCTAssertGreaterThan((atA.tones[0].ratio - atB.tones[0].ratio).magnitude, 1e-3)
    }

    func testOutsideTrustRadiusFallsBackToNil() throws {
        let fs = 48_000.0
        let survey = try QuietZoneHeadSurvey(points: [.init(x: 1.15, y: 0, z: 0, microphone: try mic(monX: 1.0, earX: 1.15, fs: fs))])
        XCTAssertNil(survey.microphone(at: .init(x: 1.15, y: 0.8, z: 0, confidence: 1, time: 0)))
    }

    func testSurveyRejectsEmptyAndMismatchedTones() throws {
        XCTAssertThrowsError(try QuietZoneHeadSurvey(points: []))
        let m = try mic(monX: 1.0, earX: 1.15, fs: 48_000)
        var other = m
        other.tones[0].frequencyHz = 200
        XCTAssertThrowsError(try QuietZoneHeadSurvey(points: [.init(x: 0, y: 0, z: 0, microphone: m),
                                                              .init(x: 1, y: 0, z: 0, microphone: other)]))
    }

    func testTrackerRejectsLowConfidenceSingleJumpsAndStaleness() {
        var t = QuietZoneHeadTracker()
        t.update(.init(x: 1, y: 0, z: 0, confidence: 0.2, time: 0))
        XCTAssertNil(t.smoothed)
        t.update(.init(x: 1, y: 0, z: 0, confidence: 0.9, time: 0))
        t.update(.init(x: 3, y: 0, z: 0, confidence: 0.9, time: 0.1))
        XCTAssertEqual(t.smoothed?.x, 1, "one mis-detection must not move the zone")
        t.update(.init(x: 3, y: 0, z: 0, confidence: 0.9, time: 0.2))
        t.update(.init(x: 3, y: 0, z: 0, confidence: 0.9, time: 0.3))
        XCTAssertEqual(t.smoothed?.x, 3, "three agreeing frames accept the jump")
        XCTAssertNotNil(t.pose(at: 0.9))
        XCTAssertNil(t.pose(at: 2.0), "stale pose reports nothing")
    }

    func testTrackerSmoothsSmallMoves() {
        var t = QuietZoneHeadTracker()
        t.update(.init(x: 0, y: 0, z: 0, confidence: 1, time: 0))
        t.update(.init(x: 0.1, y: 0, z: 0, confidence: 1, time: 0.1))
        let x = t.smoothed!.x
        XCTAssertGreaterThan(x, 0)
        XCTAssertLessThan(x, 0.1)
    }

    func testCameraPlacementMapsToRoomFrame() {
        // Camera at (2, 0, 1) looking along room +y (yaw 90 deg); a head 1 m ahead and 0.2 m to its right.
        let p = QuietZoneCameraPlacement(x: 2, y: 0, z: 1, yawRadians: .pi / 2)
        let pose = p.roomPosition(cameraX: 0.2, cameraY: 0.1, cameraZ: -1, confidence: 1, time: 0)
        XCTAssertEqual(pose.y, 1, accuracy: 1e-9)
        XCTAssertEqual(pose.x, 2.2, accuracy: 1e-9, "camera-right is room +x when looking along +y")
        XCTAssertEqual(pose.z, 1.1, accuracy: 1e-9)
    }
}
