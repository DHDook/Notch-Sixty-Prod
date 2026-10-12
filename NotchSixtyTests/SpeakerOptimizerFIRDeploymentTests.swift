import XCTest
@testable import NotchSixty

final class SpeakerOptimizerFIRDeploymentTests: XCTestCase {
    func testDefault2049TapCandidateCountsEngineAndGroupDelayExactlyOnce() throws {
        let profile = makeStereoProfile(leftDelayMilliseconds: 0.2)
        let plan = try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: profile,
            bassManagementEnabled: false,
            sampleRate: 48_000,
            tapCount: 2_049,
            declaredGroupDelayFrames: 1_024,
            correctedRoles: [.frontLeft, .frontRight]
        )

        XCTAssertEqual(plan.convolutionEngineLatencyFrames, 256)
        XCTAssertEqual(plan.declaredGroupDelayFrames, 1_024)
        XCTAssertEqual(plan.addedFIRLatencyFrames, 1_280)
        XCTAssertEqual(plan.coherenceLatencyFrames, 1_280)
        XCTAssertEqual(
            plan.addedFIRLatencyMilliseconds,
            26.666_666_666_7,
            accuracy: 1.0e-7
        )
        XCTAssertTrue(plan.requiresAVSyncCoordination)
        XCTAssertFalse(plan.canInstallLiveFIR)

