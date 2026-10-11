import CryptoKit
import XCTest
@testable import NotchSixty

final class ProductionInformationArchitectureTests: XCTestCase {
    func testDashboardIsStandaloneAndNotInAGroup() {
        let grouped =
            ProductionSection.playback
            + ProductionSection.system
            + ProductionSection.tools
            + ProductionSection.extensions

        XCTAssertFalse(grouped.contains(.dashboard))
        XCTAssertEqual(Set(grouped).count, grouped.count)
        XCTAssertEqual(
            Set(grouped + [.dashboard]),
            Set(ProductionSection.allCases)
        )
    }

    func testPlaybackGroupContainsOnlyContentFacingDailyControls() {
        XCTAssertEqual(
            ProductionSection.playback,
            [.equalizer, .dynamics, .meters]
        )
    }

    func testSystemGroupContainsHardwareCalibrationAndAcoustics() {
        XCTAssertEqual(
            ProductionSection.system,
            [
                .speakers,
                .headphones,
                .speakerCalibration,
                .roomCorrection,
                .activeAcoustics,
            ]
        )
    }

    func testToolsGroupContainsOccasionalRoomAdvisor() {
        XCTAssertEqual(
            ProductionSection.tools,
            [.roomAdvisor]
        )
    }

    func testExtensionsGroupContainsPluginRackEntryPoint() {
        XCTAssertEqual(
            ProductionSection.extensions,
            [.plugins]
        )
    }

    func testRenamedAndNewTitlesMatchProductLanguage() {
        XCTAssertEqual(ProductionSection.dashboard.title, "Dashboard")
        XCTAssertEqual(ProductionSection.speakers.title, "Speakers")
        XCTAssertEqual(
            ProductionSection.activeAcoustics.title,
            "Active Acoustics"
        )
        XCTAssertEqual(
            ProductionSection.roomAdvisor.title,
            "Room Advisor"
        )
        XCTAssertEqual(ProductionSection.plugins.title, "Plug-ins")
    }

