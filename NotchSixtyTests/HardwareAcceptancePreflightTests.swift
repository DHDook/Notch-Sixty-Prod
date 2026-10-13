import Foundation
import XCTest
@testable import NotchSixty

final class HardwareAcceptancePreflightTests: XCTestCase {
    private let systemID = UUID(uuidString:
        "112A4000-0000-0000-0000-000000000001")!

    private func scope(
        splitDriver: HardwareAcceptanceScopeDecision =
            .excluded(reason: "No active split-driver topology."),
        coherentSub: HardwareAcceptanceScopeDecision =
            .excluded(reason: "No independent coherent Sub route."),
        anc: HardwareAcceptanceScopeDecision =
            .excluded(reason: "Live ANC disabled.")
    ) -> [HardwareAcceptanceCapability:
        HardwareAcceptanceScopeDecision] {
        [
            .protectedSplitDriverMeasurement: splitDriver,
            .coherentIndependentSubAlignment: coherentSub,
            .liveFeedForwardANC: anc,
        ]
    }

    private func campaign(
        splitDriver: HardwareAcceptanceScopeDecision =
            .excluded(reason: "No active split-driver topology."),
        coherentSub: HardwareAcceptanceScopeDecision =
            .excluded(reason: "No independent coherent Sub route."),
        anc: HardwareAcceptanceScopeDecision =
            .excluded(reason: "Live ANC disabled.")
    ) -> HardwareAcceptanceCampaign {
        HardwareAcceptanceCampaign(
            identity: HardwareAcceptanceCampaignIdentity(
                id: UUID(uuidString:
                    "112A4000-0000-0000-0000-000000000002")!,
                createdAt: Date(timeIntervalSince1970: 1_800_100_000),
                commitSHA:
                    "f8ef81a80d1aac262ec21da23abef5ed29825506",
                branch:
                    "feature/pr112a-remote-hardware-acceptance-infrastructure",
                appVersion: "1.0",
                appBuild: "1124",
                playbackSystemID: systemID
            ),
            scopeDecisions: scope(
                splitDriver: splitDriver,
                coherentSub: coherentSub,
                anc: anc
            )
        )
    }

    private func environment(
        input: Bool = true,
        reference: Bool = true
    ) -> HardwareAcceptanceEnvironment {
        HardwareAcceptanceEnvironment(
            macModel: "Acceptance Mac",
            macOSVersion: "26.0",
            sampleRate: 96_000,
            ioBufferFrames: 256,
            outputDeviceName: "Acceptance DAC",
            outputDeviceUID: "acceptance-output",
            inputDeviceName: input ? "Acceptance ADC" : nil,
            inputDeviceUID: input ? "acceptance-input" : nil,
            microphoneIdentifier: input ? "calibrated-mic" : nil,
            speakerTopology: "Stereo speakers + independently routed sub",
            referencePathDescription:
                reference ? "Safe line-level reference on same ADC" : nil
        )
    }

    private func profile(
        id: UUID? = nil,
        splitDriver: Bool = false,
        coherentSub: Bool = false
    ) -> PlaybackSystemProfile {
        var state = PlaybackSystemState(
            associatedOutputUID: "acceptance-output"
        )
        if splitDriver {
            var bass = BassManagementConfiguration()
            bass.enabled = true
            state.bassManagement = bass
            state.outputRouting = MultiOutputRoutingConfiguration(
                enabled: true,
                routes: [
                    SpeakerOutputRoute(
                        name: "Left Low",
                        bus: .leftLow,
                        destination: .init(
                            deviceUID: "acceptance-output",
                            channelIndex: 0
                        )
                    ),
                    SpeakerOutputRoute(
                        name: "Left High",
                        bus: .leftHigh,
                        destination: .init(
                            deviceUID: "acceptance-output",
                            channelIndex: 1
                        )
                    ),
                ],
                referenceDeviceUID: "acceptance-output"
            )
            state.speakerDriverProcessing =
                SpeakerDriverProcessingConfiguration(
                    buses: [
                        SpeakerDriverBusProcessingConfiguration(
                            bus: .leftHigh,
                            limiterEnabled: true,
                            limiterThresholdDBFS: -20
                        )
                    ]
                )
        } else if coherentSub {
            state.outputRouting = MultiOutputRoutingConfiguration(
                enabled: true,
                routes: [
                    SpeakerOutputRoute(
                        name: "Left Main",
                        bus: .leftFullRange,
                        destination: .init(
                            deviceUID: "acceptance-output",
                            channelIndex: 0
                        )
                    ),
                    SpeakerOutputRoute(
                        name: "Right Main",
                        bus: .rightFullRange,
                        destination: .init(
                            deviceUID: "acceptance-output",
                            channelIndex: 1
                        )
                    ),
                    SpeakerOutputRoute(
                        name: "Sub",
                        bus: .subMono,
                        destination: .init(
                            deviceUID: "acceptance-output",
                            channelIndex: 2
                        )
                    ),
                ],
                referenceDeviceUID: "acceptance-output"
            )
        }
        return PlaybackSystemProfile(
            id: id ?? systemID,
            name: "Acceptance System",
            state: state
        )
    }