        let left = try XCTUnwrap(
            plan.rolePlans.first(where: { $0.role == .frontLeft })
        )
        let right = try XCTUnwrap(
            plan.rolePlans.first(where: { $0.role == .frontRight })
        )
        XCTAssertTrue(left.firApplied)
        XCTAssertTrue(right.firApplied)
        XCTAssertEqual(left.upstreamProcessingLatencyFrames, 1_280)
        XCTAssertEqual(right.upstreamProcessingLatencyFrames, 1_280)
        XCTAssertEqual(left.coherenceCompensationFrames, 0)
        XCTAssertEqual(right.coherenceCompensationFrames, 0)
        XCTAssertEqual(left.userCalibrationDelayFrames, 10)
        XCTAssertEqual(left.endToEndProgramLatencyFrames, 1_290)
        XCTAssertEqual(plan.maximumEndToEndProgramLatencyFrames, 1_290)
    }

    func testUncorrectedProgramLaneGetsExactCoherenceCompensation() throws {
        let profile = makeStereoProfile()
        let plan = try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: profile,
            bassManagementEnabled: false,
            sampleRate: 48_000,
            tapCount: 2_049,
            declaredGroupDelayFrames: 1_024,
            correctedRoles: [.frontLeft]
        )

        let left = try XCTUnwrap(
            plan.rolePlans.first(where: { $0.role == .frontLeft })
        )
        let right = try XCTUnwrap(
            plan.rolePlans.first(where: { $0.role == .frontRight })
        )

        XCTAssertEqual(left.upstreamProcessingLatencyFrames, 1_280)
        XCTAssertEqual(left.coherenceCompensationFrames, 0)
        XCTAssertEqual(left.effectiveLaneDelayFrames, 0)
        XCTAssertEqual(left.endToEndProgramLatencyFrames, 1_280)

        XCTAssertEqual(right.upstreamProcessingLatencyFrames, 0)
        XCTAssertEqual(right.coherenceCompensationFrames, 1_280)
        XCTAssertEqual(right.effectiveLaneDelayFrames, 1_280)
        XCTAssertEqual(right.endToEndProgramLatencyFrames, 1_280)
    }

    func testExistingCalibrationDelayRemainsIntentionalAfterCoherenceCompensation() throws {
        let profile = makeStereoProfile(rightDelayMilliseconds: 1.0)
        let plan = try SpeakerOptimizerFIRLatencyPlanner().plan(
            profile: profile,
            bassManagementEnabled: false,
            sampleRate: 48_000,
            tapCount: 2_049,
            declaredGroupDelayFrames: 1_024,
            correctedRoles: [.frontLeft]
        )
        let right = try XCTUnwrap(
            plan.rolePlans.first(where: { $0.role == .frontRight })
        )

        XCTAssertEqual(right.userCalibrationDelayFrames, 48)
        XCTAssertEqual(right.coherenceCompensationFrames, 1_280)
        XCTAssertEqual(right.effectiveLaneDelayFrames, 1_328)
        XCTAssertEqual(right.endToEndProgramLatencyFrames, 1_328)
        XCTAssertEqual(plan.maximumEndToEndProgramLatencyFrames, 1_328)
    }

    func testRejectsWrongGroupDelayEvenIfTapCountOtherwiseValid() throws {
        XCTAssertThrowsError(
            try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: makeStereoProfile(),
                bassManagementEnabled: false,
                sampleRate: 48_000,
                tapCount: 2_049,
                declaredGroupDelayFrames: 1_023,
                correctedRoles: [.frontLeft]
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRLatencyPlanningError,
                .invalidDeclaredGroupDelay(
                    expected: 1_024,
                    actual: 1_023
                )
            )
        }
    }

    func testRejectsEvenTapCountDuplicateRolesAndLFE() throws {
        let profile = makeStereoProfile()
        XCTAssertThrowsError(
            try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: profile,
                bassManagementEnabled: false,
                sampleRate: 48_000,
                tapCount: 2_048,
                declaredGroupDelayFrames: 1_023,
                correctedRoles: [.frontLeft]
            )
        )

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: profile,
                bassManagementEnabled: false,
                sampleRate: 48_000,
                tapCount: 2_049,
                declaredGroupDelayFrames: 1_024,
                correctedRoles: [.frontLeft, .frontLeft]
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRLatencyPlanningError,
                .duplicateCorrectedRole(.frontLeft)
            )
        }

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: profile,
                bassManagementEnabled: false,
                sampleRate: 48_000,
                tapCount: 2_049,
                declaredGroupDelayFrames: 1_024,
                correctedRoles: [.lowFrequencyEffects]
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRLatencyPlanningError,
                .unsupportedCorrectedRole(.lowFrequencyEffects)
            )
        }
    }

    func testFailsClosedWhenFIRCompensationWouldOverflowLaneDelayBuffer() throws {
        let profile = makeStereoProfile(
            rightDelayMilliseconds: 300.0
        )
        XCTAssertThrowsError(
            try SpeakerOptimizerFIRLatencyPlanner().plan(
                profile: profile,
                bassManagementEnabled: false,
                sampleRate: 192_000,
                tapCount: 16_385,
                declaredGroupDelayFrames: 8_192,
                correctedRoles: [.frontLeft]
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRLatencyPlanningError,
                .delayCapacityExceeded(role: .frontRight)
            )
        }
    }

    func testPersistentFIRValidatesAndMapsTapsInSemanticLayoutOrder() throws {
        var profile = makeStereoProfile()
        let deployment = makeDeployment(
            profile: profile,
            sources: [
                makeSource(role: .frontRight, centerTap: 0.5),
                makeSource(role: .frontLeft, centerTap: 1.0),
            ],
            requiredHeadroomDB: 1.0
        )
        profile.speakerOptimizerFIR = deployment

        XCTAssertNoThrow(
            try profile.validateStructure(
                bassManagementEnabled: false
            )
        )
        let preparation = try deployment.makeRuntimePreparation(
            programLayout: .stereo
        )
        XCTAssertEqual(preparation.activeChannelMask, 0b11)
        XCTAssertEqual(preparation.tapCount, 257)
        XCTAssertEqual(preparation.declaredGroupDelayFrames, 128)
        XCTAssertEqual(preparation.requiredHeadroomDB, 1.0)
        XCTAssertEqual(preparation.flattenedTaps.count, 514)
        XCTAssertEqual(preparation.flattenedTaps[128], 1.0)
        XCTAssertEqual(preparation.flattenedTaps[257 + 128], 0.5)
    }

    func testPersistentFIRRejectsAsymmetricTaps() throws {
        let profile = makeStereoProfile()
        var source = makeSource(
            role: .frontLeft,
            centerTap: 1.0
        )
        source.taps[0] = 0.25
        let deployment = makeDeployment(
            profile: profile,
            sources: [source],
            requiredHeadroomDB: 1.0
        )

        XCTAssertThrowsError(
            try deployment.validate(profile: profile)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRDeploymentError,
                .invalidTaps(.frontLeft)
            )
        }
    }

    func testPersistentFIRRejectsInsufficientHeadroomAndWrongRate() throws {
        let profile = makeStereoProfile()
        var source = makeSource(
            role: .frontLeft,
            centerTap: 1.0
        )
        source.maximumPositiveGainDB = 1.5
        source.recommendedHeadroomDB = 1.0
        let deployment = makeDeployment(
            profile: profile,
            sources: [source],
            requiredHeadroomDB: 1.0
        )
        XCTAssertThrowsError(
            try deployment.validate(profile: profile)
        )

        let valid = makeDeployment(
            profile: profile,
            sources: [
                makeSource(
                    role: .frontLeft,
                    centerTap: 1.0
                )
            ],
            requiredHeadroomDB: 1.0
        )
        XCTAssertThrowsError(
            try valid.validateLiveSampleRate(96_000)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRDeploymentError,
                .sampleRateMismatch(
                    expected: 48_000,
                    actual: 96_000
                )
            )
        }
    }

    func testLegacyOutputDeviceProfileDecodesWithFIRAbsent() throws {
        let profile = makeStereoProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(
            OutputDeviceProfileConfiguration.self,
            from: data
        )
        XCTAssertNil(decoded.speakerOptimizerFIR)
        XCTAssertEqual(decoded, profile)
    }

    private func makeSource(
        role: OutputProgramRole,
        centerTap: Float
    ) -> SpeakerOptimizerFIRSourceDeployment {
        var taps = [Float](repeating: 0, count: 257)
        taps[128] = centerTap
        return SpeakerOptimizerFIRSourceDeployment(
            role: role,
            candidateFingerprint: "candidate-\(role.rawValue)",
            taps: taps,
            maximumPositiveGainDB: 0.5,
            recommendedHeadroomDB: 1.0
        )
    }

    private func makeDeployment(
        profile: OutputDeviceProfileConfiguration,
        sources: [SpeakerOptimizerFIRSourceDeployment],
        requiredHeadroomDB: Double
    ) -> SpeakerOptimizerFIRDeploymentConfiguration {
        SpeakerOptimizerFIRDeploymentConfiguration(
            proposalID: UUID(),
            baselineMeasurementSetID: UUID(),
            characterizationMeasurementSetID: UUID(),
            routingSignature:
                profile.multichannelCalibrationRoutingSignature,
            sampleRate: 48_000,
            aggregateCandidateFingerprint: "aggregate-fir",
            approvedAt: Date(timeIntervalSince1970: 123),
            tapCount: 257,
            declaredGroupDelayFrames: 128,
            requiredHeadroomDB: requiredHeadroomDB,
            sources: sources
        )
    }

    private func makeStereoProfile(
        leftDelayMilliseconds: Double = 0,
        rightDelayMilliseconds: Double = 0
    ) -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "fir-output",
                        channelIndex: 0
                    ),
                    calibration: SemanticSpeakerCalibration(
                        delayMilliseconds: leftDelayMilliseconds
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "fir-output",
                        channelIndex: 1
                    ),
                    calibration: SemanticSpeakerCalibration(
                        delayMilliseconds: rightDelayMilliseconds
                    )
                ),
            ]
        )
    }
}
