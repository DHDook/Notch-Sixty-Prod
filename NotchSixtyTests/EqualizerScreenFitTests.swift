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

    /// Owner feedback (about 1,680 wide, Bands panel about 480): the band controls fill one line instead of wrapping early.
    func testBandControlsShareARowAt1680() throws {
        let engine = AudioIOEngine()
        try engine.addEQBand(EQBand(frequencyHz: 1_000, q: 1.0))
        let page = HostedPage(
            ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)),
            size: CGSize(width: 1_680, height: 1_000))
        func frame(_ label: String) throws -> CGRect {
            let control = try XCTUnwrap(page.controls.first(where: { $0.kind == .textField && $0.label == label }), "\(label) is shown")
            return control.view.convert(control.view.bounds, to: page.hosting)
        }
        let frequency = try frame("Frequency"), gain = try frame("Gain"), q = try frame("Q")
        XCTAssertEqual(gain.midY, frequency.midY, accuracy: 6, "Gain shares the Frequency row")
        XCTAssertEqual(q.midY, frequency.midY, accuracy: 6, "Q shares the Frequency row")
    }

    /// The flow wraps only when the next control truly does not fit: five controls share one line when the card is wide
    /// enough, and break after the last one that fits when it is not.
    func testControlFlowWrapsOnlyWhenNeeded() {
        struct Probe: View {
            let width: CGFloat
            var body: some View {
                EQControlFlowLayout(spacing: 12, lineSpacing: 8) {
                    ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: 170, height: 24) }
                }
                .frame(width: width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        func lines(at width: CGFloat) -> Int {
            let host = NSHostingView(rootView: Probe(width: width))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
            let height = NSHostingView(rootView: EQControlFlowLayout(spacing: 12, lineSpacing: 8) {
                ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: 170, height: 24) }
            }.frame(width: width)).fittingSize.height
            return Int(((height + 8) / 32).rounded())
        }
        XCTAssertEqual(lines(at: 900), 1, "five 170 pt controls share one line at 900 pt")
        XCTAssertEqual(lines(at: 540), 2, "three fit across 540 pt, the rest wrap")
        XCTAssertEqual(lines(at: 170), 5, "one per line only when that is all that fits")
    }
}
