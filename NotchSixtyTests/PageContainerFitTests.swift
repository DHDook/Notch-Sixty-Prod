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
}
