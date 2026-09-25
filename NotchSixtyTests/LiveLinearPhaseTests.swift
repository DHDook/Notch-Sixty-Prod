import Combine
import XCTest
@testable import NotchSixty

final class LiveLinearPhaseTests: XCTestCase {
    func testMinimumPhaseCompilesEnabledBandsIntoIIRGraph() throws {
        var configuration = EQConfiguration()
        configuration.bands[0].enabled = true
        configuration.bands[0].filterType = .peaking
        configuration.bands[0].frequencyHz = 1_000
        configuration.bands[0].gainDB = 3
        configuration.bands[0].q = 1

        let stereo = StereoEQConfiguration(linked: configuration, phaseMode: .minimumPhase)
        let graph = try stereo.makeGraphSnapshot(sampleRate: 96_000)

        XCTAssertEqual(graph.eqBandCount, 2)
        XCTAssertTrue(graph.eqBypassed == false)
        XCTAssertFalse(graph.convolution.enabled)
    }

    func testLinearPhaseLeavesIIRGraphEmptyForFIRAttachment() throws {
        var configuration = EQConfiguration()
        configuration.bands[0].enabled = true
        configuration.bands[0].filterType = .peaking
        configuration.bands[0].frequencyHz = 1_000
        configuration.bands[0].gainDB = 3
        configuration.bands[0].q = 1

        let stereo = StereoEQConfiguration(linked: configuration, phaseMode: .linearPhase)
        let graph = try stereo.makeGraphSnapshot(sampleRate: 96_000)

        XCTAssertEqual(graph.eqBandCount, 0)
        XCTAssertFalse(graph.eqBypassed)
        XCTAssertFalse(graph.convolution.enabled)
    }

