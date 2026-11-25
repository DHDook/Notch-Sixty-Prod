import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

@MainActor
final class SettingsTabsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "SettingsTabsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFlagIsRegisteredAndNotYetGraduated() {
        XCTAssertTrue(FeatureFlag.all.contains(.settingsPage))
        XCTAssertFalse(FeatureFlag.settingsPage.resolvedDefault)
    }

    func testFiveTabsInOrderWithTheirCards() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["General", "Volume", "Privacy", "Data", "About"])
        XCTAssertEqual(SettingsTab.volume.cardTitles(offersDeveloperSwitch: false), ["Volume & Feedback"])
        XCTAssertEqual(SettingsTab.privacy.cardTitles(offersDeveloperSwitch: false), ["Permissions"])
        XCTAssertEqual(
            SettingsTab.data.cardTitles(offersDeveloperSwitch: false),
            ["Backup & Restore", "Automatic Backups", "Reset & Erase"])
        let general = SettingsTab.general.cardTitles(offersDeveloperSwitch: false)
        XCTAssertEqual(general, ["Appearance", "App Presence", "Startup", "Presets", "Page Displays"])
        XCTAssertTrue(SettingsTab.general.cardTitles(offersDeveloperSwitch: true).contains("Developer Tools"))
        XCTAssertEqual(
            SettingsTab.about.cardTitles(offersDeveloperSwitch: true),
            ["About", "Licences", "Privacy Statement", "Help & Support"])
    }

    func testReleaseBuildOffersNoDeveloperSwitchAndIgnoresStoredValue() {
        XCTAssertFalse(DeveloperToolsPolicy.offersSwitch(policy: .launchArgumentOnly))
        XCTAssertTrue(DeveloperToolsPolicy.offersSwitch(policy: .storedOverrides))
        // A stored "on" from an older build is ignored in release.
        XCTAssertFalse(DeveloperToolsPolicy.isShown(
            stored: true, settingsPageEnabled: true, policy: .launchArgumentOnly, arguments: []))
        // The launch argument shows the menu in release.
        XCTAssertTrue(DeveloperToolsPolicy.isShown(
            stored: false, settingsPageEnabled: true, policy: .launchArgumentOnly,
            arguments: ["NotchSixty", DeveloperToolsPolicy.launchArgument]))
        // Debug builds keep the stored switch.
        XCTAssertTrue(DeveloperToolsPolicy.isShown(
            stored: true, settingsPageEnabled: true, policy: .storedOverrides, arguments: []))
        XCTAssertFalse(DeveloperToolsPolicy.isShown(
            stored: false, settingsPageEnabled: true, policy: .storedOverrides, arguments: []))
    }

    func testFlagOffKeepsTodaysDeveloperBehaviour() {
        XCTAssertTrue(DeveloperToolsPolicy.isShown(
            stored: true, settingsPageEnabled: false, policy: .launchArgumentOnly, arguments: []))
        XCTAssertFalse(DeveloperToolsPolicy.isShown(
            stored: false, settingsPageEnabled: false, policy: .launchArgumentOnly, arguments: []))
    }

    func testDisplayResetRemovesOnlyDisplayKeys() {
        let others = [
            PreferenceKeys.Application.appearance, PreferenceKeys.Application.showDeveloperTools,
            PreferenceKeys.abComparisonEnabled, PreferenceKeys.vuMetersEnabled,
            PreferenceKeys.quietZoneSurveys, "feature.e12.settings-page"
        ]
        for key in PageDisplayPreferences.keys { defaults.set("x", forKey: key) }
        for key in others { defaults.set("keep", forKey: key) }

        PageDisplayPreferences.reset(defaults)

        for key in PageDisplayPreferences.keys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        for key in others {
            XCTAssertEqual(defaults.string(forKey: key), "keep", key)
        }
    }

    func testDisplayKeysCoverMetersEqualizerAndEveryCurvePanel() {
        let keys = Set(PageDisplayPreferences.keys)
        XCTAssertTrue(keys.contains(PreferenceKeys.Meters.scaleFloorDB))
        XCTAssertTrue(keys.contains(PreferenceKeys.Equalizer.graphYRange))
        XCTAssertTrue(keys.contains(PreferenceKeys.Equalizer.programAnalyser))
        for source in GainReductionSource.allCases {
            XCTAssertTrue(keys.contains(PreferenceKeys.Dynamics.showTransferCurve(source.rawValue)))
        }
        XCTAssertEqual(keys.count, PageDisplayPreferences.keys.count)
    }

    func testAboutContentHasLicencesAndPrivacyStatement() throws {
        let licences = try XCTUnwrap(SettingsAboutContent.licenceText(bundle: Bundle(for: FeatureFlags.self)))
        XCTAssertTrue(licences.contains("libmysofa"))
        XCTAssertFalse(SettingsAboutContent.privacyStatement.isEmpty)
        XCTAssertTrue(SettingsAboutContent.privacyStatement.contains("does not send"))
    }

    func testAboutPageFitsTheMinimumSettingsWidth() {
        let view = SettingsAboutView(version: "1.0", build: "1", onCopyDiagnostics: {}, licenceText: "text")
            .frame(width: 520)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 520.5)
    }
}
