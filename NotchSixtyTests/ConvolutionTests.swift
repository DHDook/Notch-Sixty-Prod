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
                    convolver, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 0, &generation
                )
            }
        )

        var left: Float = 0
        var right: Float = 0
        for frame in 0...Int(N60_CONVOLUTION_PARTITION_FRAMES) {
            let input: Float = frame == 0 ? 1 : 0
            XCTAssertTrue(N60PartitionedConvolverProcessSample(convolver, 0, generation, input, input, &left, &right))
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
                    convolver, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 1, &generation
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
                    convolver, 0, leftBuffer.baseAddress!, rightBuffer.baseAddress!, UInt32(leftBuffer.count), 0, &generation
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
                    convolver, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 2_047, &generation
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

    func testRenderKernelExecutesPreparedConvolutionAndReportsLatency() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var taps: [Float] = [0.25, 0.5, 0.25]
        var info = N60ConvolutionProgramInfo()
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareConvolutionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 1, &info
                )
            }
        )

        var graph = N60DSPGraphSnapshotMakeUnity(384_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, info, true))
        XCTAssertEqual(graph.latencyFrames, UInt32(N60_CONVOLUTION_PARTITION_FRAMES) + 1)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        var outputs: [Float] = []
        let end = Int(N60_CONVOLUTION_PARTITION_FRAMES) + 5
        for frame in 0..<end {
            let input: Float = frame == 0 ? 1 : 0
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            outputs.append(left)
        }
        let start = Int(N60_CONVOLUTION_PARTITION_FRAMES)
        XCTAssertEqual(outputs[start], 0.25, accuracy: 0.000_01)
        XCTAssertEqual(outputs[start + 1], 0.5, accuracy: 0.000_01)
        XCTAssertEqual(outputs[start + 2], 0.25, accuracy: 0.000_01)

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertTrue(diagnostics.convolutionEnabled)
        XCTAssertEqual(diagnostics.convolutionTapCount, 3)
        XCTAssertEqual(diagnostics.convolutionPartitionCount, 1)
        XCTAssertEqual(diagnostics.convolutionEngineLatencyFrames, UInt32(N60_CONVOLUTION_PARTITION_FRAMES))
        XCTAssertEqual(diagnostics.convolutionDeclaredLatencyFrames, 1)
        XCTAssertEqual(diagnostics.latencyFrames, UInt32(N60_CONVOLUTION_PARTITION_FRAMES) + 1)
        XCTAssertEqual(diagnostics.convolutionProgramMisses, 0)
        XCTAssertEqual(diagnostics.sanitizedNonFiniteSamples, 0)
    }

    func testRenderKernelRejectsUnpreparedConvolutionReference() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        var fake = N60ConvolutionProgramInfo()
        fake.prepared = true
        fake.generation = 999
        fake.tapCount = 1
        fake.partitionCount = 1
        fake.engineLatencyFrames = UInt32(N60_CONVOLUTION_PARTITION_FRAMES)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, fake, true))
        XCTAssertFalse(N60RenderKernelPublishSnapshot(kernel, graph))
    }

    func test384KHzEQCrossoverAnd4096TapConvolutionRemainFiniteTogether() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        let tapCount = 4_096
        var taps = (0..<tapCount).map { index -> Float in
            if index == 2_047 { return 0.8 }
            let distance = abs(index - 2_047)
            return distance < 16 ? Float((16 - distance)) * 0.0002 : 0
        }
        var info = N60ConvolutionProgramInfo()
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareConvolutionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 2_047, &info
                )
            }
        )

        var graph = N60DSPGraphSnapshotMakeUnity(384_000)
        for index in 0..<Int(N60_MAX_EQ_BANDS) {
            let position = Double(index) / Double(Int(N60_MAX_EQ_BANDS) - 1)
            let frequency = 30.0 * pow(18_000.0 / 30.0, position)
            XCTAssertTrue(
                N60DSPGraphSnapshotSetEQBand(
                    &graph,
                    UInt32(index),
                    N60BiquadFilterTypePeaking,
                    frequency,
                    index.isMultiple(of: 2) ? 0.25 : -0.25,
                    1.0,
                    true
                )
            )
        }
        XCTAssertTrue(
            N60DSPGraphSnapshotSetCrossover(
                &graph,
                80,
                N60CrossoverTopologyLinkwitzRiley48,
                N60CrossoverMonitorModeRecombined,
                1,
                false,
                true
            )
        )
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, info, true))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        for frame in 0..<32_768 {
            let input = Float(sin(2.0 * Double.pi * 1_000.0 * Double(frame) / 384_000.0) * 0.05)
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            XCTAssertTrue(left.isFinite)
            XCTAssertTrue(right.isFinite)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(diagnostics.sanitizedNonFiniteSamples, 0)
        XCTAssertEqual(diagnostics.snapshotReadMisses, 0)
        XCTAssertEqual(diagnostics.convolutionProgramMisses, 0)
        XCTAssertEqual(diagnostics.eqBandCount, UInt32(N60_MAX_EQ_BANDS))
        XCTAssertTrue(diagnostics.crossoverEnabled)
        XCTAssertTrue(diagnostics.convolutionEnabled)
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
                    buffer.baseAddress!, nil, 1, 0, nil
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
