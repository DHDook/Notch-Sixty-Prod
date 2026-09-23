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

    func testLinearPhaseRecommendedTapCountsScaleBySampleRate() {
        let expected: [(Double, UInt32)] = [
            (44_100, 1_883),
            (48_000, 2_049),
            (96_000, 4_097),
            (192_000, 8_193),
            (384_000, 16_385),
        ]
        for (rate, taps) in expected {
            XCTAssertEqual(N60LinearPhaseEQRecommendedTapCount(rate), taps, "Unexpected tap count at \(rate) Hz")
        }
    }

    func testLinearPhaseUnityDesignIsCenteredAndSymmetric() {
        let sampleRate = 48_000.0
        var taps = [Float](repeating: 0, count: Int(N60_LINEAR_PHASE_MAX_TAPS))
        var info = N60LinearPhaseEQDesignInfo()
        XCTAssertTrue(
            taps.withUnsafeMutableBufferPointer { buffer in
                N60LinearPhaseEQDesign(sampleRate, nil, 0, buffer.baseAddress!, UInt32(buffer.count), &info)
            }
        )

        XCTAssertEqual(info.tapCount, 2_049)
        XCTAssertEqual(info.groupDelayFrames, 1_024)
        XCTAssertEqual(info.totalLatencyFrames, 1_280)
        XCTAssertEqual(info.groupDelayMilliseconds, 21.333_333, accuracy: 0.001)

        let count = Int(info.tapCount)
        let center = Int(info.groupDelayFrames)
        XCTAssertEqual(taps[center], 1.0, accuracy: 0.000_01)
        for index in 0..<count {
            XCTAssertEqual(taps[index], taps[count - 1 - index], accuracy: 0.000_001)
            if index != center {
                XCTAssertEqual(taps[index], 0.0, accuracy: 0.000_01)
            }
        }
    }

    func testLinearPhasePeakingBandMatchesRequestedMagnitudeAndRemainsSymmetric() {
        let sampleRate = 96_000.0
        var band = N60LinearPhaseEQBand()
        band.enabled = true
        band.type = N60BiquadFilterTypePeaking
        band.frequencyHz = 1_000
        band.gainDB = 6
        band.q = 1.0
        var bands = [band]
        var taps = [Float](repeating: 0, count: Int(N60_LINEAR_PHASE_MAX_TAPS))
        var info = N60LinearPhaseEQDesignInfo()

        XCTAssertTrue(
            bands.withUnsafeBufferPointer { bandBuffer in
                taps.withUnsafeMutableBufferPointer { tapBuffer in
                    N60LinearPhaseEQDesign(
                        sampleRate,
                        bandBuffer.baseAddress!,
                        UInt32(bandBuffer.count),
                        tapBuffer.baseAddress!,
                        UInt32(tapBuffer.count),
                        &info
                    )
                }
            }
        )

        let count = Int(info.tapCount)
        for index in 0..<(count / 2) {
            XCTAssertEqual(taps[index], taps[count - 1 - index], accuracy: 0.000_01)
        }
        XCTAssertEqual(firMagnitudeDB(taps, count: count, sampleRate: sampleRate, frequency: 1_000), 6.0, accuracy: 0.35)
        XCTAssertEqual(firMagnitudeDB(taps, count: count, sampleRate: sampleRate, frequency: 10_000), 0.0, accuracy: 0.35)
    }

    func testLinearPhaseUnityDesignRunsThroughProductionConvolverAtDeclaredLatency() {
        let sampleRate = 48_000.0
        var taps = [Float](repeating: 0, count: Int(N60_LINEAR_PHASE_MAX_TAPS))
        var design = N60LinearPhaseEQDesignInfo()
        XCTAssertTrue(
            taps.withUnsafeMutableBufferPointer { buffer in
                N60LinearPhaseEQDesign(sampleRate, nil, 0, buffer.baseAddress!, UInt32(buffer.count), &design)
            }
        )

        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var generation: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    design.tapCount,
                    design.groupDelayFrames,
                    &generation
                )
            }
        )
        let program = N60PartitionedConvolverProgramInfo(convolver, 0)
        XCTAssertEqual(program.tapCount, design.tapCount)
        XCTAssertEqual(program.declaredLatencyFrames, design.groupDelayFrames)
        XCTAssertEqual(program.engineLatencyFrames + program.declaredLatencyFrames, design.totalLatencyFrames)

        var left: Float = 0
        var right: Float = 0
        let expectedLatency = Int(design.totalLatencyFrames)
        for frame in 0...expectedLatency {
            let input: Float = frame == 0 ? 1 : 0
            XCTAssertTrue(N60PartitionedConvolverProcessSample(convolver, 0, generation, input, input, &left, &right))
            if frame < expectedLatency {
                XCTAssertEqual(left, 0, accuracy: 0.000_01)
                XCTAssertEqual(right, 0, accuracy: 0.000_01)
            } else {
                XCTAssertEqual(left, 1, accuracy: 0.000_01)
                XCTAssertEqual(right, 1, accuracy: 0.000_01)
            }
        }
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

    private func firMagnitudeDB(_ taps: [Float], count: Int, sampleRate: Double, frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<count {
            let phase = -2.0 * Double.pi * frequency * Double(index) / sampleRate
            let tap = Double(taps[index])
            real += tap * cos(phase)
            imaginary += tap * sin(phase)
        }
        let magnitude = max(hypot(real, imaginary), 1.0e-12)
        return 20.0 * log10(magnitude)
    }
}

