import SwiftUI

// E12 S15 (behind `e12.system-pages`): the System Overview checklist. Read-only, like the Dashboard: each row shows a
// state, a date, a one-line summary and a button to the place that changes it. The next step is highlighted.

extension SystemChecklistInputs {
    /// Plain values from the live system and the selected profile.
    @MainActor
    static func make(engine: AudioIOEngine, profiles: ProductProfileController) -> SystemChecklistInputs {
        var i = SystemChecklistInputs()
        let state = profiles.selectedSystemProfile?.state
        if let arrangement = state?.systemArrangement {
            let speakers = arrangement.speakers.count
            let subs = arrangement.subwooferCount
            i.arrangementSummary = "\(speakers) \(speakers == 1 ? "speaker" : "speakers")"
                + (subs > 0 ? " and \(subs) \(subs == 1 ? "subwoofer" : "subwoofers")" : "") + "."
        }
        let bass = engine.bassManagementConfiguration
        var trimmed = 0
        for speaker in engine.speakerRoutingConfiguration?.speakers ?? [] {
            for way in speaker.ways where way.trimDB != 0 || way.delayMilliseconds != 0 || way.polarityInverted {
                trimmed += 1
            }
        }
        if bass.subGainDB != 0 || bass.subPolarityInverted { trimmed += 1 }
        i.alignmentConfigured = trimmed > 0
        i.alignmentSummary = "\(trimmed) \(trimmed == 1 ? "output has" : "outputs have") a level, delay or polarity set."
        i.bassEnabled = bass.enabled
        i.bassSummary = String(format: "Crossover at %.0f Hz, %@.", bass.frequencyHz, bass.topology.displayName)
        i.calibration = state?.roomCorrectionCalibration
        i.record = state?.calibrationRecord
        i.current = profiles.currentCalibrationStamp()
        return i
    }
}

struct SystemOverviewChecklistView: View {
    let rows: [SystemChecklistRow]
    var open: (SystemChecklistRowID) -> Void
    var moved: () -> Void

    var body: some View {
        GroupBox("Calibration checklist") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    SystemChecklistRowView(row: row) { open(row.rowID) }
                    if row.id != rows.last?.id { Divider() }
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("I moved something", action: moved)
                        Text("Say so when you move a speaker or the seat. The calibration shows as out of date; nothing is switched off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Button("I moved something", action: moved)
                        Text("Say so when you move a speaker or the seat. The calibration shows as out of date; nothing is switched off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }
}

struct SystemChecklistRowView: View {
    let row: SystemChecklistRow
    var open: () -> Void

    private var symbol: String {
        switch row.state {
        case .done: return "checkmark.circle.fill"
        case .notDone: return "circle.dashed"
        case .outOfDate: return "exclamationmark.triangle.fill"
        }
    }

    private var stateText: String {
        switch row.state {
        case .done: return "Done"
        case .notDone: return "Not done"
        case .outOfDate: return "Out of date"
        }
    }

    var accessibilityText: String {
        var parts = [row.rowID.title, stateText]
        if let date = row.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        parts.append(row.summary)
        if let reason = row.reason { parts.append(reason) }
        if row.isNextStep { parts.append("Next step") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { content; Spacer(minLength: 8); button }
            VStack(alignment: .leading, spacing: 6) { HStack(alignment: .top, spacing: 10) { content }; button }
        }
        .padding(6)
        .background(row.isNextStep ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var content: some View {
        Group {
            Image(systemName: symbol)
                .foregroundStyle(row.state == .done ? Color.green : row.state == .outOfDate ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.rowID.title).font(.headline)
                    if row.isNextStep { Text("Next").font(.caption.bold()).foregroundStyle(Color.accentColor) }
                }
                Text(row.summary).font(.callout).foregroundStyle(.secondary)
                if let date = row.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = row.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var button: some View {
        Button(row.rowID.buttonTitle, action: open)
    }
}
