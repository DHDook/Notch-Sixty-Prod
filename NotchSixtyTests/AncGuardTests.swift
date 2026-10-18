import Foundation
import XCTest
@testable import NotchSixty

/// E4 S4: the C++ howl guard as the app links it. The full scenario set runs
/// in ci/harness_e4_anc_guard.c; these cover the behaviour at every standard
/// rate through the bridging header.
final class AncGuardTests: XCTestCase {
    private let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    private func makeGuard(_ rate: Double) throws -> OpaquePointer {
        var config = N60AncGuardConfigDefault(rate)
        return try XCTUnwrap(N60AncGuardCreate(&config), "\(rate) Hz")
    }

    private func process(_ guardRef: OpaquePointer, _ samples: inout [Float]) {
        let chunk = 512
        samples.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let count = min(chunk, buffer.count - start)
                _ = N60AncGuardProcess(
                    guardRef, buffer.baseAddress! + start, nil, nil, UInt32(count)
                )
                start += count
            }
        }
    }

    private func tone(_ rate: Double, seconds: Double, db: (Double) -> Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return Float(pow(10, db(t) / 20) * sin(2 * .pi * 60 * t))
        }
    }

    func testGrowingLoopTripsWithinFiftyMillisecondsAndLatches() throws {
        for rate in rates {
            let guardRef = try makeGuard(rate)
            defer { N60AncGuardDestroy(guardRef) }
            let onset = 0.2037
            var samples = tone(rate, seconds: 0.6) { t in
                min(-50 + (t < onset ? 0 : 500 * (t - onset)), -10)
            }
            process(guardRef, &samples)
            let status = N60AncGuardReadStatus(guardRef)
            XCTAssertEqual(status.trip, N60AncGuardTripGrowth, "\(rate) Hz")
            let delay = Double(status.tripFrame) / rate - onset
            XCTAssertGreaterThan(delay, 0, "\(rate) Hz")
            XCTAssertLessThanOrEqual(delay, 0.050, "\(rate) Hz")
            XCTAssertTrue(status.muted, "\(rate) Hz")

            var later = tone(rate, seconds: 0.2) { _ in -30 }
            process(guardRef, &later)
            XCTAssertTrue(later.allSatisfy { $0 == 0 }, "\(rate) Hz: latch released")
            XCTAssertEqual(N60AncGuardReadStatus(guardRef).tripCount, 1, "\(rate) Hz")
        }
    }

    func testStableToneDoesNotTripAndRearmRestoresOutput() throws {
        for rate in rates {
            let guardRef = try makeGuard(rate)
            defer { N60AncGuardDestroy(guardRef) }
            let original = tone(rate, seconds: 2) { _ in -24 }
            var samples = original
            process(guardRef, &samples)
            XCTAssertEqual(N60AncGuardReadStatus(guardRef).trip, N60AncGuardTripNone, "\(rate) Hz")
            XCTAssertEqual(samples, original, "\(rate) Hz: healthy guard altered output")

            var bad: [Float] = [0.01, .nan, 0.01]
            process(guardRef, &bad)
            XCTAssertEqual(N60AncGuardReadStatus(guardRef).trip, N60AncGuardTripNonFinite)
            XCTAssertTrue(bad.allSatisfy(\.isFinite), "\(rate) Hz")

            N60AncGuardRequestRearm(guardRef)
            var resumed = original
            process(guardRef, &resumed)
            let status = N60AncGuardReadStatus(guardRef)
            XCTAssertEqual(status.trip, N60AncGuardTripNone, "\(rate) Hz")
            XCTAssertFalse(status.muted, "\(rate) Hz")
            XCTAssertEqual(resumed.last, original.last, "\(rate) Hz: not restored")
        }
    }

    func testInvalidConfigurationIsRejected() {
        var config = N60AncGuardConfigDefault(48_000)
        config.outputCeiling = 0
        XCTAssertNil(N60AncGuardCreate(&config))
        config = N60AncGuardConfigDefault(1_000_000)
        XCTAssertNil(N60AncGuardCreate(&config))
    }
}
