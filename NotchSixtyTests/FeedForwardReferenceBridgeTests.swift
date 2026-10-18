import CoreAudio
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

    // MARK: E4 S9b1 pair mode

    func testPairRejectsTheSameChannelTwice() {
        XCTAssertNil(N60FeedForwardReferenceBridgeCreatePair(256, 1, 1))
    }

    func testPairPlanarKeepsBothChannelsAligned() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 0, 1))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        XCTAssertTrue(N60FeedForwardReferenceBridgeIsPair(bridge))
        let reference: [Float] = [0.1, 0.2, 0.3]
        let error: [Float] = [-0.1, -0.2, -0.3]
        XCTAssertEqual(N60FeedForwardReferenceBridgeProcessPairPlanar(bridge, reference, error, 3, 99, 7), 3)
        // A one-channel write cannot desynchronise the rings.
        XCTAssertEqual(N60FeedForwardReferenceBridgeProcessPlanar(bridge, reference, 3, 99, 10), 0)
        let (frames, errors) = readPair(bridge, 8)
        XCTAssertEqual(frames.map(\.sample), reference)
        XCTAssertEqual(errors, error)
        XCTAssertEqual(frames.map(\.frameOffset), [0, 1, 2])
    }

    func testPairRejectsANonFiniteErrorSample() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 0, 1))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        XCTAssertEqual(
            N60FeedForwardReferenceBridgeProcessPairPlanar(bridge, [0.1, 0.2], [0.1, .infinity], 2, 99, 0), 0
        )
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(bridge).droppedFrames, 2)
    }

    func testOneChannelBridgeHasNoPairRead() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreate(256, 0))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        XCTAssertFalse(N60FeedForwardReferenceBridgeIsPair(bridge))
        XCTAssertEqual(N60FeedForwardReferenceBridgeProcessPairPlanar(bridge, [0.1], [0.2], 1, 99, 0), 0)
        XCTAssertEqual(readPair(bridge, 4).0.count, 0)
    }

    /// Interleaved stereo in one buffer: channel 1 is the error, channel 0 the reference.
    func testIOProcReadsBothChannelsFromOneInterleavedBuffer() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 0, 1))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        let interleaved: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        callIOProc(bridge, buffers: [(channels: 2, samples: interleaved)])
        let (frames, errors) = readPair(bridge, 8)
        XCTAssertEqual(frames.map(\.sample), [0.1, 0.2, 0.3])
        XCTAssertEqual(errors, [-0.1, -0.2, -0.3])
    }

    /// Two mono buffers, reference in the second: channels are counted across buffers.
    func testIOProcFindsChannelsAcrossSplitBuffers() throws {
        let bridge = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 1, 0))
        defer { N60FeedForwardReferenceBridgeDestroy(bridge) }
        callIOProc(bridge, buffers: [(channels: 1, samples: [0.5, 0.6]), (channels: 1, samples: [0.7, 0.8])])
        let (frames, errors) = readPair(bridge, 8)
        XCTAssertEqual(frames.map(\.sample), [0.7, 0.8])
        XCTAssertEqual(errors, [0.5, 0.6])
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(bridge).unsupportedBufferLayouts, 0)
    }

    func testIOProcRejectsAMissingChannelOrMismatchedLengths() throws {
        let missing = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 0, 2))
        defer { N60FeedForwardReferenceBridgeDestroy(missing) }
        callIOProc(missing, buffers: [(channels: 2, samples: [0.1, 0.2])])
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(missing).unsupportedBufferLayouts, 1)
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(missing).availableFrames, 0)

        let mismatched = try XCTUnwrap(N60FeedForwardReferenceBridgeCreatePair(256, 0, 1))
        defer { N60FeedForwardReferenceBridgeDestroy(mismatched) }
        callIOProc(mismatched, buffers: [(channels: 1, samples: [0.1, 0.2]), (channels: 1, samples: [0.3])])
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(mismatched).unsupportedBufferLayouts, 1)
        XCTAssertEqual(N60FeedForwardReferenceBridgeGetSnapshot(mismatched).availableFrames, 0)
    }

    private func readPair(
        _ bridge: OpaquePointer, _ capacity: Int
    ) -> ([N60FeedForwardReferenceFrame], [Float]) {
        var frames = [N60FeedForwardReferenceFrame](repeating: N60FeedForwardReferenceFrame(), count: capacity)
        var errors = [Float](repeating: 0, count: capacity)
        let count = Int(N60FeedForwardReferenceBridgeReadPair(bridge, &frames, &errors, UInt32(capacity)))
        return (Array(frames.prefix(count)), Array(errors.prefix(count)))
    }

    private func callIOProc(_ bridge: OpaquePointer, buffers: [(channels: UInt32, samples: [Float])]) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        let storage = buffers.map { buffer -> UnsafeMutableBufferPointer<Float> in
            let memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: buffer.samples.count)
            _ = memory.initialize(from: buffer.samples)
            return memory
        }
        defer { storage.forEach { $0.deallocate() } }
        for index in buffers.indices {
            list[index] = AudioBuffer(
                mNumberChannels: buffers[index].channels,
                mDataByteSize: UInt32(storage[index].count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index].baseAddress)
            )
        }
        var time = AudioTimeStamp()
        time.mHostTime = 1_000
        time.mSampleTime = 64
        time.mFlags = [.hostTimeValid, .sampleTimeValid]
        var output = AudioBufferList()
        _ = N60FeedForwardReferenceIOProc(
            0, &time, list.unsafePointer, &time, &output, &time, UnsafeMutableRawPointer(bridge)
        )
    }
}
