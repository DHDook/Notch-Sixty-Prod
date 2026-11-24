import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupBassStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.bassStepMode == .monoBass ? "Share the bass between the speakers" : "Blend the subwoofer").font(.headline)
            if case .skipped(let reason)? = model.bassStepMode {
                Label(reason, systemImage: "info.circle")
                if let advice = model.receiverAdvice {
                    GroupBox("Before you continue") { Text(advice).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Text("Continue to the next step.").foregroundStyle(.secondary)
            } else if model.bassStepMode == .monoBass {
                monoBassContent
            } else if !model.hasSubwoofer {
                Text("You have no subwoofer, so there is nothing to blend. Continue to the next step.")
                    .foregroundStyle(.secondary)
            } else if let bass = model.bass {
                content(bass)
            } else {
                Button("Work out the bass design") { model.computeBass() }
            }
        }
        .onAppear {
            if model.bassStepMode == .monoBass { if model.monoBass == nil { model.computeBass() } }
            else if model.hasSubwoofer && model.bass == nil { model.computeBass() }
        }
    }

    @ViewBuilder
    private var monoBassContent: some View {
        Text("Both speakers share the low frequencies. Notch Sixty picks where the sharing starts from how low your speakers play at the seats you measured. Apply it to hear the result; you can skip this to keep the standard 80 Hz setting.")
            .font(.callout).foregroundStyle(.secondary)
        if let design = model.monoBass {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Left speaker plays down to").bold(); Text("\(design.leftExtensionHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Right speaker plays down to").bold(); Text("\(design.rightExtensionHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Shared bass below").bold(); Text("\(design.crossoverHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Slope").bold(); Text("\(design.filter.slopeDBPerOctave) dB per octave").monospacedDigit() }
            }
            HStack {
                Button("Apply") { Task { await model.applyBass() } }.disabled(model.choices.bassApplied)
                Button("Revert") { model.revertBass() }.disabled(!model.choices.bassApplied)
                if model.choices.bassApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
            }
        } else {
            Button("Work out the bass design") { model.computeBass() }
        }
    }

    @ViewBuilder
    private func content(_ bass: SystemSetupBassDesign) -> some View {
        Text("Notch Sixty sets the subwoofer's level, delay and polarity (push or pull) so bass is as even as possible across every seat you measured. Apply it to hear the result; Revert or Cancel restores your earlier settings.")
            .font(.callout).foregroundStyle(.secondary)
        if bass.mode == .subAlignmentOnly {
            Label("The subwoofer keeps the alignment you applied in the previous step.", systemImage: "checkmark.circle")
        } else {
            if let before = bass.seatSpreadBeforeDB, let after = bass.seatSpreadAfterDB {
                Text("Seat-to-seat bass difference (20 to 120 Hz): \(before, specifier: "%.1f") dB now, \(after, specifier: "%.1f") dB predicted.")
            }
            SystemSetupGraphPanel(model: model, graph: model.bassGraph, emptyNote: "No bass graph for this design.")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Seat").bold(); Text("Average level now").bold(); Text("Predicted").bold() }
                ForEach(Array(bass.seatNames.enumerated()), id: \.offset) { index, name in
                    GridRow {
                        Text(name)
                        Text("\(bass.seatMeanBeforeDB[safe: index] ?? 0, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(bass.seatMeanAfterDB[safe: index] ?? 0, specifier: "%.1f") dB").monospacedDigit()
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Speaker").bold(); Text("Level").bold(); Text("Delay").bold(); Text(SystemSetupTerm.polarity.plainLabel).bold() }
                ForEach(bass.rows) { row in
                    GridRow {
                        Text(row.title)
                        Text("\(row.gainDB, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(row.delayMilliseconds, specifier: "%.2f") ms").monospacedDigit()
                        Text(row.polarityInverted ? "Inverted" : "Normal")
                    }
                }
            }
            SystemSetupTermNotes(step: .bass)
        }
        HStack {
            Button("Apply") { Task { await model.applyBass() } }.disabled(model.choices.bassApplied)
            Button("Revert") { model.revertBass() }.disabled(!model.choices.bassApplied)
            if model.choices.bassApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
