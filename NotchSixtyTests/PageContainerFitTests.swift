import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// AGENTS.md section 13 (screen fit): every sidebar page that uses the shared `ProductionPageContainer` is hosted at
/// 1,280 x 800, at about 1,700 wide (an Equalizer-sized window) and at 1,920 x 1,000. At each size nothing extends past the
/// page width, and the content fills the container: it starts at the shared leading padding and, up to the 1,500 pt
/// content limit, reaches the trailing padding, so a wide window shows no large empty side bands.
@MainActor
final class PageContainerFitTests: XCTestCase {
    private static let sizes = [CGSize(width: 1_280, height: 800), CGSize(width: 1_700, height: 900), CGSize(width: 1_920, height: 1_000)]

    private func pages() -> [(String, AnyView)] {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        return [
            ("Dashboard", AnyView(ProductionDashboardView(engine: engine))),
            ("Status dashboard", AnyView(ProductionStatusDashboardView(
                engine: engine, profiles: product.profiles, navigation: ProductionNavigation(), failsafeMessage: nil))),
            ("Meters", AnyView(ProductionMetersView(engine: engine, assistant: product.headroomAssistant))),
            ("Headphones", AnyView(ProductionHeadphoneWorkspace(
                engine: engine, profiles: product.profiles, calibration: product.multichannelCalibration))),
            ("Speaker calibration", AnyView(ProductionMultichannelCalibrationWorkspace(
                engine: engine, calibration: product.multichannelCalibration, microphone: product.calibration, profiles: product.profiles))),
            ("Measurement lab", AnyView(ProductionSpeakerMeasurementLabWorkspace(
                engine: engine, microphone: product.calibration, profiles: product.profiles,
                roomCorrectionProjects: product.roomCorrectionProjects, multichannelCalibration: product.multichannelCalibration))),
            ("Room correction", AnyView(ProductionRoomCorrectionWorkspace(
                engine: engine, calibration: product.calibration, projects: product.roomCorrectionProjects, profiles: product.profiles))),
            ("Room advisor", AnyView(ProductionRoomTreatmentAdvisorWorkspace(advisor: product.roomTreatmentAdvisor, profiles: product.profiles))),
            ("Blind listening", AnyView(ProductionBlindListeningWorkspace(engine: engine))),
            ("Acoustic research", AnyView(ProductionOptionalAudioResearchWorkspace(engine: engine))),
            ("Hardware acceptance", AnyView(ProductionHardwareAcceptanceWorkspace(
                engine: engine, profiles: product.profiles, acceptance: product.hardwareAcceptance))),
        ]
    }

