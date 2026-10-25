import XCTest
@testable import NotchSixty

@MainActor
final class ProductionSystemAreaTests: XCTestCase {
    func testFlagOffSidebarIsUnchanged() {
        let groups = ProductionSection.sidebarGroups(systemArea: false)
        XCTAssertEqual(groups.map(\.title), ["Playback", "System", "Tools", "Extensions"])
        XCTAssertEqual(groups[1].sections, ProductionSection.systemGroup)
        XCTAssertEqual(groups[2].sections, ProductionSection.tools)
        XCTAssertFalse(groups.flatMap(\.sections).contains(.system))
    }

    func testFlagOnSidebarHasOneSystemRowAndRoomAdvisorMoved() {
        let groups = ProductionSection.sidebarGroups(systemArea: true)
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

    func testEverySectionIsReachableWithFlagOn() {
        let sidebar = Set(ProductionSection.sidebarGroups(systemArea: true).flatMap(\.sections))
        for section in ProductionSection.allCases where section != .dashboard {
            if ProductionSection.developerTools.contains(section) { continue }
            let reachable = sidebar.contains(section.systemAreaDestination.section)
            XCTAssertTrue(reachable, "\(section)")
        }
    }

    func testNavigateLandsOnTheRightTab() {
        let navigation = ProductionNavigation()
        navigation.navigate(to: .roomCorrection, systemArea: true)
        XCTAssertEqual(navigation.selection, .system)
        XCTAssertEqual(navigation.systemTab, .calibrate)
        XCTAssertEqual(navigation.calibrateSection, .correction)
        navigation.navigate(to: .measurementLab, systemArea: true)
        XCTAssertEqual(navigation.systemTab, .measure)
        navigation.navigate(to: .equalizer, systemArea: true)
        XCTAssertEqual(navigation.selection, .equalizer)
    }

    func testNavigateWithFlagOffKeepsOldSection() {
        let navigation = ProductionNavigation()
        navigation.navigate(to: .roomCorrection, systemArea: false)
        XCTAssertEqual(navigation.selection, .roomCorrection)
        XCTAssertEqual(navigation.systemTab, .overview)
    }

    func testRoomCorrectionHasItsOwnIcon() {
        XCTAssertNotEqual(
            ProductionSection.roomCorrection.systemImage,
            ProductionSection.measurementLab.systemImage
        )
    }

    func testFlagIsRegisteredAndOffByDefault() {
        XCTAssertTrue(FeatureFlag.all.contains(.guidedSetup))
        XCTAssertFalse(FeatureFlag.guidedSetup.defaultEnabled)
        XCTAssertEqual(FeatureFlag.guidedSetup.id, "e12.guided-setup")
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
