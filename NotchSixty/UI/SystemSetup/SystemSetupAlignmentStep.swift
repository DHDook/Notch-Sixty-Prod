import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupAlignmentStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Align levels, polarity (push or pull) and distances").font(.headline)
            Text("Notch Sixty matches the loudness and arrival time of your speakers at the seats you measured. Apply it to hear the result; you can revert at any time and Cancel restores everything.")
                .font(.callout).foregroundStyle(.secondary)
            if let note = model.alignmentSubNote {
                Label(note, systemImage: "info.circle").font(.callout)
            }
            if let alignment = model.alignment {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Speaker").bold(); Text("Level").bold(); Text("Delay").bold()
                        Text(SystemSetupTerm.polarity.plainLabel).bold(); Text("Distance").bold()
                    }
                    ForEach(alignment.rows) { row in
                        GridRow {
                            Text(model.sourceLabel(row.source))
                            Text("\(row.levelDB, specifier: "%.1f") dB").monospacedDigit()
                            Text("\(row.delayMilliseconds, specifier: "%.2f") ms").monospacedDigit()
                            Text(row.polarityInverted ? "Inverted" : "Normal")
                            Text(row.distanceText).monospacedDigit()
                        }
                    }
                }
                SystemSetupTermNotes(step: .alignment)
                if !alignment.invertedSources.isEmpty {
                    Label("A speaker looks wired out of polarity. Alignment flips it for you; check the wiring too.",
                          systemImage: "exclamationmark.triangle").font(.callout)
                }
                HStack {
                    Button("Apply") { model.applyAlignment() }.disabled(model.choices.alignmentApplied)
                    Button("Revert") { model.revertAlignment() }.disabled(!model.choices.alignmentApplied)
                    if model.choices.alignmentApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
                }
            } else {
                Button("Work out the alignment") { Task { await model.computeAlignment() } }
            }
        }
        .onAppear { if model.alignment == nil { Task { await model.computeAlignment() } } }
    }
}
