import Foundation
import XCTest
@testable import NotchSixty

final class HardwareAcceptanceTests: XCTestCase {
    private func identity() -> HardwareAcceptanceCampaignIdentity {
        HardwareAcceptanceCampaignIdentity(
            id: UUID(uuidString:
                "112A0000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            commitSHA:
                "f8ef81a80d1aac262ec21da23abef5ed29825506",
            branch:
                "feature/pr112a-remote-hardware-acceptance-infrastructure",
            appVersion: "1.0",
            appBuild: "1120",
            playbackSystemID: UUID(uuidString:
                "112A0000-0000-0000-0000-000000000002")!
        )
    }

    private func environment() -> HardwareAcceptanceEnvironment {
        HardwareAcceptanceEnvironment(
            macModel: "Mac acceptance fixture",
            macOSVersion: "26.0",
            sampleRate: 96_000,
            ioBufferFrames: 256,
            outputDeviceName: "Acceptance DAC",
            outputDeviceUID: "pr112a-output",
            inputDeviceName: "Acceptance ADC",
            inputDeviceUID: "pr112a-input",
            microphoneIdentifier: "calibrated-mic-001",
            speakerTopology: "Stereo speakers + line-level sub",
            referencePathDescription:
                "Safe line-level reference on same ADC where required"
        )
    }

    private func scope(
        splitDriver: HardwareAcceptanceScopeDecision =
            .excluded(
                reason:
                    "No independently amplified split-driver topology in this release campaign."
            ),
        coherentSub: HardwareAcceptanceScopeDecision =
            .excluded(
                reason:
                    "No independently addressable Sub route in this campaign."
            ),
        anc: HardwareAcceptanceScopeDecision =
            .excluded(
                reason:
                    "Live speaker-connected feed-forward ANC is disabled in this release scope."
            )
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
            .excluded(
                reason:
                    "No independently amplified split-driver topology in this release campaign."
            ),
        coherentSub: HardwareAcceptanceScopeDecision =
            .excluded(
                reason:
                    "No independently addressable Sub route in this campaign."
            ),
        anc: HardwareAcceptanceScopeDecision =
            .excluded(
                reason:
                    "Live speaker-connected feed-forward ANC is disabled in this release scope."
            )
    ) -> HardwareAcceptanceCampaign {
        HardwareAcceptanceCampaign(
            identity: identity(),
            scopeDecisions: scope(
                splitDriver: splitDriver,
                coherentSub: coherentSub,
                anc: anc
            )
        )
    }

    private func observation(
        gate: HardwareAcceptanceGateID,
        authority: HardwareAcceptanceEvidenceAuthority,
        outcome: HardwareAcceptanceObservationOutcome = .passed,
        id: UUID = UUID(),
        time: TimeInterval = 1_800_000_100
    ) -> HardwareAcceptanceObservation {
        HardwareAcceptanceObservation(
            id: id,
            recordedAt: Date(timeIntervalSince1970: time),
            gateID: gate,
            authority: authority,
            outcome: outcome,
            environment: environment(),
            reviewer: "Acceptance reviewer",
            notes: "Observed directly and recorded for the test fixture.",
            artifacts: [
                HardwareAcceptanceArtifactReference(
                    label: "Acceptance capture",
                    identifier:
                        "capture-\(gate.rawValue)-\(id.uuidString)",
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
    }

    private func satisfyingAuthority(
        for gate: HardwareAcceptanceGateID
    ) -> HardwareAcceptanceEvidenceAuthority {
        HardwareAcceptanceCatalog.definition(gate)
            .minimumAuthority
    }

    func testCatalogCoversEveryHandoffGateExactlyOnce() {
        XCTAssertEqual(
            HardwareAcceptanceCatalog.gates.map(\.id),
            HardwareAcceptanceGateID.allCases
        )
        XCTAssertEqual(
            Set(HardwareAcceptanceCatalog.gates.map(\.id)).count,
            HardwareAcceptanceGateID.allCases.count
        )
        XCTAssertEqual(
            HardwareAcceptanceCatalog.definition(
                .h08LiveFeedForwardANC
            ).minimumAuthority,
            .independentPhysicalReview
        )
    }

    func testRemoteSoftwarePassCannotSatisfyPhysicalGate() throws {
        var value = campaign()
        let remote = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .remoteSoftware
        )
        value = try value.appending(remote)
        let result = try value.evaluate()

        XCTAssertEqual(
            result.statuses[.h01DeviceLifecycleRecovery],
            .insufficientAuthority(
                observationID: remote.id,
                actual: .remoteSoftware,
                required: .physicalHardware
            )
        )
        XCTAssertFalse(result.physicalAcceptanceComplete)
        XCTAssertFalse(result.liveFeedForwardANCAuthorized)
    }

    func testIndependentPhysicalReviewCanSatisfyHardwareRequirement()
        throws {
        var value = campaign()
        let evidence = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .independentPhysicalReview
        )
        value = try value.appending(evidence)
        XCTAssertEqual(
            try value.evaluate()
                .statuses[.h01DeviceLifecycleRecovery],
            .passed(
                observationID: evidence.id,
                authority: .independentPhysicalReview
            )
        )
    }

    func testConditionalCapabilitiesRequireExplicitScopeDecision()
        throws {
        var value = campaign()
        value.scopeDecisions.removeValue(
            forKey: .coherentIndependentSubAlignment
        )
        XCTAssertThrowsError(try value.validated()) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceError,
                .missingScopeDecision
            )
        }

        value = campaign(
            coherentSub: .excluded(reason: "   ")
        )
        XCTAssertThrowsError(try value.validated()) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceError,
                .invalidScopeDecision
            )
        }
    }

    func testSplitDriverExclusionDoesNotWaiveMandatoryH05()
        throws {
        let value = campaign()
        let result = try value.evaluate()

        XCTAssertEqual(
            result.statuses[.h05AdvancedMeasurementLab],
            .missing
        )
        XCTAssertEqual(
            HardwareAcceptanceCatalog.definition(
                .h05AdvancedMeasurementLab
            ).supplementalCapabilities,
            [.protectedSplitDriverMeasurement]
        )
        if case .excluded =
            result.statuses[.h08LiveFeedForwardANC] {
            // Expected.
        } else {
            XCTFail("H08 should be explicitly excluded.")
        }
        XCTAssertFalse(result.liveFeedForwardANCAuthorized)
        XCTAssertFalse(result.physicalAcceptanceComplete)
    }

    func testRequiredPhysicalCampaignCanCompleteWithConditionalFeaturesExcluded()
        throws {
        var value = campaign()
        let required: [HardwareAcceptanceGateID] = [
            .h01DeviceLifecycleRecovery,
            .h02ThermalResourceSpeakerSafety,
            .h03MeasurementBaselines,
            .h04SpeakerOptimizerVerification,
            .h05AdvancedMeasurementLab,
            .h06FIRPhysicalAcceptance,
        ]
        for (index, gate) in required.enumerated() {
            value = try value.appending(
                observation(
                    gate: gate,
                    authority: satisfyingAuthority(for: gate),
                    time: 1_800_001_000 + Double(index)
                )
            )
        }

        let result = try value.evaluate()
        XCTAssertTrue(result.physicalAcceptanceComplete)
        XCTAssertTrue(result.unresolvedGateIDs.isEmpty)
        XCTAssertFalse(result.liveFeedForwardANCAuthorized)
    }

    func testLiveANCAuthorizationRequiresIncludedH08IndependentReviewAndAllGates()
        throws {
        var value = campaign(
            splitDriver: .included,
            coherentSub: .included,
            anc: .included
        )
        for (index, gate) in HardwareAcceptanceGateID
            .allCases.enumerated() {
            value = try value.appending(
                observation(
                    gate: gate,
                    authority: satisfyingAuthority(for: gate),
                    time: 1_800_002_000 + Double(index)
                )
            )
        }

        let result = try value.evaluate()
        XCTAssertTrue(result.physicalAcceptanceComplete)
        XCTAssertTrue(result.liveFeedForwardANCAuthorized)

        var insufficient = campaign(
            splitDriver: .included,
            coherentSub: .included,
            anc: .included
        )
        for (index, gate) in HardwareAcceptanceGateID
            .allCases.enumerated() {
            insufficient = try insufficient.appending(
                observation(
                    gate: gate,
                    authority:
                        gate == .h08LiveFeedForwardANC
                        ? .physicalHardware
                        : satisfyingAuthority(for: gate),
                    time: 1_800_003_000 + Double(index)
                )
            )
        }
        let blocked = try insufficient.evaluate()
        XCTAssertFalse(blocked.physicalAcceptanceComplete)
        XCTAssertFalse(blocked.liveFeedForwardANCAuthorized)
        if case .insufficientAuthority =
            blocked.statuses[.h08LiveFeedForwardANC] {
            // Expected.
        } else {
            XCTFail("H08 must reject non-independent evidence.")
        }
    }

    func testNewestObservationCanRegressPreviouslyPassedGate()
        throws {
        var value = campaign()
        let pass = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware,
            time: 1_800_004_000
        )
        value = try value.appending(pass)
        let fail = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware,
            outcome: .failed,
            time: 1_800_004_100
        )
        value = try value.appending(fail)

        XCTAssertEqual(
            try value.evaluate()
                .statuses[.h01DeviceLifecycleRecovery],
            .failed(observationID: fail.id)
        )
    }

    func testDuplicateEvidenceIDIsRejected() throws {
        let repeatedID = UUID()
        var value = campaign()
        value = try value.appending(
            observation(
                gate: .h01DeviceLifecycleRecovery,
                authority: .physicalHardware,
                id: repeatedID
            )
        )
        XCTAssertThrowsError(
            try value.appending(
                observation(
                    gate: .h03MeasurementBaselines,
                    authority: .physicalHardware,
                    id: repeatedID
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceError,
                .duplicateObservation
            )
        }
    }

    func testCampaignPersistenceRoundTripAndCorruptionFailClosed()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR112A-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HardwareAcceptanceCampaignStore(
            rootDirectory: root
        )
        var value = campaign()
        value = try value.appending(
            observation(
                gate: .h01DeviceLifecycleRecovery,
                authority: .physicalHardware,
                id: UUID(uuidString:
                    "112A0000-0000-0000-0000-000000000003")!,
                time: 1_800_005_000
            )
        )
        try store.create(value)
        XCTAssertEqual(
            try store.load(value.identity.id),
            value
        )

        let next = observation(
            gate: .h03MeasurementBaselines,
            authority: .physicalHardware,
            id: UUID(uuidString:
                "112A0000-0000-0000-0000-000000000004")!,
            time: 1_800_005_100
        )
        let updated = try store.append(
            next,
            to: value.identity.id
        )
        XCTAssertEqual(updated.observations.count, 2)

        let path = store.url(for: value.identity.id)
        let broken = Data("{broken".utf8)
        try broken.write(to: path, options: .atomic)
        XCTAssertThrowsError(
            try store.append(
                observation(
                    gate: .h04SpeakerOptimizerVerification,
                    authority: .independentPhysicalReview
                ),
                to: value.identity.id
            )
        ) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceError,
                .corruptPersistence
            )
        }
        XCTAssertEqual(try Data(contentsOf: path), broken)
    }

    func testInvalidArtifactHashAndEnvironmentFailClosed() {
        var bad = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware
        )
        bad.artifacts[0].sha256 = "not-a-sha"
        XCTAssertThrowsError(try bad.validated())

        bad = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware
        )
        bad.environment.sampleRate = .nan
        XCTAssertThrowsError(try bad.validated()) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceError,
                .invalidEnvironment
            )
        }
    }
}
