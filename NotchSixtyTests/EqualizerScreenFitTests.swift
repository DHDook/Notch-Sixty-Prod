import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// AGENTS.md section 13 (screen fit): the Equalizer page hosted at 1,280 x 800 and at 1,920 x 1,000 (a 1,920 x 1,080
/// display minus the menu bar and Dock) lays every control inside the page width, so nothing needs horizontal scrolling.
@MainActor
final class EqualizerScreenFitTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces e33.page-enhancements off")
    }

    private let flags = FeatureFlags()

    override func setUp() {
        super.setUp()
        flags.setEnabled(true, for: .eqPageEnhancements)
    }

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func assertFits(width: CGFloat, height: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let engine = AudioIOEngine()
        let page = HostedPage(
            ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)),
            size: CGSize(width: width, height: height))
        let controls = page.controls.filter { [.popup, .segmented, .toggle, .textField, .button].contains($0.kind) }
        XCTAssertFalse(controls.isEmpty, "the page shows controls", file: file, line: line)
        for control in controls {
            let frame = control.view.convert(control.view.bounds, to: page.hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.label) starts left of the page at \(width)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(control.label) \(control.title) ends past the page width at \(width)", file: file, line: line)
        }
    }

    /// A page width of about 1,100 pt (the narrow end of the other pages) and 1,280 pt: nothing runs past the edge, and the
    /// gain row and mode bar reflow rather than truncate.
    func testEveryControlFitsAt1100x800() { assertFits(width: 1_100, height: 800) }

    func testEveryControlFitsAt1280x800() { assertFits(width: 1_280, height: 800) }

    func testEveryControlFitsAt1920x1000() { assertFits(width: 1_920, height: 1_000) }
}
