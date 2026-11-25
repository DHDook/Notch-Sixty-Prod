import XCTest
@testable import NotchSixty

/// E12 S8: simple and expert modes (G86, G88, G98).
@MainActor
final class InterfaceModeTests: XCTestCase {
    func testFlagIsRegisteredAndOffByDefault() {
        XCTAssertTrue(FeatureFlag.all.contains(.simpleExpertModes))
        XCTAssertFalse(FeatureFlag.simpleExpertModes.resolvedDefault)
    }

    func testFlagOffIsAlwaysExpert() {
        for stored in [nil, "simple", "expert", "junk"] {
            XCTAssertEqual(InterfaceMode.effective(stored: stored, flagEnabled: false), .expert)
        }
    }

    func testFlagOnReadsStoredChoiceAndDefaultsToSimple() {
        XCTAssertEqual(InterfaceMode.effective(stored: nil, flagEnabled: true), .simple)
        XCTAssertEqual(InterfaceMode.effective(stored: "junk", flagEnabled: true), .simple)
        XCTAssertEqual(InterfaceMode.effective(stored: "expert", flagEnabled: true), .expert)
    }

    func testSimpleSidebarKeepsOnlySystemAndHeadphones() {
        for design in [false, true] {
            let groups = ProductionSection.sidebarGroups(designLanguage: design)
            let filtered = InterfaceMode.simple.filtered(groups)
            let simple = Set(filtered.flatMap(\.sections))
            XCTAssertTrue(simple.isSubset(of: [.system, .headphones]), "\(simple)")
            XCTAssertTrue(simple.contains(.system))
            XCTAssertTrue(filtered.allSatisfy { !$0.sections.isEmpty })
            XCTAssertEqual(InterfaceMode.expert.filtered(groups), groups)
        }
    }

    func testSwitchingToSimpleSendsAHiddenPageToTheDashboard() {
        XCTAssertEqual(InterfaceMode.simple.landing(for: .equalizer), .dashboard)
        XCTAssertEqual(InterfaceMode.simple.landing(for: .activeAcoustics), .dashboard)
        XCTAssertEqual(InterfaceMode.simple.landing(for: .system), .system)
        XCTAssertEqual(InterfaceMode.expert.landing(for: .equalizer), .equalizer)
        XCTAssertNil(InterfaceMode.simple.landing(for: nil))
    }

    func testGraphDetailFollowsModeOnlyWhenFlagIsOn() throws {
        let rig = try OfflineSetupRig(rate: 48_000, seats: 3, outputChannels: 2)
        defer { rig.tearDown() }
        let model = rig.model
        model.applyInterfaceMode(.expert, modesEnabled: false)
        XCTAssertEqual(model.graphDetail, .simple, "flag off leaves the setup flow's own switch alone")
        model.applyInterfaceMode(.expert, modesEnabled: true)
        XCTAssertEqual(model.graphDetail, .expert)
        model.applyInterfaceMode(.simple, modesEnabled: true)
        XCTAssertEqual(model.graphDetail, .simple)
    }

    func testCorrectionLimitOverrideIsClampedAndFeedsTheLimit() throws {
        let rig = try OfflineSetupRig(rate: 48_000, seats: 3, outputChannels: 2)
        defer { rig.tearDown() }
        let model = rig.model
        model.verdictsEnabled = true
        XCTAssertEqual(model.correctionLimitHz, SystemSetupCorrectionLimit.defaultHz)
        model.setCorrectionLimitOverride(500)
        XCTAssertEqual(model.correctionLimitHz, 500)
        model.setCorrectionLimitOverride(5_000)
        XCTAssertEqual(model.correctionLimitHz, 1_000)
        model.setCorrectionLimitOverride(10)
        XCTAssertEqual(model.correctionLimitHz, 60)
        model.setCorrectionLimitOverride(.nan)
        XCTAssertEqual(model.correctionLimitHz, SystemSetupCorrectionLimit.defaultHz)
    }

    func testSettingsOffersInterfaceCardFirstOnlyWhenAsked() {
        XCTAssertEqual(SettingsTab.general.cardTitles(offersDeveloperSwitch: false).first, "Appearance")
        XCTAssertEqual(
            SettingsTab.general.cardTitles(offersDeveloperSwitch: false, offersInterfaceMode: true).first, "Interface")
    }
}