    private func runtime(
        profile: PlaybackSystemProfile?,
        lifecycle: AudioLifecycleState = .idle,
        dirty: Bool = false,
        outputUID: String? = "acceptance-output"
    ) -> HardwareAcceptanceRuntimeSnapshot {
        HardwareAcceptanceRuntimeSnapshot(
            lifecycleState: lifecycle,
            selectedPlaybackSystem: profile,
            selectedPlaybackSystemIsDirty: dirty,
            engineSelectedOutputUID: outputUID
        )
    }

    private func commissioningDraft(
        for profile: PlaybackSystemProfile,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_100_100)
    ) -> ProtectedDriverCommissioningDraft {
        let baseline = profile.state.speakerDriverProcessing!
        var preview = baseline
        var high = preview.configuration(for: .leftHigh)
        high.eqBands.append(
            EQBand(
                enabled: true,
                type: .peaking,
                frequencyHz: 3_000,
                gainDB: -1.0,
                q: 1.0,
                slope: .db12
            )
        )
        preview.replace(high)
        return ProtectedDriverCommissioningDraft(
            id: UUID(),
            createdAt: createdAt,
            playbackSystemID: profile.id,
            sessionID: UUID(),
            routingSignature: "preflight-routing",
            sampleRate: 96_000,
            rollbackPlaybackSystemState: profile.state,
            previewDriverProcessing: preview,
            affectedBuses: [.leftHigh],
            sourceProtocolIDs: [UUID()],
            sourceCaptureIDs: [UUID(), UUID(), UUID()],
            timingReviews: [],
            evidenceSummary:
                "PR111 protected commissioning fixture; hardware verification pending."
        )
    }

    func testH01ReadyRequiresIdleExactSystemAndStableOutput()
        throws {
        let value = try HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(),
                gateID: .h01DeviceLifecycleRecovery,
                runtime: runtime(profile: profile()),
                environment: environment(),
                attestations: .init(),
                evaluatedAt: Date(
                    timeIntervalSince1970: 1_800_100_200
                )
            )
        XCTAssertTrue(value.readyToBeginPhysicalTest)
        XCTAssertTrue(value.blockers.isEmpty)
        XCTAssertFalse(value.physicalAcceptanceEstablished)
        XCTAssertFalse(value.canSatisfyHardwareGate)
        XCTAssertFalse(value.canApplyDSP)
        XCTAssertFalse(value.canDeploy)
        XCTAssertFalse(value.canAuthorizeLiveFeedForwardANC)
        XCTAssertFalse(value.mayMergeIntoMain)
    }

    func testIdentityDirtyStateAndNonIdleLifecycleBlockPreflight()
        throws {
        let other = profile(id: UUID())
        let value = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(),
                gateID: .h01DeviceLifecycleRecovery,
                runtime: runtime(
                    profile: other,
                    lifecycle: .running,
                    dirty: true,
                    outputUID: "wrong-output"
                ),
                environment: environment(),
                attestations: .init()
            )
        let codes = Set(value.blockers.map(\.code))
        XCTAssertTrue(codes.contains(.playbackSystemMismatch))
        XCTAssertTrue(codes.contains(.engineNotIdle))
        XCTAssertTrue(codes.contains(.playbackSystemStateDirty))
        XCTAssertTrue(codes.contains(.selectedOutputMismatch))
        XCTAssertFalse(value.readyToBeginPhysicalTest)
    }

    func testMeasurementGateRequiresRealADCAndMicrophoneIdentity()
        throws {
        let value = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(),
                gateID: .h03MeasurementBaselines,
                runtime: runtime(profile: profile()),
                environment: environment(input: false),
                attestations: .init()
            )
        let codes = Set(value.blockers.map(\.code))
        XCTAssertTrue(codes.contains(.inputDeviceRequired))
        XCTAssertTrue(codes.contains(.microphoneRequired))
        XCTAssertFalse(value.readyToBeginPhysicalTest)
    }

    func testProtectedDriverPreflightRequiresExactPR111RollbackState()
        throws {
        let activeProfile = profile(splitDriver: true)
        let draft = commissioningDraft(for: activeProfile)
        let ready = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(splitDriver: .included),
                gateID: .h05AdvancedMeasurementLab,
                runtime: runtime(profile: activeProfile),
                environment: environment(),
                attestations: .init(
                    protectedDriverWiringConfirmed: true
                ),
                commissioningDraft: draft
            )
        XCTAssertTrue(ready.readyToBeginPhysicalTest)
        XCTAssertEqual(ready.commissioningDraftID, draft.id)
        XCTAssertEqual(
            ready.commissioningSessionID,
            draft.sessionID
        )
        XCTAssertTrue(ready.warnings.contains {
            $0.contains("remain unapplied")
        })

        var changed = activeProfile
        changed.state.outputGainDB = -1
        let drifted = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(splitDriver: .included),
                gateID: .h05AdvancedMeasurementLab,
                runtime: runtime(profile: changed),
                environment: environment(),
                attestations: .init(
                    protectedDriverWiringConfirmed: true
                ),
                commissioningDraft: draft
            )
        XCTAssertTrue(drifted.blockers.contains {
            $0.code == .commissioningDraftStateDrift
        })
        XCTAssertFalse(drifted.readyToBeginPhysicalTest)
    }

    func testProtectedDriverPreflightDoesNotAcceptMissingLimiter()
        throws {
        var activeProfile = profile(splitDriver: true)
        var processing = activeProfile.state
            .speakerDriverProcessing!
        var high = processing.configuration(for: .leftHigh)
        high.limiterEnabled = false
        processing.replace(high)
        activeProfile.state.speakerDriverProcessing = processing
        let draft = commissioningDraft(for: activeProfile)
        let result = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(splitDriver: .included),
                gateID: .h05AdvancedMeasurementLab,
                runtime: runtime(profile: activeProfile),
                environment: environment(),
                attestations: .init(
                    protectedDriverWiringConfirmed: true
                ),
                commissioningDraft: draft
            )
        XCTAssertTrue(result.blockers.contains {
            $0.code == .protectedDriverProcessingRequired
        })
        XCTAssertFalse(result.readyToBeginPhysicalTest)
    }

    func testCoherentSubPreflightRequiresSameADCClockAndSafeReference()
        throws {
        let coherentCampaign = campaign(coherentSub: .included)
        let routed = profile(coherentSub: true)
        let blocked = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: coherentCampaign,
                gateID: .h07CoherentMainSubAlignment,
                runtime: runtime(profile: routed),
                environment: environment(reference: false),
                attestations: .init()
            )
        let codes = Set(blocked.blockers.map(\.code))
        XCTAssertTrue(codes.contains(.sameADCReferenceUnconfirmed))
        XCTAssertTrue(codes.contains(.commonOutputClockUnconfirmed))
        XCTAssertTrue(
            codes.contains(.safeLineLevelReferenceUnconfirmed)
        )

        let ready = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: coherentCampaign,
                gateID: .h07CoherentMainSubAlignment,
                runtime: runtime(profile: routed),
                environment: environment(),
                attestations: .init(
                    sameADCMicrophoneAndReferenceConfirmed: true,
                    commonOutputClockConfirmed: true,
                    safeLineLevelReferenceConfirmed: true
                )
            )
        XCTAssertTrue(ready.readyToBeginPhysicalTest)
        XCTAssertFalse(ready.physicalAcceptanceEstablished)
    }

    func testCoherentSubRequiresIndependentSubRoute() throws {
        let result = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(coherentSub: .included),
                gateID: .h07CoherentMainSubAlignment,
                runtime: runtime(profile: profile()),
                environment: environment(),
                attestations: .init(
                    sameADCMicrophoneAndReferenceConfirmed: true,
                    commonOutputClockConfirmed: true,
                    safeLineLevelReferenceConfirmed: true
                )
            )
        XCTAssertTrue(result.blockers.contains {
            $0.code == .independentSubRouteRequired
        })
    }

    func testH08StaysHardBlockedEvenWhenCampaignIncludesIt()
        throws {
        let result = HardwareAcceptancePreflightAnalyzer()
            .evaluate(
                campaign: campaign(anc: .included),
                gateID: .h08LiveFeedForwardANC,
                runtime: runtime(profile: profile()),
                environment: environment(),
                attestations: .init()
            )
        XCTAssertTrue(result.blockers.contains {
            $0.code == .liveFeedForwardANCNotAuthorized
        })
        XCTAssertFalse(result.readyToBeginPhysicalTest)
        XCTAssertFalse(result.canAuthorizeLiveFeedForwardANC)
    }

    func testLatestCommissioningDraftLocatorIsPlaybackSystemScoped()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR112A-Commissioning-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProtectedDriverCommissioningDraftStore(
            rootDirectory: root
        )
        let system = profile(splitDriver: true)
        var older = commissioningDraft(
            for: system,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        older.id = UUID()
        var newer = commissioningDraft(
            for: system,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        newer.id = UUID()
        try store.save(older)
        try store.save(newer)

        let other = profile(id: UUID(), splitDriver: true)
        let unrelated = commissioningDraft(
            for: other,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        try store.save(unrelated)

        let located = try HardwareAcceptanceCommissioningDraftLocator(
            store: store
        ).latest(for: system.id)
        XCTAssertEqual(located?.id, newer.id)
        XCTAssertEqual(located?.playbackSystemID, system.id)
    }
}
