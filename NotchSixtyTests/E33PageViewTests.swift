import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E33 S11b: the real SwiftUI pages, hosted in a window at their default size, with `e33.page-enhancements` off and on.
/// There is no UI test target and the accessibility tree is empty without an assistive client, so these tests check
/// what a hosted page does show: it builds and lays out in both states, draws something, the flag changes the page, and the
/// flag-off page is the same page every time (G1, G63, G65, G9, G10, G13, G20 at the level of "the page with the flag on
/// builds and draws"; row-by-row content is covered by the model tests named in each gap).
@MainActor
final class E33PageViewTests: XCTestCase {
    /// E33 S11d: the page enhancements are graduated, so the nightly flags-off matrix (which forces every graduated
    /// flag off, and off wins over a test override) cannot run these flag-on cases; the flags-off path is covered by
    /// the rest of the suite under the matrix and by the flag-off cases here in the normal run.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces e33.page-enhancements off")
    }

    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    /// The bitmap of `view` hosted at `size`, after layout and a short run loop turn.
    private func snapshot<V: View>(_ view: V, size: CGSize = CGSize(width: 1_180, height: 820)) throws -> (bytes: Data, fitting: CGSize) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        window.contentView = nil
        return (data, hosting.fittingSize)
    }

    private func pages(_ engine: AudioIOEngine) -> [(String, AnyView)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("e33-pages-\(UUID().uuidString)")
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        return [
            ("Dynamics", AnyView(ProductionDynamicsView(engine: engine))),
            ("Equalizer", AnyView(ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)))),
            ("Meters", AnyView(ProductionMetersView(engine: engine, assistant: HeadroomAssistantController(engine: engine, profiles: profiles, abComparison: ContentABComparisonController(profiles: profiles))))),
        ]
    }

    func testTheFlagChangesEachPageAndFlagOffIsStable() throws {
        for name in ["Dynamics", "Equalizer", "Meters"] {
            // G107: also the "builds and draws in both states" check (one pass, not a second test).
            func shot(_ on: Bool) throws -> Data {
                flags.setEnabled(on, for: .eqPageEnhancements)
                let page = try XCTUnwrap(pages(AudioIOEngine()).first { $0.0 == name }).1
                let result = try snapshot(page)
                XCTAssertGreaterThan(result.bytes.count, 2_000, "\(name) draws something with the flag \(on)")
                XCTAssertGreaterThan(result.fitting.width, 0, name)
                XCTAssertGreaterThan(result.fitting.height, 0, name)
                return result.bytes
            }
            let off1 = try shot(false), off2 = try shot(false), on = try shot(true)
            XCTAssertEqual(off1, off2, "\(name): the flag-off page is the same page every time (G1)")
            XCTAssertNotEqual(off1, on, "\(name): the page reads the flag (G63, G65)")
        }
    }

    func testEqualizerFlagOffDrawsAtTheDefaultAndACompactSize() throws {
        flags.setEnabled(false, for: .eqPageEnhancements)
        let engine = AudioIOEngine()
        let compact = try snapshot(ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)),
                                   size: CGSize(width: 900, height: 640))
        let wide = try snapshot(ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)))
        XCTAssertGreaterThan(compact.bytes.count, 2_000)
        XCTAssertGreaterThan(wide.bytes.count, 2_000)
    }
}