    func testConvolutionUsesThreeProgramSlotsForTwoGraphGenerations() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to create convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        var taps: [Float] = [1]
        var generation0: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    &generation0
                )
            }
        )
        XCTAssertGreaterThan(generation0, 0)
        N60PartitionedConvolverRetainProgram(convolver, 0)
        N60PartitionedConvolverMarkCurrentProgram(convolver, 0)

        var generation1: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    1,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    &generation1
                )
            }
        )
        XCTAssertGreaterThan(generation1, generation0)
        N60PartitionedConvolverRetainProgram(convolver, 1)

        var generation2: UInt64 = 0
        XCTAssertTrue(
            taps.withUnsafeBufferPointer { buffer in
                N60PartitionedConvolverPrepareProgram(
                    convolver,
                    2,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    &generation2
                )
            }
        )
        XCTAssertGreaterThan(generation2, generation1)
    }

    func testRealtimeBridgeKeepsLinearAndRoomCorrectionProgramNamespacesIndependent() {
        guard let bridge = N60RealtimeAudioBridgeCreate(64) else {
            return XCTFail("Unable to create realtime bridge")
        }
        defer { N60RealtimeAudioBridgeDestroy(bridge) }

        var linearTaps: [Float] = [1]
        var roomTaps: [Float] = [0.25, 0.5, 0.25]
        var linearInfo = N60ConvolutionProgramInfo()
        var roomInfo = N60ConvolutionProgramInfo()
        XCTAssertTrue(
            linearTaps.withUnsafeBufferPointer { buffer in
                N60RealtimeAudioBridgePrepareConvolutionProgram(
                    bridge,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    0,
                    &linearInfo
                )
            }
        )
        XCTAssertTrue(
            roomTaps.withUnsafeBufferPointer { buffer in
                N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
                    bridge,
                    0,
                    buffer.baseAddress!,
                    nil,
                    UInt32(buffer.count),
                    0,
                    &roomInfo
                )
            }
        )
        XCTAssertGreaterThan(linearInfo.generation, 0)
        XCTAssertGreaterThan(roomInfo.generation, 0)
        XCTAssertEqual(linearInfo.slot, 0)
        XCTAssertEqual(roomInfo.slot, 0)
    }

    func testConvolverRefusesCurrentRealtimeSlotAndAcceptsSpareSlot() {
        guard let convolver = N60PartitionedConvolverCreate() else {
            return XCTFail("Unable to create convolver")
        }
        defer { N60PartitionedConvolverDestroy(convolver) }

        let taps: [Float] = [1]
        var generation: UInt64 = 0
        XCTAssertTrue(taps.withUnsafeBufferPointer {
            N60PartitionedConvolverPrepareProgram(convolver, 0, $0.baseAddress!, nil, UInt32($0.count), &generation)
        })
        N60PartitionedConvolverMarkCurrentProgram(convolver, 0)

        var rejectedGeneration: UInt64 = 0
        XCTAssertFalse(taps.withUnsafeBufferPointer {
            N60PartitionedConvolverPrepareProgram(convolver, 0, $0.baseAddress!, nil, UInt32($0.count), &rejectedGeneration)
        })

        var spareGeneration: UInt64 = 0
        XCTAssertTrue(taps.withUnsafeBufferPointer {
            N60PartitionedConvolverPrepareProgram(convolver, 1, $0.baseAddress!, nil, UInt32($0.count), &spareGeneration)
        })
    }

    func testAboveNyquistBandRemainsConfiguredButIsOmittedAtLowerRate() throws {
        var eq = EQConfiguration()
        eq.bands[0].enabled = true
        eq.bands[0].frequencyHz = 30_000
        eq.bands[0].gainDB = 6
        let stereo = StereoEQConfiguration(linked: eq)

        let lowRateGraph = try stereo.makeGraphSnapshot(sampleRate: 48_000)
        XCTAssertEqual(lowRateGraph.eqBandCount, 0)
        XCTAssertTrue(eq.bands[0].enabled)
        XCTAssertEqual(eq.bands[0].frequencyHz, 30_000)

        let highRateGraph = try stereo.makeGraphSnapshot(sampleRate: 96_000)
        XCTAssertEqual(highRateGraph.eqBandCount, 2)
    }

    func testRoomCorrectionStartsBypassedWithoutLoadedFilter() {
        let room = RoomCorrectionConfiguration()
        XCTAssertFalse(room.enabled)
        XCTAssertNil(room.filter)
    }

    func testRoomCorrectionValidationFilterIsFiniteAndRateIndependent() {
        let filter = RoomCorrectionFilter.validation
        XCTAssertFalse(filter.leftImpulseResponse.isEmpty)
        XCTAssertEqual(filter.leftImpulseResponse, filter.rightImpulseResponse)
        XCTAssertTrue(filter.leftImpulseResponse.allSatisfy(\.isFinite))
        XCTAssertNil(filter.designSampleRate)
    }

    func testRoomCorrectionSampleRateValidationRejectsMismatchAndAcceptsMatchingRate() throws {
        let filter = RoomCorrectionFilter(
            id: UUID(),
            name: "48k filter",
            leftImpulseResponse: [1],
            rightImpulseResponse: [1],
            declaredLatencyFrames: 0,
            designSampleRate: 48_000
        )
        let room = RoomCorrectionConfiguration(enabled: true, filter: filter)
        XCTAssertNoThrow(try room.validate(for: 48_000))
        XCTAssertThrowsError(try room.validate(for: 96_000))
    }

    func testRoomCorrectionSampleRateValidationRejectsNonFiniteMetadata() {
        let filter = RoomCorrectionFilter(
            id: UUID(),
            name: "Bad",
            leftImpulseResponse: [1],
            rightImpulseResponse: [1],
            declaredLatencyFrames: 0,
            designSampleRate: .nan
        )
        let room = RoomCorrectionConfiguration(enabled: true, filter: filter)
        XCTAssertThrowsError(try room.validate(for: 48_000))
    }

    func testProductConfigurationSnapshotsAllCurrentDSPDomains() {
        let engine = AudioIOEngine()
        let controller = ProductController(audioEngine: engine)
        let configuration = controller.configuration
        XCTAssertEqual(configuration.schemaVersion, ProductConfiguration.currentSchemaVersion)
        XCTAssertEqual(configuration.dsp.eq, engine.stereoEQConfiguration)
        XCTAssertEqual(configuration.dsp.gain, engine.gainConfiguration)
        XCTAssertEqual(configuration.dsp.bassManagement, engine.bassManagementConfiguration)
        XCTAssertEqual(configuration.dsp.roomCorrection, engine.roomCorrectionConfiguration)
        XCTAssertEqual(configuration.dsp.dynamics, engine.dynamicsConfiguration)
    }

    func testProductControllerForwardsAudioEngineChanges() throws {
        let engine = AudioIOEngine()
        let product = ProductController(audioEngine: engine)
        var notificationCount = 0
        let observation = product.objectWillChange.sink {
            notificationCount += 1
        }

        try engine.setOutputGainDB(-3.0)

        XCTAssertGreaterThan(notificationCount, 0)
        XCTAssertEqual(product.configuration.dsp.gain.outputGainDB, -3.0)
        XCTAssertEqual(product.configuration.dsp.dynamics, engine.dynamicsConfiguration)
        withExtendedLifetime(observation) {}
    }

    func testProductConfigurationSchemaIsVersionFiveForProtectionState() {
        XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 5)
        XCTAssertEqual(ProductConfiguration().schemaVersion, 5)
    }
}
