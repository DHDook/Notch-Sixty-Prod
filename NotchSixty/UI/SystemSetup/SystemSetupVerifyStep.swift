import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupVerifyStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the result").font(.headline)
            Text("Notch Sixty measures your main seat once more with the correction on and compares it with what was predicted.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Verify") { model.runVerification() }.disabled(model.isVerifying)
                if model.isVerifying {
                    ProgressView().controlSize(.small)
                    Button("Cancel check") { model.cancelVerification() }
                }
            }
            if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: summary.verdict == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(summary.detail).font(.callout).foregroundStyle(.secondary)
            }
            if let report = model.verificationReport {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Predicted error").bold(); Text("Measured error").bold() }
                    GridRow {
                        Text("\(report.predictedErrorDB, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(report.measuredErrorDB, specifier: "%.1f") dB").monospacedDigit()
                    }
                }
            }
            if model.verificationReport != nil {
                SystemSetupGraphPanel(model: model, graph: model.verifyGraph,
                                      emptyNote: "This check did not report a response to draw.")
            }
            roomInsightsCard
        }
    }

    private var roomInsightsCard: some View {
        GroupBox("Room insights") {
            VStack(alignment: .leading, spacing: 8) {
                if model.roomInsights.isEmpty {
                    Text("Nothing here that EQ cannot handle.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.roomInsights) { insight in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.callout.weight(insight.isImportant ? .semibold : .regular))
                        Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("After you save, the summary links to the full Room advisor.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
