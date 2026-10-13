import Foundation
import XCTest
@testable import NotchSixty

final class HardwareAcceptanceReportTests: XCTestCase {
    private func identity() -> HardwareAcceptanceCampaignIdentity {
        HardwareAcceptanceCampaignIdentity(
            id: UUID(uuidString:
                "112A5000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_800_100_000),
            commitSHA: "abcdef0123456789",
            branch: "feature/pr112a-report-tests",
            appVersion: "1.0",
            appBuild: "1125",
            playbackSystemID: UUID(uuidString:
                "112A5000-0000-0000-0000-000000000002")!
        )
    }

    private func environment() -> HardwareAcceptanceEnvironment {
        HardwareAcceptanceEnvironment(
            macModel: "Mac fixture",
            macOSVersion: "26.0",
            sampleRate: 96_000,
            ioBufferFrames: 256,
            outputDeviceName: "DAC",
            outputDeviceUID: "report-dac",
            inputDeviceName: "ADC",
            inputDeviceUID: "report-adc",
            microphoneIdentifier: "cal-mic",
            speakerTopology: "Stereo + line-level Sub",
            referencePathDescription: "Safe line-level same-ADC reference"
        )
    }

    private func campaign(
        coherentSub: HardwareAcceptanceScopeDecision =
            .excluded(reason: "No independent Sub route."),
        anc: HardwareAcceptanceScopeDecision =
            .excluded(reason: "ANC not in release scope.")
    ) -> HardwareAcceptanceCampaign {
        HardwareAcceptanceCampaign(
            identity: identity(),
            scopeDecisions: [
                .protectedSplitDriverMeasurement:
                    .excluded(reason: "Passive speakers."),
                .coherentIndependentSubAlignment: coherentSub,
                .liveFeedForwardANC: anc,
            ]
        )
    }

    private func observation(
        gate: HardwareAcceptanceGateID,
        authority: HardwareAcceptanceEvidenceAuthority,
        outcome: HardwareAcceptanceObservationOutcome = .passed,
        time: TimeInterval,
        artifact: String? = nil
    ) -> HardwareAcceptanceObservation {
        HardwareAcceptanceObservation(
            id: UUID(),
            recordedAt: Date(timeIntervalSince1970: time),
            gateID: gate,
            authority: authority,
            outcome: outcome,
            environment: environment(),
            reviewer: "Physical reviewer",
            notes: "Recorded physical acceptance evidence.",
            coveredCapabilities: [],
            artifacts: artifact.map {
                [HardwareAcceptanceArtifactReference(
                    label: "Evidence",
                    identifier: $0,
                    sha256: String(repeating: "b", count: 64)
                )]
            } ?? []
        )
    }

    func testRemotePassStaysInsufficientInMachineAndHumanReport()
        throws {
        var value = campaign()
        value = try value.appending(
            observation(
                gate: .h01DeviceLifecycleRecovery,
                authority: .remoteSoftware,
                time: 1_800_100_100,
                artifact: "ci-only"
            )
        )
        let report = try HardwareAcceptanceReportBuilder().build(
            campaign: value,
            generatedAt: Date(timeIntervalSince1970: 1_800_100_200)
        )
        let h01 = try XCTUnwrap(report.gates.first {
            $0.id == .h01DeviceLifecycleRecovery
        })
        XCTAssertEqual(h01.state, .insufficientAuthority)
        XCTAssertFalse(h01.accepted)
        XCTAssertFalse(report.physicalAcceptanceComplete)
        XCTAssertFalse(report.releaseAcceptanceComplete)
        XCTAssertFalse(report.mayMergeIntoMain)
        XCTAssertFalse(report.physicalEvidenceSuppliedByCI)
        XCTAssertTrue(
            report.unresolvedGateIDs.contains(
                .h01DeviceLifecycleRecovery
            )
        )

        let markdown =
            HardwareAcceptanceReportExporter().markdown(report)
        XCTAssertTrue(markdown.contains(
            "Remote CI cannot create physical evidence"
        ))
        XCTAssertTrue(markdown.contains("insufficientAuthority"))
        XCTAssertTrue(markdown.contains("Release acceptance complete: NO"))
        XCTAssertTrue(markdown.contains("May merge into main: NO"))
    }

    func testArtifactManifestAndObservationsPreserveExactEvidenceIDs()
        throws {
        var value = campaign()
        let h03 = observation(
            gate: .h03MeasurementBaselines,
            authority: .physicalHardware,
            time: 1_800_100_100,
            artifact: "speaker-baseline-session-123"
        )
        value = try value.appending(h03)
        let report = try HardwareAcceptanceReportBuilder()
            .build(campaign: value)

        XCTAssertEqual(report.artifactManifest.count, 1)
        XCTAssertEqual(
            report.artifactManifest[0].identifier,
            "speaker-baseline-session-123"
        )
        XCTAssertEqual(
            report.artifactManifest[0].observationID,
            h03.id
        )
        XCTAssertEqual(report.observations.first?.id, h03.id)

        let json = try HardwareAcceptanceReportExporter()
            .jsonData(report)
        let text = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(text.contains(
            "speaker-baseline-session-123"
        ))
        XCTAssertTrue(text.contains(
            value.identity.commitSHA
        ))
        XCTAssertTrue(text.contains(
            "\"releaseAcceptanceComplete\" : false"
        ))
        XCTAssertTrue(text.contains(
            "\"mayMergeIntoMain\" : false"
        ))
        XCTAssertTrue(text.contains(
            "\"physicalEvidenceSuppliedByCI\" : false"
        ))
    }

    func testPhysicalCompletionCanNeverCreateReleaseOrMergeAuthority()
        throws {
        var value = campaign()
        var time = 1_800_100_100.0
        for gate in HardwareAcceptanceGateID.allCases {
            if gate == .h07CoherentMainSubAlignment
                || gate == .h08LiveFeedForwardANC {
                continue
            }
            let authority =
                HardwareAcceptanceCatalog.definition(gate)
                    .minimumAuthority
            value = try value.appending(
                observation(
                    gate: gate,
                    authority: authority,
                    time: time
                )
            )
            time += 1
        }

        let report = try HardwareAcceptanceReportBuilder()
            .build(campaign: value)
        XCTAssertTrue(report.physicalAcceptanceComplete)
        XCTAssertTrue(report.unresolvedGateIDs.isEmpty)
        XCTAssertFalse(report.releaseAcceptanceComplete)
        XCTAssertFalse(report.mayMergeIntoMain)
        XCTAssertFalse(report.liveFeedForwardANCAuthorized)
    }

    func testRunbookListsEveryGateAndKeepsSafetyBoundaries()
        throws {
        let report = try HardwareAcceptanceReportBuilder()
            .build(campaign: campaign())
        XCTAssertEqual(
            report.runbook.map(\.gateID),
            HardwareAcceptanceGateID.allCases
        )
        let h07 = try XCTUnwrap(report.runbook.first {
            $0.gateID == .h07CoherentMainSubAlignment
        })
        XCTAssertFalse(h07.includedInCampaign)
        XCTAssertTrue(h07.safetyBoundary.contains("same ADC"))
        XCTAssertTrue(h07.safetyBoundary.contains("speaker-level"))
        let h08 = try XCTUnwrap(report.runbook.first {
            $0.gateID == .h08LiveFeedForwardANC
        })
        XCTAssertTrue(h08.safetyBoundary.contains("no live ANC authorization"))
    }

    func testNewestRegressionAppearsInReportInsteadOfStalePass()
        throws {
        var value = campaign()
        let pass = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware,
            time: 1_800_100_100
        )
        let fail = observation(
            gate: .h01DeviceLifecycleRecovery,
            authority: .physicalHardware,
            outcome: .failed,
            time: 1_800_100_200
        )
        value = try value.appending(pass)
        value = try value.appending(fail)

        let report = try HardwareAcceptanceReportBuilder()
            .build(campaign: value)
        let h01 = try XCTUnwrap(report.gates.first {
            $0.id == .h01DeviceLifecycleRecovery
        })
        XCTAssertEqual(h01.state, .failed)
        XCTAssertEqual(h01.observationID, fail.id)
        XCTAssertFalse(report.physicalAcceptanceComplete)
    }
}
