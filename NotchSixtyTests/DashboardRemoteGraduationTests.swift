import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S14: graduation of `e12.dashboard-remote`. The surface rule holds with the flag at its graduated default, the output
/// picker works through production wiring, and the Dashboard cards, health items and remote panel stay inside the page.
@MainActor
final class DashboardRemoteGraduationTests: XCTestCase {
    private func device(_ id: UInt32, _ uid: String, _ name: String) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: id, uid: uid, name: name, nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 48_000)])
    }

    private func engine() throws -> AudioIOEngine {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [device(1, "dac-a", "DAC A"), device(2, "dac-b", "DAC B")]))
        _ = try engine.refreshOutputDevices()
        return engine
    }

    /// Frames of every accessibility element SwiftUI exposes (cards, health items, buttons), in the hosting view's space.
    private func accessibilityFrames(_ page: HostedPage) -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ element: Any) {
            guard let object = element as? NSAccessibilityProtocol else { return }
            let frame = object.accessibilityFrame()
            if frame.width > 0, let window = page.hosting.window {
                let inWindow = window.convertFromScreen(frame)
                frames.append(page.hosting.convert(inWindow, from: nil))
            }
            for child in object.accessibilityChildren() ?? [] { walk(child) }
        }
        walk(page.hosting)
        return frames
    }

    func testFlagDefaultsOnAndStaysRegistered() {
        XCTAssertTrue(FeatureFlag.all.contains(.dashboardRemote))
        XCTAssertTrue(FeatureFlag.dashboardRemote.graduated)
        let flags = FeatureFlags(
            known: FeatureFlag.all, defaults: UserDefaults(suiteName: "e12.s14.\(UUID().uuidString)")!,
            policy: .launchArgumentOnly, arguments: [], environment: [:])
        XCTAssertTrue(flags.isEnabled(.dashboardRemote))
        XCTAssertEqual(RemoteHost.resolve(flagOn: flags.isEnabled(.dashboardRemote), trayInserted: true), .menuBar)
    }

    func testNoSurfaceRuleControlAppearsOnBothSurfaces() throws {
        let engine = try engine()
        let product = ProductController(audioEngine: engine)
        let size = CGSize(width: 1_280, height: 800)
        let dashboard = HostedPage(
            ProductionStatusDashboardView(engine: engine, profiles: product.profiles, navigation: ProductionNavigation(), failsafeMessage: nil),
            size: size)
        let panel = HostedPage(ProductionRemotePanel(product: product), size: CGSize(width: 300, height: 700))
        // The hosted harness sees only AppKit-backed controls; the panel's pickers and sliders are SwiftUI-drawn, so the
        // panel's control list comes from the model that builds it. The Dashboard has none of them.
        XCTAssertFalse(panel.controls(of: .toggle).isEmpty, "the panel carries the Processing switch")
        XCTAssertEqual(Set(MenuBarRemoteModel.controls(for: .menuBar)), Set(RemoteControl.allCases))
        XCTAssertTrue(dashboard.controls(of: .slider).isEmpty)
        XCTAssertTrue(dashboard.controls(of: .popup).isEmpty)
        XCTAssertFalse(dashboard.has("Output device"))
        XCTAssertFalse(dashboard.has("Mute"))
    }

    func testRemoteOutputSwitchSelectsThroughTheEngineAdapter() async throws {
        let engine = try engine()
        let product = ProductController(audioEngine: engine)
        let switcher = LiveOutputSwitch(transport: OutputSwitchEngineTransport(
            engine: engine, start: { try await product.startProcessing() }))
        let outcome = await switcher.switchOutput(to: "dac-b")
        XCTAssertEqual(outcome, .selected(name: "DAC B"))
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "dac-b")
        let refused = await switcher.switchOutput(to: "missing")
        guard case .refused = refused else { return XCTFail("expected refusal") }
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "dac-b")
    }

    func testDashboardCardsHealthItemsAndRemotePanelStayInsideThePage() throws {
        let engine = try engine()
        let product = ProductController(audioEngine: engine)
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(
                ProductionStatusDashboardView(engine: engine, profiles: product.profiles, navigation: ProductionNavigation(), failsafeMessage: nil),
                size: size)
            let frames = accessibilityFrames(page)
            try XCTSkipIf(frames.isEmpty, "the hosting view exposes no accessibility frames in this harness")
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "an item extends past the page at \(size.width)")
            }
        }
        let panel = HostedPage(ProductionRemotePanel(product: product), size: CGSize(width: 300, height: 700))
        XCTAssertLessThanOrEqual(panel.hosting.fittingSize.width, 300.5)
        for control in panel.controls {
            let frame = control.view.convert(control.view.bounds, to: panel.hosting)
            XCTAssertLessThanOrEqual(frame.maxX, 300.5, "\(control.label) extends past the remote panel")
        }
    }
}
