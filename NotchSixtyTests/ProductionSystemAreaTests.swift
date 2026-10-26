import XCTest
@testable import NotchSixty

@MainActor
final class ProductionSystemAreaTests: XCTestCase {
    func testSidebarHasOneSystemRowAndRoomAdvisorMoved() {
        let groups = ProductionSection.sidebarGroups()
        XCTAssertEqual(groups.map(\.title), ["Playback", "System", "Tools", "Extensions"])
        XCTAssertEqual(groups[1].sections, [.system, .headphones, .activeAcoustics])
        XCTAssertEqual(groups[2].sections, [.blindListening])
    }

    func testEveryOldSectionMapsToOneDestination() {
        let expected: [ProductionSection: (ProductionSystemTab, ProductionCalibrateSection?)] = [
            .speakers: (.speakers, nil),
            .roomAdvisor: (.room, nil),
            .measurementLab: (.measure, nil),
            .speakerCalibration: (.calibrate, .alignment),
            .roomCorrection: (.calibrate, .correction),
            .system: (.overview, nil),
        ]
        for (section, target) in expected {
            let destination = section.systemAreaDestination
            XCTAssertEqual(destination.section, .system, "\(section)")
            XCTAssertEqual(destination.systemTab, target.0, "\(section)")
            XCTAssertEqual(destination.calibrateSection, target.1, "\(section)")
        }
        for section in [ProductionSection.dashboard, .headphones, .activeAcoustics, .blindListening, .equalizer] {
            XCTAssertEqual(section.systemAreaDestination, ProductionDestination(section: section))
        }
    }

    func testEverySectionIsReachable() {
        let sidebar = Set(ProductionSection.sidebarGroups().flatMap(\.sections))
        for section in ProductionSection.allCases where section != .dashboard {
            if ProductionSection.developerTools.contains(section) { continue }
            let reachable = sidebar.contains(section.systemAreaDestination.section)
            XCTAssertTrue(reachable, "\(section)")
        }
    }

    func testNavigateLandsOnTheRightTab() {
        let navigation = ProductionNavigation()
        navigation.navigate(to: .roomCorrection)
        XCTAssertEqual(navigation.selection, .system)
        XCTAssertEqual(navigation.systemTab, .calibrate)
        XCTAssertEqual(navigation.calibrateSection, .correction)
        navigation.navigate(to: .measurementLab)
        XCTAssertEqual(navigation.systemTab, .measure)
        navigation.navigate(to: .equalizer)
        XCTAssertEqual(navigation.selection, .equalizer)
    }

    func testRoomCorrectionHasItsOwnIcon() {
        XCTAssertNotEqual(
            ProductionSection.roomCorrection.systemImage,
            ProductionSection.measurementLab.systemImage
        )
    }

    func testOverviewStatusForNoUnverifiedAndVerifiedCalibration() {
        XCTAssertEqual(
            SystemCalibrationStatus.resolve(summary: nil, verifiedDesignID: UUID()),
            .notCalibrated
        )
        let design = UUID()
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(), activeDesignID: design, designDate: Date(timeIntervalSince1970: 0),
            positionCount: 3, correctionLowHz: 20, correctionHighHz: 300, targetName: "Flat",
            smoothingOctaves: 1.0 / 6, maximumBoostDB: 3, maximumCutDB: 12,
            recommendedHeadroomDB: 6, algorithmVersion: "t"
        )
        XCTAssertEqual(
            SystemCalibrationStatus.resolve(summary: summary, verifiedDesignID: nil),
            .unverified(summary)
        )
        XCTAssertEqual(
            SystemCalibrationStatus.resolve(summary: summary, verifiedDesignID: UUID()),
            .unverified(summary)
        )
        XCTAssertEqual(
            SystemCalibrationStatus.resolve(summary: summary, verifiedDesignID: design),
            .verified(summary)
        )
    }
}
