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
}
