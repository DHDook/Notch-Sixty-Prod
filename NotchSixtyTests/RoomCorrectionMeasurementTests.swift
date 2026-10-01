import Foundation
import XCTest
@testable import NotchSixty

final class RoomCorrectionMeasurementTests: XCTestCase {
    func testCBridgeMatchesPairedStereoTimelineAcrossArbitraryQuanta() throws {
        let sweep: [Float] = [0.25, -0.5, 0.75]
        let bridge = sweep.withUnsafeBufferPointer { buffer in
            N60RoomMeasurementBridgeCreate(
                buffer.baseAddress!,
                UInt32(buffer.count),
                2,
                1,
                2,
                0
            )
        }
        guard let bridge else {
            XCTFail("Could not allocate room measurement bridge")
            return
        }
        defer { N60RoomMeasurementBridgeDestroy(bridge) }

        // capture = 2 lead + 3 sweep + 1 tail = 6 frames/pass.
        // total = 6 left + 2 settle + 6 right = 14 frames.
        var timelineLeft: [Float] = []
        var timelineRight: [Float] = []
        for quantum in [4, 5, 7] {
            let snapshot = N60RoomMeasurementBridgeGetSnapshot(bridge)
            let start = Int(snapshot.frameCursor)
            let microphone = (0..<quantum).map { Float(start + $0) }
            var left = [Float](repeating: -99, count: quantum)
            var right = [Float](repeating: -99, count: quantum)

            let consumed = microphone.withUnsafeBufferPointer { mic in
                left.withUnsafeMutableBufferPointer { leftBuffer in
                    right.withUnsafeMutableBufferPointer { rightBuffer in
                        N60RoomMeasurementBridgeProcessPlanar(
                            bridge,
                            mic.baseAddress!,
                            leftBuffer.baseAddress!,
                            rightBuffer.baseAddress!,
                            UInt32(quantum)
                        )
                    }
                }
            }
            let expectedRemaining = max(14 - start, 0)
            XCTAssertEqual(Int(consumed), min(quantum, expectedRemaining))
            timelineLeft.append(contentsOf: left.prefix(Int(consumed)))
            timelineRight.append(contentsOf: right.prefix(Int(consumed)))
        }

        let snapshot = N60RoomMeasurementBridgeGetSnapshot(bridge)
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.frameCursor, 14)
        XCTAssertEqual(snapshot.totalFrameCount, 14)
        XCTAssertEqual(snapshot.leftCapturedFrames, 6)
        XCTAssertEqual(snapshot.rightCapturedFrames, 6)
        XCTAssertEqual(snapshot.unsupportedBufferLayouts, 0)

        XCTAssertEqual(timelineLeft, [0, 0, 0.25, -0.5, 0.75, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(timelineRight, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.25, -0.5, 0.75, 0])
        for index in timelineLeft.indices {
            XCTAssertFalse(timelineLeft[index] != 0 && timelineRight[index] != 0)
        }

        var leftCapture = [Float](repeating: 0, count: 6)
        var rightCapture = [Float](repeating: 0, count: 6)
        let leftCopied = leftCapture.withUnsafeMutableBufferPointer { buffer in
            N60RoomMeasurementBridgeCopyLeftCapture(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        let rightCopied = rightCapture.withUnsafeMutableBufferPointer { buffer in
            N60RoomMeasurementBridgeCopyRightCapture(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        XCTAssertEqual(leftCopied, 6)
        XCTAssertEqual(rightCopied, 6)
        XCTAssertEqual(leftCapture, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(rightCapture, [8, 9, 10, 11, 12, 13])
    }

    func testCBridgeZeroFillsAfterCompletionAndResetsWithoutAllocation() throws {
        let sweep: [Float] = [1]
        let bridge = sweep.withUnsafeBufferPointer { buffer in
            N60RoomMeasurementBridgeCreate(buffer.baseAddress!, 1, 0, 0, 0, 0)
        }
        guard let bridge else {
            XCTFail("Could not allocate room measurement bridge")
            return
        }
        defer { N60RoomMeasurementBridgeDestroy(bridge) }

        let microphone: [Float] = [10, 20, 30, 40]
        var left = [Float](repeating: -1, count: 4)
        var right = [Float](repeating: -1, count: 4)
        let consumed = microphone.withUnsafeBufferPointer { mic in
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    N60RoomMeasurementBridgeProcessPlanar(
                        bridge,
                        mic.baseAddress!,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        4
                    )
                }
            }
        }
        XCTAssertEqual(consumed, 2)
        XCTAssertEqual(left, [1, 0, 0, 0])
        XCTAssertEqual(right, [0, 1, 0, 0])
        XCTAssertTrue(N60RoomMeasurementBridgeGetSnapshot(bridge).complete)

        var postLeft = [Float](repeating: 5, count: 3)
        var postRight = [Float](repeating: 5, count: 3)
        let postConsumed = microphone.withUnsafeBufferPointer { mic in
            postLeft.withUnsafeMutableBufferPointer { leftBuffer in
                postRight.withUnsafeMutableBufferPointer { rightBuffer in
                    N60RoomMeasurementBridgeProcessPlanar(
                        bridge,
                        mic.baseAddress!,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        3
                    )
                }
            }
        }
        XCTAssertEqual(postConsumed, 0)
        XCTAssertEqual(postLeft, [0, 0, 0])
        XCTAssertEqual(postRight, [0, 0, 0])

        N60RoomMeasurementBridgeReset(bridge)
        let reset = N60RoomMeasurementBridgeGetSnapshot(bridge)
        XCTAssertEqual(reset.frameCursor, 0)
        XCTAssertEqual(reset.leftCapturedFrames, 0)
        XCTAssertEqual(reset.rightCapturedFrames, 0)
        XCTAssertFalse(reset.complete)
    }

    func testCBridgeRejectsTimelineFrameOverflowBeforeAllocating() {
        let sample: [Float] = [1]
        let bridge = sample.withUnsafeBufferPointer { buffer in
            N60RoomMeasurementBridgeCreate(
                buffer.baseAddress!,
                1,
                UInt32.max,
                0,
                0,
                0
            )
        }
        XCTAssertNil(bridge)
    }
}
