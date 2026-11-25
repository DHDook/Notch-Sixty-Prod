import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupCorrectionStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @Environment(\.interfaceMode) private var interfaceMode

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Correct the room").font(DesignType.sectionTitle.font)
            Text("Notch Sixty flattens the bumps and dips your seats share, using the measurements you already made. Nothing is measured again.")
                .font(DesignType.label.font).foregroundStyle(.secondary)
            if let note = model.correctionNote { Label(note, systemImage: "info.circle").font(DesignType.label.font) }
            if let limit = model.correctionLimitHz {
                Label(SystemSetupCorrectionLimit.note(limitHz: limit), systemImage: "exclamationmark.triangle").font(DesignType.label.font)
            }
            if let limit = model.correctionLimitHz, interfaceMode.showsCorrectionLimitControl(flagEnabled: FeatureFlags().isEnabled(.simpleExpertModes)) {
                SystemSetupCorrectionLimitControl(model: model, limitHz: limit)
            }
            if let advice = model.receiverAdvice { Text(advice).font(DesignType.label.font).foregroundStyle(.secondary) }
            Picker("Listening", selection: $model.correctionMode) {
                ForEach(SystemSetupCorrectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.correctionMode.detail).font(DesignType.label.font).foregroundStyle(.secondary)
            Picker("Sound", selection: $model.correctionTarget) {
                ForEach(model.correctionTargetChoices) { Text($0.title).tag($0) }
            }
            .onAppear { model.refreshCorrectionTargets() }
            Text(model.correctionTarget.detail).font(DesignType.label.font).foregroundStyle(.secondary)
            if !model.seatPredictions.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Seat").bold(); Text(SystemSetupTerm.errorNow.plainLabel).bold(); Text("Predicted").bold() }
                    ForEach(model.seatPredictions) { seat in
                        GridRow {
                            Text(seat.name)
                            Text("\(seat.rmsErrorBeforeDB, specifier: "%.1f") dB").monospacedDigit()
                            Text("\(seat.rmsErrorAfterDB, specifier: "%.1f") dB").monospacedDigit()
                        }
                    }
                }
            }
            SystemSetupGraphPanel(model: model, graph: model.correctionGraph,
                                  emptyNote: "The graph appears once your seats are measured.")
            SystemSetupTermNotes(step: .correction)
            HStack {
                Button("Apply") { Task { await model.applyCorrection() } }.disabled(model.choices.correctionApplied)
                Button("Revert") { model.revertCorrection() }.disabled(!model.choices.correctionApplied)
                if model.choices.correctionApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
            }
        }
    }
}

/// E12 S8 (G86): expert mode only. Moves the upper edge of correction while the microphone has no calibration file.
struct SystemSetupCorrectionLimitControl: View {
    @ObservedObject var model: SystemSetupFlowModel
    let limitHz: Double

    @ViewBuilder private var controls: some View {
        let range = SystemSetupCorrectionLimit.overrideRangeHz
        Text("Correction limit").font(DesignType.label.font)
        Slider(
            value: Binding(get: { log2(limitHz) }, set: { model.setCorrectionLimitOverride(pow(2, $0)) }),
            in: log2(range.lowerBound)...log2(range.upperBound))
            .frame(width: 220)
            .disabled(model.choices.correctionApplied)
        Text("\(Int(limitHz.rounded())) Hz").monospacedDigit().font(DesignType.label.font)
        Button("Default") { model.setCorrectionLimitOverride(nil) }
            .disabled(model.choices.correctionApplied || limitHz == SystemSetupCorrectionLimit.defaultHz)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            Text("Above 300 Hz an uncalibrated microphone can mislead the correction. Revert the correction to change this.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
    }
}