    func testEveryContainerPageFitsAtThreeSizes() {
        for (name, view) in pages() {
            for size in Self.sizes {
                let page = HostedPage(view, size: size)
                let frames = page.controls.map { $0.view.convert($0.view.bounds, to: page.hosting) }
                for (control, frame) in zip(page.controls, frames) {
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name): \(control.label) starts left of the page at \(size.width)")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(name): \(control.label) ends past the page at \(size.width)")
                }
            }
        }
    }

    func testContainerAlignsLeadingAndFillsUpToTheLimit() {
        let padding = DesignSpacing.xl.pt
        let limit = ProductionPageContainer<EmptyView>.maxContentWidth
        let inset: CGFloat = 7 // the AppKit segmented control's own bounds inset
        XCTAssertEqual(limit, 1_500)
        for size in Self.sizes + [CGSize(width: 2_400, height: 1_000)] {
            let page = HostedPage(
                ProductionPageContainer {
                    HStack {
                        Picker("Lead", selection: .constant(0)) { Text("A").tag(0); Text("B").tag(1) }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                        Spacer()
                        Picker("Trail", selection: .constant(0)) { Text("A").tag(0); Text("B").tag(1) }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                    }
                },
                size: size)
            let frames = page.controls(of: .segmented).map { $0.view.convert($0.view.bounds, to: page.hosting) }
            XCTAssertEqual(frames.count, 2, "both probes are laid out at \(size.width)")
            guard frames.count == 2 else { continue }
            let lead = frames.map(\.minX).min() ?? -1, trail = frames.map(\.maxX).max() ?? -1
            XCTAssertEqual(lead, padding + inset, accuracy: 2, "content is aligned leading at \(size.width)")
            XCTAssertEqual(trail, min(size.width, limit) - padding - inset, accuracy: 2,
                           "content fills the container (no side band) at \(size.width)")
        }
    }

    // MARK: Dashboard

    /// Detail area of a window `size` wide and high: the sidebar (about 220 pt) and the title bar and toolbar (about 60 pt) are not page.
    private func detail(_ window: CGSize) -> CGSize { CGSize(width: window.width - 220, height: window.height - 60) }

    /// The Dashboard content height at a detail width, and (when `png` is set) a picture of it.
    private func dashboardHeight(detailWidth: CGFloat, png: String? = nil) throws -> CGFloat {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let banner = AnyView(SystemSetupEntryCard(availability: .offer, start: {}, openHeadphones: {}))
        let page = ProductionDashboardView(engine: engine, entryCard: banner).pageContent
            .padding(DesignSpacing.xl.pt)
            .frame(width: min(detailWidth, ProductionPageContainer<EmptyView>.maxContentWidth), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        let hosted = HostedPage(page, size: CGSize(width: detailWidth, height: 3_000))
        let height = hosted.hosting.fittingSize.height
        if let png {
            hosted.hosting.frame.size.height = height
            hosted.settle()
            let rep = try XCTUnwrap(hosted.hosting.bitmapImageRepForCachingDisplay(in: hosted.hosting.bounds))
            hosted.hosting.cacheDisplay(in: hosted.hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: png))
        }
        return height
    }

    func testDashboardFitsWithoutScrollingAtTheOwnerSizes() throws {
        for window in [CGSize(width: 1_700, height: 760), CGSize(width: 1_700, height: 900), CGSize(width: 1_920, height: 1_000)] {
            let viewport = detail(window)
            let height = try dashboardHeight(detailWidth: viewport.width,
                                             png: NSTemporaryDirectory() + "dash-\(Int(window.width))-\(Int(window.height)).png")
            XCTAssertLessThanOrEqual(height, viewport.height, "the Dashboard needs no vertical scrolling in a \(window.width) x \(window.height) window")
        }
    }

    func testDashboardScrollsInsteadOfClippingAtTheSmallSize() throws {
        let viewport = detail(CGSize(width: 1_280, height: 800))
        let height = try dashboardHeight(detailWidth: viewport.width)
        XCTAssertGreaterThan(height, 0)
        // The page is a ScrollView, so content taller than the viewport scrolls; nothing is cut off.
        let page = HostedPage(ProductionDashboardView(engine: AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))), size: viewport)
        XCTAssertFalse(page.hosting.subviews.isEmpty)
        XCTAssertGreaterThan(height, viewport.height, "at 1,280 x 800 the Dashboard is taller than the viewport and scrolls")
    }

    // MARK: Dynamics

    private func scrollFrames(_ page: HostedPage) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if v is NSScrollView { found.append(v.convert(v.bounds, to: page.hosting)) }
            v.subviews.forEach(walk)
        }
        walk(page.hosting)
        return found
    }

    func testDynamicsPanesFillThePageHeightAndWidth() {
        let padding = DesignSpacing.xl.pt
        for window in [CGSize(width: 1_280, height: 800), CGSize(width: 1_700, height: 900), CGSize(width: 1_920, height: 1_000)] {
            let size = detail(window)
            let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
            let page = HostedPage(ProductionDynamicsView(engine: engine), size: size)
            let frames = scrollFrames(page)
            XCTAssertGreaterThanOrEqual(frames.count, 2, "the list and the detail each scroll at \(window.width)")
            let list = frames.min { $0.minX < $1.minX }, detailPane = frames.max { $0.minX < $1.minX }
            for pane in [list, detailPane].compactMap({ $0 }) {
                XCTAssertEqual(pane.maxY, size.height - padding, accuracy: 2, "a Dynamics pane runs to the page bottom at \(window.width)")
            }
            XCTAssertEqual(list?.width ?? 0, 300, accuracy: 1, "the list keeps a fixed readable width at \(window.width)")
            XCTAssertEqual(detailPane?.maxX ?? 0, min(size.width, ProductionPageContainer<EmptyView>.maxContentWidth) - padding, accuracy: 2,
                           "the detail pane takes the rest of the width at \(window.width)")
        }
    }
}
