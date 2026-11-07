import CoreGraphics
import Foundation
import XCTest
@testable import NotchSixty

final class EQGraphGeometryTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let size = CGSize(width: 800, height: 300)

    func testMaximumFrequencyFollowsTheRate() {
        XCTAssertEqual(EQGraphGeometry(sampleRate: 44_100).maximumFrequency, 44_100 * 0.49, accuracy: 1e-9)
        XCTAssertEqual(EQGraphGeometry(sampleRate: 96_000).maximumFrequency, 96_000 * 0.49, accuracy: 1e-9)
        XCTAssertEqual(EQGraphGeometry(sampleRate: 192_000).maximumFrequency, 94_080, accuracy: 1e-9)
        // E27 S2: the axis reaches 0.49 fs at every rate (it was capped at 96 kHz in S1).
        XCTAssertEqual(EQGraphGeometry(sampleRate: 384_000).maximumFrequency, 188_160, accuracy: 1e-9)
        XCTAssertEqual(EQGraphGeometry(sampleRate: 0).maximumFrequency, 48_000 * 0.49, accuracy: 1e-9)
    }

    func testDoubleClickMapsToFrequencyAndGainAtEveryRate() {
        for rate in rates {
            let geometry = EQGraphGeometry(sampleRate: rate)
            XCTAssertEqual(geometry.frequency(x: 0, width: size.width), 20, accuracy: 1e-9, "\(rate)")
            XCTAssertEqual(
                geometry.frequency(x: size.width, width: size.width), geometry.maximumFrequency,
                accuracy: 1e-6, "\(rate)"
            )
            // The middle of a log axis is the geometric mean.
            let middle = geometry.frequency(x: size.width / 2, width: size.width)
            XCTAssertEqual(middle, sqrt(20 * geometry.maximumFrequency), accuracy: 1e-6, "\(rate)")
            let position = geometry.position(at: CGPoint(x: size.width / 2, y: size.height / 4), size: size)
            XCTAssertEqual(position.frequencyHz, middle, accuracy: 1e-6)
            XCTAssertEqual(position.gainDB, 12, accuracy: 1e-9)
            // Round trip.
            for hertz in [20.0, 100, 1_000, 10_000, geometry.maximumFrequency] {
                let x = geometry.x(frequency: hertz, width: size.width)
                XCTAssertEqual(geometry.frequency(x: x, width: size.width), hertz, accuracy: hertz * 1e-9)
            }
        }
    }

    func testGainAxisAndClamping() {
        let geometry = EQGraphGeometry(sampleRate: 48_000)
        XCTAssertEqual(geometry.y(db: 24, height: 300), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: -24, height: 300), 300, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: 0, height: 300), 150, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: 99, height: 300), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.gain(y: -50, height: 300), 24, accuracy: 1e-9)
        XCTAssertEqual(geometry.gain(y: 999, height: 300), -24, accuracy: 1e-9)
        XCTAssertEqual(geometry.x(frequency: 5, width: 800), 0, accuracy: 1e-9)
    }

    func testHitTestPicksNearestWithinRadiusAndTopmostOnTie() {
        let a = UUID(), b = UUID(), c = UUID()
        let handles = [
            EQGraphGeometry.Handle(id: a, center: CGPoint(x: 100, y: 100)),
            EQGraphGeometry.Handle(id: b, center: CGPoint(x: 110, y: 100)),
            EQGraphGeometry.Handle(id: c, center: CGPoint(x: 400, y: 100)),
        ]
        XCTAssertEqual(EQGraphGeometry.hitHandle(at: CGPoint(x: 103, y: 100), handles: handles), a)
        XCTAssertEqual(EQGraphGeometry.hitHandle(at: CGPoint(x: 108, y: 100), handles: handles), b)
        XCTAssertEqual(EQGraphGeometry.hitHandle(at: CGPoint(x: 105, y: 100), handles: handles), b, "tie goes to the later handle")
        XCTAssertNil(EQGraphGeometry.hitHandle(at: CGPoint(x: 250, y: 100), handles: handles))
        XCTAssertEqual(EQGraphGeometry.hitHandle(at: CGPoint(x: 400 + 21, y: 100), handles: handles), c)
        XCTAssertNil(EQGraphGeometry.hitHandle(at: CGPoint(x: 400 + 22, y: 100), handles: handles))
        XCTAssertNil(EQGraphGeometry.hitHandle(at: .zero, handles: []))
    }

    func testDragFollowsPointerTravelWithoutJump() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 200, y: 100), start: CGPoint(x: 205, y: 96))
        let moved = session.update(location: CGPoint(x: 225, y: 126), shift: false, option: false, bounds: size)
        XCTAssertEqual(moved.x, 220, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 130, accuracy: 1e-9)
        XCTAssertNil(session.lockedAxis)
    }

    func testShiftLocksAfterFourPointsAndReleaseUnlocks() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 200, y: 100), start: CGPoint(x: 200, y: 100))
        // 3 pt does not lock.
        var point = session.update(location: CGPoint(x: 203, y: 100), shift: true, option: false, bounds: size)
        XCTAssertNil(session.lockedAxis)
        XCTAssertEqual(point.x, 203, accuracy: 1e-9)
        // 5 pt, mostly horizontal, locks horizontal: y stays put.
        point = session.update(location: CGPoint(x: 205, y: 102), shift: true, option: false, bounds: size)
        XCTAssertEqual(session.lockedAxis, .horizontal)
        XCTAssertEqual(point.x, 205, accuracy: 1e-9)
        XCTAssertEqual(point.y, 100, accuracy: 1e-9)
        point = session.update(location: CGPoint(x: 250, y: 160), shift: true, option: false, bounds: size)
        XCTAssertEqual(point.y, 100, accuracy: 1e-9)
        // Releasing Shift unlocks and the handle follows the pointer's full travel.
        point = session.update(location: CGPoint(x: 250, y: 160), shift: false, option: false, bounds: size)
        XCTAssertNil(session.lockedAxis)
        XCTAssertEqual(point.x, 250, accuracy: 1e-9)
        XCTAssertEqual(point.y, 160, accuracy: 1e-9)
    }

    func testShiftLocksVerticalWhenMovementIsMostlyVertical() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 200, y: 100), start: CGPoint(x: 200, y: 100))
        let point = session.update(location: CGPoint(x: 202, y: 120), shift: true, option: false, bounds: size)
        XCTAssertEqual(session.lockedAxis, .vertical)
        XCTAssertEqual(point.x, 200, accuracy: 1e-9)
        XCTAssertEqual(point.y, 120, accuracy: 1e-9)
    }

    func testOptionMovesAtOneTenth() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 200, y: 100), start: CGPoint(x: 200, y: 100))
        let point = session.update(location: CGPoint(x: 300, y: 150), shift: false, option: true, bounds: size)
        XCTAssertEqual(point.x, 210, accuracy: 1e-9)
        XCTAssertEqual(point.y, 105, accuracy: 1e-9)
    }

    func testPressingOptionMidDragDoesNotJump() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 200, y: 100), start: CGPoint(x: 200, y: 100))
        let before = session.update(location: CGPoint(x: 300, y: 100), shift: false, option: false, bounds: size)
        XCTAssertEqual(before.x, 300, accuracy: 1e-9)
        let after = session.update(location: CGPoint(x: 400, y: 100), shift: false, option: true, bounds: size)
        XCTAssertEqual(after.x, 310, accuracy: 1e-9, "only the new travel is scaled")
    }

    func testDragStopsAtTheGraphEdgeAndComesBackAtOnce() {
        var session = EQGraphGeometry.DragSession(origin: CGPoint(x: 780, y: 100), start: CGPoint(x: 780, y: 100))
        var point = session.update(location: CGPoint(x: 900, y: 100), shift: false, option: false, bounds: size)
        XCTAssertEqual(point.x, 800, accuracy: 1e-9)
        point = session.update(location: CGPoint(x: 890, y: 100), shift: false, option: false, bounds: size)
        XCTAssertEqual(point.x, 790, accuracy: 1e-9, "no dead zone after overshoot")
        point = session.update(location: CGPoint(x: 780, y: -500), shift: false, option: false, bounds: size)
        XCTAssertEqual(point.y, 0, accuracy: 1e-9)
    }

    func testReadoutText() {
        XCTAssertEqual(EQGraphReadout.cursorText(frequencyHz: 1_200, responseDB: 3.44), "1.20 kHz   +3.4 dB")
        XCTAssertEqual(EQGraphReadout.cursorText(frequencyHz: 63.4, responseDB: -0.04), "63.4 Hz   0.0 dB")
        let band = EQBand(type: .peaking, frequencyHz: 300, gainDB: -0.7, q: 1)
        XCTAssertEqual(
            EQGraphReadout.bandText(number: 3, band: band, hasGain: true, hasQ: true),
            "Band 3   Peak   300 Hz   -0.7 dB   Q 1.00"
        )
        XCTAssertEqual(
            EQGraphReadout.bandText(number: 1, band: band, hasGain: false, hasQ: false),
            "Band 1   Peak   300 Hz"
        )
    }
}
