import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E34 S3b, AGENTS.md section 13: the Active Acoustics page (every tab) and the Settings page (every tab) on the shared
/// design parts with `e34.design-language` on, hosted at 1,280 x 800 and 1,920 x 1,000; every control lies inside the page.
@MainActor
final class ActiveAcousticsDesignFitTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces graduated flags off")
        let flags = FeatureFlags()
        flags.setEnabled(true, for: .designLanguage)
        flags.setEnabled(true, for: .activeAcousticsPage)
    }

    override func tearDown() {
        FeatureFlags().resetOverrides()
        super.tearDown()
    }

    private let sizes = [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)]

    func testEveryActiveAcousticsTabFitsWithTheDesignLanguageOn() {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        for tab in ActiveAcousticsTab.allCases {
            for size in sizes {
                let page = HostedPage(ProductionActiveAcousticsWorkspace(
                    engine: engine, ambient: product.ambientCompensation, quietZone: product.activeQuietZone,
                    adaptiveQuietZone: product.adaptiveQuietZone, feedForwardSurvey: product.feedForwardSurvey,
                    feedForwardShadow: product.feedForwardShadow, feedForwardArming: product.feedForwardArming,
                    mimoTreatment: product.mimoTreatment, microphone: product.calibration,
                    projects: product.roomCorrectionProjects, initialTab: tab), size: size)
                for control in page.controls {
                    let frame = control.view.convert(control.view.bounds, to: page.hosting)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(tab.title) \(control.label) left of the page")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(tab.title) \(control.label) passes \(size.width)")
                }
            }
        }
    }

    func testEverySettingsTabFitsWithTheDesignLanguageOn() throws {
        let suite = "e34s3b-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AudioIOEngine()
        let product = ProductController(audioEngine: engine)
        let flags = FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .storedOverrides, arguments: [], environment: [:])
        flags.setEnabled(true, for: .settingsPage)
        let view = ProductionSettingsView(
            preferences: ApplicationPreferences(defaults: defaults), product: product, featureFlags: flags)
        for size in sizes {
            for tab in SettingsTab.allCases {
                let page = HostedPage(view.tabCards(tab).padding(DesignSpacing.xl.pt), size: size)
                for control in page.controls {
                    let frame = control.view.convert(control.view.bounds, to: page.hosting)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(tab.title): \(control.searchText) at \(size.width)")
                }
            }
        }
    }
}
