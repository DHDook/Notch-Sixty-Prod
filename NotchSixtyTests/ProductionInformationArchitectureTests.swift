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

}
