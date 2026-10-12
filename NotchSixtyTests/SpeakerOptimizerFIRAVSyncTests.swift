import XCTest
@testable import NotchSixty

final class SpeakerOptimizerFIRAVSyncTests: XCTestCase {
    func testAudioOnlyAllowsDefaultFIRAndReportsExactLatency() throws {
        let plan = try makePlan()
        let decision = try SpeakerOptimizerFIRAVSyncPolicy().assess(
            plan: plan,
            context: .audioOnly
        )

        XCTAssertTrue(decision.canUseFIRForContext)
        XCTAssertFalse(decision.requiresExternalVideoDelay)
        XCTAssertEqual(decision.status, .audioOnlyAllowed)
        XCTAssertEqual(decision.programPathLatencyFrames, 1_280)
        XCTAssertEqual(decision.incrementalFIRLatencyFrames, 1_280)
        XCTAssertEqual(
            decision.requiredVideoDelayMilliseconds,
            26.666_666_666_7,
            accuracy: 1.0e-7
        )
    }

    func testSynchronizedVideoWithoutExternalDelayFailsClosed() throws {
        let decision = try SpeakerOptimizerFIRAVSyncPolicy().assess(
            plan: makePlan(),
            context: .synchronizedVideo(
                externalVideoDelayCapacityMilliseconds: nil
            )
        )
        XCTAssertFalse(decision.canUseFIRForContext)
        XCTAssertTrue(decision.requiresExternalVideoDelay)
        XCTAssertEqual(
            decision.status,
            .externalVideoDelayRequired
        )
    }

    func testSynchronizedVideoRequiresEnoughExternalDelayRange() throws {
        let policy = SpeakerOptimizerFIRAVSyncPolicy()
        let plan = try makePlan()

        let insufficient = try policy.assess(
            plan: plan,
            context: .synchronizedVideo(
                externalVideoDelayCapacityMilliseconds: 25
            )
        )
        XCTAssertFalse(insufficient.canUseFIRForContext)
        XCTAssertEqual(
            insufficient.status,
            .externalVideoDelayInsufficient
        )

        let supported = try policy.assess(
            plan: plan,
            context: .synchronizedVideo(
                externalVideoDelayCapacityMilliseconds: 30
            )
        )
        XCTAssertTrue(supported.canUseFIRForContext)
        XCTAssertEqual(
            supported.status,
            .externalVideoDelayAvailable
        )
        XCTAssertEqual(
            supported.requiredVideoDelayMilliseconds,
            26.666_666_666_7,
            accuracy: 1.0e-7
        )
    }

    func testProgramPathLatencyIncludesIntentionalCalibrationDelay() throws {
        let plan = try makePlan(
            rightDelayMilliseconds: 1.0,
            correctedRoles: [.frontLeft]
        )
        let decision = try SpeakerOptimizerFIRAVSyncPolicy().assess(
            plan: plan,
            context: .audioOnly
        )

        XCTAssertEqual(
            plan.maximumEndToEndProgramLatencyFrames,
            1_328
        )
        XCTAssertEqual(
            decision.requiredVideoDelayMilliseconds,
            Double(1_328) / 48_000 * 1_000,
            accuracy: 1.0e-9
        )
        XCTAssertEqual(
            decision.incrementalFIRLatencyMilliseconds,
            Double(1_280) / 48_000 * 1_000,
            accuracy: 1.0e-9
        )
    }

    func testInvalidExternalCapacityFailsClosed() throws {
        XCTAssertThrowsError(
            try SpeakerOptimizerFIRAVSyncPolicy().assess(
                plan: makePlan(),
                context: .synchronizedVideo(
                    externalVideoDelayCapacityMilliseconds:
                        .nan
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRAVSyncError,
                .invalidExternalVideoDelayCapacity
            )
        }
    }

    private func makePlan(
        rightDelayMilliseconds: Double = 0,
        correctedRoles: [OutputProgramRole] = [
            .frontLeft, .frontRight
        ]
    ) throws -> SpeakerOptimizerFIRLatencyPlan {
        let profile = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "av-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "av-output",
                        channelIndex: 1
                    ),
                    calibration: SemanticSpeakerCalibration(
                        delayMilliseconds:
                            rightDelayMilliseconds
                    )
                ),
            ]
        )
        return try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: profile,
            bassManagementEnabled: false,
            sampleRate: 48_000,
            tapCount: 2_049,
            declaredGroupDelayFrames: 1_024,
            correctedRoles: correctedRoles
        )
    }
}
