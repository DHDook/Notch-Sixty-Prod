import AppKit
import CoreText
import PDFKit
import SwiftUI

// E12 S17 (behind `e12.system-pages`): the calibration summary page, reached from System > Overview. It reads the
// stored project and profile, shows one `SystemCalibrationSummary`, and prints or saves it as a PDF through the system
// panels. Nothing leaves the Mac except through those panels.

enum SystemCalibrationSummaryPDF {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let margin: CGFloat = 54

    static func attributedText(_ summary: SystemCalibrationSummary) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 10.5)
        let bold = NSFont.boldSystemFont(ofSize: 12)
        let result = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = .black, after: CGFloat = 2) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            result.append(NSAttributedString(
                string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        add(summary.title, font: .boldSystemFont(ofSize: 20), after: 4)
        add("Status: " + summary.status, font: bold, after: 8)
        for notice in summary.notices { add("Notice: " + notice, font: body, color: .systemOrange.blended(withFraction: 0.4, of: .black) ?? .black, after: 4) }
        for section in summary.sections {
            add(section.title, font: bold, after: 4)
            for line in section.lines { add("\(line.label): \(line.value)", font: body) }
            add("", font: body, after: 2)
        }
        add(summary.footer, font: .systemFont(ofSize: 9), color: .darkGray)
        return result
    }

    /// A paginated US Letter PDF of the summary. Text is real text, so it can be selected and searched.
    static func render(_ summary: SystemCalibrationSummary) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = page
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let setter = CTFramesetterCreateWithAttributedString(attributedText(summary))
        let length = attributedText(summary).length
        let area = page.insetBy(dx: margin, dy: margin)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: area, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            location += max(1, visible.length)
            context.endPDFPage()
        } while location < length
        context.closePDF()
        return data as Data
    }

    @MainActor
    static func printSummary(_ summary: SystemCalibrationSummary) {
        guard let document = PDFDocument(data: render(summary)),
              let operation = document.printOperation(for: nil, scalingMode: .pageScaleDownToFit, autoRotate: true)
        else { return }
        operation.run()
    }

    @MainActor
    static func savePDF(_ summary: SystemCalibrationSummary) throws {
        let panel = NSSavePanel()
        panel.title = "Save Calibration Summary"
        panel.nameFieldStringValue = "Calibration summary.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try render(summary).write(to: url, options: .atomic)
    }
}

extension SystemCalibrationSummaryInputs {
    /// Plain values from the selected profile, the live system and the stored measurement project.
    @MainActor
    static func make(
        engine: AudioIOEngine, profiles: ProductProfileController, projects: RoomCorrectionProjectController?,
        now: Date = Date()
    ) -> SystemCalibrationSummaryInputs {
        let checklist = SystemChecklistInputs.make(engine: engine, profiles: profiles)
        var i = SystemCalibrationSummaryInputs(generated: now)
        i.profileName = profiles.selectedSystemProfile?.name
        i.outputName = engine.selectedOutputDevice?.name
        i.arrangement = checklist.arrangementSummary
        i.correction = checklist.calibration
        i.verifiedDesignID = checklist.record?.verifiedDesignID
        i.verifiedDate = checklist.record?.verifiedDate
        i.movedDate = checklist.record?.movedDate
        i.outOfDate = SystemChecklistModel.outOfDateReasons(checklist)
        i.bassLine = checklist.bassEnabled ? checklist.bassSummary : nil

        var lines: [String] = []
        for speaker in engine.speakerRoutingConfiguration?.speakers ?? [] {
            for way in speaker.ways where way.trimDB != 0 || way.delayMilliseconds != 0 || way.polarityInverted {
                let name = [speaker.name, way.name].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append(String(
                    format: "%@: %+.1f dB, %.2f ms%@", name.isEmpty ? "Output" : name, way.trimDB, way.delayMilliseconds,
                    way.polarityInverted ? ", polarity inverted" : ""))
            }
        }
        let bass = engine.bassManagementConfiguration
        if bass.subGainDB != 0 || bass.subPolarityInverted {
            lines.append(String(format: "Subwoofer: %+.1f dB%@", bass.subGainDB, bass.subPolarityInverted ? ", polarity inverted" : ""))
        }
        i.alignmentLines = lines

        guard let calibration = checklist.calibration, let project = projects?.project, project.id == calibration.projectID
        else { return i }
        i.microphoneKnown = project.microphone != nil
        i.microphoneName = project.microphone?.displayName
        i.calibrationFile = project.microphone?.calibration?.sourceName
        i.measurementDate = calibration.measurementDate ?? project.measurements.map(\.left.capturedAt).max()
        i.correctionLimitHz = SystemSetupCorrectionLimit.limitHz(calibrationFile: i.calibrationFile)

        let design = project.designs.first { $0.id == calibration.activeDesignID }
        let report = design.flatMap { try? projects?.verification(for: $0) }
        i.seats = project.measurements.map { position in
            let verdict = MeasurementVerdictRules.verdict(forSeat: [
                (source: "Left", quality: position.left.quality), (source: "Right", quality: position.right.quality),
            ])
            let seatReport = report?.positionReports.first { $0.positionID == position.id }
            return SystemCalibrationSeat(
                name: position.name, included: position.included, verdict: verdict,
                rmsErrorBeforeDB: seatReport?.rmsErrorBeforeDB, rmsErrorAfterDB: seatReport?.rmsErrorAfterDB)
        }
        return i
    }
}

struct SystemCalibrationSummaryView: View {
    let summary: SystemCalibrationSummary
    var close: () -> Void
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            ViewThatFits(in: .horizontal) {
                HStack { header; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { header; actions }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                    ForEach(summary.notices, id: \.self) { notice in
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(StatusLevel.attention.color).font(DesignType.label.font)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(summary.sections) { section in
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                            Text(section.title).font(DesignType.sectionTitle.font)
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(line.label).font(DesignType.caption.font).foregroundStyle(.secondary)
                                    Text(line.value).font(DesignType.label.font).fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    Text(summary.footer).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorText { Text(errorText).font(DesignType.caption.font).foregroundStyle(StatusLevel.problem.color) }
        }
        .padding(DesignSpacing.l.pt)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 360, idealHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(summary.title).font(DesignType.sectionTitle.font.bold())
            Text(summary.status).font(DesignType.label.font).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Print…") { SystemCalibrationSummaryPDF.printSummary(summary) }
            Button("Save as PDF…") {
                do { try SystemCalibrationSummaryPDF.savePDF(summary) } catch { errorText = error.localizedDescription }
            }
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.glass)
    }
}
