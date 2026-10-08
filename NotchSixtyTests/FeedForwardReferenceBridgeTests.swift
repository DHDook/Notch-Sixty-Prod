import XCTest
@testable import NotchSixty

final class FeedForwardReferenceBridgeTests: XCTestCase {
    func testTimestampedRingPreservesSamplesAndInputClock() throws {
        let bridge = try XCTUnwrap(
            N60FeedForwardReferenceBridgeCreate(256, 0)
        )
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        let input: [Float] = [0.125, 0.25, -0.5, 0.75]
        let written = input.withUnsafeBufferPointer {
            N60FeedForwardReferenceBridgeProcessPlanar(
                bridge, $0.baseAddress!, UInt32($0.count),
                123_456, 2048
            )
        }
        XCTAssertEqual(written, UInt32(input.count))
        var result = [N60FeedForwardReferenceFrame](
            repeating: N60FeedForwardReferenceFrame(), count: 4
        )
        let read = result.withUnsafeMutableBufferPointer {
            N60FeedForwardReferenceBridgeRead(
                bridge, $0.baseAddress!, UInt32($0.count)
            )
        }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(result.map(\.sample), input)
        XCTAssertEqual(result.map(\.frameOffset), [0, 1, 2, 3])
        XCTAssertTrue(result.allSatisfy {
            $0.firstFrameHostTime == 123_456
                && $0.firstFrameSampleTime == 2048
        })
        XCTAssertEqual(
            N60FeedForwardReferenceBridgeGetSnapshot(bridge).availableFrames,
            0
        )
    }

    func testInvalidInputTimingFailsClosed() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreate(256, 0))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        let input = [Float](repeating: 0.2, count: 8)
        _ = input.withUnsafeBufferPointer {
            N60FeedForwardReferenceBridgeProcessPlanar(
                bridge, $0.baseAddress!, UInt32($0.count), 0, 0
            )
        }
        let snap = N60FeedForwardReferenceBridgeGetSnapshot(bridge)
        XCTAssertEqual(snap.availableFrames, 0)
        XCTAssertEqual(snap.invalidTimestamps, 1)
        XCTAssertEqual(snap.droppedFrames, 8)
    }

    func testFullRingDropsExcessWithoutOverwritingUnreadSamples() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreate(256, 0))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        let input = [Float](repeating: 0.3, count: 300)
        let accepted = input.withUnsafeBufferPointer {
            N60FeedForwardReferenceBridgeProcessPlanar(
                bridge, $0.baseAddress!, UInt32($0.count), 1000, 500
            )
        }
        XCTAssertEqual(accepted, 256)
        let snap = N60FeedForwardReferenceBridgeGetSnapshot(bridge)
        XCTAssertEqual(snap.availableFrames, 256)
        XCTAssertEqual(snap.droppedFrames, 44)

        var result = [N60FeedForwardReferenceFrame](
            repeating: N60FeedForwardReferenceFrame(), count: 256
        )
        _ = result.withUnsafeMutableBufferPointer {
            N60FeedForwardReferenceBridgeRead(
                bridge, $0.baseAddress!, UInt32($0.count)
            )
        }
        XCTAssertTrue(result.allSatisfy { $0.sample == 0.3 })
    }

    func testNonFiniteInputIsRejected() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreate(256, 0))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        let input: [Float] = [0.1, .nan]
        let accepted = input.withUnsafeBufferPointer {
            N60FeedForwardReferenceBridgeProcessPlanar(
                bridge, $0.baseAddress!, UInt32($0.count), 1234, 10
            )
        }
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(
            N60FeedForwardReferenceBridgeGetSnapshot(bridge).availableFrames,
            0
        )
    }
}
