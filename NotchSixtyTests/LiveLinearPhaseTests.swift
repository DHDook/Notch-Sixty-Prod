import Combine
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
        XCTAssertNoThrow(try filter.validateSampleRate(forOutputSampleRate: 384_000))
    }

    func testRoomCorrectionSampleRateValidationRejectsNonFiniteMetadata() {
        for invalidRate in [Double.nan, Double.infinity, -Double.infinity] {
            var filter = RoomCorrectionFilter.validation
            filter.sampleRate = invalidRate

            XCTAssertThrowsError(try filter.validateSampleRate(forOutputSampleRate: 96_000)) { error in
                guard case RoomCorrectionConfigurationError.sampleRateMismatch = error else {
                    return XCTFail("Expected sampleRateMismatch, got \(error)")
                }
            }
        }
    }

    func testRoomCorrectionSampleRateValidationRejectsMismatchAndAcceptsMatchingRate() {
        var filter = RoomCorrectionFilter.validation
        filter.sampleRate = 96_000
        XCTAssertNoThrow(try filter.validateSampleRate(forOutputSampleRate: 96_000))
        XCTAssertNoThrow(try filter.validateSampleRate(forOutputSampleRate: 96_000.49))

        XCTAssertThrowsError(try filter.validateSampleRate(forOutputSampleRate: 48_000)) { error in
            guard case RoomCorrectionConfigurationError.sampleRateMismatch = error else {
                return XCTFail("Expected sampleRateMismatch, got \(error)")
            }
        }
    }

    func testRoomCorrectionStartsBypassedWithoutLoadedFilter() {
        let configuration = RoomCorrectionConfiguration()
        XCTAssertFalse(configuration.enabled)
        XCTAssertNil(configuration.filter)
    }

    @MainActor
    func testProductConfigurationSnapshotsAllCurrentDSPDomains() throws {
        let engine = AudioIOEngine()
        let product = ProductController(audioEngine: engine)

        try engine.replaceEQConfiguration(
            EQConfiguration(
                phaseMode: .linearPhase,
                bypassed: true,
                bands: [EQBand(frequencyHz: 1_500, gainDB: 2.5, q: 1.2)]
            )
        )
        try engine.setInputPreampDB(-2.0)
        try engine.setHeadroomAttenuationDB(-4.0)
        try engine.setOutputGainDB(1.0)
        try engine.replaceBassManagementConfiguration(
            BassManagementConfiguration(
                enabled: true,
                frequencyHz: 90,
                topology: .linkwitzRiley48,
                monitorMode: .recombined,
                subGainDB: -1.5,
                subPolarityInverted: true
            )
        )
        try engine.replaceRoomCorrectionConfiguration(
            RoomCorrectionConfiguration(enabled: false, filter: .validation)
        )

        let snapshot = product.configuration
        XCTAssertEqual(snapshot.schemaVersion, ProductConfiguration.currentSchemaVersion)
        XCTAssertEqual(snapshot.selectedOutputUID, engine.routeConfiguration.selectedOutputUID)
        XCTAssertEqual(snapshot.dsp.eq, engine.eqConfiguration)
        XCTAssertEqual(snapshot.dsp.stereoEQ, engine.stereoEQConfiguration)
        XCTAssertEqual(snapshot.dsp.playback, engine.playbackControlConfiguration)
        XCTAssertEqual(snapshot.dsp.gain, engine.gainConfiguration)
        XCTAssertEqual(snapshot.dsp.bassManagement, engine.bassManagementConfiguration)
        XCTAssertEqual(snapshot.dsp.roomCorrection, engine.roomCorrectionConfiguration)
    }

    @MainActor
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
