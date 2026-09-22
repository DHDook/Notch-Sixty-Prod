import XCTest
@testable import NotchSixty

final class ConvolutionTests: XCTestCase {
    func testIdentityImpulseHasExactlyOnePartitionOfEngineLatency() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var taps: [Float] = [1.0]
        var generation: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    0,
                    &generation
                )
            }
        )

        var left: Float = 0
        var right: Float = 0
        for frame in 0...Int(N60_CONVOLUTION_PARTITION_FRAMES) {
            let input: Float = frame == 0 ? 1 : 0
            XCTAssertTrue(
                N60PartitionedConvolverProcessSample(
                    convolver,
                    0,
                    generation,
                    input,
                    input,
                    &left,
                    &right
                )
            )
            if frame < Int(N60_CONVOLUTION_PARTITION_FRAMES) {
                XCTAssertEqual(left, 0, accuracy: 0.000_01)
                XCTAssertEqual(right, 0, accuracy: 0.000_01)
            } else {
                XCTAssertEqual(left, 1, accuracy: 0.000_01)
                XCTAssertEqual(right, 1, accuracy: 0.000_01)
            }
        }

        let info = N60PartitionedConvolverProgramInfo(convolver, 0)
        XCTAssertTrue(info.prepared)
        XCTAssertEqual(info.tapCount, 1)
        XCTAssertEqual(info.partitionCount, 1)
        XCTAssertEqual(info.engineLatencyFrames, UInt32(N60_CONVOLUTION_PARTITION_FRAMES))
        XCTAssertEqual(info.declaredLatencyFrames, 0)
    }

    func testThreeTapImpulseResponseIsCorrectAfterEngineLatency() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var taps: [Float] = [0.25, 0.5, 0.25]
        var generation: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    1,
                    &generation
                )
            }
        )

        var outputs: [Float] = []
        var left: Float = 0
        var right: Float = 0
        let end = Int(N60_CONVOLUTION_PARTITION_FRAMES) + taps.count + 2
        for frame in 0..<end {
            let input: Float = frame == 0 ? 1 : 0
            XCTAssertTrue(N60PartitionedConvolverProcessSample(convolver, 0, generation, input, input, &left, &right))
            outputs.append(left)
            XCTAssertEqual(left, right, accuracy: 0.000_01)
        }

        let start = Int(N60_CONVOLUTION_PARTITION_FRAMES)
        XCTAssertEqual(outputs[start], 0.25, accuracy: 0.000_01)
        XCTAssertEqual(outputs[start + 1], 0.5, accuracy: 0.000_01)
        XCTAssertEqual(outputs[start + 2], 0.25, accuracy: 0.000_01)
        XCTAssertEqual(N60PartitionedConvolverProgramInfo(convolver, 0).declaredLatencyFrames, 1)
    }

    func testStereoProgramsCanUseDifferentImpulseResponses() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var leftTaps: [Float] = [1.0, 0.0]
        var rightTaps: [Float] = [0.0, 1.0]
        var generation: UInt64 = 0
        let prepared = leftTaps.withUnsafeBufferPointer { leftBuffer in
            rightTaps.withUnsafeBufferPointer { rightBuffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    leftBuffer.baseAddress!,
                    rightBuffer.baseAddress!,
                    UInt32(leftBuffer.count),
                    0,
                    &generation
                )
            }
        }
        XCTAssertTrue(prepared)

        var left: Float = 0
        var right: Float = 0
        let latency = Int(N60_CONVOLUTION_PARTITION_FRAMES)
        for frame in 0...(latency + 1) {
            let input: Float = frame == 0 ? 1 : 0
            XCTAssertTrue(N60PartitionedConvolverProcessSample(convolver, 0, generation, input, input, &left, &right))
            if frame == latency {
                XCTAssertEqual(left, 1, accuracy: 0.000_01)
                XCTAssertEqual(right, 0, accuracy: 0.000_01)
            }
            if frame == latency + 1 {
                XCTAssertEqual(left, 0, accuracy: 0.000_01)
                XCTAssertEqual(right, 1, accuracy: 0.000_01)
            }
        }
    }

    func testLongProgramRemainsFinite() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        let tapCount = 4_096
        var taps = (0..<tapCount).map { index -> Float in
            let envelope = exp(-Double(index) / 600.0)
            return Float(envelope * sin(Double(index) * 0.071) * 0.002)
        }
        taps[0] += 1.0
        var generation: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    2_047,
                    &generation
                )
            }
        )

        var left: Float = 0
        var right: Float = 0
        for frame in 0..<32_768 {
            let input = Float(sin(2.0 * Double.pi * 1_000.0 * Double(frame) / 384_000.0) * 0.1)
            XCTAssertTrue(N60PartitionedConvolverProcessSample(convolver, 0, generation, input, -input, &left, &right))
            XCTAssertTrue(left.isFinite)
            XCTAssertTrue(right.isFinite)
        }

        let info = N60PartitionedConvolverProgramInfo(convolver, 0)
        XCTAssertEqual(info.tapCount, UInt32(tapCount))
        XCTAssertEqual(info.partitionCount, 16)
        XCTAssertEqual(info.declaredLatencyFrames, 2_047)
    }

    func testProgramPreparationRejectsInvalidInput() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var bad: [Float] = [.nan]
        XCTAssertFalse(
            bad.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(convolver, 0, buffer.baseAddress!, nil, 1, 0, nil)
            }
        )

        var one: [Float] = [1]
        XCTAssertFalse(
            one.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    UInt32(N60_CONVOLUTION_PROGRAM_SLOTS),
                    buffer.baseAddress!,
                    nil,
                    1,
                    0,
                    nil
                )
            }
        )
        XCTAssertFalse(
            one.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(N60_CONVOLUTION_MAX_TAPS) + 1,
                    0,
                    nil
                )
            }
        )
    }
}
