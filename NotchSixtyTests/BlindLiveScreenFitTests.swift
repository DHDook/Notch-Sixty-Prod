import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// AGENTS.md section 13 (screen fit) for the Blind Listening page (E12 S27): hosted at 1,280 x 800 and 1,920 x 1,000, in
/// the setup state and the running state; every control lies inside the page width. The page is reached through
/// `ProductionBlindListeningWorkspace` with `e12.blind-listening` on.
@MainActor
final class BlindLiveScreenFitTests: XCTestCase {
    private let flags = FeatureFlags()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces graduated flags off")
        flags.setEnabled(true, for: .blindListening)
    }

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func assertInside(_ page: HostedPage, width: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let controls = page.controls.filter { [.popup, .segmented, .toggle, .textField, .button].contains($0.kind) }
        XCTAssertFalse(controls.isEmpty, "\(what) shows controls: \(page.outline)", file: file, line: line)
        for control in controls {
            let frame = control.view.convert(control.view.bounds, to: page.hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.label) starts left of the page (\(what))", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(control.label) \(control.title) ends past the page (\(what), \(width))", file: file, line: line)
        }
    }

    func testPageFitsAtBothReferenceSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blindfit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(ProductionBlindListeningWorkspace(engine: engine, profiles: profiles), size: size)
            assertInside(page, width: size.width, "setup")
            XCTAssertGreaterThanOrEqual(page.controls(of: .segmented).count, 1)
        }
    }

    func testRunningStateFitsAtBothReferenceSizes() throws {
        let bands = [EQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1, slope: .db12)]
        let player = BlindLiveComparisonTests.FakePlayer(current: ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(channelMode: .linked, editChannel: .linked, phaseMode: .minimumPhase, bypassed: false, linkedBands: bands),
            inputPreampDB: 0, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration()))
        let list = ComparisonCandidates.list(current: player.current, presets: [])
        for kind in [BlindComparisonService.Kind.abx, .preference] {
            let service = try BlindLiveComparison.makeService(player: player, a: list[0], b: list[1], kind: kind, trialCount: 12)
            for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
                let page = HostedPage(ScrollView { BlindLiveRunView(service: service, kind: kind, onClose: {}).padding(28) }, size: size)
                // SwiftUI buttons are not AppKit controls in the harness (G107), so the laid-out content width is checked.
                XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width, "running \(kind) wider than \(size.width)")
            }
        }
    }
}