    func testActiveAcousticsUXRequiresCalibrationBeforeTimingReview() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: false,
            timingReadiness: .missingMeasurements
        )

        XCTAssertEqual(snapshot.state, .calibrationRequired)
        XCTAssertEqual(snapshot.timingCaption, "MEASUREMENTS REQUIRED")
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testPhysicallyPlausibleTimingStillRequiresHardwareVerification() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .physicallyPlausible
        )

        XCTAssertEqual(snapshot.state, .timingPlausibleHardwareRequired)
        XCTAssertEqual(snapshot.timingCaption, "DIAGNOSTIC PASS")
        XCTAssertTrue(snapshot.nextAction.contains("PR99 A/B/A"))
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testNonCausalTimingNeverLooksReady() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .nonCausal
        )

        XCTAssertEqual(snapshot.state, .timingUnqualified)
        XCTAssertEqual(snapshot.timingCaption, "NON-CAUSAL")
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
    }


    func testConsolidatedDiagnosticsKeepPhysicalGatesSeparate() {
        let budget = QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible,
            acousticPreviewSeconds: 0.020,
            conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.010,
            conservativeReserveSeconds: 0.005,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Synthetic diagnostic fixture"
        )
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: budget
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "causality" })?.disposition,
            .diagnosticPass
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "acoustic" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "mute" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "output" })?.disposition,
            .disconnected
        )
        XCTAssertGreaterThan(snapshot.unresolvedCount, 0)
    }

    func testConsolidatedDiagnosticsExposeMissingCommissioningRecords() {
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: .missing
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "plan" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "clock" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "path" })?.disposition,
            .blocked
        )
        XCTAssertTrue(snapshot.headline.contains("blockers"))
    }


    func testPhysicalCampaignPlanPreservesABAAndEvidenceCounts() {
        let campaign = ActiveAcousticsPhysicalCampaignUXSnapshot()

        XCTAssertEqual(campaign.visits.map(\.positionLabel), ["A", "B", "A"])
        XCTAssertEqual(campaign.totalSourceCaptures, 9)
        XCTAssertEqual(campaign.totalFaultWitnesses, 15)
        XCTAssertFalse(campaign.physicalVerificationComplete)
        XCTAssertFalse(campaign.instrumentProvenanceAuthenticated)
        XCTAssertFalse(campaign.liveOutputAuthorized)
    }


    private func makePhysicalEvidencePackage(
        validDigest: Bool = true
    ) throws -> QuietZonePhysicalEvidencePackage {
        let rig = QuietZoneHardwareCalibrationRig(
            projectID: UUID(),
            microphoneID: "test-mic",
            microphoneChannel: 0,
            outputDeviceID: "test-dac",
            routeID: "route-1",
            sampleRate: 96_000,
            clockID: "clock-1",
            triggerID: "fixture-1"
        )
        let campaign = QuietZonePhysicalVerificationReview(
            rig: rig,
            sessionIDs: [UUID(), UUID(), UUID()],
            firstPrimaryReductionDB: 5.0,
            neighboringSeatReductionDB: 2.0,
            returningPrimaryReductionDB: 4.6,
            worstMeasuredBandReductionDB: 1.0,
            largestPrimaryBaselineDifferenceDB: 0.7,
            primaryReductionRepeatDifferenceDB: 0.4,
            worstReportedShutdownSeconds: 0.050,
            uniqueExternalLaunchCount: 24
        )
        let rows = [["SCHEMA", "PR99_PHYSICAL_EVIDENCE", "1"]]
        let data = try JSONEncoder().encode(rows)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let actualDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let digest = validDigest
            ? actualDigest
            : String(repeating: "0", count: 64)
        return QuietZonePhysicalEvidencePackage(
            schemaVersion: 1,
            canonicalJSON: json,
            sha256Hex: digest,
            frequencyResults: [
                .init(
                    frequencyHz: 40,
                    primaryFirstReductionDB: 5.0,
                    neighboringSeatReductionDB: 2.0,
                    primaryReturnReductionDB: 4.6,
                    primaryRepeatDifferenceDB: 0.4,
                    worstObservedReductionDB: 2.0,
                    primaryFourBaselineSpanDB: 0.5
                ),
                .init(
                    frequencyHz: 80,
                    primaryFirstReductionDB: 4.0,
                    neighboringSeatReductionDB: 1.5,
                    primaryReturnReductionDB: 3.8,
                    primaryRepeatDifferenceDB: 0.2,
                    worstObservedReductionDB: 1.5,
                    primaryFourBaselineSpanDB: 0.7
                ),
                .init(
                    frequencyHz: 120,
                    primaryFirstReductionDB: 3.5,
                    neighboringSeatReductionDB: 1.0,
                    primaryReturnReductionDB: 3.2,
                    primaryRepeatDifferenceDB: 0.3,
                    worstObservedReductionDB: 1.0,
                    primaryFourBaselineSpanDB: 0.6
                ),
            ],
            campaignReview: campaign,
            maximumPrimaryBandRepeatDifferenceDB: 0.4,
            worstFrequencyReductionDB: 1.0,
            rawSourceLaunchCount: 9,
            rawFaultWitnessCount: 15
        )
    }

    func testPhysicalEvidenceUXWaitsForRealCampaign() {
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: nil,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .awaitingCampaign)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXShowsVerifiedNumericalPackageWithoutAuthorizingANC()
        throws {
        let package = try makePhysicalEvidencePackage()
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .numericalEvidenceAvailable)
        XCTAssertTrue(snapshot.digestIntegrityVerified)
        XCTAssertEqual(snapshot.curvePoints.count, 3)
        XCTAssertEqual(snapshot.initialPrimaryReductionDB, 5.0)
        XCTAssertEqual(snapshot.neighboringSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.returningPrimaryReductionDB, 4.6)
        XCTAssertEqual(snapshot.worstSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.worstFrequencyReductionDB, 1.0)
        XCTAssertEqual(snapshot.largestPrimaryBaselineDifferenceDB, 0.7)
        XCTAssertFalse(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXSuppressesTamperedPackageMetrics() throws {
        let package = try makePhysicalEvidencePackage(validDigest: false)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .invalidPackage)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertNil(snapshot.worstFrequencyReductionDB)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testTwoRoleReviewStillDoesNotAuthenticatePhysicalEvidence() throws {
        let package = try makePhysicalEvidencePackage()
        let packet = QuietZoneExternalReviewPacket(
            evidenceSHA256Hex: package.sha256Hex,
            reviews: [],
            numericalAcceptance: true,
            independentRolesAcknowledged: true
        )
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(snapshot.state, .roleReviewAcknowledged)
        XCTAssertTrue(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

}
