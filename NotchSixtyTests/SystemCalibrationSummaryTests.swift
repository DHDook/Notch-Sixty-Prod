import AppKit
import PDFKit
import XCTest
@testable import NotchSixty

/// E12 S17 (G20 summary part): the calibration summary's content, its PDF and its page fit.
@MainActor
final class SystemCalibrationSummaryTests: XCTestCase {
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func correction(design: UUID) -> RoomCorrectionCalibrationSummary {
        RoomCorrectionCalibrationSummary(
            projectID: UUID(), activeDesignID: design, designDate: Date(timeIntervalSince1970: 1_000),
            positionCount: 2, correctionLowHz: 20, correctionHighHz: 300, targetName: "Warm",
            smoothingOctaves: 1.0 / 6, maximumBoostDB: 3, maximumCutDB: 12,
            recommendedHeadroomDB: 6, algorithmVersion: "t")
    }

    private func inputs(design: UUID = UUID(), verified: Bool = true) -> SystemCalibrationSummaryInputs {
        var i = SystemCalibrationSummaryInputs(generated: Date(timeIntervalSince1970: 2_000))
        i.profileName = "Lounge"
        i.outputName = "Studio DAC"
        i.arrangement = "2 speakers and 1 subwoofer."
        i.microphoneKnown = true
        i.microphoneName = "UMIK-1"
        i.calibrationFile = "umik.txt"
        i.measurementDate = Date(timeIntervalSince1970: 500)
        i.seats = [
            SystemCalibrationSeat(
                name: "Main seat", included: true,
                verdict: MeasurementVerdict(level: .good, reason: "Clean sweep."),
                rmsErrorBeforeDB: 6.2, rmsErrorAfterDB: 1.4),
            SystemCalibrationSeat(name: "Sofa", included: false, verdict: nil),
        ]
        i.alignmentLines = ["Left: +1.5 dB, 0.30 ms"]
        i.bassLine = "Crossover at 80 Hz, LR4."
        i.correction = correction(design: design)
        if verified {
            i.verifiedDesignID = design
            i.verifiedDate = Date(timeIntervalSince1970: 1_500)
        }
        return i
    }

    private func text(_ s: SystemCalibrationSummary) -> String { s.plainText }

    func testVerifiedSummaryCarriesEveryStoredValue() {
        let s = SystemCalibrationSummary.make(inputs())
        let t = text(s)
        XCTAssertEqual(s.status, "Calibrated and verified")
        XCTAssertTrue(s.notices.isEmpty)
        for expected in ["Lounge", "Studio DAC", "UMIK-1", "umik.txt", "1 of 2 used", "Left: +1.5 dB, 0.30 ms",
                         "Crossover at 80 Hz", "Warm", "20 to 300 Hz", "3.0 dB boost, 12.0 dB cut",
                         "Clean sweep.", "6.2 dB before, 1.4 dB after", "Sofa", "left out", "Passed on"] {
            XCTAssertTrue(t.contains(expected), "missing \(expected) in\n\(t)")
        }
    }

    func testUnverifiedAndNoCorrectionSaySo() {
        let unverified = SystemCalibrationSummary.make(inputs(verified: false))
        XCTAssertEqual(unverified.status, "Calibrated, not verified")
        XCTAssertTrue(unverified.notices.contains { $0.contains("no passing verification") })
        XCTAssertTrue(text(unverified).contains("Not verified"))

        let none = SystemCalibrationSummary.make(SystemCalibrationSummaryInputs(generated: Date()))
        XCTAssertEqual(none.status, "Not calibrated")
        XCTAssertTrue(none.notices.contains { $0.contains("no room correction") })
        XCTAssertTrue(text(none).contains("Microphone: Not recorded"))
    }

    func testOutOfDateNamesTheReason() {
        var i = inputs()
        i.outOfDate = [.output, .moved]
        let s = SystemCalibrationSummary.make(i)
        XCTAssertTrue(s.status.hasSuffix("out of date"))
        XCTAssertTrue(s.notices.contains { $0.contains("the output device changed") && $0.contains("you said something moved") })
    }

    func testNoCalibrationFileStatesTheLimit() {
        var i = inputs()
        i.calibrationFile = nil
        i.correctionLimitHz = 500
        let t = text(SystemCalibrationSummary.make(i))
        XCTAssertTrue(t.contains("Calibration file: None"))
        XCTAssertTrue(t.contains("stops at 500 Hz"))
    }

    func testPDFIsNonEmptyHasTheSameValuesAndPaginates() throws {
        var i = inputs()
        i.seats = (1...120).map { SystemCalibrationSeat(name: "Seat \($0)", included: true, verdict: nil) }
        let s = SystemCalibrationSummary.make(i)
        let document = try XCTUnwrap(PDFDocument(data: SystemCalibrationSummaryPDF.render(s)))
        XCTAssertGreaterThan(document.pageCount, 1)
        let pdfText = try XCTUnwrap(document.string)
        for expected in ["Calibration summary", "Calibrated and verified", "UMIK-1", "umik.txt", "Warm", "Seat 120"] {
            XCTAssertTrue(pdfText.contains(expected), "PDF is missing \(expected)")
        }
    }

    func testPDFSaysWhenUnverified() throws {
        let s = SystemCalibrationSummary.make(inputs(verified: false))
        let document = try XCTUnwrap(PDFDocument(data: SystemCalibrationSummaryPDF.render(s)))
        XCTAssertTrue(try XCTUnwrap(document.string).contains("no passing verification"))
    }

    func testLiveInputsReadTheProfileAndStayPlainWithoutAProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s17-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        _ = profiles.saveCurrentSystemProfile(named: "Den")
        let live = SystemCalibrationSummaryInputs.make(engine: engine, profiles: profiles, projects: nil)
        XCTAssertEqual(live.profileName, "Den")
        XCTAssertNil(live.correction)
        XCTAssertTrue(live.seats.isEmpty)
        XCTAssertTrue(SystemCalibrationSummary.make(live).notices.contains { $0.contains("no room correction") })
    }

    func testSummaryPageFitsAtBothReferenceSizes() throws {
        let s = SystemCalibrationSummary.make(inputs(verified: false))
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(SystemCalibrationSummaryView(summary: s, close: {}), size: size)
            // SwiftUI draws the buttons itself, so check the layout: the page asks for no more width than the
            // window gives it, and no scroll area has content wider than itself.
            XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width + 0.5, "page wider than \(size.width)")
            var scrolls = 0
            func walk(_ v: NSView) {
                if let scroll = v as? NSScrollView, let document = scroll.documentView {
                    scrolls += 1
                    XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5, "sideways scroll at \(size.width)")
                }
                v.subviews.forEach(walk)
            }
            walk(page.hosting)
            XCTAssertGreaterThan(scrolls, 0)
        }
    }
}
