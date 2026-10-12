import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabCapabilityTests: XCTestCase {
    func testWholeSpeakerOnAxisDelegatesToExistingProtectedPlanner() throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(distanceMeters: 1.0)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )
        XCTAssertTrue(plan.canStartMeasurement)
        XCTAssertTrue(plan.measurementOnly)
        XCTAssertFalse(plan.canDeploy)
        XCTAssertFalse(plan.canMutateDSP)
        XCTAssertEqual(
            plan.delegatedTransportPlans.first?.physicalOutputChannelIndex,
            0
        )
        XCTAssertTrue(
            plan.analysisProducts.contains(.earlyWindowMagnitude)
        )
    }

    func testOffAxisRequiresActualAngularOffset() throws {
        let invalid = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOffAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(distanceMeters: 1.0)
        )
        XCTAssertThrowsError(try invalid.validate()) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabError,
                .invalidGeometry
            )
        }

        let valid = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOffAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(
                distanceMeters: 1.0,
                horizontalAngleDegrees: 30
            )
        )
        XCTAssertNoThrow(try valid.validate())
    }

    func testSubwooferNearFieldRequiresSubwooferAndNearFieldDistance() throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .subwooferNearField,
            target: .acousticSource(.subwoofer(0)),
            geometry: .init(distanceMeters: 0.05)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )
        XCTAssertTrue(plan.canStartMeasurement)
        XCTAssertEqual(
            plan.delegatedTransportPlans.first?.physicalOutputChannelIndex,
            2
        )
        XCTAssertTrue(
            plan.analysisProducts.contains(
                .lowFrequencyNearFieldMagnitude
            )
        )

        var wrongSource = request
        wrongSource.target = .acousticSource(.speaker(.frontLeft))
        XCTAssertThrowsError(try wrongSource.validate())

        var tooFar = request
        tooFar.geometry.distanceMeters = 1.0
        XCTAssertThrowsError(try tooFar.validate())
    }

    func testProtectedDriverNearFieldCannotFallThroughToRawOutput() throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .protectedDriverNearField,
            target: .protectedDriverBus(.leftLow),
            geometry: .init(distanceMeters: 0.05)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil,
            bassManagementConfiguration: nil
        )
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertTrue(plan.delegatedTransportPlans.isEmpty)
        XCTAssertNil(plan.protectedDriverBus)
        XCTAssertEqual(
            plan.blockReasons,
            [.protectedDriverTransportRequired(.leftLow)]
        )
    }

    func testProtectedDriverNearFieldUnlocksOnlyDedicatedProtectedPath()
        throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .protectedDriverNearField,
            target: .protectedDriverBus(.leftHigh),
            geometry: .init(distanceMeters: 0.05)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: makeProtectedRouting(),
            speakerDriverProcessing:
                makeProtectedDriver(bus: .leftHigh),
            bassManagementConfiguration: makeBiAmpBass()
        )
        XCTAssertTrue(plan.canStartMeasurement)
        XCTAssertTrue(plan.delegatedTransportPlans.isEmpty)
        XCTAssertEqual(plan.protectedDriverBus, .leftHigh)
        XCTAssertTrue(
            plan.analysisProducts.contains(.magnitudeResponse)
        )
        XCTAssertFalse(plan.canDeploy)
        XCTAssertFalse(plan.canMutateDSP)

        var noLimiter = SpeakerDriverProcessingConfiguration()
        noLimiter.replace(
            SpeakerDriverBusProcessingConfiguration(
                bus: .leftHigh,
                limiterEnabled: false
            )
        )
        let blocked = try SpeakerMeasurementLabCapabilityPlanner()
            .plan(
                request,
                routePlan: makeRoutePlan(),
                multiOutputRouting: makeProtectedRouting(),
                speakerDriverProcessing: noLimiter,
                bassManagementConfiguration: makeBiAmpBass()
            )
        XCTAssertFalse(blocked.canStartMeasurement)
        XCTAssertNil(blocked.protectedDriverBus)
    }

    func testCoherentTimingRequiresAuthenticatedSharedClock() throws {
        let request = SpeakerMeasurementLabRequest(
            mode: .coherentMainsSubTiming,
            target: .sourcePair(
                main: .speaker(.frontLeft),
                subwoofer: .subwoofer(0)
            ),
            geometry: .init(distanceMeters: 3.0)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertFalse(plan.phaseReferenceAuthenticated)
        XCTAssertEqual(
            plan.blockReasons,
            [.authenticatedSharedClockRequired]
        )
        XCTAssertTrue(
            plan.analysisProducts.contains(.relativePhase)
        )
    }

    func testActiveSplitDriverRoutingStillBlocksWholeSpeakerRawTarget() throws {
        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Low",
                    bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr106-output",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Left High",
                    bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr106-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let request = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(distanceMeters: 1.0)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: routing,
            speakerDriverProcessing: nil
        )
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertEqual(
            plan.blockReasons,
            [.transport(.activeCrossoverRoutingPresent)]
        )
    }

    func testConfiguredDriverLimiterStillBlocksWholeSpeakerRawTarget() throws {
        let protection = SpeakerDriverProcessingConfiguration(
            buses: [
                SpeakerDriverBusProcessingConfiguration(
                    bus: .leftFullRange,
                    limiterEnabled: true,
                    limiterThresholdDBFS: -6
                ),
            ]
        )
        let request = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(distanceMeters: 1.0)
        )
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: protection
        )
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertEqual(
            plan.blockReasons,
            [.transport(.configuredLimiterWouldBeBypassed)]
        )
    }

    func testEveryLabModeRequiresAtLeastThreeRepeats() throws {
        var request = SpeakerMeasurementLabRequest(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            geometry: .init(distanceMeters: 1.0),
            repeatCount: 2
        )
        XCTAssertThrowsError(try request.validate()) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabError,
                .invalidRepeatCount(2)
            )
        }
        request.repeatCount = 3
        XCTAssertNoThrow(try request.validate())
    }

    private func makeProtectedRouting()
        -> MultiOutputRoutingConfiguration {
        MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Low",
                    bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr106-output",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Left High",
                    bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr106-output",
                        channelIndex: 1
                    )
                ),
            ],
            referenceDeviceUID: "pr106-output"
        )
    }

    private func makeBiAmpBass() -> BassManagementConfiguration {
        var result = BassManagementConfiguration()
        result.enabled = true
        result.frequencyHz = 1_000
        result.physicalOutputMode = .biAmp
        return result
    }

    private func makeProtectedDriver(
        bus: SpeakerOutputBus
    ) -> SpeakerDriverProcessingConfiguration {
        var result = SpeakerDriverProcessingConfiguration()
        result.replace(
            SpeakerDriverBusProcessingConfiguration(
                bus: bus,
                limiterEnabled: true,
                limiterThresholdDBFS: -30
            )
        )
        return result
    }

    private func makeRoutePlan() -> LiveNChannelOutputRoutePlan {
        var program = Array(
            repeating: UInt32.max,
            count: Int(N60_MAX_PROGRAM_CHANNELS)
        )
        program[0] = 0
        program[1] = 1
        var subs = Array(
            repeating: UInt32.max,
            count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
        )
        subs[0] = 2
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["pr106-output"],
            referenceDeviceUID: "pr106-output",
            physicalChannelCount: 3,
            programPhysicalChannels: program,
            subwooferPhysicalChannels: subs,
            subwooferCount: 1,
            bassManagementEnabled: true,
            speakerCalibrations: [:],
            subwooferCalibrations: Array(
                repeating: nil,
                count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
            )
        )
    }
}
