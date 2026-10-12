import XCTest
@testable import NotchSixty

@MainActor
final class CoherentSubwooferAlignmentGuidedWorkflowTests:
    XCTestCase {
    func testSingleSubGuidedReviewApplyAndRollback() throws {
        let profile = makeProfile(subwooferCount: 1)
        let store = PR108GuidedFakeStore(profile: profile)
        let controller =
            CoherentSubwooferAlignmentGuidedController(
                profileStore: store
            )
        let baseline = try makeSession(
            profile: profile,
            subwooferArrivalsMilliseconds: [0: 3],
            capturedAtBase: 1_706_000_000
        )

        try controller.prepareReview(
            baselineSession: baseline
        )

        XCTAssertEqual(
            controller.mode,
            .singleSubwoofer(0)
        )
        XCTAssertEqual(controller.state, .reviewReady)
        XCTAssertTrue(controller.canApproveAndApply)
        XCTAssertNotNil(controller.singleCandidate)
        XCTAssertNotNil(controller.singleProposal)
        XCTAssertNil(controller.multiCandidate)

        try controller.approveAndApply(
            userInitiated: true,
            approvedAt: Date(timeIntervalSince1970: 10),
            appliedAt: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            controller.state,
            .appliedPendingVerification
        )
        XCTAssertTrue(controller.canRollback)
        XCTAssertNotNil(
            store.profile?.state.outputDeviceProfile?
                .coherentSubwooferAlignment
        )

        try controller.rollback(
            rolledBackAt: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertEqual(store.profile?.state, profile.state)

        controller.resetAfterRollback()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.mode)
    }

    func testMultiSubGuidedReviewUsesAtomicCoordinatedPath()
        throws {
        let profile = makeProfile(subwooferCount: 2)
        let store = PR108GuidedFakeStore(profile: profile)
        let controller =
            CoherentSubwooferAlignmentGuidedController(
                profileStore: store
            )
        let baseline = try makeSession(
            profile: profile,
            subwooferArrivalsMilliseconds: [
                0: 3,
                1: -2,
            ],
            capturedAtBase: 1_706_100_000
        )

        try controller.prepareReview(
            baselineSession: baseline
        )

        XCTAssertEqual(
            controller.mode,
            .coordinatedMultiSubwoofer([0, 1])
        )
        XCTAssertEqual(controller.subwooferCount, 2)
        XCTAssertTrue(controller.canApproveAndApply)
        XCTAssertNotNil(controller.multiCandidate)
        XCTAssertNotNil(controller.multiProposal)
        XCTAssertNil(controller.singleCandidate)

        try controller.approveAndApply(
            userInitiated: true
        )
        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        XCTAssertNotNil(
            output.coherentMultiSubwooferAlignment
        )
        XCTAssertNil(output.coherentSubwooferAlignment)

        try controller.rollback()
        XCTAssertEqual(store.profile?.state, profile.state)
    }

    func testAcceptedSingleVerificationFinalizesAndCanRollback()
        throws {
        let profile = makeProfile(subwooferCount: 1)
        let store = PR108GuidedFakeStore(profile: profile)
        let controller =
            CoherentSubwooferAlignmentGuidedController(
                profileStore: store
            )
        try controller.prepareReview(
            baselineSession: makeSession(
                profile: profile,
                subwooferArrivalsMilliseconds: [0: 3],
                capturedAtBase: 1_706_200_000
            )
        )
        try controller.approveAndApply(
            userInitiated: true,
            appliedAt: Date(timeIntervalSince1970: 100)
        )
        let receipt = try XCTUnwrap(
            controller.singleApplyReceipt
        )
        let candidate = receipt.candidate

        let source =
            CoherentSubwooferAlignmentSourceVerification(
                mainRole: candidate.mainRoles[0],
                analyzedFrequencyCount:
                    candidate.analyzedFrequencyCount,
                phaseTrackingRMSRadians: 0.05,
                magnitudeTrackingRMSDB: 0.05,
                coherenceBeforeDB: -2,
                coherenceAfterDB: -0.5,
                measuredImprovementDB: 1.5,
                accepted: true,
                blockingReasons: []
            )
        let report =
            CoherentSubwooferAlignmentVerificationReport(
                applyReceiptID: receipt.id,
                verificationSessionID: UUID(),
                playbackSystemID: receipt.playbackSystemID,
                routingSignature:
                    candidate.routingSignature,
                microphone: candidate.microphone,
                sampleRate: candidate.sampleRate,
                subwooferIndex:
                    candidate.subwooferIndex,
                crossoverFrequencyHz:
                    candidate.crossoverFrequencyHz,
                evidenceConfidence: 0.95,
                sources: [source],
                coherenceBeforeDB: -2,
                coherenceAfterDB: -0.5,
                measuredImprovementDB: 1.5,
                blockingReasons: [],
                warnings: []
            )

        try controller.recordVerification(report)

        XCTAssertEqual(
            controller.state,
            .measuredAccepted
        )
        XCTAssertNotNil(
            controller.singleFinalizationReceipt
        )
        XCTAssertTrue(
            store.profile?.state.outputDeviceProfile?
                .coherentSubwooferAlignment?.verified
                == true
        )

        try controller.rollback()
        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertEqual(store.profile?.state, profile.state)
    }

    func testRejectedMultiVerificationAutomaticallyRollsBack()
        throws {
        let profile = makeProfile(subwooferCount: 2)
        let store = PR108GuidedFakeStore(profile: profile)
        let controller =
            CoherentSubwooferAlignmentGuidedController(
                profileStore: store
            )
        try controller.prepareReview(
            baselineSession: makeSession(
                profile: profile,
                subwooferArrivalsMilliseconds: [
                    0: 3,
                    1: -2,
                ],
                capturedAtBase: 1_706_300_000
            )
        )
        try controller.approveAndApply(
            userInitiated: true
        )
        let receipt = try XCTUnwrap(
            controller.multiApplyReceipt
        )
        let candidate = receipt.candidate

        let sources =
            candidate.subwoofers.map { sub in
                CoherentMultiSubwooferAlignmentSourceVerification(
                    subwooferIndex: sub.subwooferIndex,
                    mainRole: candidate.mainRoles[0],
                    analyzedFrequencyCount: 12,
                    phaseTrackingRMSRadians: 1,
                    magnitudeTrackingRMSDB: 0,
                    coherenceBeforeDB: -2,
                    coherenceAfterDB: -2,
                    measuredImprovementDB: 0,
                    accepted: false,
                    blockingReasons: ["phase mismatch"]
                )
            }
        let report =
            CoherentMultiSubwooferAlignmentVerificationReport(
                applyReceiptID: receipt.id,
                verificationSessionID: UUID(),
                playbackSystemID: receipt.playbackSystemID,
                routingSignature:
                    candidate.routingSignature,
                microphone: candidate.microphone,
                sampleRate: candidate.sampleRate,
                subwooferIndices:
                    candidate.subwoofers
                        .map(\.subwooferIndex)
                        .sorted(),
                crossoverFrequencyHz:
                    candidate.crossoverFrequencyHz,
                evidenceConfidence: 0.95,
                sources: sources,
                coherenceBeforeDB: -2,
                coherenceAfterDB: -2,
                measuredImprovementDB: 0,
                blockingReasons:
                    ["Coordinated verification rejected."],
                warnings: []
            )

        try controller.recordVerification(report)

        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertNotNil(controller.multiRollbackReceipt)
        XCTAssertEqual(store.profile?.state, profile.state)
    }

    func testReviewRequiresExactAssignedSubEvidence()
        throws {
        let profile = makeProfile(subwooferCount: 2)
        let store = PR108GuidedFakeStore(profile: profile)
        let controller =
            CoherentSubwooferAlignmentGuidedController(
                profileStore: store
            )
        // The session contains only Sub 1 even though two physical Subs
        // are assigned.
        let incomplete = try makeSession(
            profile: profile,
            subwooferArrivalsMilliseconds: [0: 3],
            capturedAtBase: 1_706_400_000
        )

        XCTAssertThrowsError(
            try controller.prepareReview(
                baselineSession: incomplete
            )
        ) {
            XCTAssertEqual(
                $0 as? CoherentSubwooferAlignmentGuidedError,
                .coherentEvidenceShapeMismatch
            )
        }
        XCTAssertEqual(controller.state, .failed)
    }

    private func makeProfile(
        subwooferCount: Int
    ) -> PlaybackSystemProfile {
        let speakers = [
            SemanticSpeakerOutputAssignment(
                role: .frontLeft,
                destination: PhysicalOutputEndpoint(
                    deviceUID: "pr108-guided-output",
                    channelIndex: 0
                )
            ),
            SemanticSpeakerOutputAssignment(
                role: .frontRight,
                destination: PhysicalOutputEndpoint(
                    deviceUID: "pr108-guided-output",
                    channelIndex: 1
                )
            ),
        ]
        let subs = (0..<subwooferCount).map { index in
            PhysicalSubwooferOutputAssignment(
                index: UInt32(index),
                destination: PhysicalOutputEndpoint(
                    deviceUID: "pr108-guided-output",
                    channelIndex: UInt32(index + 2)
                )
            )
        }
        return PlaybackSystemProfile(
            id: UUID(
                uuidString:
                    "E9000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            name: "PR108 Guided",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(
                        enabled: true,
                        frequencyHz: 80
                    ),
                outputDeviceProfile:
                    OutputDeviceProfileConfiguration(
                        enabled: true,
                        programLayout: .stereo,
                        speakerAssignments: speakers,
                        subwooferAssignments: subs
                    )
            )
        )
    }

    private func makeSession(
        profile: PlaybackSystemProfile,
        subwooferArrivalsMilliseconds: [UInt32: Double],
        capturedAtBase: TimeInterval
    ) throws -> SpeakerMeasurementLabSession {
        let output = try XCTUnwrap(
            profile.state.outputDeviceProfile
        )
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr108-guided-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: "pr108-guided-cal"
        )
        var protocols: [SpeakerMeasurementLabProtocol] = []

        for subIndex in subwooferArrivalsMilliseconds.keys.sorted() {
            let pairID = UUID()
            let request = SpeakerMeasurementLabRequest(
                mode: .coherentMainsSubTiming,
                target: .sourcePair(
                    main: .speaker(.frontLeft),
                    subwoofer: .subwoofer(subIndex)
                ),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 2
                ),
                repeatCount: 3
            )
            protocols.append(
                SpeakerMeasurementLabProtocol(
                    name: "Main / Sub \(subIndex + 1)",
                    request: request,
                    excitationLevelDBFS: -24,
                    coherentPairID: pairID,
                    coherentLeg: .main
                )
            )
            protocols.append(
                SpeakerMeasurementLabProtocol(
                    name: "Sub \(subIndex + 1)",
                    request: request,
                    excitationLevelDBFS: -24,
                    coherentPairID: pairID,
                    coherentLeg: .subwoofer
                )
            )
        }

        var session = SpeakerMeasurementLabSession(
            playbackSystemID: profile.id,
            routingSignature:
                output.multichannelCalibrationRoutingSignature,
            microphone: mic,
            sharedClockReferenceConfiguration:
                SpeakerMeasurementLabSharedClockReferenceConfiguration(
                    inputDeviceUID: mic.deviceUID,
                    inputChannelIndex: 1,
                    outputReferenceDeviceUID:
                        "pr108-guided-output",
                    minimumSNRDB: 35
                ),
            sampleRate: 48_000,
            protocols: protocols,
            captures: []
        )

        for (protocolOffset, labProtocol)
            in protocols.enumerated() {
            guard case .sourcePair(_, .subwoofer(let subIndex))
                    = labProtocol.request.target,
                  let relativeMilliseconds =
                    subwooferArrivalsMilliseconds[subIndex] else {
                throw CoherentSubwooferAlignmentGuidedError
                    .coherentEvidenceShapeMismatch
            }
            let mainArrival = 0.010
            let subArrival =
                mainArrival
                    + relativeMilliseconds / 1_000
            let acousticArrival =
                labProtocol.coherentLeg == .main
                    ? mainArrival : subArrival

            for repeatIndex in 0..<3 {
                let referenceArrival =
                    0.002
                        + Double(repeatIndex) * 0.00001
                session.captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeatIndex,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                capturedAtBase
                                + Double(
                                    protocolOffset * 10
                                        + repeatIndex
                                )
                        ),
                        playbackSystemID: profile.id,
                        routingSignature:
                            output
                                .multichannelCalibrationRoutingSignature,
                        microphone: mic,
                        excitationLevelDBFS: -24,
                        sampleRate: 48_000,
                        source: labProtocol.captureSource!,
                        sharedClockReference:
                            referenceEvidence(
                                microphone: mic,
                                arrival: referenceArrival,
                                repeatIndex: repeatIndex
                            ),
                        impulseResponse: [0, 0.1, 1, 0.2, 0],
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: frequencies,
                                magnitudeDB:
                                    Array(
                                        repeating: 0,
                                        count: frequencies.count
                                    ),
                                phaseRadians:
                                    Array(
                                        repeating: 0,
                                        count: frequencies.count
                                    )
                            ),
                        quality:
                            RoomCorrectionMeasurementQuality(
                                clipped: false,
                                playbackPeakDBFS: -24,
                                capturePeakDBFS: -12,
                                estimatedNoiseFloorDBFS: -75,
                                estimatedSNRDB: 60,
                                sweepComplete: true,
                                directArrivalSeconds:
                                    acousticArrival
                                    + Double(repeatIndex)
                                        * 0.00001,
                                usableLowHz: 40,
                                usableHighHz: 140,
                                warnings: []
                            )
                    )
                )
            }
        }

        try session.validateStructure()
        return session
    }

    private func referenceEvidence(
        microphone: SpeakerOptimizerMicrophoneIdentity,
        arrival: Double,
        repeatIndex: Int
    ) -> SpeakerMeasurementLabSharedClockReferenceEvidence {
        SpeakerMeasurementLabSharedClockReferenceEvidence(
            inputDeviceUID: microphone.deviceUID,
            inputChannelIndex: 1,
            outputReferenceDeviceUID:
                "pr108-guided-output",
            sampleRate: 48_000,
            directArrivalSeconds: arrival,
            transferFunction:
                RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: Array(
                        repeating:
                            Double(repeatIndex - 1) * 0.005,
                        count: frequencies.count
                    ),
                    phaseRadians: Array(
                        repeating:
                            Double(repeatIndex - 1) * 0.002,
                        count: frequencies.count
                    )
                ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -24,
                capturePeakDBFS: -8,
                estimatedNoiseFloorDBFS: -75,
                estimatedSNRDB: 65,
                sweepComplete: true,
                directArrivalSeconds: arrival,
                usableLowHz: 40,
                usableHighHz: 140,
                warnings: []
            )
        )
    }

    private var frequencies: [Double] {
        stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
    }
}

@MainActor
private final class PR108GuidedFakeStore:
    CoherentSubwooferAlignmentProfileMutating {
    var profile: PlaybackSystemProfile?
    var coherentAlignmentLifecycleState:
        AudioLifecycleState = .idle

    init(profile: PlaybackSystemProfile?) {
        self.profile = profile
    }

    var coherentAlignmentSelectedSystemProfile:
        PlaybackSystemProfile? {
        profile
    }

    func coherentAlignmentReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        profile?.state.outputDeviceProfile = configuration
    }
}
