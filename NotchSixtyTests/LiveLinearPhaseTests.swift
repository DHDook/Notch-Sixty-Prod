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
}
