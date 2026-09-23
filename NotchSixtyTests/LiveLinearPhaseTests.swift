import XCTest
@testable import NotchSixty

final class LiveLinearPhaseTests: XCTestCase {
    func testMinimumPhaseCompilesEnabledBandsIntoIIRGraph() throws {
        let configuration = EQConfiguration(
            phaseMode: .minimumPhase,
            bands: [EQBand(frequencyHz: 1_000, gainDB: 6, q: 1.0)]
        )
        let graph = try configuration.makeGraphSnapshot(sampleRate: 96_000)
        XCTAssertEqual(graph.eqBandCount, 1)
        XCTAssertFalse(graph.convolution.enabled)
    }

    func testLinearPhaseLeavesIIRGraphEmptyForFIRAttachment() throws {
        let configuration = EQConfiguration(
            phaseMode: .linearPhase,
            bands: [EQBand(frequencyHz: 1_000, gainDB: 6, q: 1.0)]
        )
        let graph = try configuration.makeGraphSnapshot(sampleRate: 96_000)
        XCTAssertEqual(graph.eqBandCount, 0)
        XCTAssertFalse(graph.convolution.enabled)
        XCTAssertEqual(try configuration.linearPhaseBands(sampleRate: 96_000).count, 1)
    }

    func testAboveNyquistBandRemainsConfiguredButIsOmittedAtLowerRate() throws {
        let band = EQBand(frequencyHz: 30_000, gainDB: 3, q: 1.0)
        let minimum = EQConfiguration(phaseMode: .minimumPhase, bands: [band])
        let linear = EQConfiguration(phaseMode: .linearPhase, bands: [band])

        XCTAssertEqual(minimum.bands.count, 1)
        XCTAssertEqual(try minimum.makeGraphSnapshot(sampleRate: 48_000).eqBandCount, 0)
        XCTAssertEqual(linear.bands.count, 1)
        XCTAssertTrue(try linear.linearPhaseBands(sampleRate: 48_000).isEmpty)
    }

    func testConvolutionUsesThreeProgramSlotsForTwoGraphGenerations() {
        XCTAssertEqual(UInt32(N60_CONVOLUTION_PROGRAM_SLOTS), 3)
    }

    func testConvolverRefusesCurrentRealtimeSlotAndAcceptsSpareSlot() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to allocate convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var taps: [Float] = [1]
        var generation0: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver, 0, buffer.baseAddress!, nil, 1, 0, &generation0
                )
            }
        )

        var left: Float = 0
        var right: Float = 0
        XCTAssertTrue(
            N60PartitionedConvolverProcessSample(
                convolver, 0, generation0, 1, 1, &left, &right
            )
        )

        XCTAssertFalse(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver, 0, buffer.baseAddress!, nil, 1, 0, nil
                )
            }
        )

        var generation1: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver, 1, buffer.baseAddress!, nil, 1, 0, &generation1
                )
            }
        )
        XCTAssertNotEqual(generation0, generation1)

        var generation2: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver, 2, buffer.baseAddress!, nil, 1, 0, &generation2
                )
            }
        )
        XCTAssertNotEqual(generation1, generation2)
    }

    func testRealtimeBridgeKeepsLinearAndRoomCorrectionProgramNamespacesIndependent() {
        guard let bridge = N60RealtimeAudioBridgeCreate(1_024) else {
            return XCTFail("Unable to allocate realtime bridge")
        }
        defer { N60RealtimeAudioBridgeDestroy(bridge) }

        var linearTaps: [Float] = [1]
        var roomTaps: [Float] = [0.25, 0.5, 0.25]
        var linearInfo = N60ConvolutionProgramInfo()
        var roomInfo = N60ConvolutionProgramInfo()

        XCTAssertTrue(
            linearTaps.withUnsafeBufferPointer { buffer in
                N60RealtimeAudioBridgePrepareConvolutionProgram(
                    bridge, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 0, &linearInfo
                )
            }
        )
        XCTAssertTrue(
            roomTaps.withUnsafeBufferPointer { buffer in
                N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
                    bridge, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 1, &roomInfo
                )
            }
        )

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, linearInfo, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 0, roomInfo, true))
        XCTAssertEqual(graph.latencyFrames, UInt32(N60_CONVOLUTION_PARTITION_FRAMES * 2) + 1)
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, graph))

        let diagnostics = N60RealtimeAudioBridgeGetRenderDiagnostics(bridge)
        XCTAssertTrue(diagnostics.convolutionEnabled)
        XCTAssertTrue(diagnostics.roomCorrectionEnabled)
        XCTAssertEqual(diagnostics.convolutionProgramSlot, 0)
        XCTAssertEqual(diagnostics.roomCorrectionProgramSlot, 0)
        XCTAssertEqual(diagnostics.roomCorrectionTapCount, 3)
        XCTAssertEqual(diagnostics.roomCorrectionDeclaredLatencyFrames, 1)
    }

    func testRoomCorrectionValidationFilterIsFiniteAndRateIndependent() {
        let filter = RoomCorrectionFilter.validation
        XCTAssertNil(filter.sampleRate)
        XCTAssertEqual(filter.leftTaps, [0.25, 0.5, 0.25])
        XCTAssertNil(filter.rightTaps)
        XCTAssertEqual(filter.declaredLatencyFrames, 1)
        XCTAssertTrue(filter.leftTaps.allSatisfy { $0.isFinite })
    }

    func testRoomCorrectionStartsBypassedWithoutLoadedFilter() {
        let configuration = RoomCorrectionConfiguration()
        XCTAssertFalse(configuration.enabled)
        XCTAssertNil(configuration.filter)
    }
}
