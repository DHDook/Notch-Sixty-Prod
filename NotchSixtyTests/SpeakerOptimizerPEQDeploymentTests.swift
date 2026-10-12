import XCTest
@testable import NotchSixty

final class SpeakerOptimizerPEQDeploymentTests: XCTestCase {
    func testOptimizerPEQIsSeparateFromSpeakerCalibrationAndCompilesAfterIt() throws {
        var profile = makeProfile(
            calibrationBandCount: 1,
            optimizerBands: [
                .init(frequencyHz: 2_000, gainDB: -3, q: 1.2)
            ]
        )
        let originalCalibration = profile.speakerAssignments[0].calibration
        let optimizer = try XCTUnwrap(profile.speakerOptimizerPEQ)
        try optimizer.validate(profile: profile)

        XCTAssertEqual(profile.speakerAssignments[0].calibration, originalCalibration)
        XCTAssertEqual(
            optimizer.bandsByRole[.frontLeft]?.first?.gainDB,
            -3
        )

        let route = makeRoutePlan(profile: profile)
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: route,
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration:
                BassManagementConfiguration(enabled: false)
        )
        XCTAssertTrue(N60LiveNChannelRenderGraphIsValid(&unsafeMutable(graph)))
        XCTAssertEqual(
            laneEQCount(graph: graph, channel: 0),
            2,
            "One calibration band + one separately owned optimizer band should compile as a two-section realtime cascade."
        )
    }

    func testAggregateLaneCapacityFailsClosedBeforeRuntimeCompilation() throws {
        let profile = makeProfile(
            calibrationBandCount: Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS) - 1,
            optimizerBands: [
                .init(frequencyHz: 1_000, gainDB: -1, q: 1),
                .init(frequencyHz: 2_000, gainDB: -1, q: 1),
            ]
        )
        XCTAssertThrowsError(
            try XCTUnwrap(profile.speakerOptimizerPEQ).validate(
                profile: profile
            )
        ) {
            guard case .laneSectionCapacityExceeded(
                .frontLeft,
                let ordinary,
                let optimizer
            ) = $0 as? SpeakerOptimizerPEQDeploymentError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(
                ordinary,
                Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS) - 1
            )
            XCTAssertEqual(optimizer, 2)
        }
    }

    func testOptimizerDeploymentRejectsBoostAndLFE() throws {
        var profile = makeProfile(
            calibrationBandCount: 0,
            optimizerBands: [
                .init(frequencyHz: 2_000, gainDB: 1, q: 1)
            ]
        )
        XCTAssertThrowsError(
            try XCTUnwrap(profile.speakerOptimizerPEQ).validate(
                profile: profile
            )
        )

        profile.speakerOptimizerPEQ?.sources[0].role =
            .lowFrequencyEffects
        XCTAssertThrowsError(
            try XCTUnwrap(profile.speakerOptimizerPEQ).validate(
                profile: profile
            )
        )
    }

    func testOptimizerMetadataDoesNotChangeMeasurementRoutingSignature() throws {
        let without = makeProfile(
            calibrationBandCount: 1,
            optimizerBands: []
        )
        let with = makeProfile(
            calibrationBandCount: 1,
            optimizerBands: [
                .init(frequencyHz: 2_000, gainDB: -2, q: 1)
            ]
        )
        XCTAssertEqual(
            without.multichannelCalibrationRoutingSignature,
            with.multichannelCalibrationRoutingSignature
        )
    }

    private func makeProfile(
        calibrationBandCount: Int,
        optimizerBands: [SpeakerOptimizerDeployedPEQBand]
    ) -> OutputDeviceProfileConfiguration {
        let calibration = SemanticSpeakerCalibration(
            trimDB: -1,
            delayMilliseconds: 0.2,
            polarityInverted: false,
            eqBands: (0..<calibrationBandCount).map { index in
                OutputCalibrationEQBand(
                    frequencyHz: 200 + Double(index) * 100,
                    gainDB: -0.5,
                    q: 1
                )
            }
        )
        var profile = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "optimizer-output",
                        channelIndex: 0
                    ),
                    calibration: calibration
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "optimizer-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        if !optimizerBands.isEmpty {
            profile.speakerOptimizerPEQ =
                SpeakerOptimizerPEQDeploymentConfiguration(
                    proposalID: UUID(),
                    baselineMeasurementSetID: UUID(),
                    characterizationMeasurementSetID: UUID(),
                    routingSignature:
                        profile.multichannelCalibrationRoutingSignature,
                    sampleRate: 48_000,
                    aggregateCandidateFingerprint: "fixture",
                    approvedAt: Date(timeIntervalSince1970: 1_703_600_000),
                    sources: [
                        SpeakerOptimizerPEQSourceDeployment(
                            role: .frontLeft,
                            bands: optimizerBands
                        )
                    ]
                )
        }
        return profile
    }

    private func makeRoutePlan(
        profile: OutputDeviceProfileConfiguration
    ) -> LiveNChannelOutputRoutePlan {
        let calibrations = Dictionary(
            uniqueKeysWithValues:
                profile.speakerAssignments.compactMap { assignment in
                    assignment.calibration.map {
                        (assignment.role, $0)
                    }
                }
        )
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["optimizer-output"],
            referenceDeviceUID: "optimizer-output",
            physicalChannelCount: 2,
            programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [],
            subwooferCount: 0,
            bassManagementEnabled: false,
            speakerCalibrations: calibrations,
            subwooferCalibrations: [],
            speakerOptimizerPEQ:
                profile.speakerOptimizerPEQ?.bandsByRole ?? [:]
        )
    }

    private func laneEQCount(
        graph: N60LiveNChannelRenderGraph,
        channel: Int
    ) -> UInt32 {
        var mutable = graph.laneGraph
        return withUnsafePointer(to: &mutable.lanes) { pointer in
            pointer.withMemoryRebound(
                to: N60ProgramLaneSnapshot.self,
                capacity: Int(N60_MAX_PROGRAM_CHANNELS)
            ) {
                $0[channel].eqSectionCount
            }
        }
    }

    private func unsafeMutable<T>(_ value: T) -> T {
        value
    }
}
