import Foundation
import XCTest
@testable import NotchSixty

final class FeedForwardPreviewFIRTests: XCTestCase {
    private func configured(_ coefficients: [Float]) throws
        -> OpaquePointer {
        let engine = try XCTUnwrap(N60FeedForwardPreviewFIRCreate())
        let result = coefficients.withUnsafeBufferPointer { l in
            coefficients.withUnsafeBufferPointer { r in
                N60FeedForwardPreviewFIRConfigure(
                    engine, l.baseAddress!, r.baseAddress!, UInt32(l.count)
                )
            }
        }
        if !result { N60FeedForwardPreviewFIRDestroy(engine) }
        XCTAssertTrue(result)
        return engine
    }

    func testImpulseResponseIsCausalAndMatchesTaps() throws {
        let engine = try configured([0, 0.01, -0.02, 0.005])
        defer { N60FeedForwardPreviewFIRDestroy(engine) }
        let input: [Float] = [1, 0, 0, 0, 0, 0]
        var output: [Float] = []
        for value in input {
            var l: Float = 10, r: Float = 10
            N60FeedForwardPreviewFIRProcessFrame(engine, value, &l, &r)
            XCTAssertEqual(l, r, accuracy: 1.0e-7)
            output.append(l)
        }
        XCTAssertEqual(output.count, 6)
        for (i, expected) in [Float](arrayLiteral: 0, 0.01, -0.02, 0.005, 0, 0).enumerated() {
            XCTAssertEqual(output[i], expected, accuracy: 1.0e-7)
        }
        XCTAssertEqual(
            N60FeedForwardPreviewFIRGetSnapshot(engine).renderedFrames, 6
        )
    }

    func testRejectExcessiveGainAndNonfiniteFilterWithoutReplacingConfiguration() throws {
        let engine = try configured([0.01])
        defer { N60FeedForwardPreviewFIRDestroy(engine) }
        let excessive: [Float] = [0.2]
        let rejected = excessive.withUnsafeBufferPointer { l in
            excessive.withUnsafeBufferPointer { r in
                N60FeedForwardPreviewFIRConfigure(engine, l.baseAddress!, r.baseAddress!, 1)
            }
        }
        XCTAssertFalse(rejected)
        let invalid: [Float] = [.nan]
        let bad = invalid.withUnsafeBufferPointer { l in
            invalid.withUnsafeBufferPointer { r in
                N60FeedForwardPreviewFIRConfigure(engine, l.baseAddress!, r.baseAddress!, 1)
            }
        }
        XCTAssertFalse(bad)
        var l: Float = 0, r: Float = 0
        N60FeedForwardPreviewFIRProcessFrame(engine, 1, &l, &r)
        XCTAssertEqual(l, 0.01, accuracy: 1.0e-6)
    }

    func testNonFiniteMicrophoneInputSilencesAndFlushesHistory() throws {
        let engine = try configured([0.01, 0.01])
        defer { N60FeedForwardPreviewFIRDestroy(engine) }
        var l: Float = 0, r: Float = 0
        N60FeedForwardPreviewFIRProcessFrame(engine, 1, &l, &r)
        N60FeedForwardPreviewFIRProcessFrame(engine, .nan, &l, &r)
        XCTAssertEqual(l, 0)
        XCTAssertEqual(r, 0)
        N60FeedForwardPreviewFIRProcessFrame(engine, 0, &l, &r)
        XCTAssertEqual(l, 0)
        XCTAssertEqual(
            N60FeedForwardPreviewFIRGetSnapshot(engine).sanitizedInputs, 1
        )
    }

    func testDefaultUnconfiguredProcessorRemainsSilent() throws {
        let engine = try XCTUnwrap(N60FeedForwardPreviewFIRCreate())
        defer { N60FeedForwardPreviewFIRDestroy(engine) }
        var l: Float = 1, r: Float = 1
        N60FeedForwardPreviewFIRProcessFrame(engine, 0.5, &l, &r)
        XCTAssertEqual(l, 0)
        XCTAssertEqual(r, 0)
        XCTAssertFalse(N60FeedForwardPreviewFIRGetSnapshot(engine).configured)
    }
}
