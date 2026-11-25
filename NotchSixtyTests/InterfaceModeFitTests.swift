import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S8, AGENTS.md section 13: the Correction step (with the expert limit slider) and the Settings Interface card,
/// hosted at 1,280 x 800 and 1,920 x 1,000, in simple and expert mode; every control lies inside the page.
@MainActor
final class InterfaceModeFitTests: XCTestCase {
    private let sizes = [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces graduated flags off")
        let flags = FeatureFlags()
        flags.setEnabled(true, for: .simpleExpertModes)
        flags.setEnabled(true, for: .setupFlow)
    }

    override func tearDown() {
        FeatureFlags().resetOverrides()
        super.tearDown()
    }

    func testCorrectionLimitControlIsExpertOnlyAndFitsBothScreens() throws {
        XCTAssertTrue(InterfaceMode.expert.showsCorrectionLimitControl(flagEnabled: true))
        XCTAssertFalse(InterfaceMode.simple.showsCorrectionLimitControl(flagEnabled: true))
        XCTAssertFalse(InterfaceMode.expert.showsCorrectionLimitControl(flagEnabled: false))
        let rig = try OfflineSetupRig(rate: 48_000, seats: 3, outputChannels: 2)
        defer { rig.tearDown() }
        rig.model.verdictsEnabled = true
        let limit = try XCTUnwrap(rig.model.correctionLimitHz)
        // Hosted SwiftUI sliders and buttons are not AppKit controls here, so the row's own ideal width is measured:
        // it must be narrower than the page, and the Correction step as a whole must host at both sizes.
        let row = SystemSetupCorrectionLimitControl(model: rig.model, limitHz: limit)
        let ideal = NSHostingView(rootView: row.fixedSize()).fittingSize.width
        XCTAssertGreaterThan(ideal, 0)
        for size in sizes {
            XCTAssertLessThanOrEqual(ideal + 2 * DesignSpacing.xl.pt, size.width, "limit row ideal width \(ideal)")
            for mode in InterfaceMode.allCases {
                let page = HostedPage(
                    SystemSetupCorrectionStep(model: rig.model)
                        .environment(\.interfaceMode, mode).padding(DesignSpacing.xl.pt),
                    size: size)
                for control in page.controls {
                    let frame = control.view.convert(control.view.bounds, to: page.hosting)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(mode) \(control.searchText) at \(size.width)")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(mode) \(control.searchText) at \(size.width)")
                }
            }
        }
    }

    func testSettingsInterfaceCardFits() throws {
        let suite = "e12s8-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let product = ProductController(audioEngine: AudioIOEngine())
        let flags = FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .storedOverrides, arguments: [], environment: [:])
        flags.setEnabled(true, for: .settingsPage)
        flags.setEnabled(true, for: .simpleExpertModes)
        let view = ProductionSettingsView(
            preferences: ApplicationPreferences(defaults: defaults), product: product, featureFlags: flags)
        for size in sizes {
            let page = HostedPage(view.tabCards(.general).padding(DesignSpacing.xl.pt), size: size)
            XCTAssertTrue(page.controls.contains { $0.items.contains("Expert") || $0.searchText.contains("Expert") },
                          "the Interface picker is on General at \(size.width)")
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.searchText) at \(size.width)")
            }
        }
    }
}
