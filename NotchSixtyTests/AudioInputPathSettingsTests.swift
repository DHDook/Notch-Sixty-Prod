import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

@MainActor
final class AudioInputPathSettingsTests: XCTestCase {
    private func model(_ status: DriverStatus, url: URL? = URL(string: "https://example.invalid/driver"),
                       opened: @escaping (URL) -> Void = { _ in },
                       switched: @escaping (AudioInputPath) -> Void = { _ in }) -> AudioInputPathModel {
        AudioInputPathModel(probe: { status }, downloadURL: url, openURL: opened, onSwitch: switched)
    }

    func testEachStatusHasTextAndActions() {
        let cases: [(DriverStatus, String, Bool, Bool)] = [
            (.notInstalled, "not installed", true, false),
            (.installed(version: 1), "installed", false, true),
            (.needsUpdate(version: 0), "needs an update", true, false),
            (.unknownVersion(99), "Unknown driver version", true, false),
            (.inUse(version: 1), "in use", false, true),
            (.leaseRefused(-1), "refused", true, false),
        ]
        for (status, text, download, canSwitch) in cases {
            let p = AudioInputPathPresentation(status: status)
            XCTAssertTrue(p.headline.localizedCaseInsensitiveContains(text), "\(status)")
            XCTAssertFalse(p.detail.isEmpty)
            XCTAssertEqual(p.actions.contains(.openDownloadPage), download, "\(status)")
            XCTAssertTrue(p.actions.contains(.recheck))
            XCTAssertEqual(p.canSwitchToDriver, canSwitch, "\(status)")
        }
    }

    func testSwitchRefusedWhenDriverUnusable() {
        var switched: [AudioInputPath] = []
        let m = model(.notInstalled, switched: { switched.append($0) })
        m.select(.virtualDriver)
        XCTAssertEqual(m.selectedPath, .processTap)
        XCTAssertTrue(switched.isEmpty)
    }

    func testSwitchBothWaysWhenUsable() {
        var switched: [AudioInputPath] = []
        let m = model(.installed(version: 1), switched: { switched.append($0) })
        m.select(.virtualDriver)
        m.select(.processTap)
        XCTAssertEqual(switched, [.virtualDriver, .processTap])
    }

    func testDriverDisappearingReturnsSelectionToTapDisplay() {
        var status = DriverStatus.installed(version: 1)
        let m = AudioInputPathModel(probe: { status }, downloadURL: nil, openURL: { _ in })
        m.select(.virtualDriver)
        status = .notInstalled
        m.refresh()
        XCTAssertEqual(m.status, .notInstalled)
        XCTAssertEqual(m.selectedPath, .processTap)
    }

    func testDownloadLinkOpensOnlyWhenPublished() {
        var opened: [URL] = []
        let linked = model(.notInstalled, opened: { opened.append($0) })
        linked.openDownloadPage()
        XCTAssertEqual(opened.count, 1)
        let unlinked = model(.notInstalled, url: nil, opened: { opened.append($0) })
        XCTAssertFalse(unlinked.canOpenDownloadPage)
        unlinked.openDownloadPage()
        XCTAssertEqual(opened.count, 1)
    }

    func testCrashWarningMentionsActiveSpeakers() {
        XCTAssertTrue(AudioInputPathPresentation.crashWarning.contains("active speakers"))
    }

    private func assertFits(_ status: DriverStatus, width: CGFloat, height: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        let page = HostedPage(
            ScrollView { AudioInputPathSettingsSection(model: model(status)).padding(18) }
                .productionCompactToggleStyle(),
            size: CGSize(width: width, height: height))
        let controls = page.controls.filter { [.toggle, .button].contains($0.kind) }
        XCTAssertFalse(controls.isEmpty, "no controls at \(width): \(page.outline)", file: file, line: line)
        for control in controls {
            let frame = control.view.convert(control.view.bounds, to: page.hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.title) left of page", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(control.title) past page width \(width)", file: file, line: line)
        }
    }

    func testSectionFitsAtBothSizesForEveryStatus() {
        let statuses: [DriverStatus] = [.notInstalled, .installed(version: 1), .needsUpdate(version: 0),
                                        .unknownVersion(9), .inUse(version: 1), .leaseRefused(-1)]
        for status in statuses {
            assertFits(status, width: 1_280, height: 800)
            assertFits(status, width: 1_920, height: 1_000)
            assertFits(status, width: 520, height: 800)
        }
    }
}
