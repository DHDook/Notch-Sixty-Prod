import SwiftUI
import XCTest
@testable import NotchSixty

final class DesignLanguageTests: XCTestCase {
    func testDecibelFormat() {
        XCTAssertEqual(DesignFormat.db(-6.04), "\u{2212}6.0 dB")
        XCTAssertEqual(DesignFormat.db(3.5, signed: true), "+3.5 dB")
        XCTAssertEqual(DesignFormat.db(3.5), "3.5 dB")
        XCTAssertEqual(DesignFormat.db(-0.01, signed: true), "0.0 dB")
        XCTAssertEqual(DesignFormat.db(.nan), "\u{2013} dB")
    }

    func testFrequencyFormat() {
        XCTAssertEqual(DesignFormat.hz(63), "63 Hz")
        XCTAssertEqual(DesignFormat.hz(999.4), "999 Hz")
        XCTAssertEqual(DesignFormat.hz(1000), "1 kHz")
        XCTAssertEqual(DesignFormat.hz(1250), "1.25 kHz")
        XCTAssertEqual(DesignFormat.hz(20000), "20 kHz")
        XCTAssertEqual(DesignFormat.hz(384000), "384 kHz")
    }

    func testMillisecondAndPercentFormat() {
        XCTAssertEqual(DesignFormat.ms(12.5), "12.5 ms")
        XCTAssertEqual(DesignFormat.ms(-2, signed: true), "\u{2212}2.0 ms")
        XCTAssertEqual(DesignFormat.percent(0.5), "50 %")
        XCTAssertEqual(DesignFormat.percent(0.05, signed: true), "+5 %")
    }

    func testEveryStatusLevelHasIconAndLabel() {
        XCTAssertEqual(StatusLevel.allCases.count, 4)
        XCTAssertEqual(Set(StatusLevel.allCases.map(\.iconName)).count, 4)
        XCTAssertEqual(Set(StatusLevel.allCases.map(\.label)).count, 4)
        for level in StatusLevel.allCases {
            XCTAssertFalse(level.iconName.isEmpty)
            XCTAssertFalse(level.label.isEmpty)
        }
    }

    func testValuesBothStyles() {
        for style in [DesignStyle.current, .redesigned] {
            for type in DesignType.allCases {
                XCTAssertGreaterThanOrEqual(type.size(style), DesignType.minimumSize)
            }
            let radii = DesignRadius.allCases.map { $0.value(style) }
            XCTAssertEqual(radii, radii.sorted())
            XCTAssertEqual(Set(radii).count, 3)
            let steps = DesignSpacing.allCases.map { $0.value(style) }
            XCTAssertEqual(steps, steps.sorted())
            XCTAssertGreaterThan(DesignType.body.size(style), DesignType.caption.size(style) - 1)
        }
    }

    @MainActor
    func testComponentsBuildWithFlagOnAndOff() {
        for style in [DesignStyle.current, .redesigned] {
            _ = DesignCard(style: style) { Text("x") }.body
            _ = DesignPageHeader(title: "t", status: .good, style: style).body
            for level in StatusLevel.allCases { _ = DesignStatusBadge(level: level, style: style).body }
            for kind in DesignStateKind.allCases { _ = DesignStateView(kind: kind, title: "t", style: style).body }
        }
        for role in DesignButtonRole.allCases { _ = DesignButton(title: "b", systemImage: nil, role: role) {}.body }
    }

    func testActiveStyleFollowsFlag() {
        let expected: DesignStyle = FeatureFlags.isEnabledProcessWide(.designLanguage) ? .redesigned : .current
        XCTAssertEqual(DesignStyle.active, expected)
    }

    func testNearestSpacingAndRadiusMapping() {
        XCTAssertNil(DesignSpacing.nearest(0))
        XCTAssertEqual(DesignSpacing.nearest(3), .xs)
        XCTAssertEqual(DesignSpacing.nearest(6), .s)
        XCTAssertEqual(DesignSpacing.nearest(10), .m)
        XCTAssertEqual(DesignSpacing.nearest(14), .l)
        XCTAssertEqual(DesignSpacing.nearest(18), .l)
        XCTAssertEqual(DesignSpacing.nearest(22), .xl)
        XCTAssertEqual(DesignRadius.nearest(8), .small)
        XCTAssertEqual(DesignRadius.nearest(12), .medium)
        XCTAssertEqual(DesignRadius.nearest(16), .medium)
        XCTAssertEqual(DesignRadius.nearest(18), .large)
        XCTAssertEqual(DesignRadius.nearest(22), .large)
    }

    func testSurfaceOpacityAndLevelFormat() {
        XCTAssertEqual(DesignSurface.opacity(.current), 0.22, accuracy: 1e-9)
        XCTAssertGreaterThan(DesignSurface.opacity(.redesigned), DesignSurface.opacity(.current))
        XCTAssertEqual(DesignFormat.level(-23.04, unit: "LUFS"), "\u{2212}23.0 LUFS")
        XCTAssertEqual(DesignFormat.level(-1, unit: "dBTP"), "\u{2212}1.0 dBTP")
        XCTAssertEqual(DesignFormat.hz(44100), "44.1 kHz")
        XCTAssertEqual(DesignFormat.hz(352800), "352.8 kHz")
    }

    func testModifiersBuildWithFlagOnAndOff() {
        for style in [DesignStyle.current, .redesigned] {
            let view = Text("x").designSurface(.large).designPanel().designTint(.green).designGlass()
            XCTAssertNotNil(view)
            XCTAssertGreaterThan(DesignSpacing.xl.value(style), DesignSpacing.l.value(style) - 1)
        }
    }

    /// E34 S2b: the page title (window title and Help link) follows the sidebar row's name, so
    /// the System page is "Speakers & Room" with the flag on and "System" with it off.
    func testPageTitlesFollowSidebarNamesWithFlagOnAndOff() {
        for section in ProductionSection.allCases {
            XCTAssertEqual(section.sidebarTitle(designLanguage: false), section.title)
            let on = section.sidebarTitle(designLanguage: true)
            XCTAssertEqual(on, section == .system ? "Speakers & Room" : section.title)
            XCTAssertFalse(on.isEmpty)
        }
    }

    /// E34 S2b: the Dashboard's shared steps resolve to distinct, ordered values in both styles.
    func testDashboardSpacingStepsAreOrderedInBothStyles() {
        for style in [DesignStyle.current, .redesigned] {
            let steps = [DesignSpacing.xs, .s, .m, .l, .xl].map { $0.value(style) }
            XCTAssertEqual(steps, steps.sorted())
            XCTAssertEqual(Set(steps).count, steps.count)
            XCTAssertGreaterThanOrEqual(DesignType.caption.size(style), DesignType.minimumSize)
        }
    }
}