extension ConvolutionTests {
    func testRoomCorrectionUsesIndependentProgramNamespaceAndAddsLatency() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var linearTaps: [Float] = [1.0]
        var roomTaps: [Float] = [0.25, 0.5, 0.25]
        var linearInfo = N60ConvolutionProgramInfo()
        var roomInfo = N60ConvolutionProgramInfo()

        XCTAssertTrue(
            linearTaps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareConvolutionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 0, &linearInfo
                )
            }
        )
        XCTAssertTrue(
            roomTaps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareRoomCorrectionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 1, &roomInfo
                )
            }
        )

        XCTAssertNotEqual(linearInfo.generation, 0)
        XCTAssertNotEqual(roomInfo.generation, 0)

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, linearInfo, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 0, roomInfo, true))
        XCTAssertEqual(
            graph.latencyFrames,
            UInt32(N60_CONVOLUTION_PARTITION_FRAMES * 2) + 1
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        var output: [Float] = []
        let start = Int(N60_CONVOLUTION_PARTITION_FRAMES * 2)
        for frame in 0..<(start + 5) {
            let input: Float = frame == 0 ? 1 : 0
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            output.append(left)
        }

        XCTAssertEqual(output[start], 0.25, accuracy: 0.000_01)
        XCTAssertEqual(output[start + 1], 0.5, accuracy: 0.000_01)
        XCTAssertEqual(output[start + 2], 0.25, accuracy: 0.000_01)

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertTrue(diagnostics.convolutionEnabled)
        XCTAssertTrue(diagnostics.roomCorrectionEnabled)
        XCTAssertEqual(diagnostics.convolutionProgramSlot, 0)
        XCTAssertEqual(diagnostics.roomCorrectionProgramSlot, 0)
        XCTAssertEqual(diagnostics.roomCorrectionTapCount, 3)
        XCTAssertEqual(diagnostics.roomCorrectionPartitionCount, 1)
        XCTAssertEqual(diagnostics.roomCorrectionDeclaredLatencyFrames, 1)
        XCTAssertEqual(diagnostics.convolutionProgramMisses, 0)
        XCTAssertEqual(diagnostics.roomCorrectionProgramMisses, 0)
    }

    func testRoomCorrectionRejectsProgramPreparedOnlyForLinearEQConvolver() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var taps: [Float] = [1.0]
        var linearInfo = N60ConvolutionProgramInfo()
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareConvolutionProgram(
                    kernel, 1, buffer.baseAddress!, nil, UInt32(buffer.count), 0, &linearInfo
                )
            }
        )

        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 1, linearInfo, true))
        XCTAssertFalse(N60RenderKernelPublishSnapshot(kernel, graph))
    }

    func testRoomCorrectionBypassDoesNotAddLatencyOrAlterUnityPath() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(192_000)
        XCTAssertEqual(graph.latencyFrames, 0)
        XCTAssertFalse(graph.roomCorrection.enabled)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.125, -0.25, &left, &right)
        XCTAssertEqual(left, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.25, accuracy: 0.000_001)

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertFalse(diagnostics.roomCorrectionEnabled)
        XCTAssertEqual(diagnostics.roomCorrectionProgramMisses, 0)
        XCTAssertEqual(diagnostics.latencyFrames, 0)
    }

    func test384KHzLinearEQAndRoomCorrectionConvolutionRemainFiniteTogether() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        let tapCount = 4_096
        var linearTaps = [Float](repeating: 0, count: tapCount)
        var roomTaps = [Float](repeating: 0, count: tapCount)
        linearTaps[2_047] = 1.0
        roomTaps[2_047] = 0.95
        roomTaps[2_046] = 0.025
        roomTaps[2_048] = 0.025

        var linearInfo = N60ConvolutionProgramInfo()
        var roomInfo = N60ConvolutionProgramInfo()
        XCTAssertTrue(
            linearTaps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareConvolutionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 2_047, &linearInfo
                )
            }
        )
        XCTAssertTrue(
            roomTaps.withUnsafeBufferPointer { buffer in
                N60RenderKernelPrepareRoomCorrectionProgram(
                    kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 2_047, &roomInfo
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
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, linearInfo, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 0, roomInfo, true))
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
        XCTAssertEqual(diagnostics.roomCorrectionProgramMisses, 0)
        XCTAssertTrue(diagnostics.convolutionEnabled)
        XCTAssertTrue(diagnostics.roomCorrectionEnabled)
        XCTAssertTrue(diagnostics.crossoverEnabled)
        XCTAssertEqual(diagnostics.eqBandCount, UInt32(N60_MAX_EQ_BANDS))
    }
}
