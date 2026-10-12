import XCTest
@testable import NotchSixty

final class SpeakerOptimizerPostApplyVerificationTests: XCTestCase {
    func testFreshQualifiedVerificationAcceptsTrackedBeneficialPEQ() throws {
        let fixture = try makeFixture()
        let report = try SpeakerOptimizerPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )

        XCTAssertTrue(report.isMeasuredVerification)
        XCTAssertTrue(report.accepted, report.blockingReasons.joined(separator: "; "))
        XCTAssertFalse(report.shouldRollback)
        XCTAssertTrue(report.canFinalizeDeployment)
        let source = try XCTUnwrap(report.sources.first)
        XCTAssertLessThan(source.filterTrackingRMSDB, 0.15)
        XCTAssertGreaterThan(source.persistentImprovementDB, 0.10)
        XCTAssertLessThanOrEqual(source.protectedRegressionDB, 0.35)
    }

    func testGlobalMeasurementLevelOffsetDoesNotCreateFalseFailure() throws {
        let fixture = try makeFixture(verificationGlobalOffsetDB: 2.0)
        let report = try SpeakerOptimizerPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )
        XCTAssertTrue(report.accepted, report.blockingReasons.joined(separator: "; "))
        XCTAssertLessThan(
            try XCTUnwrap(report.sources.first).filterTrackingRMSDB,
            0.15
        )
    }

    func testNoAcousticChangeAfterApplyRecommendsRollback() throws {
        let fixture = try makeFixture(applyFilterToVerification: false)
        let report = try SpeakerOptimizerPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.shouldRollback)
        XCTAssertFalse(report.canFinalizeDeployment)
        XCTAssertTrue(
            try XCTUnwrap(report.sources.first).blockingReasons
                .contains {
                    $0.localizedCaseInsensitiveContains(
                        "did not improve"
                    )
                }
        )
    }

    func testProtectedRegionRegressionRecommendsRollback() throws {
        let fixture = try makeFixture(
            protectedRegressionDB: 4.0
        )
        let report = try SpeakerOptimizerPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.shouldRollback)
        XCTAssertGreaterThan(
            try XCTUnwrap(report.sources.first).protectedRegressionDB,
            0.35
        )
    }

    func testVerificationMustBeNewPostApplyEvidence() throws {
        var fixture = try makeFixture()
        for index in fixture.verification.captures.indices {
            fixture.verification.captures[index].capturedAt =
                fixture.receipt.appliedAt
        }
        XCTAssertThrowsError(
            try SpeakerOptimizerPostApplyVerifier().verify(
                baseline: fixture.baseline,
                verification: fixture.verification,
                plan: fixture.plan,
                receipt: fixture.receipt
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPostApplyVerificationError,
                .verificationNotPostApply
            )
        }
    }

    func testVerificationIdentityAndQualityDriftFailClosed() throws {
        var fixture = try makeFixture()
        fixture.verification.microphone.deviceUID = "different-mic"
        XCTAssertThrowsError(
            try SpeakerOptimizerPostApplyVerifier().verify(
                baseline: fixture.baseline,
                verification: fixture.verification,
                plan: fixture.plan,
                receipt: fixture.receipt
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPostApplyVerificationError,
                .incompatibleIdentity
            )
        }

        fixture = try makeFixture()
        fixture.verification.captures[0].quality.estimatedSNRDB = 20
        XCTAssertThrowsError(
            try SpeakerOptimizerPostApplyVerifier().verify(
                baseline: fixture.baseline,
                verification: fixture.verification,
                plan: fixture.plan,
                receipt: fixture.receipt
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPostApplyVerificationError,
                .verificationUnqualified
            )
        }
    }

    private func makeFixture(
        applyFilterToVerification: Bool = true,
        verificationGlobalOffsetDB: Double = 0,
        protectedRegressionDB: Double = 0
    ) throws -> (
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        receipt: SpeakerOptimizerPEQApplyReceipt
    ) {
        let playbackID = UUID(
            uuidString: "C7000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString: "C7100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString: "C7200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let verificationID = UUID(
            uuidString: "C7300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr105-verification-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: nil
        )
        let seats = [
            SpeakerOptimizerMeasurementPosition(
                id: UUID(
                    uuidString:
                        "C7400000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
                )!,
                name: "Main"
            ),
            SpeakerOptimizerMeasurementPosition(
                id: UUID(
                    uuidString:
                        "C7500000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
                )!,
                name: "Second"
            ),
        ]
        let frequencies = (0..<96).map { index in
            350 * pow(
                12_000.0 / 350.0,
                Double(index) / 95.0
            )
        }

        let ordinary = SemanticSpeakerCalibration(
            trimDB: -0.5,
            delayMilliseconds: 0,
            polarityInverted: false,
            eqBands: []
        )
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr105-verification-output",
                        channelIndex: 0
                    ),
                    calibration: ordinary
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr105-verification-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let route = output.multichannelCalibrationRoutingSignature
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "Verification System",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )

        let band = try XCTUnwrap(
            SpeakerOptimizerPEQBand.peak(
                centerHz: 2_000,
                q: 1.4,
                gainDB: -3.5,
                sampleRate: 48_000
            )
        )
        let modeled = frequencies.map {
            band.magnitudeDB(at: $0, sampleRate: 48_000)
        }
        let candidate = SpeakerOptimizerPEQCandidatePlan(
            baselineMeasurementSetID: baselineID,
            playbackSystemID: playbackID,
            routingSignature: route,
            sampleRate: 48_000,
            evidenceConfidence: 0.95,
            sources: [
                SpeakerOptimizerPEQSourceCandidate(
                    source: source,
                    bands: [band],
                    frequenciesHz: frequencies,
                    modeledFilterMagnitudeDB: modeled,
                    weightedRMSEBeforeDB: 3,
                    predictedWeightedRMSEAfterDB: 1.5,
                    worstSeatRegressionDB: 0,
                    maximumPositiveGainDB: 0,
                    recommendedHeadroomDB: 0,
                    warnings: []
                )
            ]
        )
        let classificationPoints = frequencies.map { frequency in
            let distance = abs(log2(frequency / 2_000))
            return SpeakerOptimizerCrossDomainPoint(
                frequencyHz: frequency,
                characterizationResidualDB:
                    distance < 0.32 ? 3 : 0,
                listeningMeanResidualDB:
                    distance < 0.32 ? 3 : 0,
                listeningSeatSpreadDB: 0.1,
                classification:
                    distance < 0.32
                    ? .speakerPersistent
                    : .noMaterialDeviation
            )
        }
        let classification = SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: characterizationID,
            listeningMeasurementSetID: baselineID,
            playbackSystemID: playbackID,
            routingSignature: route,
            sources: [
                SpeakerOptimizerCrossDomainSourceReport(
                    source: source,
                    frequenciesHz: frequencies,
                    points: classificationPoints,
                    characterizationCaptureCount: 3,
                    listeningSeatCount: seats.count
                )
            ],
            warnings: []
        )
        let plan = SpeakerOptimizerClassificationAwarePEQPlan(
            classification: classification,
            candidate: candidate
        )

        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            plan: plan,
            createdAt: Date(timeIntervalSince1970: 1_703_800_000)
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(timeIntervalSince1970: 1_703_800_100),
            userInitiated: true
        )
        let deployment = try planner.makePEQDeploymentConfiguration(
            profile: profile,
            plan: plan,
            proposal: proposal,
            approval: approval
        )
        var expectedState = profile.state
        var expectedOutput = try XCTUnwrap(
            expectedState.outputDeviceProfile
        )
        expectedOutput.speakerOptimizerPEQ = deployment
        expectedState.outputDeviceProfile = expectedOutput
        let appliedAt = Date(
            timeIntervalSince1970: 1_703_800_200
        )
        let receipt = SpeakerOptimizerPEQApplyReceipt(
            appliedAt: appliedAt,
            proposalID: proposal.id,
            playbackSystemID: playbackID,
            baselineMeasurementSetID: baselineID,
            characterizationMeasurementSetID: characterizationID,
            routingSignature: route,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            deployment: deployment,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expectedState
        )

        var baselineCaptures:
            [SpeakerOptimizerMeasurementCapture] = []
        var verificationCaptures:
            [SpeakerOptimizerMeasurementCapture] = []

        for (seatIndex, seat) in seats.enumerated() {
            for repeatIndex in 0..<3 {
                let baselineMagnitude = frequencies.map { frequency in
                    gaussian(
                        frequency,
                        center: 2_000,
                        gain: 5.5,
                        width: 0.20
                    )
                    + gaussian(
                        frequency,
                        center: 6_000,
                        gain: seatIndex == 0 ? 2.5 : 1.8,
                        width: 0.18
                    )
                    + Double(repeatIndex - 1) * 0.02
                }
                let verificationMagnitude =
                    frequencies.indices.map { index in
                        baselineMagnitude[index]
                        + (applyFilterToVerification
                            ? modeled[index] : 0)
                        + verificationGlobalOffsetDB
                        + gaussian(
                            frequencies[index],
                            center: 6_000,
                            gain: protectedRegressionDB,
                            width: 0.12
                        )
                    }

                baselineCaptures.append(
                    capture(
                        playbackID: playbackID,
                        route: route,
                        microphone: mic,
                        positionID: seat.id,
                        source: source,
                        frequencies: frequencies,
                        magnitudeDB: baselineMagnitude,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_703_799_000
                                + Double(seatIndex * 10 + repeatIndex)
                        ),
                        repeatIndex: repeatIndex
                    )
                )
                verificationCaptures.append(
                    capture(
                        playbackID: playbackID,
                        route: route,
                        microphone: mic,
                        positionID: seat.id,
                        source: source,
                        frequencies: frequencies,
                        magnitudeDB: verificationMagnitude,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_703_801_000
                                + Double(seatIndex * 10 + repeatIndex)
                        ),
                        repeatIndex: repeatIndex
                    )
                )
            }
        }

        let baseline = SpeakerOptimizerMeasurementSet(
            id: baselineID,
            role: .baseline,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: mic,
            sampleRate: 48_000,
            positions: seats,
            plannedSources: [source],
            captures: baselineCaptures
        )
        let verification = SpeakerOptimizerMeasurementSet(
            id: verificationID,
            role: .verification,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: mic,
            sampleRate: 48_000,
            positions: seats,
            plannedSources: [source],
            captures: verificationCaptures
        )
        return (baseline, verification, plan, receipt)
    }

    private func capture(
        playbackID: UUID,
        route: String,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        frequencies: [Double],
        magnitudeDB: [Double],
        capturedAt: Date,
        repeatIndex: Int
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            capturedAt: capturedAt,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: microphone,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: magnitudeDB,
                phaseRadians: frequencies.map {
                    0.03 * log2($0 / 1_000)
                        + Double(repeatIndex - 1) * 0.002
                }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -20,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -72,
                estimatedSNRDB: 58,
                sweepComplete: true,
                directArrivalSeconds:
                    0.010 + Double(repeatIndex) * 0.00002,
                usableLowHz: 350,
                usableHighHz: 12_000,
                warnings: []
            )
        )
    }

    private func gaussian(
        _ frequency: Double,
        center: Double,
        gain: Double,
        width: Double
    ) -> Double {
        gain * exp(
            -0.5 * pow(log2(frequency / center) / width, 2)
        )
    }
}
