import Foundation

// E12 S17 (G20, summary part): one page that says what was measured, what was applied, how each seat came out and
// whether the calibration still stands. Pure value types: the page, the print and the PDF all render the same
// `SystemCalibrationSummary`, so what is on the screen is what is on paper. No engine, no SwiftUI, nothing here runs
// on an audio thread.

/// One measured seat, as the summary lists it.
struct SystemCalibrationSeat: Equatable, Sendable {
    var name: String
    var included: Bool
    var verdict: MeasurementVerdict?
    /// RMS distance from the target across the correction band, before and after the correction (dB).
    var rmsErrorBeforeDB: Double?
    var rmsErrorAfterDB: Double?
}

/// Plain values the summary is built from.
struct SystemCalibrationSummaryInputs: Equatable, Sendable {
    var profileName: String?
    var outputName: String?
    var arrangement: String?
    var microphoneName: String?
    /// The microphone calibration file name; nil or empty means none.
    var calibrationFile: String?
    var microphoneKnown = false
    var measurementDate: Date?
    var seats: [SystemCalibrationSeat] = []
    var alignmentLines: [String] = []
    var bassLine: String?
    var correction: RoomCorrectionCalibrationSummary?
    var verifiedDesignID: UUID?
    var verifiedDate: Date?
    var outOfDate: [SystemCalibrationChange] = []
    var movedDate: Date?
    var correctionLimitHz: Double?
    var generated: Date
}

struct SystemCalibrationSummary: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var label: String
        var value: String
    }

    struct Section: Equatable, Identifiable, Sendable {
        var title: String
        var lines: [Line]
        var id: String { title }
    }

    var title: String
    var status: String
    /// Warnings that must be seen first: unverified, out of date, no calibration.
    var notices: [String]
    var sections: [Section]
    var footer: String

    static func make(_ i: SystemCalibrationSummaryInputs) -> SystemCalibrationSummary {
        let status = SystemCalibrationStatus.resolve(summary: i.correction, verifiedDesignID: i.verifiedDesignID)
        var notices: [String] = []
        if i.correction == nil {
            notices.append("This system has no room correction, so there is nothing to verify.")
        }
        if case .unverified = status {
            notices.append("The correction has no passing verification. Run the verification in Calibrate.")
        }
        if let reason = SystemChecklistModel.reasonText(i.outOfDate) {
            notices.append(reason + " Measure or verify again to bring it up to date.")
        }

        func date(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded" }

        var measured: [Line] = [
            .init(label: "Profile", value: i.profileName ?? "None"),
            .init(label: "Output", value: i.outputName ?? "None selected"),
            .init(label: "Speakers", value: i.arrangement ?? "No arrangement chosen"),
            .init(label: "Microphone", value: i.microphoneKnown ? (i.microphoneName ?? "Unnamed") : "Not recorded"),
            .init(
                label: "Calibration file",
                value: i.microphoneKnown ? (i.calibrationFile.flatMap { $0.isEmpty ? nil : $0 } ?? "None") : "Not recorded"),
            .init(label: "Measured", value: date(i.measurementDate)),
            .init(label: "Seats", value: i.seats.isEmpty ? "None measured" : "\(i.seats.filter(\.included).count) of \(i.seats.count) used"),
        ]
        if i.microphoneKnown, i.calibrationFile?.isEmpty ?? true, let limit = i.correctionLimitHz {
            measured.append(.init(label: "Limit", value: "No calibration file, so correction stops at \(Int(limit.rounded())) Hz."))
        }

        var applied: [Line] = i.alignmentLines.isEmpty
            ? [.init(label: "Alignment", value: "No levels, delays or polarity set")]
            : i.alignmentLines.map { .init(label: "Alignment", value: $0) }
        applied.append(.init(label: "Bass", value: i.bassLine ?? "Bass management is off"))
        if let c = i.correction {
            applied += [
                .init(label: "Correction target", value: c.targetName),
                .init(label: "Range", value: "\(Int(c.correctionLowHz.rounded())) to \(Int(c.correctionHighHz.rounded())) Hz"),
                .init(
                    label: "Strength",
                    value: String(format: "Up to %.1f dB boost, %.1f dB cut, %.2f octave smoothing",
                                  c.maximumBoostDB, c.maximumCutDB, c.smoothingOctaves)),
                .init(label: "Designed", value: date(c.designDate)),
            ]
        } else {
            applied.append(.init(label: "Correction", value: "None"))
        }

        var seats: [Line] = []
        for seat in i.seats {
            var parts: [String] = []
            if !seat.included { parts.append("left out") }
            if let v = seat.verdict { parts.append("\(v.level.title): \(v.reason)") }
            if let before = seat.rmsErrorBeforeDB, let after = seat.rmsErrorAfterDB {
                parts.append(String(format: "error from target %.1f dB before, %.1f dB after", before, after))
            }
            seats.append(.init(label: seat.name, value: parts.isEmpty ? "No result recorded" : parts.joined(separator: "; ")))
        }
        if seats.isEmpty { seats = [.init(label: "Seats", value: "No seat results to show")] }

        let verification: String
        switch status {
        case .notCalibrated: verification = "Nothing to verify"
        case .unverified: verification = "Not verified"
        case .verified: verification = "Passed" + (i.verifiedDate.map { " on " + date($0) } ?? "")
        }

        return SystemCalibrationSummary(
            title: "Calibration summary",
            status: status.headline + (i.outOfDate.isEmpty ? "" : ", out of date"),
            notices: notices,
            sections: [
                .init(title: "What was measured", lines: measured),
                .init(title: "What was applied", lines: applied),
                .init(title: "Each seat, before and after", lines: seats),
                .init(title: "Verification", lines: [.init(label: "Result", value: verification)]),
            ],
            footer: "Made on " + date(i.generated) + ". Stays on this Mac unless you save or print it.")
    }

    /// The whole page as plain text: the PDF is drawn from this, so it carries exactly the same values.
    var plainText: String {
        var out = [title, "Status: " + status]
        if !notices.isEmpty { out.append(""); out += notices.map { "Notice: " + $0 } }
        for section in sections {
            out += ["", section.title]
            out += section.lines.map { "\($0.label): \($0.value)" }
        }
        out += ["", footer]
        return out.joined(separator: "\n")
    }
}
