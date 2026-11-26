import SwiftUI

// E12 S16 (G18): the distances and levels table at the top of Calibrate > Alignment. Per speaker: distance (length and
// milliseconds), level trim and polarity, through the arrangement's per-feed calibration (the same trim, delay and
// polarity the wizard's Alignment step writes). Two-channel (feed session) arrangements only; other layouts keep their
// per-driver trims in the routing matrix.

/// Writes table edits: stamps a configured-but-unstamped system first (G91), then stores and applies the change.
@MainActor
enum SpeakerFeedTableEditor {
    static func edit(
        side: SpeakerFeedRow.Side, engine: AudioIOEngine, profiles: ProductProfileController,
        _ change: (inout SpeakerFeedCalibration) -> Void
    ) throws {
        guard let arrangement = profiles.selectedSystemProfile?.state.systemArrangement,
              SystemSetupAdaptiveSteps.isFeedSession(arrangement) else { return }
        profiles.stampBeforeManualChange(
            hadConfiguration: SpeakerFeedTable.hadConfiguration(
                arrangement: arrangement, bass: engine.bassManagementConfiguration))
        _ = try SystemArrangementApplier.editStereoAlignment(
            of: arrangement,
            { alignment in alignment = SpeakerFeedTable.editing(alignment, side: side, change) },
            profiles: profiles, engine: engine)
    }

    /// Puts one speaker (or both, when `side` is nil) back to the measured values.
    static func resetToMeasured(
        side: SpeakerFeedRow.Side?, engine: AudioIOEngine, profiles: ProductProfileController
    ) throws {
        guard let measured = profiles.selectedSystemProfile?.state.calibrationRecord?.measuredFeeds else { return }
        for target in [SpeakerFeedRow.Side.left, .right] where side == nil || side == target {
            let values = target == .left ? measured.left : measured.right
            try edit(side: target, engine: engine, profiles: profiles) { $0 = values }
        }
    }
}

struct SpeakerDistancesLevelsTable: View {
    var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var unit: DistanceUnit = .metres
    @State private var error: String?

    private var rows: [SpeakerFeedRow] {
        SpeakerFeedTable.rows(
            arrangement: profiles.selectedSystemProfile?.state.systemArrangement,
            measured: profiles.selectedSystemProfile?.state.calibrationRecord?.measuredFeeds)
    }

    private var driverRows: [SpeakerDriverRow] {
        SpeakerDriverTable.rows(routing: engine.speakerRoutingConfiguration)
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Text("Distances and levels").font(DesignType.sectionTitle.font)
                Spacer()
                Picker("Distance unit", selection: $unit) {
                    ForEach(DistanceUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 100)
            }
            if rows.isEmpty && driverRows.isEmpty {
                Text("Per-speaker distance, level and polarity are edited here for two-channel speaker pairs and for "
                    + "systems that use the routing matrix.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("One row per driver. Distance is how far a driver's sound is delayed to arrive together with the others.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                ForEach(driverRows) { row in driverRowView(row) }
            } else {
                Text("Distance is how far a speaker's sound is delayed to arrive together with the others. "
                    + "Values from the alignment are shown as measured; your own changes are marked.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                ForEach(rows) { row in rowView(row) }
                if rows.contains(where: \.isManual) {
                    Button("Reset all to measured") { run { try SpeakerFeedTableEditor.resetToMeasured(
                        side: nil, engine: engine, profiles: profiles) } }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignType.label.font).foregroundStyle(StatusLevel.problem.color)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.medium.pt))
        .padding(.horizontal, DesignSpacing.xl.pt)
        .padding(.top, DesignSpacing.m.pt)
    }

    private func rowView(_ row: SpeakerFeedRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.l.pt) { cells(row) }
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { cells(row) }
        }
    }

    @ViewBuilder
    private func cells(_ row: SpeakerFeedRow) -> some View {
        Text(row.name).font(DesignType.label.font.bold()).frame(width: 60, alignment: .leading)
        LabeledContent("Distance") {
            HStack(spacing: 6) {
                TextField("Distance", value: Binding(
                    get: { SpeakerFeedTable.distance(delayMs: row.feed.delayMs, unit: unit) },
                    set: { value in
                        let ms = SpeakerFeedTable.delayMs(distance: value, unit: unit)
                        run { try SpeakerFeedTableEditor.edit(side: row.side, engine: engine, profiles: profiles) { $0.delayMs = ms } }
                    }), format: .number.precision(.fractionLength(2)))
                    .frame(width: 70).multilineTextAlignment(.trailing)
                Text(unit.title)
                Text("(\(row.feed.delayMs, specifier: "%.2f") ms)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        LabeledContent("Level") {
            HStack(spacing: 6) {
                TextField("Level", value: Binding(
                    get: { row.feed.trimDB },
                    set: { value in
                        run { try SpeakerFeedTableEditor.edit(side: row.side, engine: engine, profiles: profiles) { $0.trimDB = value } }
                    }), format: .number.precision(.fractionLength(1)))
                    .frame(width: 60).multilineTextAlignment(.trailing)
                Text("dB")
            }
        }
        Toggle("Invert polarity", isOn: Binding(
            get: { row.feed.polarityInverted },
            set: { value in
                run { try SpeakerFeedTableEditor.edit(side: row.side, engine: engine, profiles: profiles) { $0.polarityInverted = value } }
            }))
        if row.isManual {
            Label("Changed by you", systemImage: "pencil").font(DesignType.caption.font).foregroundStyle(.secondary)
            Button("Reset to measured") { run { try SpeakerFeedTableEditor.resetToMeasured(
                side: row.side, engine: engine, profiles: profiles) } }
        }
    }

    private func driverRowView(_ row: SpeakerDriverRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.l.pt) { driverCells(row) }
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { driverCells(row) }
        }
    }

    @ViewBuilder
    private func driverCells(_ row: SpeakerDriverRow) -> some View {
        Text(row.title).font(DesignType.label.font.bold()).frame(width: 140, alignment: .leading)
        LabeledContent("Distance") {
            HStack(spacing: 6) {
                TextField("Distance", value: Binding(
                    get: { SpeakerFeedTable.distance(delayMs: row.delayMs, unit: unit) },
                    set: { value in
                        let ms = SpeakerFeedTable.delayMs(distance: value, unit: unit)
                        run { try SpeakerDriverTableEditor.edit(way: row.id, engine: engine, profiles: profiles) { $0.delayMs = ms } }
                    }), format: .number.precision(.fractionLength(2)))
                    .frame(width: 70).multilineTextAlignment(.trailing)
                Text(unit.title)
                Text("(\(row.delayMs, specifier: "%.2f") ms)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        LabeledContent("Level") {
            HStack(spacing: 6) {
                TextField("Level", value: Binding(
                    get: { row.trimDB },
                    set: { value in
                        run { try SpeakerDriverTableEditor.edit(way: row.id, engine: engine, profiles: profiles) { $0.trimDB = value } }
                    }), format: .number.precision(.fractionLength(1)))
                    .frame(width: 60).multilineTextAlignment(.trailing)
                Text("dB")
            }
        }
        Toggle("Invert polarity", isOn: Binding(
            get: { row.polarityInverted },
            set: { value in
                run { try SpeakerDriverTableEditor.edit(way: row.id, engine: engine, profiles: profiles) { $0.polarityInverted = value } }
            }))
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
